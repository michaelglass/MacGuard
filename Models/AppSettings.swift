// AppSettings.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import AVFoundation
import SwiftUI

/// Proximity distance presets for trusted device detection
enum ProximityPreset: String, CaseIterable, Identifiable {
    case near = "Near"      // ~1-2m
    case medium = "Medium"  // ~3-5m (default)
    case far = "Far"        // ~7-10m

    var id: String { rawValue }

    var thresholds: ProximityThresholds {
        switch self {
        case .near: return ProximityThresholds(present: -60, away: -70)
        case .medium: return ProximityThresholds(present: -70, away: -80)
        case .far: return ProximityThresholds(present: -80, away: -95)
        }
    }

    /// Human-readable description
    var description: String {
        switch self {
        case .near: return "~1-2 meters"
        case .medium: return "~3-5 meters"
        case .far: return "~7-10 meters"
        }
    }
}

/// A user-chosen detection centre in dBm, within the slider's range.
struct DetectionRange: Equatable {
    static let range: ClosedRange<Int> = -100 ... -55
    static let `default` = DetectionRange(clamping: -65)

    let dBm: Int

    init(clamping raw: Int) {
        dBm = raw.clamped(to: Self.range)
    }

    /// A fixed hysteresis band around the centre.
    var thresholds: ProximityThresholds { ProximityThresholds(present: dBm + 5, away: dBm - 5) }

    /// The closest preset this range still covers, if any.
    var nearestPreset: ProximityPreset? {
        ProximityPreset.allCases.first { thresholds.away >= $0.thresholds.away }
    }
}

enum ProximityDistance: Equatable {
    case preset(ProximityPreset)
    case custom(DetectionRange)

    static let `default` = ProximityDistance.preset(.medium)

    var thresholds: ProximityThresholds {
        switch self {
        case .preset(let preset): return preset.thresholds
        case .custom(let range): return range.thresholds
        }
    }
}

/// The stored form of a setting that is a preset or a custom value: the preset's
/// raw value, or "custom:<payload>" with a non-empty payload.
enum StoredChoice<Preset: RawRepresentable> where Preset.RawValue == String {
    case preset(Preset)
    case custom(String)

    private static var customPrefix: String { "custom:" }

    init?(rawValue: String) {
        if let preset = Preset(rawValue: rawValue) {
            self = .preset(preset)
        } else if rawValue.hasPrefix(Self.customPrefix), rawValue.count > Self.customPrefix.count {
            self = .custom(String(rawValue.dropFirst(Self.customPrefix.count)))
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .preset(let preset): return preset.rawValue
        case .custom(let payload): return Self.customPrefix + payload
        }
    }
}

/// Stored as "Near"/"Medium"/"Far" or "custom:<dBm>".
extension ProximityDistance: RawRepresentable {
    private typealias Stored = StoredChoice<ProximityPreset>

    init?(rawValue: String) {
        switch Stored(rawValue: rawValue) {
        case .preset(let preset): self = .preset(preset)
        case .custom(let payload):
            guard let dBm = Int(payload) else { return nil }
            self = .custom(DetectionRange(clamping: dBm))
        case nil: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .preset(let preset): return Stored.preset(preset).rawValue
        case .custom(let range): return Stored.custom(String(range.dBm)).rawValue
        }
    }
}

/// The Detection Distance menu: the presets plus one "Custom" entry, whatever its dBm.
enum ProximityMenuItem: Hashable, Identifiable {
    case preset(ProximityPreset)
    case custom

    init(_ distance: ProximityDistance) {
        switch distance {
        case .preset(let preset): self = .preset(preset)
        case .custom: self = .custom
        }
    }

    var id: String { label }

    var label: String {
        switch self {
        case .preset(let preset): return "\(preset.rawValue) (\(preset.description))"
        case .custom: return "Custom"
        }
    }

    static let offered: [ProximityMenuItem] = ProximityPreset.allCases.map(ProximityMenuItem.preset) + [.custom]
}

/// Available alarm sounds
enum AlarmSound: String, CaseIterable, Identifiable {
    // Bundled sound
    case dontTouchMyMac = "Don't Touch My Mac"
    // System sounds
    case funk = "Funk"
    case basso = "Basso"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case glass = "Glass"
    case hero = "Hero"
    case morse = "Morse"
    case ping = "Ping"
    case pop = "Pop"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case tink = "Tink"

    var id: String { rawValue }

    var file: PlayableSound? {
        switch self {
        case .dontTouchMyMac:
            return ResourceBundle.url(forResource: "dont-touch-my-mac", withExtension: "mp3", subdirectory: "Resources")
                .flatMap(PlayableSound.init(url:))
        case .funk, .basso, .blow, .bottle, .frog, .glass, .hero, .morse, .ping, .pop, .purr, .sosumi, .submarine, .tink:
            return PlayableSound(url: URL(fileURLWithPath: "/System/Library/Sounds/\(rawValue).aiff"))
        }
    }
}

/// The stored alarm sound choice.
enum AlarmSoundChoice: Equatable {
    case builtIn(AlarmSound)
    case custom(URL)

    static let `default` = AlarmSoundChoice.builtIn(.dontTouchMyMac)

    /// Checks a custom file now: it may have moved since it was chosen.
    var resolved: ResolvedAlarmSound {
        switch self {
        case .builtIn(let sound): return .builtIn(sound)
        case .custom(let url): return PlayableSound(url: url).map(ResolvedAlarmSound.custom) ?? .customUnavailable(url)
        }
    }
}

/// Stored as the built-in name or "custom:<path>".
extension AlarmSoundChoice: RawRepresentable {
    private typealias Stored = StoredChoice<AlarmSound>

    init?(rawValue: String) {
        switch Stored(rawValue: rawValue) {
        case .preset(let sound): self = .builtIn(sound)
        case .custom(let path): self = .custom(URL(fileURLWithPath: path))
        case nil: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .builtIn(let sound): return Stored.preset(sound).rawValue
        case .custom(let url): return Stored.custom(url.path).rawValue
        }
    }
}

enum ResolvedAlarmSound: Equatable {
    case builtIn(AlarmSound)
    case custom(PlayableSound)
    case customUnavailable(URL)

    /// `nil` only if even the bundled sound is missing (the caller beeps).
    var file: PlayableSound? {
        switch self {
        case .builtIn(let sound): return sound.file ?? AlarmSound.dontTouchMyMac.file
        case .custom(let sound): return sound
        case .customUnavailable: return AlarmSound.dontTouchMyMac.file
        }
    }
}

/// The Alarm Sound menu: built-in sounds plus a "Custom..." entry that opens a file picker.
enum AlarmSoundMenuItem: Hashable, Identifiable {
    case builtIn(AlarmSound)
    case custom

    /// An unplayable custom file shows as the default it falls back to.
    init(_ sound: ResolvedAlarmSound) {
        switch sound {
        case .builtIn(let sound): self = .builtIn(sound)
        case .custom: self = .custom
        case .customUnavailable: self = .builtIn(.dontTouchMyMac)
        }
    }

    var id: String { label }

    var label: String {
        switch self {
        case .builtIn(let sound): return sound.rawValue
        case .custom: return "Custom..."
        }
    }

    /// Computed once: each check opens the file.
    static let offered: [AlarmSoundMenuItem] =
        AlarmSound.allCases.filter { $0.file != nil }.map(AlarmSoundMenuItem.builtIn) + [.custom]
}

/// A file `AVAudioPlayer` opens, with non-zero length, so a moved or corrupt file can't reach the alarm.
struct PlayableSound: Equatable {
    let url: URL

    init?(url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url), player.duration > 0 else { return nil }
        self.url = url
    }
}

enum CountdownDuration: Int, CaseIterable, Identifiable {
    case immediate = 0
    case s3 = 3, s5 = 5, s10 = 10, s15 = 15, s30 = 30

    static let `default` = CountdownDuration.s3

    var id: Int { rawValue }

    var countdown: Countdown? { Countdown(seconds: rawValue) }

    var label: String { self == .immediate ? "Immediately" : "\(rawValue) seconds" }
}

/// Lets the owner walk away, and keeps the arming keystroke from being an intrusion.
enum ExitDelay: Int, CaseIterable, Identifiable {
    case s1 = 1, s5 = 5, s10 = 10, s30 = 30

    static let `default` = ExitDelay.s1

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var label: String { rawValue == 1 ? "1 second" : "\(rawValue) seconds" }
}

enum GracePeriod: Int, CaseIterable, Identifiable {
    case s5 = 5, s10 = 10, s15 = 15, s30 = 30, s60 = 60

    static let `default` = GracePeriod.s15

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var label: String { "\(rawValue) sec" }
}

/// A near-silent alarm is not offered.
struct AlarmVolume: Equatable {
    static let range: ClosedRange<Double> = 0.5...1.0

    let value: Double

    init(clamping raw: Double) {
        value = raw.isFinite ? raw.clamped(to: Self.range) : Self.range.upperBound
    }
}

/// Folds older installs' keys into current ones: custom sound path and dBm, single trusted device.
/// Runs once at app launch (main.swift), before anything reads settings.
enum SettingsMigration {
    static let alarmSoundKey = "alarmSoundChoice"
    static let proximityDistanceKey = "detectionDistance"
    static let trustedDevicesKey = "MacGuard.trustedDevices"

    private enum Legacy {
        /// One JSON `TrustedDevice`, before several were allowed.
        static let trustedDevice = "MacGuard.trustedDevice"
        static let alarmSound = "alarmSound"
        static let customSoundPath = "customSoundPath"
        static let proximityDistance = "proximityDistance"
        static let customDetectionRange = "customDetectionRange"
        /// Removed: only a device away during a session may disarm, so there is no mode.
        static let autoArmMode = "autoArmMode"
        static let customSound = "Custom..."
        static let customDistance = "Custom"
    }

    static func run(_ defaults: UserDefaults) {
        if defaults.object(forKey: alarmSoundKey) == nil, let raw = defaults.string(forKey: Legacy.alarmSound) {
            defaults.set(alarmSound(raw: raw, customPath: defaults.string(forKey: Legacy.customSoundPath)).rawValue,
                         forKey: alarmSoundKey)
        }
        if defaults.object(forKey: proximityDistanceKey) == nil, let raw = defaults.string(forKey: Legacy.proximityDistance) {
            let range = defaults.object(forKey: Legacy.customDetectionRange) as? Int
            defaults.set(proximityDistance(raw: raw, customDetectionRange: range).rawValue, forKey: proximityDistanceKey)
        }
        for key in [Legacy.alarmSound, Legacy.customSoundPath, Legacy.proximityDistance, Legacy.customDetectionRange,
                    Legacy.autoArmMode] {
            defaults.removeObject(forKey: key)
        }
        migrateTrustedDevice(defaults)
    }

    /// Only when the list is missing or unreadable, as loading used to fall back to the single device.
    private static func migrateTrustedDevice(_ defaults: UserDefaults) {
        guard decoded([TrustedDevice].self, defaults.data(forKey: trustedDevicesKey)) == nil,
              let device = decoded(TrustedDevice.self, defaults.data(forKey: Legacy.trustedDevice)),
              let list = try? JSONEncoder().encode([device]) else { return }
        defaults.set(list, forKey: trustedDevicesKey)
        defaults.removeObject(forKey: Legacy.trustedDevice)
    }

    private static func decoded<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// "Custom..." with no path used to play (and show) the default.
    private static func alarmSound(raw: String, customPath: String?) -> AlarmSoundChoice {
        if raw == Legacy.customSound, let path = customPath, !path.isEmpty {
            return .custom(URL(fileURLWithPath: path))
        }
        return AlarmSound(rawValue: raw).map(AlarmSoundChoice.builtIn) ?? .default
    }

    private static func proximityDistance(raw: String, customDetectionRange: Int?) -> ProximityDistance {
        if raw == Legacy.customDistance {
            return .custom(customDetectionRange.map(DetectionRange.init(clamping:)) ?? .default)
        }
        return ProximityPreset(rawValue: raw).map(ProximityDistance.preset) ?? .default
    }
}

/// App settings manager with UserDefaults persistence
class AppSettings: ObservableObject {
    static let shared = AppSettings()


    // MARK: - Published Settings

    @AppStorage("autoLockOnArm") var autoLockOnArm: Bool = false
    // Enums parse in AppStorage itself: an unoffered stored value reads as the default.
    @AppStorage(SettingsMigration.alarmSoundKey) private(set) var alarmSound: AlarmSoundChoice = .default
    @AppStorage("alarmVolume") private var alarmVolumeRaw: Double = 1.0
    @AppStorage("countdownDuration") var countdownDuration: CountdownDuration = .default
    @AppStorage("lidCloseProtection") private var _lidCloseProtection: Bool = false
    @AppStorage(SettingsMigration.proximityDistanceKey) var proximityDistance: ProximityDistance = .default
    @AppStorage("autoArmOnDeviceLeave") var autoArmOnDeviceLeave: Bool = false
    @AppStorage("exitDelay") var exitDelay: ExitDelay = .default
    @AppStorage("usbTriggerEnabled") var usbTriggerEnabled: Bool = true
    @AppStorage("motionTriggerEnabled") var motionTriggerEnabled: Bool = true
    @AppStorage("motionSensitivity") var motionSensitivity: MotionSensitivity = .medium
    @AppStorage("lidAngleTriggerEnabled") var lidAngleTriggerEnabled: Bool = true
    @AppStorage("networkTriggerEnabled") var networkTriggerEnabled: Bool = false
    @AppStorage("autoArmOnScreenLock") var autoArmOnScreenLock: Bool = false
    @AppStorage("autoArmGracePeriod") var autoArmGracePeriod: GracePeriod = .default

    var alarmVolume: Double {
        get { AlarmVolume(clamping: alarmVolumeRaw).value }
        set { alarmVolumeRaw = AlarmVolume(clamping: newValue).value }
    }

    /// Enabling only sticks if the admin prompt succeeds; disabling always clears it.
    var lidCloseProtection: Bool {
        get { _lidCloseProtection }
        set {
            guard newValue != _lidCloseProtection else { return }
            if setDisableSleep(newValue) || !newValue { _lidCloseProtection = newValue }
        }
    }

    /// On quit. pmset needs root, so this prompts for an admin password too.
    func resetLidCloseProtection() {
        guard _lidCloseProtection else { return }
        _ = setDisableSleep(false)
        _lidCloseProtection = false
    }

    private func setDisableSleep(_ on: Bool) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "do shell script \"pmset -a disablesleep \(on ? 1 : 0)\" with administrator privileges") else { return false }
        script.executeAndReturnError(&error)
        if let error {
            logActivity(.system, "Failed to set disablesleep \(on ? 1 : 0): \(error)")
            return false
        }
        logActivity(.system, "disablesleep \(on ? "enabled" : "disabled")")
        return true
    }

    private init() {}

    /// Plays it once, so it can be judged without arming.
    func chooseSound(_ sound: AlarmSound) {
        alarmSound = .builtIn(sound)
        previewSound()
    }

    /// Preview the selected alarm sound
    func previewSound() {
        guard let file = alarmSound.resolved.file,
              let sound = NSSound(contentsOf: file.url, byReference: true) else {
            NSSound.beep()
            return
        }
        sound.volume = Float(alarmVolume)
        sound.play()
    }

    /// Select custom sound file via file picker
    func selectCustomSound() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select an audio file for the alarm"

        if panel.runModal() == .OK, let url = panel.url {
            guard PlayableSound(url: url) != nil else {
                logActivity(.system, "Custom sound rejected: '\(url.lastPathComponent)' is not playable audio")
                return false
            }
            alarmSound = .custom(url)
            previewSound()
            return true
        }
        return false
    }
}
