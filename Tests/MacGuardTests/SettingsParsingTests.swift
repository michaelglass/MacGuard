// SettingsParsingTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

final class SettingsParsingTests: XCTestCase {
    func testCountdownDurationParsesOnlyOfferedValues() {
        XCTAssertEqual(CountdownDuration(rawValue: 10), .s10)
        XCTAssertNil(CountdownDuration(rawValue: 7), "unoffered values fall back to the default at the call site")
        XCTAssertNil(CountdownDuration.immediate.countdown)
        XCTAssertEqual(CountdownDuration.s5.countdown?.total, 5)
    }

    func testAlarmVolumeClamps() {
        XCTAssertEqual(AlarmVolume(clamping: 0).value, 0.5)
        XCTAssertEqual(AlarmVolume(clamping: 0.75).value, 0.75)
        XCTAssertEqual(AlarmVolume(clamping: 7).value, 1.0)
        XCTAssertEqual(AlarmVolume(clamping: .nan).value, 1.0)
    }
}
