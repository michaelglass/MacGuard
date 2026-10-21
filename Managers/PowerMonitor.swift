// PowerMonitor.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import Foundation
import IOKit.ps

enum PowerSource: Equatable {
    case ac, battery
}

/// Protocol for receiving power state change events
protocol PowerMonitorDelegate: AnyObject {
    func powerSourceChanged(to source: PowerSource)
}

/// Monitors power cable connect/disconnect events
class PowerMonitor {
    weak var delegate: PowerMonitorDelegate?

    private var runLoopSource: CFRunLoopSource?
    private var lastSource: PowerSource = .ac
    private var isMonitoring = false

    // MARK: - Monitoring

    /// Start monitoring power state changes
    func startMonitoring() {
        guard !isMonitoring else { return }

        // Check initial state
        lastSource = currentSource()

        // Create power source notification callback
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handlePowerSourceChange()
        }, context).takeRetainedValue()

        // Common modes: still delivered while a menu or modal is tracking
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        isMonitoring = true

        logActivity(.power, "Started monitoring power state")
    }

    /// Stop monitoring power state changes
    func stopMonitoring() {
        guard isMonitoring else { return }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }

        isMonitoring = false
        logActivity(.power, "Stopped monitoring power state")
    }

    // MARK: - Power State

    /// Check if currently on AC power
    /// - Returns: true if on AC power, false if on battery
    /// The *providing* source: a UPS reports "AC Power" even after the laptop's cable is pulled.
    func currentSource() -> PowerSource {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return .ac // Assume AC if unknown
        }
        return (providing as String) == kIOPSACPowerValue ? .ac : .battery
    }

    /// `nil` when nothing changed (IOKit also notifies on battery-level changes).
    static func transition(from previous: PowerSource, to current: PowerSource) -> PowerSource? {
        current == previous ? nil : current
    }

    // MARK: - Private

    private func handlePowerSourceChange() {
        guard let source = Self.transition(from: lastSource, to: currentSource()) else { return }
        lastSource = source

        logActivity(.power, source == .ac ? "Power cable connected" : "Power cable disconnected")
        DispatchQueue.main.async {
            self.delegate?.powerSourceChanged(to: source)
        }
    }

    deinit {
        stopMonitoring()
    }
}
