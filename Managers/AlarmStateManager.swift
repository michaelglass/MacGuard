// AlarmStateManager.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import SwiftUI
import Combine
import CoreBluetooth

/// Imperative shell around `AlarmMachine`: turns monitor callbacks and UI
/// actions into `AlarmInput`s, and performs the `AlarmEffect`s that come back.
/// All decisions live in the machine; this class only does I/O.
@MainActor
class AlarmStateManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var state: AlarmState = .idle
    @Published var hasAccessibilityPermission = false
    /// When monitoring starts during `.arming` (display only; the machine
    /// still decides via `.armingDelayElapsed`).
    @Published private(set) var armingDeadline: Date?

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
    private let usbMonitor = USBMonitor()
    private let networkMonitor = NetworkMonitor()
    /// Pending exit-delay callback; cancelled on reschedule and stand-down so
    /// a stale delay can never arm a later arming session early.
    private var armingDelayWork: DispatchWorkItem?
    private let overlayController = CountdownWindowController()
    private var eventSinks: [(AlarmEvent) -> Void] = []

    // MARK: - Initialization

    init() {
        inputMonitor.delegate = self
        sleepMonitor.delegate = self
        powerMonitor.delegate = self
        usbMonitor.delegate = self
        networkMonitor.delegate = self
        bluetoothManager.delegate = self
        checkPermissions()
        startPermissionPolling()

        // Screen lock is an idle-time signal (auto-arm), so it is always observed;
        // the machine decides whether it arms.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.screenLocked) }
        }

        // Forward bluetoothManager changes to trigger view updates
        bluetoothManager.objectWillChange
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

    /// Parsed settings and proximity evidence, read fresh for every step.
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
            autoArmOnScreenLock: settings.autoArmOnScreenLock,
            exitDelay: settings.exitDelay
        )
    }

    /// Feed one input through the machine and run its effects.
    private func send(_ input: AlarmInput) {
        let (next, effects) = AlarmMachine.step(state, input, environment)
        state = next
        effects.forEach(perform)
    }

    /// Subscribe to security-relevant events (notifiers, recorders).
    func onEvent(_ sink: @escaping (AlarmEvent) -> Void) {
        eventSinks.append(sink)
    }

    // MARK: - Actions (UI)

    /// Arm the alarm system, optionally lock screen, and start monitoring
    func arm() {
        send(.armRequested(auto: false))
    }

    /// Cancel an arm request before monitoring starts. No authentication is
    /// needed: nothing is being guarded yet.
    func cancelArming() {
        send(.cancelArming)
    }

    /// Disarm after the owner authenticated. Only `AuthManager` can produce
    /// an `OwnerAuthentication`, so UI code cannot disarm without one.
    func disarm(_ proof: OwnerAuthentication) {
        send(.authenticated(proof))
    }

    /// Ask for Touch ID / password, and disarm on success.
    func requestDisarm(completion: @escaping (Bool) -> Void = { _ in }) {
        authManager.authenticate { [weak self] proof in
            guard let self, let proof else { return completion(false) }
            self.disarm(proof)
            completion(true)
        }
    }

    /// A previous instance was killed while armed: come back sounding.
    func resumeAfterTamper(_ session: ArmSession) {
        send(.resumeAfterTamper(session))
    }

    /// Try a PIN, disarming on success.
    func attemptPINDisarm(_ pin: String) -> PINVerification {
        let result = authManager.verifyPIN(pin)
        if case .accepted(let proof) = result {
            disarm(proof)
        }
        return result
    }

    /// Clear the event log - only while idle, so the record of an intrusion survives.
    func clearActivityLog() {
        guard state == .idle else { return }
        ActivityLogManager.shared.clear()
    }

    // MARK: - Effects

    private func perform(_ effect: AlarmEffect) {
        switch effect {
        case .prepareAudio:
            audioManager.prepare()
        case .lockScreen:
            lockScreen()
        case .closeConfigWindows:
            // Config windows opened while idle must not stay editable once armed
            PINSetupWindowController.shared.close()
            TrustedDevicesConfigWindowController.shared.close()
            DeviceScannerWindowController.shared.close()
        case .scheduleArmingDelay(let delay):
            // Start monitors after the exit delay (also avoids capturing the lock keystroke)
            armingDelayWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.armingDeadline = nil
                self?.send(.armingDelayElapsed)
            }
            armingDelayWork = work
            armingDeadline = Date().addingTimeInterval(delay.seconds)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay.seconds, execute: work)
        case .startInputMonitoring:
            let started = inputMonitor.startMonitoring()
            hasAccessibilityPermission = started
            send(.inputMonitoringStarted(started))
        case .startSystemMonitors:
            sleepMonitor.startMonitoring()
            powerMonitor.startMonitoring()
            usbMonitor.startMonitoring()
            networkMonitor.startMonitoring()
            bluetoothManager.startScanning()
            bluetoothManager.setArmedState(true)
        case .stopMonitors:
            armingDelayWork?.cancel()
            armingDelayWork = nil
            armingDeadline = nil
            inputMonitor.stopMonitoring()
            usbMonitor.stopMonitoring()
            networkMonitor.stopMonitoring()
            sleepMonitor.stopMonitoring()
            powerMonitor.stopMonitoring()
            bluetoothManager.setArmedState(false)
            bluetoothManager.stopScanning()
        case .showOverlay:
            overlayController.show(alarmManager: self)
        case .hideOverlay:
            overlayController.hide()
        case .playAlarm:
            audioManager.playAlarm()
        case .stopAlarm:
            // Stop audio and release pre-loaded audio
            audioManager.stopAlarm()
            audioManager.unprepare()
        case .startCountdownTimer:
            countdownTimer?.invalidate()
            countdownTimer = scheduleOnMain(every: 1, repeats: true) { $0.send(.countdownTick) }
        case .stopCountdownTimer:
            countdownTimer?.invalidate()
            countdownTimer = nil
        case .startAutoArmTimer:
            autoArmTimer?.invalidate()
            let grace = AppSettings.shared.autoArmGracePeriod
            ActivityLogManager.shared.log(.system, "Auto-arm timer started (\(grace.rawValue)s grace period)")
            autoArmTimer = scheduleOnMain(every: grace.seconds, repeats: false) { $0.send(.autoArmTimerFired) }
        case .cancelAutoArmTimer(let reason):
            if autoArmTimer != nil {
                ActivityLogManager.shared.log(.system, reason ?? "Auto-arm timer cancelled")
            }
            autoArmTimer?.invalidate()
            autoArmTimer = nil
        case .resumeIdleScanning:
            bluetoothManager.startScanning()
        case .log(let category, let message):
            ActivityLogManager.shared.log(category, message)
        case .emit(let event):
            eventSinks.forEach { $0(event) }
        case .persistArmedMarker(let session):
            TamperGuard.shared.persist(session)
        case .clearArmedMarker:
            TamperGuard.shared.clear()
        }
    }

    /// A main-run-loop timer in `.common` mode, so it keeps firing while a
    /// menu is open (the default mode pauses during menu tracking).
    private func scheduleOnMain(every interval: TimeInterval, repeats: Bool,
                                _ action: @escaping (AlarmStateManager) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] _ in
            MainActor.assumeIsolated { self.map(action) }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
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
