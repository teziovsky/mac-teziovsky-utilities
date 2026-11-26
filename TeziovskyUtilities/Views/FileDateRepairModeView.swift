import AppKit
import SwiftUI

struct LocalPhotosModeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var filter = ""

    @ObservedObject var service: LocalPhotosService

    private static let topID = "local-photos-top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
            }
            .onChange(of: service.workflowStep) { _, _ in
                // Each step's buttons sit at the top of its card; bring them into view.
                withAnimation(.smooth(duration: 0.25)) {
                    proxy.scrollTo(Self.topID, anchor: .top)
                }
            }
        }
        .navigationTitle(AppBranding.localPhotosModeTitle)
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter files")
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
        .onDisappear {
            if !service.isRunning {
                service.reset()
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
                .id(Self.topID)
            folderCard
            if service.isRunning {
                progressCard
            }
            if service.directory != nil, !service.isScanning {
                if service.lastScanCompleted {
                    workflowSteps
                    switch service.workflowStep {
                    case .convert:
                        conversionCard
                    case .repair:
                        resultsCard
                    case .organize:
                        organizationCard
                    case .complete:
                        completionCard
                    }
                } else {
                    LocalMediaIncompleteScanCard(
                        message: service.cancellationMessage
                            ?? "The folder could not be scanned completely. Check the issues below and rescan.",
                        rescan: rescan
                    )
                }
            }
            if !service.failures.isEmpty {
                failuresCard
            }
        }
        .padding(24)
        .frame(maxWidth: 1_000, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppBranding.localPhotosModeTitle)
                .font(.largeTitle.bold())
            Text(AppBranding.localPhotosModeSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(
                "Review every proposed change first. Convert legacy media, repair dates, then organize "
                    + "each parent folder into YYYY directories with videos under YYYY/_Filmy."
            )
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var folderCard: some View {
        GlassCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Media folder")
                        .font(.headline)
                    if let directory = service.directory {
                        Text(directory.path)
                            .font(.callout.monospaced())
                            .foregroundStyle(Color.green.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Choose a folder to scan recursively. Nothing changes during the scan.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Button(service.directory == nil ? "Choose & Scan" : "Change & Rescan") {
                    appState.run(.openFolder)
                }
                .pillActionButton(prominent: service.directory == nil)
                .help("Choose a media folder and scan it (⌘O)")
            }
        }
    }

    private var progressCard: some View {
        let activeProgress: FileDateRepairProgress
        if service.isConverting {
            activeProgress = service.conversionProgress
        } else if service.isOrganizing {
            activeProgress = service.organizationProgress
        } else {
            activeProgress = service.progress
        }
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(progressTitle)
                        .font(.headline)
                    Spacer()
                    Text("\(activeProgress.processed) of \(activeProgress.total)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: activeProgress.fraction)
                Text(activeProgress.currentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(service.cancellationMessage == nil ? "Cancel" : "Cancelling…", role: .cancel) {
                    service.cancel()
                }
                .buttonStyle(.bordered)
                .disabled(service.cancellationMessage != nil)
            }
        }
    }

    private var progressTitle: String {
        if service.isScanning { return "Scanning media" }
        if service.isConverting { return "Converting media" }
        if service.isRepairing { return "Repairing dates" }
        return "Organizing files"
    }

    private var workflowSteps: some View {
        HStack(spacing: 10) {
            ForEach(LocalPhotosWorkflowStep.allCases, id: \.rawValue) { item in
                let isReached = item.rawValue <= service.workflowStep.rawValue
                HStack(spacing: 7) {
                    Text("\(item.rawValue + 1)")
                        .font(.caption.bold())
                        .frame(width: 22, height: 22)
                        .background(isReached ? Color.accentColor : Color.secondary.opacity(0.18), in: Circle())
                        .foregroundStyle(isReached ? Color.white : Color.secondary)
                    Text(item.title)
                        .font(.callout.weight(item == service.workflowStep ? .semibold : .regular))
                        .foregroundStyle(item == service.workflowStep ? .primary : .secondary)
                }
                if item != LocalPhotosWorkflowStep.allCases.last {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(height: 1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var resultsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                resultSummary
                repairNavigation

                if !service.items.isEmpty {
                    Divider()
                    chunkControls
                    LocalMediaTreeList(
                        service: service,
                        items: service.items,
                        path: \.relativePath,
                        filter: filter,
                        step: .repair
                    ) { item in
                        let didFail = service.attemptedIDs.contains(item.id)
                            && !service.repairedIDs.contains(item.id)
                        LocalMediaSelectableRow(
                            service: service,
                            path: item.relativePath,
                            fileURL: item.fileURL,
                            step: .repair
                        ) {
                            FileDateRepairRow(
                                item: item,
                                isRepaired: service.repairedIDs.contains(item.id),
                                didFail: didFail,
                                failureMessage: didFail ? service.failureMessage(for: item.id) : nil
                            )
                        }
                    }
                }
            }
        }
    }

    private var repairNavigation: some View {
        HStack {
            Button("Back to Conversion Preview") {
                appState.run(.back)
            }
            .pillActionButton()
            .help("Back to the conversion preview (⌘[ or Esc)")
            .disabled(service.isRunning)
            Text("Continue when the date-repair preview has been reviewed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Continue to Organize Preview") {
                service.workflowStep = .organize
            }
            .pillActionButton(prominent: true)
            .keyboardShortcut(.defaultAction)
            .help("Continue to the organize preview (↩)")
            .disabled(service.isRunning)
        }
    }

    private var conversionCard: some View {
        LocalMediaConversionPreviewCard(
            service: service,
            filter: filter,
            continueWithoutConversion: { service.workflowStep = .repair }
        )
    }

    @ViewBuilder
    private var resultSummary: some View {
        let remaining = service.pendingItems.count
        VStack(alignment: .leading, spacing: 5) {
            Text("Scan results")
                .font(.headline)
            Text(
                "\(service.scannedFileCount) supported files scanned · "
                    + "\(service.items.count) need repair · "
                    + "\(service.repairedIDs.count) repaired · \(remaining) remaining"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if let cancellationMessage = service.cancellationMessage {
                Label(cancellationMessage, systemImage: "stop.circle.fill")
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else if service.items.isEmpty {
                Label("No incorrect dates found.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding(.top, 4)
            } else if remaining == 0 {
                Label("All chunks have been processed.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .padding(.top, 4)
            }
        }
    }

    private var chunkControls: some View {
        HStack(spacing: 12) {
            Picker("Chunk size", selection: serviceBinding(\.chunkSize)) {
                Text("25").tag(25)
                Text("100").tag(100)
                Text("250").tag(250)
                Text("500").tag(500)
            }
            .pickerStyle(.menu)
            .frame(width: 180)

            Text("Next chunk: \(service.currentChunk.count) files")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if !service.repairedIDs.isEmpty {
                Button("Clear Processed") {
                    service.clearProcessed()
                }
                .pillActionButton()
                .disabled(service.isRunning)
                .help("Remove successfully repaired files from the list")
            }

            Button("Fix Current Chunk") {
                service.repairCurrentChunk()
            }
            .pillActionButton()
            .disabled(service.currentChunk.isEmpty || service.isRunning)

            Button("Fix All (\(service.pendingItems.count))") {
                service.repairAll()
            }
            .pillActionButton(prominent: true)
            .disabled(service.pendingItems.isEmpty || service.isRunning)
            .help("Repair every remaining file without using chunks")
        }
    }

    private var organizationCard: some View {
        LocalMediaOrganizationPreviewCard(
            service: service,
            filter: filter,
            goBack: { appState.run(.back) },
            finish: { service.workflowStep = .complete }
        )
    }

    private var completionCard: some View {
        LocalMediaCompletionCard(
            service: service,
            reviewRemaining: { service.workflowStep = .organize },
            rescan: rescan,
            returnHome: { appState.run(.home) }
        )
    }

    private var failuresCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(service.failures.count) issues", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ForEach(service.failures.prefix(50)) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.relativePath)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if service.failures.count > 50 {
                    Text("And \(service.failures.count - 50) more…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func serviceBinding<Value>(_ keyPath: ReferenceWritableKeyPath<LocalPhotosService, Value>) -> Binding<Value> {
        Binding(
            get: { service[keyPath: keyPath] },
            set: { service[keyPath: keyPath] = $0 }
        )
    }

    private func rescan() {
        appState.run(.refresh)
    }
}

private struct LocalMediaConversionPreviewCard: View {
    @ObservedObject var service: LocalPhotosService
    let filter: String
    let continueWithoutConversion: () -> Void
    @State private var confirmsConversion = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Conversion preview")
                        .font(.headline)
                    Text(
                        "\(service.conversionItems.count) HEIC images or legacy videos need conversion."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text("Nothing is converted until you confirm this preview.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if service.conversionItems.isEmpty {
                    conversionCompleteLabel
                }
                navigation
                if !service.conversionItems.isEmpty {
                    Divider()
                    LocalMediaTreeList(
                        service: service,
                        items: service.conversionItems,
                        path: \.sourceRelativePath,
                        filter: filter,
                        step: .conversion
                    ) { item in
                        LocalMediaSelectableRow(
                            service: service,
                            path: item.sourceRelativePath,
                            fileURL: item.sourceURL,
                            step: .conversion
                        ) {
                            LocalMediaConversionRow(item: item)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Convert \(service.includedConversionItems.count) files?",
            isPresented: $confirmsConversion,
            titleVisibility: .visible
        ) {
            Button("Convert") { service.convertAll() }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Files convert exactly as shown in the preview. Originals marked "
                + "“Original removed after verification” are permanently deleted once their "
                + "converted copy checks out.")
        }
    }

    private var navigation: some View {
        HStack {
            if !service.conversionItems.isEmpty {
                Button("Skip Conversion", action: continueWithoutConversion)
                    .pillActionButton()
                    .disabled(service.isRunning)
            }
            Spacer()
            if service.conversionItems.isEmpty {
                Button("Continue to Date Preview", action: continueWithoutConversion)
                    .pillActionButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .help("Continue to the date preview (↩)")
            } else {
                Button("Convert \(service.includedConversionItems.count) Files…") {
                    confirmsConversion = true
                }
                .pillActionButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .help("Convert the files in this preview (↩)")
                .disabled(service.isRunning || service.includedConversionItems.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var conversionCompleteLabel: some View {
        if let summary = service.conversionSummary {
            Label(
                "\(summary.converted) converted · \(summary.failed) failed",
                systemImage: summary.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(summary.failed == 0 ? Color.green : Color.orange)
        } else {
            Label("No media needs conversion.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

private struct LocalMediaConversionRow: View {
    let item: LocalMediaConversionItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(.blue)
                .frame(width: 20)
                .localMediaRowAnchor()
            VStack(alignment: .leading, spacing: 5) {
                Text(item.sourceRelativePath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(item.destinationRelativePath)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption.monospaced())
                Text(item.kind.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(
                    item.keepOriginal ? "Original will be kept" : "Original removed after verification",
                    systemImage: item.keepOriginal ? "doc.on.doc" : "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(item.keepOriginal ? Color.secondary : Color.orange)
                if item.destinationWasRenamed {
                    Label("Filename adjusted to avoid an existing file", systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

    private var iconName: String {
        switch item.kind {
        case .heicToJPEG: return "photo.badge.arrow.down"
        case .legacyVideo: return "film.stack"
        case .remuxVideo: return "shippingbox"
        }
    }
}

private struct LocalMediaOrganizationPreviewCard: View {
    @ObservedObject var service: LocalPhotosService
    let filter: String
    let goBack: () -> Void
    let finish: () -> Void
    @State private var confirmsOrganization = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Organization preview")
                        .font(.headline)
                    Text(
                        "\(service.organizationItems.count) moves planned from "
                            + "\(service.scannedFileCount) supported media files · "
                            + "\(service.organizationSkippedCount) already organized."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text("No files move until you confirm this preview.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if service.organizationItems.isEmpty {
                    Label("All scanned files are already organized.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                navigation
                if !service.organizationItems.isEmpty {
                    Divider()
                    LocalMediaTreeList(
                        service: service,
                        items: service.organizationItems,
                        path: \.sourceRelativePath,
                        filter: filter,
                        step: .organization
                    ) { item in
                        LocalMediaSelectableRow(
                            service: service,
                            path: item.sourceRelativePath,
                            fileURL: item.sourceURL,
                            step: .organization
                        ) {
                            LocalMediaOrganizationRow(item: item)
                        }
                    }
                }
                if !service.keptItems.isEmpty {
                    LocalMediaKeptSection(items: service.keptItems)
                }
            }
        }
        .confirmationDialog(
            "Organize \(service.includedOrganizationItems.count) files?",
            isPresented: $confirmsOrganization,
            titleVisibility: .visible
        ) {
            Button("Organize") { service.organizeAll() }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Every file moves exactly as shown in the preview.")
        }
    }

    private var navigation: some View {
        HStack {
            Button("Back to Date Preview", action: goBack)
                .pillActionButton()
                .help("Back to the date preview (⌘[ or Esc)")
                .disabled(service.isRunning)
            Spacer()
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if service.organizationItems.isEmpty {
            Button("Finish", action: finish)
                .pillActionButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .help("Show the summary (↩)")
        } else {
            Button("Organize \(service.includedOrganizationItems.count) Files…") {
                confirmsOrganization = true
            }
            .pillActionButton(prominent: true)
            .keyboardShortcut(.defaultAction)
            .disabled(service.isRunning || service.includedOrganizationItems.isEmpty)
            .help("Move every file exactly as shown in this preview (↩)")
        }
    }
}

private struct LocalMediaCompletionCard: View {
    @ObservedObject var service: LocalPhotosService
    let reviewRemaining: () -> Void
    let rescan: () -> Void
    let returnHome: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Organization summary")
                    .font(.headline)
                summary
                Text(
                    service.organizationItems.isEmpty
                        ? "The refreshed preview has no remaining moves."
                        : "\(service.organizationItems.count) moves remain in the refreshed preview."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Divider()
                actions
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let summary = service.organizationSummary {
            Label(
                "\(summary.moved) moved · \(summary.skipped) skipped · "
                    + "\(summary.failed) failed · \(summary.total) planned",
                systemImage: summary.failed == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(summary.failed == 0 ? Color.green : Color.orange)
            if summary.wasCancelled {
                Text("Organization was cancelled. Completed moves were kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("No files needed organization.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        }
    }

    private var actions: some View {
        HStack {
            Button("Review Remaining Moves", action: reviewRemaining)
                .pillActionButton()
                .disabled(service.isRunning || service.organizationItems.isEmpty)
            Button("Rescan", action: rescan)
                .pillActionButton()
                .help("Scan the folder again (⌘R)")
                .disabled(service.isRunning)
            Spacer()
            Button("Return Home", action: returnHome)
                .pillActionButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .help("Back to the home screen (↩ or ⇧⌘H)")
        }
    }
}

private struct LocalMediaOrganizationRow: View {
    let item: LocalMediaOrganizationItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.isVideo ? "film.fill" : "photo.fill")
                .foregroundStyle(item.isVideo ? .purple : .blue)
                .frame(width: 20)
                .localMediaRowAnchor()

            VStack(alignment: .leading, spacing: 5) {
                Text(item.sourceRelativePath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(item.destinationRelativePath)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption.monospaced())
                Text(
                    "\(item.proposedDate.formatted(date: .abbreviated, time: .omitted)) "
                        + "from \(item.proposedSource.label)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if item.destinationWasRenamed {
                    Label("Filename adjusted to avoid an existing file", systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

private struct FileDateRepairRow: View {
    let item: FileDateRepairItem
    let isRepaired: Bool
    let didFail: Bool
    let failureMessage: String?
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                        .localMediaRowAnchor()
                    statusIcon
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.relativePath)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text(format(item.newestDisagreeingDate))
                                .strikethrough()
                            Image(systemName: "arrow.right")
                            Text(format(item.proposedDate))
                                .foregroundStyle(.green)
                            Text("from \(item.proposedSource.label)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.monospacedDigit())
                    }
                    Spacer(minLength: 0)
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 5) {
                        if let failureMessage {
                            Text(failureMessage)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(item.evidence) { evidence in
                            HStack {
                                Text(evidence.source.label)
                                Spacer()
                                Text(format(evidence.date))
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 40)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isRepaired {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if didFail {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(.blue)
        }
    }

    private func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
