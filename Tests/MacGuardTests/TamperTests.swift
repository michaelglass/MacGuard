// TamperTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import ServiceManagement
import XCTest
@testable import MacGuard

final class TamperMachineTests: XCTestCase {
    private let manual = ArmSession(departed: [])
    private let left = ArmSession(departed: [TrustedDevice.phone.id])

    private let env = AlarmEnvironment.fixture()

    func testArmingPersistsTheMarker() {
        let effects = AlarmMachine.step(.arming(left, until: AlarmEnvironment.t0, origin: .deviceLeft), .inputMonitoringStarted(true), env).effects
        XCTAssertEqual(effects.first, .persistArmedMarker(left))
    }

    func testEveryStandDownClearsTheMarker() {
        let standDowns: [(AlarmState, AlarmInput)] = [
            (.arming(manual, until: AlarmEnvironment.t0, origin: .manual), .cancelArming),
            (.arming(manual, until: AlarmEnvironment.t0, origin: .manual), .inputMonitoringStarted(false)),
            (.armed(left), .trustedDeviceNearby(.phone)),
            (.alarming(left, .tamper), .systemWoke),
        ]
        let nearby = AlarmEnvironment.fixture(countdown: 0, proximity: .devices([.phone: .nearby]))
        for (state, input) in standDowns {
            let (next, effects) = AlarmMachine.step(state, input, nearby)
            XCTAssertEqual(next, .idle, "\(state) + \(input)")
            for required: AlarmEffect in [.stopCountdownTimer, .stopMonitors, .stopAlarm, .hideOverlay,
                                          .clearArmedMarker, .endOwnerChallenge] {
                XCTAssertTrue(effects.contains(required), "\(state) + \(input): \(required)")
            }
        }
    }

    /// Sounds at once with the stored session: a killed manual arm gains no proximity-disarm rights.
    func testResumeAfterTamperSoundsWithTheStoredSession() {
        for session in [left, manual] {
            let (state, effects) = AlarmMachine.step(.idle, .resumeAfterTamper(session), env)
            XCTAssertEqual(state, .alarming(session, .tamper))
            for required: AlarmEffect in [.persistArmedMarker(session), .startSystemMonitors, .showOverlay,
                                          .playAlarm, .emit(.alarmSounding(.tamper))] {
                XCTAssertTrue(effects.contains(required), "\(session): \(required)")
            }
        }
    }

    func testResumeIgnoredWhenAlreadyActive() {
        XCTAssertEqual(AlarmMachine.step(.armed(manual), .resumeAfterTamper(left), env).state, .armed(manual))
    }
}

final class LaunchDecisionTests: XCTestCase {
    private let phoneLeft = ArmSession(departed: [TrustedDevice.phone.id])

    private func markerData(_ session: ArmSession, pid: Int32) throws -> Data {
        try TamperGuard.encoder.encode(ArmedMarker(session, armedAt: Date(), pid: pid))
    }

    func testDecision() throws {
        let cases: [(String, Data?, Bool, LaunchDecision)] = [
            ("no marker", nil, false, .normal),
            ("dead owner", try markerData(phoneLeft, pid: 4242), false, .resumeAfterTamper(phoneLeft)),
            ("live owner", try markerData(ArmSession(departed: []), pid: 4242), true, .normal),
            ("corrupt marker fails closed", Data("garbage".utf8), true,
             .resumeAfterTamper(ArmSession(departed: []))),
            ("pre-upgrade marker fails closed", Data(#"{"trustedDeviceHasLeft":true,"armedAt":0,"pid":4242}"#.utf8), false,
             .resumeAfterTamper(ArmSession(departed: []))),
        ]
        for (name, data, alive, expected) in cases {
            XCTAssertEqual(LaunchDecision.decide(markerData: data) { _ in alive }, expected, name)
        }
    }

    func testOwnProcessIsRecognised() {
        XCTAssertTrue(TamperGuard.isMacGuardProcess(getpid()))
        XCTAssertFalse(TamperGuard.isMacGuardProcess(1), "launchd is not MacGuard")
        XCTAssertFalse(TamperGuard.isMacGuardProcess(-1))
    }
}

final class WatchdogSyncTests: XCTestCase {
    private let old = CodeHash(rawValue: "aa01")
    private let new = CodeHash(rawValue: "bb02")

    func testStoredEmptyCodeMeansNeverRegistered() {
        XCTAssertNil(CodeHash(rawValue: ""))
        XCTAssertEqual(CodeHash(rawValue: "aa01")?.rawValue, "aa01")
    }

    func testPlan() {
        let cases: [(String, Bool, SMAppService.Status, CodeHash?, CodeHash?, WatchdogSync)] = [
            ("enabled, same signature", true, .enabled, old, old, .keep),
            ("signature changed", true, .enabled, old, new, .reregister),
            ("registered before hashes were stored", true, .enabled, nil, new, .reregister),
            ("unsigned build, registered unsigned", true, .enabled, nil, nil, .keep),
            ("not registered", true, .notRegistered, old, old, .register),
            ("awaiting approval", true, .requiresApproval, old, old, .register),
            ("disabled, still enabled", false, .enabled, old, old, .unregister),
            ("disabled, awaiting approval", false, .requiresApproval, old, new, .unregister),
            ("disabled, not registered", false, .notRegistered, old, new, .keep),
        ]
        for (name, enabled, service, registered, own, expected) in cases {
            XCTAssertEqual(WatchdogSync.plan(enabled: enabled, service: service, registered: registered, own: own),
                           expected, name)
        }
    }

    func testStatus() {
        let failed = WatchdogSyncOutcome.failed(reason: "boom")
        let cases: [(Bool, WatchdogSyncOutcome, SMAppService.Status, WatchdogStatus)] = [
            (false, failed, .enabled, .off),
            (true, failed, .enabled, .unavailable("boom")),
            (true, .synced, .enabled, .active),
            (true, .synced, .requiresApproval, .needsApproval),
            (true, .synced, .notRegistered, .unavailable("Not registered")),
        ]
        for (enabled, outcome, service, expected) in cases {
            XCTAssertEqual(WatchdogStatus(enabled: enabled, outcome: outcome, service: service), expected,
                           "\(enabled) \(outcome) \(service)")
        }
    }
}
