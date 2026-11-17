// AlarmMachineTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

final class AlarmMachineTests: XCTestCase {
    private let manual = ArmSession(trustedDeviceHasLeft: false)
    private let left = ArmSession(trustedDeviceHasLeft: true)
    private let key = TriggerCause.input(.keyboard)

    private func arming(_ session: ArmSession, _ delay: ExitDelay = .s1) -> AlarmState {
        .arming(session, until: AlarmEnvironment.t0.addingTimeInterval(delay.seconds))
    }

    private func step(_ s: AlarmState, _ i: AlarmInput, _ e: AlarmEnvironment = .fixture()) -> AlarmMachine.Transition {
        AlarmMachine.step(s, i, e)
    }

    // MARK: Arming

    func testArmEntersArmingSynchronously() {
        let (state, effects) = step(.idle, .armRequested(auto: false))
        XCTAssertEqual(state, arming(manual))
        XCTAssertEqual(effects, [.closeConfigWindows, .prepareAudio, .scheduleArmingDelay(.s1)])
        XCTAssertTrue(step(.idle, .armRequested(auto: false), .fixture(exitDelay: .s30)).effects
            .contains(.scheduleArmingDelay(.s30)))
    }

    func testArmingCarriesItsDeadline() {
        let now = AlarmEnvironment.t0.addingTimeInterval(100)
        XCTAssertEqual(step(.idle, .armRequested(auto: false), .fixture(now: now, exitDelay: .s30)).state,
                       .arming(manual, until: now.addingTimeInterval(30)))
    }

    func testArmLocksScreenOnlyWhenConfigured() {
        XCTAssertTrue(step(.idle, .armRequested(auto: false), .fixture(autoLock: true)).effects.contains(.lockScreen))
    }

    func testSecondArmRequestIsIgnored() {
        XCTAssertTrue(step(arming(manual), .armRequested(auto: false)).effects.isEmpty)
        XCTAssertTrue(step(.armed(manual), .armRequested(auto: false)).effects.isEmpty)
    }

    func testArmingCompletesWhenInputMonitoringStarts() {
        XCTAssertEqual(step(arming(manual), .armingDelayElapsed).effects, [.startInputMonitoring])
        let (state, effects) = step(arming(manual), .inputMonitoringStarted(true))
        XCTAssertEqual(state, .armed(manual))
        XCTAssertTrue(effects.contains(.emit(.armed(auto: false))))
    }

    func testDelayAfterCancelDoesNotArm() {
        let (cancelled, _) = step(arming(manual), .cancelArming)
        XCTAssertEqual(cancelled, .idle)
        XCTAssertEqual(step(cancelled, .armingDelayElapsed).state, .idle)
        XCTAssertEqual(step(cancelled, .inputMonitoringStarted(true)).state, .idle)
    }

    func testIntrusionsIgnoredUnlessArmed() {
        let inputs: [AlarmInput] = [.intrusion(key), .severeIntrusion(.lidClosed),
                                    .intrusion(.usbDeviceAttached(name: "x")), .intrusion(.networkChanged)]
        for state: AlarmState in [.idle, arming(manual)] {
            for input in inputs {
                XCTAssertEqual(step(state, input, .fixture(network: true)).state, state, "\(state) + \(input)")
            }
        }
    }

    func testCancelArmingCannotDisarmAnArmedSystem() {
        XCTAssertEqual(step(.armed(manual), .cancelArming).state, .armed(manual))
    }

    // MARK: Triggering

    func testIntrusionStartsCountdown() throws {
        let (state, effects) = step(.armed(manual), .intrusion(key))
        XCTAssertEqual(state, .triggered(manual, try XCTUnwrap(Countdown(seconds: 3)), key))
        XCTAssertTrue(effects.contains(.showOverlay))
        XCTAssertTrue(effects.contains(.startCountdownTimer))
        XCTAssertTrue(effects.contains(.emit(.countdownStarted(key, seconds: 3))))
    }

    func testNoCountdownSoundsImmediately() {
        let (state, effects) = step(.armed(manual), .intrusion(.powerDisconnected), .fixture(countdown: 0))
        XCTAssertEqual(state, .alarming(manual, .powerDisconnected))
        XCTAssertTrue(effects.contains(.playAlarm))
    }

    func testCountdownTicksThenSoundsWithOriginalCause() throws {
        var state = AlarmState.triggered(manual, try XCTUnwrap(Countdown(seconds: 2)), key)
        state = step(state, .countdownTick).state
        guard case .triggered(_, let countdown, _) = state else { return XCTFail("still counting down") }
        XCTAssertEqual(countdown.remaining, 1)

        let (final, effects) = step(state, .countdownTick)
        XCTAssertEqual(final, .alarming(manual, key))
        XCTAssertTrue(effects.contains(.emit(.alarmSounding(key))))
        XCTAssertFalse(effects.contains(.showOverlay), "overlay is already up")
    }

    func testStaleTickAfterDisarmIsNoOp() {
        XCTAssertEqual(step(.idle, .countdownTick).state, .idle)
        XCTAssertTrue(step(.idle, .countdownTick).effects.isEmpty)
    }

    func testSevereIntrusionEscalatesMidCountdown() throws {
        let triggered = AlarmState.triggered(manual, try XCTUnwrap(Countdown(seconds: 10)), key)
        XCTAssertEqual(step(triggered, .severeIntrusion(.lidClosed)).state, .alarming(manual, .lidClosed))
        XCTAssertEqual(step(.armed(manual), .severeIntrusion(.lidClosed)).state, .alarming(manual, .lidClosed))
    }

    func testNearbyDeviceSuppressesOnlyInAllDevicesAwayMode() {
        XCTAssertEqual(step(.armed(manual), .intrusion(key), .fixture(proximity: .devices(.allDevicesAway, nearby: .some))).state, .armed(manual))
        XCTAssertEqual(step(.armed(manual), .severeIntrusion(.lidClosed), .fixture(proximity: .devices(.allDevicesAway, nearby: .some))).state, .armed(manual))
        XCTAssertNotEqual(step(.armed(manual), .intrusion(key), .fixture(proximity: .devices(.anyDeviceAway, nearby: .some))).state, .armed(manual))
    }

    // MARK: Proximity disarm

    func testManualArmIsNotDisarmedByPresentDevice() {
        let (state, effects) = step(.armed(manual), .trustedDeviceNearby(.phone), .fixture(proximity: .devices(nearby: .some)))
        XCTAssertEqual(state, .armed(manual))
        XCTAssertTrue(effects.contains(.log(.bluetooth, "Device 'Phone' nearby but manual arm - not auto-disarming")))
    }

    func testDeviceThatLeftThenReturnedDisarms() {
        let away = step(.armed(manual), .trustedDeviceAway(.phone)).state
        XCTAssertEqual(away, .armed(left))
        XCTAssertEqual(step(away, .trustedDeviceNearby(.phone), .fixture(proximity: .devices(nearby: .some))).state, .idle)
    }

    func testReturnDisarmsDuringAlarmToo() {
        XCTAssertEqual(step(.alarming(left, key), .trustedDeviceNearby(.phone), .fixture(proximity: .devices(nearby: .some))).state, .idle)
    }

    func testAnyDeviceAwayModeNeedsAllDevicesBack() {
        let partial = AlarmEnvironment.fixture(proximity: .devices(.anyDeviceAway, nearby: .some))
        XCTAssertEqual(step(.armed(left), .trustedDeviceNearby(.phone), partial).state, .armed(left))
        XCTAssertEqual(step(.armed(left), .trustedDeviceNearby(.watch), .fixture(proximity: .devices(.anyDeviceAway, nearby: .all))).state, .idle)
    }

    /// Including the manual-arm rule and "any device away" mode.
    func testWakeFollowsTheSameRule() {
        XCTAssertEqual(step(.armed(manual), .systemWoke, .fixture(proximity: .devices(nearby: .some))).state, .armed(manual))
        XCTAssertEqual(step(.armed(left), .systemWoke, .fixture(proximity: .devices(.anyDeviceAway, nearby: .some))).state, .armed(left))
        XCTAssertEqual(step(.armed(left), .systemWoke, .fixture(proximity: .devices(nearby: .some))).state, .idle)
    }

    func testNoProximityDisarmWhileArming() {
        XCTAssertEqual(step(arming(left), .trustedDeviceNearby(.phone), .fixture(proximity: .devices(nearby: .some))).state, arming(left))
    }

    func testNearbyAlwaysCancelsAutoArmTimer() {
        XCTAssertEqual(step(.idle, .trustedDeviceNearby(.phone)).effects,
                       [.cancelAutoArmTimer(reason: "Auto-arm cancelled - 'Phone' detected nearby")])
    }

    // MARK: Auto-arm

    func testAllAwayStartsGracePeriodOnlyWhenEnabledAndStable() {
        XCTAssertTrue(step(.idle, .allTrustedDevicesAway, .fixture(proximity: .autoArmStable)).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(step(.idle, .allTrustedDevicesAway, .fixture(proximity: .devices())).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(step(.idle, .allTrustedDevicesAway, .fixture(proximity: .devices(autoArm: .onDeviceLeave(.unstable)))).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(step(.idle, .allTrustedDevicesAway, .fixture(proximity: .devices(.anyDeviceAway, autoArm: .onDeviceLeave(.stable)))).effects.contains(.startAutoArmTimer))
    }

    func testAnyAwayModeStartsGracePeriodOnSingleDeparture() {
        let effects = step(.idle, .trustedDeviceAway(.phone), .fixture(proximity: .devices(.anyDeviceAway, autoArm: .onDeviceLeave(.stable)))).effects
        XCTAssertTrue(effects.contains(.startAutoArmTimer))
    }

    func testAutoArmTimerArmsAsDeviceLeft() {
        XCTAssertEqual(step(.idle, .autoArmTimerFired).state, arming(left))
        XCTAssertEqual(step(.armed(manual), .autoArmTimerFired).state, .armed(manual))
    }

    // MARK: Stand down

    func testStandDownResumesIdleScanningOnlyWhenAutoArmConfigured() {
        XCTAssertTrue(step(arming(manual), .cancelArming, .fixture(proximity: .autoArmStable)).effects.contains(.resumeIdleScanning))
        XCTAssertFalse(step(arming(manual), .cancelArming, .fixture(proximity: .noTrustedDevices)).effects.contains(.resumeIdleScanning))
        XCTAssertFalse(step(arming(manual), .cancelArming, .fixture(proximity: .devices())).effects.contains(.resumeIdleScanning))
    }

    func testSettingsChangeAppliesTheIdleScanningRule() {
        XCTAssertEqual(step(.idle, .settingsChanged, .fixture(proximity: .autoArmStable)).effects, [.resumeIdleScanning])
        XCTAssertEqual(step(.idle, .settingsChanged, .fixture(proximity: .noTrustedDevices)).effects, [.stopIdleScanning])
        XCTAssertEqual(step(.idle, .settingsChanged, .fixture(proximity: .devices())).effects, [.stopIdleScanning])
    }

    func testSettingsChangeLeavesActiveScanningAlone() {
        for state: AlarmState in [arming(manual), .armed(manual)] {
            XCTAssertEqual(step(state, .settingsChanged, .fixture(proximity: .devices())).effects, [], "\(state)")
        }
    }

    // MARK: Optional triggers

    func testUSBAttachIntrudesOnlyWhenEnabled() throws {
        let usb = TriggerCause.usbDeviceAttached(name: "Flash Drive")
        XCTAssertEqual(step(.armed(manual), .intrusion(usb), .fixture(usb: true)).state,
                       .triggered(manual, try XCTUnwrap(Countdown(seconds: 3)), usb))
        XCTAssertEqual(step(.armed(manual), .intrusion(usb), .fixture(usb: false)).state, .armed(manual))
    }

    func testNetworkChangeIntrudesOnlyWhenEnabled() {
        XCTAssertEqual(step(.armed(manual), .intrusion(.networkChanged), .fixture(network: false)).state, .armed(manual))
        XCTAssertEqual(step(.armed(manual), .intrusion(.networkChanged), .fixture(network: true)).state.phase, .triggered)
    }

    func testMotionAndLidIntrudeOnlyWhenEnabled() {
        for cause: TriggerCause in [.motion, .lidMoved(degrees: -6)] {
            XCTAssertEqual(step(.armed(manual), .intrusion(cause), .fixture()).state.phase, .triggered, "\(cause)")
        }
        XCTAssertEqual(step(.armed(manual), .intrusion(.motion), .fixture(motion: false)).state, .armed(manual))
        XCTAssertEqual(step(.armed(manual), .intrusion(.lidMoved(degrees: 9)), .fixture(lidAngle: false)).state, .armed(manual))
    }

    func testCoreTriggersCannotBeDisabledBySensorSettings() {
        let off = AlarmEnvironment.fixture(usb: false, network: false, motion: false, lidAngle: false)
        XCTAssertEqual(step(.armed(manual), .intrusion(key), off).state.phase, .triggered)
        XCTAssertEqual(step(.armed(manual), .intrusion(.powerDisconnected), off).state.phase, .triggered)
    }

    // MARK: Screen lock

    func testScreenLockArmsOnlyWhenEnabledAndIdle() {
        XCTAssertEqual(step(.idle, .screenLocked, .fixture(lockArms: true)).state, arming(manual))
        XCTAssertEqual(step(.idle, .screenLocked, .fixture(lockArms: false)).state, .idle)
        XCTAssertEqual(step(.armed(left), .screenLocked, .fixture(lockArms: true)).state, .armed(left))
    }

    // MARK: Parsing proximity evidence

    func testPresenceCountsPositiveEvidenceOnly() {
        XCTAssertEqual(Presence(anyNearby: false, allNearby: false), .none)
        XCTAssertEqual(Presence(anyNearby: true, allNearby: false), .some)
        XCTAssertEqual(Presence(anyNearby: true, allNearby: true), .all)
        XCTAssertEqual(Presence(anyNearby: false, allNearby: true), .none, "a stale reading vouches for nobody")
    }

    func testProximityEvidenceParsesSettingsAndBluetooth() {
        func parse(devices: Bool = true, mode: AutoArmMode = .allDevicesAway, autoArm: Bool = false,
                   any: Bool = false, all: Bool = false, stable: Bool = true) -> ProximityEvidence {
            ProximityEvidence(hasTrustedDevices: devices, mode: mode, autoArmEnabled: autoArm,
                              anyNearby: any, allNearby: all, bluetoothStable: stable)
        }
        XCTAssertEqual(parse(devices: false, autoArm: true, any: true), .noTrustedDevices)
        XCTAssertEqual(parse(), .devices())
        XCTAssertEqual(parse(mode: .anyDeviceAway, any: true, all: true), .devices(.anyDeviceAway, nearby: .all))
        XCTAssertEqual(parse(autoArm: true), .devices(autoArm: .onDeviceLeave(.stable)))
        XCTAssertEqual(parse(autoArm: true, stable: false), .devices(autoArm: .onDeviceLeave(.unstable)))
        XCTAssertEqual(parse(stable: false), .devices(), "stability only matters to auto-arm")
    }
}
