// SleepWatcherTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest

@testable import MacGuard

/// Runs the real watcher script, unprivileged, against a `pmset` that logs its arguments.
@MainActor
final class SleepWatcherTests: XCTestCase {
    private var directory: URL!
    private var log: URL!
    private var fakePMSet: ScriptSafePath!

    override func setUp() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        directory = base.appendingPathComponent("SleepWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = directory.appendingPathComponent("calls.log")
        let fake = directory.appendingPathComponent("pmset")
        try "#!/bin/sh\necho \"$*\" >> '\(log.path)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        fakePMSet = try XCTUnwrap(ScriptSafePath(fake.path))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func startWatcher(_ fifo: ScriptSafePath) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", WatcherScript.shell(fifo: fifo, pmset: fakePMSet)]
        try process.run()
        return process
    }

    private func calls() throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func waitForExit(_ process: Process) async {
        while process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testAppliesRequestsAndClearsOnStartAndWhenThePipeCloses() async throws {
        let fifo = try WatcherPipe.makeFIFO(in: directory)
        let watcher = try startWatcher(fifo)
        let connected = await WatcherPipe.connect(to: fifo)
        let pipe = try XCTUnwrap(connected)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fifo.value), "the FIFO's name is removed once open")
        XCTAssertTrue(pipe.send(sleepDisabled: true))
        XCTAssertTrue(pipe.send(sleepDisabled: false))
        pipe.close()
        await waitForExit(watcher)

        XCTAssertEqual(
            try calls(),
            ["-a disablesleep 0", "-a disablesleep 1", "-a disablesleep 0", "-a disablesleep 0"])
    }

    func testIgnoresAnythingButZeroAndOne() async throws {
        let fifo = try WatcherPipe.makeFIFO(in: directory)
        let watcher = try startWatcher(fifo)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: fifo.value))
        handle.write(Data("1; rm -rf /\n$(id)\n1\n".utf8))
        try handle.close()
        await waitForExit(watcher)

        XCTAssertEqual(try calls(), ["-a disablesleep 0", "-a disablesleep 1", "-a disablesleep 0"])
    }

    func testAWatcherThatDiedFailsTheNextSend() async throws {
        let fifo = try WatcherPipe.makeFIFO(in: directory)
        let watcher = try startWatcher(fifo)
        let connected = await WatcherPipe.connect(to: fifo)
        let pipe = try XCTUnwrap(connected)
        watcher.terminate()
        await waitForExit(watcher)

        XCTAssertFalse(pipe.send(sleepDisabled: true))
        pipe.close()
    }

    func testConnectGivesUpWithoutAWatcher() async throws {
        let fifo = try WatcherPipe.makeFIFO(in: directory)
        let pipe = await WatcherPipe.connect(to: fifo, timeout: .milliseconds(300))
        XCTAssertNil(pipe)
    }

    func testUnsafePathsAreRejected() {
        XCTAssertNil(ScriptSafePath("relative/path"))
        XCTAssertNil(ScriptSafePath("/tmp/it's"))
        XCTAssertNil(ScriptSafePath("/tmp/a b"))
        XCTAssertNil(ScriptSafePath("/tmp/$(id)"))
        XCTAssertNil(ScriptSafePath("/tmp/a\"b"))
        XCTAssertNotNil(ScriptSafePath("/var/folders/ab/x_y-z/T/MacGuard/sleep-1.fifo"))
    }

    func testAppleScriptCarriesTheShellUnchanged() throws {
        let fifo = try XCTUnwrap(ScriptSafePath("/tmp/x.fifo"))
        let shell = WatcherScript.shell(fifo: fifo)
        let script = WatcherScript.appleScript(shell)
        XCTAssertTrue(script.hasPrefix("do shell script \"/usr/bin/nohup /bin/sh -c '\(shell)'"))
        XCTAssertTrue(script.hasSuffix("with administrator privileges"))
        XCTAssertFalse(shell.contains("'"))
        XCTAssertFalse(shell.contains("\""))
    }
}
