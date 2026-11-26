import AppKit
import SwiftUI

// MARK: - Moving

struct ExternalDriveMovingCard: View {
    @ObservedObject var service: ExternalDriveTransferService

    private var progress: ExternalDriveProgress { service.progress }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label(service.activityTitle ?? "Moving files", systemImage: "externaldrive.badge.timemachine")
                    .font(.title3.weight(.semibold))
                Text("Each file is copied, checked against the original, and only then is the original moved "
                    + "to the Trash. The Mac stays awake until the run ends.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Cancel") { service.cancel() }
                        .pillActionButton()
                        .help("Stop after the current file; a file that isn't verified yet is left unchanged")
                }

                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.bytesDone), total: Double(max(progress.bytesTotal, 1)))
                    Text(ExternalDriveText.movingLine(
                        progress,
                        done: ExternalDriveText.byteCount(progress.bytesDone),
                        total: ExternalDriveText.byteCount(progress.bytesTotal),
                        remaining: progress.estimatedRemaining.flatMap(ExternalDriveText.duration)
                    ))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                if !progress.currentPath.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(progress.currentPath)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ProgressView(
                            value: Double(progress.currentFileBytesDone),
                            total: Double(max(progress.currentFileBytesTotal, 1))
                        )
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - Summary

struct ExternalDriveSummaryCard: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var service: ExternalDriveTransferService

    private var name: String { service.destinationName }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                if let summary = service.summary {
                    headline(summary)
                }
                actionRow
                if let summary = service.summary {
                    attentionList(ExternalDriveText.attentionItems(summary, destinationName: name))
                    if let review = service.review {
                        heldBack(review, kind: summary.kind)
                    }
                }
            }
        }
    }

    private func headline(_ summary: ExternalDriveRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                ExternalDriveText.headline(summary, destinationName: name),
                systemImage: summary.needAttentionCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .font(.title3.weight(.semibold))
            .foregroundStyle(summary.needAttentionCount == 0 ? Color.green : Color.orange)
            if let stoppedReason = summary.stoppedReason {
                Text(stoppedReason)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if summary.wasCancelled {
                Text("Cancelled")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Back") { appState.run(.back) }
                .pillActionButton()
                .help("Back to the review with a fresh check (⌘[ or Esc)")
            Spacer(minLength: 12)
            Button("Show Log") { appState.showExternalDriveLog() }
                .pillActionButton()
                .help("Reveal the log of every file in Finder")
            Button("Done") { appState.run(.home) }
                .pillActionButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .help("Back to the home screen (↩ or ⇧⌘H)")
        }
    }

    @ViewBuilder
    private func attentionList(_ items: [ExternalDriveAttentionItem]) -> some View {
        if !items.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("\(items.count) need attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                LocalMediaFilteredList(items: items, path: \.relativePath, filter: "") { item in
                    ExternalDriveFileRow(
                        relativePath: item.relativePath,
                        detail: item.message,
                        detailIsWarning: true,
                        note: nil,
                        byteCount: nil,
                        reveal: {
                            ExternalDriveReveal.file(item.relativePath, source: service.sourceURL,
                                                     destination: service.destination)
                        }
                    )
                }
            }
        }
    }

    /// The review's buckets that this run didn't touch, so nothing left behind goes unmentioned.
    @ViewBuilder
    private func heldBack(_ review: ExternalDriveReview, kind: ExternalDriveRunSummary.Kind) -> some View {
        let buckets: [ExternalDriveBucket] = kind == .move
            ? [.needsOrganizing, .alreadyOnDestination, .notMedia, .problem]
            : [.needsOrganizing, .notMedia, .problem]
        if buckets.contains(where: { !review.entries(in: $0).isEmpty }) {
            Divider()
            Text("Not part of this run")
                .font(.headline)
            ExternalDriveBucketSections(
                review: review, buckets: buckets, sourceURL: service.sourceURL, destinationName: name
            )
        }
    }
}

// MARK: - Buckets

/// One collapsible list per non-empty bucket, each row with its reason and a Reveal button.
struct ExternalDriveBucketSections: View {
    let review: ExternalDriveReview
    let buckets: [ExternalDriveBucket]
    let sourceURL: URL?
    let destinationName: String
    @State private var expanded: Set<String> = ["needsOrganizing", "problem"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(buckets, id: \.key) { bucket in
                let entries = review.entries(in: bucket)
                if !entries.isEmpty {
                    DisclosureGroup(isExpanded: binding(for: bucket)) {
                        LocalMediaFilteredList(items: entries, path: \.relativePath, filter: "") { entry in
                            ExternalDriveFileRow(
                                relativePath: entry.relativePath,
                                detail: entry.reason,
                                detailIsWarning: bucket == .problem,
                                note: entry.note,
                                byteCount: entry.byteCount,
                                reveal: { ExternalDriveReveal.file(entry.relativePath, source: sourceURL) }
                            )
                        }
                        .padding(.top, 6)
                    } label: {
                        Label("\(title(bucket)) (\(entries.count))", systemImage: symbol(bucket))
                            .font(.headline)
                    }
                }
            }
        }
    }

    private func binding(for bucket: ExternalDriveBucket) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(bucket.key) },
            set: { isExpanded in
                if isExpanded { expanded.insert(bucket.key) } else { expanded.remove(bucket.key) }
            }
        )
    }

    private func title(_ bucket: ExternalDriveBucket) -> String {
        switch bucket {
        case .ready: return "Ready to move"
        case .needsOrganizing: return "Need organizing"
        case .alreadyOnDestination: return "Already on \(destinationName)"
        case .notMedia: return "Not media — left in place"
        case .problem: return "Problems"
        }
    }

    private func symbol(_ bucket: ExternalDriveBucket) -> String {
        switch bucket {
        case .ready: return "checkmark.circle"
        case .needsOrganizing: return "wand.and.stars"
        case .alreadyOnDestination: return "externaldrive.badge.checkmark"
        case .notMedia: return "doc"
        case .problem: return "exclamationmark.triangle"
        }
    }
}

private extension ExternalDriveBucket {
    var key: String {
        switch self {
        case .ready: return "ready"
        case .needsOrganizing: return "needsOrganizing"
        case .alreadyOnDestination: return "alreadyOnDestination"
        case .notMedia: return "notMedia"
        case .problem: return "problem"
        }
    }
}

struct ExternalDriveFileRow: View {
    let relativePath: String
    let detail: String?
    let detailIsWarning: Bool
    let note: String?
    let byteCount: Int64?
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(relativePath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailIsWarning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let byteCount {
                Text(ExternalDriveText.byteCount(byteCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(action: reveal) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(relativePath) in Finder")
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        }
    }
}

enum ExternalDriveReveal {
    /// Reveals the file in the source folder; if it's gone (moved or trashed), its copy on the drive;
    /// otherwise the nearest folder that still exists.
    @MainActor
    static func file(_ relativePath: String, source: URL?, destination: ExternalDriveFolderResolution = .notChosen) {
        var candidates: [URL] = []
        if let source { candidates.append(source.appendingPathComponent(relativePath)) }
        if case let .resolved(root) = destination { candidates.append(root.appendingPathComponent(relativePath)) }
        let manager = FileManager.default
        if let existing = candidates.first(where: { manager.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.activateFileViewerSelecting([existing])
            return
        }
        guard var folder = candidates.first?.deletingLastPathComponent() else { return }
        while !manager.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
