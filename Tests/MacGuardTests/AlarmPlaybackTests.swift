// AlarmPlaybackTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

final class AlarmPlaybackTests: XCTestCase {
    private typealias P = AlarmPlayback<String>
    private typealias State = P.State
    private typealias Cmd = P.Cmd

    private let speaker = AudioDevice(1)!
    private let usb = AudioDevice(2)!
    private let headphones = AudioDevice(3)!

    private func read(_ device: AudioDevice, _ volume: Float? = 0.3, muted: Bool = false) -> P.Reading {
        P.Reading(device: device, volume: volume, isMuted: muted)
    }

    private func start(speaker: P.Reading?, output: P.Reading?) -> P.Start {
        P.Start(targetVolume: 1.0, speaker: speaker, output: output)
    }

    private func update(_ state: State, _ msg: P.Msg) -> (State, [Cmd]) {
        P.update(state, msg)
    }

    /// Starts from a pre-loaded sound and returns the playing state.
    private func playing(_ start: P.Start) -> State {
        update(.idle(prepared: "siren"), .start(start)).0
    }

    private func restores(_ cmds: [Cmd]) -> [Cmd] {
        cmds.filter {
            if case .setOutputVolume = $0 { return true }
            if case .setDefaultOutput = $0 { return true }
            return false
        }
    }

    // MARK: Preparation

    func testPrepareLoadsOnce() {
        XCTAssertEqual(update(.idle(prepared: nil), .prepare).1, [.preload])
        XCTAssertEqual(update(.idle(prepared: nil), .preloaded("siren")).0, .idle(prepared: "siren"))
        XCTAssertEqual(update(.idle(prepared: "siren"), .prepare).1, [])
    }

    func testUnprepareIsIgnoredWhilePlaying() {
        let state = playing(start(speaker: read(speaker), output: read(speaker)))
        XCTAssertEqual(update(state, .unprepare).0, state)
        XCTAssertEqual(update(.idle(prepared: "siren"), .unprepare).0, .idle(prepared: nil))
    }

    // MARK: Start

    func testStartWithoutPreparedSoundLoadsItFirst() {
        let s = start(speaker: read(speaker), output: read(speaker))
        XCTAssertEqual(update(.idle(prepared: nil), .start(s)).1, [.loadSound(then: s)])
        let (state, cmds) = update(.idle(prepared: nil), .soundLoaded("siren", then: s))
        XCTAssertTrue(cmds.contains(.playSound("siren")))
        guard case .playing = state else { return XCTFail("not playing") }
    }

    func testBeepsWhenNoSoundLoads() {
        let s = start(speaker: read(speaker), output: read(speaker))
        let (state, cmds) = update(.idle(prepared: nil), .soundLoaded(nil, then: s))
        XCTAssertTrue(cmds.contains(.startBeeping))
        XCTAssertTrue(update(state, .stop).1.contains(.stopBeeping))
    }

    func testStartMovesOutputToSpeakerAndRaisesVolume() {
        let (_, cmds) = update(.idle(prepared: "siren"), .start(start(speaker: read(speaker), output: read(usb))))
        let effects = cmds.filter { if case .log = $0 { return false } else { return true } }
        XCTAssertEqual(effects, [.setDefaultOutput(speaker), .setOutputVolume(1.0), .unmuteOutput,
                                 .watch(speaker), .playSound("siren")])
    }

    func testSecondStartIsIgnored() {
        let state = playing(start(speaker: read(speaker), output: read(speaker)))
        XCTAssertEqual(update(state, .start(start(speaker: read(speaker), output: read(usb)))).1, [])
    }

    // MARK: Restore only what changed

    func testStopRestoresVolumeAndDisplacedOutput() {
        // The saved volume is the speaker's: it is the output the alarm raised.
        let state = playing(start(speaker: read(speaker, 0.2), output: read(usb, 0.7)))
        XCTAssertEqual(restores(update(state, .stop).1), [.setOutputVolume(0.2), .setDefaultOutput(usb)])
    }

    func testStopRestoresTableDriven() {
        let cases: [(P.Start, [Cmd])] = [
            (start(speaker: read(speaker, 0.2), output: read(speaker, 0.2)), [.setOutputVolume(0.2)]),
            (start(speaker: nil, output: read(usb, 0.4)), [.setOutputVolume(0.4)]),
            (start(speaker: read(speaker, nil), output: read(usb)), [.setDefaultOutput(usb)]),
            (start(speaker: nil, output: nil), []),
        ]
        for (s, expected) in cases {
            XCTAssertEqual(restores(update(playing(s), .stop).1), expected, "\(s)")
        }
    }

    func testStopFromIdleRestoresNothing() {
        let (state, cmds) = update(.idle(prepared: "siren"), .stop)
        XCTAssertEqual(state, .idle(prepared: nil))
        XCTAssertEqual(cmds, [.log(.alarm, "Alarm stopped")])
    }

    // MARK: While playing

    func testHeadphonesMidAlarmKeepTheSpeaker() {
        let state = playing(start(speaker: read(speaker), output: read(speaker)))
        let (moved, cmds) = update(state, .outputChanged(headphones))
        XCTAssertEqual(cmds.first, .setDefaultOutput(speaker))
        XCTAssertEqual(cmds.last, .readOutput)
        XCTAssertTrue(cmds.contains(.resumeSound("siren")))
        // Still watching the speaker, and the headphones are what stop puts back.
        XCTAssertFalse(update(moved, .outputRead(read(speaker, 1.0))).1.contains { if case .watch = $0 { true } else { false } })
        XCTAssertEqual(restores(update(moved, .stop).1), [.setOutputVolume(0.3), .setDefaultOutput(headphones)])
    }

    func testWithoutSpeakerTheAlarmFollowsTheOutput() {
        let state = playing(start(speaker: nil, output: read(usb)))
        XCTAssertEqual(update(state, .outputChanged(headphones)).1, [.resumeSound("siren"), .readOutput])
        let (followed, cmds) = update(state, .outputRead(read(headphones, 1.0)))
        XCTAssertEqual(cmds, [.watch(headphones)])
        XCTAssertEqual(update(followed, .outputRead(read(headphones, 1.0))).1, [])
    }

    func testEnforcesVolumeAndMute() {
        let state = playing(start(speaker: read(speaker), output: read(speaker)))
        let cases: [(P.Reading, [Cmd])] = [
            (read(speaker, 1.0, muted: true), [.unmuteOutput, .setOutputVolume(1.0)]),
            (read(speaker, 0.5), [.setOutputVolume(1.0)]),
            (read(speaker, 0.96), []),
            (read(speaker, nil), []),
        ]
        for (reading, expected) in cases {
            let effects = update(state, .outputRead(reading)).1.filter { if case .log = $0 { false } else { true } }
            XCTAssertEqual(effects, expected, "\(reading)")
        }
    }

    func testOutputChangesAfterStopAreIgnored() {
        XCTAssertEqual(update(.idle(prepared: nil), .outputChanged(headphones)).1, [])
        XCTAssertEqual(update(.idle(prepared: nil), .outputRead(read(headphones))).1, [])
    }
}
