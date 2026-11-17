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

    private func step(_ s: AlarmState, _ i: AlarmInput, _ e: AlarmEnvironment = .fixture()) -> AlarmMachine.Transition {
        AlarmMachine.step(s, i, e)
    }

    // MARK: Arming

    func testArmEntersArmingSynchronously() {
        let (state, effects) = step(.idle, .armRequested(auto: false))
        XCTAssertEqual(state, arming(.noDepartures))
        XCTAssertEqual(effects, [.closeConfigWindows, .prepareAudio, .scheduleArmingDelay(.s1)])
        XCTAssertTrue(step(.idle, .armRequested(auto: false), .fixture(exitDelay: .s30)).effects
            .contains(.scheduleArmingDelay(.s30)))
    }

    func testArmingCarriesItsDeadline() {
        let now = AlarmEnvironment.t0.addingTimeInterval(100)
        XCTAssertEqual(step(.idle, .armRequested(auto: false), .fixture(now: now, exitDelay: .s30)).state,
                       .arming(.noDepartures, until: now.addingTimeInterval(30), origin: .manual))
    }

    func testArmLocksScreenOnlyWhenConfigured() {
        XCTAssertTrue(step(.idle, .armRequested(auto: false), .fixture(autoLock: true)).effects.contains(.lockScreen))
    }

    func testSecondArmRequestIsIgnored() {
        XCTAssertTrue(step(arming(.noDepartures), .armRequested(auto: false)).effects.isEmpty)
        XCTAssertTrue(step(.armed(.noDepartures), .armRequested(auto: false)).effects.isEmpty)
    }

    func testArmingCompletesWhenInputMonitoringStarts() {
        XCTAssertEqual(step(arming(.noDepartures), .armingDelayElapsed).effects, [.startInputMonitoring])
        let (state, effects) = step(arming(.noDepartures), .inputMonitoringStarted(true))
        XCTAssertEqual(state, .armed(.noDepartures))
        XCTAssertTrue(effects.contains(.emit(.armed(auto: false))))
        XCTAssertTrue(step(arming(phoneLeft, origin: .deviceLeft), .inputMonitoringStarted(true)).effects
            .contains(.emit(.armed(auto: true))))
    }

    func testDelayAfterCancelDoesNotArm() {
        let (cancelled, _) = step(arming(.noDepartures), .cancelArming)
        XCTAssertEqual(cancelled, .idle)
        XCTAssertEqual(step(cancelled, .armingDelayElapsed).state, .idle)
        XCTAssertEqual(step(cancelled, .inputMonitoringStarted(true)).state, .idle)
    }

    func testIntrusionsIgnoredUnlessArmed() {
        let inputs: [AlarmInput] = [.intrusion(key), .severeIntrusion(.lidClosed),
                                    .intrusion(.usbDeviceAttached(name: "x")), .intrusion(.networkChanged)]
        for state: AlarmState in [.idle, arming(.noDepartures)] {
            for input in inputs {
                XCTAssertEqual(step(state, input, .fixture(network: true)).state, state, "\(state) + \(input)")
            }
        }
    }

    func testCancelArmingCannotDisarmAnArmedSystem() {
        XCTAssertEqual(step(.armed(.noDepartures), .cancelArming).state, .armed(.noDepartures))
    }

    // MARK: Triggering

    func testIntrusionStartsCountdown() throws {
        let (state, effects) = step(.armed(.noDepartures), .intrusion(key))
        XCTAssertEqual(state, .triggered(.noDepartures, try XCTUnwrap(Countdown(seconds: 3)), key))
        XCTAssertTrue(effects.contains(.showOverlay))
        XCTAssertTrue(effects.contains(.startCountdownTimer))
        XCTAssertTrue(effects.contains(.emit(.countdownStarted(key, seconds: 3))))
    }

    func testNoCountdownSoundsImmediately() {
        let (state, effects) = step(.armed(.noDepartures), .intrusion(.powerDisconnected), .fixture(countdown: 0))
        XCTAssertEqual(state, .alarming(.noDepartures, .powerDisconnected))
        XCTAssertTrue(effects.contains(.playAlarm))
    }

    func testCountdownTicksThenSoundsWithOriginalCause() throws {
        var state = AlarmState.triggered(.noDepartures, try XCTUnwrap(Countdown(seconds: 2)), key)
        state = step(state, .countdownTick).state
        guard case .triggered(_, let countdown, _) = state else { return XCTFail("still counting down") }
        XCTAssertEqual(countdown.remaining, 1)

        let (final, effects) = step(state, .countdownTick)
        XCTAssertEqual(final, .alarming(.noDepartures, key))
        XCTAssertTrue(effects.contains(.emit(.alarmSounding(key))))
        XCTAssertFalse(effects.contains(.showOverlay), "overlay is already up")
    }

    func testStaleTickAfterDisarmIsNoOp() {
        XCTAssertEqual(step(.idle, .countdownTick).state, .idle)
        XCTAssertTrue(step(.idle, .countdownTick).effects.isEmpty)
    }

    func testSevereIntrusionEscalatesMidCountdown() throws {
        let triggered = AlarmState.triggered(.noDepartures, try XCTUnwrap(Countdown(seconds: 10)), key)
        XCTAssertEqual(step(triggered, .severeIntrusion(.lidClosed)).state, .alarming(.noDepartures, .lidClosed))
        XCTAssertEqual(step(.armed(.noDepartures), .severeIntrusion(.lidClosed)).state, .alarming(.noDepartures, .lidClosed))
    }

    /// A phone left on the desk must not silence the alarm.
    func testNearbyDeviceDoesNotSuppressIntrusions() {
        let phoneHere = AlarmEnvironment.fixture(sightings: [.phone: .nearby])
        XCTAssertEqual(step(.armed(.noDepartures), .intrusion(key), phoneHere).state.phase, .triggered)
        XCTAssertEqual(step(.armed(.noDepartures), .severeIntrusion(.lidClosed), phoneHere).state.phase, .alarming)
    }

    // MARK: Proximity disarm

    func testArmRecordsOnlyDevicesSeenAway() {
        let env = AlarmEnvironment.fixture(sightings: [.phone: .away, .watch: .nearby])
        XCTAssertEqual(step(.idle, .armRequested(auto: false), env).state, arming(phoneLeft))
        XCTAssertEqual(step(.idle, .armRequested(auto: false), .fixture()).state, arming(.noDepartures),
                       "unobserved devices have not been seen away")
    }

    func testDeviceHereAtArmingDoesNotDisarm() {
        let (state, effects) = step(.armed(.noDepartures), .proximity(.seen(.phone, .nearby)), .fixture(sightings: [.phone: .nearby]))
        XCTAssertEqual(state, .armed(.noDepartures))
        XCTAssertTrue(effects.contains(.log(.bluetooth, "'Phone' nearby but was here at arming - not disarming")))
    }

    func testDeviceThatLeftThenReturnedDisarms() {
        let away = step(.armed(.noDepartures), .proximity(.seen(.phone, .away))).state
        XCTAssertEqual(away, .armed(phoneLeft))
        XCTAssertEqual(step(away, .proximity(.seen(.phone, .nearby)), .fixture(sightings: [.phone: .nearby])).state, .idle)
    }

    func testOnlyADepartedDeviceDisarms() {
        XCTAssertEqual(step(.armed(phoneLeft), .proximity(.seen(.watch, .nearby))).state, .armed(phoneLeft))
        XCTAssertEqual(step(.armed(phoneLeft), .proximity(.seen(.phone, .nearby))).state, .idle)
    }

    func testReturnDisarmsDuringAlarmAndArmingToo() {
        XCTAssertEqual(step(.alarming(phoneLeft, key), .proximity(.seen(.phone, .nearby))).state, .idle)
        XCTAssertEqual(step(arming(phoneLeft, origin: .deviceLeft), .proximity(.seen(.phone, .nearby))).state, .idle)
    }

    func testWakeDisarmsOnlyWithADepartedDeviceNearby() {
        XCTAssertEqual(step(.armed(.noDepartures), .systemWoke, .fixture(sightings: [.phone: .nearby])).state, .armed(.noDepartures))
        XCTAssertEqual(step(.armed(phoneLeft), .systemWoke, .fixture(sightings: [.watch: .nearby])).state, .armed(phoneLeft))
        XCTAssertEqual(step(.armed(phoneLeft), .systemWoke, .fixture(sightings: [.phone: .nearby])).state, .idle)
    }

    // MARK: Auto-arm

    func testDepartureStartsGracePeriodOnlyWhenEnabledAndStable() {
        XCTAssertTrue(step(.idle, .proximity(.seen(.phone, .away)), .fixture(autoArm: .onDeviceLeave(.stable))).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(step(.idle, .proximity(.seen(.phone, .away)), .fixture()).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(step(.idle, .proximity(.seen(.phone, .away)), .fixture(autoArm: .onDeviceLeave(.unstable))).effects.contains(.startAutoArmTimer))
    }

    func testReturnCancelsGracePeriodOnlyWhenNoDeviceIsStillAway() {
        XCTAssertEqual(step(.idle, .proximity(.seen(.phone, .nearby)), .fixture(sightings: [.phone: .nearby])).effects,
                       [.cancelAutoArmTimer(reason: "Auto-arm cancelled - 'Phone' back nearby")])
        XCTAssertEqual(step(.idle, .proximity(.seen(.phone, .nearby)), .fixture(sightings: [.phone: .nearby, .watch: .away])).effects, [])
    }

    func testLosingSightIsNeitherReturnNorDeparture() {
        let autoArm = AlarmEnvironment.fixture(autoArm: .onDeviceLeave(.stable))
        XCTAssertEqual(step(.idle, .proximity(.lost(.phone)), autoArm).effects, [])
        XCTAssertEqual(step(.armed(phoneLeft), .proximity(.lost(.phone))).state, .armed(phoneLeft))
        XCTAssertEqual(step(.armed(.noDepartures), .proximity(.lost(.phone))).state, .armed(.noDepartures))
    }

    func testAutoArmTimerArmsWithTheDevicesThatLeft() {
        let env = AlarmEnvironment.fixture(sightings: [.phone: .away, .watch: .nearby])
        XCTAssertEqual(step(.idle, .autoArmTimerFired, env).state, arming(phoneLeft, origin: .deviceLeft))
        XCTAssertEqual(step(.armed(.noDepartures), .autoArmTimerFired, env).state, .armed(.noDepartures))
    }

    // MARK: Stand down

    func testStandDownResumesIdleScanningOnlyWhenAutoArmConfigured() {
        XCTAssertTrue(step(arming(.noDepartures), .cancelArming, .fixture(autoArm: .onDeviceLeave(.stable))).effects.contains(.resumeIdleScanning))
        XCTAssertFalse(step(arming(.noDepartures), .cancelArming, .fixture()).effects.contains(.resumeIdleScanning))
    }

    func testSettingsChangeAppliesTheIdleScanningRule() {
        XCTAssertEqual(step(.idle, .settingsChanged, .fixture(autoArm: .onDeviceLeave(.stable))).effects, [.resumeIdleScanning])
        XCTAssertEqual(step(.idle, .settingsChanged, .fixture()).effects, [.stopIdleScanning])
    }

    func testSettingsChangeLeavesActiveScanningAlone() {
        for state: AlarmState in [arming(.noDepartures), .armed(.noDepartures)] {
            XCTAssertEqual(step(state, .settingsChanged, .fixture()).effects, [], "\(state)")
        }
    }

    // MARK: Optional triggers

    func testUSBAttachIntrudesOnlyWhenEnabled() throws {
        let usb = TriggerCause.usbDeviceAttached(name: "Flash Drive")
        XCTAssertEqual(step(.armed(.noDepartures), .intrusion(usb), .fixture(usb: true)).state,
                       .triggered(.noDepartures, try XCTUnwrap(Countdown(seconds: 3)), usb))
        XCTAssertEqual(step(.armed(.noDepartures), .intrusion(usb), .fixture(usb: false)).state, .armed(.noDepartures))
    }

    func testNetworkChangeIntrudesOnlyWhenEnabled() {
        XCTAssertEqual(step(.armed(.noDepartures), .intrusion(.networkChanged), .fixture(network: false)).state, .armed(.noDepartures))
        XCTAssertEqual(step(.armed(.noDepartures), .intrusion(.networkChanged), .fixture(network: true)).state.phase, .triggered)
    }

    func testMotionAndLidIntrudeOnlyWhenEnabled() {
        for cause: TriggerCause in [.motion, .lidMoved(degrees: -6)] {
            XCTAssertEqual(step(.armed(.noDepartures), .intrusion(cause), .fixture()).state.phase, .triggered, "\(cause)")
        }
        XCTAssertEqual(step(.armed(.noDepartures), .intrusion(.motion), .fixture(motion: false)).state, .armed(.noDepartures))
        XCTAssertEqual(step(.armed(.noDepartures), .intrusion(.lidMoved(degrees: 9)), .fixture(lidAngle: false)).state, .armed(.noDepartures))
    }

    func testCoreTriggersCannotBeDisabledBySensorSettings() {
        let off = AlarmEnvironment.fixture(usb: false, network: false, motion: false, lidAngle: false)
        XCTAssertEqual(step(.armed(.noDepartures), .intrusion(key), off).state.phase, .triggered)
        XCTAssertEqual(step(.armed(.noDepartures), .intrusion(.powerDisconnected), off).state.phase, .triggered)
    }

    // MARK: Screen lock

    func testScreenLockArmsOnlyWhenEnabledAndIdle() {
        XCTAssertEqual(step(.idle, .screenLocked, .fixture(lockArms: true)).state, arming(.noDepartures))
        XCTAssertEqual(step(.idle, .screenLocked, .fixture(lockArms: false)).state, .idle)
        XCTAssertEqual(step(.armed(phoneLeft), .screenLocked, .fixture(lockArms: true)).state, .armed(phoneLeft))
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

    func testSeenSplitsSightings() {
        let env = AlarmEnvironment.fixture(sightings: [.phone: .away, .watch: .nearby])
        XCTAssertEqual(env.seen(.away), [TrustedDevice.phone.id])
        XCTAssertEqual(env.seen(.nearby), [TrustedDevice.watch.id])
        XCTAssertEqual(AlarmEnvironment.fixture().seen(.away), [])
    }
}
