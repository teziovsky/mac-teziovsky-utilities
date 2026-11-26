import AppKit
import SwiftUI

/// Move to External Drive: review (check the source folder), moving, summary. The step lives in the
/// service; each step's card puts its buttons above its lists.
struct ExternalDriveModeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var service: ExternalDriveTransferService

    private static let topID = "external-drive-top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                        .id(Self.topID)
                    switch service.step {
                    case .review:
                        ExternalDriveReviewCard(service: service)
                    case .moving:
                        ExternalDriveMovingCard(service: service)
                    case .summary:
                        ExternalDriveSummaryCard(service: service)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1_000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: service.step) { _, _ in
                // Each step's buttons sit at the top of its card; bring them into view.
                withAnimation(.smooth(duration: 0.25)) {
                    proxy.scrollTo(Self.topID, anchor: .top)
                }
            }
        }
        .navigationTitle(AppBranding.externalDriveModeTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    appState.run(.home)
                } label: {
                    Label("Home", systemImage: "house")
                }
                .help("Back to the home screen (⇧⌘H)")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppBranding.externalDriveModeTitle)
                .font(.largeTitle.bold())
            Text(AppBranding.externalDriveModeSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                folderLine("From", path: service.sourceURL?.path)
                folderLine("To", path: destinationPath)
            }
            .padding(.top, 2)
        }
    }

    private var destinationPath: String? {
        switch service.destination {
        case let .resolved(url): return url.path
        case let .unavailable(path): return path
        case .notChosen: return nil
        }
    }

    private func folderLine(_ title: String, path: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(path.map(DroneFormat.abbreviatedPath) ?? "Not chosen")
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
    }
}

// MARK: - Review

private struct ExternalDriveReviewCard: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var service: ExternalDriveTransferService
    @State private var confirmsMove = false
    @State private var confirmsTrash = false

    private enum Phase {
        case notChosen
        case notConnected(String)
        case checking
        case failed(String)
        case reviewed(ExternalDriveReview)
        case incomplete
    }

    private var phase: Phase {
        if service.sourceURL == nil || service.preflightState == .notChosen { return .notChosen }
        if case let .notConnected(message) = service.preflightState { return .notConnected(message) }
        if service.isChecking { return .checking }
        if let failure = service.checkFailure { return .failed(failure) }
        if let review = service.review { return .reviewed(review) }
        return .incomplete
    }

    private var name: String { service.destinationName }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Review", systemImage: "checklist")
                    .font(.title3.weight(.semibold))
                status
                actionRow
                if case let .reviewed(review) = phase {
                    Divider()
                    ExternalDriveBucketSections(
                        review: review,
                        buckets: [.ready, .needsOrganizing, .alreadyOnDestination, .notMedia, .problem],
                        sourceURL: service.sourceURL,
                        destinationName: name
                    )
                }
            }
        }
        .confirmationDialog(
            "Move \(readyFileCount) files to \(name)?",
            isPresented: $confirmsMove,
            titleVisibility: .visible
        ) {
            Button("Move") { startMove() }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(ExternalDriveText.moveConfirmationMessage(service.review, destinationName: name))
        }
        .confirmationDialog(
            "Move \(existingFileCount) originals to the Trash?",
            isPresented: $confirmsTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash") {
                service.trashExistingOriginals()
                explainIfNotStarted(checksSpace: false)
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Each original goes to the Trash only if it is identical to the copy already on \(name). "
                + "Different files stay where they are.")
        }
    }

    private var readyFileCount: Int { service.review?.entries(in: .ready).count ?? 0 }
    private var existingFileCount: Int { service.review?.entries(in: .alreadyOnDestination).count ?? 0 }
    private var needsOrganizingCount: Int { service.review?.entries(in: .needsOrganizing).count ?? 0 }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .notChosen:
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose the folder to move from and the folder on the drive to move to.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Files keep their relative path, e.g. 2024/IMG_0001.jpg goes to the same place on the drive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case let .notConnected(message):
            Label(message, systemImage: "externaldrive.badge.xmark")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .checking:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: service.checkProgress.fraction)
                Text("Checked \(service.checkProgress.processed) of \(service.checkProgress.total) files")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                Label("The source folder couldn't be checked", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case let .reviewed(review):
            reviewStatus(review)
        case .incomplete:
            Text("The check didn't finish. Press Check Again to look at the source folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func reviewStatus(_ review: ExternalDriveReview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ExternalDriveText.reviewSummary(review, destinationName: name))
                .font(.callout.weight(.medium))
            if case let .ready(freeBytes) = service.preflightState {
                Text(ExternalDriveText.sizeLine(
                    toMove: ExternalDriveText.byteCount(review.readyByteCount),
                    free: ExternalDriveText.byteCount(freeBytes),
                    destinationName: name
                ))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            let problems = review.entries(in: .problem).count
            if problems > 0 {
                Label("\(problems) can't be moved — see Problems below", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Actions

    /// Back on the left, secondary actions, the prominent primary on the right. Falls back to two rows
    /// when the window is too narrow for every button.
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                backButton
                Spacer(minLength: 12)
                secondaryButtons
                bucketButtons
                primaryButton
            }
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    backButton
                    Spacer(minLength: 12)
                    secondaryButtons
                    primaryButton
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    bucketButtons
                }
            }
        }
    }

    private var backButton: some View {
        Button("Back") { appState.run(.back) }
            .pillActionButton()
            .help("Back to the home screen (⌘[ or Esc)")
    }

    @ViewBuilder
    private var secondaryButtons: some View {
        switch phase {
        case .notChosen:
            if service.sourceURL == nil, service.preflightState == .notChosen {
                chooseButton(.destination, prominent: false)
            }
        case .checking:
            Button("Cancel") { service.cancel() }
                .pillActionButton()
                .help("Stop checking; nothing has changed")
        case .notConnected, .failed, .incomplete:
            revealButton
        case let .reviewed(review):
            revealButton
            if !review.readyUnits.isEmpty {
                checkAgainButton(prominent: false)
            }
        }
    }

    @ViewBuilder
    private var bucketButtons: some View {
        if case .reviewed = phase {
            if existingFileCount > 0 {
                Button("Trash \(existingFileCount) Originals Already on \(name)…") { confirmsTrash = true }
                    .pillActionButton()
                    .help("Move the originals whose identical copies are already on \(name) to the Trash")
            }
            if needsOrganizingCount > 0 {
                Button("Open in Organize Local Media") { appState.openSourceInLocalMedia() }
                    .pillActionButton()
                    .help("Fix dates, conversions and folders for the files that need organizing")
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch phase {
        case .notChosen:
            chooseButton(service.sourceURL == nil ? .source : .destination, prominent: true)
        case .checking:
            EmptyView()
        case .notConnected, .failed, .incomplete:
            checkAgainButton(prominent: true)
        case let .reviewed(review):
            if review.readyUnits.isEmpty {
                checkAgainButton(prominent: true)
            } else {
                Button("Move \(readyFileCount) Files to \(name)…") { pressMove(review) }
                    .pillActionButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .help("Move the ready files (↩)")
            }
        }
    }

    private func chooseButton(_ role: ExternalDriveFolderRole, prominent: Bool) -> some View {
        let title = role == .source ? "Choose Source Folder…" : "Choose Drive Folder…"
        let button = Button(title) { appState.chooseExternalDriveFolder(role) }
            .pillActionButton(prominent: prominent)
            .help((role == .source ? "Choose the folder to move from" : "Choose the folder on the drive")
                + (prominent ? " (↩)" : ""))
        return Group {
            if prominent {
                button.keyboardShortcut(.defaultAction)
            } else {
                button
            }
        }
    }

    private var revealButton: some View {
        Button("Reveal") { appState.run(.reveal) }
            .pillActionButton()
            .help("Reveal the source folder in Finder (⇧⌘R)")
    }

    @ViewBuilder
    private func checkAgainButton(prominent: Bool) -> some View {
        let button = Button("Check Again") { appState.run(.refresh) }
            .pillActionButton(prominent: prominent)
        if prominent {
            button
                .keyboardShortcut(.defaultAction)
                .help("Check the source folder and the drive again (↩ or ⌘R)")
        } else {
            button
                .help("Check the source folder and the drive again (⌘R)")
        }
    }

    private func pressMove(_ review: ExternalDriveReview) {
        switch moveAction(review) {
        case .checkAgain: appState.run(.refresh)
        case let .notice(message): appState.showNotice(message)
        case .confirm: confirmsMove = true
        }
    }

    private func moveAction(_ review: ExternalDriveReview) -> ExternalDriveText.MoveAction {
        ExternalDriveText.moveAction(
            review, preflight: service.preflightState, destinationName: name,
            formatBytes: ExternalDriveText.byteCount
        )
    }

    private func startMove() {
        service.moveReady()
        explainIfNotStarted(checksSpace: true)
    }

    /// The service re-checks the drive before a run starts; when it refuses, say why instead of doing nothing.
    private func explainIfNotStarted(checksSpace: Bool) {
        guard !service.isTransferring else { return }
        if checksSpace, let review = service.review, case let .notice(message) = moveAction(review) {
            appState.showNotice(message)
        } else if case let .notConnected(message) = service.preflightState {
            appState.showNotice(message)
        } else {
            appState.showNotice("The run couldn't start. Press Check Again (⌘R) and try again.")
        }
    }
}
