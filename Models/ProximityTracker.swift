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

/// `unobserved` (no reading since scanning started) never vouches for presence.
enum Proximity: Equatable {
    case unobserved, nearby, away
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

    var isNearby: Bool { proximity == .nearby }

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
        proximity = nearby ? .nearby : .away
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

    mutating func markDisconnected() {
        proximity = .away
    }

    /// So devices don't flap "away" (and auto-arm) while connections recover after BT power-on.
    mutating func assumeNearbyForRecovery() {
        if proximity != .unobserved {
            proximity = .nearby
        }
    }

    /// Forgets the current reading, keeps debounce history.
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
