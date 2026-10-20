// AlarmModelTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

final class CountdownTests: XCTestCase {
    func testNonPositiveDurationMeansImmediateAlarm() {
        XCTAssertNil(Countdown(seconds: 0))
        XCTAssertNil(Countdown(seconds: -3))
    }

    func testTicksDownThenExpires() throws {
        var countdown = try XCTUnwrap(Countdown(seconds: 3))
        XCTAssertEqual(countdown.remaining, 3)
        XCTAssertEqual(countdown.progress, 1.0)

        countdown = try XCTUnwrap(countdown.ticked())
        countdown = try XCTUnwrap(countdown.ticked())
        XCTAssertEqual(countdown.remaining, 1)
        XCTAssertEqual(countdown.total, 3)

        XCTAssertNil(countdown.ticked(), "an expired countdown is not representable")
    }
}

final class PINTests: XCTestCase {
    func testAcceptsFourToEightDigits() {
        XCTAssertNotNil(PIN("1234"))
        XCTAssertNotNil(PIN("12345678"))
    }

    func testRejectsWrongLengthOrNonDigits() {
        XCTAssertNil(PIN("123"))
        XCTAssertNil(PIN("123456789"))
        XCTAssertNil(PIN("12a4"))
        XCTAssertNil(PIN("１２３４"), "full-width digits are not ASCII")
        XCTAssertNil(PIN("١٢٣٤"), "Arabic-Indic digits are not ASCII")
    }
}

final class AlarmStateTests: XCTestCase {
    private let manual = ArmSession(trustedDeviceHasLeft: false)

    func testIdleHasNoSession() {
        XCTAssertNil(AlarmState.idle.session)
        XCTAssertEqual(AlarmState.idle.updatingSession { $0.trustedDeviceHasLeft = true }, .idle)
    }

    func testUpdatingSessionKeepsCaseAndCountdown() throws {
        let countdown = try XCTUnwrap(Countdown(seconds: 5))
        let updated = AlarmState.triggered(manual, countdown)
            .updatingSession { $0.trustedDeviceHasLeft = true }
        XCTAssertEqual(updated, .triggered(ArmSession(trustedDeviceHasLeft: true), countdown))
    }

    func testPhaseIgnoresPayload() throws {
        let countdown = try XCTUnwrap(Countdown(seconds: 5))
        XCTAssertEqual(AlarmState.arming(manual).phase, .arming)
        XCTAssertEqual(AlarmState.triggered(manual, countdown).phase, .triggered)
        XCTAssertEqual(AlarmState.alarming(manual).phase, .alarming)
    }
}
