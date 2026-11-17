// AlarmPlaybackTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

final class AlarmPlaybackTests: XCTestCase {
    private typealias P = AlarmPlayback<String>
    private typealias Model = P.Model
    private typealias Effect = P.Effect

    private let speaker = AudioDevice(1)!
    private let usb = AudioDevice(2)!
    private let headphones = AudioDevice(3)!

    private func read(_ device: AudioDevice, _ volume: Float? = 0.3, muted: Bool = false) -> P.Reading {
        P.Reading(device: device, volume: volume, isMuted: muted)
    }

    private func start(speaker: P.Reading?, output: P.Reading?) -> P.Start {
        P.Start(targetVolume: 1.0, speaker: speaker, output: output)
    }

    private func update(_ model: Model, _ msg: P.Msg) -> (Model, [Effect]) {
        P.update(model, msg)
    }

    /// Starts from a pre-loaded sound and returns the playing state.
    private func playing(_ start: P.Start) -> Model {
        update(.idle(prepared: "siren"), .start(start)).0
    }

    private func restores(_ effects: [Effect]) -> [Effect] {
        effects.filter {
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
        let (state, effects) = update(.idle(prepared: nil), .soundLoaded("siren", then: s))
        XCTAssertTrue(effects.contains(.playSound("siren")))
        guard case .playing = state else { return XCTFail("not playing") }
    }

    func testBeepsWhenNoSoundLoads() {
        let s = start(speaker: read(speaker), output: read(speaker))
        let (state, effects) = update(.idle(prepared: nil), .soundLoaded(nil, then: s))
        XCTAssertTrue(effects.contains(.startBeeping))
        XCTAssertTrue(update(state, .stop).1.contains(.stopBeeping))
    }

    func testStartMovesOutputToSpeakerAndRaisesVolume() {
        let (_, effects) = update(.idle(prepared: "siren"), .start(start(speaker: read(speaker), output: read(usb))))
        let actions = effects.filter { if case .log = $0 { return false } else { return true } }
        XCTAssertEqual(actions, [.recordRestore(AudioRestore(displaced: usb, volume: 0.3)),
                                 .setDefaultOutput(speaker), .setOutputVolume(1.0), .unmuteOutput,
                                 .watch(speaker), .playSound("siren")])
    }

    /// The record comes before any change, and matches what stop restores.
    func testStartRecordsTheRestoreFirst() {
        let cases: [(P.Start, AudioRestore)] = [
            (start(speaker: read(speaker, 0.2), output: read(usb, 0.7)), AudioRestore(displaced: usb, volume: 0.2)),
            (start(speaker: read(speaker, 0.2), output: read(speaker, 0.2)), AudioRestore(displaced: nil, volume: 0.2)),
            (start(speaker: nil, output: read(usb, nil)), AudioRestore(displaced: nil, volume: nil)),
        ]
        for (s, expected) in cases {
            XCTAssertEqual(update(.idle(prepared: "siren"), .start(s)).1.first, .recordRestore(expected), "\(s)")
        }
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
        let cases: [(P.Start, [Effect])] = [
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
        let (state, effects) = update(.idle(prepared: "siren"), .stop)
        XCTAssertEqual(state, .idle(prepared: nil))
        XCTAssertEqual(effects, [.log(.alarm, "Alarm stopped")])
    }

    // MARK: Relaunched after a kill mid-alarm

    /// The killed alarm left the speaker at full volume; stop puts back what it recorded.
    func testInheritedRestoreWinsOverTheCurrentReading() {
        let recorded = AudioRestore(displaced: usb, volume: 0.2)
        let inherited = update(.idle(prepared: nil), .inherit(recorded)).0
        XCTAssertEqual(inherited, .inherited(recorded))
        let s = start(speaker: read(speaker, 1.0), output: read(speaker, 1.0))
        XCTAssertEqual(update(inherited, .start(s)).1, [.loadSound(then: s)])
        let (state, effects) = update(inherited, .soundLoaded("siren", then: s))
        XCTAssertEqual(effects.first, .recordRestore(recorded), "a second kill keeps the originals")
        XCTAssertEqual(restores(update(state, .stop).1), [.setOutputVolume(0.2), .setDefaultOutput(usb)])
    }

    func testInheritedRouteTableDriven() {
        let cases: [(String, AudioRestore, P.Start, AudioRestore)] = [
            ("output moved since the kill, alarm had moved none", AudioRestore(displaced: nil, volume: 0.2),
             start(speaker: read(speaker, 1.0), output: read(headphones)), AudioRestore(displaced: headphones, volume: 0.2)),
            ("recorded output wins over one moved since", AudioRestore(displaced: usb, volume: nil),
             start(speaker: read(speaker, 1.0), output: read(headphones)), AudioRestore(displaced: usb, volume: nil)),
            ("no speaker: nothing to route back through", AudioRestore(displaced: usb, volume: 0.2),
             start(speaker: nil, output: read(usb, 1.0)), AudioRestore(displaced: nil, volume: 0.2)),
        ]
        for (name, recorded, s, expected) in cases {
            let effects = update(.inherited(recorded), .soundLoaded("siren", then: s)).1
            XCTAssertEqual(effects.first, .recordRestore(expected), name)
        }
    }

    func testStopBeforeSoundingAgainUndoesTheKilledAlarm() {
        let (state, effects) = update(.inherited(AudioRestore(displaced: usb, volume: 0.2)), .stop)
        XCTAssertEqual(state, .idle(prepared: nil))
        XCTAssertEqual(restores(effects), [.setOutputVolume(0.2), .setDefaultOutput(usb)])
    }

    // MARK: While playing

    func testHeadphonesMidAlarmKeepTheSpeaker() {
        let state = playing(start(speaker: read(speaker), output: read(speaker)))
        let (moved, effects) = update(state, .outputChanged(headphones))
        XCTAssertEqual(Array(effects.prefix(2)), [.recordRestore(AudioRestore(displaced: headphones, volume: 0.3)),
                                                  .setDefaultOutput(speaker)])
        // The same output again changes nothing that stop restores.
        XCTAssertFalse(update(moved, .outputChanged(headphones)).1.contains { if case .recordRestore = $0 { true } else { false } })
        XCTAssertEqual(effects.last, .readOutput)
        XCTAssertTrue(effects.contains(.resumeSound("siren")))
        // Still watching the speaker, and the headphones are what stop puts back.
        XCTAssertFalse(update(moved, .outputRead(read(speaker, 1.0))).1.contains { if case .watch = $0 { true } else { false } })
        XCTAssertEqual(restores(update(moved, .stop).1), [.setOutputVolume(0.3), .setDefaultOutput(headphones)])
    }

    func testWithoutSpeakerTheAlarmFollowsTheOutput() {
        let state = playing(start(speaker: nil, output: read(usb)))
        XCTAssertEqual(update(state, .outputChanged(headphones)).1, [.resumeSound("siren"), .readOutput])
        let (followed, effects) = update(state, .outputRead(read(headphones, 1.0)))
        XCTAssertEqual(effects, [.watch(headphones)])
        XCTAssertEqual(update(followed, .outputRead(read(headphones, 1.0))).1, [])
    }

    func testEnforcesVolumeAndMute() {
        let state = playing(start(speaker: read(speaker), output: read(speaker)))
        let cases: [(P.Reading, [Effect])] = [
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
