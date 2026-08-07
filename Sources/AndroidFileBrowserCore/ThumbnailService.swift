import AppKit
import CryptoKit
import Foundation
import ImageIO
import QuickLookThumbnailing

public actor ThumbnailService {
    private let cacheRoot: URL?
    private var lastCacheTouchByPath: [String: Date] = [:]

    public init(cacheRoot: URL? = nil) {
        self.cacheRoot = cacheRoot
    }

    public func sourceCacheFileName(cacheKey: String, originalName: String) -> String {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let pathExtension = (originalName as NSString).pathExtension
        return pathExtension.isEmpty ? digest : "\(digest).\(pathExtension)"
    }

    public func cachedThumbnailURL(cacheKey: String) -> URL? {
        guard let thumbnailURL = try? thumbnailURL(for: cacheKey),
              FileManager.default.fileExists(atPath: thumbnailURL.path) else {
            return nil
        }
        touchCacheFileIfNeeded(thumbnailURL)
        return thumbnailURL
    }

    public func removeCachedThumbnails(cacheKeys: Set<String>) {
        for cacheKey in cacheKeys {
            guard let thumbnailURL = try? thumbnailURL(for: cacheKey) else { continue }
            try? FileManager.default.removeItem(at: thumbnailURL)
            lastCacheTouchByPath[thumbnailURL.path] = nil
        }
    }

    public func migrateLegacyThumbnailIfAvailable(
        legacyCacheKey: String,
        cacheKey: String,
        sourceModified: Date?
    ) -> URL? {
        guard let directory = try? cacheDirectory(),
              let destination = try? thumbnailURL(for: cacheKey) else {
            return nil
        }
        let legacyName = legacyCacheKey
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let legacyURL = directory.appending(path: "\(legacyName).png")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return nil }

        if let sourceModified,
           let attributes = try? FileManager.default.attributesOfItem(atPath: legacyURL.path),
           let cachedModified = attributes[.modificationDate] as? Date,
           cachedModified < sourceModified {
            return nil
        }

        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: legacyURL, to: destination)
            }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        } catch {
            return legacyURL
        }
    }

    public func generateThumbnail(localURL: URL, cacheKey: String, size: CGSize = CGSize(width: 128, height: 128)) async throws -> URL {
        let thumbnailURL = try thumbnailURL(for: cacheKey)
        if FileManager.default.fileExists(atPath: thumbnailURL.path) {
            touchCacheFileIfNeeded(thumbnailURL)
            return thumbnailURL
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: localURL,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        let pngData: Data = try await withCheckedThrowingContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let representation {
                    guard let tiffData = representation.nsImage.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiffData),
                          let pngData = bitmap.representation(using: .png, properties: [:]) else {
                        continuation.resume(throwing: FileOperationError.commandFailed("Unable to encode thumbnail."))
                        return
                    }
                    continuation.resume(returning: pngData)
                } else {
                    continuation.resume(throwing: error ?? FileOperationError.commandFailed("Unable to generate thumbnail."))
                }
            }
        }

        try pngData.write(to: thumbnailURL, options: .atomic)
        return thumbnailURL
    }

    public func storeThumbnailImageData(_ data: Data, cacheKey: String) throws -> URL {
        let thumbnailURL = try thumbnailURL(for: cacheKey)
        if FileManager.default.fileExists(atPath: thumbnailURL.path) {
            touchCacheFileIfNeeded(thumbnailURL)
            return thumbnailURL
        }
        guard CGImageSourceCreateWithData(data as CFData, nil) != nil else {
            throw FileOperationError.commandFailed("Unable to decode the device thumbnail.")
        }
        // GetThumb already returns compressed image data. Persist it as-is instead of
        // decoding through NSImage and synchronously re-encoding it as PNG for every row.
        try data.write(to: thumbnailURL, options: .atomic)
        lastCacheTouchByPath[thumbnailURL.path] = Date()
        return thumbnailURL
    }

    private func touchCacheFileIfNeeded(_ url: URL) {
        let now = Date()
        if let lastTouch = lastCacheTouchByPath[url.path],
           now.timeIntervalSince(lastTouch) < 60 * 60 {
            return
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        lastCacheTouchByPath[url.path] = now
    }

    private func thumbnailURL(for cacheKey: String) throws -> URL {
        let directory = try cacheDirectory()
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: "\(digest).png")
    }

    private func cacheDirectory() throws -> URL {
        let root = if let cacheRoot {
            cacheRoot
        } else {
            try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let directory = root.appending(
            path: AppCacheStore.thumbnailFolderName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Decodes thumbnail files away from the main actor and keeps the resulting small
/// CGImages in memory. Views only create the inexpensive NSImage wrapper on the main actor.
actor ThumbnailImageLoader {
    static let shared = ThumbnailImageLoader()

    private let images = NSCache<NSURL, CGImage>()

    private init() {
        images.countLimit = 512
        images.totalCostLimit = 64 * 1024 * 1024
    }

    func image(at url: URL, maxPixelSize: Int = 256) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let key = url as NSURL
        if let cached = images.object(forKey: key) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard !Task.isCancelled,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
