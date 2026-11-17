// DeviceScannerTests.swift
// MacGuard - Anti-Theft Alarm for macOS

import XCTest
@testable import MacGuard

private let address = BluetoothAddress("aa:bb:cc:dd:ee:ff")!
private let p1 = UUID()
private let p2 = UUID()

private func paired(_ name: String, address: BluetoothAddress? = address,
                    connected: Bool = false, dBm: Int? = nil) -> DiscoveredDevice {
    DiscoveredDevice(id: UUID(), name: name, classicAddress: address,
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
        XCTAssertEqual(effects, [.bound(name: "mike's iphone", peripheral: p1)])
    }

    // S12: a second peripheral with the same name unbinds, and the name never binds again
    func testSecondPeripheralWithSameNameUnbindsForGood() {
        let (scan, effects) = feed([
            .pairedLoaded([paired("Phone")]), ad("Phone", p1), ad("Phone", p2), ad("Phone", p1),
        ])
        XCTAssertEqual(scan.devices[0].tracking, .classic(address))
        XCTAssertEqual(effects, [.bound(name: "Phone", peripheral: p1), .unboundAmbiguous(name: "Phone")])
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
        let (bound, _) = feed([.pairedLoaded([classic]), ad("Phone", p1)])
        typealias Refusal = BluetoothProximityManager.Refusal
        let cases: [(DiscoveredDevice, Refusal?, DiscoveredDevice.RowState)] = [
            (classic, nil, .selectable(TrustedDevice(id: classic.id, name: "Phone",
                                                     transport: .classic(address: address)))),
            (bound.devices[0], nil, .selectable(TrustedDevice(id: p1, name: "Phone", transport: .ble))),
            (classic, .alreadyTrusted, .alreadyAdded),
            (classic, .full, .unavailable),
            (paired("Phone", address: nil), nil, .unavailable),
        ]
        for (device, refusal, expected) in cases {
            XCTAssertEqual(device.rowState { _, _ in refusal }, expected)
        }
    }

    func testBoundDeviceIsAdmittedByPeripheralIDAndPairedAddress() {
        let (scan, _) = feed([.pairedLoaded([paired("Phone")]), ad("Phone", p1)])
        var asked: (UUID, BluetoothAddress?)?
        _ = scan.devices[0].rowState { id, addr in asked = (id, addr); return nil }
        XCTAssertEqual(asked?.0, p1)
        XCTAssertEqual(asked?.1, address)
    }
}
