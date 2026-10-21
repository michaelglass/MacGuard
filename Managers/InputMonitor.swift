// InputMonitor.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import Cocoa
import ApplicationServices

/// User input that counts as an intrusion, parsed from raw `CGEventType`s at the boundary.
enum IntrusionInput: CaseIterable {
    case keyboard, mediaKey, modifier, click, drag, pointerMove, scroll

    /// NX_SYSDEFINED (media, volume, brightness keys); not a named `CGEventType`.
    private static let systemDefinedRawValue: UInt32 = 14

    /// The tap's event mask is derived from these, so mask and parser cannot disagree.
    var eventTypeRawValues: [UInt32] {
        switch self {
        case .keyboard: return [CGEventType.keyDown.rawValue]
        case .mediaKey: return [Self.systemDefinedRawValue]
        case .modifier: return [CGEventType.flagsChanged.rawValue]   // ⌘, ⌥, fn, ... alone
        case .click: return [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].map(\.rawValue)
        case .drag: return [CGEventType.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].map(\.rawValue)
        case .pointerMove: return [CGEventType.mouseMoved.rawValue]
        case .scroll: return [CGEventType.scrollWheel.rawValue]
        }
    }

    init?(_ type: CGEventType) {
        guard let input = Self.allCases.first(where: { $0.eventTypeRawValues.contains(type.rawValue) }) else {
            return nil
        }
        self = input
    }

    var label: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mediaKey: return "media/system key"
        case .modifier: return "modifier key"
        case .click: return "mouse click"
        case .drag: return "mouse drag"
        case .pointerMove: return "mouse move"
        case .scroll: return "scroll/touchpad"
        }
    }

    static let eventMask: CGEventMask = allCases
        .flatMap(\.eventTypeRawValues)
        .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
}

/// Protocol for receiving input detection events
protocol InputMonitorDelegate: AnyObject {
    func inputDetected(_ input: IntrusionInput)
}

/// Monitors global keyboard, mouse, and touchpad input using CGEventTap
/// Requires Accessibility permission
class InputMonitor {
    weak var delegate: InputMonitorDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false

    // Debouncing to prevent event spam
    private var lastEventTime: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.5


    // MARK: - Permission Check

    /// Check if Accessibility permission is granted
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Request Accessibility permission (shows system dialog)
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Monitoring

    /// Start monitoring input events
    /// - Returns: true if monitoring started successfully, false if permission denied
    func startMonitoring() -> Bool {
        guard Self.hasAccessibilityPermission() else {
            Self.requestAccessibilityPermission()
            return false
        }

        guard !isMonitoring else { return true }

        // `lastEventTime` is unsynchronised; the tap runs on the main run loop.
        dispatchPrecondition(condition: .onQueue(.main))

        // Create event tap callback
        let callback: CGEventTapCallBack = { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
            // Handle tap disabled by system - re-enable via monitor's eventTap
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon = refcon {
                    let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            // Notify delegate with debouncing
            if let refcon = refcon, let input = IntrusionInput(type) {
                let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // Debounce check
                let now = Date()
                if now.timeIntervalSince(monitor.lastEventTime) > monitor.debounceInterval {
                    monitor.lastEventTime = now
                    DispatchQueue.main.async {
                        monitor.delegate?.inputDetected(input)
                    }
                }
            }

            // Pass event through (we're only listening, not blocking)
            return Unmanaged.passUnretained(event)
        }

        // Create event tap
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: IntrusionInput.eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logActivity(.input, "Failed to create event tap - check Accessibility permissions")
            return false
        }

        eventTap = tap

        // Add to run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        // Enable tap
        CGEvent.tapEnable(tap: tap, enable: true)
        isMonitoring = true

        logActivity(.input, "Started monitoring input events")
        return true
    }

    /// Stop monitoring input events
    func stopMonitoring() {
        guard isMonitoring else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Drop the tap now: the callback holds an unretained pointer to self.
            CFMachPortInvalidate(tap)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isMonitoring = false

        logActivity(.input, "Stopped monitoring input events")
    }

    deinit {
        stopMonitoring()
    }
}
