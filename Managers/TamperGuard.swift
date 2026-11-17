// TamperGuard.swift
// MacGuard - Anti-Theft Alarm for macOS

import AppKit
import Darwin
import Security
import ServiceManagement
import SwiftUI

/// Exists from `.armed` until stand down: one whose process is gone means MacGuard was killed.
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

enum LaunchDecision: Equatable {
    case normal
    case resumeAfterTamper(ArmSession)

    static func decide(markerData: Data?, isAlive: (Int32) -> Bool) -> LaunchDecision {
        guard let markerData else { return .normal }
        // Unreadable marker: fail closed, without proximity-disarm rights.
        guard let marker = try? TamperGuard.decoder.decode(ArmedMarker.self, from: markerData) else {
            return .resumeAfterTamper(ArmSession(trustedDeviceHasLeft: false))
        }
        return isAlive(marker.pid) ? .normal : .resumeAfterTamper(marker.session)
    }
}

/// Code directory hash (hex) of a signed binary.
struct CodeHash: Equatable, RawRepresentable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

/// What `syncAgent` does to the launchd agent.
enum WatchdogSync: Equatable {
    case keep
    case register
    /// launchd pins the agent to the registering signature; after a rebuild it
    /// refuses to start it (EX_CONFIG) while still `.enabled`.
    case reregister
    case unregister

    /// `nil` hashes mean unsigned (own) or never registered / registered unsigned (stored).
    static func plan(enabled: Bool, service: SMAppService.Status,
                     registered: CodeHash?, own: CodeHash?) -> WatchdogSync {
        if enabled {
            guard service == .enabled else { return .register }
            return registered == own ? .keep : .reregister
        }
        return service == .enabled || service == .requiresApproval ? .unregister : .keep
    }
}

enum WatchdogSyncOutcome: Equatable {
    case synced
    case failed(reason: String)
}

enum WatchdogStatus: Equatable {
    case off
    case active
    /// Allow MacGuard in System Settings > Login Items.
    case needsApproval
    case unavailable(String)

    init(enabled: Bool, outcome: WatchdogSyncOutcome, service: SMAppService.Status) {
        guard enabled else { self = .off; return }
        switch outcome {
        case .failed(let reason): self = .unavailable(reason)
        case .synced:
            switch service {
            case .enabled: self = .active
            case .requiresApproval: self = .needsApproval
            case .notRegistered: self = .unavailable("Not registered")
            case .notFound: self = .unavailable("Launch agent missing from app bundle")
            @unknown default: self = .unavailable("Unknown status")
            }
        }
    }
}

/// The app writes `ArmedMarker` while armed; a KeepAlive launchd agent (this binary
/// with `--watchdog`) relaunches it when the marker's process is gone.
@MainActor
final class TamperGuard: ObservableObject {
    static let shared = TamperGuard()

    static let agentPlistName = "com.shenglong.macguard.watchdog.plist"

    nonisolated static let encoder = JSONEncoder()
    nonisolated static let decoder = JSONDecoder()

    @AppStorage("tamperProtection") private var enabledRaw = true
    /// "" when never registered (or registered while unsigned).
    @AppStorage("watchdogRegisteredCode") private var registeredCodeRaw = ""
    @Published private(set) var status: WatchdogStatus = .off

    private var agent: SMAppService { SMAppService.agent(plistName: Self.agentPlistName) }

    private init() {}

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

    func launchDecision() -> LaunchDecision {
        guard isEnabled else { clear(); return .normal }
        let data = try? Data(contentsOf: Self.markerURL)
        let me = getpid()
        return LaunchDecision.decide(markerData: data) { $0 != me && Self.isMacGuardProcess($0) }
    }

    // MARK: Watchdog agent

    func syncAgent() {
        let enabled = isEnabled
        let plan = WatchdogSync.plan(enabled: enabled, service: agent.status,
                                     registered: CodeHash(rawValue: registeredCodeRaw), own: Self.ownCodeHash)
        let outcome: WatchdogSyncOutcome
        do {
            try apply(plan)
            outcome = .synced
        } catch {
            outcome = .failed(reason: error.localizedDescription)
            logActivity(.system, "Tamper watchdog \(enabled ? "registration" : "removal") failed: \(error.localizedDescription)")
        }
        status = WatchdogStatus(enabled: enabled, outcome: outcome, service: agent.status)
    }

    private func apply(_ plan: WatchdogSync) throws {
        switch plan {
        case .keep:
            break
        case .register:
            try register()
        case .reregister:
            logActivity(.system, "App signature changed - re-registering tamper watchdog")
            try agent.unregister()
            if agent.status != .enabled { try register() }
        case .unregister:
            try agent.unregister()
        }
    }

    private func register() throws {
        try agent.register()
        registeredCodeRaw = Self.ownCodeHash?.rawValue ?? ""
    }

    // MARK: Process identity

    nonisolated static func isMacGuardProcess(_ pid: Int32) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        return path == ownExecutablePath
    }

    /// nil when unsigned.
    nonisolated static let ownCodeHash: CodeHash? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return CodeHash(rawValue: unique.map { String(format: "%02x", $0) }.joined())
    }()

    nonisolated static var ownExecutablePath: String? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }
}

/// `MacGuard --watchdog`, run by the launchd agent. Never shows UI.
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
