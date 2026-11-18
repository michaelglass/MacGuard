// FileVaultTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest

@testable import MacGuard

final class FileVaultTests: XCTestCase {
    func testParsesFdesetupStatus() {
        XCTAssertEqual(FileVaultStatus(fdesetupOutput: "FileVault is On.\n"), .on)
        XCTAssertEqual(FileVaultStatus(fdesetupOutput: "FileVault is Off.\n"), .off)
        XCTAssertEqual(
            FileVaultStatus(fdesetupOutput: "FileVault is On.\nEncryption in progress: Percent completed = 12\n"), .on)
        XCTAssertEqual(
            FileVaultStatus(fdesetupOutput: "FileVault is On.\nDecryption in progress: Percent completed = 40\n"), .off)
        XCTAssertEqual(FileVaultStatus(fdesetupOutput: ""), .unknown)
        XCTAssertEqual(FileVaultStatus(fdesetupOutput: "Error: something\n"), .unknown)
    }

    func testReadsThisMacsStatus() async {
        let status = await FileVaultStatus.current()
        XCTAssertNotEqual(status, .unknown)
    }
}
