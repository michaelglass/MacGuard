// TriggerSettingsView.swift
// MacGuard - Anti-Theft Alarm for macOS

import SwiftUI

/// Optional triggers and arming options (rendered inside the Behavior section,
/// which is read-only while armed).
struct TriggerSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Picker("Exit delay", selection: $settings.exitDelay) {
            ForEach(ExitDelay.allCases) { delay in
                Text(delay.label).tag(delay)
            }
        }
        .help("Time between arming and monitoring starting")

        Toggle("Alarm when a USB device is plugged in", isOn: $settings.usbTriggerEnabled)

        Toggle("Alarm when the network connection changes", isOn: $settings.networkTriggerEnabled)
            .help("Wi-Fi dropouts can cause false alarms")

        Toggle("Arm automatically when the screen locks", isOn: $settings.autoArmOnScreenLock)
    }
}
