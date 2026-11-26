import Photos
@testable import TeziovskyUtilities
import XCTest

final class DestinationAlbumTitleTests: XCTestCase {
    func testBlankSuffixMeansThereIsNoDestinationAlbum() {
        XCTAssertNil(PhotosService.destinationAlbumTitle(forSourceAlbumNamed: "Wakacje", suffix: ""))
        XCTAssertNil(PhotosService.destinationAlbumTitle(forSourceAlbumNamed: "Wakacje", suffix: "  "))
        XCTAssertEqual(
            PhotosService.destinationAlbumTitle(forSourceAlbumNamed: "Wakacje", suffix: " _zgrane "),
            "Wakacje_zgrane"
        )
    }
}

final class ExportedFileMarkerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportedFileMarker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testFindsTheEarlierExportOfTheSameAssetAmongNumberedNames() throws {
        let other = directory.appendingPathComponent("IMG_0001.HEIC")
        let earlier = directory.appendingPathComponent("IMG_0001 (1).HEIC")
        try Data("a".utf8).write(to: other)
        try Data("b".utf8).write(to: earlier)
        PhotoAssetExporter.markExported(other, assetIdentifier: "OTHER/L0/001")
        PhotoAssetExporter.markExported(earlier, assetIdentifier: "ASSET/L0/001")

        let found = PhotoAssetExporter.existingExport(
            ofAssetIdentifier: "ASSET/L0/001",
            filename: "IMG_0001.HEIC",
            in: directory
        )

        XCTAssertEqual(found?.lastPathComponent, "IMG_0001 (1).HEIC")
    }

    func testUnmarkedFilesWithTheSameNameAreNotMistakenForAnEarlierExport() throws {
        try Data("a".utf8).write(to: directory.appendingPathComponent("IMG_0001.HEIC"))

        XCTAssertNil(PhotoAssetExporter.existingExport(
            ofAssetIdentifier: "ASSET/L0/001",
            filename: "IMG_0001.HEIC",
            in: directory
        ))
    }
}

final class ICloudErrorClassificationTests: XCTestCase {
    func testRecognisesPhotoKitNetworkErrorsWithoutReadingTheMessage() {
        let error = NSError(
            domain: PHPhotosErrorDomain,
            code: PHPhotosError.networkAccessRequired.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Nie można pobrać zasobu."]
        )

        XCTAssertTrue(PhotoAssetExporter.isICloudDownloadFailure(error))
    }

    func testRecognisesAnUnderlyingNetworkError() {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let error = NSError(
            domain: "SomeWrapperDomain",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: "Operacja nie powiodła się."]
        )

        XCTAssertTrue(PhotoAssetExporter.isICloudDownloadFailure(error))
    }

    func testOtherErrorsAreNotICloudFailures() {
        XCTAssertFalse(PhotoAssetExporter.isICloudDownloadFailure(CocoaError(.fileWriteOutOfSpace) as NSError))
    }
}

final class ExportDirectoryResolutionTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportDirectoryResolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base {
            try? FileManager.default.removeItem(at: base)
        }
    }

    func testFollowsTheChosenFolderWhenItIsMovedAndRemembersItsNewPath() throws {
        let chosen = base.appendingPathComponent("Export", isDirectory: true)
        let movedTo = base.appendingPathComponent("Export moved", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        AppSettings.setExportDirectory(chosen)
        try FileManager.default.moveItem(at: chosen, to: movedTo)

        let resolved = try XCTUnwrap(AppSettings.resolveExportDirectory())

        let expected = movedTo.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(resolved.standardizedFileURL.resolvingSymlinksInPath().path, expected)
        XCTAssertEqual(
            AppSettings.exportDirectoryPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            expected
        )
    }
}
