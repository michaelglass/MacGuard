// AlarmAudioManager.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import AVFoundation
import Cocoa
import CoreAudio

/// Manages alarm audio playback at maximum volume
class AlarmAudioManager: ObservableObject {
    @Published var isPlaying = false

    private var audioPlayer: AVAudioPlayer?
    /// Volume before the alarm raised it; `nil` when there is nothing to restore
    /// (stopAlarm() also runs on every plain disarm).
    private var originalVolume: Float?
    private var originalOutputDeviceID: AudioDeviceID = 0
    private var builtInSpeakerID: AudioDeviceID = 0
    private var shouldRestoreOutputDevice = false
    private var beepTimer: Timer?
    private var volumeEnforcementTimer: Timer?
    private var isPrepared = false
    private var targetVolume: Float = 1.0


    // MARK: - Preparation

    /// Pre-load audio file so it's ready for instant playback
    func prepare() {
        guard !isPrepared else { return }

        let settings = AppSettings.shared
        if settings.customSoundUnavailable {
            logActivity(.alarm, "Custom sound '\(settings.customSoundName)' is unavailable - using the default sound")
        }
        if let file = settings.alarmSoundFile {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: file.url)
                audioPlayer?.numberOfLoops = -1
                audioPlayer?.volume = 1.0
                audioPlayer?.prepareToPlay()
                isPrepared = true
                logActivity(.alarm, "Audio pre-loaded and ready")
            } catch {
                logActivity(.alarm, "Failed to pre-load audio: \(error)")
            }
        }
    }

    /// Release pre-loaded audio
    func unprepare() {
        if !isPlaying {
            audioPlayer?.stop()
            audioPlayer = nil
            isPrepared = false
            logActivity(.alarm, "Audio released")
        }
    }

    // MARK: - Playback

    /// Play the alarm sound at configured volume
    func playAlarm() {
        guard !isPlaying else { return }

        let settings = AppSettings.shared

        // Switch to built-in speaker (before volume changes)
        switchToBuiltInSpeaker()

        // Save original volume
        originalVolume = outputVolume()
        logActivity(.alarm, "Saved original volume: \(originalVolume.map { String($0) } ?? "unknown")")

        // Store target volume for enforcement
        targetVolume = Float(settings.alarmVolume)

        // Set system volume based on settings
        setSystemVolume(targetVolume)

        // Unmute if muted
        unmuteSpeaker()

        // Start volume enforcement timer to prevent muting
        startVolumeEnforcement()

        // Use pre-loaded player if available, otherwise load now
        if isPrepared, let player = audioPlayer {
            player.play()
            isPlaying = true
            logActivity(.alarm, "Playing alarm sound (pre-loaded)")
        } else if let file = settings.alarmSoundFile {
            playAudioFile(file.url)
        } else {
            // Fallback to system beep
            logActivity(.alarm, "Alarm sound not found, using system beep")
            playSystemAlert()
        }
    }

    /// Stop the alarm and restore volume
    func stopAlarm() {
        // Stop volume enforcement first
        stopVolumeEnforcement()

        audioPlayer?.stop()
        audioPlayer = nil
        beepTimer?.invalidate()
        beepTimer = nil
        isPlaying = false
        isPrepared = false

        // Restore original volume (only if the alarm changed it)
        if let originalVolume {
            setSystemVolume(originalVolume)
            self.originalVolume = nil
        }

        // Restore original output device
        restoreOutputDevice()

        logActivity(.alarm, "Alarm stopped")
    }

    // MARK: - Volume Enforcement

    /// Start timer to continuously enforce volume (prevents muting via keyboard)
    private func startVolumeEnforcement() {
        stopVolumeEnforcement()
        volumeEnforcementTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.enforceVolume()
        }
        logActivity(.alarm, "Volume enforcement started")
    }

    private func stopVolumeEnforcement() {
        volumeEnforcementTimer?.invalidate()
        volumeEnforcementTimer = nil
    }

    /// Keep the alarm audible: on the built-in speaker, playing, unmuted, loud.
    private func enforceVolume() {
        guard isPlaying else { return }

        // Connecting headphones (or picking another output) moves the default
        // output, and the alarm would follow it. Move it back; the device chosen
        // mid-alarm is the one restored on disarm.
        let current = getDefaultOutputDevice()
        if builtInSpeakerID != 0, current != 0, current != builtInSpeakerID {
            originalOutputDeviceID = current
            shouldRestoreOutputDevice = true
            setDefaultOutputDevice(builtInSpeakerID)
            logActivity(.alarm, "Output moved to device \(current) - alarm kept on built-in speaker")
        }

        // A device change can stop the player
        if let player = audioPlayer, !player.isPlaying {
            player.play()
            logActivity(.alarm, "Alarm playback resumed after an output change")
        }

        if outputMuted() == true {
            unmuteSpeaker()
            setSystemVolume(targetVolume)
            logActivity(.alarm, "Mute blocked - volume restored")
        }

        if let current = outputVolume(), current < targetVolume - 0.05 {
            setSystemVolume(targetVolume)
            logActivity(.alarm, "Volume restored from \(Int(current * 100))% to \(Int(targetVolume * 100))%")
        }
    }

    // MARK: - Audio File Playback

    private func playAudioFile(_ url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1 // Loop forever
            audioPlayer?.volume = 1.0
            audioPlayer?.prepareToPlay() // Pre-load audio buffers
            audioPlayer?.play()
            isPlaying = true
            logActivity(.alarm, "Playing alarm sound")
        } catch {
            logActivity(.alarm, "Failed to play alarm: \(error)")
            playSystemAlert()
        }
    }

    // MARK: - System Volume Control

    // Volume and mute go through CoreAudio on the current default output
    // device (the built-in speaker once the alarm has switched to it).
    // The enforcement timer runs every 0.3s, so this must not compile and run
    // AppleScript on the main thread.

    private func setSystemVolume(_ volume: Float) {
        let device = getDefaultOutputDevice()
        var value = Float32(min(max(volume, 0), 1))
        for element in volumeElements(device, kAudioDevicePropertyVolumeScalar) {
            var address = outputAddress(kAudioDevicePropertyVolumeScalar, element)
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
        logActivity(.alarm, "Set volume to \(Int(value * 100))%")
    }

    private func unmuteSpeaker() {
        let device = getDefaultOutputDevice()
        var value = UInt32(0)
        for element in volumeElements(device, kAudioDevicePropertyMute) {
            var address = outputAddress(kAudioDevicePropertyMute, element)
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }

    /// Average output volume (0...1), or `nil` if the device exposes none.
    private func outputVolume() -> Float? {
        let device = getDefaultOutputDevice()
        let values: [Float32] = volumeElements(device, kAudioDevicePropertyVolumeScalar).compactMap { element in
            var address = outputAddress(kAudioDevicePropertyVolumeScalar, element)
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    /// Whether any controllable output element is muted.
    private func outputMuted() -> Bool? {
        let device = getDefaultOutputDevice()
        let values: [UInt32] = volumeElements(device, kAudioDevicePropertyMute).compactMap { element in
            var address = outputAddress(kAudioDevicePropertyMute, element)
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
        guard !values.isEmpty else { return nil }
        return values.contains { $0 != 0 }
    }

    private func outputAddress(_ selector: AudioObjectPropertySelector,
                               _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    /// The main element if it carries `selector`, otherwise the stereo
    /// channels (1, 2) that do. Many devices only expose per-channel volume.
    private func volumeElements(_ device: AudioDeviceID,
                                _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        guard device != 0 else { return [] }
        func has(_ element: AudioObjectPropertyElement) -> Bool {
            var address = outputAddress(selector, element)
            return AudioObjectHasProperty(device, &address)
        }
        if has(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(has)
    }

    // MARK: - Audio Output Device Control

    /// Save current output device and switch to built-in speaker
    private func switchToBuiltInSpeaker() {
        // Save current output device
        originalOutputDeviceID = getDefaultOutputDevice()

        // Find built-in speaker
        builtInSpeakerID = findBuiltInSpeaker()

        if builtInSpeakerID != 0 && builtInSpeakerID != originalOutputDeviceID {
            setDefaultOutputDevice(builtInSpeakerID)
            shouldRestoreOutputDevice = true
            logActivity(.alarm, "Switched from device \(originalOutputDeviceID) to built-in speaker \(builtInSpeakerID)")
        } else if builtInSpeakerID == originalOutputDeviceID {
            logActivity(.alarm, "Already using built-in speaker")
            shouldRestoreOutputDevice = false
        } else {
            logActivity(.alarm, "Could not find built-in speaker, using current device")
            shouldRestoreOutputDevice = false
        }
    }

    /// Restore original output device
    private func restoreOutputDevice() {
        guard shouldRestoreOutputDevice, originalOutputDeviceID != 0 else { return }
        setDefaultOutputDevice(originalOutputDeviceID)
        logActivity(.alarm, "Restored output device to \(originalOutputDeviceID)")
        shouldRestoreOutputDevice = false
    }

    /// Get current default output device
    private func getDefaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        if status != noErr {
            logActivity(.alarm, "Failed to get default output device: \(status)")
        }
        return deviceID
    }

    /// Set default output device
    private func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        var mutableDeviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )

        if status != noErr {
            logActivity(.alarm, "Failed to set output device: \(status)")
        }
    }

    /// Find built-in speaker device ID
    private func findBuiltInSpeaker() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            logActivity(.alarm, "Failed to get devices size: \(status)")
            return 0
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        )

        guard status == noErr else {
            logActivity(.alarm, "Failed to get devices: \(status)")
            return 0
        }

        // Find the built-in output device
        for device in devices {
            if isBuiltInOutputDevice(device) {
                return device
            }
        }

        return 0
    }

    /// Check if device is built-in output speaker
    private func isBuiltInOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        // Check if device has output streams
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var streamSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize)
        guard status == noErr && streamSize > 0 else { return false }

        // Check transport type (built-in = kAudioDeviceTransportTypeBuiltIn)
        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        status = AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transportType)
        guard status == noErr else { return false }

        let isBuiltIn = transportType == kAudioDeviceTransportTypeBuiltIn
        if isBuiltIn {
            logActivity(.alarm, "Found built-in speaker: device ID \(deviceID)")
        }
        return isBuiltIn
    }

    // MARK: - System Alert Fallback

    private func playSystemAlert() {
        isPlaying = true
        playBeepLoop()
    }

    private func playBeepLoop() {
        guard isPlaying else { return }
        NSSound.beep()
        beepTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.playBeepLoop()
        }
    }

    deinit {
        stopAlarm()
    }
}
