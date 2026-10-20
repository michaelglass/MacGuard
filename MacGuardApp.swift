// MacGuardApp.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import SwiftUI

/// App delegate to handle app lifecycle events
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here (not by the SwiftUI scene) so termination can consult it.
    let alarmManager = AlarmStateManager()

    /// While the overlay is up the app is a regular, frontmost app with an
    /// app menu, so ⌘Q would otherwise silence the alarm without authentication.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard alarmManager.state == .idle else {
            ActivityLogManager.shared.log(.system, "Quit blocked - disarm first")
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Reset lid close protection on app exit to restore normal sleep behavior
        if AppSettings.shared.lidCloseProtection {
            AppSettings.shared.resetLidCloseProtection()
        }
    }
}

/// Main entry point for MacGuard menu bar application
@main
struct MacGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Initialize update manager (starts Sparkle auto-update)
    private let updateManager = UpdateManager.shared

    init() {
        // Check for updates on app launch (silent - only shows UI if update available)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            UpdateManager.shared.checkForUpdatesInBackground()
        }
    }

    var body: some Scene {
        // Menu bar app (no main window)
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.alarmManager)
        } label: {
            MenuBarIconView(alarmManager: appDelegate.alarmManager)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Custom menu bar icon view with state-based color tint
struct MenuBarIconView: View {
    @ObservedObject var alarmManager: AlarmStateManager

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(iconColor)
    }

    private var iconName: String {
        switch alarmManager.state.phase {
        case .idle:
            return "shield"
        case .arming, .armed:
            return "shield.fill"
        case .triggered, .alarming:
            return "exclamationmark.shield.fill"
        }
    }

    private var iconColor: Color {
        switch alarmManager.state.phase {
        case .idle:
            return .primary
        case .arming:
            return .secondary
        case .armed:
            return .green
        case .triggered:
            return .orange
        case .alarming:
            return .red
        }
    }
}
