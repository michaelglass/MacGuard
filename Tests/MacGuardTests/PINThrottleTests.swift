// PINThrottleTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

final class PINThrottleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFreeAttemptsDoNotLockOut() {
        var throttle = PINThrottle()
        for _ in 0..<PINThrottle.freeAttempts {
            XCTAssertNil(throttle.recordFailure(at: t0))
        }
        XCTAssertNil(throttle.lockout(at: t0))
    }

    func testLockoutDoublesAndExpires() {
        var throttle = PINThrottle()
        for _ in 0..<PINThrottle.freeAttempts { _ = throttle.recordFailure(at: t0) }

        XCTAssertEqual(throttle.recordFailure(at: t0), t0.addingTimeInterval(30))
        XCTAssertEqual(throttle.lockout(at: t0.addingTimeInterval(29)), t0.addingTimeInterval(30))
        XCTAssertNil(throttle.lockout(at: t0.addingTimeInterval(30)), "lockout ends exactly at its deadline")

        let t1 = t0.addingTimeInterval(30)
        XCTAssertEqual(throttle.recordFailure(at: t1), t1.addingTimeInterval(60))
    }

    func testLockoutIsCapped() {
        var throttle = PINThrottle()
        var until: Date?
        for _ in 0..<50 { until = throttle.recordFailure(at: t0) }
        XCTAssertEqual(until, t0.addingTimeInterval(30 * 1024))
    }

    func testSuccessResets() {
        var throttle = PINThrottle()
        for _ in 0..<5 { _ = throttle.recordFailure(at: t0) }
        throttle.recordSuccess()
        XCTAssertEqual(throttle, PINThrottle())
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(AuthManager.constantTimeEquals(Data("1234".utf8), Data("1234".utf8)))
        XCTAssertFalse(AuthManager.constantTimeEquals(Data("1234".utf8), Data("1235".utf8)))
        XCTAssertFalse(AuthManager.constantTimeEquals(Data("1234".utf8), Data("12345".utf8)))
    }
}
