// AlarmAudioManager.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import AVFoundation
import Cocoa
import CoreAudio

/// A CoreAudio device. The HAL's "unknown" id (0) never becomes one.
struct AudioDevice: Equatable, CustomStringConvertible {
    let id: AudioDeviceID

    init?(_ id: AudioDeviceID) {
        guard id != kAudioObjectUnknown else { return nil }
        self.id = id
    }

    var description: String { "\(id)" }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static var defaultOutput: AudioDevice? {
        get { get(system, address(kAudioHardwarePropertyDefaultOutputDevice), as: AudioDeviceID(0)).flatMap(AudioDevice.init) }
        set {
            guard let newValue, !set(system, address(kAudioHardwarePropertyDefaultOutputDevice), newValue.id) else { return }
            logActivity(.alarm, "Failed to set output device \(newValue)")
        }
    }

    static var all: [AudioDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(AudioDevice.init)
    }

    var isBuiltInOutput: Bool {
        var streams = Self.address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0 else { return false }
        return Self.get(id, Self.address(kAudioDevicePropertyTransportType), as: UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
    }

    /// Average output volume (0...1), or nil if the device exposes none.
    var volume: Float? {
        let values = outputElements(kAudioDevicePropertyVolumeScalar).compactMap {
            Self.get(id, Self.output(kAudioDevicePropertyVolumeScalar, $0), as: Float32(0))
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    /// False when the device exposes no mute control.
    var isMuted: Bool {
        outputElements(kAudioDevicePropertyMute).contains { Self.get(id, Self.output(kAudioDevicePropertyMute, $0), as: UInt32(0)).map { $0 != 0 } ?? false }
    }

    func setVolume(_ volume: Float) {
        for element in outputElements(kAudioDevicePropertyVolumeScalar) {
            Self.set(id, Self.output(kAudioDevicePropertyVolumeScalar, element), Float32(volume.clamped(to: 0...1)))
        }
    }

    func unmute() {
        for element in outputElements(kAudioDevicePropertyMute) {
            Self.set(id, Self.output(kAudioDevicePropertyMute, element), UInt32(0))
        }
    }

    /// Volume and mute listener addresses on this device.
    var enforcementAddresses: [AudioObjectPropertyAddress] {
        [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].flatMap { selector in
            outputElements(selector).map { Self.output(selector, $0) }
        }
    }

    /// Many devices only expose per-channel (1, 2) volume, not the main element.
    private func outputElements(_ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        func has(_ element: AudioObjectPropertyElement) -> Bool {
            var address = Self.output(selector, element)
            return AudioObjectHasProperty(id, &address)
        }
        return has(kAudioObjectPropertyElementMain) ? [kAudioObjectPropertyElementMain] : [1, 2].filter(has)
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func output(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    private static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }
}

/// Performs AlarmPlayback's decisions: reads CoreAudio into messages and runs the commands.
class AlarmAudioManager {
    private typealias Playback = AlarmPlayback
    private var state: Playback.State<AVAudioPlayer> = .idle(prepared: nil)
    private lazy var outputWatch = OutputWatch { [weak self] in self?.send(.outputChanged(AudioDevice.defaultOutput)) }
    private let beeper = Beeper()

    /// Pre-load audio file so it's ready for instant playback
    func prepare() { send(.prepare) }

    /// Release pre-loaded audio
    func unprepare() { send(.unprepare) }

    func playAlarm() {
        // Built-in speaker before volume changes
        send(.start(Playback.Start(
            targetVolume: Float(AppSettings.shared.alarmVolume),
            speaker: AudioDevice.all.first(where: \.isBuiltInOutput).map(Playback.Reading.init),
            output: AudioDevice.defaultOutput.map(Playback.Reading.init))))
    }

    /// Stop the alarm and restore what it changed
    func stopAlarm() { send(.stop) }

    private func send(_ msg: Playback.Msg<AVAudioPlayer>) {
        let (next, cmds) = Playback.update(state, msg)
        state = next
        cmds.forEach(perform)
    }

    private func perform(_ cmd: Playback.Cmd<AVAudioPlayer>) {
        switch cmd {
        case .preload:
            let settings = AppSettings.shared
            if settings.customSoundUnavailable {
                logActivity(.alarm, "Custom sound '\(settings.customSoundName)' is unavailable - using the default sound")
            }
            send(.preloaded(loadSound()))
        case .loadSound(let start):
            send(.soundLoaded(loadSound(), then: start))
        case .setDefaultOutput(let device):
            AudioDevice.defaultOutput = device
        case .setOutputVolume(let volume):
            // CoreAudio, not AppleScript: enforcement runs on every volume change, on the main thread.
            AudioDevice.defaultOutput?.setVolume(volume)
            logActivity(.alarm, "Set volume to \(Int(volume.clamped(to: 0...1) * 100))%")
        case .unmuteOutput:
            AudioDevice.defaultOutput?.unmute()
        case .readOutput:
            send(.outputRead(AudioDevice.defaultOutput.map(Playback.Reading.init)))
        case .watch(let device):
            outputWatch.watch(device)
        case .unwatch:
            outputWatch.unwatch()
        case .playSound(let player):
            player.play()
        case .resumeSound(let player):
            guard !player.isPlaying else { return }
            player.play()
            logActivity(.alarm, "Alarm playback resumed after an output change")
        case .stopSound(let player):
            player.stop()
        case .startBeeping:
            beeper.start()
        case .stopBeeping:
            beeper.stop()
        case .log(let message):
            logActivity(.alarm, message)
        }
    }

    private func loadSound() -> AVAudioPlayer? {
        guard let file = AppSettings.shared.alarmSoundFile else { return nil }
        do {
            let player = try AVAudioPlayer(contentsOf: file.url)
            player.numberOfLoops = -1
            player.volume = 1.0
            player.prepareToPlay()
            return player
        } catch {
            logActivity(.alarm, "Failed to load alarm sound: \(error)")
            return nil
        }
    }

    deinit {
        stopAlarm()
    }
}

private extension AlarmPlayback.Reading {
    init(_ device: AudioDevice) {
        self.init(device: device, volume: device.volume, isMuted: device.isMuted)
    }
}

/// Listeners on the default-output selection and on one device's volume and mute
/// (keys, connecting headphones).
private final class OutputWatch {
    private let block: AudioObjectPropertyListenerBlock
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress)] = []

    init(_ onChange: @escaping () -> Void) {
        block = { _, _ in onChange() }
    }

    func watch(_ device: AudioDevice?) {
        unwatch()
        let targets = [(AudioObjectID(kAudioObjectSystemObject), AudioDevice.address(kAudioHardwarePropertyDefaultOutputDevice))]
            + (device.map { d in d.enforcementAddresses.map { (d.id, $0) } } ?? [])
        for (object, address) in targets {
            var address = address
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                listeners.append((object, address))
            }
        }
        logActivity(.alarm, "Volume enforcement started")
    }

    func unwatch() {
        for (object, address) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners = []
    }
}

/// System alert fallback when there is no playable sound.
private final class Beeper {
    private var timer: Timer?

    func start() {
        NSSound.beep()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in NSSound.beep() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
