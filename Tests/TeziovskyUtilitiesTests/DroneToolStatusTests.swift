@testable import TeziovskyUtilities
import XCTest

final class DroneToolStatusTests: XCTestCase {
    private var root: URL!
    private var cli: URL { root.appendingPathComponent("HandBrakeCLI") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroneToolStatus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testAValidConfiguredPathIsUsed() {
        XCTAssertEqual(
            DroneToolPaths.handBrakeStatus(configuredPath: cli.path, candidates: []),
            .configured(cli)
        )
    }

    func testABrokenConfiguredPathIsReportedEvenWhenAutoDetectionSucceeds() {
        XCTAssertEqual(
            DroneToolPaths.handBrakeStatus(configuredPath: "/nope/HandBrakeCLI", candidates: [cli.path]),
            .autoDetected(cli, configuredPathIsInvalid: true)
        )
    }

    func testAutoDetectionWithoutAConfiguredPath() {
        XCTAssertEqual(
            DroneToolPaths.handBrakeStatus(configuredPath: "  ", candidates: ["/nope", cli.path]),
            .autoDetected(cli, configuredPathIsInvalid: false)
        )
    }

    func testNothingFound() {
        XCTAssertEqual(
            DroneToolPaths.handBrakeStatus(configuredPath: "", candidates: ["/nope"]),
            .notFound(configuredPathIsInvalid: false)
        )
    }
}
