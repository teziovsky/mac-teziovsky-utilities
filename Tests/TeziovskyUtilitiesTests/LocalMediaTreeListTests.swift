@testable import TeziovskyUtilities
import XCTest

final class LocalMediaTreeListTests: XCTestCase {
    private func paths(_ count: Int, in folder: String) -> [String] {
        (0..<count).map { "\(folder)/f\($0).jpg" }
    }

    func testAllRowsShownWhenFileRowsFitTheLimit() {
        let rows = LocalMediaTree.rows(paths: paths(2, in: "A") + paths(2, in: "B"), collapsed: ["B"])
        let limited = LocalMediaTree.limitedRows(rows, fileLimit: 2)
        XCTAssertEqual(limited.rows.map(\.id), rows.map(\.id))
        XCTAssertFalse(limited.isTruncated)
    }

    func testHeadersDoNotCountTowardsTheLimit() {
        let rows = LocalMediaTree.rows(paths: paths(2, in: "A") + paths(2, in: "B"), collapsed: [])
        let limited = LocalMediaTree.limitedRows(rows, fileLimit: 3)
        XCTAssertEqual(limited.rows.map(\.id), ["d:A", "f:A/f0.jpg", "f:A/f1.jpg", "d:B", "f:B/f0.jpg"])
        XCTAssertTrue(limited.isTruncated)
    }

    func testStopsRightAfterTheLastAllowedFileRow() {
        let rows = LocalMediaTree.rows(paths: paths(2, in: "A") + paths(2, in: "B"), collapsed: [])
        let limited = LocalMediaTree.limitedRows(rows, fileLimit: 2)
        XCTAssertEqual(limited.rows.map(\.id), ["d:A", "f:A/f0.jpg", "f:A/f1.jpg"])
        XCTAssertTrue(limited.isTruncated)
    }

    func testClickingFolderCheckboxIncludesUnlessAllIncluded() {
        XCTAssertTrue(LocalMediaFolderSelection.all.excludesOnClick)
        XCTAssertFalse(LocalMediaFolderSelection.some.excludesOnClick)
        XCTAssertFalse(LocalMediaFolderSelection.none.excludesOnClick)
    }

    func testFolderCheckboxSymbolsAndHelp() {
        XCTAssertEqual(LocalMediaFolderSelection.all.checkboxSymbol, "checkmark.square.fill")
        XCTAssertEqual(LocalMediaFolderSelection.some.checkboxSymbol, "minus.square.fill")
        XCTAssertEqual(LocalMediaFolderSelection.none.checkboxSymbol, "square")
        XCTAssertEqual(LocalMediaFolderSelection.all.checkboxHelp, "Exclude all files in this folder")
        XCTAssertEqual(LocalMediaFolderSelection.some.checkboxHelp, "Include all files in this folder")
        XCTAssertEqual(LocalMediaFolderSelection.none.checkboxHelp, "Include all files in this folder")
    }

    func testFolderCheckboxAccessibilityLabelNamesTheAction() {
        XCTAssertEqual(LocalMediaFolderSelection.all.checkboxAccessibilityLabel(folder: "2019"), "Exclude all files in 2019")
        XCTAssertEqual(LocalMediaFolderSelection.some.checkboxAccessibilityLabel(folder: "2019"), "Include all files in 2019")
        XCTAssertEqual(LocalMediaFolderSelection.none.checkboxAccessibilityLabel(folder: "2019"), "Include all files in 2019")
    }

    func testOrganizationSummaryMentionsKeptFiles() {
        XCTAssertEqual(
            LocalMediaKeptSection.previewSummary(moves: 5, scanned: 40, alreadyOrganized: 20, kept: 0),
            "5 moves planned from 40 supported media files · 20 already organized."
        )
        XCTAssertEqual(
            LocalMediaKeptSection.previewSummary(moves: 5, scanned: 40, alreadyOrganized: 20, kept: 12),
            "5 moves planned from 40 supported media files · 20 already organized · 12 kept in their year folder."
        )
    }
}
