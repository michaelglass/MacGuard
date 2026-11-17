// TrustAdmission.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation

/// Whether a device may join the trusted list.
enum TrustAdmission {
    enum Refusal: Equatable { case alreadyTrusted, full }

    static let maxTrustedDevices = 10

    /// Refused if the id or the paired Classic address is already trusted, or the list is full.
    static func admission(of id: UUID, classicAddress: BluetoothAddress?, in trusted: [TrustedDevice]) -> Refusal? {
        if trusted.contains(where: { $0.id == id || (classicAddress != nil && $0.classicAddress == classicAddress) }) {
            return .alreadyTrusted
        }
        return trusted.count >= maxTrustedDevices ? .full : nil
    }
}
