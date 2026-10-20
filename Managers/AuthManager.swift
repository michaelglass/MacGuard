// AuthManager.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import LocalAuthentication
import Security

/// Proof that the owner just authenticated.
/// The initializer is fileprivate, so only `AuthManager` can mint one and
/// `AlarmStateManager.disarm(_:)` cannot be reached from an unauthenticated path.
struct OwnerAuthentication {
    enum Method: String {
        case system = "Touch ID / password"
        case pin = "PIN"
    }

    let method: Method

    fileprivate init(_ method: Method) {
        self.method = method
    }
}

/// A PIN that satisfies the format rules (4-8 ASCII digits).
/// Holding a `PIN` means it has already been checked.
struct PIN {
    static let allowedLengths = 4...8

    fileprivate let digits: String

    init?(_ raw: String) {
        guard Self.allowedLengths.contains(raw.count),
              raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        digits = raw
    }
}

/// Outcome of a PIN attempt.
enum PINVerification {
    case accepted(OwnerAuthentication)
    case rejected
    /// Too many wrong attempts; no attempt is evaluated before this date.
    case lockedOut(until: Date)
    case noPINConfigured
}

/// Manages authentication for disarming the alarm (Touch ID / password + PIN fallback)
class AuthManager: ObservableObject {
    // MARK: - Published Properties

    @Published var hasBiometrics = false
    @Published var hasPIN = false

    // MARK: - Private Properties

    private let keychainService = "com.shenglong.macguard"
    private let keychainAccount = "userPIN"

    /// Wrong attempts allowed before a lockout begins.
    private let freeAttempts = 3
    private var failedAttempts = 0
    private var lockedUntil: Date?

    // MARK: - Logging Helper

    private func log(_ category: ActivityLogCategory, _ message: String) {
        Task { @MainActor in
            ActivityLogManager.shared.log(category, message)
        }
    }

    // MARK: - Initialization

    init() {
        checkBiometrics()
        hasPIN = retrievePIN() != nil
    }

    // MARK: - System Authentication

    /// Check if biometric authentication is available (used for labelling)
    func checkBiometrics() {
        let context = LAContext()
        var error: NSError?
        hasBiometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        if let error = error {
            log(.system, "Biometrics not available: \(error.localizedDescription)")
        }
    }

    /// Authenticate with Touch ID, falling back to the login password.
    /// Using `.deviceOwnerAuthentication` means a Mac without Touch ID (or
    /// with the lid closed on an external display) can still disarm.
    func authenticate(completion: @escaping (OwnerAuthentication?) -> Void) {
        let context = LAContext()
        let reason = "Authenticate to disable MacGuard alarm"

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                completion(success ? OwnerAuthentication(.system) : nil)
            }
        }
    }

    // MARK: - PIN Management

    /// Save PIN to Keychain
    /// - Returns: true if saved successfully
    @discardableResult
    func savePIN(_ pin: PIN) -> Bool {
        // Delete existing PIN first
        deletePIN()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: Data(pin.digits.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        hasPIN = status == errSecSuccess

        if hasPIN {
            log(.system, "PIN saved to Keychain")
        } else {
            log(.system, "Failed to save PIN: \(status)")
        }

        return hasPIN
    }

    /// Retrieve the stored PIN bytes from Keychain
    private func retrievePIN() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Check an entered PIN. Wrong attempts beyond `freeAttempts` lock out
    /// for a doubling period (30s, 60s, 120s, ...) so a 4-digit PIN cannot be
    /// brute-forced while the alarm counts down.
    /// The input is not parsed as a `PIN`: PINs saved by older versions were
    /// not restricted to digits and must keep working.
    func verifyPIN(_ input: String, now: Date = Date()) -> PINVerification {
        if let lockedUntil, now < lockedUntil {
            return .lockedOut(until: lockedUntil)
        }
        guard let stored = retrievePIN() else { return .noPINConfigured }

        if Self.constantTimeEquals(stored, Data(input.utf8)) {
            failedAttempts = 0
            lockedUntil = nil
            return .accepted(OwnerAuthentication(.pin))
        }

        failedAttempts += 1
        log(.system, "Incorrect PIN (attempt \(failedAttempts))")
        let excess = failedAttempts - freeAttempts
        guard excess > 0 else { return .rejected }

        let until = now.addingTimeInterval(30 * pow(2, Double(min(excess - 1, 10))))
        lockedUntil = until
        return .lockedOut(until: until)
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Delete PIN from Keychain
    /// - Returns: true if deleted successfully
    @discardableResult
    func deletePIN() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            hasPIN = false
            log(.system, "PIN deleted from Keychain")
            return true
        }
        return false
    }
}
