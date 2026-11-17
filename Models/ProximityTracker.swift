// ProximityTracker.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation

enum Observation: Equatable {
    case signal(RSSI)
    /// Connected, but the stack reports no RSSI. Treated as nearby.
    case connectedWithoutSignal
    /// Never nearby, whatever the thresholds.
    case disconnected

    func meets(_ threshold: Int) -> Bool {
        switch self {
        case .signal(let rssi): return rssi.dBm >= threshold
        case .connectedWithoutSignal: return true
        case .disconnected: return false
        }
    }

    var rssi: RSSI? {
        if case .signal(let rssi) = self { return rssi }
        return nil
    }
}

/// RSSI hysteresis band: become nearby at `present`, stay nearby down to `away`.
struct ProximityThresholds: Equatable {
    let present: Int
    let away: Int
}

enum Sighting: Equatable {
    case nearby, away
}

/// Only `seen` is evidence. `unobserved` (no reading since scanning started) and
/// `assumedNearby` (held nearby during the BT recovery cooldown, not observed) are not.
enum Proximity: Equatable {
    case unobserved
    /// Treated as nearby for hysteresis and debounce, so devices don't flap away
    /// while connections recover; only a real observation replaces it.
    case assumedNearby
    case seen(Sighting)

    /// Nearby for the tracker's own hysteresis, whether observed or assumed.
    var holdsNearby: Bool {
        switch self {
        case .assumedNearby, .seen(.nearby): return true
        case .unobserved, .seen(.away): return false
        }
    }
}

extension Proximity {
    /// Positive evidence only: what each trusted device was actually seen as.
    static func sightings(
        of devices: [TrustedDevice],
        _ proximity: (TrustedDevice.ID) -> Proximity
    ) -> [TrustedDevice: Sighting] {
        devices.reduce(into: [:]) { result, device in
            switch proximity(device.id) {
            case .seen(let sighting): result[device] = sighting
            case .unobserved, .assumedNearby: break
            }
        }
    }
}

/// A change in what a trusted device is seen as: the one way proximity reaches the
/// alarm. Becoming nearby is a return, becoming away a departure; losing sight
/// (scan stopped or reset, device removed, proximity only assumed) is neither.
enum SightingChange: Equatable {
    case seen(TrustedDevice, Sighting)
    case lost(TrustedDevice)

    /// One change per device whose sighting differs, in a stable order.
    static func changes(from old: [TrustedDevice: Sighting], to new: [TrustedDevice: Sighting]) -> [SightingChange] {
        let devices = Set(old.keys).union(new.keys).sorted { $0.id.uuidString < $1.id.uuidString }
        return devices.compactMap { device in
            switch (old[device], new[device]) {
            case let (before, now?) where before != now: return .seen(device, now)
            case (_?, nil): return .lost(device)
            case (_, _?), (nil, nil): return nil
            }
        }
    }

    func applied(to sightings: [TrustedDevice: Sighting]) -> [TrustedDevice: Sighting] {
        var result = sightings
        switch self {
        case .seen(let device, let sighting): result[device] = sighting
        case .lost(let device): result[device] = nil
        }
        return result
    }
}

enum ProximityChange: Equatable {
    case becameNearby
    case becameAway
    case awaySuppressedByCooldown
    case awayDebounced(sinceNearby: TimeInterval)
    case unchanged
}

/// Debounce windows (seconds), longer in Low Power Mode where scans are sparser.
enum ProximityTiming {
    static func awayDebounce(lowPower: Bool) -> TimeInterval { lowPower ? 10 : 3 }
    static func disconnectDebounce(lowPower: Bool) -> TimeInterval { lowPower ? 15 : 5 }
    static let classicSignalTimeout: TimeInterval = 1
}

/// Hysteresis + debounce state for one trusted device.
struct ProximityTracker: Equatable {
    private(set) var proximity: Proximity = .unobserved
    private(set) var lastObservation: Observation?
    private(set) var lastNearby: Date?
    private var lastNearbySignal: Date?

    var isNearby: Bool { proximity.holdsNearby }

    mutating func observe(
        _ observation: Observation,
        at now: Date,
        thresholds: ProximityThresholds,
        lowPower: Bool,
        recoveryCooldownActive: Bool
    ) -> ProximityChange {
        let wasNearby = isNearby
        var nearby = observation.meets(wasNearby ? thresholds.away : thresholds.present)
        var change = ProximityChange.unchanged

        if wasNearby && !nearby {
            if recoveryCooldownActive {
                nearby = true
                change = .awaySuppressedByCooldown
            } else {
                let since = now.timeIntervalSince(lastNearbySignal ?? .distantPast)
                if since < ProximityTiming.awayDebounce(lowPower: lowPower) {
                    nearby = true
                    change = .awayDebounced(sinceNearby: since)
                }
            }
        }

        // Measured before the overrides above, so a run of weak readings ages out
        if observation.meets(thresholds.away) {
            lastNearbySignal = now
        }
        // Held nearby only by the cooldown: an assumption, not a sighting
        proximity = change == .awaySuppressedByCooldown ? .assumedNearby : .seen(nearby ? .nearby : .away)
        lastObservation = observation
        if nearby {
            lastNearby = now
        }

        if !wasNearby && nearby { return .becameNearby }
        if wasNearby && !nearby { return .becameAway }
        return change
    }

    func shouldDebounceDisconnect(at now: Date, lowPower: Bool) -> Bool {
        now.timeIntervalSince(lastNearby ?? .distantPast) < ProximityTiming.disconnectDebounce(lowPower: lowPower)
    }

    mutating func markDisconnected() -> ProximityChange {
        let wasNearby = isNearby
        proximity = .seen(.away)
        return wasNearby ? .becameAway : .unchanged
    }

    /// So devices don't flap "away" (and auto-arm) while connections recover after BT power-on.
    mutating func assumeNearbyForRecovery() -> ProximityChange {
        switch proximity {
        case .unobserved, .assumedNearby, .seen(.nearby): return .unchanged
        case .seen(.away):
            proximity = .assumedNearby
            return .becameNearby
        }
    }

    /// Forgets the current reading, keeps debounce history. Not a change: unobserved
    /// is neither nearby nor away.
    mutating func resetForScan() {
        proximity = .unobserved
        lastObservation = nil
    }
}

/// IOBluetooth connection state machine for one Classic device.
struct ClassicLinkTracker: Equatable {
    enum Link: Equatable {
        /// No poll since scanning started.
        case unpolled
        /// `since` is the last accepted state change, the disconnect-debounce clock.
        case polled(connected: Bool, since: Date)
    }

    private(set) var link: Link = .unpolled
    /// Last RSSI since scanning started; inquiry results can land in any link state.
    private var lastSignal: Date?

    var isConnected: Bool {
        switch link {
        case .unpolled: return false
        case .polled(let connected, _): return connected
        }
    }

    enum LinkEvent: Equatable {
        case initiallyConnected, initiallyDisconnected, connected, disconnected
    }

    enum PollResult: Equatable {
        case none
        case disconnectDebounced
        case observe(Observation, LinkEvent?)
    }

    mutating func poll(isConnected: Bool, rssi: RSSI?, at now: Date, lowPower: Bool) -> PollResult {
        let connectedObservation = rssi.map(Observation.signal) ?? .connectedWithoutSignal

        switch link {
        case .unpolled:
            link = .polled(connected: isConnected, since: now)
            return isConnected
                ? .observe(connectedObservation, .initiallyConnected)
                : .observe(.disconnected, .initiallyDisconnected)

        case .polled(let wasConnected, let since) where isConnected != wasConnected:
            // AirPods and similar flap; ignore a disconnect right after a change
            if !isConnected && now.timeIntervalSince(since) < ProximityTiming.disconnectDebounce(lowPower: lowPower) {
                return .disconnectDebounced
            }
            link = .polled(connected: isConnected, since: now)
            return isConnected
                ? .observe(connectedObservation, .connected)
                : .observe(.disconnected, .disconnected)

        case .polled:
            guard isConnected else { return .none }
            if let rssi {
                lastSignal = now
                return .observe(.signal(rssi), nil)
            }
            return signalIsStale(at: now) ? .observe(.connectedWithoutSignal, nil) : .none
        }
    }

    private func signalIsStale(at now: Date) -> Bool {
        guard let lastSignal else { return true }
        return now.timeIntervalSince(lastSignal) > ProximityTiming.classicSignalTimeout
    }

    mutating func noteSignal(at now: Date) {
        lastSignal = now
    }

    /// Re-initialises on the next poll, which restarts the debounce clock.
    mutating func resetForScan() {
        link = .unpolled
        lastSignal = nil
    }
}

/// The window after Bluetooth powers on during which proximity is assumed, not observed.
enum RecoveryCooldown: Equatable {
    static let duration: TimeInterval = 15

    case inactive
    case started(Date)

    mutating func start(at now: Date) { self = .started(now) }

    func isActive(at now: Date) -> Bool {
        switch self {
        case .inactive: return false
        case .started(let startedAt): return now.timeIntervalSince(startedAt) < Self.duration
        }
    }
}
