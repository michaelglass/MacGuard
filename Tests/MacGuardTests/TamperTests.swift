// TamperTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import ServiceManagement
import XCTest
@testable import MacGuard

final class TamperMachineTests: XCTestCase {
    private let left = ArmSession(departed: [TrustedDevice.phone.id])

    private let env = AlarmEnvironment.fixture()

    func testArmingPersistsTheMarker() {
        let effects = AlarmMachine.update(.fixture(.arming(left, until: AlarmEnvironment.t0, origin: .deviceLeft)), .inputMonitoringStarted(true), env).1
        XCTAssertEqual(effects.first, .persistArmedMarker(left))
    }

    func testEveryStandDownClearsTheMarker() {
        let standDowns: [(AlarmState, AlarmMachine.Msg)] = [
            (.arming(.noDepartures, until: AlarmEnvironment.t0, origin: .manual), .cancelArming),
            (.arming(.noDepartures, until: AlarmEnvironment.t0, origin: .manual), .inputMonitoringStarted(false)),
            (.armed(left), .proximity(.seen(.phone, .nearby))),
            (.alarming(left, .tamper), .systemWoke),
        ]
        for (state, input) in standDowns {
            let (next, effects) = AlarmMachine.update(.fixture(state, presence: [.phone: .seen(.nearby)]), input, .fixture(countdown: 0))
            XCTAssertEqual(next.alarm, .idle, "\(state) + \(input)")
            for required: AlarmMachine.Effect in [.stopCountdownTimer, .stopMonitors, .stopAlarm, .hideOverlay,
                                          .clearArmedMarker, .endOwnerChallenge] {
                XCTAssertTrue(effects.contains(required), "\(state) + \(input): \(required)")
            }
        }
    }

    /// Sounds at once with the stored session: a killed manual arm gains no proximity-disarm rights.
    func testResumeAfterTamperSoundsWithTheStoredSession() {
        for session in [left, .noDepartures] {
            let (model, effects) = AlarmMachine.update(.initial, .resumeAfterTamper(session), env)
            XCTAssertEqual(model.alarm, .alarming(session, .tamper))
            for required: AlarmMachine.Effect in [.persistArmedMarker(session), .startSystemMonitors, .showOverlay,
                                          .playAlarm, .emit(.alarmSounding(.tamper))] {
                XCTAssertTrue(effects.contains(required), "\(session): \(required)")
            }
        }
    }

    func testResumeIgnoredWhenAlreadyActive() {
        XCTAssertEqual(AlarmMachine.update(.fixture(.armed(.noDepartures)), .resumeAfterTamper(left), env).0.alarm, .armed(.noDepartures))
    }
}

final class LaunchDecisionTests: XCTestCase {
    private let phoneLeft = ArmSession(departed: [TrustedDevice.phone.id])

    private func markerData(_ session: ArmSession, pid: Int32) throws -> Data {
        try TamperGuard.encoder.encode(ArmedMarker(session: session, pid: pid))
    }

    func testDecision() throws {
        let cases: [(String, Data?, Bool, LaunchDecision)] = [
            ("no marker", nil, false, .normal),
            ("dead owner", try markerData(phoneLeft, pid: 4242), false, .resumeAfterTamper(phoneLeft)),
            ("live owner", try markerData(.noDepartures, pid: 4242), true, .normal),
            ("corrupt marker fails closed", Data("garbage".utf8), true,
             .resumeAfterTamper(.noDepartures)),
            ("pre-upgrade marker fails closed", Data(#"{"trustedDeviceHasLeft":true,"armedAt":0,"pid":4242}"#.utf8), false,
             .resumeAfterTamper(.noDepartures)),
            ("flat departed marker fails closed",
             Data(#"{"departed":["\#(TrustedDevice.phone.id)"],"armedAt":0,"pid":4242}"#.utf8), false,
             .resumeAfterTamper(.noDepartures)),
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
        let cases: [(Bool, SMAppService.Status, WatchdogStatus)] = [
            (false, .enabled, .off),
            (true, .enabled, .active),
            (true, .requiresApproval, .needsApproval),
            (true, .notRegistered, .unavailable("Not registered")),
        ]
        for (enabled, service, expected) in cases {
            XCTAssertEqual(WatchdogStatus(enabled: enabled, service: service), expected, "\(enabled) \(service)")
        }
    }
}
