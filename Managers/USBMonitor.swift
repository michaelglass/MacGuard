// USBMonitor.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation
import IOKit
import IOKit.usb

protocol USBMonitorDelegate: AnyObject {
    func usbDeviceAttached(name: String)
}

/// Devices attached before monitoring starts are drained silently.
class USBMonitor {
    weak var delegate: USBMonitorDelegate?

    private var notificationPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0

    /// Never empty.
    static func productName(product: String?, registryName: String?) -> String {
        for candidate in [product, registryName] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return "Unknown USB device"
    }

    func startMonitoring() {
        guard notificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logActivity(.system, "USB monitoring unavailable")
            return
        }
        notificationPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)

        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<USBMonitor>.fromOpaque(refcon).takeUnretainedValue().handleAttached(iterator)
        }
        let status = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("IOUSBHostDevice"),
            callback,
            Unmanaged.passUnretained(self).toOpaque(),
            &iterator
        )
        guard status == KERN_SUCCESS else {
            logActivity(.system, "USB monitoring failed: \(status)")
            stopMonitoring()
            return
        }
        // Arms the notification and skips devices that are already attached
        Self.drain(iterator) { _ in }
        logActivity(.system, "Started monitoring USB devices")
    }

    func stopMonitoring() {
        if iterator != 0 {
            IOObjectRelease(iterator)
            iterator = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
            logActivity(.system, "Stopped monitoring USB devices")
        }
    }

    private func handleAttached(_ iterator: io_iterator_t) {
        Self.drain(iterator) { service in
            let product = IORegistryEntryCreateCFProperty(service, kUSBProductString as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            var nameBuffer = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
            let registryName = IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS ? String(cString: nameBuffer) : nil
            let name = Self.productName(product: product, registryName: registryName)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.usbDeviceAttached(name: name)
            }
        }
    }

    private static func drain(_ iterator: io_iterator_t, _ body: (io_object_t) -> Void) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    deinit {
        stopMonitoring()
    }
}
