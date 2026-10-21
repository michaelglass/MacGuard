// UtilityWindow.swift
// MacGuard - Anti-Theft Alarm for macOS

import SwiftUI
import AppKit

/// A titled window built once around its SwiftUI content.
@MainActor
final class UtilityWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private weak var parent: NSWindow?
    private let onClose: () -> Void

    init<Content: View>(title: String, size: NSSize,
                        style: NSWindow.StyleMask = [.titled, .closable],
                        transparent: Bool = false,
                        fitsContent: Bool = false,
                        onClose: @escaping () -> Void = {},
                        content: Content) {
        let host = NSHostingController(rootView: content)
        if fitsContent { host.sizingOptions = .preferredContentSize }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = title
        window.isReleasedWhenClosed = false
        if transparent {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        self.onClose = onClose
        super.init()
        window.delegate = self
    }

    /// A menu-bar-only app can't take focus, so it becomes a regular app while a window is open.
    func show() {
        if let key = NSApp.keyWindow, key !== window { parent = key }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        if window.isVisible { window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
        if let parent, parent.isVisible { parent.makeKeyAndOrderFront(nil) }
        // Borderless windows (status item, overlay) don't count as open app windows
        let othersOpen = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        if !othersOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
