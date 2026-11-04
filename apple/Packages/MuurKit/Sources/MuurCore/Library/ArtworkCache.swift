import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Content-addressed artwork store. Originals live in Application Support (`AppPaths.artworkDirectory`),
/// downscaled JPEG thumbnails in Caches (`AppPaths.thumbnailDirectory`) and are regenerated on demand.
public final class ArtworkCache: @unchecked Sendable {
    /// Standard thumbnail edge lengths in pixels.
    public enum Size: Int, CaseIterable, Sendable {
        case small = 128
        case medium = 300
        case large = 600
        case widget = 400
    }

    private let originalsDirectory: URL
    private let thumbnailsDirectory: URL
    private let memory = NSCache<NSString, NSData>()
    private let colorCache = LockedValue<[String: String]>([:])
    private let fileManager = FileManager.default

    public init(paths: AppPaths) {
        self.originalsDirectory = paths.artworkDirectory
        self.thumbnailsDirectory = paths.thumbnailDirectory
        memory.totalCostLimit = 48 * 1024 * 1024
        try? fileManager.createDirectory(at: originalsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
    }

    private static let extensions = ["jpg", "png", "gif", "webp", "bmp", "heic", "img"]

    static func detectExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if bytes.starts(with: [0x42, 0x4D]) { return "bmp" }
        if bytes.count >= 12, Array(bytes[0...3]) == [0x52, 0x49, 0x46, 0x46], Array(bytes[8...11]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if bytes.count >= 12, Array(bytes[4...7]) == [0x66, 0x74, 0x79, 0x70] { return "heic" }
        return "img"
    }

    /// Stores image data and returns its key (nil for empty or undecodable data).
    @discardableResult
    public func store(_ data: Data) -> String? {
        guard data.count > 16 else { return nil }
        let key = String(Hashing.sha256Hex(data).prefix(32))
        if originalURL(for: key) != nil { return key }
        guard CGImageSourceCreateWithData(data as CFData, nil).map({ CGImageSourceGetCount($0) > 0 }) == true else { return nil }
        let url = originalsDirectory.appendingPathComponent("\(key).\(ArtworkCache.detectExtension(data))")
        do {
            try data.write(to: url, options: [.atomic])
            return key
        } catch {
            Log.library.error("Failed to store artwork: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Stores the image at `url` (e.g. a folder `cover.jpg`).
    @discardableResult
    public func store(contentsOf url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return store(data)
    }

    public func originalURL(for key: String) -> URL? {
        for ext in ArtworkCache.extensions {
            let url = originalsDirectory.appendingPathComponent("\(key).\(ext)")
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public func originalData(for key: String) -> Data? {
        originalURL(for: key).flatMap { try? Data(contentsOf: $0) }
    }

    /// URL of a JPEG thumbnail (generated if needed) whose longest edge is at most `size` pixels.
    public func thumbnailURL(for key: String, size: Int = Size.medium.rawValue) -> URL? {
        let url = thumbnailsDirectory.appendingPathComponent("\(key)_\(size).jpg")
        if fileManager.fileExists(atPath: url.path) { return url }
        guard let original = originalURL(for: key), let data = ArtworkCache.makeThumbnail(from: original, maxPixelSize: size) else {
            return nil
        }
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    public func thumbnailURL(for key: String, size: Size) -> URL? {
        thumbnailURL(for: key, size: size.rawValue)
    }

    /// Thumbnail JPEG data, memory cached.
    public func thumbnailData(for key: String, size: Int = Size.medium.rawValue) -> Data? {
        let cacheKey = "\(key)_\(size)" as NSString
        if let cached = memory.object(forKey: cacheKey) { return cached as Data }
        guard let url = thumbnailURL(for: key, size: size), let data = try? Data(contentsOf: url) else { return nil }
        memory.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        return data
    }

    /// Decoded thumbnail image.
    public func thumbnailImage(for key: String, size: Int = Size.medium.rawValue) -> CGImage? {
        guard let data = thumbnailData(for: key, size: size),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Average color of the artwork as "#RRGGBB" (used for adaptive backgrounds).
    public func averageColorHex(for key: String) -> String? {
        if let cached = colorCache.get()[key] { return cached }
        guard let image = thumbnailImage(for: key, size: Size.small.rawValue) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let hex = String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
        colorCache.mutate { $0[key] = hex }
        return hex
    }

    /// JPEG thumbnail data for an image file.
    public static func makeThumbnail(from url: URL, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return makeThumbnail(source: source, maxPixelSize: maxPixelSize)
    }

    /// JPEG thumbnail data for in-memory image data.
    public static func makeThumbnail(from data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return makeThumbnail(source: source, maxPixelSize: maxPixelSize)
    }

    private static func makeThumbnail(source: CGImageSource, maxPixelSize: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Deletes originals and thumbnails whose keys are not in `keep`.
    public func prune(keeping keep: Set<String>) {
        for directory in [originalsDirectory, thumbnailsDirectory] {
            guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for file in files {
                let base = (file as NSString).deletingPathExtension
                let key = base.components(separatedBy: "_").first ?? base
                if !keep.contains(key) {
                    try? fileManager.removeItem(at: directory.appendingPathComponent(file))
                }
            }
        }
        memory.removeAllObjects()
    }

    /// Removes all generated thumbnails (they are recreated on demand).
    public func clearThumbnails() {
        try? fileManager.removeItem(at: thumbnailsDirectory)
        try? fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        memory.removeAllObjects()
    }
}
