import AVFoundation
import Foundation

private final class ExportSessionCancellation: @unchecked Sendable {
    let session: AVAssetExportSession

    init(session: AVAssetExportSession) {
        self.session = session
    }

    func cancel() {
        session.cancelExport()
    }
}

enum VideoMetadataTransferError: LocalizedError {
    case exportSessionUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .exportSessionUnavailable:
            return "Could not create an export session to copy video metadata."
        case .exportFailed(let message):
            return message
        }
    }
}

/// Best-effort native copy of container-level metadata (creation date, location, and other
/// common metadata) from a source video onto a compressed video using an AVFoundation
/// passthrough export (no re-encode, so quality is preserved).
enum VideoMetadataTransfer {
    static func transfer(from sourceURL: URL, to compressedURL: URL) async throws {
        let sourceAsset = AVURLAsset(url: sourceURL)
        let metadata = try await sourceAsset.load(.commonMetadata)
        guard !metadata.isEmpty else { return }
        try await rewrite(compressedURL, metadata: metadata)
    }

    static func synchronizeCreationDates(in url: URL, to date: Date) async throws {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.commonMetadata)
        var didFindCreationDate = false
        var synchronized: [AVMetadataItem] = []
        for item in metadata {
            guard item.commonKey == .commonKeyCreationDate,
                  let mutableItem = item.mutableCopy() as? AVMutableMetadataItem else {
                synchronized.append(item)
                continue
            }
            didFindCreationDate = true
            // QuickTime/MP4 store creation dates as ISO 8601 text; an NSDate value is silently
            // dropped by the export, which would erase the date instead of updating it.
            let original = try? await item.load(.stringValue)
            mutableItem.value = creationDateString(for: date, matching: original) as NSString
            synchronized.append(mutableItem)
        }
        guard didFindCreationDate else { return }
        try await rewrite(url, metadata: synchronized)
    }

    /// ISO 8601 text for `date`, expressed in the UTC offset of `original` when it has one
    /// (e.g. iPhone `2019-06-08T15:20:00+0200`), otherwise in the current time zone.
    static func creationDateString(for date: Date, matching original: String?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = original.flatMap(utcOffset(in:)) ?? .current
        return formatter.string(from: date)
    }

    private static func utcOffset(in value: String) -> TimeZone? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0) }
        guard let signIndex = trimmed.lastIndex(where: { $0 == "+" || $0 == "-" }),
              trimmed.distance(from: signIndex, to: trimmed.endIndex) <= 6,
              trimmed[..<signIndex].contains("T") else {
            return nil
        }
        return ExifDateCodec.timeZone(forOffset: String(trimmed[signIndex...]))
    }

    private static func rewrite(_ url: URL, metadata: [AVMetadataItem]) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw VideoMetadataTransferError.exportSessionUnavailable
        }

        let outputType = outputFileType(for: url, session: session)
        let tempURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(".video-metadata-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)

        session.outputURL = tempURL
        session.outputFileType = outputType
        session.metadata = metadata
        session.shouldOptimizeForNetworkUse = true

        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await runExport(session)
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            throw VideoMetadataTransferError.exportFailed("Export produced no output file.")
        }

        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    private static func outputFileType(for url: URL, session: AVAssetExportSession) -> AVFileType {
        let supported = session.supportedFileTypes
        let preferred: AVFileType
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v":
            preferred = .mp4
        case "mov", "qt":
            preferred = .mov
        case "m4a":
            preferred = .m4a
        default:
            preferred = .mov
        }
        if supported.contains(preferred) { return preferred }
        return supported.first ?? preferred
    }

    private static func runExport(_ session: AVAssetExportSession) async throws {
        try Task.checkCancellation()
        let cancellation = ExportSessionCancellation(session: session)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously {
                    continuation.resume()
                }
            }
        } onCancel: {
            cancellation.cancel()
        }

        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        default:
            let message = session.error?.localizedDescription ?? "Unknown export error."
            throw VideoMetadataTransferError.exportFailed(message)
        }
    }
}
