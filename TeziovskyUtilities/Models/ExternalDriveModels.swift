import Foundation

enum ExternalDriveBucket: Sendable, Equatable {
    case ready
    case needsOrganizing
    case alreadyOnDestination
    case notMedia
    case problem
}

struct ExternalDriveEntry: Identifiable, Sendable, Equatable {
    var id: String { relativePath }
    let relativePath: String
    let bucket: ExternalDriveBucket
    let reason: String?
    let note: String?
    let byteCount: Int64
}

/// Files that move together: a single file, or a Live Photo still followed by its motion file.
struct ExternalDriveUnit: Identifiable, Sendable, Equatable {
    var id: String { relativePaths[0] }
    let relativePaths: [String]
    let byteCount: Int64
}

struct ExternalDriveReview: Sendable, Equatable {
    let entries: [ExternalDriveEntry]
    let readyUnits: [ExternalDriveUnit]
    let existingUnits: [ExternalDriveUnit]

    func entries(in bucket: ExternalDriveBucket) -> [ExternalDriveEntry] {
        entries.filter { $0.bucket == bucket }
    }

    var readyByteCount: Int64 {
        readyUnits.reduce(0) { $0 + $1.byteCount }
    }
}

enum ExternalDriveStep: Equatable {
    case review
    case moving
    case summary
}

struct ExternalDriveProgress: Equatable {
    var unitIndex = 0
    var unitCount = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    /// The current unit's first path (a Live Photo pair counts as one "file" here).
    var currentPath = ""
    var currentFileBytesDone: Int64 = 0
    var currentFileBytesTotal: Int64 = 0
    var startedAt: Date?
    var estimatedRemaining: TimeInterval?
}

struct ExternalDriveRunResult: Identifiable, Equatable {
    var id: String { relativePath }
    let relativePath: String
    let outcome: ExternalDriveUnitOutcome
}

struct ExternalDriveRunSummary: Equatable {
    enum Kind: Equatable {
        case move
        case trashExisting
    }

    let kind: Kind
    /// Every unit the run was started with.
    let totalUnits: Int
    let attemptedUnits: Int
    let succeededUnits: Int
    let results: [ExternalDriveRunResult]
    /// Ids (first relative path) of the units never attempted because the run was cancelled or stopped.
    let notAttempted: [String]
    let wasCancelled: Bool
    let stoppedReason: String?

    /// Attempted units that didn't succeed, plus the ones never attempted.
    var needAttentionCount: Int { attemptedUnits - succeededUnits + notAttempted.count }
}
