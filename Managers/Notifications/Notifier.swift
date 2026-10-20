// Notifier.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation

/// Stable identifiers for the built-in notifiers (also UserDefaults key stems).
enum NotifierID: String, CaseIterable, Identifiable, Comparable {
    case notificationCenter, mail, messages, shortcuts, webhook

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notificationCenter: return "Notification Center"
        case .mail: return "Mail"
        case .messages: return "Messages"
        case .shortcuts: return "Shortcuts"
        case .webhook: return "Webhook"
        }
    }

    static func < (a: NotifierID, b: NotifierID) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// A delivery channel. An instance exists only with a complete, parsed
/// configuration, so every notifier the dispatcher holds can be sent to.
protocol Notifier {
    var id: NotifierID { get }
    func send(_ alert: Alert) async throws
}

struct NotifierError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
