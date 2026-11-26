import AppKit
@testable import TeziovskyUtilities
import XCTest

final class ThumbnailLoaderTests: XCTestCase {
    private var cacheRoot: URL!

    override func setUpWithError() throws {
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailLoader-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let cacheRoot {
            try? FileManager.default.removeItem(at: cacheRoot)
        }
    }

    func testSelectingAnAlbumKeepsItsThumbnailsOnDisk() async throws {
        let loader = ThumbnailLoader(cacheRoot: cacheRoot)
        let album = PhotoAlbum(
            id: "album-1", name: "Trip", mediaCount: 1, photoCount: 1, videoCount: 0,
            collectionIdentifier: "album-1"
        )
        let item = MediaItem(id: "asset/1", filename: "IMG_0001.HEIC", isVideo: false, creationDate: nil)
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let jpeg = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: await loader.diskCacheURL(album: album, itemID: item.id))

        // What AppState does every time the album is selected.
        await loader.clearMemoryCache(forAlbumID: album.id)

        let cached = await loader.thumbnail(for: item, album: album, asset: nil)
        XCTAssertNotNil(cached, "The on-disk thumbnail must survive re-selecting the album")
    }
}
