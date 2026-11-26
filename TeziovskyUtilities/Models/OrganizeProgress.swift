import Foundation

struct OrganizeProgress: Sendable {
    let current: Int
    let total: Int
    let filename: String
    let failedCount: Int
    let skippedCount: Int
    let movedCount: Int
    let isComplete: Bool
    let wasCancelled: Bool

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }
}

struct OrganizeFailure: Identifiable, Sendable {
    let id = UUID()
    let filename: String
    let message: String
}

/// Remaining-time estimate for long exports, based on the average time per item so far.
enum OrganizeETA {
    static func remaining(processed: Int, total: Int, elapsed: TimeInterval) -> TimeInterval? {
        // Too early to average, or nothing left.
        guard processed >= 3, elapsed >= 5, processed < total else { return nil }
        return elapsed / Double(processed) * Double(total - processed)
    }

    static func text(forRemaining seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "about \(minutes) min left" }
        return "about \(minutes / 60) h \(minutes % 60) min left"
    }
}
