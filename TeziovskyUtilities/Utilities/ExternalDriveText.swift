import Foundation

/// A file that needs attention after a run, with why.
struct ExternalDriveAttentionItem: Identifiable, Equatable {
    var id: String { relativePath }
    let relativePath: String
    let message: String
}

/// The words the Move to External Drive screens show. Pure, so the copy is tested; sizes and
/// durations come in already formatted.
enum ExternalDriveText {
    /// What the review's primary button does.
    enum MoveAction: Equatable {
        case checkAgain
        case notice(String)
        case confirm(fileCount: Int)
    }

    /// Why a unit needs attention after a run; nil for the run's successes.
    static func outcome(_ outcome: ExternalDriveUnitOutcome, destinationName: String) -> String? {
        switch outcome {
        case .moved, .trashedOriginal: return nil
        case .alreadyOnDestination: return "Already on \(destinationName) — left in place"
        case .cancelled: return "Cancelled — nothing changed"
        case let .failed(message), let .verifiedButNotTrashed(message): return message
        case let .differentFileOnDestination(message):
            return "A different file with this name is on \(destinationName): \(message)"
        case .destinationUnavailable: return "\(destinationName) wasn't reachable"
        }
    }

    /// Every unit that didn't succeed, in run order, then the ones never attempted.
    static func attentionItems(_ summary: ExternalDriveRunSummary, destinationName: String)
        -> [ExternalDriveAttentionItem] {
        let failures = summary.results.compactMap { result in
            outcome(result.outcome, destinationName: destinationName)
                .map { ExternalDriveAttentionItem(relativePath: result.relativePath, message: $0) }
        }
        let skipped = summary.notAttempted.map {
            ExternalDriveAttentionItem(relativePath: $0, message: "Not attempted")
        }
        return failures + skipped
    }

    /// "240 ready · 5 need organizing · 3 already on MEDIA · 1 not media", zero parts left out.
    /// Problem files are listed in their own section, not here.
    static func reviewSummary(_ review: ExternalDriveReview, destinationName: String) -> String {
        let parts: [(Int, String)] = [
            (review.entries(in: .ready).count, "ready"),
            (review.entries(in: .needsOrganizing).count, "need organizing"),
            (review.entries(in: .alreadyOnDestination).count, "already on \(destinationName)"),
            (review.entries(in: .notMedia).count, "not media")
        ]
        let shown = parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        if shown.isEmpty {
            return review.entries.isEmpty ? "No files in the source folder" : "Nothing to move"
        }
        return shown.joined(separator: " · ")
    }

    static func sizeLine(toMove: String, free: String, destinationName: String) -> String {
        "\(toMove) to move · \(free) free on \(destinationName)"
    }

    static func headline(_ summary: ExternalDriveRunSummary, destinationName: String) -> String {
        let (done, total) = (summary.succeededUnits, summary.totalUnits)
        switch summary.kind {
        case .move: return "Moved \(done) of \(total) to \(destinationName)"
        case .trashExisting: return "Moved \(done) of \(total) originals to the Trash"
        }
    }

    /// The one notification a run posts when it ends.
    static func notificationBody(_ summary: ExternalDriveRunSummary, destinationName: String) -> String {
        let (done, total) = (summary.succeededUnits, summary.totalUnits)
        var body = switch summary.kind {
        case .move: "Moved \(done) of \(total) to \(destinationName)"
        case .trashExisting: "Moved \(done) of \(total) originals already on \(destinationName) to the Trash"
        }
        if summary.needAttentionCount > 0 { body += " — \(summary.needAttentionCount) need attention" }
        if summary.wasCancelled {
            body += " (cancelled)"
        } else if summary.stoppedReason != nil {
            body += " (stopped)"
        }
        return body
    }

    /// "File 37 of 240 · 1 GB of 9 GB · about 4 min left"; the estimate only once there is one.
    static func movingLine(_ progress: ExternalDriveProgress, done: String, total: String, remaining: String?)
        -> String {
        let file = min(progress.unitIndex + 1, progress.unitCount)
        let line = "File \(file) of \(progress.unitCount) · \(done) of \(total)"
        guard let remaining else { return line }
        return "\(line) · about \(remaining) left"
    }

    /// The outcome as written in the log, after the file's path.
    static func logLine(for outcome: ExternalDriveUnitOutcome, destinationName: String) -> String {
        switch outcome {
        case .moved: return "moved"
        case .alreadyOnDestination: return "already on \(destinationName), not copied"
        case .cancelled: return "cancelled"
        case let .failed(message): return "failed: \(message)"
        case let .verifiedButNotTrashed(message): return "copied and verified, original not trashed: \(message)"
        case .trashedOriginal: return "original moved to the Trash"
        case let .differentFileOnDestination(message): return "different file on \(destinationName): \(message)"
        case .destinationUnavailable: return "\(destinationName) unavailable"
        }
    }

    /// Nothing ready → check again; too big for the drive → a banner; otherwise confirm the move.
    static func moveAction(
        _ review: ExternalDriveReview, preflight: ExternalDrivePreflight, destinationName: String,
        formatBytes: (Int64) -> String
    ) -> MoveAction {
        let fileCount = review.entries(in: .ready).count
        guard fileCount > 0, !review.readyUnits.isEmpty else { return .checkAgain }
        if case let .ready(freeBytes) = preflight, review.readyByteCount > freeBytes {
            return .notice(
                "Not enough space on \(destinationName): \(formatBytes(review.readyByteCount)) to move, "
                    + "\(formatBytes(freeBytes)) free."
            )
        }
        return .confirm(fileCount: fileCount)
    }

    /// The move confirmation's text, with one example of where a file lands, e.g.
    /// "2024/IMG_0001.jpg → MEDIA/2024/IMG_0001.jpg".
    static func moveConfirmationMessage(_ review: ExternalDriveReview?, destinationName: String) -> String {
        let message = "Originals go to the Trash after each file is verified."
        guard let path = review?.readyUnits.first?.relativePaths.first else { return message }
        return "\(message)\n\(path) → \(destinationName)/\(path)"
    }

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "4 min, 20 sec"-style, at most two units.
    static func duration(_ interval: TimeInterval) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: max(1, interval.rounded()))
    }
}
