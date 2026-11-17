// SettingsParsingTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import Combine
import XCTest

@testable import MacGuard

final class SettingsParsingTests: XCTestCase {
    func testCountdownDurationMapsToCountdown() {
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

final class ProximityDistanceTests: XCTestCase {
    func testEveryDistanceHasAProperBand() {
        let distances =
            ProximityPreset.allCases.map(ProximityDistance.preset)
            + [-200, -100, -65, -55, 0].map { .custom(DetectionRange(clamping: $0)) }
        for distance in distances {
            let band = distance.thresholds
            XCTAssertGreaterThan(band.present, band.away, "\(distance)")
        }
    }

    func testCustomRangeIsClampedToTheSliderRange() {
        XCTAssertEqual(
            ProximityDistance.custom(DetectionRange(clamping: 0)).thresholds,
            ProximityThresholds(present: -50, away: -60))
        XCTAssertEqual(
            ProximityDistance.custom(DetectionRange(clamping: -500)).thresholds,
            ProximityThresholds(present: -95, away: -105))
    }

    func testCustomRangeNamesTheNearestPreset() {
        let cases: [(Int, ProximityPreset?)] = [
            (-55, .near), (-65, .near), (-70, .medium), (-75, .medium),
            (-80, .far), (-90, .far), (-95, nil), (-100, nil),
        ]
        for (dBm, expected) in cases {
            XCTAssertEqual(DetectionRange(clamping: dBm).nearestPreset, expected, "\(dBm)")
        }
    }

    func testStoredFormRoundTripsAndClamps() {
        for distance in ProximityPreset.allCases.map(ProximityDistance.preset) + [.custom(.default)] {
            XCTAssertEqual(ProximityDistance(rawValue: distance.rawValue), distance)
        }
        XCTAssertEqual(ProximityDistance(rawValue: "custom:0"), .custom(DetectionRange(clamping: -55)))
        for junk in ["", "Custom", "custom:", "custom:abc", "Nowhere"] {
            XCTAssertNil(ProximityDistance(rawValue: junk), junk)
        }
    }
}

final class AlarmSoundChoiceTests: XCTestCase {
    func testStoredFormRoundTrips() {
        let choices: [AlarmSoundChoice] =
            AlarmSound.allCases.map(AlarmSoundChoice.builtIn)
            + [.custom(URL(fileURLWithPath: "/Users/me/Music/alarm sound.mp3"))]
        for choice in choices {
            XCTAssertEqual(AlarmSoundChoice(rawValue: choice.rawValue), choice)
        }
        for junk in ["", "Custom...", "custom:", "Kazoo"] {
            XCTAssertNil(AlarmSoundChoice(rawValue: junk), junk)
        }
    }
}

final class SettingsMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SettingsMigrationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func migrated(_ legacy: [String: Any]) -> (AlarmSoundChoice?, ProximityDistance?) {
        for (key, value) in legacy { defaults.set(value, forKey: key) }
        SettingsMigration.run(defaults)
        return (
            defaults.string(forKey: SettingsMigration.alarmSoundKey).flatMap(AlarmSoundChoice.init(rawValue:)),
            defaults.string(forKey: SettingsMigration.proximityDistanceKey).flatMap(ProximityDistance.init(rawValue:))
        )
    }

    func testAlarmSoundMigration() {
        let cases: [([String: Any], AlarmSoundChoice?)] = [
            ([:], nil),
            (["alarmSound": "Ping"], .builtIn(.ping)),
            (["alarmSound": "Ping", "customSoundPath": "/a.mp3"], .builtIn(.ping)),
            (["alarmSound": "Custom...", "customSoundPath": "/a.mp3"], .custom(URL(fileURLWithPath: "/a.mp3"))),
            (["alarmSound": "Custom...", "customSoundPath": ""], .default),
            (["alarmSound": "Custom..."], .default),
            (["alarmSound": "Kazoo"], .default),
        ]
        for (legacy, expected) in cases {
            setUpDefaultsFresh()
            XCTAssertEqual(migrated(legacy).0, expected, "\(legacy)")
        }
    }

    func testProximityMigration() {
        let cases: [([String: Any], ProximityDistance?)] = [
            ([:], nil),
            (["proximityDistance": "Far"], .preset(.far)),
            (["proximityDistance": "Near", "customDetectionRange": -90], .preset(.near)),
            (["proximityDistance": "Custom", "customDetectionRange": -90], .custom(DetectionRange(clamping: -90))),
            (["proximityDistance": "Custom", "customDetectionRange": 0], .custom(DetectionRange(clamping: -55))),
            (["proximityDistance": "Custom"], .custom(.default)),
            (["proximityDistance": "Nowhere"], .default),
        ]
        for (legacy, expected) in cases {
            setUpDefaultsFresh()
            XCTAssertEqual(migrated(legacy).1, expected, "\(legacy)")
        }
    }

    func testMigrationRemovesLegacyKeysAndKeepsNewValues() {
        defaults.set("Tink", forKey: SettingsMigration.alarmSoundKey)
        defaults.set("custom:-80", forKey: SettingsMigration.proximityDistanceKey)
        let (sound, distance) = migrated([
            "alarmSound": "Ping", "customSoundPath": "/a.mp3",
            "proximityDistance": "Near", "customDetectionRange": -90,
            "autoArmMode": "any",
        ])
        XCTAssertEqual(sound, .builtIn(.tink))
        XCTAssertEqual(distance, .custom(DetectionRange(clamping: -80)))
        for key in ["alarmSound", "customSoundPath", "proximityDistance", "customDetectionRange", "autoArmMode"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }

    func testTrustedDeviceMigration() throws {
        let legacyKey = "MacGuard.trustedDevice"
        let legacy = try JSONEncoder().encode(TrustedDevice.phone)
        let other = TrustedDevice(id: UUID(), name: "Watch", transport: .ble)
        let current = try JSONEncoder().encode([other])
        let cases: [(String, Data?, [TrustedDevice]?, Bool)] = [
            ("single device becomes a list", nil, [.phone], false),
            ("existing list wins", current, [other], true),
            ("unreadable list falls back", Data("garbage".utf8), [.phone], false),
        ]
        for (name, list, expected, legacyKept) in cases {
            setUpDefaultsFresh()
            defaults.set(legacy, forKey: legacyKey)
            if let list { defaults.set(list, forKey: SettingsMigration.trustedDevicesKey) }
            SettingsMigration.run(defaults)
            let stored = try defaults.data(forKey: SettingsMigration.trustedDevicesKey)
                .map { try JSONDecoder().decode([TrustedDevice].self, from: $0) }
            XCTAssertEqual(stored, expected, name)
            XCTAssertEqual(defaults.object(forKey: legacyKey) != nil, legacyKept, name)
        }
    }

    private func setUpDefaultsFresh() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

final class SettingsPublishingTests: XCTestCase {
    /// AlarmStateManager re-plans idle scanning on AppSettings.objectWillChange,
    /// which relies on @AppStorage publishing from inside an ObservableObject.
    @MainActor
    func testEnumSettingChangePublishes() {
        let settings = AppSettings.shared
        let original = settings.exitDelay
        defer { settings.exitDelay = original }
        var fired = 0
        let subscription = settings.objectWillChange.sink { fired += 1 }
        settings.exitDelay = original == .s30 ? .s10 : .s30
        subscription.cancel()
        XCTAssertGreaterThan(fired, 0)
    }
}
