// AlarmState.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import Foundation

/// Facts about one arm session (from arming until disarm).
struct ArmSession: Equatable {
    /// A trusted device has been away at some point during this session.
    /// Only then may its return disarm: arming manually with the phone in your
    /// pocket must not let that same phone disarm a moment later.
    var trustedDeviceHasLeft: Bool
}

/// A running countdown. `remaining` is always in `1...total`, so a countdown
/// that has run out is not representable - it has become `.alarming`.
struct Countdown: Equatable {
    let total: Int
    private(set) var remaining: Int

    /// `nil` for a non-positive duration: the alarm sounds immediately.
    init?(seconds: Int) {
        guard seconds > 0 else { return nil }
        total = seconds
        remaining = seconds
    }

    /// The countdown one second later, or `nil` once it has expired.
    func ticked() -> Countdown? {
        guard remaining > 1 else { return nil }
        var next = self
        next.remaining -= 1
        return next
    }

    var progress: Double { Double(remaining) / Double(total) }
}

/// Represents the current state of the alarm system.
/// Data that only exists in some states lives inside those cases.
enum AlarmState: Equatable {
    /// App running, theft mode OFF
    case idle
    /// Arm requested; monitors start after a short delay (so the keystroke
    /// that locked the screen is not detected as an intrusion)
    case arming(ArmSession)
    /// Theft mode ON, monitoring for unauthorized input
    case armed(ArmSession)
    /// Intrusion detected, countdown active before alarm
    case triggered(ArmSession, Countdown)
    /// Alarm is actively playing
    case alarming(ArmSession)

    /// The session for every state except `.idle`.
    var session: ArmSession? {
        switch self {
        case .idle: return nil
        case .arming(let s), .armed(let s), .triggered(let s, _), .alarming(let s): return s
        }
    }

    /// Same state with its session updated; `.idle` is unchanged.
    func updatingSession(_ update: (inout ArmSession) -> Void) -> AlarmState {
        switch self {
        case .idle: return self
        case .arming(var s): update(&s); return .arming(s)
        case .armed(var s): update(&s); return .armed(s)
        case .triggered(var s, let c): update(&s); return .triggered(s, c)
        case .alarming(var s): update(&s); return .alarming(s)
        }
    }

    /// Payload-free tag, for views that only care which state this is.
    var phase: AlarmPhase {
        switch self {
        case .idle: return .idle
        case .arming: return .arming
        case .armed: return .armed
        case .triggered: return .triggered
        case .alarming: return .alarming
        }
    }
}

enum AlarmPhase: Equatable {
    case idle, arming, armed, triggered, alarming
}
