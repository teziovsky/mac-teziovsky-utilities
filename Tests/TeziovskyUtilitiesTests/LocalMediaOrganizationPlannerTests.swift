import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import TeziovskyUtilities

final class LocalMediaOrganizationPlannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMediaOrganizationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testPlansPhotoAndVideoUnderTheirImmediateParent() throws {
        let parent = root.appendingPathComponent("Trips/Italy", isDirectory: true)
        let photo = parent.appendingPathComponent("photo.jpg")
        let video = parent.appendingPathComponent("video.mov")

        let photoItem = try XCTUnwrap(makeCandidate(photo, relativePath: "Trips/Italy/photo.jpg"))
        let videoItem = try XCTUnwrap(
            makeCandidate(video, relativePath: "Trips/Italy/video.mov", isVideo: true)
        )

        XCTAssertEqual(photoItem.destinationRelativePath, "Trips/Italy/2024/photo.jpg")
        XCTAssertEqual(videoItem.destinationRelativePath, "Trips/Italy/2024/_Filmy/video.mov")
    }

    func testSkipsFilesAlreadyInComputedDestination() {
        let photo = root.appendingPathComponent("Trips/Italy/2024/photo.jpg")
        let video = root.appendingPathComponent("Trips/Italy/2024/_Filmy/video.mov")

        XCTAssertNil(makeCandidate(photo, relativePath: "Trips/Italy/2024/photo.jpg"))
        XCTAssertNil(
            makeCandidate(
                video,
                relativePath: "Trips/Italy/2024/_Filmy/video.mov",
                isVideo: true
            )
        )
    }

    func testSkipsPhotoInsideRelatedFolderBelowMatchingYear() {
        let photo = root.appendingPathComponent(
            "_ada/2022/Koncert_Dawid_Podsiadlo/photo.jpg"
        )
        let item = LocalMediaOrganizationPlanner.makeCandidate(
            fileURL: photo,
            relativePath: "_ada/2022/Koncert_Dawid_Podsiadlo/photo.jpg",
            rootDirectory: root,
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: date(2022)),
                FileDateEvidence(source: .filesystemModification, date: date(2023))
            ],
            isVideo: false,
            now: date(2026)
        )

        XCTAssertNil(item)
    }

    func testSkipsVideoInsideNestedVideoFolderBelowMatchingYear() {
        let relativePath = "_ada/2022/Koncert Dawid Podsiadlo/_Filmy/"
            + "Video Dawid_Podsiadlo Poznan_20221.MOV"
        let video = root.appendingPathComponent(relativePath)
        let item = LocalMediaOrganizationPlanner.makeCandidate(
            fileURL: video,
            relativePath: relativePath,
            rootDirectory: root,
            evidence: [
                FileDateEvidence(source: .filesystemCreation, date: date(2022)),
                FileDateEvidence(source: .filesystemModification, date: date(2023))
            ],
            isVideo: true,
            now: date(2026)
        )

        XCTAssertNil(item)
    }

    func testPreservesRelatedFolderWhenCorrectingYear() throws {
        let photo = root.appendingPathComponent("_ada/2021/Koncert/photo.jpg")
        let item = try XCTUnwrap(
            makeCandidate(
                photo,
                relativePath: "_ada/2021/Koncert/photo.jpg",
                evidence: embeddedEvidence
            )
        )

        XCTAssertEqual(item.destinationRelativePath, "_ada/2024/Koncert/photo.jpg")
    }

    func testCorrectsWrongYearWithoutNestingYearDirectories() throws {
        let photo = root.appendingPathComponent("Trips/Italy/2021/photo.jpg")
        let video = root.appendingPathComponent("Trips/Italy/2021/_Filmy/video.mov")

        let photoItem = try XCTUnwrap(
            makeCandidate(photo, relativePath: "Trips/Italy/2021/photo.jpg", evidence: embeddedEvidence)
        )
        let videoItem = try XCTUnwrap(
            makeCandidate(
                video,
                relativePath: "Trips/Italy/2021/_Filmy/video.mov",
                isVideo: true,
                evidence: embeddedEvidence
            )
        )

        XCTAssertEqual(photoItem.destinationRelativePath, "Trips/Italy/2024/photo.jpg")
        XCTAssertEqual(videoItem.destinationRelativePath, "Trips/Italy/2024/_Filmy/video.mov")
    }

    func testMovesPhotoOutOfVideoDirectory() throws {
        let photo = root.appendingPathComponent("Trips/Italy/2024/_Filmy/photo.jpg")
        let item = try XCTUnwrap(
            makeCandidate(photo, relativePath: "Trips/Italy/2024/_Filmy/photo.jpg")
        )

        XCTAssertEqual(item.destinationRelativePath, "Trips/Italy/2024/photo.jpg")
    }

    func testUsesOldestPlausibleDateForDestinationYear() throws {
        let file = root.appendingPathComponent("photo.jpg")
        let candidate = try XCTUnwrap(
            LocalMediaOrganizationPlanner.makeCandidate(
                fileURL: file,
                relativePath: "photo.jpg",
                rootDirectory: root,
                evidence: [
                    FileDateEvidence(source: .filesystemCreation, date: date(2024)),
                    FileDateEvidence(source: .filesystemModification, date: date(2015)),
                    FileDateEvidence(source: .exifOriginal, date: date(2005))
                ],
                isVideo: false,
                now: date(2026)
            )
        )

        XCTAssertEqual(candidate.destinationRelativePath, "2005/photo.jpg")
        XCTAssertEqual(candidate.proposedSource, .exifOriginal)
    }

    func testResolvesExistingAndPlannedDestinationCollisionsDeterministically() throws {
        let destinationDirectory = root.appendingPathComponent("2024", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: destinationDirectory.appendingPathComponent("photo.jpg"))

        let first = try XCTUnwrap(makeCandidate(root.appendingPathComponent("photo.jpg"), relativePath: "photo.jpg"))
        let second = try XCTUnwrap(
            makeCandidate(
                root.appendingPathComponent("2021/photo.jpg"),
                relativePath: "2021/photo.jpg",
                evidence: embeddedEvidence
            )
        )
        let resolved = LocalMediaOrganizationPlanner.resolveCollisions(
            [first, second],
            rootDirectory: root
        )

        XCTAssertEqual(
            resolved.map(\.destinationRelativePath),
            ["2024/photo (1).jpg", "2024/photo (2).jpg"]
        )
        XCTAssertTrue(resolved.allSatisfy(\.destinationWasRenamed))
    }

    func testMoveNeverOverwritesDestinationCreatedAfterPreview() async throws {
        let source = root.appendingPathComponent("photo.jpg")
        let destination = root.appendingPathComponent("2024/photo.jpg")
        try Data("source".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("destination".utf8).write(to: destination)
        let item = LocalMediaOrganizationItem(
            sourceURL: source,
            sourceRelativePath: "photo.jpg",
            destinationURL: destination,
            destinationRelativePath: "2024/photo.jpg",
            proposedDate: date(2024),
            proposedSource: .filesystemCreation,
            isVideo: false,
            destinationWasRenamed: false,
            rootDirectory: root,
            groupsWithPhotos: false
        )

        do {
            try await LocalMediaOrganizer.move(item)
            XCTFail("Expected the move to reject an occupied destination")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: destination), Data("destination".utf8))
        }
    }

    private func makeCandidate(
        _ fileURL: URL,
        relativePath: String,
        isVideo: Bool = false,
        evidence: [FileDateEvidence]? = nil
    ) -> LocalMediaOrganizationItem? {
        LocalMediaOrganizationPlanner.makeCandidate(
            fileURL: fileURL,
            relativePath: relativePath,
            rootDirectory: root,
            evidence: evidence ?? [
                FileDateEvidence(source: .filesystemCreation, date: date(2024)),
                FileDateEvidence(source: .filesystemModification, date: date(2025))
            ],
            isVideo: isVideo,
            now: date(2026)
        )
    }

    /// A year folder only gives way to an embedded date, so year corrections need one.
    private var embeddedEvidence: [FileDateEvidence] {
        [
            FileDateEvidence(source: .exifOriginal, date: date(2024)),
            FileDateEvidence(source: .filesystemCreation, date: date(2025))
        ]
    }

    /// Mid-year, so the New Year night rule never shifts the year.
    private func date(_ year: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 7, day: 1, hour: 12))!
    }
}
