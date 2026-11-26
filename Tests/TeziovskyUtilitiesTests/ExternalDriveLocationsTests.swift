import Foundation
@testable import TeziovskyUtilities
import XCTest

final class ExternalDriveLocationsTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var originalDefaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriveLocations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "ExternalDriveLocationsTests-\(UUID().uuidString)"
        originalDefaults = AppSettings.externalDriveDefaults
        AppSettings.externalDriveDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        AppSettings.externalDriveDefaults.removePersistentDomain(forName: suiteName)
        AppSettings.externalDriveDefaults = originalDefaults
        try? FileManager.default.removeItem(at: root)
    }

    func testPreflightOnBootVolumeIsNotConnected() throws {
        let destination = root.appendingPathComponent("MEDIA", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = ExternalDriveLocations.preflight(destination: .resolved(destination), bootVolume: root)
        XCTAssertEqual(result, .notConnected("MEDIA isn't connected. Connect the drive and press Check Again (⌘R)."))
    }

    func testPreflightWithDifferentVolumeIsReady() throws {
        let rootValues = try root.resourceValues(forKeys: [.volumeIdentifierKey])
        let rootVolume = try XCTUnwrap(rootValues.volumeIdentifier as? NSObject)
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        let other = volumes.map { URL(fileURLWithPath: "/Volumes/\($0)") }.first { url in
            let id = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            return id != nil && id != rootVolume
        }
        try XCTSkipUnless(other != nil, "No second volume mounted")
        let result = ExternalDriveLocations.preflight(destination: .resolved(root), bootVolume: try XCTUnwrap(other))
        guard case let .ready(freeBytes) = result else { return XCTFail("Expected ready, got \(result)") }
        XCTAssertGreaterThan(freeBytes, 0)
    }

    func testPreflightMissingFolderIsNotConnected() {
        let missing = root.appendingPathComponent("GONE", isDirectory: true)
        let result = ExternalDriveLocations.preflight(destination: .resolved(missing), bootVolume: root)
        XCTAssertEqual(result, .notConnected("GONE isn't connected. Connect the drive and press Check Again (⌘R)."))
    }

    func testPreflightUnavailableUsesStoredPathName() {
        let result = ExternalDriveLocations.preflight(
            destination: .unavailable(path: "/Volumes/MEDIA"),
            bootVolume: root
        )
        XCTAssertEqual(result, .notConnected("MEDIA isn't connected. Connect the drive and press Check Again (⌘R)."))
    }

    func testPreflightNotChosen() {
        XCTAssertEqual(ExternalDriveLocations.preflight(destination: .notChosen, bootVolume: root), .notChosen)
    }

    func testStoreAndResolveRoundTrip() throws {
        XCTAssertEqual(AppSettings.resolveExternalDriveFolder(.source), .notChosen)
        let folder = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        AppSettings.storeExternalDriveFolder(folder, role: .source)
        guard case let .resolved(url) = AppSettings.resolveExternalDriveFolder(.source) else {
            return XCTFail("Expected resolved")
        }
        XCTAssertEqual(url.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(AppSettings.resolveExternalDriveFolder(.destination), .notChosen)
    }

    func testResolveFallsBackToUnavailableWhenBookmarkIsBroken() {
        AppSettings.externalDriveDefaults.set(Data([1, 2, 3]), forKey: "externalDriveDestinationBookmark")
        AppSettings.externalDriveDefaults.set("/Volumes/MEDIA", forKey: "externalDriveDestinationPath")
        XCTAssertEqual(AppSettings.resolveExternalDriveFolder(.destination), .unavailable(path: "/Volumes/MEDIA"))
    }

    func testSuggestedPaths() {
        XCTAssertEqual(ExternalDriveFolderRole.destination.suggestedPath, "/Volumes/MEDIA")
        XCTAssertTrue(ExternalDriveFolderRole.source.suggestedPath.hasSuffix("/Pictures/_To_Homelab_Media"))
    }

    func testLogAppendsLines() throws {
        let file = root.appendingPathComponent("Logs/external-drive.log")
        let log = ExternalDriveLog(fileURL: file)
        log.append("first")
        log.append("second")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("  first"))
        XCTAssertTrue(lines[1].hasSuffix("  second"))
        XCTAssertNotNil(lines[0].range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}  "#, options: .regularExpression))
    }
}
