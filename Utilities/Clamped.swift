// Clamped.swift
// MacGuard - Anti-Theft Alarm for macOS

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
