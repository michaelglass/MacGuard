// AlarmStateManager.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import SwiftUI
import Combine
import CoreBluetooth

/// Imperative shell around `AlarmMachine`: parses callbacks into inputs, performs effects.
@MainActor
class AlarmStateManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var state: AlarmState = .idle
    @Published var hasAccessibilityPermission = false
    /// Display only; the machine decides via `.armingDelayElapsed`.
    @Published private(set) var armingDeadline: Date?

    // MARK: - Public Managers (for UI access)

    let bluetoothManager = BluetoothProximityManager()
    let authManager = AuthManager()
    let audioManager = AlarmAudioManager()

    // MARK: - Private Properties

    private var permissionCheckTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let inputMonitor = InputMonitor()
    private let sleepMonitor = SleepMonitor()
    private let powerMonitor = PowerMonitor()
    private let usbMonitor = USBMonitor()
    private let motionMonitor = MotionMonitor()
    private let networkMonitor = NetworkMonitor()
    private lazy var overlayController = CountdownWindowController(alarmManager: self)

    private lazy var runtime: AlarmRuntime = {
        let runtime = AlarmRuntime(
            hardware: self,
            scheduler: RunLoopScheduler(),
            environment: { [unowned self] in self.environment },
            gracePeriod: { AppSettings.shared.autoArmGracePeriod }
        )
        runtime.onStateChange = { [unowned self] in self.state = $0 }
        runtime.onArmingDeadlineChange = { [unowned self] in self.armingDeadline = $0 }
        return runtime
    }()

    // MARK: - Initialization

    init() {
        inputMonitor.delegate = self
        sleepMonitor.delegate = self
        powerMonitor.delegate = self
        usbMonitor.delegate = self
        motionMonitor.delegate = self
        networkMonitor.delegate = self
        bluetoothManager.delegate = self
        checkPermissions()
        startPermissionPolling()

        // Always observed (an idle-time signal); the machine decides whether it arms.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.screenLocked) }
        }

        // Forward nested managers' changes so views observing this one redraw
        Publishers.Merge(bluetoothManager.objectWillChange, authManager.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Observe AppSettings changes to start/stop scanning when auto-arm setting changes
        AppSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleSettingsChanged()
            }
            .store(in: &cancellables)
    }

    /// Check current accessibility permission status
    func checkPermissions() {
        hasAccessibilityPermission = InputMonitor.hasAccessibilityPermission()
        // Stop polling once permission is granted
        if hasAccessibilityPermission {
            stopPermissionPolling()
        }
    }

    /// Start polling for permission changes (when permission not yet granted)
    private func startPermissionPolling() {
        guard !hasAccessibilityPermission else { return }
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.checkPermissions()
            }
        }
    }

    /// Stop permission polling
    private func stopPermissionPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    /// Request accessibility permission from user
    func requestAccessibilityPermission() {
        InputMonitor.requestAccessibilityPermission()
        // Start polling for permission changes (user may grant in System Preferences)
        startPermissionPolling()
    }

    // MARK: - Machine

    private var environment: AlarmEnvironment {
        let settings = AppSettings.shared
        return AlarmEnvironment(
            countdown: settings.countdownDuration.countdown,
            autoLockOnArm: settings.autoLockOnArm,
            autoArmEnabled: settings.autoArmOnDeviceLeave,
            autoArmMode: settings.autoArmMode,
            hasTrustedDevices: !bluetoothManager.trustedDevices.isEmpty,
            anyTrustedDeviceNearby: bluetoothManager.isTrustedDeviceNearby(),
            allTrustedDevicesNearby: bluetoothManager.areAllDevicesNearby,
            bluetoothStable: bluetoothManager.isBluetoothStable,
            usbTriggerEnabled: settings.usbTriggerEnabled,
            networkTriggerEnabled: settings.networkTriggerEnabled,
            motionTriggerEnabled: settings.motionTriggerEnabled,
            lidAngleTriggerEnabled: settings.lidAngleTriggerEnabled,
            autoArmOnScreenLock: settings.autoArmOnScreenLock,
            exitDelay: settings.exitDelay
        )
    }

    private func send(_ input: AlarmInput) {
        runtime.send(input)
    }

    func onEvent(_ sink: @escaping (AlarmEvent) -> Void) {
        runtime.onEvent(sink)
    }

    // MARK: - Actions (UI)

    /// Arm the alarm system, optionally lock screen, and start monitoring
    func arm() {
        send(.armRequested(auto: false))
    }

    /// No authentication: nothing is guarded yet.
    func cancelArming() {
        send(.cancelArming)
    }

    func disarm(_ proof: OwnerAuthentication) {
        send(.authenticated(proof))
    }

    func requestDisarm(completion: @escaping (Bool) -> Void = { _ in }) {
        authManager.authenticate { [weak self] proof in
            guard let self, let proof else { return completion(false) }
            self.disarm(proof)
            completion(true)
        }
    }

    func resumeAfterTamper(_ session: ArmSession) {
        send(.resumeAfterTamper(session))
    }

    func attemptPINDisarm(_ pin: String) -> PINVerification {
        let result = authManager.verifyPIN(pin)
        if case .accepted(let proof) = result {
            disarm(proof)
        }
        return result
    }

    /// Idle only, so the record of an intrusion survives.
    func clearActivityLog() {
        guard state == .idle else { return }
        ActivityLogManager.shared.clear()
    }

    /// Lock the Mac screen
    func lockScreen() {
        // Primary method: pmset displaysleepnow (reliable on modern macOS)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]

        do {
            try task.run()
            task.waitUntilExit()
            ActivityLogManager.shared.log(.system, "Screen locked via pmset")
        } catch {
            ActivityLogManager.shared.log(.system, "Failed to lock via pmset: \(error)")
            // Fallback: AppleScript
            lockScreenViaAppleScript()
        }
    }

    private func lockScreenViaAppleScript() {
        let script = """
        tell application "System Events" to keystroke "q" using {control down, command down}
        """
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if error == nil {
                ActivityLogManager.shared.log(.system, "Screen locked via AppleScript")
            }
        }
    }

    /// Handle AppSettings changes - start/stop Bluetooth scanning based on auto-arm setting
    private func handleSettingsChanged() {
        guard state == .idle else { return }

        let shouldScan = AppSettings.shared.autoArmOnDeviceLeave && !bluetoothManager.trustedDevices.isEmpty

        if shouldScan && !bluetoothManager.isScanning {
            bluetoothManager.startScanning()
            ActivityLogManager.shared.log(.bluetooth, "Started scanning (auto-arm enabled)")
        } else if !shouldScan && bluetoothManager.isScanning {
            bluetoothManager.stopScanning()
            ActivityLogManager.shared.log(.bluetooth, "Stopped scanning (auto-arm disabled)")
        }
    }
}

// MARK: - AlarmHardware

extension AlarmStateManager: AlarmHardware {
    func prepareAudio() { audioManager.prepare() }

    func closeConfigWindows() {
        // Config windows opened while idle must not stay editable once armed
        PINSetupWindowController.shared.close()
        TrustedDevicesConfigWindowController.shared.close()
        DeviceScannerWindowController.shared.close()
    }

    func startInputMonitoring() -> Bool {
        let started = inputMonitor.startMonitoring()
        hasAccessibilityPermission = started
        return started
    }

    func startSystemMonitors() {
        sleepMonitor.startMonitoring()
        powerMonitor.startMonitoring()
        usbMonitor.startMonitoring()
        networkMonitor.startMonitoring()
        // The accelerometer is only woken when its trigger is on (battery)
        let settings = AppSettings.shared
        motionMonitor.start(motion: settings.motionTriggerEnabled ? settings.motionSensitivity : nil,
                            lidAngle: settings.lidAngleTriggerEnabled)
        bluetoothManager.startScanning()
        bluetoothManager.setArmedState(true)
    }

    func stopMonitors() {
        inputMonitor.stopMonitoring()
        usbMonitor.stopMonitoring()
        networkMonitor.stopMonitoring()
        motionMonitor.stop()
        sleepMonitor.stopMonitoring()
        powerMonitor.stopMonitoring()
        bluetoothManager.setArmedState(false)
        bluetoothManager.stopScanning()
    }

    func resumeIdleScanning() { bluetoothManager.startScanning() }
    func showOverlay() { overlayController.show() }
    func hideOverlay() { overlayController.hide() }
    func playAlarm() { audioManager.playAlarm() }

    func stopAlarm() {
        audioManager.stopAlarm()
        audioManager.unprepare()
    }

    func persistArmedMarker(_ session: ArmSession) { TamperGuard.shared.persist(session) }
    func clearArmedMarker() { TamperGuard.shared.clear() }
    func endOwnerChallenge() {
        authManager.resetPINAttempts()
        authManager.cancelPendingAuthentication()
    }
    func log(_ category: ActivityLogCategory, _ message: String) { ActivityLogManager.shared.log(category, message) }
}

// MARK: - InputMonitorDelegate

extension AlarmStateManager: InputMonitorDelegate {
    nonisolated func inputDetected(_ input: IntrusionInput) {
        Task { @MainActor in self.send(.intrusion(.input(input))) }
    }
}

// MARK: - SleepMonitorDelegate

extension AlarmStateManager: SleepMonitorDelegate {
    nonisolated func lidWillClose() {
        Task { @MainActor in self.send(.severeIntrusion(.lidClosed)) }
    }

    nonisolated func systemDidWake() {
        Task { @MainActor in self.send(.systemWoke) }
    }
}

// MARK: - PowerMonitorDelegate

extension AlarmStateManager: PowerMonitorDelegate {
    nonisolated func powerSourceChanged(to source: PowerSource) {
        Task { @MainActor in
            switch source {
            case .battery:
                ActivityLogManager.shared.log(.power, "Power cable disconnected")
                self.send(.intrusion(.powerDisconnected))
            case .ac:
                ActivityLogManager.shared.log(.power, "Power cable connected")
            }
        }
    }
}

// MARK: - USBMonitorDelegate

extension AlarmStateManager: USBMonitorDelegate {
    nonisolated func usbDeviceAttached(name: String) {
        Task { @MainActor in
            ActivityLogManager.shared.log(.input, "USB device attached: \(name)")
            self.send(.intrusion(.usbDeviceAttached(name: name)))
        }
    }
}

// MARK: - NetworkMonitorDelegate

extension AlarmStateManager: NetworkMonitorDelegate {
    nonisolated func networkChanged() {
        Task { @MainActor in
            ActivityLogManager.shared.log(.system, "Network links changed")
            self.send(.intrusion(.networkChanged))
        }
    }
}

// MARK: - BluetoothProximityDelegate

extension AlarmStateManager: BluetoothProximityDelegate {
    nonisolated func trustedDeviceNearby(_ device: TrustedDevice) {
        Task { @MainActor in self.send(.trustedDeviceNearby(name: device.name)) }
    }

    nonisolated func trustedDeviceAway(_ device: TrustedDevice) {
        Task { @MainActor in self.send(.trustedDeviceAway(name: device.name)) }
    }

    nonisolated func allTrustedDevicesAway() {
        Task { @MainActor in self.send(.allTrustedDevicesAway) }
    }

    nonisolated func bluetoothStateChanged(_ state: CBManagerState) {
        Task { @MainActor in
            if state == .poweredOff {
                ActivityLogManager.shared.log(.bluetooth, "Bluetooth turned off")
            } else if state == .poweredOn {
                ActivityLogManager.shared.log(.bluetooth, "Bluetooth turned on")
            }
        }
    }
}

// MARK: - MotionMonitorDelegate

extension AlarmStateManager: MotionMonitorDelegate {
    nonisolated func motionDetected(deviation: Double) {
        Task { @MainActor in
            ActivityLogManager.shared.log(.input, String(format: "Motion detected (%.3f g)", deviation))
            self.send(.intrusion(.motion))
        }
    }

    nonisolated func lidAngleChanged(by degrees: Int) {
        Task { @MainActor in
            ActivityLogManager.shared.log(.input, "Lid moved \(degrees)°")
            self.send(.intrusion(.lidMoved(degrees: degrees)))
        }
    }
}
