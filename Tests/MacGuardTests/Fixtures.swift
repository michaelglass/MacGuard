// Fixtures.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation

@testable import MacGuard

extension AlarmEnvironment {
    /// The clock every machine fixture runs at.
    static let t0 = Date(timeIntervalSince1970: 0)

    /// The one place tests build an environment; defaults match the app's.
    static func fixture(
        now: Date = t0,
        countdown: Int = 3,
        autoLock: Bool = false,
        autoArm: AutoArm = .off,
        usb: Bool = true,
        network: Bool = false,
        motion: Bool = true,
        lidAngle: Bool = true,
        lockArms: Bool = false,
        exitDelay: ExitDelay = .s1
    ) -> AlarmEnvironment {
        AlarmEnvironment(
            now: now, countdown: Countdown(seconds: countdown), autoLockOnArm: autoLock,
            autoArm: autoArm,
            usbTriggerEnabled: usb, networkTriggerEnabled: network,
            motionTriggerEnabled: motion, lidAngleTriggerEnabled: lidAngle,
            autoArmOnScreenLock: lockArms, exitDelay: exitDelay
        )
    }
}

extension AlarmMachine.Model {
    static func fixture(_ alarm: AlarmState, presence: [TrustedDevice: Presence] = [:]) -> Self {
        Self(alarm: alarm, presence: Dictionary(uniqueKeysWithValues: presence.map { ($0.key.id, $0.value) }))
    }
}

extension TrustedDevice {
    static let phone = TrustedDevice(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: "Phone", transport: .ble)
    static let watch = TrustedDevice(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, name: "Watch", transport: .ble)
}

extension BluetoothAddress {
    static let sample = BluetoothAddress("aa:bb:cc:dd:ee:ff")!
}
