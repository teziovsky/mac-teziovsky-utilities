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
