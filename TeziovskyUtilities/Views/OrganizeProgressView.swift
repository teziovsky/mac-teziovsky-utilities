import AppKit
import SwiftUI

struct OrganizeProgressView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var exporter: OrganizeExporter { appState.organizeExporter }

    private var failures: [OrganizeFailure] {
        exporter.failures
    }

    private func etaText(for progress: OrganizeProgress) -> String? {
        guard !progress.isComplete, let startedAt = exporter.startedAt,
              let remaining = OrganizeETA.remaining(
                  processed: progress.current,
                  total: progress.total,
                  elapsed: Date().timeIntervalSince(startedAt)
              ) else {
            return nil
        }
        return OrganizeETA.text(forRemaining: remaining)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Organizing Album")
                .font(.title2)
                .bold()

            if let albumName = exporter.sourceAlbumName {
                VStack(alignment: .leading, spacing: 4) {
                    Text(albumName)
                        .font(AlbumListRowStyle.nameFont)
                    if let destination = exporter.destinationAlbumTitle {
                        Text("Moving to “\(destination)”")
                            .font(AlbumListRowStyle.detailFont)
                            .foregroundStyle(.secondary)
                    }
                    if let folder = exporter.exportDirectory {
                        Label(DroneFormat.abbreviatedPath(folder.path), systemImage: "folder")
                            .font(AlbumListRowStyle.detailFont.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if let progress = exporter.progress {
                ProgressView(value: progress.fraction) {
                    HStack {
                        Text("\(progress.current) / \(progress.total)")
                        Spacer()
                        if let eta = etaText(for: progress) {
                            Text(eta)
                                .foregroundStyle(.secondary)
                        }
                    }
                } currentValueLabel: {
                    Text(progress.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 16) {
                    if progress.movedCount > 0 {
                        Label("\(progress.movedCount) moved", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                    if progress.failedCount > 0 {
                        Label("\(progress.failedCount) failed", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                    if progress.skippedCount > 0 {
                        Label("\(progress.skippedCount) skipped", systemImage: "icloud.slash")
                            .foregroundStyle(.orange)
                    }
                }
                .font(AlbumListRowStyle.detailFont)

                if progress.isComplete {
                    completionMessage(progress: progress)
                }
            } else {
                ProgressView()
            }

            if !failures.isEmpty {
                failuresList
            }

            HStack {
                Spacer()
                if exporter.isRunning {
                    Button("Cancel") {
                        exporter.cancel()
                    }
                } else {
                    if let folder = exporter.exportDirectory, exporter.progress?.movedCount ?? 0 > 0 {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder
    private func completionMessage(progress: OrganizeProgress) -> some View {
        if progress.wasCancelled {
            Text("Organize cancelled. Some items may already have been exported or moved.")
                .foregroundStyle(.secondary)
        } else if progress.failedCount > 0 || progress.skippedCount > 0 {
            Text(
                "Organize finished with issues. Exported files may remain on disk even when a move failed; you can run Organize again for remaining items."
            )
            .foregroundStyle(.secondary)
        } else {
            Text("Organize finished.")
                .foregroundStyle(.secondary)
        }
    }

    private var failuresList: some View {
        let visible = Array(failures.prefix(50))
        let hiddenCount = failures.count - visible.count

        return GroupBox("Issues") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visible) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.filename)
                                .font(AlbumListRowStyle.detailFont)
                                .bold()
                            Text(failure.message)
                                .font(AlbumListRowStyle.detailFont)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if hiddenCount > 0 {
                        Text("And \(hiddenCount) more…")
                            .font(AlbumListRowStyle.detailFont)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .accessibilityLabel("Organize issues, \(failures.count) total")
        }
    }
}
