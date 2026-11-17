// ScreenUnderMouse.swift
// MacGuard - Anti-Theft Alarm for macOS

import AppKit

extension NSScreen {
    /// The display the user is looking at. `NSScreen.main` follows the key window,
    /// which for a background menu-bar app can be any display.
    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) } ?? main ?? screens.first
    }
}
