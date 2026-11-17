// AlarmMachine.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation

/// Why the alarm was set off, parsed at the monitor boundary.
enum TriggerCause: Equatable {
    case input(IntrusionInput)
    case powerDisconnected
    case lidClosed
    case usbDeviceAttached(name: String)
    case networkChanged
    case motion
    case lidMoved(degrees: Int)
    case tamper

    var label: String {
        switch self {
        case .input(let input): return input.label
        case .powerDisconnected: return "power cable disconnected"
        case .lidClosed: return "lid closed"
        case .usbDeviceAttached(let name): return "USB device attached (\(name))"
        case .networkChanged: return "network changed"
        case .motion: return "Mac moved"
        case .lidMoved(let degrees): return "lid moved \(abs(degrees))°"
        case .tamper: return "MacGuard was terminated while armed"
        }
    }
}

/// Security-relevant facts for observers, so none has to interpret raw state.
enum AlarmEvent: Equatable {
    case armed(auto: Bool)
    case disarmed(reason: String)
    case countdownStarted(TriggerCause, seconds: Int)
    case alarmSounding(TriggerCause)
}

enum AlarmInput {
    case armRequested(auto: Bool)
    case armingDelayElapsed
    case inputMonitoringStarted(Bool)
    case cancelArming
    case authenticated(OwnerAuthentication)
    /// Starts the countdown, or sounds at once when there is none.
    case intrusion(TriggerCause)
    /// Sounds immediately, even mid-countdown.
    case severeIntrusion(TriggerCause)
    case countdownTick
    case trustedDeviceNearby(TrustedDevice)
    case trustedDeviceAway(TrustedDevice)
    case systemWoke
    case autoArmTimerFired
    case screenLocked
    case resumeAfterTamper(ArmSession)
    case settingsChanged
}

/// A trusted device positively observed (scanning, outside the BT recovery cooldown).
enum Sighting: Equatable {
    case nearby, away
}

enum BluetoothHealth: Equatable {
    case stable, unstable
}

/// Auto-arm when trusted devices leave. Its grace period needs stable Bluetooth.
enum AutoArm: Equatable {
    case off
    case onDeviceLeave(BluetoothHealth)
}

struct TrustedDeviceEvidence: Equatable {
    /// Unobserved devices are absent: not seen is neither here nor gone.
    var sightings: [TrustedDevice.ID: Sighting]
    var autoArm: AutoArm
}

/// With no trusted devices there are no sightings or auto-arm to consider.
enum ProximityEvidence: Equatable {
    case noTrustedDevices
    case trusted(TrustedDeviceEvidence)

    init(hasTrustedDevices: Bool, sightings: [TrustedDevice.ID: Sighting],
         autoArmEnabled: Bool, bluetoothStable: Bool) {
        guard hasTrustedDevices else {
            self = .noTrustedDevices
            return
        }
        self = .trusted(TrustedDeviceEvidence(
            sightings: sightings,
            autoArm: autoArmEnabled ? .onDeviceLeave(bluetoothStable ? .stable : .unstable) : .off
        ))
    }

    func seen(_ sighting: Sighting) -> Set<TrustedDevice.ID> {
        switch self {
        case .noTrustedDevices: return []
        case .trusted(let devices): return Set(devices.sightings.filter { $0.value == sighting }.keys)
        }
    }
}

/// Snapshot of parsed settings and proximity *evidence* the machine decides on.
struct AlarmEnvironment {
    /// The runtime's clock at this step.
    var now: Date
    var countdown: Countdown?
    var autoLockOnArm: Bool
    var proximity: ProximityEvidence
    var usbTriggerEnabled: Bool
    var networkTriggerEnabled: Bool
    var motionTriggerEnabled: Bool
    var lidAngleTriggerEnabled: Bool
    var autoArmOnScreenLock: Bool
    var exitDelay: ExitDelay
}

/// Side effects the shell performs, in order.
enum AlarmEffect: Equatable {
    case prepareAudio
    case lockScreen
    case closeConfigWindows
    case scheduleArmingDelay(ExitDelay)
    case startInputMonitoring
    case startSystemMonitors
    case stopMonitors
    case showOverlay
    case hideOverlay
    case playAlarm
    case stopAlarm
    case startCountdownTimer
    case stopCountdownTimer
    case startAutoArmTimer
    case cancelAutoArmTimer(reason: String?)
    case resumeIdleScanning
    case stopIdleScanning
    case log(ActivityLogCategory, String)
    case emit(AlarmEvent)
    /// Record that this session is armed, so a killed process is detectable.
    case persistArmedMarker(ArmSession)
    case clearArmedMarker
    /// Disarmed: drop wrong-PIN history and any open Touch ID prompt.
    case endOwnerChallenge
}

/// The alarm's decisions as a pure function: no timers, singletons or I/O.
enum AlarmMachine {
    typealias Transition = (state: AlarmState, effects: [AlarmEffect])

    static func step(_ state: AlarmState, _ input: AlarmInput, _ env: AlarmEnvironment) -> Transition {
        switch (state, input) {

        // MARK: Arming
        case (.idle, .armRequested(let auto)):
            var effects: [AlarmEffect] = [.closeConfigWindows, .prepareAudio]
            if env.autoLockOnArm { effects.append(.lockScreen) }
            effects.append(.scheduleArmingDelay(env.exitDelay))
            let until = env.now.addingTimeInterval(env.exitDelay.seconds)
            let session = ArmSession(departed: env.proximity.seen(.away))
            return (.arming(session, until: until, origin: auto ? .deviceLeft : .manual), effects)

        case (.arming, .armingDelayElapsed):
            return (state, [.startInputMonitoring])

        case (.arming(let session, _, let origin), .inputMonitoringStarted(true)):
            return (.armed(session), [
                .persistArmedMarker(session),
                .startSystemMonitors,
                .log(.armed, "System armed - monitoring active"),
                .emit(.armed(auto: origin == .deviceLeft)),
            ])

        case (.arming, .inputMonitoringStarted(false)):
            return standDown("Failed to arm - accessibility permission denied", env)

        case (.arming, .cancelArming):
            return standDown("Arming cancelled", env)

        // MARK: Disarming
        case (_, .authenticated(let proof)) where state != .idle:
            return standDown("Disarmed via \(proof.method.rawValue)", env)

        // MARK: Triggering
        case (.armed(let session), .intrusion(let cause)):
            guard isEnabled(cause, env) else {
                return (state, [.log(.system, "Ignored \(cause.label) - trigger disabled")])
            }
            guard let countdown = env.countdown else {
                return soundAlarm(session, cause, "Immediate alarm triggered (no countdown)", overlay: true)
            }
            return (.triggered(session, countdown, cause), [
                .showOverlay,
                .startCountdownTimer,
                .log(.trigger, "Countdown started (\(countdown.total)s) - \(cause.label)"),
                .emit(.countdownStarted(cause, seconds: countdown.total)),
            ])

        case (.armed(let session), .severeIntrusion(let cause)),
             (.triggered(let session, _, _), .severeIntrusion(let cause)):
            return soundAlarm(session, cause, "ALARM ACTIVE - \(cause.label)", overlay: true)

        case (.triggered(let session, let countdown, let cause), .countdownTick):
            guard let next = countdown.ticked() else {
                return soundAlarm(session, cause, "Countdown expired - ALARM ACTIVE", overlay: false)
            }
            return (.triggered(session, next, cause), [])

        // MARK: Proximity
        // The grace period runs while any device is still away.
        case (.idle, .trustedDeviceNearby(let device)):
            guard env.proximity.seen(.away).isEmpty else { return (state, []) }
            return (state, [.cancelAutoArmTimer(reason: "Auto-arm cancelled - '\(device.name)' back nearby")])

        case (_, .trustedDeviceNearby(let device)):
            guard state.session?.departed.contains(device.id) == true else {
                return (state, [.log(.bluetooth, "'\(device.name)' nearby but was here at arming - not disarming")])
            }
            return standDown("Disarmed via trusted device '\(device.name)'", env)

        case (.idle, .trustedDeviceAway(let device)):
            guard case .trusted(let devices) = env.proximity else { return (state, []) }
            return (state, autoArmGracePeriod("'\(device.name)' left - starting grace period", devices.autoArm))

        case (_, .trustedDeviceAway(let device)):
            var effects: [AlarmEffect] = [.log(.bluetooth, "Trusted device '\(device.name)' left proximity")]
            if state.session?.departed.contains(device.id) == false {
                effects.append(.log(.bluetooth, "'\(device.name)' may now disarm on return"))
            }
            return (state.updatingSession { $0.departed.insert(device.id) }, effects)

        case (_, .systemWoke):
            if let session = state.session, !session.departed.isDisjoint(with: env.proximity.seen(.nearby)) {
                return standDown("Disarmed on wake - trusted device back nearby", env)
            }
            return (state, [.log(.system, "System woke from sleep")])

        // The marker is rewritten so a second kill is caught too.
        case (.idle, .resumeAfterTamper(let session)):
            let (next, effects) = soundAlarm(session, .tamper, "Restarted after being terminated while armed - ALARM ACTIVE", overlay: true)
            return (next, [.persistArmedMarker(session), .startSystemMonitors] + effects)

        case (.idle, .autoArmTimerFired):
            let (next, effects) = step(.idle, .armRequested(auto: true), env)
            return (next, [.log(.armed, "Auto-arming - trusted device still away")] + effects)

        case (.idle, .screenLocked):
            guard env.autoArmOnScreenLock else { return (state, []) }
            // A manual arm: only devices already away (or leaving later) may disarm.
            let (next, effects) = step(.idle, .armRequested(auto: false), env)
            return (next, [.log(.armed, "Screen locked - arming")] + effects)

        case (.idle, .settingsChanged):
            return (state, [wantsIdleScanning(env.proximity) ? .resumeIdleScanning : .stopIdleScanning])

        // Anything else is a no-op here (e.g. a stale tick after disarm).
        default:
            return (state, [])
        }
    }

    // MARK: - Rules

    /// Core triggers are always on; optional ones have a setting.
    private static func isEnabled(_ cause: TriggerCause, _ env: AlarmEnvironment) -> Bool {
        switch cause {
        case .input, .powerDisconnected, .lidClosed, .tamper: return true
        case .usbDeviceAttached: return env.usbTriggerEnabled
        case .networkChanged: return env.networkTriggerEnabled
        case .motion: return env.motionTriggerEnabled
        case .lidMoved: return env.lidAngleTriggerEnabled
        }
    }

    private static func autoArmGracePeriod(_ message: String, _ autoArm: AutoArm) -> [AlarmEffect] {
        switch autoArm {
        case .off: return []
        case .onDeviceLeave(.unstable): return [.log(.bluetooth, "Auto-arm blocked - BT unstable or off")]
        case .onDeviceLeave(.stable): return [.log(.bluetooth, message), .startAutoArmTimer]
        }
    }

    private static func soundAlarm(_ session: ArmSession, _ cause: TriggerCause, _ message: String, overlay: Bool) -> Transition {
        let effects: [AlarmEffect] = (overlay ? [.showOverlay] : []) + [
            .stopCountdownTimer,
            .playAlarm,
            .log(.alarm, message),
            .emit(.alarmSounding(cause)),
        ]
        return (.alarming(session, cause), effects)
    }

    private static func standDown(_ reason: String, _ env: AlarmEnvironment) -> Transition {
        var effects: [AlarmEffect] = [
            .stopCountdownTimer,
            .cancelAutoArmTimer(reason: nil),
            .stopMonitors,
            .stopAlarm,
            .hideOverlay,
            .clearArmedMarker,
            // PIN attempts only accrue while triggered or alarming, which end
            // only with owner proof or a trusted device's return.
            .endOwnerChallenge,
            .log(.disarmed, reason),
            .emit(.disarmed(reason: reason)),
        ]
        if wantsIdleScanning(env.proximity) { effects.append(.resumeIdleScanning) }
        return (.idle, effects)
    }

    /// Idle scanning only when auto-arm needs it (keeps idle CPU low).
    private static func wantsIdleScanning(_ proximity: ProximityEvidence) -> Bool {
        guard case .trusted(let devices) = proximity else { return false }
        switch devices.autoArm {
        case .off: return false
        case .onDeviceLeave: return true
        }
    }
}
