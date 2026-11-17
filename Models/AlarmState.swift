// AlarmState.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import Foundation

struct ArmSession: Equatable, Codable {
    /// Trusted devices seen away during this session (at arming or since).
    /// Only these may disarm: a phone left on the desk never vouches for the owner.
    var departed: Set<TrustedDevice.ID>
}

extension ArmSession {
    /// No trusted device may disarm.
    static let noDepartures = ArmSession(departed: [])
}

/// Why arming started; reported once armed.
enum ArmOrigin: Equatable {
    case manual, deviceLeft
}

/// `remaining` is always in `1...total`; an expired countdown is `.alarming`.
struct Countdown: Equatable {
    let total: Int
    private(set) var remaining: Int

    /// `nil` when the alarm should sound immediately.
    init?(seconds: Int) {
        guard seconds > 0 else { return nil }
        total = seconds
        remaining = seconds
    }

    func ticked() -> Countdown? {
        guard remaining > 1 else { return nil }
        var next = self
        next.remaining -= 1
        return next
    }

    var progress: Double { Double(remaining) / Double(total) }
}

/// Data that only exists in some states lives inside those cases.
enum AlarmState: Equatable {
    /// App running, theft mode OFF
    case idle
    /// Monitors start after the exit delay, so the arming keystroke is not an intrusion.
    /// `until` is when that delay ends.
    case arming(ArmSession, until: Date, origin: ArmOrigin)
    /// Theft mode ON, monitoring for unauthorized input
    case armed(ArmSession)
    /// Intrusion detected, countdown active before alarm
    case triggered(ArmSession, Countdown, TriggerCause)
    /// Alarm is actively playing
    case alarming(ArmSession, TriggerCause)

    var session: ArmSession? {
        switch self {
        case .idle: return nil
        case .arming(let s, _, _), .armed(let s), .triggered(let s, _, _), .alarming(let s, _): return s
        }
    }

    func updatingSession(_ update: (inout ArmSession) -> Void) -> AlarmState {
        switch self {
        case .idle: return self
        case .arming(var s, let until, let origin): update(&s); return .arming(s, until: until, origin: origin)
        case .armed(var s): update(&s); return .armed(s)
        case .triggered(var s, let c, let cause): update(&s); return .triggered(s, c, cause)
        case .alarming(var s, let cause): update(&s); return .alarming(s, cause)
        }
    }

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
