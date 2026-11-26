@testable import TeziovskyUtilities
import XCTest

@MainActor
final class LocalMediaTreeTests: XCTestCase {
    private let paths = [
        "Imprezy/Festiwale/Audioriver/2023/a.jpg",
        "Imprezy/Festiwale/Audioriver/2023/b.jpg",
        "Imprezy/Warszawa/DUEL/2022/c.jpg",
        "root.jpg"
    ]

    func testRowsGroupFilesUnderCompressedFolders() {
        let rows = LocalMediaTree.rows(paths: paths, collapsed: [])
        let kinds = rows.map(\.kind)
        XCTAssertEqual(kinds.count, 7)
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 2, 1, 2, 0])
        guard case let .folder(path0, title0, filePaths0) = kinds[0] else { return XCTFail("row 0") }
        XCTAssertEqual(title0, "Imprezy")
        XCTAssertEqual(path0, "Imprezy")
        XCTAssertEqual(filePaths0.count, 3)
        guard case let .folder(path1, title1, files1) = kinds[1] else { return XCTFail("row 1") }
        XCTAssertEqual(title1, "Festiwale/Audioriver/2023")
        XCTAssertEqual(path1, "Imprezy/Festiwale/Audioriver/2023")
        XCTAssertEqual(files1, [paths[0], paths[1]])
        XCTAssertEqual(kinds[2], .file(index: 0))
        XCTAssertEqual(kinds[3], .file(index: 1))
        guard case let .folder(_, title4, _) = kinds[4] else { return XCTFail("row 4") }
        XCTAssertEqual(title4, "Warszawa/DUEL/2022")
        XCTAssertEqual(kinds[5], .file(index: 2))
        XCTAssertEqual(kinds[6], .file(index: 3))
        XCTAssertEqual(rows[2].id, "f:" + paths[0])
        XCTAssertEqual(rows[0].id, "d:Imprezy")
    }

    func testCollapsedFolderHidesDescendants() {
        let rows = LocalMediaTree.rows(paths: paths, collapsed: ["Imprezy"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, "d:Imprezy")
        XCTAssertEqual(rows[1].kind, .file(index: 3))
    }

    func testFolderSelectionStates() {
        let service = LocalPhotosService()
        let files = Array(paths.prefix(3))
        XCTAssertEqual(service.selection(of: files, in: .organization), .all)
        XCTAssertEqual(service.selection(of: [], in: .organization), .all)
        service.setExcluded(true, path: files[0], in: .organization)
        XCTAssertEqual(service.selection(of: files, in: .organization), .some)
        service.setExcluded(true, paths: files, in: .organization)
        XCTAssertEqual(service.selection(of: files, in: .organization), .none)
        service.setExcluded(false, paths: files, in: .organization)
        XCTAssertEqual(service.selection(of: files, in: .organization), .all)
    }

    func testFolderToggleAffectsOnlyVisiblePaths() {
        let service = LocalPhotosService()
        let visible = Array(paths.prefix(1))
        let rows = LocalMediaTree.rows(paths: visible, collapsed: [])
        guard case let .folder(_, _, filePaths) = rows[0].kind else { return XCTFail("folder") }
        service.setExcluded(true, paths: filePaths, in: .organization)
        XCTAssertTrue(service.isExcluded(path: paths[0], in: .organization))
        XCTAssertFalse(service.isExcluded(path: paths[1], in: .organization))
        XCTAssertFalse(service.isExcluded(path: paths[2], in: .organization))
    }
}
