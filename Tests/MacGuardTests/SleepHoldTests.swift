// SleepHoldTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest

@testable import MacGuard

private func feed(_ msgs: [SleepHold.Msg], from model: SleepHold.Model = .init()) -> (
    SleepHold.Model, [SleepHold.Effect]
) {
    msgs.reduce((model, [])) { acc, msg in
        let (next, effects) = SleepHold.update(acc.0, msg)
        return (next, acc.1 + effects)
    }
}

private func sleepEffects(_ effects: [SleepHold.Effect]) -> [SleepHold.Effect] {
    effects.filter { if case .log = $0 { return false } else { return true } }
}

final class SleepHoldTests: XCTestCase {
    func testEnablingStartsTheWatcherOnce() {
        let (model, effects) = feed([.enable, .enable])
        XCTAssertEqual(model.link, .authorizing)
        XCTAssertEqual(sleepEffects(effects), [.startWatcher])
    }

    func testSleepIsDisabledOnlyWhileGuarding() {
        let (model, effects) = feed([
            .enable, .authorized, .guardingChanged(true), .guardingChanged(true), .guardingChanged(false),
        ])
        XCTAssertEqual(model.link, .connected(sleepDisabled: false))
        XCTAssertEqual(sleepEffects(effects), [.startWatcher, .disableSleep(true), .disableSleep(false)])
    }

    func testArmingDuringThePromptDisablesSleepOnceConnected() {
        let (model, effects) = feed([.enable, .guardingChanged(true), .authorized])
        XCTAssertEqual(model.link, .connected(sleepDisabled: true))
        XCTAssertEqual(sleepEffects(effects), [.startWatcher, .disableSleep(true)])
    }

    func testIdleConnectionSendsNothing() {
        let (_, effects) = feed([.enable, .authorized])
        XCTAssertEqual(sleepEffects(effects), [.startWatcher])
    }

    func testDisablingDuringThePromptClosesTheLateConnection() {
        let (model, effects) = feed([.enable, .disable, .authorized])
        XCTAssertEqual(model.link, .disabled)
        XCTAssertEqual(sleepEffects(effects), [.startWatcher, .stopWatcher, .stopWatcher])
    }

    func testRefusalAllowsARetry() {
        let (model, effects) = feed([.enable, .refused, .enable])
        XCTAssertEqual(model.link, .authorizing)
        XCTAssertEqual(sleepEffects(effects), [.startWatcher, .startWatcher])
    }

    func testLosingTheWatcherStopsAndAllowsARetry() {
        let (model, effects) = feed([.enable, .authorized, .guardingChanged(true), .lost, .enable])
        XCTAssertEqual(model.link, .authorizing)
        XCTAssertEqual(
            sleepEffects(effects), [.startWatcher, .disableSleep(true), .stopWatcher, .startWatcher])
    }

    func testStaleMessagesAreIgnored() {
        let (model, effects) = feed([.refused, .lost, .disable, .guardingChanged(true)])
        XCTAssertEqual(model.link, .disabled)
        XCTAssertEqual(sleepEffects(effects), [])
    }
}
