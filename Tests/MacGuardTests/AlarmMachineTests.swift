// AlarmMachineTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

final class AlarmMachineTests: XCTestCase {
    private let manual = ArmSession(departed: [])
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
        XCTAssertEqual(state, arming(manual))
        XCTAssertEqual(effects, [.closeConfigWindows, .prepareAudio, .scheduleArmingDelay(.s1)])
        XCTAssertTrue(step(.idle, .armRequested(auto: false), .fixture(exitDelay: .s30)).effects
            .contains(.scheduleArmingDelay(.s30)))
    }

    func testArmingCarriesItsDeadline() {
        let now = AlarmEnvironment.t0.addingTimeInterval(100)
        XCTAssertEqual(step(.idle, .armRequested(auto: false), .fixture(now: now, exitDelay: .s30)).state,
                       .arming(manual, until: now.addingTimeInterval(30), origin: .manual))
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
        XCTAssertTrue(step(arming(phoneLeft, origin: .deviceLeft), .inputMonitoringStarted(true)).effects
            .contains(.emit(.armed(auto: true))))
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

    /// A phone left on the desk must not silence the alarm.
    func testNearbyDeviceDoesNotSuppressIntrusions() {
        let phoneHere = AlarmEnvironment.fixture(proximity: .devices([.phone: .nearby]))
        XCTAssertEqual(step(.armed(manual), .intrusion(key), phoneHere).state.phase, .triggered)
        XCTAssertEqual(step(.armed(manual), .severeIntrusion(.lidClosed), phoneHere).state.phase, .alarming)
    }

    // MARK: Proximity disarm

    func testArmRecordsOnlyDevicesSeenAway() {
        let env = AlarmEnvironment.fixture(proximity: .devices([.phone: .away, .watch: .nearby]))
        XCTAssertEqual(step(.idle, .armRequested(auto: false), env).state, arming(phoneLeft))
        XCTAssertEqual(step(.idle, .armRequested(auto: false), .fixture(proximity: .devices())).state, arming(manual),
                       "unobserved devices have not been seen away")
    }

    func testDeviceHereAtArmingDoesNotDisarm() {
        let (state, effects) = step(.armed(manual), .trustedDeviceNearby(.phone), .fixture(proximity: .devices([.phone: .nearby])))
        XCTAssertEqual(state, .armed(manual))
        XCTAssertTrue(effects.contains(.log(.bluetooth, "'Phone' nearby but was here at arming - not disarming")))
    }

    func testDeviceThatLeftThenReturnedDisarms() {
        let away = step(.armed(manual), .trustedDeviceAway(.phone)).state
        XCTAssertEqual(away, .armed(phoneLeft))
        XCTAssertEqual(step(away, .trustedDeviceNearby(.phone), .fixture(proximity: .devices([.phone: .nearby]))).state, .idle)
    }

    func testOnlyADepartedDeviceDisarms() {
        XCTAssertEqual(step(.armed(phoneLeft), .trustedDeviceNearby(.watch)).state, .armed(phoneLeft))
        XCTAssertEqual(step(.armed(phoneLeft), .trustedDeviceNearby(.phone)).state, .idle)
    }

    func testReturnDisarmsDuringAlarmAndArmingToo() {
        XCTAssertEqual(step(.alarming(phoneLeft, key), .trustedDeviceNearby(.phone)).state, .idle)
        XCTAssertEqual(step(arming(phoneLeft, origin: .deviceLeft), .trustedDeviceNearby(.phone)).state, .idle)
    }

    func testWakeDisarmsOnlyWithADepartedDeviceNearby() {
        XCTAssertEqual(step(.armed(manual), .systemWoke, .fixture(proximity: .devices([.phone: .nearby]))).state, .armed(manual))
        XCTAssertEqual(step(.armed(phoneLeft), .systemWoke, .fixture(proximity: .devices([.watch: .nearby]))).state, .armed(phoneLeft))
        XCTAssertEqual(step(.armed(phoneLeft), .systemWoke, .fixture(proximity: .devices([.phone: .nearby]))).state, .idle)
    }

    // MARK: Auto-arm

    func testDepartureStartsGracePeriodOnlyWhenEnabledAndStable() {
        XCTAssertTrue(step(.idle, .trustedDeviceAway(.phone), .fixture(proximity: .autoArmStable)).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(step(.idle, .trustedDeviceAway(.phone), .fixture(proximity: .devices())).effects.contains(.startAutoArmTimer))
        XCTAssertFalse(step(.idle, .trustedDeviceAway(.phone), .fixture(proximity: .devices(autoArm: .onDeviceLeave(.unstable)))).effects.contains(.startAutoArmTimer))
    }

    func testReturnCancelsGracePeriodOnlyWhenNoDeviceIsStillAway() {
        XCTAssertEqual(step(.idle, .trustedDeviceNearby(.phone), .fixture(proximity: .devices([.phone: .nearby]))).effects,
                       [.cancelAutoArmTimer(reason: "Auto-arm cancelled - 'Phone' back nearby")])
        XCTAssertEqual(step(.idle, .trustedDeviceNearby(.phone), .fixture(proximity: .devices([.phone: .nearby, .watch: .away]))).effects, [])
    }

    func testAutoArmTimerArmsWithTheDevicesThatLeft() {
        let env = AlarmEnvironment.fixture(proximity: .devices([.phone: .away, .watch: .nearby]))
        XCTAssertEqual(step(.idle, .autoArmTimerFired, env).state, arming(phoneLeft, origin: .deviceLeft))
        XCTAssertEqual(step(.armed(manual), .autoArmTimerFired, env).state, .armed(manual))
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
        XCTAssertEqual(step(.armed(phoneLeft), .screenLocked, .fixture(lockArms: true)).state, .armed(phoneLeft))
    }

    // MARK: Parsing proximity evidence

    func testProximityEvidenceParsesSettingsAndBluetooth() {
        func parse(devices: Bool = true, sightings: [TrustedDevice.ID: Sighting] = [:],
                   autoArm: Bool = false, stable: Bool = true) -> ProximityEvidence {
            ProximityEvidence(hasTrustedDevices: devices, sightings: sightings,
                              autoArmEnabled: autoArm, bluetoothStable: stable)
        }
        XCTAssertEqual(parse(devices: false, sightings: [TrustedDevice.phone.id: .nearby], autoArm: true), .noTrustedDevices)
        XCTAssertEqual(parse(), .devices())
        XCTAssertEqual(parse(sightings: [TrustedDevice.phone.id: .away]), .devices([.phone: .away]))
        XCTAssertEqual(parse(autoArm: true), .devices(autoArm: .onDeviceLeave(.stable)))
        XCTAssertEqual(parse(autoArm: true, stable: false), .devices(autoArm: .onDeviceLeave(.unstable)))
        XCTAssertEqual(parse(stable: false), .devices(), "stability only matters to auto-arm")
    }

    func testSeenSplitsSightings() {
        let evidence = ProximityEvidence.devices([.phone: .away, .watch: .nearby])
        XCTAssertEqual(evidence.seen(.away), [TrustedDevice.phone.id])
        XCTAssertEqual(evidence.seen(.nearby), [TrustedDevice.watch.id])
        XCTAssertEqual(ProximityEvidence.noTrustedDevices.seen(.away), [])
    }
}
