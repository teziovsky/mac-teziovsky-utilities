@testable import TeziovskyUtilities
import XCTest

final class MediaItemPresentationTests: XCTestCase {
    func testVideoDurationBadgeText() {
        XCTAssertEqual(item(duration: 7).durationText, "0:07")
        XCTAssertEqual(item(duration: 83.4).durationText, "1:23")
        XCTAssertEqual(item(duration: 3_725).durationText, "1:02:05")
    }

    func testNoBadgeWithoutAUsableDuration() {
        XCTAssertNil(item(duration: nil).durationText)
        XCTAssertNil(item(duration: 0).durationText)
        XCTAssertNil(item(duration: .nan).durationText)
    }

    private func item(duration: TimeInterval?) -> MediaItem {
        MediaItem(id: "1", filename: "clip.mov", isVideo: true, creationDate: nil, duration: duration)
    }
}
