// AlarmStateManager.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import SwiftUI
import Combine
import CoreBluetooth

/// Central state machine managing alarm states and transitions
@MainActor
class AlarmStateManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var state: AlarmState = .idle
    @Published var hasAccessibilityPermission = false

    // MARK: - Public Managers (for UI access)

    let bluetoothManager = BluetoothProximityManager()
    let authManager = AuthManager()
    let audioManager = AlarmAudioManager()

    // MARK: - Private Properties

    private var countdownTimer: Timer?
    private var permissionCheckTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var autoArmTimer: Timer?
    private let inputMonitor = InputMonitor()
    private let sleepMonitor = SleepMonitor()
    private let powerMonitor = PowerMonitor()
    private let overlayController = CountdownWindowController()

    // MARK: - Initialization

    init() {
        inputMonitor.delegate = self
        sleepMonitor.delegate = self
        powerMonitor.delegate = self
        bluetoothManager.delegate = self
        checkPermissions()
        startPermissionPolling()

        // Forward bluetoothManager changes to trigger view updates
        bluetoothManager.$trustedDevices
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

    // MARK: - State Transitions

    /// Arm the alarm system, optionally lock screen, and start monitoring
    /// - Parameter isAutoArm: true if triggered by auto-arm (device left), false for manual arm
    func arm(isAutoArm: Bool = false) {
        guard state == .idle else { return }

        // Entering `.arming` synchronously closes the window in which a second
        // arm() or a disarm() used to be overridden by the delayed block below.
        state = .arming(ArmSession(trustedDeviceHasLeft: isAutoArm))

        // Pre-load audio for instant playback
        audioManager.prepare()

        // Lock screen if enabled in settings
        if AppSettings.shared.autoLockOnArm {
            lockScreen()
        }

        // Start monitors after a delay to avoid capturing the lock keystroke
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, case .arming(let session) = self.state else { return }

            // Start input monitoring
            guard self.inputMonitor.startMonitoring() else {
                // Permission denied - show warning
                self.hasAccessibilityPermission = false
                self.standDown(reason: "Failed to arm - accessibility permission denied")
                return
            }

            // Start system event monitors
            self.sleepMonitor.startMonitoring()
            self.powerMonitor.startMonitoring()

            // Start Bluetooth proximity scanning
            self.bluetoothManager.startScanning()
            self.bluetoothManager.setArmedState(true)

            self.hasAccessibilityPermission = true
            self.state = .armed(session)
            ActivityLogManager.shared.log(.armed, "System armed - monitoring active")
        }
    }

    /// Lock the Mac screen
    private func lockScreen() {
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

    /// Disarm after the owner authenticated. Only `AuthManager` can produce
    /// an `OwnerAuthentication`, so UI code cannot disarm without one.
    func disarm(_ proof: OwnerAuthentication) {
        standDown(reason: "Disarmed via \(proof.method.rawValue)")
    }

    /// Cancel an arm request before monitoring starts. No authentication is
    /// needed: nothing is being guarded yet.
    func cancelArming() {
        guard case .arming = state else { return }
        standDown(reason: "Arming cancelled")
    }

    /// Ask for Touch ID / password, and disarm on success.
    func requestDisarm(completion: @escaping (Bool) -> Void = { _ in }) {
        authManager.authenticate { [weak self] proof in
            guard let self, let proof else { return completion(false) }
            self.disarm(proof)
            completion(true)
        }
    }

    /// Try a PIN, disarming on success.
    func attemptPINDisarm(_ pin: String) -> PINVerification {
        let result = authManager.verifyPIN(pin)
        if case .accepted(let proof) = result {
            disarm(proof)
        }
        return result
    }

    /// Stop all monitoring and return to idle. Private: callers must either
    /// hold an `OwnerAuthentication` or be a proximity rule in this file.
    private func standDown(reason: String) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        cancelAutoArmTimer()
        inputMonitor.stopMonitoring()
        sleepMonitor.stopMonitoring()
        powerMonitor.stopMonitoring()
        bluetoothManager.setArmedState(false)
        bluetoothManager.stopScanning()

        // Stop audio, release pre-loaded audio, and hide overlay
        audioManager.stopAlarm()
        audioManager.unprepare()
        overlayController.hide()

        state = .idle
        ActivityLogManager.shared.log(.disarmed, reason)

        // Only scan in idle if auto-arm enabled AND trusted devices configured
        // This reduces CPU from ~10% to <1% when feature is OFF (default)
        if AppSettings.shared.autoArmOnDeviceLeave,
           !bluetoothManager.trustedDevices.isEmpty {
            bluetoothManager.startScanning()
        }
    }

    // MARK: - Proximity Policy

    /// Whether trusted-device proximity should swallow an intrusion signal.
    /// In "any device away" mode the user asked for an alarm whenever any
    /// device is away, so a single nearby device does not suppress.
    private var proximitySuppressesTrigger: Bool {
        guard bluetoothManager.isTrustedDeviceNearby() else { return false }
        return AppSettings.shared.autoArmMode == .allDevicesAway
    }

    /// Whether proximity alone may disarm this session. The single rule for
    /// every proximity disarm (device returned, lid opened / system woke).
    private var proximityMayDisarm: Bool {
        guard let session = state.session, state.phase != .arming,
              session.trustedDeviceHasLeft else { return false }
        switch AppSettings.shared.autoArmMode {
        case .allDevicesAway:
            return bluetoothManager.isTrustedDeviceNearby()
        case .anyDeviceAway:
            return bluetoothManager.areAllDevicesNearby
        }
    }

    // MARK: - Triggering

    /// Trigger the alarm countdown (called when intrusion detected)
    func trigger() {
        guard case .armed(let session) = state else { return }

        if proximitySuppressesTrigger {
            ActivityLogManager.shared.log(.bluetooth, "Trusted device nearby - ignoring trigger")
            return
        }

        // Show fullscreen overlay
        overlayController.show(alarmManager: self)

        guard let countdown = Countdown(seconds: AppSettings.shared.countdownDuration) else {
            soundAlarm(session, reason: "Immediate alarm triggered (no countdown)")
            return
        }
        state = .triggered(session, countdown)
        startCountdown()
        ActivityLogManager.shared.log(.trigger, "Countdown started (\(countdown.total)s)")
    }

    /// Immediately trigger alarm (e.g., for lid close)
    func triggerImmediate() {
        let session: ArmSession
        switch state {
        case .armed(let s), .triggered(let s, _): session = s
        case .idle, .arming, .alarming: return
        }

        if proximitySuppressesTrigger {
            ActivityLogManager.shared.log(.bluetooth, "Trusted device nearby - ignoring immediate trigger")
            return
        }

        overlayController.show(alarmManager: self)
        soundAlarm(session, reason: "ALARM ACTIVE")
    }

    private func soundAlarm(_ session: ArmSession, reason: String) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        audioManager.playAlarm()
        state = .alarming(session)
        ActivityLogManager.shared.log(.alarm, reason)
    }

    // MARK: - Private Methods

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                guard case .triggered(let session, let countdown) = strongSelf.state else { return }
                if let next = countdown.ticked() {
                    strongSelf.state = .triggered(session, next)
                } else {
                    strongSelf.soundAlarm(session, reason: "Countdown expired - ALARM ACTIVE")
                }
            }
        }
    }

    // MARK: - Auto-Arm Timer

    private func startAutoArmTimer() {
        autoArmTimer?.invalidate()
        let delay = AppSettings.shared.autoArmGracePeriod
        ActivityLogManager.shared.log(.system, "Auto-arm timer started (\(delay)s grace period)")

        autoArmTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delay), repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.state == .idle else { return }
                ActivityLogManager.shared.log(.armed, "Auto-arming - trusted device still away")
                self.arm(isAutoArm: true)
            }
        }
    }

    private func cancelAutoArmTimer(reason: String? = nil) {
        if autoArmTimer != nil {
            ActivityLogManager.shared.log(.system, reason ?? "Auto-arm timer cancelled")
        }
        autoArmTimer?.invalidate()
        autoArmTimer = nil
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

// MARK: - InputMonitorDelegate

extension AlarmStateManager: InputMonitorDelegate {
    nonisolated func inputDetected(_ input: IntrusionInput) {
        Task { @MainActor in
            guard case .armed = self.state else { return }

            ActivityLogManager.shared.log(.input, "Input detected: \(input.label)")

            self.trigger()
        }
    }
}

// MARK: - SleepMonitorDelegate

extension AlarmStateManager: SleepMonitorDelegate {
    nonisolated func lidWillClose() {
        Task { @MainActor in
            guard case .armed = self.state else { return }
            // Lid close = immediate alarm (no countdown per validation)
            ActivityLogManager.shared.log(.system, "Lid close detected - immediate alarm")
            self.triggerImmediate()
        }
    }

    nonisolated func systemDidWake() {
        Task { @MainActor in
            // Same rule as a returning device: wake alone must not bypass
            // "any device away" mode or the manual-arm guard
            if self.proximityMayDisarm {
                self.standDown(reason: "Disarmed on wake - trusted device nearby")
            } else {
                ActivityLogManager.shared.log(.system, "System woke from sleep")
            }
        }
    }
}

// MARK: - PowerMonitorDelegate

extension AlarmStateManager: PowerMonitorDelegate {
    nonisolated func powerSourceChanged(to source: PowerSource) {
        Task { @MainActor in
            switch source {
            case .battery:
                guard case .armed = self.state else { return }
                // Power disconnect = start countdown
                ActivityLogManager.shared.log(.power, "Power cable disconnected - starting countdown")
                self.trigger()
            case .ac:
                ActivityLogManager.shared.log(.power, "Power cable connected")
            }
        }
    }
}

// MARK: - BluetoothProximityDelegate

extension AlarmStateManager: BluetoothProximityDelegate {
    nonisolated func trustedDeviceNearby(_ device: TrustedDevice) {
        Task { @MainActor in
            // Cancel pending auto-arm (always, regardless of mode)
            self.cancelAutoArmTimer(reason: "Auto-arm cancelled - '\(device.name)' detected nearby")

            guard self.state.session != nil else { return }

            if self.proximityMayDisarm {
                self.standDown(reason: "Disarmed via trusted device '\(device.name)'")
            } else if self.state.session?.trustedDeviceHasLeft == false {
                ActivityLogManager.shared.log(.bluetooth, "Device '\(device.name)' nearby but manual arm - not auto-disarming")
            }
        }
    }

    nonisolated func trustedDeviceAway(_ device: TrustedDevice) {
        Task { @MainActor in
            ActivityLogManager.shared.log(.bluetooth, "Trusted device '\(device.name)' left proximity")

            // If armed and device leaves, enable auto-disarm on return
            // (device actually left, so return should disarm)
            if self.state.session?.trustedDeviceHasLeft == false {
                self.state = self.state.updatingSession { $0.trustedDeviceHasLeft = true }
                ActivityLogManager.shared.log(.bluetooth, "Device left while armed - enabling auto-disarm on return")
            }

            // For "any device away" mode - start auto-arm when any device leaves
            guard AppSettings.shared.autoArmOnDeviceLeave,
                  AppSettings.shared.autoArmMode == .anyDeviceAway,
                  self.state == .idle else { return }

            // Don't auto-arm if BT is unstable or powered off (prevents false alarms)
            guard self.bluetoothManager.isBluetoothStable else {
                ActivityLogManager.shared.log(.bluetooth, "Auto-arm blocked - BT unstable or off")
                return
            }

            ActivityLogManager.shared.log(.bluetooth, "Any device away mode - starting grace period")
            self.startAutoArmTimer()
        }
    }

    nonisolated func allTrustedDevicesAway() {
        Task { @MainActor in
            guard AppSettings.shared.autoArmOnDeviceLeave,
                  AppSettings.shared.autoArmMode == .allDevicesAway,
                  self.state == .idle else { return }

            // Don't auto-arm if BT is unstable or powered off (prevents false alarms)
            guard self.bluetoothManager.isBluetoothStable else {
                ActivityLogManager.shared.log(.bluetooth, "Auto-arm blocked - BT unstable or off")
                return
            }

            ActivityLogManager.shared.log(.bluetooth, "All trusted devices away - starting grace period")
            self.startAutoArmTimer()
        }
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
