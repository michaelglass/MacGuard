// FileVault.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation

/// Without FileVault a thief can read the disk from Recovery or another Mac, and on a Mac
/// that logs in automatically, a forced restart lands in the owner's session.
enum FileVaultStatus: Equatable, Sendable {
    case on
    /// Off, or being turned off.
    case off
    /// `fdesetup` failed or printed something unrecognised.
    case unknown

    init(fdesetupOutput output: String) {
        if output.contains("Decryption in progress") {
            self = .off
        } else if output.hasPrefix("FileVault is On.") {
            self = .on
        } else if output.hasPrefix("FileVault is Off.") {
            self = .off
        } else {
            self = .unknown
        }
    }

    /// `fdesetup status` needs no privileges.
    static func current() async -> FileVaultStatus {
        await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
            process.arguments = ["status"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return .unknown }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .unknown }
            return FileVaultStatus(fdesetupOutput: String(decoding: data, as: UTF8.self))
        }.value
    }
}
