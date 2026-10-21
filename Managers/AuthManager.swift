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

    /// Why this PIN is among the first a thief would try, if it is.
    var weakness: PINWeakness? {
        let values = digits.compactMap(\.wholeNumberValue)
        let steps = Set(zip(values, values.dropFirst()).map { $1 - $0 })
        if digits == "1234" || digits == "12345" { return .luggage }
        if steps == [0] { return .repeated }
        if steps == [1] || steps == [-1] { return .sequence }
        if PINWeakness.wellKnown.contains(digits) { return .common }
        return nil
    }
}

/// A guessable PIN. Saving one takes a second confirmation.
enum PINWeakness: Equatable {
    /// 1234 / 12345 (Spaceballs)
    case luggage
    /// One digit repeated: 0000, 999999
    case repeated
    /// A straight run: 2345, 9876
    case sequence
    /// Other well-known PINs
    case common

    static let wellKnown: Set<String> = ["1212", "2580", "1122", "1313", "6969", "4321", "2000", "1004", "123123", "121212", "112233"]

    var message: String {
        switch self {
        case .luggage:
            return "“That's the kind of thing an idiot would have on his luggage!” - Dark Helmet"
        case .repeated: return "A repeated digit is one of the first PINs anyone tries."
        case .sequence: return "A straight run of digits is one of the first PINs anyone tries."
        case .common: return "This is one of the most common PINs."
        }
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

/// Attempt limiting for PIN entry, as a pure value so the schedule is testable.
/// `freeAttempts` wrong guesses are allowed; each further one locks out for
/// 30s, doubling (capped at 30s * 2^10 ≈ 8.5h).
struct PINThrottle: Equatable {
    static let freeAttempts = 3
    static let baseLockout: TimeInterval = 30

    private(set) var failedAttempts = 0
    private(set) var lockedUntil: Date?

    /// The lockout end if `now` is still inside one.
    func lockout(at now: Date) -> Date? {
        guard let lockedUntil, now < lockedUntil else { return nil }
        return lockedUntil
    }

    mutating func recordSuccess() {
        self = PINThrottle()
    }

    /// Records a wrong attempt; returns the new lockout end, if one starts.
    mutating func recordFailure(at now: Date) -> Date? {
        failedAttempts += 1
        let excess = failedAttempts - Self.freeAttempts
        guard excess > 0 else { return nil }
        let until = now.addingTimeInterval(Self.baseLockout * pow(2, Double(min(excess - 1, 10))))
        lockedUntil = until
        return until
    }
}

/// Manages authentication for disarming the alarm (Touch ID / password + PIN fallback)
class AuthManager: ObservableObject {
    // MARK: - Published Properties

    @Published var hasBiometrics = false
    @Published var hasPIN = false

    // MARK: - Private Properties

    private let keychainService = "com.shenglong.macguard"
    private let keychainAccount = "userPIN"

    private var throttle = PINThrottle()


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
            logActivity(.system, "Biometrics not available: \(error.localizedDescription)")
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
            logActivity(.system, "PIN saved to Keychain")
        } else {
            logActivity(.system, "Failed to save PIN: \(status)")
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

    /// Check an entered PIN, rate-limited by `PINThrottle` so a 4-digit PIN
    /// cannot be brute-forced while the alarm counts down.
    /// The input is not parsed as a `PIN`: PINs saved by older versions were
    /// not restricted to digits and must keep working.
    func verifyPIN(_ input: String, now: Date = Date()) -> PINVerification {
        if let until = throttle.lockout(at: now) {
            return .lockedOut(until: until)
        }
        guard let stored = retrievePIN() else { return .noPINConfigured }

        if Self.constantTimeEquals(stored, Data(input.utf8)) {
            throttle.recordSuccess()
            return .accepted(OwnerAuthentication(.pin))
        }

        let until = throttle.recordFailure(at: now)
        logActivity(.system, "Incorrect PIN (attempt \(throttle.failedAttempts))")
        return until.map { .lockedOut(until: $0) } ?? .rejected
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
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
            logActivity(.system, "PIN deleted from Keychain")
            return true
        }
        return false
    }
}
