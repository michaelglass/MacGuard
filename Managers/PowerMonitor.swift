// PowerMonitor.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import Foundation
import IOKit.ps

/// Protocol for receiving power state change events
protocol PowerMonitorDelegate: AnyObject {
    /// Called when power cable is disconnected
    func powerCableDisconnected()
    /// Called when power cable is connected
    func powerCableConnected()
}

/// Monitors power cable connect/disconnect events
class PowerMonitor {
    weak var delegate: PowerMonitorDelegate?

    private var runLoopSource: CFRunLoopSource?
    private var wasOnACPower = true
    private var isMonitoring = false

    // MARK: - Logging Helper

    private func log(_ category: ActivityLogCategory, _ message: String) {
        Task { @MainActor in
            ActivityLogManager.shared.log(category, message)
        }
    }

    // MARK: - Monitoring

    /// Start monitoring power state changes
    func startMonitoring() {
        guard !isMonitoring else { return }

        // Check initial state
        wasOnACPower = isOnACPower()

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

        log(.power, "Started monitoring power state")
    }

    /// Stop monitoring power state changes
    func stopMonitoring() {
        guard isMonitoring else { return }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }

        isMonitoring = false
        log(.power, "Stopped monitoring power state")
    }

    // MARK: - Power State

    /// Check if currently on AC power
    /// - Returns: true if on AC power, false if on battery
    /// Asks which source is *providing* power. Reading the state of the first
    /// listed source instead could pick an attached UPS, which reports
    /// "AC Power" even after the laptop's own cable is pulled.
    func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return true // Assume AC if unknown
        }
        return (providing as String) == kIOPSACPowerValue
    }

    // MARK: - Private

    private func handlePowerSourceChange() {
        let isAC = isOnACPower()

        if wasOnACPower && !isAC {
            // Power cable disconnected
            log(.power, "Power cable disconnected")
            DispatchQueue.main.async {
                self.delegate?.powerCableDisconnected()
            }
        } else if !wasOnACPower && isAC {
            // Power cable connected
            log(.power, "Power cable connected")
            DispatchQueue.main.async {
                self.delegate?.powerCableConnected()
            }
        }

        wasOnACPower = isAC
    }

    deinit {
        stopMonitoring()
    }
}
