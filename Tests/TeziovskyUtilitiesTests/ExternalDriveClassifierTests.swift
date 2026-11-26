import XCTest
@testable import TeziovskyUtilities

final class ExternalDriveClassifierTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/x")

    private func output(
        _ path: String,
        conversion: LocalMediaConversionItem? = nil,
        repair: FileDateRepairItem? = nil,
        organization: LocalMediaOrganizationItem? = nil,
        outsideYear: String? = nil,
        hasUsableDate: Bool = true,
        notices: [String] = [],
        failure: String? = nil
    ) -> FileDateScanOutput {
        FileDateScanOutput(
            relativePath: path,
            conversionCandidate: conversion,
            repairItem: repair,
            organizationCandidate: organization,
            isAlreadyOrganized: false,
            hasUsableDate: hasUsableDate,
            outsideScannedFolderYear: outsideYear,
            notices: notices.map { FileDateRepairFailure(relativePath: path, message: $0) },
            failure: failure.map { FileDateRepairFailure(relativePath: path, message: $0) }
        )
    }

    private func review(
        _ outputs: [FileDateScanOutput],
        companions: [String: String] = [:],
        failures: [FileDateRepairFailure] = [],
        other: [String] = [],
        existing: Set<String> = []
    ) -> ExternalDriveReview {
        ExternalDriveClassifier.classify(
            FileDateScanOutputs(outputs: outputs, enumerationFailures: failures, livePhotoCompanions: companions),
            otherFiles: other,
            byteCount: { _ in 10 },
            existsOnDestination: { existing.contains($0) }
        )
    }

    private func single(_ out: FileDateScanOutput) -> ExternalDriveEntry {
        review([out]).entries[0]
    }

    private func organizationItem(_ destination: String) -> LocalMediaOrganizationItem {
        LocalMediaOrganizationItem(
            sourceURL: url, sourceRelativePath: "a.mov", destinationURL: url,
            destinationRelativePath: destination, proposedDate: Date(), proposedSource: .exifOriginal,
            isVideo: true, destinationWasRenamed: false, rootDirectory: url, groupsWithPhotos: false
        )
    }

    func testFailureNeedsOrganizing() {
        let entry = single(output("a.jpg", failure: "Unreadable"))
        XCTAssertEqual(entry.bucket, .needsOrganizing)
        XCTAssertEqual(entry.reason, "Unreadable")
    }

    func testConversionCandidateNeedsOrganizing() {
        let item = LocalMediaConversionItem(
            sourceURL: url, sourceRelativePath: "a.heic", destinationURL: url,
            destinationRelativePath: "a.jpg", kind: .heicToJPEG, keepOriginal: false,
            destinationWasRenamed: false
        )
        let entry = single(output("a.heic", conversion: item))
        XCTAssertEqual(entry.bucket, .needsOrganizing)
        XCTAssertEqual(entry.reason, "Conversion pending: HEIC → highest-quality JPEG")
    }

    func testRepairItemNeedsOrganizing() {
        let item = FileDateRepairItem(
            relativePath: "a.jpg", fileURL: url, currentCreationDate: Date(), proposedDate: Date(),
            proposedSource: .exifOriginal, evidence: []
        )
        let entry = single(output("a.jpg", repair: item))
        XCTAssertEqual(entry.bucket, .needsOrganizing)
        XCTAssertEqual(entry.reason, "Dates don't match")
    }

    func testOrganizationCandidateNeedsOrganizing() {
        let entry = single(output("a.mov", organization: organizationItem("2024/_Filmy/a.mov")))
        XCTAssertEqual(entry.bucket, .needsOrganizing)
        XCTAssertEqual(entry.reason, "Wrong folder (→ 2024/_Filmy)")
    }

    func testOutsideFolderYearNeedsOrganizing() {
        let entry = single(output("a.jpg", outsideYear: "2019", notices: ["Year folder unreachable"]))
        XCTAssertEqual(entry.bucket, .needsOrganizing)
        XCTAssertEqual(entry.reason, "Belongs in a “2019” folder outside the source folder")
        XCTAssertNil(entry.note)
    }

    func testNoUsableDateNeedsOrganizing() {
        let entry = single(output("a.jpg", hasUsableDate: false))
        XCTAssertEqual(entry.bucket, .needsOrganizing)
        XCTAssertEqual(entry.reason, "No usable date")
    }

    func testCleanFileIsReady() {
        let result = review([output("2024/a.jpg")])
        XCTAssertEqual(result.entries[0].bucket, .ready)
        XCTAssertNil(result.entries[0].reason)
        XCTAssertEqual(result.readyUnits, [ExternalDriveUnit(relativePaths: ["2024/a.jpg"], byteCount: 10)])
        XCTAssertEqual(result.readyByteCount, 10)
    }

    func testUnsupportedConversionNoticeDoesNotBlock() {
        let entry = single(output("2024/_Filmy/a.avi", notices: ["Cannot convert this file", "Second"]))
        XCTAssertEqual(entry.bucket, .ready)
        XCTAssertEqual(entry.note, "Cannot convert this file\nSecond")
    }

    func testFileOutsideAnyYearFolderNeedsOrganizing() {
        let entry = single(output("IMG.JPG"))
        XCTAssertEqual(entry.bucket, .needsOrganizing)
        XCTAssertEqual(entry.reason, "Not inside a year folder (choose a folder above the year folders)")
        for path in ["Wakacje/USA/IMG.JPG", "0815/IMG.JPG", "9999/IMG.JPG", "_Filmy/a.mov"] {
            XCTAssertEqual(single(output(path)).bucket, .needsOrganizing, path)
        }
    }

    func testFileInsideAYearFolderIsReady() {
        for path in ["Wakacje/USA/2024/IMG.JPG", "2024/_Filmy/a.mov", "1900/a.jpg", "2024/Trip/a.jpg"] {
            XCTAssertEqual(single(output(path)).bucket, .ready, path)
        }
    }

    func testNoUsableDateWinsOverTheYearFolderRule() {
        XCTAssertEqual(single(output("IMG.JPG", hasUsableDate: false)).reason, "No usable date")
    }

    func testLivePhotoPairMovesAsOneUnit() {
        let result = review(
            [output("2024/IMG_1.MOV"), output("2024/IMG_1.HEIC")],
            companions: ["2024/IMG_1.MOV": "2024/IMG_1.HEIC"]
        )
        XCTAssertEqual(result.readyUnits, [
            ExternalDriveUnit(relativePaths: ["2024/IMG_1.HEIC", "2024/IMG_1.MOV"], byteCount: 20)
        ])
        XCTAssertEqual(result.entries(in: .ready).count, 2)
    }

    func testLivePhotoWithNonReadyMemberHoldsBothBack() {
        let result = review(
            [output("2024/IMG_1.MOV", hasUsableDate: false), output("2024/IMG_1.HEIC")],
            companions: ["2024/IMG_1.MOV": "2024/IMG_1.HEIC"]
        )
        XCTAssertTrue(result.readyUnits.isEmpty)
        let heic = result.entries.first { $0.relativePath == "2024/IMG_1.HEIC" }
        let mov = result.entries.first { $0.relativePath == "2024/IMG_1.MOV" }
        XCTAssertEqual(heic?.bucket, .needsOrganizing)
        XCTAssertEqual(heic?.reason, "Its Live Photo pair “IMG_1.MOV” needs organizing")
        XCTAssertEqual(mov?.reason, "No usable date")
    }

    func testExistingDestinationGoesToAlreadyOnDestination() {
        let result = review([output("2024/a.jpg")], existing: ["2024/a.jpg"])
        XCTAssertEqual(result.entries[0].bucket, .alreadyOnDestination)
        XCTAssertTrue(result.readyUnits.isEmpty)
        XCTAssertEqual(result.existingUnits.map(\.relativePaths), [["2024/a.jpg"]])
    }

    func testPartlyExistingLivePhotoIsAProblem() {
        let result = review(
            [output("2024/IMG_1.MOV"), output("2024/IMG_1.HEIC")],
            companions: ["2024/IMG_1.MOV": "2024/IMG_1.HEIC"],
            existing: ["2024/IMG_1.MOV"]
        )
        XCTAssertEqual(result.entries.map(\.bucket), [.problem, .problem])
        XCTAssertEqual(result.entries[0].reason, "Part of this Live Photo is already on the drive")
        XCTAssertTrue(result.readyUnits.isEmpty)
        XCTAssertTrue(result.existingUnits.isEmpty)
    }

    func testOtherFilesAreNotMedia() {
        let result = review([], other: ["notes.txt"])
        XCTAssertEqual(result.entries.map(\.bucket), [.notMedia])
    }

    func testEnumerationFailureIsAProblem() {
        let failure = FileDateRepairFailure(relativePath: "locked", message: "Permission denied")
        let result = review([], failures: [failure])
        XCTAssertEqual(result.entries[0].bucket, .problem)
        XCTAssertEqual(result.entries[0].reason, "Permission denied")
    }

    func testEntriesSortedNaturally() {
        let result = review([output("IMG_10.jpg"), output("IMG_2.jpg")])
        XCTAssertEqual(result.entries.map(\.relativePath), ["IMG_2.jpg", "IMG_10.jpg"])
    }

    func testOtherFilesSkipsHiddenAndSupported() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [".DS_Store", "a.jpg", "notes.txt", "b.jpg.xmp"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(
            ExternalDriveClassifier.otherFiles(in: root, supportedExtensions: ["jpg"]).paths,
            ["b.jpg.xmp", "notes.txt"]
        )
    }

    func testUnreadableOtherFileIsAProblemInsteadOfDropped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [".hidden.txt", "a.jpg", "broken.txt", "notes.txt"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let unreadable: Set<String> = [".hidden.txt", "a.jpg", "broken.txt"]

        let other = ExternalDriveClassifier.otherFiles(in: root, supportedExtensions: ["jpg"]) { url, keys in
            if unreadable.contains(url.lastPathComponent) { throw CocoaError(.fileReadNoPermission) }
            return try url.resourceValues(forKeys: keys)
        }

        // Hidden files and supported media are the scanner's to report.
        XCTAssertEqual(other.paths, ["notes.txt"])
        XCTAssertEqual(other.failures.map(\.relativePath), ["broken.txt"])
        XCTAssertFalse(other.failures.first?.message.isEmpty ?? true)
    }

    func testOtherFileFailuresAreProblems() {
        let scanFailure = FileDateRepairFailure(relativePath: "locked", message: "Permission denied")
        let result = ExternalDriveClassifier.classify(
            FileDateScanOutputs(outputs: [], enumerationFailures: [scanFailure], livePhotoCompanions: [:]),
            otherFiles: [],
            otherFailures: [
                FileDateRepairFailure(relativePath: "broken.txt", message: "Couldn't read it"),
                FileDateRepairFailure(relativePath: "locked", message: "Duplicate")
            ],
            byteCount: { _ in 0 },
            existsOnDestination: { _ in false }
        )
        XCTAssertEqual(result.entries.map(\.relativePath), ["broken.txt", "locked"])
        XCTAssertEqual(result.entries.map(\.bucket), [.problem, .problem])
        XCTAssertEqual(result.entries.map(\.reason), ["Couldn't read it", "Permission denied"])
    }
}
