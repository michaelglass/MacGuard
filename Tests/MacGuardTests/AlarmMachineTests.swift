// AlarmMachineTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

final class AlarmMachineTests: XCTestCase {
    private let manual = ArmSession(trustedDeviceHasLeft: false)
    private let left = ArmSession(trustedDeviceHasLeft: true)
    private let key = TriggerCause.input(.keyboard)

    private func env(
        countdown: Int = 3, autoLock: Bool = false, autoArm: Bool = false,
        mode: AutoArmMode = .allDevicesAway, devices: Bool = true, any: Bool = false,
        all: Bool = false, stable: Bool = true, usb: Bool = true, network: Bool = false,
        lockArms: Bool = false, exitDelay: ExitDelay = .s1
    ) -> AlarmEnvironment {
        .fixture(countdown: countdown, autoLock: autoLock, autoArm: autoArm, mode: mode,
                 devices: devices, any: any, all: all, stable: stable, usb: usb,
                 network: network, lockArms: lockArms, exitDelay: exitDelay)
    }

    private func step(_ s: AlarmState, _ i: AlarmInput, _ e: AlarmEnvironment? = nil) -> AlarmMachine.Transition {
        AlarmMachine.step(s, i, e ?? env())
    }

    // MARK: Arming

    func testArmEntersArmingSynchronously() {
        let (state, effects) = step(.idle, .armRequested(auto: false))
        XCTAssertEqual(state, .arming(manual))
        XCTAssertEqual(effects, [.closeConfigWindows, .prepareAudio, .scheduleArmingDelay(.s1)])
    }

    func testArmLocksScreenOnlyWhenConfigured() {
        XCTAssertTrue(step(.idle, .armRequested(auto: false), env(autoLock: true)).effects.contains(.lockScreen))
    }

    func testSecondArmRequestIsIgnored() {
        XCTAssertTrue(step(.arming(manual), .armRequested(auto: false)).effects.isEmpty)
        XCTAssertTrue(step(.armed(manual), .armRequested(auto: false)).effects.isEmpty)
    }

    func testArmingCompletesWhenInputMonitoringStarts() {
        XCTAssertEqual(step(.arming(manual), .armingDelayElapsed).effects, [.startInputMonitoring])
        let (state, effects) = step(.arming(manual), .inputMonitoringStarted(true))
        XCTAssertEqual(state, .armed(manual))
        XCTAssertTrue(effects.contains(.emit(.armed(auto: false))))
    }

    func testArmingFailsWithoutPermission() {
        let (state, effects) = step(.arming(manual), .inputMonitoringStarted(false))
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(effects.contains(.stopMonitors))
    }

    func testDelayAfterCancelDoesNotArm() {
        let (cancelled, _) = step(.arming(manual), .cancelArming)
        XCTAssertEqual(cancelled, .idle)
        XCTAssertEqual(step(cancelled, .armingDelayElapsed).state, .idle)
        XCTAssertEqual(step(cancelled, .inputMonitoringStarted(true)).state, .idle)
    }

    func testCancelArmingCannotDisarmAnArmedSystem() {
        XCTAssertEqual(step(.armed(manual), .cancelArming).state, .armed(manual))
    }

    func testIntrusionDuringArmingIsIgnored() {
        XCTAssertEqual(step(.arming(manual), .intrusion(key)).state, .arming(manual))
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
        let (state, effects) = step(.armed(manual), .intrusion(.powerDisconnected), env(countdown: 0))
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

    func testSevereIntrusionIgnoredWhenNotArmed() {
        XCTAssertEqual(step(.idle, .severeIntrusion(.lidClosed)).state, .idle)
        XCTAssertEqual(step(.arming(manual), .severeIntrusion(.lidClosed)).state, .arming(manual))
    }

    func testNearbyDeviceSuppressesOnlyInAllDevicesAwayMode() {
        XCTAssertEqual(step(.armed(manual), .intrusion(key), env(mode: .allDevicesAway, any: true)).state, .armed(manual))
        XCTAssertEqual(step(.armed(manual), .severeIntrusion(.lidClosed), env(mode: .allDevicesAway, any: true)).state, .armed(manual))
        XCTAssertNotEqual(step(.armed(manual), .intrusion(key), env(mode: .anyDeviceAway, any: true)).state, .armed(manual))
    }

    // MARK: Proximity disarm

    func testManualArmIsNotDisarmedByPresentDevice() {
        let (state, effects) = step(.armed(manual), .trustedDeviceNearby(name: "Phone"), env(any: true))
        XCTAssertEqual(state, .armed(manual))
        XCTAssertTrue(effects.contains(.log(.bluetooth, "Device 'Phone' nearby but manual arm - not auto-disarming")))
    }

    func testDeviceThatLeftThenReturnedDisarms() {
        let away = step(.armed(manual), .trustedDeviceAway(name: "Phone")).state
        XCTAssertEqual(away, .armed(left))
        XCTAssertEqual(step(away, .trustedDeviceNearby(name: "Phone"), env(any: true)).state, .idle)
    }

    func testReturnDisarmsDuringAlarmToo() {
        XCTAssertEqual(step(.alarming(left, key), .trustedDeviceNearby(name: "Phone"), env(any: true)).state, .idle)
    }

    func testAnyDeviceAwayModeNeedsAllDevicesBack() {
        let partial = env(mode: .anyDeviceAway, any: true, all: false)
        XCTAssertEqual(step(.armed(left), .trustedDeviceNearby(name: "Phone"), partial).state, .armed(left))
        XCTAssertEqual(step(.armed(left), .trustedDeviceNearby(name: "Watch"), env(mode: .anyDeviceAway, any: true, all: true)).state, .idle)
    }

    /// Including the manual-arm rule and "any device away" mode.
    func testWakeFollowsTheSameRule() {
        XCTAssertEqual(step(.armed(manual), .systemWoke, env(any: true)).state, .armed(manual))
        XCTAssertEqual(step(.armed(left), .systemWoke, env(mode: .anyDeviceAway, any: true, all: false)).state, .armed(left))
        XCTAssertEqual(step(.armed(left), .systemWoke, env(any: true)).state, .idle)
    }

    func testNoProximityDisarmWhileArming() {
        XCTAssertEqual(step(.arming(left), .trustedDeviceNearby(name: "Phone"), env(any: true)).state, .arming(left))
    }

    func testNearbyAlwaysCancelsAutoArmTimer() {
        XCTAssertEqual(step(.idle, .trustedDeviceNearby(name: "Phone")).effects,
                       [.cancelAutoArmTimer(reason: "Auto-arm cancelled - 'Phone' detected nearby")])
    }

    // MARK: Auto-arm

    func testAllAwayStartsGracePeriodOnlyWhenEnabledAndStable() {
        XCTAssertTrue(step(.idle, .allTrustedDevicesAway, env(autoArm: true)).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(step(.idle, .allTrustedDevicesAway, env(autoArm: false)).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(step(.idle, .allTrustedDevicesAway, env(autoArm: true, stable: false)).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(step(.idle, .allTrustedDevicesAway, env(autoArm: true, mode: .anyDeviceAway)).effects.contains(.startAutoArmTimer))
    }

    func testAnyAwayModeStartsGracePeriodOnSingleDeparture() {
        let effects = step(.idle, .trustedDeviceAway(name: "Phone"), env(autoArm: true, mode: .anyDeviceAway)).effects
        XCTAssertTrue(effects.contains(.startAutoArmTimer))
    }

    func testAutoArmTimerArmsAsDeviceLeft() {
        XCTAssertEqual(step(.idle, .autoArmTimerFired).state, .arming(left))
        XCTAssertEqual(step(.armed(manual), .autoArmTimerFired).state, .armed(manual))
    }

    // MARK: Stand down

    func testStandDownResumesIdleScanningOnlyWhenAutoArmConfigured() {
        XCTAssertTrue(step(.arming(manual), .cancelArming, env(autoArm: true, devices: true)).effects.contains(.resumeIdleScanning))
        XCTAssertFalse(step(.arming(manual), .cancelArming, env(autoArm: true, devices: false)).effects.contains(.resumeIdleScanning))
        XCTAssertFalse(step(.arming(manual), .cancelArming, env(autoArm: false)).effects.contains(.resumeIdleScanning))
    }

    func testSettingsChangeAppliesTheIdleScanningRule() {
        XCTAssertEqual(step(.idle, .settingsChanged, env(autoArm: true, devices: true)).effects, [.resumeIdleScanning])
        XCTAssertEqual(step(.idle, .settingsChanged, env(autoArm: true, devices: false)).effects, [.stopIdleScanning])
        XCTAssertEqual(step(.idle, .settingsChanged, env(autoArm: false)).effects, [.stopIdleScanning])
    }

    func testSettingsChangeLeavesActiveScanningAlone() {
        for state: AlarmState in [.arming(manual), .armed(manual)] {
            XCTAssertEqual(step(state, .settingsChanged, env(autoArm: false)).effects, [], "\(state)")
        }
    }

    func testStandDownStopsEverything() {
        let effects = step(.arming(manual), .cancelArming).effects
        for required: AlarmEffect in [.stopCountdownTimer, .stopMonitors, .stopAlarm, .hideOverlay] {
            XCTAssertTrue(effects.contains(required), "\(required)")
        }
    }

    // MARK: Exit delay

    func testExitDelayIsPropagatedToTheShell() {
        let effects = step(.idle, .armRequested(auto: false), env(exitDelay: .s30)).effects
        XCTAssertTrue(effects.contains(.scheduleArmingDelay(.s30)))
    }

    // MARK: Optional triggers

    func testUSBAttachIntrudesOnlyWhenEnabled() throws {
        let usb = TriggerCause.usbDeviceAttached(name: "Flash Drive")
        XCTAssertEqual(step(.armed(manual), .intrusion(usb), env(usb: true)).state,
                       .triggered(manual, try XCTUnwrap(Countdown(seconds: 3)), usb))
        XCTAssertEqual(step(.armed(manual), .intrusion(usb), env(usb: false)).state, .armed(manual))
    }

    func testNetworkChangeIntrudesOnlyWhenEnabled() {
        XCTAssertEqual(step(.armed(manual), .intrusion(.networkChanged), env(network: false)).state, .armed(manual))
        XCTAssertEqual(step(.armed(manual), .intrusion(.networkChanged), env(network: true)).state.phase, .triggered)
    }

    func testMotionAndLidIntrudeOnlyWhenEnabled() {
        for cause: TriggerCause in [.motion, .lidMoved(degrees: -6)] {
            XCTAssertEqual(step(.armed(manual), .intrusion(cause), .fixture()).state.phase, .triggered, "\(cause)")
        }
        XCTAssertEqual(step(.armed(manual), .intrusion(.motion), .fixture(motion: false)).state, .armed(manual))
        XCTAssertEqual(step(.armed(manual), .intrusion(.lidMoved(degrees: 9)), .fixture(lidAngle: false)).state, .armed(manual))
    }

    func testOptionalTriggersIgnoredWhenNotArmed() {
        for state: AlarmState in [.idle, .arming(manual)] {
            XCTAssertEqual(step(state, .intrusion(.usbDeviceAttached(name: "x")), env(usb: true)).state, state)
            XCTAssertEqual(step(state, .intrusion(.networkChanged), env(network: true)).state, state)
        }
    }

    func testCoreTriggersCannotBeDisabledBySensorSettings() {
        let off = env(usb: false, network: false)
        XCTAssertEqual(step(.armed(manual), .intrusion(key), off).state.phase, .triggered)
        XCTAssertEqual(step(.armed(manual), .intrusion(.powerDisconnected), off).state.phase, .triggered)
    }

    // MARK: Screen lock

    func testScreenLockArmsOnlyWhenEnabledAndIdle() {
        XCTAssertEqual(step(.idle, .screenLocked, env(lockArms: true)).state, .arming(manual))
        XCTAssertEqual(step(.idle, .screenLocked, env(lockArms: false)).state, .idle)
        XCTAssertEqual(step(.armed(left), .screenLocked, env(lockArms: true)).state, .armed(left))
    }

    func testScreenLockArmingUsesManualArmSemantics() {
        // The owner locked with devices present: their presence must not disarm
        let armed = step(.arming(manual), .inputMonitoringStarted(true)).state
        XCTAssertEqual(step(armed, .systemWoke, env(any: true)).state, armed)
    }
}
