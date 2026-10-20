// NotificationSettings.swift
// MacGuard - Anti-Theft Alarm for macOS

import SwiftUI

/// What the user has typed, exactly as stored. Not trusted: it is parsed
/// into notifiers by `NotifierDrafts.notifier(for:)`.
struct NotifierDrafts: Equatable {
    var enabled: Set<NotifierID> = []
    var mailTo = ""
    var messagesTo = ""
    var shortcutName = ""
    var webhookURL = ""

    /// The notifier `id` would be with the current drafts, or `nil` while its
    /// configuration is incomplete. The only way a notifier is constructed.
    func notifier(for id: NotifierID) -> (any Notifier)? {
        switch id {
        case .notificationCenter: return NotificationCenterNotifier()
        case .mail: return EmailAddress(mailTo).map { MailNotifier(recipient: $0) }
        case .messages: return MessagesRecipient(messagesTo).map { MessagesNotifier(recipient: $0) }
        case .shortcuts: return ShortcutName(shortcutName).map { ShortcutsNotifier(shortcut: $0) }
        case .webhook: return WebhookURL(webhookURL).map { WebhookNotifier(endpoint: $0) }
        }
    }

    /// Enabled notifiers whose configuration parses. An enabled flag whose
    /// draft no longer parses contributes nothing (and shows as off in the UI).
    func enabledNotifiers() -> [any Notifier] {
        NotifierID.allCases.filter(enabled.contains).compactMap(notifier(for:))
    }
}

/// UserDefaults-backed notification settings. Everything is off by default.
final class NotificationSettings: ObservableObject {
    static let shared = NotificationSettings()

    @AppStorage("notify.enabled") private var enabledRaw = ""
    @AppStorage("notify.includeArmed") var includeArmed = false
    @AppStorage("notify.mail.to") var mailTo = ""
    @AppStorage("notify.messages.to") var messagesTo = ""
    @AppStorage("notify.shortcuts.name") var shortcutName = ""
    @AppStorage("notify.webhook.url") var webhookURL = ""

    var drafts: NotifierDrafts {
        NotifierDrafts(
            enabled: Set(enabledRaw.split(separator: ",").compactMap { NotifierID(rawValue: String($0)) }),
            mailTo: mailTo, messagesTo: messagesTo, shortcutName: shortcutName, webhookURL: webhookURL
        )
    }

    var policy: AlertPolicy { AlertPolicy(includeArmed: includeArmed) }

    func enabledNotifiers() -> [any Notifier] { drafts.enabledNotifiers() }

    /// Whether `id` is on. Turning a notifier on succeeds only while its
    /// configuration parses; a notifier with a broken draft reads as off.
    func isEnabled(_ id: NotifierID) -> Bool {
        drafts.enabled.contains(id) && drafts.notifier(for: id) != nil
    }

    func setEnabled(_ id: NotifierID, _ on: Bool) {
        var ids = drafts.enabled
        if on {
            guard drafts.notifier(for: id) != nil else { return }
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        enabledRaw = NotifierID.allCases.filter(ids.contains).map(\.rawValue).joined(separator: ",")
    }

    private init() {}
}
