// Fixtures.swift
// MacGuard - Anti-Theft Alarm for macOS

@testable import MacGuard

extension AlarmEnvironment {
    /// The one place tests build an environment; defaults match the app's.
    static func fixture(
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
            countdown: Countdown(seconds: countdown), autoLockOnArm: autoLock,
            proximity: proximity,
            usbTriggerEnabled: usb, networkTriggerEnabled: network,
            motionTriggerEnabled: motion, lidAngleTriggerEnabled: lidAngle,
            autoArmOnScreenLock: lockArms, exitDelay: exitDelay
        )
    }
}

extension ProximityEvidence {
    static func devices(_ mode: AutoArmMode = .allDevicesAway, nearby: Presence = .none,
                        autoArm: AutoArm = .off) -> ProximityEvidence {
        .trusted(TrustedDeviceEvidence(mode: mode, presence: nearby, autoArm: autoArm))
    }

    static let autoArmStable = devices(autoArm: .onDeviceLeave(.stable))
}
