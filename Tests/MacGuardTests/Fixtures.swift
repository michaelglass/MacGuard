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
        proximity: ProximityEvidence = .devices(),
        usb: Bool = true,
        network: Bool = false,
        motion: Bool = true,
        lidAngle: Bool = true,
        lockArms: Bool = false,
        exitDelay: ExitDelay = .s1
    ) -> AlarmEnvironment {
        AlarmEnvironment(
            now: now, countdown: Countdown(seconds: countdown), autoLockOnArm: autoLock,
            proximity: proximity,
            usbTriggerEnabled: usb, networkTriggerEnabled: network,
            motionTriggerEnabled: motion, lidAngleTriggerEnabled: lidAngle,
            autoArmOnScreenLock: lockArms, exitDelay: exitDelay
        )
    }
}

extension ProximityEvidence {
    static func devices(_ sightings: [TrustedDevice: Sighting] = [:], autoArm: AutoArm = .off) -> ProximityEvidence {
        .trusted(TrustedDeviceEvidence(
            sightings: Dictionary(uniqueKeysWithValues: sightings.map { ($0.key.id, $0.value) }),
            autoArm: autoArm
        ))
    }

    static let autoArmStable = devices(autoArm: .onDeviceLeave(.stable))
}

extension TrustedDevice {
    static let phone = TrustedDevice(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: "Phone", transport: .ble)
    static let watch = TrustedDevice(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, name: "Watch", transport: .ble)
}
