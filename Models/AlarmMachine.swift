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
    case allTrustedDevicesAway
    case systemWoke
    case autoArmTimerFired
    case screenLocked
    case resumeAfterTamper(ArmSession)
    case settingsChanged
}

/// How many trusted devices are positively observed nearby.
enum Presence: Equatable {
    case none, some, all

    /// Both facts are positive evidence only (scanning, outside the BT recovery
    /// cooldown), so "all" without "any" is a stale reading and vouches for nobody.
    init(anyNearby: Bool, allNearby: Bool) {
        switch (anyNearby, allNearby) {
        case (false, _): self = .none
        case (true, false): self = .some
        case (true, true): self = .all
        }
    }
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
    /// Applies with auto-arm off too: it decides which presence suppresses and disarms.
    var mode: AutoArmMode
    var presence: Presence
    var autoArm: AutoArm
}

/// With no trusted devices there is no presence, mode or auto-arm to consider.
enum ProximityEvidence: Equatable {
    case noTrustedDevices
    case trusted(TrustedDeviceEvidence)

    init(hasTrustedDevices: Bool, mode: AutoArmMode, autoArmEnabled: Bool,
         anyNearby: Bool, allNearby: Bool, bluetoothStable: Bool) {
        guard hasTrustedDevices else {
            self = .noTrustedDevices
            return
        }
        self = .trusted(TrustedDeviceEvidence(
            mode: mode,
            presence: Presence(anyNearby: anyNearby, allNearby: allNearby),
            autoArm: autoArmEnabled ? .onDeviceLeave(bluetoothStable ? .stable : .unstable) : .off
        ))
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
            return (.arming(ArmSession(trustedDeviceHasLeft: auto), until: until), effects)

        case (.arming, .armingDelayElapsed):
            return (state, [.startInputMonitoring])

        case (.arming(let session, _), .inputMonitoringStarted(true)):
            return (.armed(session), [
                .persistArmedMarker(session),
                .startSystemMonitors,
                .log(.armed, "System armed - monitoring active"),
                .emit(.armed(auto: session.trustedDeviceHasLeft)),
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
            if let suppressed = suppression(env.proximity) { return (state, [suppressed]) }
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
            if let suppressed = suppression(env.proximity) { return (state, [suppressed]) }
            return soundAlarm(session, cause, "ALARM ACTIVE - \(cause.label)", overlay: true)

        case (.triggered(let session, let countdown, let cause), .countdownTick):
            guard let next = countdown.ticked() else {
                return soundAlarm(session, cause, "Countdown expired - ALARM ACTIVE", overlay: false)
            }
            return (.triggered(session, next, cause), [])

        // MARK: ProximityEvidence
        case (_, .trustedDeviceNearby(let device)):
            let name = device.name
            let cancel = AlarmEffect.cancelAutoArmTimer(reason: "Auto-arm cancelled - '\(name)' detected nearby")
            guard let session = state.session else { return (state, [cancel]) }
            if proximityMayDisarm(state, env) {
                let (next, effects) = standDown("Disarmed via trusted device '\(name)'", env)
                return (next, [cancel] + effects)
            }
            guard !session.trustedDeviceHasLeft else { return (state, [cancel]) }
            return (state, [cancel, .log(.bluetooth, "Device '\(name)' nearby but manual arm - not auto-disarming")])

        case (_, .trustedDeviceAway(let device)):
            var effects: [AlarmEffect] = [.log(.bluetooth, "Trusted device '\(device.name)' left proximity")]
            var next = state
            if state.session?.trustedDeviceHasLeft == false {
                next = state.updatingSession { $0.trustedDeviceHasLeft = true }
                effects.append(.log(.bluetooth, "Device left while armed - enabling auto-disarm on return"))
            }
            if next == .idle, case .trusted(let devices) = env.proximity, devices.mode == .anyDeviceAway {
                effects += autoArmGracePeriod("Any device away mode - starting grace period", devices.autoArm)
            }
            return (next, effects)

        case (.idle, .allTrustedDevicesAway):
            guard case .trusted(let devices) = env.proximity, devices.mode == .allDevicesAway else { return (state, []) }
            return (state, autoArmGracePeriod("All trusted devices away - starting grace period", devices.autoArm))

        case (_, .systemWoke):
            if proximityMayDisarm(state, env) {
                return standDown("Disarmed on wake - trusted device nearby", env)
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
            // Manual-arm rules: a device must leave before its return may disarm.
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

    /// A nearby trusted device swallows intrusions, except in "any device away" mode.
    private static func suppression(_ proximity: ProximityEvidence) -> AlarmEffect? {
        guard case .trusted(let devices) = proximity else { return nil }
        switch (devices.mode, devices.presence) {
        case (.allDevicesAway, .some), (.allDevicesAway, .all):
            return .log(.bluetooth, "Trusted device nearby - ignoring trigger")
        case (.allDevicesAway, .none), (.anyDeviceAway, _):
            return nil
        }
    }

    /// Every proximity disarm (return, wake): only once a device has left this session.
    static func proximityMayDisarm(_ state: AlarmState, _ env: AlarmEnvironment) -> Bool {
        guard let session = state.session, state.phase != .arming,
              session.trustedDeviceHasLeft,
              case .trusted(let devices) = env.proximity else { return false }
        switch (devices.mode, devices.presence) {
        case (_, .all), (.allDevicesAway, .some): return true
        case (_, .none), (.anyDeviceAway, .some): return false
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
