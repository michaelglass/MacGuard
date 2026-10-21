// TamperGuard.swift
// MacGuard - Anti-Theft Alarm for macOS

import AppKit
import Darwin
import Security
import ServiceManagement
import SwiftUI

/// On-disk record that a session is armed. Exists from `.armed` until stand
/// down, so finding one whose process is gone means MacGuard was killed.
struct ArmedMarker: Codable, Equatable {
    let trustedDeviceHasLeft: Bool
    let armedAt: Date
    let pid: Int32

    init(_ session: ArmSession, armedAt: Date, pid: Int32) {
        trustedDeviceHasLeft = session.trustedDeviceHasLeft
        self.armedAt = armedAt
        self.pid = pid
    }

    var session: ArmSession { ArmSession(trustedDeviceHasLeft: trustedDeviceHasLeft) }
}

/// What a fresh launch should do, decided from what it found on disk.
enum LaunchDecision: Equatable {
    case normal
    case resumeAfterTamper(ArmSession)

    /// - Parameters:
    ///   - markerData: contents of the marker file, `nil` if absent
    ///   - isAlive: whether a pid is a live MacGuard process (not this one)
    static func decide(markerData: Data?, isAlive: (Int32) -> Bool) -> LaunchDecision {
        guard let markerData else { return .normal }
        // Unreadable marker: something wrote or truncated it while armed.
        // Fail closed - treat as armed, without proximity-disarm rights.
        guard let marker = try? TamperGuard.decoder.decode(ArmedMarker.self, from: markerData) else {
            return .resumeAfterTamper(ArmSession(trustedDeviceHasLeft: false))
        }
        return isAlive(marker.pid) ? .normal : .resumeAfterTamper(marker.session)
    }
}

/// State of the relaunch watchdog, parsed from the setting + launchd status.
enum WatchdogStatus: Equatable {
    case off
    case active
    /// The user must allow MacGuard in System Settings > Login Items.
    case needsApproval
    case unavailable(String)

    init(enabled: Bool, service: SMAppService.Status, registrationError: String?) {
        guard enabled else { self = .off; return }
        if let registrationError { self = .unavailable(registrationError); return }
        switch service {
        case .enabled: self = .active
        case .requiresApproval: self = .needsApproval
        case .notRegistered: self = .unavailable("Not registered")
        case .notFound: self = .unavailable("Launch agent missing from app bundle")
        @unknown default: self = .unavailable("Unknown status")
        }
    }
}

/// Detects and recovers from MacGuard being killed while armed.
///
/// Two halves: the app writes `ArmedMarker` while armed (driven by
/// `AlarmEffect.persistArmedMarker` / `.clearArmedMarker`), and a KeepAlive
/// launchd agent running this same binary with `--watchdog` relaunches the
/// app whenever a marker exists but its process is gone. The relaunched app
/// sees the marker and sounds `TriggerCause.tamper`.
@MainActor
final class TamperGuard: ObservableObject {
    static let shared = TamperGuard()

    static let agentPlistName = "com.shenglong.macguard.watchdog.plist"

    nonisolated static let encoder = JSONEncoder()
    nonisolated static let decoder = JSONDecoder()

    @AppStorage("tamperProtection") private var enabledRaw = true
    /// Code signature the watchdog was registered with (see `syncAgent`).
    @AppStorage("watchdogRegisteredCode") private var registeredCode = ""
    @Published private(set) var status: WatchdogStatus = .off
    private var registrationError: String?

    private var agent: SMAppService { SMAppService.agent(plistName: Self.agentPlistName) }

    private init() {}

    /// Tamper protection (default on). Setting it registers/unregisters the watchdog.
    var isEnabled: Bool {
        get { enabledRaw }
        set {
            enabledRaw = newValue
            if !newValue { clear() }
            syncAgent()
        }
    }

    // MARK: Marker

    nonisolated static var markerURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("MacGuard/armed-session", isDirectory: false)
    }

    func persist(_ session: ArmSession) {
        guard isEnabled else { return }
        let marker = ArmedMarker(session, armedAt: Date(), pid: getpid())
        do {
            try FileManager.default.createDirectory(at: Self.markerURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.encoder.encode(marker).write(to: Self.markerURL, options: .atomic)
        } catch {
            logActivity(.system, "Failed to write armed marker: \(error.localizedDescription)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.markerURL)
    }

    /// Decide at launch whether a previous instance was killed while armed.
    func launchDecision() -> LaunchDecision {
        guard isEnabled else { clear(); return .normal }
        let data = try? Data(contentsOf: Self.markerURL)
        let me = getpid()
        return LaunchDecision.decide(markerData: data) { $0 != me && Self.isMacGuardProcess($0) }
    }

    // MARK: Watchdog agent

    func syncAgent() {
        registrationError = nil
        do {
            if isEnabled {
                // launchd pins the agent to the code signature that registered
                // it. After an update or rebuild it refuses to start the
                // watchdog (EX_CONFIG) while status still reads `.enabled`, so
                // a changed signature re-registers.
                let code = Self.ownCodeHash ?? ""
                if agent.status == .enabled && registeredCode != code {
                    logActivity(.system, "App signature changed - re-registering tamper watchdog")
                    try agent.unregister()
                }
                if agent.status != .enabled {
                    try agent.register()
                    registeredCode = code
                }
            } else if agent.status == .enabled || agent.status == .requiresApproval {
                try agent.unregister()
            }
        } catch {
            registrationError = error.localizedDescription
            logActivity(.system, "Tamper watchdog \(isEnabled ? "registration" : "removal") failed: \(error.localizedDescription)")
        }
        status = WatchdogStatus(enabled: isEnabled, service: agent.status, registrationError: registrationError)
    }

    // MARK: Process identity

    /// Whether `pid` is a running process of this same executable.
    nonisolated static func isMacGuardProcess(_ pid: Int32) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        return path == ownExecutablePath
    }

    /// This build's code directory hash (hex), or nil when unsigned. Fixed
    /// for the life of the process, so computed once.
    nonisolated static let ownCodeHash: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }()

    nonisolated static var ownExecutablePath: String? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }
}

/// Entry point for `MacGuard --watchdog`, run by the launchd agent.
/// Never shows UI; relaunches the app when an armed marker is orphaned.
enum Watchdog {
    static let argument = "--watchdog"
    private static let pollInterval: TimeInterval = 2
    /// After a relaunch, give the new instance time to rewrite the marker.
    private static let relaunchBackoff: TimeInterval = 15

    static func run() -> Never {
        var nextAttempt = Date.distantPast
        let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
            guard Date() >= nextAttempt,
                  let data = try? Data(contentsOf: TamperGuard.markerURL) else { return }
            let decision = LaunchDecision.decide(markerData: data) { TamperGuard.isMacGuardProcess($0) }
            guard case .resumeAfterTamper = decision else { return }
            nextAttempt = Date().addingTimeInterval(relaunchBackoff)
            relaunchApp()
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run()
        exit(0)
    }

    private static func relaunchApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        // The watchdog shares the bundle; force a real app instance.
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                FileHandle.standardError.write(Data("MacGuard watchdog relaunch failed: \(error)\n".utf8))
            }
        }
    }
}
