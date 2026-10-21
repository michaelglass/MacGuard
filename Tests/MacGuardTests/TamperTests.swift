// TamperTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

final class TamperMachineTests: XCTestCase {
    private let manual = ArmSession(trustedDeviceHasLeft: false)
    private let left = ArmSession(trustedDeviceHasLeft: true)

    private let env = AlarmEnvironment.fixture()

    func testArmingPersistsTheMarker() {
        let effects = AlarmMachine.step(.arming(left), .inputMonitoringStarted(true), env).effects
        XCTAssertEqual(effects.first, .persistArmedMarker(left))
    }

    func testEveryStandDownClearsTheMarker() {
        let standDowns: [(AlarmState, AlarmInput)] = [
            (.arming(manual), .cancelArming),
            (.arming(manual), .inputMonitoringStarted(false)),
            (.armed(left), .trustedDeviceNearby(name: "Phone")),
            (.alarming(left, .tamper), .systemWoke),
        ]
        let nearby = AlarmEnvironment.fixture(countdown: 0, any: true, all: true)
        for (state, input) in standDowns {
            let (next, effects) = AlarmMachine.step(state, input, nearby)
            XCTAssertEqual(next, .idle, "\(state) + \(input)")
            XCTAssertTrue(effects.contains(.clearArmedMarker), "\(state) + \(input)")
            XCTAssertTrue(effects.contains(.endOwnerChallenge), "\(state) + \(input): PIN history and Touch ID prompt end on disarm")
        }
    }

    func testResumeAfterTamperSoundsImmediately() {
        let (state, effects) = AlarmMachine.step(.idle, .resumeAfterTamper(left), env)
        XCTAssertEqual(state, .alarming(left, .tamper))
        for required: AlarmEffect in [.persistArmedMarker(left), .startSystemMonitors, .showOverlay, .playAlarm,
                                      .emit(.alarmSounding(.tamper))] {
            XCTAssertTrue(effects.contains(required), "\(required)")
        }
    }

    func testResumeKeepsTheStoredProximityRights() {
        // A manual-arm session must not gain proximity-disarm rights by being killed
        XCTAssertEqual(AlarmMachine.step(.idle, .resumeAfterTamper(manual), env).state, .alarming(manual, .tamper))
    }

    func testResumeIgnoredWhenAlreadyActive() {
        XCTAssertEqual(AlarmMachine.step(.armed(manual), .resumeAfterTamper(left), env).state, .armed(manual))
    }
}

final class LaunchDecisionTests: XCTestCase {
    private func markerData(left: Bool, pid: Int32) throws -> Data {
        try TamperGuard.encoder.encode(ArmedMarker(ArmSession(trustedDeviceHasLeft: left), armedAt: Date(), pid: pid))
    }

    func testNoMarkerIsNormalLaunch() {
        XCTAssertEqual(LaunchDecision.decide(markerData: nil) { _ in false }, .normal)
    }

    func testDeadOwnerMeansTamper() throws {
        let data = try markerData(left: true, pid: 4242)
        XCTAssertEqual(LaunchDecision.decide(markerData: data) { _ in false },
                       .resumeAfterTamper(ArmSession(trustedDeviceHasLeft: true)))
    }

    func testLiveOwnerIsNotTamper() throws {
        let data = try markerData(left: false, pid: 4242)
        XCTAssertEqual(LaunchDecision.decide(markerData: data) { $0 == 4242 }, .normal)
    }

    func testCorruptMarkerFailsClosed() {
        XCTAssertEqual(LaunchDecision.decide(markerData: Data("garbage".utf8)) { _ in true },
                       .resumeAfterTamper(ArmSession(trustedDeviceHasLeft: false)))
    }

    func testOwnProcessIsRecognised() {
        XCTAssertTrue(TamperGuard.isMacGuardProcess(getpid()))
        XCTAssertFalse(TamperGuard.isMacGuardProcess(1), "launchd is not MacGuard")
        XCTAssertFalse(TamperGuard.isMacGuardProcess(-1))
    }
}
