import AppKit
import CoreGraphics
import ImageIO
@testable import TeziovskyUtilities
import XCTest

/// Every shortcut either runs or explains itself; nothing is silently blocked.
@MainActor
final class AppCommandDecisionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCommands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testHomeWorksFromEveryModeWhenIdle() {
        let state = makeState()
        for route in [AppRoute.photos, .localPhotos, .drone] {
            state.route = route
            XCTAssertEqual(state.decision(for: .home), .perform, "\(route)")
        }
    }

    func testCommandsAreBlockedWhileADialogIsOpen() {
        let state = makeState()
        state.route = .drone
        state.isPresentingModalUI = { true }
        for command in [AppCommand.home, .back, .escape, .openFolder, .refresh] {
            assertNotice(state.decision(for: command), contains: "dialog")
        }
    }

    func testPhotosOnlyCommandsExplainThemselvesInOtherModes() {
        let state = makeState()
        state.route = .drone
        let photosOnly: [AppCommand] = [
            .toggleSidebar, .toggleThumbnails, .organize, .quickLook, .largerThumbnails,
            .smallerThumbnails, .selectAlbum(0), .nextAlbum, .previousAlbum
        ]
        for command in photosOnly {
            assertNotice(state.decision(for: command), contains: "Export iCloud Photos")
        }
    }

    func testUndoLastStepExplainsItselfOutsideDroneAndWhenThereIsNothingToUndo() {
        let state = makeState()
        state.route = .photos
        assertNotice(state.decision(for: .undoFinalizeStep), contains: "Organize Drone Footage")
        state.route = .drone
        assertNotice(state.decision(for: .undoFinalizeStep), contains: "nothing to undo")
    }

    func testOpenFolderExplainsWhereThereIsNoFolderToOpen() {
        let state = makeState()
        state.route = .photos
        assertNotice(state.decision(for: .openFolder), contains: "⌘E")
        state.route = .home
        assertNotice(state.decision(for: .openFolder), contains: "Choose a workflow")
        state.route = .localPhotos
        XCTAssertEqual(state.decision(for: .openFolder), .perform)
        state.route = .drone
        XCTAssertEqual(state.decision(for: .openFolder), .perform)
    }

    func testRevealAndRefreshNeedAFolderFirst() {
        let state = makeState()
        for route in [AppRoute.localPhotos, .drone] {
            state.route = route
            assertNotice(state.decision(for: .reveal), contains: "⌘O")
            assertNotice(state.decision(for: .refresh), contains: "⌘O")
        }
    }

    func testPhotosCommandsSayWhatIsMissing() {
        let state = makeState()
        state.route = .photos
        assertNotice(state.decision(for: .toggleThumbnails), contains: "Select an album")
        assertNotice(state.decision(for: .organize), contains: "Select an album")
        assertNotice(state.decision(for: .quickLook), contains: "Select a photo")
        assertNotice(state.decision(for: .selectAlbum(4)), contains: "album 5")
    }

    func testBackClimbsOutOfPhotosToHome() async throws {
        let state = makeState()
        state.route = .photos
        state.selectedAlbum = PhotoAlbum(
            id: "a", name: "Trip", mediaCount: 1, photoCount: 1, videoCount: 0, collectionIdentifier: "a"
        )
        state.selectedMediaID = "photo"

        state.run(.back)
        XCTAssertNil(state.selectedMediaID)
        state.run(.back)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(state.selectedAlbum)
        state.run(.back)
        XCTAssertEqual(state.route, .home)
    }

    func testEscapeFirstLeavesATextFieldInsteadOfGoingBack() throws {
        let state = makeState()
        state.route = .photos
        state.selectedAlbum = PhotoAlbum(
            id: "a", name: "Trip", mediaCount: 1, photoCount: 1, videoCount: 0, collectionIdentifier: "a"
        )
        state.selectedMediaID = "photo"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(field)
        state.mainWindow = window
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue((window.firstResponder as? NSText)?.isFieldEditor == true, "Field should be editing")

        state.run(.escape)
        XCTAssertEqual(state.selectedMediaID, "photo", "The first Esc only leaves the text field")
        XCTAssertNil(state.notice)
        XCTAssertFalse(window.firstResponder is NSText)

        state.run(.escape)
        XCTAssertNil(state.selectedMediaID, "The next Esc navigates back")
    }

    func testLocalPhotosBlocksHomeAndEscapeWhileScanningThenAllowsHome() async throws {
        for index in 0..<200 {
            try makeJPEG("\(index).jpg")
        }
        let state = makeState()
        state.route = .localPhotos
        state.localPhotosService.scan(directory: root)

        assertNotice(state.decision(for: .home), contains: "Scanning")
        assertNotice(state.decision(for: .escape), contains: "Cancel")
        state.run(.home)
        XCTAssertEqual(state.route, .localPhotos, "Blocked home must not leave the mode")
        XCTAssertNotNil(state.notice)

        try await waitUntilIdle(state.localPhotosService)
        state.run(.home)
        XCTAssertEqual(state.route, .home)
        XCTAssertNil(state.localPhotosService.directory, "Leaving resets the mode")
    }

    func testBackWalksTheLocalPhotosStepsAndProtectsResultsAtTheFirstStep() async throws {
        try makeJPEG("a.jpg")
        let state = makeState()
        state.route = .localPhotos
        state.localPhotosService.scan(directory: root)
        try await waitUntilIdle(state.localPhotosService)
        state.localPhotosService.workflowStep = .organize

        state.run(.back)
        XCTAssertEqual(state.localPhotosService.workflowStep, .repair)
        state.run(.escape)
        XCTAssertEqual(state.localPhotosService.workflowStep, .convert)
        assertNotice(state.decision(for: .back), contains: "⇧⌘H")
        XCTAssertEqual(state.route, .localPhotos)
    }

    func testDroneBlocksHomeDuringAFinalizeStepAndPointsBackToUndoAfterIt() async throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        for name in ["raw", "export"] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        try Data("graded".utf8).write(to: project.appendingPathComponent("export/clip.mov"))
        let state = makeState()
        state.route = .drone
        state.droneWorkflow.loadProject(projectDirectory: project, config: .default)
        state.droneWorkflow.beginFinalize()

        state.droneWorkflow.performFinalizeStep()
        assertNotice(state.decision(for: .home), contains: "finalize")

        while state.droneWorkflow.finalizer.isRunning {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        assertNotice(state.decision(for: .back), contains: "⌥⌘Z")
        XCTAssertEqual(state.decision(for: .undoFinalizeStep), .perform)
    }

    // MARK: - Helpers

    private func makeState() -> AppState {
        let state = AppState()
        state.playsAlertSound = false
        state.isPresentingModalUI = { false }
        return state
    }

    private func assertNotice(
        _ decision: CommandDecision,
        contains fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .notice(let message) = decision else {
            return XCTFail("Expected a notice containing “\(fragment)”, got \(decision)", file: file, line: line)
        }
        XCTAssertTrue(message.contains(fragment), "“\(message)” lacks “\(fragment)”", file: file, line: line)
    }

    private func waitUntilIdle(_ service: LocalPhotosService) async throws {
        let deadline = Date().addingTimeInterval(30)
        try await Task.sleep(nanoseconds: 20_000_000)
        while service.isRunning {
            guard Date() < deadline else { return XCTFail("Service did not finish") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeJPEG(_ name: String) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            root.appendingPathComponent(name) as CFURL, "public.jpeg" as CFString, 1, nil
        ))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2015:06:15 12:00:00"]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

/// The Local Photos step lives in the service so shortcuts can move it.
@MainActor
final class LocalPhotosWorkflowStepTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalPhotosSteps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testScanStartsAtTheConversionStep() async throws {
        let service = LocalPhotosService()
        service.workflowStep = .organize
        service.scan(directory: root)
        XCTAssertEqual(service.workflowStep, .convert)
    }

    func testOrganizingEndsOnTheSummary() async throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            root.appendingPathComponent("a.jpg") as CFURL, "public.jpeg" as CFString, 1, nil
        ))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2015:06:15 12:00:00"]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let service = LocalPhotosService()
        service.scan(directory: root)
        try await waitUntilIdle(service)
        service.workflowStep = .organize

        service.organizeAll()
        try await waitUntilIdle(service)

        XCTAssertEqual(service.workflowStep, .complete)
    }

    private func waitUntilIdle(_ service: LocalPhotosService) async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
        while service.isRunning {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
