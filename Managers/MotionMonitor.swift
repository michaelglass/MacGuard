// MotionMonitor.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation
import IOKit
import IOKit.hid

protocol MotionMonitorDelegate: AnyObject {
    func motionDetected(deviation: Double)
    func lidAngleChanged(by degrees: Int)
}

/// Reads the accelerometer and lid-angle sensor of Apple Silicon MacBooks
/// (AppleSPUHIDDevice; no root needed) and feeds the pure detectors.
/// Sensor layout per github.com/olvvier/apple-silicon-accelerometer (MIT).
final class MotionMonitor {
    weak var delegate: MotionMonitorDelegate?

    private static let accelerometer: [String: Int] = [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3]
    private static let lidSensor: [String: Int] = [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 138]

    static let hasAccelerometer = !devices(matching: accelerometer).devices.isEmpty
    static let hasLidSensor = !devices(matching: lidSensor).devices.isEmpty

    private var accelManager: IOHIDManager?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var motion: MotionDetector?
    private var lidManager: IOHIDManager?
    private var lidDevice: IOHIDDevice?
    private var lidTimer: Timer?
    private var lid = LidAngleDetector()
    private var wokenDriver: io_service_t = 0

    func start(motion sensitivity: MotionSensitivity?, lidAngle: Bool) {
        stop()
        if let sensitivity { startAccelerometer(sensitivity) }
        if lidAngle { startLidSensor() }
    }

    func stop() {
        if let accelManager {
            IOHIDManagerUnscheduleFromRunLoop(accelManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(accelManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        accelManager = nil
        reportBuffer?.deallocate()
        reportBuffer = nil
        motion = nil
        sleepDriver()

        lidTimer?.invalidate()
        lidTimer = nil
        if let lidManager { IOHIDManagerClose(lidManager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        lidManager = nil
        lidDevice = nil
    }

    // MARK: Accelerometer

    private func startAccelerometer(_ sensitivity: MotionSensitivity) {
        let (manager, devices) = Self.devices(matching: Self.accelerometer)
        guard !devices.isEmpty else {
            logActivity(.system, "Motion trigger unavailable: no accelerometer")
            return
        }
        wakeDriver()
        motion = MotionDetector(sensitivity: sensitivity)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        reportBuffer = buffer
        let context = Unmanaged.passUnretained(self).toOpaque()
        for device in devices {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
                guard let context else { return }
                Unmanaged<MotionMonitor>.fromOpaque(context).takeUnretainedValue()
                    .received(UnsafeRawBufferPointer(start: report, count: length))
            }, context)
        }
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        accelManager = manager
        logActivity(.system, "Motion monitoring started (\(sensitivity.rawValue) sensitivity)")
    }

    private func received(_ report: UnsafeRawBufferPointer) {
        guard let sample = Acceleration(report: report), let deviation = motion?.add(sample) else { return }
        delegate?.motionDetected(deviation: deviation)
    }

    /// The accelerometer reports only while its driver is powered and
    /// reporting. Only its own driver is touched: the other SPU drivers
    /// (lid, gyro, light) serve macOS. Their properties don't read back, so
    /// stopping switches reporting off rather than restoring a prior value.
    private func wakeDriver() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            func number(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            guard wokenDriver == 0,
                  number(kIOHIDPrimaryUsagePageKey) == Self.accelerometer[kIOHIDPrimaryUsagePageKey],
                  number(kIOHIDPrimaryUsageKey) == Self.accelerometer[kIOHIDPrimaryUsageKey] else {
                IOObjectRelease(service)
                continue
            }
            setDriver(service, reporting: true)
            wokenDriver = service
        }
    }

    private func setDriver(_ service: io_service_t, reporting: Bool) {
        let values = ["SensorPropertyReportingState": reporting ? 1 : 0,
                      "SensorPropertyPowerState": reporting ? 1 : 0,
                      "ReportInterval": reporting ? 10_000 : 0]
        for (key, value) in values {
            IORegistryEntrySetCFProperty(service, key as CFString, value as CFNumber)
        }
    }

    private func sleepDriver() {
        guard wokenDriver != 0 else { return }
        setDriver(wokenDriver, reporting: false)
        IOObjectRelease(wokenDriver)
        wokenDriver = 0
    }

    // MARK: Lid angle

    private func startLidSensor() {
        let (manager, devices) = Self.devices(matching: Self.lidSensor)
        guard let device = devices.first else {
            logActivity(.system, "Lid angle trigger unavailable: no lid sensor")
            return
        }
        lidManager = manager
        lidDevice = device
        lid = LidAngleDetector()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollLid() }
        RunLoop.main.add(timer, forMode: .common)
        lidTimer = timer
        pollLid()
        logActivity(.system, "Lid angle monitoring started")
    }

    private func pollLid() {
        guard let lidDevice else { return }
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        guard IOHIDDeviceGetReport(lidDevice, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess,
              let angle = LidAngle(report: Array(report.prefix(length))),
              let change = lid.add(angle) else { return }
        delegate?.lidAngleChanged(by: change)
    }

    private static func devices(matching: [String: Int]) -> (manager: IOHIDManager, devices: [IOHIDDevice]) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>).map(Array.init) ?? []
        return (manager, devices)
    }
}
