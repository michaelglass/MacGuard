// SoundParsingTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

final class SoundParsingTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testSystemSoundParses() {
        XCTAssertNotNil(PlayableSound(url: URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")))
    }

    func testRejectsMissingNonAudioAndEmptyFiles() throws {
        try Data("definitely not audio".utf8).write(to: scratch.appendingPathComponent("not-audio.mp3"))
        try Data().write(to: scratch.appendingPathComponent("empty.aiff"))
        for name in ["gone.mp3", "not-audio.mp3", "empty.aiff"] {
            XCTAssertNil(PlayableSound(url: scratch.appendingPathComponent(name)), name)
        }
    }

    func testPickerOffersCustomAndOnlyPlayableBuiltIns() {
        XCTAssertEqual(AlarmSoundMenuItem.offered.last, .custom)
        for case .builtIn(let sound) in AlarmSoundMenuItem.offered {
            XCTAssertNotNil(sound.file, "\(sound)")
        }
    }

    func testUnplayableCustomFallsBackToTheBundledSound() {
        let gone = scratch.appendingPathComponent("gone.mp3")
        let resolved = AlarmSoundChoice.custom(gone).resolved
        XCTAssertEqual(resolved, .customUnavailable(gone))
        XCTAssertEqual(resolved.file, AlarmSound.dontTouchMyMac.file)
        XCTAssertEqual(AlarmSoundMenuItem(resolved), .builtIn(.dontTouchMyMac))
    }

    func testPlayableCustomResolves() {
        let ping = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
        XCTAssertEqual(AlarmSoundChoice.custom(ping).resolved.file?.url, ping)
        XCTAssertEqual(AlarmSoundMenuItem(AlarmSoundChoice.custom(ping).resolved), .custom)
    }
}
