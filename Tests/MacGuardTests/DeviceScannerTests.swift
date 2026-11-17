// DeviceScannerTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

private let address = BluetoothAddress.sample
private let p1 = TrustedDevice.phone.id
private let p2 = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
private let pairedID = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!

private func paired(_ name: String, address: BluetoothAddress? = address,
                    connected: Bool = false, dBm: Int? = nil) -> DiscoveredDevice {
    DiscoveredDevice(id: pairedID, name: name, classicAddress: address,
                     isConnected: connected, signal: dBm.flatMap(RSSI.init))
}

private func ad(_ name: String, _ peripheral: UUID, _ dBm: Int = -60) -> DeviceScan.Msg {
    .advertised(Advertisement(name: name, peripheral: peripheral, rawRSSI: dBm)!)
}

private func feed(_ msgs: [DeviceScan.Msg]) -> (DeviceScan, [DeviceScan.Effect]) {
    msgs.reduce((DeviceScan(), [])) { acc, msg in
        let (model, effects) = DeviceScan.update(acc.0, msg)
        return (model, acc.1 + effects)
    }
}

final class DeviceScannerTests: XCTestCase {
    func testUniqueNameBindsToPeripheralCaseInsensitively() {
        let (scan, effects) = feed([.pairedLoaded([paired("Mike's iPhone")]), ad("mike's iphone", p1, -55)])
        XCTAssertEqual(scan.devices[0].tracking, .ble(peripheral: p1))
        XCTAssertEqual(scan.devices[0].signal, RSSI(-55))
        XCTAssertEqual(effects, [.log(.bluetooth, "Device mike's iphone found via BLE, UUID: \(p1)")])
    }

    // S12: a second peripheral with the same name unbinds, and the name never binds again
    func testSecondPeripheralWithSameNameUnbindsForGood() {
        let (scan, effects) = feed([
            .pairedLoaded([paired("Phone")]), ad("Phone", p1), ad("Phone", p2), ad("Phone", p1),
        ])
        XCTAssertEqual(scan.devices[0].tracking, .classic(address))
        XCTAssertEqual(effects, [
            .log(.bluetooth, "Device Phone found via BLE, UUID: \(p1)"),
            .log(.bluetooth, "Multiple BLE peripherals named Phone - keeping Classic tracking"),
        ])
    }

    func testAmbiguousNameWithoutAddressIsUntrackable() {
        let (scan, _) = feed([.pairedLoaded([paired("Phone", address: nil)]), ad("Phone", p1), ad("Phone", p2)])
        XCTAssertEqual(scan.devices[0].tracking, .untrackable)
    }

    func testUnpairedAdvertisementsAreIgnored() {
        let (scan, effects) = feed([.pairedLoaded([paired("Phone")]), ad("Stranger", p1)])
        XCTAssertEqual(scan.devices.map(\.tracking), [.classic(address)])
        XCTAssertEqual(effects, [])
    }

    func testAdvertisementParsing() {
        XCTAssertNil(Advertisement(name: nil, peripheral: p1, rawRSSI: -50))
        XCTAssertNil(Advertisement(name: "", peripheral: p1, rawRSSI: -50))
        XCTAssertNil(Advertisement(name: "x", peripheral: p1, rawRSSI: -90))
        // 127 means "no reading": still counts toward the name, but carries no signal
        XCTAssertNil(Advertisement(name: "x", peripheral: p1, rawRSSI: 127)?.signal)
    }

    func testNoReadingKeepsPreviousSignal() {
        let (scan, _) = feed([.pairedLoaded([paired("Phone", connected: true, dBm: -65)]), ad("Phone", p1, 127)])
        XCTAssertEqual(scan.devices[0].signal, RSSI(-65))
    }

    func testOrderConnectedFirstThenSignalThenNoReading() {
        let (scan, _) = feed([.pairedLoaded([
            paired("none"), paired("weak", dBm: -80), paired("conn", connected: true), paired("strong", dBm: -40),
        ])])
        XCTAssertEqual(scan.devices.map(\.name), ["conn", "strong", "weak", "none"])
    }

    func testRowState() {
        let classic = paired("Phone")
        let (scan, _) = feed([.pairedLoaded([classic]), ad("Phone", p1)])
        let bound = scan.devices[0]
        let cases: [(DiscoveredDevice, [TrustedDevice], DiscoveredDevice.RowState)] = [
            (classic, [], .selectable(trustedClassic)),
            (bound, [], .selectable(.phone)),
            (classic, [trustedClassic], .alreadyAdded),
            (classic, full, .unavailable),
            (paired("Phone", address: nil), [], .unavailable),
            // A bound device is admitted by peripheral id and by its paired Classic address
            (bound, [.phone], .alreadyAdded),
            (bound, [trustedClassic], .alreadyAdded),
        ]
        for (device, trusted, expected) in cases {
            XCTAssertEqual(device.rowState(trusted: trusted), expected)
        }
    }
}

private let trustedClassic = TrustedDevice(id: pairedID, name: "Phone", transport: .classic(address: address))
private let full = (0..<TrustAdmission.maxTrustedDevices).map {
    TrustedDevice(id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", $0))!,
                  name: "d\($0)", transport: .ble)
}

final class TrustAdmissionTests: XCTestCase {
    func testAdmission() {
        let other = p2
        let cases: [(UUID, BluetoothAddress?, [TrustedDevice], TrustAdmission.Refusal?)] = [
            (other, nil, [], nil),
            (p1, nil, [.phone], .alreadyTrusted),
            (other, address, [trustedClassic], .alreadyTrusted),
            // No address never matches a BLE device's missing address
            (other, nil, [.phone], nil),
            (other, nil, full, .full),
            (full[0].id, nil, full, .alreadyTrusted),
        ]
        for (id, classicAddress, trusted, expected) in cases {
            XCTAssertEqual(TrustAdmission.admission(of: id, classicAddress: classicAddress, in: trusted), expected)
        }
    }
}
