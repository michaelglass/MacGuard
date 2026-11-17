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

extension AlarmMachine {
    enum Msg {
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
        case proximity(PresenceChange)
        case systemWoke
        case autoArmTimerFired
        case screenLocked
        case resumeAfterTamper(ArmSession)
        case settingsChanged
    }
}

enum BluetoothHealth: Equatable {
    case stable, unstable
}

/// Auto-arm when trusted devices leave. Its grace period needs stable Bluetooth.
enum AutoArm: Equatable {
    case off
    case onDeviceLeave(BluetoothHealth)

    /// Off without trusted devices too: none can leave.
    init(enabled: Bool, hasTrustedDevices: Bool, bluetoothStable: Bool) {
        guard enabled, hasTrustedDevices else {
            self = .off
            return
        }
        self = .onDeviceLeave(bluetoothStable ? .stable : .unstable)
    }
}

/// Snapshot of parsed settings the machine decides on.
struct AlarmEnvironment {
    /// The runtime's clock at this update.
    var now: Date
    var countdown: Countdown?
    var autoLockOnArm: Bool
    var autoArm: AutoArm
    var usbTriggerEnabled: Bool
    var networkTriggerEnabled: Bool
    var motionTriggerEnabled: Bool
    var lidAngleTriggerEnabled: Bool
    var autoArmOnScreenLock: Bool
    var exitDelay: ExitDelay
}

extension AlarmMachine {
    /// Side effects the shell performs, in order.
    enum Effect: Equatable {
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
}

/// The alarm's decisions as a pure function: no timers, singletons or I/O.
enum AlarmMachine {
    struct Model: Equatable {
        var alarm: AlarmState
        /// Kept from `.proximity` messages. Only `.seen` is evidence; unobserved
        /// devices are absent: not seen is neither here nor gone.
        var presence: [TrustedDevice.ID: Presence]

        static let initial = Model(alarm: .idle, presence: [:])
    }

    static func update(_ model: Model, _ msg: Msg, _ env: AlarmEnvironment) -> (Model, [Effect]) {
        var presence = model.presence
        if case .proximity(let change) = msg {
            change.apply(to: &presence, by: \.id)
        }
        let (alarm, effects) = decide(model.alarm, msg, before: model.presence, after: presence, env)
        return (Model(alarm: alarm, presence: presence), effects)
    }

    /// `after` includes this message's change; `before` is only for telling a
    /// departure (leaving from nearby) from a first sighting of away.
    private static func decide(
        _ state: AlarmState,
        _ msg: Msg,
        before: [TrustedDevice.ID: Presence],
        after: [TrustedDevice.ID: Presence],
        _ env: AlarmEnvironment
    ) -> (AlarmState, [Effect]) {
        func seen(_ sighting: Sighting) -> Set<TrustedDevice.ID> {
            Set(after.filter { $0.value == .seen(sighting) }.keys)
        }

        // Message first, then state, with every pairing spelled out: a new state or
        // message does not compile until each of its combinations is decided.
        switch msg {

        // MARK: Arming
        case .armRequested(let auto):
            switch state {
            case .idle:
                var effects: [Effect] = [.closeConfigWindows, .prepareAudio]
                if env.autoLockOnArm { effects.append(.lockScreen) }
                effects.append(.scheduleArmingDelay(env.exitDelay))
                let until = env.now.addingTimeInterval(env.exitDelay.seconds)
                let session = ArmSession(departed: seen(.away))
                return (.arming(session, until: until, origin: auto ? .deviceLeft : .manual), effects)
            case .arming, .armed, .triggered, .alarming:
                return (state, [])
            }

        case .armingDelayElapsed:
            switch state {
            case .arming:
                return (state, [.startInputMonitoring])
            case .idle, .armed, .triggered, .alarming:  // a delay outliving its session
                return (state, [])
            }

        case .inputMonitoringStarted(let granted):
            switch state {
            case .arming(let session, _, let origin):
                guard granted else { return standDown("Failed to arm - accessibility permission denied", env) }
                return (
                    .armed(session),
                    [
                        .persistArmedMarker(session),
                        .startSystemMonitors,
                        .log(.armed, "System armed - monitoring active"),
                        .emit(.armed(auto: origin == .deviceLeft)),
                    ]
                )
            case .idle, .armed, .triggered, .alarming:
                return (state, [])
            }

        case .cancelArming:
            switch state {
            case .arming:
                return standDown("Arming cancelled", env)
            case .idle, .armed, .triggered, .alarming:  // once armed, only the owner disarms
                return (state, [])
            }

        // MARK: Disarming
        case .authenticated(let proof):
            switch state {
            case .arming, .armed, .triggered, .alarming:
                return standDown("Disarmed via \(proof.method.rawValue)", env)
            case .idle:
                return (state, [])
            }

        // MARK: Triggering
        case .intrusion(let cause):
            switch state {
            case .armed(let session):
                guard isEnabled(cause, env) else {
                    return (state, [.log(.system, "Ignored \(cause.label) - trigger disabled")])
                }
                guard let countdown = env.countdown else {
                    return soundAlarm(session, cause, "Immediate alarm triggered (no countdown)", overlay: true)
                }
                return (
                    .triggered(session, countdown, cause),
                    [
                        .showOverlay,
                        .startCountdownTimer,
                        .log(.trigger, "Countdown started (\(countdown.total)s) - \(cause.label)"),
                        .emit(.countdownStarted(cause, seconds: countdown.total)),
                    ]
                )
            case .idle, .arming, .triggered, .alarming:  // not monitoring, or already raised
                return (state, [])
            }

        case .severeIntrusion(let cause):
            switch state {
            case .armed(let session), .triggered(let session, _, _):
                return soundAlarm(session, cause, "ALARM ACTIVE - \(cause.label)", overlay: true)
            case .idle, .arming, .alarming:
                return (state, [])
            }

        case .countdownTick:
            switch state {
            case .triggered(let session, let countdown, let cause):
                guard let next = countdown.ticked() else {
                    return soundAlarm(session, cause, "Countdown expired - ALARM ACTIVE", overlay: false)
                }
                return (.triggered(session, next, cause), [])
            case .idle, .arming, .armed, .alarming:  // a tick outliving its countdown
                return (state, [])
            }

        // MARK: Proximity
        case .proximity(.seen(let device, .nearby)):
            switch state {
            // The grace period runs while any device is still away.
            case .idle:
                guard seen(.away).isEmpty else { return (state, []) }
                return (state, [.cancelAutoArmTimer(reason: "Auto-arm cancelled - '\(device.name)' back nearby")])
            case .arming(let session, _, _), .armed(let session), .triggered(let session, _, _),
                .alarming(let session, _):
                guard session.departed.contains(device.id) else {
                    return (state, [.log(.bluetooth, "'\(device.name)' nearby but was here at arming - not disarming")])
                }
                return standDown("Disarmed via trusted device '\(device.name)'", env)
            }

        case .proximity(.seen(let device, .away)):
            switch state {
            // Only leaving starts the grace period: a device first seen away was never here.
            case .idle:
                guard before[device.id]?.holdsNearby == true else {
                    return (
                        state, [.log(.bluetooth, "'\(device.name)' seen away but was not nearby - no grace period")]
                    )
                }
                return (state, autoArmGracePeriod("'\(device.name)' left - starting grace period", env.autoArm))
            // A first sighting of away counts too: the device is missing from this session.
            case .arming(let session, _, _), .armed(let session), .triggered(let session, _, _),
                .alarming(let session, _):
                var effects: [Effect] = [.log(.bluetooth, "Trusted device '\(device.name)' left proximity")]
                if !session.departed.contains(device.id) {
                    effects.append(.log(.bluetooth, "'\(device.name)' may now disarm on return"))
                }
                return (state.updatingSession { $0.departed.insert(device.id) }, effects)
            }

        // An assumption or no longer seen is neither a return nor a departure.
        case .proximity(.assumedNearby), .proximity(.lost):
            return (state, [])

        case .systemWoke:
            switch state {
            case .arming(let session, _, _), .armed(let session), .triggered(let session, _, _),
                .alarming(let session, _):
                if !session.departed.isDisjoint(with: seen(.nearby)) {
                    return standDown("Disarmed on wake - trusted device back nearby", env)
                }
                return (state, [.log(.system, "System woke from sleep")])
            case .idle:
                return (state, [.log(.system, "System woke from sleep")])
            }

        // MARK: Idle-only
        case .resumeAfterTamper(let session):
            switch state {
            // The marker is rewritten so a second kill is caught too.
            case .idle:
                let (next, effects) = soundAlarm(
                    session, .tamper, "Restarted after being terminated while armed - ALARM ACTIVE", overlay: true)
                return (next, [.persistArmedMarker(session), .startSystemMonitors] + effects)
            case .arming, .armed, .triggered, .alarming:
                return (state, [])
            }

        case .autoArmTimerFired:
            switch state {
            case .idle:
                let (next, effects) = decide(.idle, .armRequested(auto: true), before: before, after: after, env)
                return (next, [.log(.armed, "Auto-arming - trusted device still away")] + effects)
            case .arming, .armed, .triggered, .alarming:
                return (state, [])
            }

        case .screenLocked:
            switch state {
            case .idle:
                guard env.autoArmOnScreenLock else { return (state, []) }
                // A manual arm: only devices already away (or leaving later) may disarm.
                let (next, effects) = decide(.idle, .armRequested(auto: false), before: before, after: after, env)
                return (next, [.log(.armed, "Screen locked - arming")] + effects)
            case .arming, .armed, .triggered, .alarming:
                return (state, [])
            }

        case .settingsChanged:
            switch state {
            case .idle:
                return (state, [wantsIdleScanning(env.autoArm) ? .resumeIdleScanning : .stopIdleScanning])
            case .arming, .armed, .triggered, .alarming:  // scanning is already on while armed
                return (state, [])
            }
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

    private static func autoArmGracePeriod(_ message: String, _ autoArm: AutoArm) -> [Effect] {
        switch autoArm {
        case .off: return []
        case .onDeviceLeave(.unstable): return [.log(.bluetooth, "Auto-arm blocked - BT unstable or off")]
        case .onDeviceLeave(.stable): return [.log(.bluetooth, message), .startAutoArmTimer]
        }
    }

    private static func soundAlarm(_ session: ArmSession, _ cause: TriggerCause, _ message: String, overlay: Bool) -> (
        AlarmState, [Effect]
    ) {
        let effects: [Effect] =
            (overlay ? [.showOverlay] : []) + [
                .stopCountdownTimer,
                .playAlarm,
                .log(.alarm, message),
                .emit(.alarmSounding(cause)),
            ]
        return (.alarming(session, cause), effects)
    }

    private static func standDown(_ reason: String, _ env: AlarmEnvironment) -> (AlarmState, [Effect]) {
        var effects: [Effect] = [
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
        if wantsIdleScanning(env.autoArm) { effects.append(.resumeIdleScanning) }
        return (.idle, effects)
    }

    /// Idle scanning only when auto-arm needs it (keeps idle CPU low).
    private static func wantsIdleScanning(_ autoArm: AutoArm) -> Bool {
        switch autoArm {
        case .off: return false
        case .onDeviceLeave: return true
        }
    }
}
