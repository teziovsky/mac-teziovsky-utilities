@testable import TeziovskyUtilities
import XCTest

/// Runs the real finalize steps on a temporary project. The Trash is replaced by a folder
/// inside the fixture so nothing lands in the user's Trash.
@MainActor
final class DroneFinalizerExecutionTests: XCTestCase {
    private var root: URL!
    private var project: URL { root.appendingPathComponent("project", isDirectory: true) }
    private var export: URL { project.appendingPathComponent("export", isDirectory: true) }
    private var trash: URL { root.appendingPathComponent("Trash", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroneFinalizerExecution-\(UUID().uuidString)", isDirectory: true)
        for directory in [project.appendingPathComponent("raw"), export, trash] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testFlattenKeepsExportFolderThatStillHoldsUnplannedFiles() async throws {
        try Data("graded".utf8).write(to: export.appendingPathComponent("clip.mov"))
        try Data("resolve project".utf8).write(to: export.appendingPathComponent("project.drp"))
        let finalizer = makeFinalizer()

        finalizer.loadProject(projectDirectory: project, config: .default)
        try await perform(finalizer, steps: 3)

        XCTAssertTrue(exists(project.appendingPathComponent("clip.mov")))
        XCTAssertTrue(exists(export.appendingPathComponent("project.drp")), "Unplanned files must not be trashed")
        XCTAssertEqual(try trashedNames(), [])
        XCTAssertTrue(
            finalizer.failures.contains { $0.message.contains("project.drp") },
            "The kept file must be reported: \(finalizer.failures.map(\.message))"
        )
    }

    func testFlattenTrashesExportFolderOnceItIsEmpty() async throws {
        try Data("graded".utf8).write(to: export.appendingPathComponent("clip.mov"))
        let finalizer = makeFinalizer()

        finalizer.loadProject(projectDirectory: project, config: .default)
        try await perform(finalizer, steps: 3)

        XCTAssertTrue(exists(project.appendingPathComponent("clip.mov")))
        XCTAssertFalse(exists(export))
        XCTAssertEqual(try trashedNames(), ["export"])
    }

    func testCleanupKeepsOriginalWhenCompressedVideoIsNotPlayable() async throws {
        try await TestVideoFactory.makeVideo(at: export.appendingPathComponent("clip.mov"), seconds: 3)
        try Data(repeating: 0x42, count: 4_096).write(to: export.appendingPathComponent("clip_COMPRESSED.mp4"))
        let finalizer = makeFinalizer()

        finalizer.loadProject(projectDirectory: project, config: .default)
        try await perform(finalizer, steps: 2)

        XCTAssertTrue(exists(export.appendingPathComponent("clip.mov")), "The original must not be trashed")
        XCTAssertTrue(exists(export.appendingPathComponent("clip_COMPRESSED.mp4")))
        XCTAssertEqual(try trashedNames(), [])
        XCTAssertTrue(finalizer.failures.contains { $0.filename == "clip_COMPRESSED.mp4" })
    }

    func testCleanupKeepsOriginalWhenCompressedVideoIsTruncated() async throws {
        try await TestVideoFactory.makeVideo(at: export.appendingPathComponent("clip.mov"), seconds: 4)
        try await TestVideoFactory.makeVideo(
            at: export.appendingPathComponent("clip_COMPRESSED.mp4"),
            seconds: 1,
            fileType: .mp4
        )
        let finalizer = makeFinalizer()

        finalizer.loadProject(projectDirectory: project, config: .default)
        try await perform(finalizer, steps: 2)

        XCTAssertTrue(exists(export.appendingPathComponent("clip.mov")))
        XCTAssertEqual(try trashedNames(), [])
        XCTAssertTrue(finalizer.failures.contains { $0.filename == "clip_COMPRESSED.mp4" })
    }

    func testCleanupTrashesOriginalForAVerifiedCompressedCopy() async throws {
        try await TestVideoFactory.makeVideo(at: export.appendingPathComponent("clip.mov"), seconds: 3)
        try await TestVideoFactory.makeVideo(
            at: export.appendingPathComponent("clip_COMPRESSED.mp4"),
            seconds: 3,
            fileType: .mp4
        )
        let finalizer = makeFinalizer()

        finalizer.loadProject(projectDirectory: project, config: .default)
        try await perform(finalizer, steps: 2)

        XCTAssertFalse(exists(export.appendingPathComponent("clip.mov")))
        XCTAssertTrue(exists(export.appendingPathComponent("clip.mp4")))
        XCTAssertEqual(try trashedNames(), ["clip.mov"])
    }

    // MARK: - Helpers

    private func makeFinalizer() -> DroneFinalizer {
        let trash = trash
        return DroneFinalizer(trash: { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
    }

    private func perform(_ finalizer: DroneFinalizer, steps: Int) async throws {
        for _ in 0..<steps {
            finalizer.performCurrentStep()
            try await waitUntilIdle(finalizer)
        }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func trashedNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: trash.path).sorted()
    }
}

/// Navigation must never undo filesystem work; undo is its own explicit action.
@MainActor
final class DroneWorkflowFinalizeNavigationTests: XCTestCase {
    private var root: URL!
    private var project: URL { root.appendingPathComponent("project", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroneWorkflowNavigation-\(UUID().uuidString)", isDirectory: true)
        for name in ["raw", "export"] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Trash"),
            withIntermediateDirectories: true
        )
        try Data("graded".utf8).write(to: project.appendingPathComponent("export/clip.mov"))
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testGoBackDuringFinalizeDoesNotUndoCompletedSteps() async throws {
        let workflow = makeWorkflow()
        workflow.loadProject(projectDirectory: project, config: .default)
        workflow.beginFinalize()
        workflow.performFinalizeStep()
        try await waitUntilIdle(workflow.finalizer)
        XCTAssertEqual(workflow.finalizer.step, .cleanup)

        workflow.goBack()
        try await waitUntilIdle(workflow.finalizer)

        XCTAssertEqual(workflow.finalizer.step, .cleanup, "Go Back / Esc must not revert file changes")
        XCTAssertEqual(workflow.phase, .finalize)
    }

    func testUndoLastFinalizeStepRevertsIt() async throws {
        let workflow = makeWorkflow()
        workflow.loadProject(projectDirectory: project, config: .default)
        workflow.beginFinalize()
        workflow.performFinalizeStep()
        try await waitUntilIdle(workflow.finalizer)

        workflow.undoLastFinalizeStep()
        try await waitUntilIdle(workflow.finalizer)

        XCTAssertEqual(workflow.finalizer.step, .merge)
    }

    func testPhaseBecomesDoneAfterTheLastFinalizeStep() async throws {
        let workflow = makeWorkflow()
        workflow.loadProject(projectDirectory: project, config: .default)
        workflow.beginFinalize()
        for _ in 0..<3 {
            workflow.performFinalizeStep()
            try await waitUntilIdle(workflow.finalizer)
        }

        XCTAssertEqual(workflow.finalizer.step, .done)
        XCTAssertEqual(workflow.phase, .done)
    }

    private func makeWorkflow() -> DroneWorkflowCoordinator {
        let trash = root.appendingPathComponent("Trash")
        return DroneWorkflowCoordinator(finalizer: DroneFinalizer(trash: { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }))
    }
}

@MainActor
private func waitUntilIdle(_ finalizer: DroneFinalizer, timeout: TimeInterval = 30) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while finalizer.isRunning {
        guard Date() < deadline else {
            XCTFail("Finalize step did not finish within \(timeout) s")
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    // Let observers of the finished step (e.g. the workflow phase) run.
    try await Task.sleep(nanoseconds: 50_000_000)
}
