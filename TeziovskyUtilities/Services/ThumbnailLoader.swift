import AppKit
import CryptoKit
import Foundation
import Photos

actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let imageManager = PHImageManager.default()
    /// Bounded: a 10 000-item album must not keep every decoded thumbnail alive.
    private let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()
    private let requestTimeoutSeconds: UInt64 = 12
    private let maxDiskCacheBytes: Int64 = 500 * 1024 * 1024
    /// The disk cache is trimmed after this much new data, not after every single thumbnail.
    private let pruneEveryBytes: Int64 = 32 * 1024 * 1024
    private var bytesWrittenSincePrune: Int64 = .max
    private let customCacheRoot: URL?

    /// Thumbnail sizes in pixels. Each cell requests the smallest bucket covering it on the
    /// current display, so large cells on Retina stay sharp and small cells stay cheap.
    nonisolated static let pixelBuckets = [256, 512, 1024, 2048]

    nonisolated static func pixelBucket(forPoints points: CGFloat, scale: CGFloat) -> Int {
        let needed = Int((points * max(scale, 1)).rounded(.up))
        return pixelBuckets.first { $0 >= needed } ?? pixelBuckets[pixelBuckets.count - 1]
    }

    init(cacheRoot: URL? = nil) {
        customCacheRoot = cacheRoot
    }

    private var cacheRoot: URL {
        if let customCacheRoot { return customCacheRoot }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TeziovskyUtilities/Thumbnails", isDirectory: true)
    }

    func cachedImage(for itemID: String, pixelSize: Int = 512) -> NSImage? {
        memoryCache.object(forKey: Self.cacheKey(itemID, pixelSize) as NSString)
    }

    func thumbnail(for item: MediaItem, album: PhotoAlbum, asset: PHAsset?, pixelSize: Int = 512) async -> NSImage? {
        let key = Self.cacheKey(item.id, pixelSize)
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        let diskPath = diskCacheURL(album: album, itemID: item.id, pixelSize: pixelSize)
        if FileManager.default.fileExists(atPath: diskPath.path),
           let image = NSImage(contentsOf: diskPath) {
            remember(image, for: key)
            return image
        }

        guard let asset else { return nil }

        let image = await requestImage(for: asset, pixelSize: pixelSize)
        guard let image, !Task.isCancelled else { return image }

        remember(image, for: key)
        if let written = try? saveToDisk(image: image, url: diskPath) {
            bytesWrittenSincePrune = bytesWrittenSincePrune == .max ? written : bytesWrittenSincePrune + written
        }
        if bytesWrittenSincePrune >= pruneEveryBytes {
            bytesWrittenSincePrune = 0
            await pruneDiskCacheIfNeeded()
        }
        return image
    }

    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    /// Called when an album is selected. Only frees memory: the album's disk cache is what
    /// makes re-opening it fast, so it is kept.
    func clearMemoryCache(forAlbumID albumID: String) {
        memoryCache.removeAllObjects()
    }

    private func remember(_ image: NSImage, for itemID: String) {
        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        let cost = max(pixels, Int(image.size.width * image.size.height)) * 4
        memoryCache.setObject(image, forKey: itemID as NSString, cost: cost)
    }

    private static func cacheKey(_ itemID: String, _ pixelSize: Int) -> String {
        "\(itemID)@\(pixelSize)"
    }

    private func requestImage(for asset: PHAsset, pixelSize: Int) async -> NSImage? {
        let request = ImageRequest(imageManager: imageManager)
        let timeout = requestTimeoutSeconds
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(continuation)
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true
                options.isSynchronous = false

                let requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: pixelSize, height: pixelSize),
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool) == true {
                        request.finish(nil)
                        return
                    }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) ?? false { return }
                    request.finish(image)
                }
                request.attach(requestID: requestID, timeoutSeconds: timeout)
            }
        } onCancel: {
            // The grid cell scrolled away: stop the PhotoKit request instead of finishing it.
            request.cancel()
        }
    }

    func diskCacheURL(album: PhotoAlbum, itemID: String, pixelSize: Int = 512) -> URL {
        let albumHash = SHA256.hash(data: Data(album.id.utf8)).compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        let safeItemID = itemID.replacingOccurrences(of: "/", with: "_")
        let dir = cacheRoot.appendingPathComponent(String(albumHash), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(safeItemID)@\(pixelSize).jpg")
    }

    private func pruneDiskCacheIfNeeded() async {
        let root = cacheRoot
        let cacheLimit = maxDiskCacheBytes
        let files: [(url: URL, size: Int64, date: Date)] = await Task.detached {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var collected: [(url: URL, size: Int64, date: Date)] = []
            var total: Int64 = 0
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "jpg" else { continue }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                let date = values?.contentModificationDate ?? .distantPast
                collected.append((url, size, date))
                total += size
            }
            guard total > cacheLimit else { return [] }
            return collected
        }.value

        guard !files.isEmpty else { return }

        var sorted = files
        sorted.sort { $0.date < $1.date }
        var removed: Int64 = 0
        let target = files.reduce(0) { $0 + $1.size } - cacheLimit / 2
        for file in sorted {
            guard removed < target else { break }
            try? FileManager.default.removeItem(at: file.url)
            removed += file.size
        }
    }

    /// Writes the thumbnail and returns the number of bytes written.
    private func saveToDisk(image: NSImage, url: URL) throws -> Int64 {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return 0
        }
        try jpeg.write(to: url)
        return Int64(jpeg.count)
    }
}

/// One PhotoKit image request whose continuation is resumed exactly once, whether it
/// finishes, times out or is cancelled (these arrive on different threads).
private final class ImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let imageManager: PHImageManager
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var requestID: PHImageRequestID?
    private var timeoutTask: Task<Void, Never>?
    private var isCancelled = false

    init(imageManager: PHImageManager) {
        self.imageManager = imageManager
    }

    func start(_ continuation: CheckedContinuation<NSImage?, Never>) {
        lock.lock()
        let cancelledEarly = isCancelled
        if !cancelledEarly { self.continuation = continuation }
        lock.unlock()
        if cancelledEarly { continuation.resume(returning: nil) }
    }

    func attach(requestID: PHImageRequestID, timeoutSeconds: UInt64) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isCancelled
        // PhotoKit may already have answered synchronously from its cache.
        if !shouldCancel, continuation != nil {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.cancel()
            }
        }
        lock.unlock()
        if shouldCancel { imageManager.cancelImageRequest(requestID) }
    }

    func finish(_ image: NSImage?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let timeout = timeoutTask
        timeoutTask = nil
        lock.unlock()
        timeout?.cancel()
        pending?.resume(returning: image)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let id = requestID
        lock.unlock()
        if let id { imageManager.cancelImageRequest(id) }
        finish(nil)
    }
}
