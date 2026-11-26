@testable import TeziovskyUtilities
import XCTest

final class PhotosCommandStateTests: XCTestCase {
    func testPhotosCommandsAreDisabledOutsidePhotosMode() {
        for route in [AppRoute.home, .drone, .localPhotos] {
            let state = PhotosCommandState(
                route: route,
                hasSelectedAlbum: true,
                hasSelectedMedia: true,
                hasMedia: true,
                canOrganizeSelectedAlbum: true,
                isOrganizing: false,
                isLoadingAlbums: false
            )
            XCTAssertFalse(state.canRefreshAlbums, "\(route)")
            XCTAssertFalse(state.canToggleThumbnails, "\(route)")
            XCTAssertFalse(state.canOrganize, "\(route)")
            XCTAssertFalse(state.canQuickLook, "\(route)")
            XCTAssertFalse(state.canSwitchAlbums, "\(route)")
        }
    }

    func testPhotosCommandsFollowTheSelectionInPhotosMode() {
        let idle = PhotosCommandState(
            route: .photos,
            hasSelectedAlbum: false,
            hasSelectedMedia: false,
            hasMedia: false,
            canOrganizeSelectedAlbum: false,
            isOrganizing: false,
            isLoadingAlbums: false
        )
        XCTAssertTrue(idle.canRefreshAlbums)
        XCTAssertTrue(idle.canSwitchAlbums)
        XCTAssertFalse(idle.canToggleThumbnails)
        XCTAssertFalse(idle.canOrganize)
        XCTAssertFalse(idle.canQuickLook)

        let busy = PhotosCommandState(
            route: .photos,
            hasSelectedAlbum: true,
            hasSelectedMedia: true,
            hasMedia: true,
            canOrganizeSelectedAlbum: true,
            isOrganizing: true,
            isLoadingAlbums: true
        )
        XCTAssertFalse(busy.canRefreshAlbums)
        XCTAssertFalse(busy.canOrganize)
        XCTAssertTrue(busy.canQuickLook)
        XCTAssertTrue(busy.canToggleThumbnails)
    }
}
