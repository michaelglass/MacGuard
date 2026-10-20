// TrustedDevice.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import Foundation

/// Represents a trusted Bluetooth device for auto-disarm
/// Supports both BLE devices (iPhone, Watch) and Classic Bluetooth (AirPods, headphones)
struct TrustedDevice: Identifiable, Codable, Hashable {
    /// How the device is tracked. A Classic device always has an address and a
    /// BLE device never does, so "classic without address" is unrepresentable.
    enum Transport: Hashable {
        /// Matched by `CBPeripheral.identifier` (== `TrustedDevice.id`)
        case ble
        /// Matched by IOBluetooth address (e.g., "AA-BB-CC-DD-EE-FF")
        case classic(address: String)
    }

    /// Unique device identifier (Bluetooth UUID for BLE, generated UUID for Classic BT)
    let id: UUID

    /// User-friendly device name
    var name: String

    let transport: Transport

    /// Last measured RSSI value (signal strength) - runtime only, not persisted
    var lastRSSI: Int?

    /// Last time device was seen - runtime only, not persisted
    var lastSeen: Date?

    // Persisted under the original keys so older builds can still read the data
    enum CodingKeys: String, CodingKey {
        case id, name, bluetoothAddress, isClassicBluetooth
    }

    // MARK: - Computed Properties

    var isClassicBluetooth: Bool {
        if case .classic = transport { return true }
        return false
    }

    var classicAddress: String? {
        if case .classic(let address) = transport { return address }
        return nil
    }

    /// SF Symbol icon based on device name
    var icon: String {
        Self.icon(for: name)
    }

    /// Get SF Symbol icon for a device name
    static func icon(for name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("iphone") { return "iphone" }
        if lowered.contains("watch") { return "applewatch" }
        if lowered.contains("ipad") { return "ipad" }
        if lowered.contains("mac") { return "laptopcomputer" }
        if lowered.contains("airpods") { return "airpodspro" }
        if lowered.contains("headphone") || lowered.contains("beats") { return "headphones" }
        return "iphone"
    }

    // MARK: - Initialization

    init(id: UUID, name: String, transport: Transport) {
        self.id = id
        self.name = name
        self.transport = transport
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let isClassic = try container.decodeIfPresent(Bool.self, forKey: .isClassicBluetooth) ?? false
        let address = try container.decodeIfPresent(String.self, forKey: .bluetoothAddress)
        if isClassic, let address {
            transport = .classic(address: address)
        } else {
            // Includes legacy "classic without address" records. Older builds
            // skipped those when polling, and their generated id never matches
            // a peripheral, so they were never detected; decoding them as BLE
            // keeps that behaviour instead of failing the whole array decode.
            transport = .ble
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isClassicBluetooth, forKey: .isClassicBluetooth)
        try container.encodeIfPresent(classicAddress, forKey: .bluetoothAddress)
    }
}
