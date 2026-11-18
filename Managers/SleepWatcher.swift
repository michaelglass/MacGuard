// SleepWatcher.swift
// MacGuard - Anti-Theft Alarm for macOS

import Darwin
import Foundation

/// A path that can be pasted into shell and AppleScript source unquoted.
struct ScriptSafePath: Equatable, Sendable {
    let value: String

    init?(_ value: String) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        guard value.hasPrefix("/"), value.allSatisfy(allowed.contains) else { return nil }
        self.value = value
    }

    static let pmset = ScriptSafePath("/usr/bin/pmset")!
}

/// The root side of `SleepHold`, as shell source. It is the whole privileged program, inlined
/// into the prompt's command so no file an unprivileged process could edit ever runs as root.
enum WatcherScript {
    /// Clears the setting, then applies `1`/`0` lines from the pipe until it closes, then clears
    /// it again. The pipe closes when MacGuard exits for any reason.
    static func shell(fifo: ScriptSafePath, pmset: ScriptSafePath = .pmset) -> String {
        let set = "\(pmset.value) -a disablesleep"
        return
            "\(set) 0; while read -r l; do case $l in 1) \(set) 1;; 0) \(set) 0;; esac; done < \(fifo.value); \(set) 0"
    }

    /// Runs `shell` as root in the background, so the prompt returns once it has started.
    static func appleScript(_ shell: String) -> String {
        let command = "/usr/bin/nohup /bin/sh -c '\(shell)' >/dev/null 2>&1 &"
        let prompt = "MacGuard needs an administrator password to keep the Mac awake when the lid closes while armed."
        return
            "do shell script \"\(escaped(command))\" with prompt \"\(escaped(prompt))\" with administrator privileges"
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// MacGuard's end of the watcher's pipe. Closing it, or MacGuard exiting, ends the watcher.
@MainActor
final class WatcherPipe {
    private var fd: Int32?

    private init(fd: Int32) { self.fd = fd }

    /// A new FIFO in a directory only this user can enter.
    nonisolated static func makeFIFO(in directory: URL) throws -> ScriptSafePath {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let path = ScriptSafePath(directory.appendingPathComponent("sleep-\(UUID().uuidString).fifo").path)
        else { throw POSIXError(.EINVAL) }
        guard mkfifo(path.value, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return path
    }

    /// Waits for the watcher to open its end, then removes the FIFO's name; the open ends keep working.
    static func connect(to fifo: ScriptSafePath, timeout: Duration = .seconds(10)) async -> WatcherPipe? {
        let deadline = ContinuousClock.now + timeout
        defer { unlink(fifo.value) }
        while ContinuousClock.now < deadline {
            let fd = open(fifo.value, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                // Blocking writes; a closed reader fails the write with EPIPE instead of a signal.
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                return WatcherPipe(fd: fd)
            }
            guard errno == ENXIO else { return nil }  // ENXIO: no reader yet
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// False when the watcher is gone.
    func send(sleepDisabled: Bool) -> Bool {
        guard let fd else { return false }
        let line = sleepDisabled ? "1\n" : "0\n"
        return line.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, 2) == 2 }
    }

    func close() {
        if let fd { Darwin.close(fd) }
        fd = nil
    }
}
