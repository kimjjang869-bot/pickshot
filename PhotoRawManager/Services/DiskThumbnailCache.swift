import AppKit
import CryptoKit

/// Persistent disk cache for thumbnails stored as JPEG files.
/// Cache hierarchy: Memory (ThumbnailCache) -> Disk (DiskThumbnailCache) -> Extract from file
class DiskThumbnailCache {
    static let shared = DiskThumbnailCache()

    private let cacheDir: URL
    private let lock = NSLock()
    /// v8.6.2: 하드 2GB 고정 → UserDefaults 기반 동적 cap. 0 = 무제한 (macOS isPurgeable 로 자동 관리).
    ///   Apple 공식 권장 방식 — `~/Library/Caches` 하위 + purgeable 플래그 = 디스크 부족 시 시스템이
    ///   오래된 것부터 조용히 삭제. 앱 관여 불필요.
    private var maxCacheBytes: Int64 {
        let gb = UserDefaults.standard.double(forKey: "thumbnailCacheMaxGB")
        return gb > 0 ? Int64(gb * 1_000_000_000) : 0  // 0 = 무제한
    }
    private let jpegQuality: CGFloat = 0.82

    /// 점진적 사이즈 추적 (매번 디렉토리 전체 스캔 방지)
    private var _trackedSize: Int64 = -1  // -1 = 미초기화
    private var _evictionInProgress = false
    /// 메모리 기반 LRU 추적 (디스크 setAttributes 제거)
    private var accessTime: [String: Int] = [:]  // cacheKey → accessCounter
    private var accessCounter: Int = 0

    /// Current total cache size in bytes (점진적 추적, O(1))
    var cacheSize: Int64 {
        lock.lock()
        if _trackedSize < 0 {
            _trackedSize = computeCacheSize()
        }
        let size = _trackedSize
        lock.unlock()
        return size
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

        // 파일 존재 확인만 (setAttributes LRU touch 제거 — 메모리 기반 LRU 사용)
        guard FileManager.default.fileExists(atPath: filePath.path) else { return nil }

        // LRU 추적: 메모리에서 O(1) 업데이트
        lock.lock()
        accessCounter += 1
        accessTime[key] = accessCounter
        lock.unlock()

        // v8.6.1: NSImage(contentsOf:) 는 I/O — lock 밖에서 실행.
        guard let image = NSImage(contentsOf: filePath) else {
            // Corrupt cache file — remove it (I/O, lock 불필요)
            try? FileManager.default.removeItem(at: filePath)
            return nil
        }
        return image
    }

    /// Saves thumbnail to disk cache as JPEG
    /// v8.6.1: I/O (jpeg.write) 를 lock 밖으로 이동 — 이전엔 수십 MB write 가 lock 점유하면
    /// 모든 get 이 직렬화되어 스크롤 중 스톨 발생.
    func set(url: URL, modDate: Date, image: NSImage) {
        let key = cacheKey(url: url, modDate: modDate)
        let filePath = cacheDir.appendingPathComponent(key + ".jpg")

        // v9.1.4 (T-4): 작은 픽셀 → 큰 픽셀 덮어쓰기 차단 — 파일 size 만으로 비교.
        //   이전엔 getByPath() 가 NSImage 디스크 디코드 → 픽셀 비교 (1000장 첫 sweep ~200-500ms 누적).
        //   같은 source 의 thumbnail 은 픽셀 클수록 jpeg size 도 큼 → byte 비교로 충분.
        guard let jpegData = jpegData(from: image) else { return }
        let dataSize = Int64(jpegData.count)
        if FileManager.default.fileExists(atPath: filePath.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: filePath.path),
           let existingSize = attrs[.size] as? Int64,
           existingSize > dataSize * 2 {
            // 기존 파일이 새 파일보다 2배 이상 크면 더 큰 픽셀로 추정 → skip (margin: JPEG 압축률 변동).
            plog("[DiskThumbCache] SKIP write — existing \(existingSize)B > new \(dataSize)B (×2 margin)\n")
            return
        }

        // I/O 는 lock 밖 — atomic write 자체가 OS 레벨 동기화 보장
        let writeSuccess = (try? jpegData.write(to: filePath, options: .atomic)) != nil
        guard writeSuccess else { return }
        // v8.6.2: 파일에 purgeable 플래그 설정 → macOS 가 디스크 부족 시 자동 정리 (공식 권장 방식).
        // 앱은 그대로 파일을 사용 가능, 시스템이 조용히 삭제 → 다음 접근 시 cache miss → 재생성.
        var mutableURL = filePath
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true  // iCloud/TimeMachine 백업 대상 제외
        try? mutableURL.setResourceValues(rv)
        // NSURLIsPurgeableKey 는 Foundation URLResourceKey 에 isPurgeable 로 존재하지 않아
        // setResourceValue 로 직접 세팅.
        _ = try? (mutableURL as NSURL).setResourceValue(NSNumber(value: true), forKey: .isPurgeableKey)

        // state 업데이트만 lock 안
        lock.lock()
        if _trackedSize >= 0 { _trackedSize += dataSize }
        let pathHash = pathOnlyKey(url: url)
        fileIndex[pathHash] = filePath
        // v8.6.2: maxCacheBytes == 0 이면 무제한 (macOS 가 isPurgeable 로 자동 관리 — Apple 공식 방식)
        let cap = maxCacheBytes
        let needsEviction = cap > 0 && _trackedSize > cap && !_evictionInProgress
        if needsEviction { _evictionInProgress = true }
        lock.unlock()

        if needsEviction {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.evictIfNeeded()
            }
        }
    }

    /// Delete entire cache directory
    /// v9.0: lock 분리 — I/O (외장 NAS 수백 ms) 를 lock 밖에서 수행해 다른 get()/set() 직렬화 방지.
    func clearAll() {
        lock.lock()
        accessTime.removeAll()
        fileIndex.removeAll()
        fileIndexBuilt = false
        _trackedSize = 0
        let dir = cacheDir
        lock.unlock()

        let fm = FileManager.default
        if (try? fm.removeItem(at: dir)) == nil {
            plog("[DiskCache] clearAll: removeItem 실패 \(dir.path)\n")
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Fast NAS lookup: find any cached thumbnail for this file path (ignores modDate).
    /// Returns the most recent cache entry matching the path prefix.
    /// 캐시 파일명 인덱스 — contentsOfDirectory 1번만 호출
    private var fileIndex: [String: URL] = [:]  // pathHash prefix → full URL
    private var fileIndexBuilt = false

    private func buildFileIndex() {
        guard !fileIndexBuilt else { return }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for file in files {
            let name = file.lastPathComponent
            // pathHash는 파일명의 첫 부분 (underscore 전)
            if let underscoreIdx = name.firstIndex(of: "_") {
                let prefix = String(name[name.startIndex..<underscoreIdx])
                fileIndex[prefix] = file
            } else {
                // underscore 없으면 전체 이름을 키로
                let noExt = (name as NSString).deletingPathExtension
                fileIndex[noExt] = file
            }
        }
        fileIndexBuilt = true
    }

    /// 캐시 파일 추가 시 인덱스도 업데이트
    func invalidateFileIndex() {
        lock.lock()
        fileIndexBuilt = false
        fileIndex.removeAll()
        lock.unlock()
    }

    /// v8.6.1: 사진 삭제 시 해당 디스크 캐시 파일 제거 (메모리/디스크 누수 방지).
    /// pathOnlyKey 로 인덱스 찾아 실제 파일 삭제 + 인덱스 엔트리 제거.
    func invalidate(url: URL) {
        let pathHash = pathOnlyKey(url: url)
        lock.lock()
        if let cached = fileIndex[pathHash] {
            fileIndex.removeValue(forKey: pathHash)
            lock.unlock()
            try? FileManager.default.removeItem(at: cached)
        } else {
            lock.unlock()
        }
    }

    func getByPath(url: URL) -> NSImage? {
        let pathHash = pathOnlyKey(url: url)

        lock.lock()
        buildFileIndex()
        let cachedURL = fileIndex[pathHash]
        lock.unlock()

        guard let fileURL = cachedURL else { return nil }
        return NSImage(contentsOf: fileURL)
    }

    /// v8.6.2: CacheSweeper 가 "이미 디스크 캐시에 있는지" 빠르게 확인 (디코드 없이).
    func hasThumb(for url: URL) -> Bool {
        let pathHash = pathOnlyKey(url: url)
        lock.lock()
        buildFileIndex()
        let has = fileIndex[pathHash] != nil
        lock.unlock()
        return has
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

    /// Convert NSImage to JPEG data (CGImage 직접 — TIFF 중간 단계 제거)
    private func jpegData(from image: NSImage) -> Data? {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
        }
        // fallback
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
    /// 메모리 기반 accessTime을 참조하여 최근 사용 파일은 보존
    /// v9.0: lock 점유 시간 최소화 — accessTime snapshot 만 lock 안에서, I/O 는 lock 밖.
    ///   이전엔 lock 점유한 채 enumerator + removeItem N회 → 수천장 폴더에서 수백 ms freeze.
    private func evictIfNeeded() {
        // 1) lock 안에서 accessTime snapshot + maxCacheBytes 만 읽기
        lock.lock()
        let accessSnapshot = accessTime
        let maxBytes = maxCacheBytes
        lock.unlock()

        // 2) lock 밖에서 디렉토리 스캔 (수십~수백 ms 소요)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            lock.lock(); _evictionInProgress = false; lock.unlock()
            return
        }

        struct CacheEntry {
            let url: URL
            let size: Int64
            let key: String      // 파일명에서 추출한 캐시 키
            let lastAccess: Int  // 메모리 LRU 카운터 (0 = 미접근)
        }

        var entries: [CacheEntry] = []
        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            let size = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let name = (fileURL.lastPathComponent as NSString).deletingPathExtension
            let lastAccess = accessSnapshot[name] ?? 0
            entries.append(CacheEntry(url: fileURL, size: size, key: name, lastAccess: lastAccess))
            totalSize += size
        }

        guard totalSize > maxBytes else {
            lock.lock(); _evictionInProgress = false; _trackedSize = totalSize; lock.unlock()
            return
        }

        // 메모리 LRU 카운터 오름차순 (0=미접근이 가장 먼저 삭제)
        entries.sort { $0.lastAccess < $1.lastAccess }

        // 3) lock 밖에서 removeItem 수행 — 삭제된 키 목록만 모아둠
        var evicted: Int64 = 0
        var removedKeys: [String] = []
        for entry in entries {
            guard totalSize > maxBytes else { break }
            try? fm.removeItem(at: entry.url)
            totalSize -= entry.size
            evicted += entry.size
            removedKeys.append(entry.key)
        }

        // 4) lock 안에서 상태만 업데이트
        lock.lock()
        for key in removedKeys {
            accessTime.removeValue(forKey: key)
        }
        if evicted > 0 {
            _trackedSize = totalSize
        }
        _evictionInProgress = false
        lock.unlock()
    }
}
