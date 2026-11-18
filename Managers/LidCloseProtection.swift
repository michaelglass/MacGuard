// LidCloseProtection.swift
// MacGuard - Anti-Theft Alarm for macOS

import Combine
import Darwin
import Foundation

/// Runs `SleepHold`: one admin prompt per launch starts the root watcher, and sleep is
/// disabled only while the alarm is not idle.
@MainActor
final class LidCloseProtection: ObservableObject {
    static let shared = LidCloseProtection()

    @Published private(set) var model = SleepHold.Model()
    private var pipe: WatcherPipe?
    private var guarding: AnyCancellable?

    private init() {}

    /// Called after any tamper resume, so the prompt never delays the alarm.
    func start(watching alarm: AlarmStateManager) {
        guarding = alarm.$state
            .map { $0 != .idle }
            .removeDuplicates()
            .sink { [weak self] in self?.send(.guardingChanged($0)) }
        if AppSettings.shared.lidCloseProtection { send(.enable) }
    }

    func setEnabled(_ enabled: Bool) {
        AppSettings.shared.lidCloseProtection = enabled
        send(enabled ? .enable : .disable)
    }

    /// After a cancelled prompt or a lost watcher.
    func retry() { send(.enable) }

    private func send(_ msg: SleepHold.Msg) {
        let (next, effects) = SleepHold.update(model, msg)
        model = next
        effects.forEach(run)
    }

    private func run(_ effect: SleepHold.Effect) {
        switch effect {
        case .startWatcher:
            startWatcher()
        case .stopWatcher:
            pipe?.close()
            pipe = nil
        case .disableSleep(let disabled):
            if pipe?.send(sleepDisabled: disabled) != true { send(.lost) }
        case .log(let message):
            logActivity(.system, message)
        }
    }

    private func startWatcher() {
        let fifo: ScriptSafePath
        do {
            fifo = try WatcherPipe.makeFIFO(
                in: FileManager.default.temporaryDirectory.appendingPathComponent("MacGuard", isDirectory: true))
        } catch {
            logActivity(.system, "Lid-close protection: could not create its pipe: \(error)")
            send(.refused)
            return
        }
        // osascript rather than NSAppleScript: the prompt waits off the main thread.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", WatcherScript.appleScript(WatcherScript.shell(fifo: fifo))]
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in await self.authorizationEnded(status: status, fifo: fifo) }
        }
        do {
            try process.run()
        } catch {
            unlink(fifo.value)
            logActivity(.system, "Lid-close protection: could not start osascript: \(error)")
            send(.refused)
        }
    }

    private func authorizationEnded(status: Int32, fifo: ScriptSafePath) async {
        guard status == 0 else {
            unlink(fifo.value)
            send(.refused)
            return
        }
        guard let connected = await WatcherPipe.connect(to: fifo) else {
            logActivity(.system, "Lid-close protection: the watcher never opened its pipe")
            send(.refused)
            return
        }
        pipe = connected
        send(.authorized)
    }
}
