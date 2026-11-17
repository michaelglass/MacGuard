// CountdownWindowController.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import AppKit
import SwiftUI

/// Custom window that can become key even when borderless
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The fullscreen overlay, kept and reshown (closing it crashed during cleanup).
/// The controls sit on the display under the mouse; every other display gets a
/// blank shield, so nothing behind the alarm is visible or clickable. While it is
/// up the app is in kiosk mode, so it cannot be switched away from or force quit.
@MainActor
final class CountdownWindowController {
    /// Exists only while the overlay is up.
    private struct Shown {
        let screenObserver: NSObjectProtocol
        /// Put back on hide.
        let previousPresentation: NSApplication.PresentationOptions
        var shields: [NSWindow]
    }

    /// Hiding the Dock is what AppKit requires for hiding the menu bar and disabling
    /// process switching; an invalid combination raises, so keep these together.
    static let kiosk: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableProcessSwitching,
        .disableForceQuit, .disableSessionTermination, .disableHideApplication,
    ]

    private let window: KeyableWindow
    private var shown: Shown?

    init(alarmManager: AlarmStateManager) {
        window = KeyableWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        Self.cover(window)
        window.contentViewController = NSHostingController(rootView: CountdownOverlayView(alarmManager: alarmManager))
        window.acceptsMouseMovedEvents = true
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if shown == nil {
            // Displays can be plugged in, removed or rearranged while the alarm is up.
            let observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.coverAllScreens() }
            }
            shown = Shown(screenObserver: observer, previousPresentation: NSApp.presentationOptions, shields: [])
            NSApp.presentationOptions = Self.kiosk
        }
        coverAllScreens()
        window.makeKeyAndOrderFront(nil)
        logActivity(.system, "Countdown overlay shown")
    }

    func hide() {
        if let shown {
            NotificationCenter.default.removeObserver(shown.screenObserver)
            for shield in shown.shields { shield.orderOut(nil) }
            NSApp.presentationOptions = shown.previousPresentation
        }
        shown = nil
        window.orderOut(nil)
        logActivity(.system, "Countdown overlay hidden")
    }

    private func coverAllScreens() {
        guard var current = shown, let controls = NSScreen.underMouse else { return }
        for shield in current.shields { shield.orderOut(nil) }
        window.setFrame(controls.frame, display: true)
        current.shields = NSScreen.screens.filter { $0 != controls }.map { screen in
            let shield = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            Self.cover(shield)
            shield.orderFrontRegardless()
            return shield
        }
        shown = current
    }

    /// Shared by the controls window and the shields, so every display is covered alike.
    private static func cover(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        // On every Space and over full-screen apps, and not moved by a Space switch
        // or Mission Control, so changing Space cannot uncover the desktop.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = NSColor.black.withAlphaComponent(Theme.Opacity.overlayHeavy)
        window.isOpaque = false
    }
}
