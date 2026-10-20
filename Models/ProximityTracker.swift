// ProximityTracker.swift
// MacGuard - Anti-Theft Alarm for macOS
//
// Pure per-device proximity decisions. `BluetoothProximityManager` parses
// Bluetooth callbacks into `Observation`s, feeds them in with the current
// time and settings, and turns the results into logs and delegate calls.

import Foundation

/// One parsed reading of a trusted device.
enum Observation: Equatable {
    /// A real signal-strength reading
    case signal(RSSI)
    /// Connected, but the stack reports no RSSI. Treated as nearby.
    case connectedWithoutSignal
    /// Not connected / not reachable. Never nearby, whatever the thresholds.
    case disconnected

    /// Whether this observation is at least as strong as `threshold` (dBm).
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

/// Per-device proximity. `unobserved` (no reading since scanning started) is
/// distinct from `away`, but both mean "not nearby": nothing unobserved ever
/// vouches for the owner being present.
enum Proximity: Equatable {
    case unobserved, nearby, away
}

/// What one observation did to a device's proximity.
enum ProximityChange: Equatable {
    case becameNearby
    case becameAway
    /// Would have gone away, but BT is in its post-power-on recovery cooldown
    case awaySuppressedByCooldown
    /// Would have gone away, but a nearby-strength reading arrived `sinceNearby` seconds ago
    case awayDebounced(sinceNearby: TimeInterval)
    case unchanged
}

/// Debounce windows (seconds), longer in Low Power Mode where scans are sparser.
enum ProximityTiming {
    static func awayDebounce(lowPower: Bool) -> TimeInterval { lowPower ? 10 : 3 }
    static func disconnectDebounce(lowPower: Bool) -> TimeInterval { lowPower ? 15 : 5 }
    /// Connected Classic device with no valid RSSI for this long counts as `.connectedWithoutSignal`
    static let classicSignalTimeout: TimeInterval = 1
}

/// Hysteresis + debounce state for one trusted device.
struct ProximityTracker: Equatable {
    private(set) var proximity: Proximity = .unobserved
    private(set) var lastObservation: Observation?
    /// Last time the device was judged nearby (BLE disconnect debounce)
    private(set) var lastNearby: Date?
    /// Last time a reading met the away threshold (away debounce)
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

    /// Whether a BLE disconnect should be ignored as a blip (was nearby very recently).
    func shouldDebounceDisconnect(at now: Date, lowPower: Bool) -> Bool {
        now.timeIntervalSince(lastNearby ?? .distantPast) < ProximityTiming.disconnectDebounce(lowPower: lowPower)
    }

    /// CoreBluetooth reported a disconnect: mark away directly (no transition event).
    mutating func markDisconnected() {
        proximity = .away
    }

    /// After BT powers back on, assume previously observed devices are nearby
    /// so they do not flap "away" (and auto-arm) while connections recover.
    mutating func assumeNearbyForRecovery() {
        if proximity != .unobserved {
            proximity = .nearby
        }
    }

    /// Scanning restarted: forget the current reading, keep debounce history.
    mutating func resetForScan() {
        proximity = .unobserved
        lastObservation = nil
    }
}

/// IOBluetooth connection state machine for one Classic device.
struct ClassicLinkTracker: Equatable {
    /// Connection state at the last poll, `nil` before the first poll since scanning started
    private(set) var connected: Bool?
    private var lastStateChange: Date?
    private var lastValidSignal: Date?

    enum LinkEvent: Equatable {
        case initiallyConnected, initiallyDisconnected, connected, disconnected
    }

    enum PollResult: Equatable {
        /// Nothing to report this poll
        case none
        /// Disconnect within the debounce window of the last state change
        case disconnectDebounced
        /// Feed this observation to the device's `ProximityTracker`
        case observe(Observation, LinkEvent?)
    }

    mutating func poll(isConnected: Bool, rssi: RSSI?, at now: Date, lowPower: Bool) -> PollResult {
        let connectedObservation = rssi.map(Observation.signal) ?? .connectedWithoutSignal

        guard let wasConnected = connected else {
            connected = isConnected
            lastStateChange = now
            return isConnected
                ? .observe(connectedObservation, .initiallyConnected)
                : .observe(.disconnected, .initiallyDisconnected)
        }

        if isConnected != wasConnected {
            // AirPods and similar flap; ignore a disconnect right after a change
            let sinceChange = now.timeIntervalSince(lastStateChange ?? .distantPast)
            if !isConnected && sinceChange < ProximityTiming.disconnectDebounce(lowPower: lowPower) {
                return .disconnectDebounced
            }
            connected = isConnected
            lastStateChange = now
            return isConnected
                ? .observe(connectedObservation, .connected)
                : .observe(.disconnected, .disconnected)
        }

        guard isConnected else { return .none }
        if let rssi {
            lastValidSignal = now
            return .observe(.signal(rssi), nil)
        }
        if now.timeIntervalSince(lastValidSignal ?? .distantPast) > ProximityTiming.classicSignalTimeout {
            return .observe(.connectedWithoutSignal, nil)
        }
        return .none
    }

    /// An inquiry delivered a valid RSSI.
    mutating func noteSignal(at now: Date) {
        lastValidSignal = now
    }

    /// Scanning restarted: re-initialise on the next poll, keep the debounce clock.
    mutating func resetForScan() {
        connected = nil
        lastValidSignal = nil
    }
}

/// The window after Bluetooth powers on during which proximity is assumed, not observed.
struct RecoveryCooldown: Equatable {
    static let duration: TimeInterval = 15
    private(set) var startedAt: Date?

    mutating func start(at now: Date) { startedAt = now }

    func isActive(at now: Date) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) < Self.duration
    }

    /// Assumed proximity vouches for nobody: presence counts only outside the cooldown.
    func vouchesForPresence(_ nearby: Bool, at now: Date) -> Bool {
        nearby && !isActive(at: now)
    }
}
