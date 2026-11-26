@testable import TeziovskyUtilities
import XCTest

@MainActor
final class SidebarSelectionTests: XCTestCase {
    func testRapidSidebarSelectionHighlightsAtOnceAndLoadsOnlyTheLastAlbum() async throws {
        let state = AppState()
        let first = album("first")
        let second = album("second")

        state.selectAlbumFromSidebar(first)
        state.selectAlbumFromSidebar(second)

        XCTAssertEqual(state.selectedAlbum?.id, "second", "The highlight follows the click immediately")
        XCTAssertTrue(state.isLoadingMedia)

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(state.selectedAlbum?.id, "second")
        XCTAssertFalse(state.isLoadingMedia, "The debounced load for the last album has run")
    }

    func testClearingTheSidebarSelectionDeselects() async throws {
        let state = AppState()
        state.selectAlbumFromSidebar(album("first"))
        state.selectAlbumFromSidebar(nil)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(state.selectedAlbum)
        XCTAssertFalse(state.isLoadingMedia)
    }

    private func album(_ id: String) -> PhotoAlbum {
        PhotoAlbum(id: id, name: id, mediaCount: 1, photoCount: 1, videoCount: 0, collectionIdentifier: id)
    }
}
