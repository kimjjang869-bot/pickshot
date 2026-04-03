import AppKit
import CryptoKit

/// Persistent disk cache for thumbnails stored as JPEG files.
/// Cache hierarchy: Memory (ThumbnailCache) -> Disk (DiskThumbnailCache) -> Extract from file
class DiskThumbnailCache {
    static let shared = DiskThumbnailCache()

    private let cacheDir: URL
    private let lock = NSLock()
    private let maxCacheBytes: Int64 = 2_000_000_000 // 2GB
    private let jpegQuality: CGFloat = 0.82

    /// Current total cache size in bytes
    var cacheSize: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return computeCacheSize()
    }

    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDir = cachesDir.appendingPathComponent("PickShot/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Returns cached thumbnail or nil on cache miss
    func get(url: URL, modDate: Date) -> NSImage? {
        let key = cacheKey(url: url, modDate: modDate)
        let filePath = cacheDir.appendingPathComponent(key + ".jpg")

        lock.lock()
        let exists = FileManager.default.fileExists(atPath: filePath.path)
        lock.unlock()

        guard exists else { return nil }

        // Touch access date for LRU tracking
        lock.lock()
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: filePath.path
        )
        lock.unlock()

        guard let image = NSImage(contentsOf: filePath) else {
            // Corrupt cache file — remove it
            lock.lock()
            try? FileManager.default.removeItem(at: filePath)
            lock.unlock()
            return nil
        }
        return image
    }

    /// Saves thumbnail to disk cache as JPEG
    func set(url: URL, modDate: Date, image: NSImage) {
        let key = cacheKey(url: url, modDate: modDate)
        let filePath = cacheDir.appendingPathComponent(key + ".jpg")

        guard let jpegData = jpegData(from: image) else { return }

        lock.lock()
        try? jpegData.write(to: filePath, options: .atomic)
        lock.unlock()

        // Evict if over size limit (async to not block caller)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.evictIfNeeded()
        }
    }

    /// Delete entire cache directory
    func clearAll() {
        lock.lock()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        lock.unlock()
    }

    /// Fast NAS lookup: find any cached thumbnail for this file path (ignores modDate).
    /// Returns the most recent cache entry matching the path prefix.
    func getByPath(url: URL) -> NSImage? {
        let pathHash = pathOnlyKey(url: url)
        let fm = FileManager.default

        lock.lock()
        let files = (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        lock.unlock()

        // Find any cache file matching the path-only hash prefix
        for file in files {
            if file.lastPathComponent.hasPrefix(pathHash) {
                if let image = NSImage(contentsOf: file) {
                    return image
                }
            }
        }
        return nil
    }

    // MARK: - Private

    /// SHA256 hash of file path only (for NAS fast lookup, ignoring modDate)
    private func pathOnlyKey(url: URL) -> String {
        let hash = SHA256.hash(data: Data(url.path.utf8))
        // Return first 16 chars as prefix for matching
        return hash.prefix(8).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// SHA256 hash of file path + modification date as cache key
    private func cacheKey(url: URL, modDate: Date) -> String {
        let input = url.path + "\(modDate.timeIntervalSince1970)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Convert NSImage to JPEG data
    private func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }

    /// Compute total size of all files in cache directory
    private func computeCacheSize() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// LRU eviction: remove oldest files until under maxCacheBytes
    private func evictIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        struct CacheEntry {
            let url: URL
            let size: Int64
            let modDate: Date
        }

        var entries: [CacheEntry] = []
        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let mod = values?.contentModificationDate ?? Date.distantPast
            entries.append(CacheEntry(url: fileURL, size: size, modDate: mod))
            totalSize += size
        }

        guard totalSize > maxCacheBytes else { return }

        // Sort by modification date ascending (oldest first = least recently used)
        entries.sort { $0.modDate < $1.modDate }

        for entry in entries {
            guard totalSize > maxCacheBytes else { break }
            try? fm.removeItem(at: entry.url)
            totalSize -= entry.size
        }
    }
}
