import AppKit
import SwiftUI

struct DroneModeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pendingDestructiveStep: DroneFinalizeStep?

    @ObservedObject var workflow: DroneWorkflowCoordinator
    private var finalizer: DroneFinalizer { workflow.finalizer }
    private var config: DroneFinalizeConfig { AppSettings.droneFinalizeConfig }

    private static let topID = "drone-top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
            }
            .onChange(of: workflow.phase) { _, _ in scrollToTop(proxy) }
            .onChange(of: finalizer.step) { _, _ in scrollToTop(proxy) }
        }
        .navigationTitle(AppBranding.droneModeTitle)
        .toolbar {
            toolbarContent
        }
        .confirmationDialog(
            pendingDestructiveStep.map { "\($0.actionTitle)?" } ?? "",
            isPresented: Binding(
                get: { pendingDestructiveStep != nil },
                set: { if !$0 { pendingDestructiveStep = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDestructiveStep
        ) { step in
            Button(step.actionTitle, role: .destructive) {
                pendingDestructiveStep = nil
                workflow.performFinalizeStep()
            }
            Button("Cancel", role: .cancel) {
                pendingDestructiveStep = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: { step in
            Text(confirmationMessage(for: step))
        }
        .onDisappear {
            if !isBusy {
                workflow.reset()
            }
        }
    }

    /// Each step's buttons sit at the top of its card; bring them into view on a new step.
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        withAnimation(.smooth(duration: 0.25)) {
            proxy.scrollTo(Self.topID, anchor: .top)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
                .id(Self.topID)
            folderSection

            if let error = workflow.previewError ?? finalizer.previewError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if workflow.hasProject && workflow.previewError == nil && finalizer.previewError == nil {
                DroneWorkflowStepIndicator(current: workflow.phase)
                    .frame(maxWidth: .infinity)
                phaseCard
                if !workflowFailures.isEmpty {
                    DroneNotesBox(failures: workflowFailures)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                appState.run(.home)
            } label: {
                Label("Home", systemImage: "house")
            }
            .help("Back to the home screen (⇧⌘H)")
        }

        ToolbarItem(placement: .navigation) {
            Button {
                appState.run(.back)
            } label: {
                Label("Go Back", systemImage: "chevron.backward")
            }
            .help("Go back one step (⌘[ or Esc). Never changes files.")
            .disabled(!workflow.canGoBack || isBusy)
        }

        if workflow.canUndoFinalizeStep {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.run(.undoFinalizeStep)
                } label: {
                    Label("Undo Last Step", systemImage: "arrow.uturn.backward")
                }
                .help("Revert the last finalize step: restore trashed files and undo renames (⌥⌘Z)")
                .disabled(isBusy)
            }
        }
    }

    private var isBusy: Bool {
        finalizer.isRunning || workflow.compressionSession.isRunning
    }

    private var workflowFailures: [OrganizeFailure] {
        finalizer.failures + workflow.compressionSession.failures
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppBranding.droneModeTitle)
                .font(.largeTitle.bold())
            Text(AppBranding.droneModeSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var folderSection: some View {
        GlassCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project folder")
                        .font(.headline)
                    if !workflow.hasProject {
                        Text("Pick the folder that contains your “\(config.rawDirectoryName)” and “\(config.exportDirectoryName)” subfolders.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                if let path = workflow.projectDirectoryPath {
                    Text(DroneFormat.abbreviatedPath(path))
                        .font(.callout.monospaced())
                        .foregroundStyle(Color.green.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button(workflow.hasProject ? "Change" : "Choose") {
                    appState.run(.openFolder)
                }
                .pillActionButton()
                .help("Choose the drone project folder (⌘O)")
            }
        }
    }

    @ViewBuilder
    private var phaseCard: some View {
        switch workflow.phase {
        case .validateLayout:
            DroneValidateLayoutStepView(
                result: workflow.validationResult,
                config: config,
                isRunning: false,
                onCreateMissing: { workflow.createMissingOrientationDirectories() },
                action: { workflow.continueFromValidation() }
            )
        case .waitForResolve:
            DroneWaitResolveStepView(
                config: config,
                openResolve: { workflow.openDaVinciResolve() },
                action: { workflow.finishResolveEditing() }
            )
        case .scanExport:
            DroneScanExportStepView(
                exports: workflow.uncompressedExports,
                message: workflow.scanMessage,
                isRunning: false,
                onRescan: { workflow.refreshExportScan() },
                action: { workflow.continueFromScan() }
            )
        case .pickPreset:
            DronePickPresetStepView(
                presets: workflow.presetLoader.presets,
                selectedPreset: workflow.selectedPreset,
                isLoading: workflow.presetLoader.isLoading,
                errorMessage: workflow.presetLoader.errorMessage,
                onSelect: { workflow.selectPreset($0) },
                action: {
                    AppSettings.droneLastHandBrakePreset = workflow.selectedPreset
                    workflow.continueFromPresetPicker()
                }
            )
        case .compress:
            DroneCompressStepView(
                exports: workflow.uncompressedExports,
                preset: workflow.selectedPreset,
                progress: workflow.compressionSession.progress,
                isRunning: workflow.compressionSession.isRunning,
                onStart: { workflow.startCompression() },
                onCancel: { workflow.compressionSession.cancel() },
                action: { workflow.continueFromCompression() }
            )
        case .finalize:
            finalizeStepCard
        case .done:
            DroneDoneStepView(
                projectPath: workflow.projectDirectoryPath,
                config: config,
                onChooseAnother: { appState.run(.openFolder) }
            )
        }
    }

    @ViewBuilder
    private var finalizeStepCard: some View {
        switch finalizer.step {
        case .merge:
            DroneMergeStepView(
                pairs: finalizer.pairMetadata,
                isRunning: finalizer.isRunning,
                statusMessage: finalizer.statusMessage,
                action: { workflow.performFinalizeStep() }
            )
        case .cleanup:
            DroneCleanupStepView(
                plan: finalizer.plan,
                config: config,
                isRunning: finalizer.isRunning,
                statusMessage: finalizer.statusMessage,
                action: { pendingDestructiveStep = .cleanup }
            )
        case .flatten:
            DroneFlattenStepView(
                plan: finalizer.plan,
                config: config,
                isRunning: finalizer.isRunning,
                statusMessage: finalizer.statusMessage,
                action: { pendingDestructiveStep = .flatten }
            )
        case .done:
            DroneDoneStepView(
                projectPath: workflow.projectDirectoryPath,
                config: config,
                onChooseAnother: { appState.run(.openFolder) }
            )
        }
    }

    private func confirmationMessage(for step: DroneFinalizeStep) -> String {
        let plan = finalizer.plan
        switch step {
        case .cleanup:
            let count = plan?.matchedPairs.count ?? 0
            return "\(count) original\(count == 1 ? "" : "s") will be moved to the Trash and compressed files renamed. "
                + "You can undo this step afterwards."
        case .flatten:
            let rawNote = finalizer.config.keepRawAfterFinalize
                ? ""
                : " The “\(finalizer.config.rawDirectoryName)/” folder with the raw footage will be moved to the Trash."
            return "Finished media will be moved into the project folder.\(rawNote) You can undo this step afterwards."
        case .merge, .done:
            return ""
        }
    }
}

// MARK: - Workflow step indicator

private struct DroneWorkflowStepIndicator: View {
    let current: DroneWorkflowPhase

    private let steps: [DroneWorkflowPhase] = [
        .validateLayout, .waitForResolve, .scanExport, .pickPreset, .compress, .finalize,
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                    let state = state(for: step)
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(state == .upcoming ? Color.secondary.opacity(0.2) : Color.accentColor)
                                .frame(width: 26, height: 26)
                            if state == .done {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(step.stepNumber)")
                                    .font(.caption.bold())
                                    .foregroundStyle(state == .upcoming ? Color.secondary : .white)
                            }
                        }
                        Text(step.shortTitle)
                            .font(.subheadline)
                            .fontWeight(state == .current ? .semibold : .regular)
                            .foregroundStyle(state == .upcoming ? Color.secondary : .primary)
                    }
                    if index < steps.count - 1 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 16, height: 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private enum State { case done, current, upcoming }

    private func state(for step: DroneWorkflowPhase) -> State {
        if current == .done { return .done }
        if step.rawValue < current.rawValue { return .done }
        if step == current { return .current }
        return .upcoming
    }
}

// MARK: - Workflow phase views

private struct DroneValidateLayoutStepView: View {
    let result: DroneProjectValidationResult?
    let config: DroneFinalizeConfig
    let isRunning: Bool
    let onCreateMissing: () -> Void
    let action: () -> Void

    private var layoutDescription: String {
        "Confirm the project has “\(config.rawDirectoryName)/” and “\(config.exportDirectoryName)/”, "
            + "optionally with “\(config.verticalDirectoryName)/” and “\(config.horizontalDirectoryName)/”."
    }

    var body: some View {
        DroneWorkflowStepContainer(
            phase: .validateLayout,
            description: layoutDescription,
            isRunning: isRunning,
            statusMessage: nil,
            actionTitle: "Continue",
            actionRole: nil,
            actionDisabled: result?.canContinue != true,
            action: action
        ) {
            if let result {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(result.treeLines, id: \.self) { line in
                        Text(line).font(.callout.monospaced())
                    }
                    ForEach(result.messages, id: \.self) { message in
                        Label(message, systemImage: result.status == .invalid ? "xmark.circle.fill" : "info.circle")
                            .font(.callout)
                            .foregroundStyle(result.status == .invalid ? .red : .secondary)
                    }
                    if result.status == .validWithWarnings {
                        Button("Create missing orientation folders", action: onCreateMissing)
                            .pillActionButton()
                    }
                }
            }
        }
    }
}

private struct DroneWaitResolveStepView: View {
    let config: DroneFinalizeConfig
    let openResolve: () -> Void
    let action: () -> Void

    var body: some View {
        DroneWorkflowStepContainer(
            phase: .waitForResolve,
            description: "Cut scenes, grade, and export movies into “\(config.exportDirectoryName)/”. Come back here when exports are ready for compression.",
            isRunning: false,
            statusMessage: nil,
            actionTitle: "Done exporting",
            actionRole: nil,
            actionDisabled: false,
            secondaryActionTitle: "Open DaVinci Resolve",
            secondaryAction: openResolve,
            action: action
        ) {
            VStack(alignment: .leading, spacing: 8) {
                checklistItem("Raw footage is in “\(config.rawDirectoryName)/”")
                checklistItem("Scenes are cut and graded in DaVinci Resolve")
                checklistItem("Exports are saved into “\(config.exportDirectoryName)/”")
            }
        }
    }

    private func checklistItem(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

private struct DroneScanExportStepView: View {
    let exports: [DroneUncompressedExport]
    let message: String?
    let isRunning: Bool
    let onRescan: () -> Void
    let action: () -> Void

    var body: some View {
        DroneWorkflowStepContainer(
            phase: .scanExport,
            description: "These Resolve exports do not yet have compressed copies in the same folder.",
            isRunning: isRunning,
            statusMessage: nil,
            actionTitle: exports.isEmpty ? "Continue to finalize" : "Continue",
            actionRole: nil,
            actionDisabled: false,
            secondaryActionTitle: "Rescan",
            secondaryAction: onRescan,
            action: action
        ) {
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if exports.isEmpty {
                Text("No uncompressed exports found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(exports.prefix(40)) { export in
                        HStack {
                            Text(export.relativePath)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                            Spacer()
                            Text(DroneFormat.size(export.fileSizeBytes))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if exports.count > 40 {
                        Text("And \(exports.count - 40) more…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct DronePickPresetStepView: View {
    let presets: [String]
    let selectedPreset: String
    let isLoading: Bool
    let errorMessage: String?
    let onSelect: (String) -> Void
    let action: () -> Void

    var body: some View {
        DroneWorkflowStepContainer(
            phase: .pickPreset,
            description: "Choose the HandBrake preset for this project.",
            isRunning: isLoading,
            statusMessage: isLoading ? "Loading presets…" : nil,
            actionTitle: "Continue",
            actionRole: nil,
            actionDisabled: selectedPreset.isEmpty,
            action: action
        ) {
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.orange)
            }
            if presets.isEmpty && !isLoading {
                Text("No presets loaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Preset", selection: Binding(
                    get: { selectedPreset },
                    set: { onSelect($0) }
                )) {
                    Text("Select a preset").tag("")
                    ForEach(presets, id: \.self) { preset in
                        Text(preset).tag(preset)
                    }
                }
                .labelsHidden()
            }
        }
        .onAppear {
            if selectedPreset.isEmpty, !AppSettings.droneLastHandBrakePreset.isEmpty {
                onSelect(AppSettings.droneLastHandBrakePreset)
            }
        }
    }
}

private struct DroneCompressStepView: View {
    let exports: [DroneUncompressedExport]
    let preset: String
    let progress: HandBrakeCompressionProgress?
    let isRunning: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    let action: () -> Void

    private var isComplete: Bool { progress?.isComplete == true }

    private var description: String {
        "Compress \(exports.count) export\(exports.count == 1 ? "" : "s") with preset “\(preset)” using HandBrakeCLI."
    }

    var body: some View {
        DroneWorkflowStepContainer(
            phase: .compress,
            description: description,
            isRunning: isRunning,
            statusMessage: progress.map(Self.statusMessage),
            actionTitle: isComplete ? "Continue to finalize" : "Start compression",
            actionRole: nil,
            actionDisabled: isRunning || (!isComplete && preset.isEmpty),
            action: isComplete ? action : onStart
        ) {
            if let progress, isRunning || isComplete {
                ProgressView(value: progress.overallFraction)
                HStack {
                    Text(Self.summary(progress))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isRunning {
                        Button("Cancel", role: .cancel, action: onCancel)
                            .pillActionButton()
                            .help("Stop HandBrakeCLI; the unfinished file is discarded")
                    }
                }
            }
        }
    }

    private static func statusMessage(_ progress: HandBrakeCompressionProgress) -> String {
        var parts = ["Compressing \(progress.filename) (\(progress.current)/\(progress.total))"]
        parts.append("\(Int((progress.fileFraction * 100).rounded(.down)))%")
        if let eta = progress.eta {
            parts.append("ETA \(eta)")
        }
        return parts.joined(separator: " · ")
    }

    private static func summary(_ progress: HandBrakeCompressionProgress) -> String {
        if progress.wasCancelled {
            return "Cancelled after \(progress.completed) of \(progress.total)"
        }
        return "\(progress.completed) of \(progress.total) complete"
    }
}

private struct DroneWorkflowStepContainer<Content: View>: View {
    let phase: DroneWorkflowPhase
    let description: String
    let isRunning: Bool
    let statusMessage: String?
    let actionTitle: String
    let actionRole: ButtonRole?
    let actionDisabled: Bool
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label(phase.title, systemImage: phase.systemImage)
                    .font(.title3.weight(.semibold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Actions come before the (often long) step content, so reaching them takes no scrolling.
                HStack {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                        Text(statusMessage ?? "Working…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let secondaryActionTitle, let secondaryAction {
                        Button(secondaryActionTitle, action: secondaryAction)
                            .pillActionButton()
                            .disabled(isRunning)
                    }
                    Button(actionTitle, role: actionRole, action: action)
                        .pillActionButton(prominent: true)
                        .keyboardShortcut(.defaultAction)
                        .help("\(actionTitle) (↩)")
                        .disabled(isRunning || actionDisabled)
                }

                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DroneNotesBox: View {
    let failures: [OrganizeFailure]

    var body: some View {
        GlassCard(title: "Notes") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(failures.prefix(50)) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        if !failure.filename.isEmpty {
                            Text(failure.filename)
                                .font(.callout)
                                .bold()
                        }
                        Text(failure.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum DroneFormat {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }

    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
