// DeviceScan.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation

/// A paired device as the scanner sees it.
struct DiscoveredDevice: Identifiable, Equatable {
    enum Tracking: Equatable {
        case ble(peripheral: UUID)
        case classic(BluetoothAddress)
        /// Classic with no address and no unique BLE match: could never be detected
        case untrackable
    }

    let id: UUID
    let name: String
    /// As paired; also checked against already-trusted Classic devices when tracked via BLE
    let classicAddress: BluetoothAddress?
    let isConnected: Bool
    fileprivate(set) var signal: RSSI?
    /// `.ble` only while exactly one BLE peripheral advertises this name
    fileprivate(set) var tracking: Tracking

    init(id: UUID, name: String, classicAddress: BluetoothAddress?, isConnected: Bool, signal: RSSI?) {
        self.id = id
        self.name = name
        self.classicAddress = classicAddress
        self.isConnected = isConnected
        self.signal = signal
        self.tracking = Self.pairedTracking(classicAddress)
    }

    /// Tracking without a BLE binding.
    fileprivate static func pairedTracking(_ classicAddress: BluetoothAddress?) -> Tracking {
        classicAddress.map(Tracking.classic) ?? .untrackable
    }

    enum RowState: Equatable {
        case selectable(TrustedDevice)
        case alreadyAdded
        case unavailable
    }

    func rowState(trusted devices: [TrustedDevice]) -> RowState {
        let trusted: TrustedDevice
        switch tracking {
        case .ble(let peripheral):
            trusted = TrustedDevice(id: peripheral, name: name, transport: .ble)
        case .classic(let address):
            trusted = TrustedDevice(id: id, name: name, transport: .classic(address: address))
        case .untrackable:
            return .unavailable
        }
        // The paired Classic address also counts when tracked via BLE
        switch TrustAdmission.admission(of: trusted.id, classicAddress: classicAddress, in: devices) {
        case .alreadyTrusted?: return .alreadyAdded
        case .full?: return .unavailable
        case nil: return .selectable(trusted)
        }
    }
}

/// A named BLE advertisement strong enough to count.
struct Advertisement: Equatable {
    let name: String
    let peripheral: UUID
    let signal: RSSI?

    init?(name: String?, peripheral: UUID, rawRSSI: Int) {
        guard let name, !name.isEmpty, rawRSSI > -90 else { return nil }
        self.name = name
        self.peripheral = peripheral
        self.signal = RSSI(rawRSSI)
    }
}

/// The scanner's list: paired devices, bound to a BLE peripheral only while that
/// peripheral is the sole one advertising the (attacker-controlled) name.
struct DeviceScan: Equatable {
    private(set) var devices: [DiscoveredDevice] = []
    private var peripheralsByName: [String: Set<UUID>] = [:]

    enum Msg: Equatable {
        case pairedLoaded([DiscoveredDevice])
        case advertised(Advertisement)
    }

    enum Effect: Equatable {
        case log(ActivityLogCategory, String)
    }

    static func update(_ model: DeviceScan, _ msg: Msg) -> (DeviceScan, [Effect]) {
        var model = model
        var effects: [Effect] = []
        switch msg {
        case .pairedLoaded(let devices):
            model.devices = devices
        case .advertised(let ad):
            let key = ad.name.lowercased()
            let peripherals = model.peripheralsByName[key, default: []].union([ad.peripheral])
            model.peripheralsByName[key] = peripherals
            // Unpaired BLE devices are ignored; only the first same-named paired device binds
            if let index = model.devices.firstIndex(where: { $0.name.lowercased() == key }) {
                if peripherals.count == 1 {
                    model.devices[index].tracking = .ble(peripheral: ad.peripheral)
                    model.devices[index].signal = ad.signal ?? model.devices[index].signal
                    effects.append(.log(.bluetooth, "Device \(ad.name) found via BLE, UUID: \(ad.peripheral)"))
                } else if case .ble = model.devices[index].tracking {
                    model.devices[index].tracking = DiscoveredDevice.pairedTracking(model.devices[index].classicAddress)
                    effects.append(.log(.bluetooth, "Multiple BLE peripherals named \(ad.name) - keeping Classic tracking"))
                }
            }
        }
        model.devices.sort(by: listOrder)
        return (model, effects)
    }

    /// Connected first, then strongest signal; no reading sorts last.
    private static func listOrder(_ a: DiscoveredDevice, _ b: DiscoveredDevice) -> Bool {
        if a.isConnected != b.isConnected { return a.isConnected }
        switch (a.signal, b.signal) {
        case let (a?, b?): return a > b
        case (_?, nil): return true
        case (nil, _): return false
        }
    }
}
