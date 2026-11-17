// AlarmMachineTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

final class AlarmMachineTests: XCTestCase {
    private let phoneLeft = ArmSession(departed: [TrustedDevice.phone.id])
    private let key = TriggerCause.input(.keyboard)

    private func arming(_ session: ArmSession, _ delay: ExitDelay = .s1, origin: ArmOrigin = .manual) -> AlarmState {
        .arming(session, until: AlarmEnvironment.t0.addingTimeInterval(delay.seconds), origin: origin)
    }

    private func update(_ s: AlarmState, _ i: AlarmMachine.Msg, _ e: AlarmEnvironment = .fixture(),
                      seen sightings: [TrustedDevice: Sighting] = [:]) -> (state: AlarmState, effects: [AlarmMachine.Effect]) {
        let (model, effects) = AlarmMachine.update(.fixture(s, presence: sightings.mapValues(Presence.seen)), i, e)
        return (model.alarm, effects)
    }

    // MARK: Arming

    func testArmEntersArmingSynchronously() {
        let (state, effects) = update(.idle, .armRequested(auto: false))
        XCTAssertEqual(state, arming(.noDepartures))
        XCTAssertEqual(effects, [.closeConfigWindows, .prepareAudio, .scheduleArmingDelay(.s1)])
        XCTAssertTrue(update(.idle, .armRequested(auto: false), .fixture(exitDelay: .s30)).effects
            .contains(.scheduleArmingDelay(.s30)))
    }

    func testArmingCarriesItsDeadline() {
        let now = AlarmEnvironment.t0.addingTimeInterval(100)
        XCTAssertEqual(update(.idle, .armRequested(auto: false), .fixture(now: now, exitDelay: .s30)).state,
                       .arming(.noDepartures, until: now.addingTimeInterval(30), origin: .manual))
    }

    func testArmLocksScreenOnlyWhenConfigured() {
        XCTAssertTrue(update(.idle, .armRequested(auto: false), .fixture(autoLock: true)).effects.contains(.lockScreen))
    }

    func testSecondArmRequestIsIgnored() {
        XCTAssertTrue(update(arming(.noDepartures), .armRequested(auto: false)).effects.isEmpty)
        XCTAssertTrue(update(.armed(.noDepartures), .armRequested(auto: false)).effects.isEmpty)
    }

    func testArmingCompletesWhenInputMonitoringStarts() {
        XCTAssertEqual(update(arming(.noDepartures), .armingDelayElapsed).effects, [.startInputMonitoring])
        let (state, effects) = update(arming(.noDepartures), .inputMonitoringStarted(true))
        XCTAssertEqual(state, .armed(.noDepartures))
        XCTAssertTrue(effects.contains(.emit(.armed(auto: false))))
        XCTAssertTrue(update(arming(phoneLeft, origin: .deviceLeft), .inputMonitoringStarted(true)).effects
            .contains(.emit(.armed(auto: true))))
    }

    func testDelayAfterCancelDoesNotArm() {
        let (cancelled, _) = update(arming(.noDepartures), .cancelArming)
        XCTAssertEqual(cancelled, .idle)
        XCTAssertEqual(update(cancelled, .armingDelayElapsed).state, .idle)
        XCTAssertEqual(update(cancelled, .inputMonitoringStarted(true)).state, .idle)
    }

    func testIntrusionsIgnoredUnlessArmed() {
        let inputs: [AlarmMachine.Msg] = [.intrusion(key), .severeIntrusion(.lidClosed),
                                    .intrusion(.usbDeviceAttached(name: "x")), .intrusion(.networkChanged)]
        for state: AlarmState in [.idle, arming(.noDepartures)] {
            for input in inputs {
                XCTAssertEqual(update(state, input, .fixture(network: true)).state, state, "\(state) + \(input)")
            }
        }
    }

    func testCancelArmingCannotDisarmAnArmedSystem() {
        XCTAssertEqual(update(.armed(.noDepartures), .cancelArming).state, .armed(.noDepartures))
    }

    // MARK: Triggering

    func testIntrusionStartsCountdown() throws {
        let (state, effects) = update(.armed(.noDepartures), .intrusion(key))
        XCTAssertEqual(state, .triggered(.noDepartures, try XCTUnwrap(Countdown(seconds: 3)), key))
        XCTAssertTrue(effects.contains(.showOverlay))
        XCTAssertTrue(effects.contains(.startCountdownTimer))
        XCTAssertTrue(effects.contains(.emit(.countdownStarted(key, seconds: 3))))
    }

    func testNoCountdownSoundsImmediately() {
        let (state, effects) = update(.armed(.noDepartures), .intrusion(.powerDisconnected), .fixture(countdown: 0))
        XCTAssertEqual(state, .alarming(.noDepartures, .powerDisconnected))
        XCTAssertTrue(effects.contains(.playAlarm))
    }

    func testCountdownTicksThenSoundsWithOriginalCause() throws {
        var state = AlarmState.triggered(.noDepartures, try XCTUnwrap(Countdown(seconds: 2)), key)
        state = update(state, .countdownTick).state
        guard case .triggered(_, let countdown, _) = state else { return XCTFail("still counting down") }
        XCTAssertEqual(countdown.remaining, 1)

        let (final, effects) = update(state, .countdownTick)
        XCTAssertEqual(final, .alarming(.noDepartures, key))
        XCTAssertTrue(effects.contains(.emit(.alarmSounding(key))))
        XCTAssertFalse(effects.contains(.showOverlay), "overlay is already up")
    }

    func testStaleTickAfterDisarmIsNoOp() {
        XCTAssertEqual(update(.idle, .countdownTick).state, .idle)
        XCTAssertTrue(update(.idle, .countdownTick).effects.isEmpty)
    }

    func testSevereIntrusionEscalatesMidCountdown() throws {
        let triggered = AlarmState.triggered(.noDepartures, try XCTUnwrap(Countdown(seconds: 10)), key)
        XCTAssertEqual(update(triggered, .severeIntrusion(.lidClosed)).state, .alarming(.noDepartures, .lidClosed))
        XCTAssertEqual(update(.armed(.noDepartures), .severeIntrusion(.lidClosed)).state, .alarming(.noDepartures, .lidClosed))
    }

    /// A phone left on the desk must not silence the alarm.
    func testNearbyDeviceDoesNotSuppressIntrusions() {
        let phoneHere: [TrustedDevice: Sighting] = [.phone: .nearby]
        XCTAssertEqual(update(.armed(.noDepartures), .intrusion(key), seen: phoneHere).state.phase, .triggered)
        XCTAssertEqual(update(.armed(.noDepartures), .severeIntrusion(.lidClosed), seen: phoneHere).state.phase, .alarming)
    }

    // MARK: Proximity disarm

    func testArmRecordsOnlyDevicesSeenAway() {
        XCTAssertEqual(update(.idle, .armRequested(auto: false), seen: [.phone: .away, .watch: .nearby]).state, arming(phoneLeft))
        XCTAssertEqual(update(.idle, .armRequested(auto: false), .fixture()).state, arming(.noDepartures),
                       "unobserved devices have not been seen away")
    }

    func testDeviceHereAtArmingDoesNotDisarm() {
        let (state, effects) = update(.armed(.noDepartures), .proximity(.seen(.phone, .nearby)))
        XCTAssertEqual(state, .armed(.noDepartures))
        XCTAssertTrue(effects.contains(.log(.bluetooth, "'Phone' nearby but was here at arming - not disarming")))
    }

    func testDeviceThatLeftThenReturnedDisarms() {
        let away = update(.armed(.noDepartures), .proximity(.seen(.phone, .away))).state
        XCTAssertEqual(away, .armed(phoneLeft))
        XCTAssertEqual(update(away, .proximity(.seen(.phone, .nearby))).state, .idle)
    }

    func testOnlyADepartedDeviceDisarms() {
        XCTAssertEqual(update(.armed(phoneLeft), .proximity(.seen(.watch, .nearby))).state, .armed(phoneLeft))
        XCTAssertEqual(update(.armed(phoneLeft), .proximity(.seen(.phone, .nearby))).state, .idle)
    }

    func testReturnDisarmsDuringAlarmAndArmingToo() {
        XCTAssertEqual(update(.alarming(phoneLeft, key), .proximity(.seen(.phone, .nearby))).state, .idle)
        XCTAssertEqual(update(arming(phoneLeft, origin: .deviceLeft), .proximity(.seen(.phone, .nearby))).state, .idle)
    }

    func testWakeDisarmsOnlyWithADepartedDeviceNearby() {
        XCTAssertEqual(update(.armed(.noDepartures), .systemWoke, seen: [.phone: .nearby]).state, .armed(.noDepartures))
        XCTAssertEqual(update(.armed(phoneLeft), .systemWoke, seen: [.watch: .nearby]).state, .armed(phoneLeft))
        XCTAssertEqual(update(.armed(phoneLeft), .systemWoke, seen: [.phone: .nearby]).state, .idle)
    }

    // MARK: Auto-arm

    func testDepartureStartsGracePeriodOnlyWhenEnabledAndStable() {
        let left = AlarmMachine.Msg.proximity(.seen(.phone, .away))
        XCTAssertTrue(update(.idle, left, .fixture(autoArm: .onDeviceLeave(.stable)), seen: [.phone: .nearby]).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(update(.idle, left, .fixture(), seen: [.phone: .nearby]).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(update(.idle, left, .fixture(autoArm: .onDeviceLeave(.unstable)), seen: [.phone: .nearby]).effects.contains(.startAutoArmTimer))
    }

    /// Only leaving starts the grace period: from seen or assumed nearby, not a first sighting.
    func testOnlyLeavingStartsGracePeriod() {
        let autoArm = AlarmEnvironment.fixture(autoArm: .onDeviceLeave(.stable))
        let left = AlarmMachine.Msg.proximity(.seen(.phone, .away))
        func grace(from presence: [TrustedDevice: Presence]) -> Bool {
            AlarmMachine.update(.fixture(.idle, presence: presence), left, autoArm).1.contains(.startAutoArmTimer)
        }
        XCTAssertTrue(grace(from: [.phone: .seen(.nearby)]), "nearby -> away")
        XCTAssertTrue(grace(from: [.phone: .assumedNearby]), "assumed after BT recovery -> away")
        XCTAssertFalse(grace(from: [:]), "first sighting of away")
        XCTAssertFalse(grace(from: [.watch: .seen(.nearby)]), "another device's presence does not count")
    }

    /// A Classic device left disconnected (AirPods in the case) must not re-arm after every disarm.
    func testDisarmThenScanRestartWithDisconnectedDeviceDoesNotRearm() {
        let autoArm = AlarmEnvironment.fixture(autoArm: .onDeviceLeave(.stable))
        let msgs: [AlarmMachine.Msg] = [
            .cancelArming,                       // any stand-down; PIN proof can't be built here
            .proximity(.lost(.phone)),           // scan stopped on stand-down
            .proximity(.seen(.phone, .away)),    // first poll after the scan restarts
        ]
        var model = AlarmMachine.Model.fixture(arming(phoneLeft), presence: [.phone: .seen(.away)])
        var effects: [AlarmMachine.Effect] = []
        for msg in msgs {
            (model, effects) = AlarmMachine.update(model, msg, autoArm)
        }
        XCTAssertEqual(model.alarm, .idle)
        XCTAssertFalse(effects.contains(.startAutoArmTimer))
    }

    func testAssumedNearbyIsNotEvidence() {
        let assumed = AlarmMachine.update(.fixture(.armed(phoneLeft), presence: [.phone: .seen(.away)]), .proximity(.assumedNearby(.phone)), .fixture()).0
        XCTAssertEqual(assumed.alarm, .armed(phoneLeft), "an assumption is not a return")
        XCTAssertEqual(AlarmMachine.update(assumed, .systemWoke, .fixture()).0.alarm, .armed(phoneLeft))
        let idle = AlarmMachine.update(.fixture(.idle, presence: [.phone: .assumedNearby]), .armRequested(auto: false), .fixture()).0
        XCTAssertEqual(idle.alarm, arming(.noDepartures), "an assumption is not seen away either")
    }

    func testReturnCancelsGracePeriodOnlyWhenNoDeviceIsStillAway() {
        XCTAssertEqual(update(.idle, .proximity(.seen(.phone, .nearby))).effects,
                       [.cancelAutoArmTimer(reason: "Auto-arm cancelled - 'Phone' back nearby")])
        XCTAssertEqual(update(.idle, .proximity(.seen(.phone, .nearby)), seen: [.watch: .away]).effects, [])
    }

    func testLosingSightIsNeitherReturnNorDeparture() {
        let autoArm = AlarmEnvironment.fixture(autoArm: .onDeviceLeave(.stable))
        XCTAssertEqual(update(.idle, .proximity(.lost(.phone)), autoArm).effects, [])
        XCTAssertEqual(update(.armed(phoneLeft), .proximity(.lost(.phone))).state, .armed(phoneLeft))
        XCTAssertEqual(update(.armed(.noDepartures), .proximity(.lost(.phone))).state, .armed(.noDepartures))
    }

    func testAutoArmTimerArmsWithTheDevicesThatLeft() {
        let seen: [TrustedDevice: Sighting] = [.phone: .away, .watch: .nearby]
        XCTAssertEqual(update(.idle, .autoArmTimerFired, seen: seen).state, arming(phoneLeft, origin: .deviceLeft))
        XCTAssertEqual(update(.armed(.noDepartures), .autoArmTimerFired, seen: seen).state, .armed(.noDepartures))
    }

    // MARK: Stand down

    func testStandDownResumesIdleScanningOnlyWhenAutoArmConfigured() {
        XCTAssertTrue(update(arming(.noDepartures), .cancelArming, .fixture(autoArm: .onDeviceLeave(.stable))).effects.contains(.resumeIdleScanning))
        XCTAssertFalse(update(arming(.noDepartures), .cancelArming, .fixture()).effects.contains(.resumeIdleScanning))
    }

    func testSettingsChangeAppliesTheIdleScanningRule() {
        XCTAssertEqual(update(.idle, .settingsChanged, .fixture(autoArm: .onDeviceLeave(.stable))).effects, [.resumeIdleScanning])
        XCTAssertEqual(update(.idle, .settingsChanged, .fixture()).effects, [.stopIdleScanning])
    }

    func testSettingsChangeLeavesActiveScanningAlone() {
        for state: AlarmState in [arming(.noDepartures), .armed(.noDepartures)] {
            XCTAssertEqual(update(state, .settingsChanged, .fixture()).effects, [], "\(state)")
        }
    }

    // MARK: Optional triggers

    func testUSBAttachIntrudesOnlyWhenEnabled() throws {
        let usb = TriggerCause.usbDeviceAttached(name: "Flash Drive")
        XCTAssertEqual(update(.armed(.noDepartures), .intrusion(usb), .fixture(usb: true)).state,
                       .triggered(.noDepartures, try XCTUnwrap(Countdown(seconds: 3)), usb))
        XCTAssertEqual(update(.armed(.noDepartures), .intrusion(usb), .fixture(usb: false)).state, .armed(.noDepartures))
    }

    func testNetworkChangeIntrudesOnlyWhenEnabled() {
        XCTAssertEqual(update(.armed(.noDepartures), .intrusion(.networkChanged), .fixture(network: false)).state, .armed(.noDepartures))
        XCTAssertEqual(update(.armed(.noDepartures), .intrusion(.networkChanged), .fixture(network: true)).state.phase, .triggered)
    }

    func testMotionAndLidIntrudeOnlyWhenEnabled() {
        for cause: TriggerCause in [.motion, .lidMoved(degrees: -6)] {
            XCTAssertEqual(update(.armed(.noDepartures), .intrusion(cause), .fixture()).state.phase, .triggered, "\(cause)")
        }
        XCTAssertEqual(update(.armed(.noDepartures), .intrusion(.motion), .fixture(motion: false)).state, .armed(.noDepartures))
        XCTAssertEqual(update(.armed(.noDepartures), .intrusion(.lidMoved(degrees: 9)), .fixture(lidAngle: false)).state, .armed(.noDepartures))
    }

    func testCoreTriggersCannotBeDisabledBySensorSettings() {
        let off = AlarmEnvironment.fixture(usb: false, network: false, motion: false, lidAngle: false)
        XCTAssertEqual(update(.armed(.noDepartures), .intrusion(key), off).state.phase, .triggered)
        XCTAssertEqual(update(.armed(.noDepartures), .intrusion(.powerDisconnected), off).state.phase, .triggered)
    }

    // MARK: Screen lock

    func testScreenLockArmsOnlyWhenEnabledAndIdle() {
        XCTAssertEqual(update(.idle, .screenLocked, .fixture(lockArms: true)).state, arming(.noDepartures))
        XCTAssertEqual(update(.idle, .screenLocked, .fixture(lockArms: false)).state, .idle)
        XCTAssertEqual(update(.armed(phoneLeft), .screenLocked, .fixture(lockArms: true)).state, .armed(phoneLeft))
    }

    // MARK: Parsing auto-arm

    func testAutoArmParsesSettingsAndBluetooth() {
        XCTAssertEqual(AutoArm(enabled: true, hasTrustedDevices: false, bluetoothStable: true), .off,
                       "no trusted device can leave")
        XCTAssertEqual(AutoArm(enabled: false, hasTrustedDevices: true, bluetoothStable: true), .off)
        XCTAssertEqual(AutoArm(enabled: true, hasTrustedDevices: true, bluetoothStable: true), .onDeviceLeave(.stable))
        XCTAssertEqual(AutoArm(enabled: true, hasTrustedDevices: true, bluetoothStable: false), .onDeviceLeave(.unstable))
        XCTAssertEqual(AutoArm(enabled: false, hasTrustedDevices: true, bluetoothStable: false), .off,
                       "stability only matters to auto-arm")
    }

    // MARK: Sightings

    func testModelKeepsSightingsFromProximityInputs() {
        let inputs: [AlarmMachine.Msg] = [.proximity(.seen(.phone, .away)), .proximity(.seen(.watch, .nearby)),
                                    .proximity(.seen(.phone, .nearby)), .proximity(.lost(.watch))]
        let model = inputs.reduce(AlarmMachine.Model.initial) { AlarmMachine.update($0, $1, .fixture()).0 }
        XCTAssertEqual(model, .fixture(.idle, presence: [.phone: .seen(.nearby)]))
        XCTAssertEqual(AlarmMachine.update(model, .settingsChanged, .fixture()).0.presence, model.presence,
                       "only proximity messages change presence")
    }

    /// Recovery assumption or a stopped scan: lost sight is no longer evidence.
    func testLostSightingIsNotEvidenceAtArmingOrWake() {
        let lost = AlarmMachine.update(.fixture(.idle, presence: [.phone: .seen(.away)]), .proximity(.lost(.phone)), .fixture()).0
        XCTAssertEqual(AlarmMachine.update(lost, .armRequested(auto: false), .fixture()).0.alarm, arming(.noDepartures))

        let lostNearby = AlarmMachine.update(.fixture(.armed(phoneLeft), presence: [.phone: .seen(.nearby)]), .proximity(.lost(.phone)), .fixture()).0
        XCTAssertEqual(AlarmMachine.update(lostNearby, .systemWoke, .fixture()).0.alarm, .armed(phoneLeft))
    }
}
