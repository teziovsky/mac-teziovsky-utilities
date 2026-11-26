import Foundation

struct MediaItem: Identifiable, Hashable, Sendable {
    let id: String
    let filename: String
    let isVideo: Bool
    let creationDate: Date?
    var duration: TimeInterval?

    /// `m:ss` or `h:mm:ss` for the grid's video badge; nil when the duration is unknown.
    var durationText: String? {
        guard let duration, duration.isFinite, duration >= 0.5 else { return nil }
        let total = Int(duration.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
