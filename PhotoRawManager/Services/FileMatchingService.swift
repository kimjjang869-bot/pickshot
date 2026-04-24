import Foundation
import UniformTypeIdentifiers
import AVFoundation
import AppKit

struct FileMatchingService {
    static let jpgExtensions: Set<String> = ["jpg", "jpeg"]
    static let imageExtensions: Set<String> = [
        "png",                      // PNG
        "heic", "heif",             // Apple HEIC/HEIF
        "psd",                      // Adobe Photoshop
        "tif", "tiff",              // TIFF
        "bmp",                      // BMP
        "gif",                      // GIF
        "webp",                     // WebP (macOS 14+)
        "avif",                     // AVIF (AV1 기반 차세대 포맷)
        "jxl",                      // JPEG XL (차세대 JPEG)
        "jp2", "j2k", "jpx",       // JPEG 2000
        "tga",                      // Truevision TGA
        "exr",                      // OpenEXR (HDR)
        "ico",                      // Windows Icon
        "icns",                     // macOS Icon
        "sgi",                      // Silicon Graphics
        "pbm", "pgm", "ppm",       // Netpbm
        "dds",                      // DirectDraw Surface
        "ktx", "ktx2",             // Khronos Texture
        "astc",                     // Adaptive Scalable Texture Compression
        "hdr",                      // Radiance HDR
    ]

    /// 모든 지원 이미지 확장자 (JPG + RAW + Image + Video)
    static let allImageExtensions: Set<String> = jpgExtensions
        .union(rawExtensions)
        .union(imageExtensions)

    static let allMediaExtensions: Set<String> = allImageExtensions
        .union(videoExtensions)
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "avi", "m4v"  // Video files
    ]
    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw",       // Canon
        "arw", "sr2", "srf",       // Sony
        "nef", "nrw",              // Nikon (NEF + Coolpix NRW)
        "raf",                      // Fujifilm
        "dng",                      // Adobe DNG
        "orf", "ori",               // Olympus/OM System
        "rw2", "rwl",               // Panasonic / Leica
        "pef",                      // Pentax
        "srw",                      // Samsung
        "3fr", "fff",               // Hasselblad
        "iiq",                      // Phase One
        "mos",                      // Leaf
        "erf",                      // Epson
        "kdc", "dcr",               // Kodak
        "rwz",                      // Rawzor
        "x3f",                      // Sigma
        "gpr",                      // GoPro
    ]

    /// Classifies a file URL using UTType for accurate type detection.
    /// Falls back to extension-based matching if UTType cannot determine the type.
    private static func classifyFile(_ fileURL: URL) -> FileCategory {
        let ext = fileURL.pathExtension.lowercased()

        // Check video first (UTType won't help distinguish our intent)
        if videoExtensions.contains(ext) { return .video }

        // Try UTType-based detection first
        if let utType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if utType.conforms(to: .jpeg) {
                return .jpg
            }
            if utType.conforms(to: .rawImage) {
                return .raw
            }
            // Check DNG specifically (conforms to both rawImage and public.camera-raw-image)
            if utType.conforms(to: UTType("com.adobe.raw-image") ?? .rawImage) {
                return .raw
            }
            // HEIC, PSD, TIFF conform to UTType.image
            if utType.conforms(to: .image) && imageExtensions.contains(ext) {
                return .image
            }
        }

        // Fallback to extension-based matching for edge cases
        if jpgExtensions.contains(ext) { return .jpg }
        if rawExtensions.contains(ext) { return .raw }
        if imageExtensions.contains(ext) { return .image }

        return .other
    }

    private enum FileCategory {
        case jpg, raw, image, video, other
    }

    /// 외부(드래그앤드롭 등)에서 가져올 수 있는 파일인지 판별. 이미지/RAW/비디오만 true.
    static func isImportableFile(_ url: URL) -> Bool {
        switch classifyFile(url) {
        case .jpg, .raw, .image, .video: return true
        case .other: return false
        }
    }

    /// Generate a thumbnail from the first frame of a video file
    static func generateVideoThumbnail(url: URL) -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }

    /// Extract video duration in seconds (lightweight, no full decode)
    static func videoDuration(url: URL) -> Double? {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let dur = asset.duration
        guard dur.isNumeric, dur != .zero else { return nil }
        let seconds = CMTimeGetSeconds(dur)
        return seconds > 0 ? seconds : nil
    }

    /// v8.7: 파일명에서 "번호" 추출 (마지막 숫자 블록)
    ///   - "IMG_1234" → 1234
    ///   - "IMG_1234_LR" → 1234
    ///   - "DSC-5678-edit" → 5678
    ///   - "IMG_1234_crop_v2" → 2 (마지막 숫자) — 편집 버전 구분 안 되는 케이스
    /// 매칭의 정확도는 촬영기 파일명 관례에 의존. 대부분 `PREFIX_NNNN[suffix]` 구조.
    static func extractTrailingNumber(from baseName: String) -> Int? {
        let lower = baseName.lowercased()
        // 뒤에서부터 탐색하되, 편집 접미사 (_lr, _edit, -crop 등) 는 스킵하고 그 앞 숫자 찾기
        // 간단 휴리스틱: 뒤에서 숫자 시작점을 찾되, non-digit 이 나오면 일단 스톱.
        //   숫자 블록이 여러 개면 가장 오른쪽 "길이 3+" 숫자 채택 (짧은 version suffix 필터링)
        var blocks: [(range: Range<String.Index>, value: Int)] = []
        var idx = lower.startIndex
        while idx < lower.endIndex {
            if lower[idx].isNumber {
                let start = idx
                var end = idx
                while end < lower.endIndex, lower[end].isNumber {
                    end = lower.index(after: end)
                }
                if let n = Int(lower[start..<end]) {
                    blocks.append((start..<end, n))
                }
                idx = end
            } else {
                idx = lower.index(after: idx)
            }
        }
        // 길이 3+ 블록 중 가장 오른쪽 (일반적 파일번호 특성)
        if let best = blocks.reversed().first(where: {
            lower.distance(from: $0.range.lowerBound, to: $0.range.upperBound) >= 3
        }) {
            return best.value
        }
        // fallback: 마지막 숫자 블록
        return blocks.last?.value
    }

    /// v8.6.3: 스트리밍 + 병렬 스캔.
    /// 최상위 서브폴더를 동시에 스캔하고, 배치 단위로 `onBatch` 콜백을 main thread 에서 호출.
    /// 카메라 3대 시나리오 (3 subfolders × 2000장 = 6000장) 에서 첫 배치 ~200ms 내 UI 업데이트 → 체감 3~5배 향상.
    /// - Parameters:
    ///   - folderURL: 루트 폴더
    ///   - recursive: true 면 하위폴더까지 포함
    ///   - isSlowDisk: HDD/NAS 등 슬로우 디스크면 병렬도 낮춤 (head thrashing 방지)
    ///   - onBatch: 새 배치 발생 시 (main thread)
    ///   - onComplete: 모든 스캔 완료 시 총 장수 (main thread)
    static func scanAndMatchStreaming(
        folderURL: URL,
        recursive: Bool,
        isSlowDisk: Bool = false,
        // v8.9.4: cancel token — 새 recursive scan 시작 시 옛 batch callback 차단
        isCancelled: @escaping () -> Bool = { false },
        onBatch: @escaping ([PhotoItem]) -> Void,
        onComplete: @escaping (Int) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let overallStart = CFAbsoluteTimeGetCurrent()

            if !recursive {
                let items = scanAndMatch(folderURL: folderURL, recursive: false)
                DispatchQueue.main.async {
                    guard !isCancelled() else { onComplete(0); return }
                    if !items.isEmpty { onBatch(items) }
                    onComplete(items.filter { !$0.isFolder && !$0.isParentFolder }.count)
                }
                return
            }

            let fm = FileManager.default
            let topChildren = (try? fm.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let topFolders = topChildren.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            // v8.9.4: batch coalescing — 250ms 또는 300개마다 flush.
            //   기존엔 서브폴더마다 즉시 main async → photosVersion bump 폭주 → reloadData 폭주.
            //   v8.9.4-fix: collectorQueue 의 timer event handler 안에서 collectorQueue.sync 를 호출하면
            //               dispatch_sync deadlock crash → _doFlush 는 항상 collectorQueue 위에서 실행되는
            //               것을 전제로 호출자가 책임지고 dispatch.async 로 진입.
            let collectorQueue = DispatchQueue(label: "com.pickshot.scan.collector")
            // 클로저 내 mutable 캡처를 위해 class 박스 사용 (Swift @Sendable 위반 회피)
            final class CollectorState {
                var pendingBatch: [PhotoItem] = []
                var lastFlushAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
                var totalCount: Int = 0
            }
            let state = CollectorState()
            let flushIntervalMs: Double = 250
            let flushSizeThreshold = 300

            // 항상 collectorQueue 위에서만 호출.
            func _doFlushOnQueue(force: Bool) {
                let now = CFAbsoluteTimeGetCurrent()
                let elapsedMs = (now - state.lastFlushAt) * 1000
                let shouldFlush = force
                    || state.pendingBatch.count >= flushSizeThreshold
                    || (state.pendingBatch.count > 0 && elapsedMs >= flushIntervalMs)
                if shouldFlush && !state.pendingBatch.isEmpty {
                    let batch = state.pendingBatch
                    state.pendingBatch.removeAll(keepingCapacity: true)
                    state.lastFlushAt = now
                    DispatchQueue.main.async {
                        guard !isCancelled() else { return }
                        onBatch(batch)
                    }
                }
            }

            // 외부 (scan worker) 에서 호출 — async 로 큐에 넣기만 함
            func appendItems(_ items: [PhotoItem]) {
                collectorQueue.async {
                    state.pendingBatch.append(contentsOf: items)
                    state.totalCount += items.count
                    _doFlushOnQueue(force: false)
                }
            }

            // 1) 최상위 파일 먼저
            if isCancelled() { DispatchQueue.main.async { onComplete(0) }; return }
            let topLevelOnly = scanAndMatch(folderURL: folderURL, recursive: false)
                .filter { !$0.isFolder && !$0.isParentFolder }
            if !topLevelOnly.isEmpty {
                appendItems(topLevelOnly)
            }

            // 2) 서브폴더 병렬 스캔 — v8.9.4: SSD 4 → 2 보수화 (file-system contention 감소)
            //   - SSD: 2
            //   - HDD/NAS/SD: 1
            let maxConcurrent = isSlowDisk ? 1 : min(max(topFolders.count, 1), 2)
            let semaphore = DispatchSemaphore(value: maxConcurrent)
            let group = DispatchGroup()
            let scanQueue = DispatchQueue(label: "com.pickshot.scan.parallel", qos: .userInitiated, attributes: .concurrent)

            fputs("[SCAN] subfolders=\(topFolders.count) parallel=\(maxConcurrent) slow=\(isSlowDisk)\n", stderr)

            for sub in topFolders {
                if isCancelled() { break }
                group.enter()
                scanQueue.async {
                    semaphore.wait()
                    let subStart = CFAbsoluteTimeGetCurrent()
                    defer {
                        let elapsed = (CFAbsoluteTimeGetCurrent() - subStart) * 1000
                        // 5초 이상 걸린 서브폴더는 stall 후보 — 로그 남김
                        if elapsed > 5000 {
                            fputs("[SCAN] SLOW subfolder \(sub.lastPathComponent) took \(Int(elapsed))ms\n", stderr)
                        }
                        semaphore.signal()
                        group.leave()
                    }
                    if isCancelled() { return }
                    let subItems = scanAndMatch(folderURL: sub, recursive: true)
                        .filter { !$0.isFolder && !$0.isParentFolder }
                    if !subItems.isEmpty && !isCancelled() {
                        appendItems(subItems)
                    }
                }
            }

            // 주기 flush — coalescing 사이에 시간이 비면 강제 flush 보장
            // Timer event handler 는 collectorQueue 위에서 실행되므로 _doFlushOnQueue 직접 호출 (sync 금지!).
            let flushTimer = DispatchSource.makeTimerSource(queue: collectorQueue)
            flushTimer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            flushTimer.setEventHandler {
                if !isCancelled() { _doFlushOnQueue(force: false) }
            }
            flushTimer.resume()

            group.notify(queue: .main) {
                flushTimer.cancel()
                // 마지막 잔여 flush + totalCount 회수 — collectorQueue 에 async 로 진입
                collectorQueue.async {
                    _doFlushOnQueue(force: true)
                    let final = state.totalCount
                    DispatchQueue.main.async {
                        let elapsed = (CFAbsoluteTimeGetCurrent() - overallStart) * 1000
                        fputs("[SCAN] streaming total \(final) photos in \(Int(elapsed))ms (parallel=\(maxConcurrent))\n", stderr)
                        onComplete(isCancelled() ? 0 : final)
                    }
                }
            }
        }
    }

    /// Scans a folder and its subdirectories for JPG/RAW/image/video files and matches them by filename.
    /// Uses UTType for accurate file type detection with extension-based fallback.
    /// Supports structures like:
    ///   - All files in one folder
    ///   - Separate jpg/ and raw/ subfolders
    ///   - Any nested structure
    static func scanAndMatch(folderURL: URL, recursive: Bool = false) -> [PhotoItem] {
        let fileManager = FileManager.default

        // Only scan current folder (not subfolders) for speed
        var enumOptions: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !recursive {
            enumOptions.insert(.skipsSubdirectoryDescendants)
        }
        // 파일 크기/날짜를 enumerator에서 한번에 가져와 stat() 중복 제거
        let prefetchKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(prefetchKeys),
            options: enumOptions
        ) else {
            return []
        }

        struct FileInfo {
            let url: URL
            let size: Int64
            let modDate: Date
        }

        var jpgFiles: [String: FileInfo] = [:]
        var rawFiles: [String: FileInfo] = [:]
        var imageFiles: [String: FileInfo] = [:]
        var videoFiles: [String: FileInfo] = [:]
        var otherFiles: [String: URL] = [:]

        while let fileURL = enumerator.nextObject() as? URL {
            guard let rv = try? fileURL.resourceValues(forKeys: prefetchKeys),
                  rv.isRegularFile == true else { continue }

            let baseName = fileURL.deletingPathExtension().lastPathComponent.lowercased()
            let info = FileInfo(
                url: fileURL,
                size: Int64(rv.fileSize ?? 0),
                modDate: rv.contentModificationDate ?? .distantPast
            )

            switch classifyFile(fileURL) {
            case .jpg:   jpgFiles[baseName] = info
            case .raw:   rawFiles[baseName] = info
            case .image: imageFiles[baseName] = info
            case .video: videoFiles[baseName] = info
            case .other: otherFiles[baseName] = fileURL
            }
        }

        // Add subfolders as folder items in the grid (no recursive scanning)
        let subFolders = (try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []

        // v8.7: 파일번호 기반 매칭 (옵션) — _LR, -edit 같은 접미사 자동 무시
        //   설정 UserDefaults "matchByFileNumber" = true 일 때 활성
        let useNumberMatching = UserDefaults.standard.bool(forKey: "matchByFileNumber")
        // 번호 → FileInfo 인덱스 (충돌 시 먼저 나온 것 유지)
        var jpgByNumber: [Int: FileInfo] = [:]
        var rawByNumber: [Int: FileInfo] = [:]
        if useNumberMatching {
            for (base, info) in jpgFiles {
                if let num = extractTrailingNumber(from: base), jpgByNumber[num] == nil {
                    jpgByNumber[num] = info
                }
            }
            for (base, info) in rawFiles {
                if let num = extractTrailingNumber(from: base), rawByNumber[num] == nil {
                    rawByNumber[num] = info
                }
            }
        }

        /// JPG 엔트리와 매칭되는 RAW 찾기 — 정확 매칭 먼저, 없으면 번호 매칭
        func pairedRAW(forJPGBase jpgBase: String) -> FileInfo? {
            if let exact = rawFiles[jpgBase] { return exact }
            if useNumberMatching,
               let num = extractTrailingNumber(from: jpgBase),
               let byNum = rawByNumber[num] {
                return byNum
            }
            return nil
        }

        /// 어떤 JPG 키가 RAW 를 "소유" 하는지 판정 (중복 매핑 방지)
        func rawBaseIsPairedFromJPG(_ rawBase: String) -> Bool {
            if jpgFiles[rawBase] != nil { return true }
            if useNumberMatching,
               let num = extractTrailingNumber(from: rawBase),
               let jpgInfo = jpgByNumber[num],
               // 해당 JPG 가 존재하고 + 이 RAW 를 pairedRAW 로 가져간다면 true
               pairedRAW(forJPGBase: jpgInfo.url.deletingPathExtension().lastPathComponent.lowercased())?.url == rawFiles[rawBase]?.url {
                return true
            }
            return false
        }

        // JPG가 있는 파일: JPG를 미리보기로, RAW를 매칭 (stat() 불필요 — enumerator에서 이미 로드)
        var result: [PhotoItem] = jpgFiles
            .sorted { $0.key < $1.key }
            .map { baseName, jpgInfo in
                let rawInfo = pairedRAW(forJPGBase: baseName)
                var item = PhotoItem(
                    jpgURL: jpgInfo.url,
                    rawURL: rawInfo?.url
                )
                item.fileModDate = jpgInfo.modDate
                item.jpgFileSize = jpgInfo.size
                if let r = rawInfo {
                    item.rawFileSize = r.size
                }
                return item
            }

        // RAW만 있는 파일 — 번호 매칭 시에도 JPG 에 딸린 것은 제외
        let rawOnly = rawFiles.filter { !rawBaseIsPairedFromJPG($0.key) }
        let rawOnlyItems = rawOnly
            .sorted { $0.key < $1.key }
            .map { baseName, rawInfo in
                var item = PhotoItem(
                    jpgURL: rawInfo.url,
                    rawURL: rawInfo.url
                )
                item.fileModDate = rawInfo.modDate
                item.rawFileSize = rawInfo.size
                return item
            }
        result.append(contentsOf: rawOnlyItems)

        // HEIC/PSD/TIFF
        let imageOnly = imageFiles.filter { jpgFiles[$0.key] == nil && rawFiles[$0.key] == nil }
        let imageOnlyItems = imageOnly
            .sorted { $0.key < $1.key }
            .map { baseName, imgInfo in
                var item = PhotoItem(
                    jpgURL: imgInfo.url,
                    rawURL: nil
                )
                item.fileModDate = imgInfo.modDate
                item.jpgFileSize = imgInfo.size
                return item
            }
        result.append(contentsOf: imageOnlyItems)

        // Video files
        // v8.9.4: videoDuration(url:) 는 AVAsset 동기 로드 (비싸고 NAS 에서 매우 느림).
        //         초기 스캔에선 0 으로 두고 PhotoPreviewView 가 첫 표시 직전 lazy 로드.
        let videoItems = videoFiles
            .sorted { $0.key < $1.key }
            .map { baseName, vidInfo in
                var item = PhotoItem(
                    jpgURL: vidInfo.url,
                    rawURL: nil
                )
                item.fileModDate = vidInfo.modDate
                item.jpgFileSize = vidInfo.size
                // item.videoDuration = 0 (default) — preview 표시 시점에 lazy 채움
                return item
            }
        result.append(contentsOf: videoItems)

        // Add subfolder items at the beginning (folder icons in thumbnail grid)
        let folderItems = subFolders
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { folderURL in
                PhotoItem(
                    jpgURL: folderURL,
                    rawURL: nil,
                    isFolder: true
                )
            }
        result.insert(contentsOf: folderItems, at: 0)

        return result
    }
}

// MARK: - 문자열 거리 계산 (매칭 서비스 공통)
enum StringDistance {
    static func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1), b = Array(s2)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                dp[i][j] = min(dp[i-1][j] + 1, dp[i][j-1] + 1, dp[i-1][j-1] + cost)
            }
        }
        return dp[m][n]
    }
}
