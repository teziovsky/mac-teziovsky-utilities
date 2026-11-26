import SwiftUI

/// Originals that an earlier "keep originals" conversion left next to their converted copy.
/// Replacing trashes each ticked original and gives its copy the original's name.
struct LocalMediaReplacementSection: View {
    @ObservedObject var service: LocalPhotosService
    let filter: String
    @State private var confirmsReplacement = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Converted copies ready to replace originals (\(service.replaceablePairs.count))")
                    .font(.headline)
                Text("Check the converted copies first. Replacing moves each original to the Trash "
                    + "and gives its copy the original's name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            actionRow
            if let summary = service.replacementSummary, !service.isReplacing {
                LocalMediaReplacementSummaryView(summary: summary)
            }
            if !service.replaceablePairs.isEmpty {
                LocalMediaTreeList(
                    service: service,
                    items: service.replaceablePairs,
                    path: \.originalRelativePath,
                    filter: filter,
                    step: .replacement
                ) { pair in
                    LocalMediaSelectableRow(
                        service: service,
                        path: pair.originalRelativePath,
                        fileURL: pair.originalURL,
                        step: .replacement
                    ) {
                        LocalMediaReplacementRow(pair: pair)
                    }
                }
            }
        }
        .confirmationDialog(
            "Replace \(service.includedReplaceablePairs.count) originals?",
            isPresented: $confirmsReplacement,
            titleVisibility: .visible
        ) {
            Button("Replace \(service.includedReplaceablePairs.count) Originals", role: .destructive) {
                service.replaceOriginals()
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(
                "The originals go to the Trash. Each copy is checked again first, and copies take the original's name."
            )
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if service.isReplacing {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: service.replacementProgress.fraction)
                    Text(
                        "\(service.replacementProgress.processed) of \(service.replacementProgress.total) · "
                            + service.replacementProgress.currentPath
                    )
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Button(service.cancellationMessage == nil ? "Cancel" : "Cancelling…", role: .cancel) {
                    service.cancel()
                }
                .pillActionButton()
                .disabled(service.cancellationMessage != nil)
            }
        } else if !service.replaceablePairs.isEmpty {
            HStack {
                Spacer()
                Button("Replace \(service.includedReplaceablePairs.count) Originals…") {
                    confirmsReplacement = true
                }
                .pillActionButton()
                .disabled(service.isRunning || service.includedReplaceablePairs.isEmpty)
                .help("Move the ticked originals to the Trash and give their copies the original names")
            }
        }
    }
}

private struct LocalMediaReplacementSummaryView: View {
    let summary: LocalMediaReplacementSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(summaryText, systemImage: isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isClean ? Color.green : Color.orange)
            ForEach(summary.issues) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.relativePath)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isClean: Bool {
        summary.failed == 0 && summary.keptCopyName == 0 && summary.cancelled == 0
    }

    private var summaryText: String {
        var parts = ["\(summary.replaced) replaced"]
        if summary.keptCopyName > 0 { parts.append("\(summary.keptCopyName) kept the copy's name") }
        parts.append("\(summary.failed) failed")
        if summary.cancelled > 0 { parts.append("\(summary.cancelled) cancelled") }
        return parts.joined(separator: " · ")
    }
}

private struct LocalMediaReplacementRow: View {
    let pair: LocalMediaReplaceablePair

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: pair.isVideo ? "film" : "photo")
                .foregroundStyle(.blue)
                .frame(width: 20)
                .localMediaRowAnchor()
            VStack(alignment: .leading, spacing: 5) {
                Text("\(pair.originalRelativePath) → \(pair.copyURL.lastPathComponent)")
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if pair.finalName != pair.copyURL.lastPathComponent {
                    Text("Will be named \(pair.finalName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        }
    }
}
