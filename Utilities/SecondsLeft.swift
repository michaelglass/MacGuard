// SecondsLeft.swift
// MacGuard - Anti-Theft Alarm for macOS

import Foundation

extension Date {
    /// Whole seconds from `now` until this date, rounded up, for countdown text.
    func secondsLeft(from now: Date) -> Int {
        Int(timeIntervalSince(now).rounded(.up))
    }
}
