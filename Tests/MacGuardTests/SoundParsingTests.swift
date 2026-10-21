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

    func testMissingFileIsRejected() {
        XCTAssertNil(PlayableSound(url: scratch.appendingPathComponent("gone.mp3")))
    }

    func testNonAudioFileIsRejected() throws {
        let fake = scratch.appendingPathComponent("not-audio.mp3")
        try Data("definitely not audio".utf8).write(to: fake)
        XCTAssertNil(PlayableSound(url: fake))
    }

    func testEmptyFileIsRejected() throws {
        let empty = scratch.appendingPathComponent("empty.aiff")
        try Data().write(to: empty)
        XCTAssertNil(PlayableSound(url: empty))
    }

    func testPickerOffersCustomAndOnlyPlayableBuiltIns() {
        XCTAssertTrue(AlarmSound.offered.contains(.custom))
        for sound in AlarmSound.offered where sound != .custom {
            XCTAssertNotNil(sound.file, "\(sound)")
        }
    }
}
