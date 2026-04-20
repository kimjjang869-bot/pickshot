import SwiftUI
import Combine
import CoreImage

extension Notification.Name {
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let toggleHistogram = Notification.Name("toggleHistogram")
    /// 영상 IN/OUT 마커가 바뀌었을 때 발송됨. object 는 영상 URL.
    /// 썸네일 그리드 / 클라이언트 전달 UI 가 수신하여 갱신.
    static let videoMarkersChanged = Notification.Name("videoMarkersChanged")
    /// v8.5 — C 키로 인라인 크롭 모드 토글
    static let toggleCropMode = Notification.Name("toggleCropMode")
}

/// 실제로 프리뷰에 렌더된 이미지의 frame(aspect-fit 후 결과) 을 전달하는 PreferenceKey.
/// 크롭 오버레이가 이 프레임에 정확히 맞추기 위해 사용.
struct PreviewImageFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Zoom Presets

enum ZoomPreset: String, CaseIterable, Identifiable {
    case fit = "화면 맞춤"
    case p25 = "25%"
    case p50 = "50%"
    case p75 = "75%"
    case p100 = "100%"
    case p150 = "150%"
    case p200 = "200%"
    case p500 = "500%"
    case p1000 = "1000%"
    case p2000 = "2000%"

    var id: String { rawValue }

    var scale: CGFloat? {
        switch self {
        case .fit: return nil
        case .p25: return 0.25
        case .p50: return 0.50
        case .p75: return 0.75
        case .p100: return 1.0
        case .p150: return 1.5
        case .p200: return 2.0
        case .p500: return 5.0
        case .p1000: return 10.0
        case .p2000: return 20.0
        }
    }

    static func fromScale(_ scale: CGFloat) -> ZoomPreset? {
        allCases.first { guard let s = $0.scale else { return false }; return abs(s - scale) < 0.01 }
    }
}

// MARK: - Preview Image Cache (Hybrid RAM + Disk, RAM-adaptive)

class PreviewImageCache {
    static let shared = PreviewImageCache()
    private var cache: [URL: NSImage] = [:]
    private var accessTime: [URL: Int] = [:]  // LRU tracking (O(1) 업데이트)
    private var accessCounter: Int = 0
    private var entrySizes: [URL: Int] = [:]  // 항목별 바이트 크기 추적
    private var currentBytes: Int = 0
    /// v8.6.1: 500MB → 300MB 로 하향 (전체 RSS 6GB 타겟 달성을 위해).
    /// `reduceCacheLimit()` 로 메모리 압박 시 더 낮춤.
    private var maxBytes: Int = 300 * 1024 * 1024
    private let lock = NSLock()

    /// v8.6.1: 메모리 압박 시 상한 절반으로 — 즉시 LRU evict 유도
    func reduceCacheLimit() {
        lock.lock()
        let newLimit = max(maxBytes / 2, 50 * 1024 * 1024)
        maxBytes = newLimit
        // 초과분 즉시 evict
        while currentBytes > maxBytes && !cache.isEmpty {
            if let oldestKey = accessTime.min(by: { $0.value < $1.value })?.key {
                cache.removeValue(forKey: oldestKey)
                accessTime.removeValue(forKey: oldestKey)
                currentBytes -= entrySizes.removeValue(forKey: oldestKey) ?? 0
            } else { break }
        }
        lock.unlock()
    }

    /// 원래 상한으로 복원 (cleanup 후).
    func restoreCacheLimit() {
        lock.lock()
        maxBytes = 300 * 1024 * 1024
        lock.unlock()
    }
    private var maxEntries: Int
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let diskCacheDir: URL
    // 디스크 쓰기 serialization: evict 시 concurrent queue 로 뿌리면 누적 I/O 병목 → 직렬 큐로 변경
    // 빠른 네비게이션 후반부에 속도 저하 주요 원인 (20장 이동 = 20개 JPEG 인코딩 병렬 → 디스크 경합)
    private let diskEvictQueue = DispatchQueue(label: "previewcache.evict", qos: .utility)

    init() {
        // UserDefaults에 저장된 값 우선, 없으면 RAM 기반 자동 설정
        let savedEntries = Int(UserDefaults.standard.double(forKey: "previewCacheSize"))
        if savedEntries > 0 {
            maxEntries = savedEntries
        } else {
            let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
            if ramGB >= 64 {
                maxEntries = 20
            } else if ramGB >= 32 {
                maxEntries = 15
            } else if ramGB >= 16 {
                maxEntries = 10
            } else {
                maxEntries = 5
            }
        }

        // Setup disk cache directory
        diskCacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("pickshot_cache")
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)

        // Listen for memory pressure → auto-clear cache
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [self] in
            self.clearCache()
        }
        source.resume()
        memoryPressureSource = source

        // 설정 변경 시 maxEntries 재조정
        NotificationCenter.default.addObserver(forName: .init("SettingsChanged"), object: nil, queue: .main) { [weak self] _ in
            let newVal = Int(UserDefaults.standard.double(forKey: "previewCacheSize"))
            if newVal > 0 { self?.maxEntries = newVal }
        }
    }

    /// Stable hash for disk cache filename from URL
    private func diskKey(for url: URL) -> URL {
        let hash = url.absoluteString.utf8.reduce(into: UInt64(5381)) { h, c in
            h = h &* 33 &+ UInt64(c)
        }
        return diskCacheDir.appendingPathComponent("\(hash).jpg")
    }

    /// v8.6.2: CacheSweeper 가 "이미 메모리 캐시에 있는지" 빠르게 확인 (RAM only).
    func hasCached(for url: URL) -> Bool {
        lock.lock()
        let has = cache[url] != nil
        lock.unlock()
        return has
    }

    func get(_ url: URL) -> NSImage? {
        lock.lock()
        // RAM hit
        if let img = cache[url] {
            accessCounter += 1
            accessTime[url] = accessCounter
            lock.unlock()
            return img
        }
        lock.unlock()

        // Disk cache hit — NSImage(contentsOf:) 는 lazy decoding 이라
        // 다음 렌더 프레임에 스파이크가 나므로 즉시 bitmap 으로 디코딩
        let diskPath = diskKey(for: url)
        if let data = try? Data(contentsOf: diskPath),
           let cgImg = NSBitmapImageRep(data: data)?.cgImage {
            let decoded = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
            set(url, image: decoded)
            return decoded
        }
        return nil
    }

    /// 이미지 예상 메모리 크기 (바이트)
    private func estimateBytes(_ image: NSImage) -> Int {
        let rep = image.representations.first
        let w = rep?.pixelsWide ?? Int(image.size.width)
        let h = rep?.pixelsHigh ?? Int(image.size.height)
        return max(1, w * h * 4)
    }

    /// LRU 기준으로 가장 오래된 항목을 디스크로 evict (O(n log n) 정렬, accessOrder 배열 제거)
    private func evictOldest(count: Int) {
        let removeCount = min(count, cache.count)
        guard removeCount > 0 else { return }
        // accessTime 기준 오름차순 정렬 → 가장 오래된 것부터 제거
        let sorted = accessTime.sorted { $0.value < $1.value }
        let evictKeys = sorted.prefix(removeCount).map(\.key)
        for key in evictKeys {
            if let evictedImg = cache.removeValue(forKey: key) {
                currentBytes -= entrySizes.removeValue(forKey: key) ?? 0
                accessTime.removeValue(forKey: key)
                let diskPath = diskKey(for: key)
                let capturedImg = evictedImg
                // 직렬 큐로 뿌려서 동시 JPEG 인코딩/디스크 쓰기 경합 방지
                // (빠른 네비게이션 시 누적되는 작업 수가 제한됨)
                diskEvictQueue.async {
                    // 이미 디스크에 있으면 쓰기 스킵 — 불필요한 I/O 제거
                    if FileManager.default.fileExists(atPath: diskPath.path) { return }
                    if let cgImage = capturedImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let bitmap = NSBitmapImageRep(cgImage: cgImage)
                        if let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                            try? jpegData.write(to: diskPath, options: .atomic)
                        }
                    } else if let tiffData = capturedImg.tiffRepresentation,
                              let bitmap = NSBitmapImageRep(data: tiffData),
                              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                        try? jpegData.write(to: diskPath, options: .atomic)
                    }
                }
            }
        }
    }

    func set(_ url: URL, image: NSImage) {
        lock.lock()
        let imageBytes = estimateBytes(image)

        // 항목 수 상한 체크
        if cache.count >= maxEntries {
            evictOldest(count: maxEntries / 3)
        }
        // 바이트 상한 체크 (500MB)
        while currentBytes + imageBytes > maxBytes && !cache.isEmpty {
            evictOldest(count: 1)
        }

        // 기존 항목 교체 시 이전 크기 빼기
        if let oldSize = entrySizes[url] {
            currentBytes -= oldSize
        }
        cache[url] = image
        entrySizes[url] = imageBytes
        currentBytes += imageBytes

        // LRU 업데이트 O(1)
        accessCounter += 1
        accessTime[url] = accessCounter
        lock.unlock()
    }

    func has(_ url: URL) -> Bool {
        lock.lock()
        let inRAM = cache[url] != nil
        lock.unlock()
        if inRAM { return true }
        // Check disk cache
        return FileManager.default.fileExists(atPath: diskKey(for: url).path)
    }

    func remove(url: URL) {
        lock.lock()
        cache.removeValue(forKey: url)
        accessTime.removeValue(forKey: url)
        currentBytes -= entrySizes.removeValue(forKey: url) ?? 0
        lock.unlock()
        // Also remove from disk cache
        let diskPath = diskKey(for: url)
        try? FileManager.default.removeItem(at: diskPath)
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        accessTime.removeAll()
        entrySizes.removeAll()
        currentBytes = 0
        lock.unlock()
    }

    /// v8.6.3: 선제 trim — 가장 오래 안 쓰인 비율만큼만 제거 (MemoryGuard Layer 2)
    func trimOldest(ratio: Double) {
        let r = max(0.05, min(0.95, ratio))
        lock.lock()
        let total = cache.count
        let evictCount = Int(Double(total) * r)
        if evictCount > 0 {
            // 디스크 이관 포함한 evictOldest 사용
            evictOldest(count: evictCount)
        }
        lock.unlock()
    }

    /// 디버그용 — 현재 캐시 통계 (NavigationPerformanceMonitor 에서 사용)
    func debugStats() -> (count: Int, bytes: Int) {
        lock.lock()
        let c = cache.count
        let b = currentBytes
        lock.unlock()
        return (c, b)
    }

    /// Prefetch previews at given resolution
    private static let prefetchQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility  // 실제 로드(.userInitiated)와 경합 방지
        return q
    }()

    func prefetch(urls: [URL], resolution: Int = 0) {
        if ProcessInfo.processInfo.thermalState == .critical ||
           ProcessInfo.processInfo.thermalState == .serious {
            return
        }

        let screenPx = Self.optimalPreviewSize()
        for url in urls {
            // RAW 프리페치 스킵 — RawCamera 디모자이킹이 CPU 폭발 유발
            let ext = url.pathExtension.lowercased()
            if FileMatchingService.rawExtensions.contains(ext) { continue }

            let maxPx: CGFloat = resolution > 0 ? CGFloat(resolution) : screenPx
            let key = url.appendingPathExtension("r\(Int(maxPx))")
            if has(key) { continue }
            Self.prefetchQueue.addOperation { [self] in
                autoreleasepool {
                    guard !self.has(key) else { return }
                    let img = Self.loadOptimized(url: url, maxPixel: maxPx)
                    if let img = img { self.set(key, image: img) }
                }
            }
        }
    }

    /// Optimal preview size based on screen resolution
    static func optimalPreviewSize() -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let screenW = (NSScreen.main?.frame.width ?? 1440) * scale
        // Use full retina resolution for sharp previews
        return min(screenW * 0.7, 4000)
    }

    /// Load image with optimized CGImageSource options (no system cache = less memory)
    /// Target color space for RAW rendering (user configurable)
    static var targetColorSpace: CGColorSpace {
        let fallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let pref = UserDefaults.standard.string(forKey: "colorProfile") ?? "display"
        switch pref {
        case "srgb": return CGColorSpace(name: CGColorSpace.sRGB) ?? fallback
        case "p3": return CGColorSpace(name: CGColorSpace.displayP3) ?? fallback
        case "adobeRGB": return CGColorSpace(name: CGColorSpace.adobeRGB1998) ?? fallback
        default: return NSScreen.main?.colorSpace?.cgColorSpace ?? fallback
        }
    }

    static func loadOptimized(url: URL, maxPixel: CGFloat) -> NSImage? {
        // 전체 로드 경로를 autoreleasepool 로 감싸서 CGImageSource + 중간 NSImage/CGImage
        // 임시 객체를 즉시 해제. key repeat 꾹 누르기 시 autorelease pool 이 main loop 블록되면
        // 못 비워지는 문제 방지.
        let base = autoreleasepool { () -> NSImage? in
            _loadOptimizedImpl(url: url, maxPixel: maxPixel)
        }
        guard let img = base else { return nil }
        // v8.6.2: 사용자 override 회전 (RAW 사이드카 + 앱내부) 적용
        let deg = PhotoStore.rotationOverrideCW(for: url)
        return deg == 0 ? img : RotationService.rotateImage(img, degreesCW: deg)
    }

    private static func _loadOptimizedImpl(url: URL, maxPixel: CGFloat) -> NSImage? {
        let sourceOptions: [NSString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let canDecode = props?[kCGImagePropertyPixelWidth as String] != nil
        let origW = (props?[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
        let origH = (props?[kCGImagePropertyPixelHeight as String] as? Int) ?? 0
        let origMax = max(origW, origH)

        let ext = url.pathExtension.lowercased()
        let isJPG = ["jpg", "jpeg"].contains(ext)
        let isRAW = FileMatchingService.rawExtensions.contains(ext)
        let isTIFF = ["tif", "tiff"].contains(ext)
        // TIFF는 풀 디코드 매우 느림 (100MB+ 파일이 흔함) → SubsampleFactor 적용 대상
        let canSubsample = isJPG || isTIFF

        // JPG: load at original size if smaller than maxPixel
        if isJPG && origMax > 0 && origMax <= Int(maxPixel) {
            return NSImage(contentsOf: url)
        }

        let effectiveMaxPx = origMax > 0 ? min(maxPixel, CGFloat(origMax)) : maxPixel

        // RAW files: CIRAWFilter mode (user setting)
        let useCIRAW = UserDefaults.standard.string(forKey: "rawPreviewMode") == "ciraw"
        if isRAW && canDecode && useCIRAW {
            if #available(macOS 12.0, *) {
                if let rawImage = loadRAWWithCIFilter(url: url, maxPixel: effectiveMaxPx) {
                    return rawImage
                }
            }
        }

        if canDecode {
            // Strategy 1: Embedded preview (fastest)
            let embedOnly: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: effectiveMaxPx,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, embedOnly as CFDictionary) {
                if cgImage.width >= Int(maxPixel * 0.3) || cgImage.height >= Int(maxPixel * 0.3) {
                    let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    return PhotoPreviewView.correctThumbnailOrientationIfNeeded(img, source: source)
                }
            }

            // Strategy 2: Generate thumbnail with SubsampleFactor for faster JPEG decode
            let origMax = max(origW, origH)
            var subsample = 1
            let targetPx = Int(effectiveMaxPx)
            if origMax > targetPx * 8 { subsample = 8 }
            else if origMax > targetPx * 4 { subsample = 4 }
            else if origMax > targetPx * 2 { subsample = 2 }

            var genOpts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: effectiveMaxPx,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false
            ]
            if canSubsample && subsample > 1 {
                // JPG/TIFF: SubsampleFactor 2/4/8로 디코드 시간 4~64배 단축
                // (TIFF 100MB → 1.5초+ 풀 디코드가 ~0.2초로 줄어듦)
                genOpts[kCGImageSourceSubsampleFactor as NSString] = subsample
            }
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, genOpts as CFDictionary) {
                let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                return PhotoPreviewView.correctThumbnailOrientationIfNeeded(img, source: source)
            }
        }

        // Fallback: extract BEST embedded JPEG from unsupported RAW (e.g., Nikon Z8/Z9 High Efficiency)
        let rawExt = url.pathExtension.lowercased()
        guard FileMatchingService.rawExtensions.contains(rawExt) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 100 else { return nil }
        let ffd8: [UInt8] = [0xFF, 0xD8]
        // Scan first 2MB to find ALL embedded JPEGs, pick the LARGEST one
        let scanLimit = min(data.count - 2, 2_000_000)
        guard scanLimit > 0 else { return nil }

        var bestImage: NSImage?
        var bestWidth = 0

        for i in 0..<scanLimit {
            if data[i] == ffd8[0] && data[i + 1] == ffd8[1] {
                // v8.6.1: FFD8 스캔 per-iteration autoreleasepool — 큰 RAW 에서 subdata/CGImage
                // 임시 생성물이 누적되어 수백 MB 메모리 피크 나던 문제 수정.
                autoreleasepool {
                    let end = min(i + 5_000_000, data.count)
                    let subData = data.subdata(in: i..<end)
                    guard let imgSource = CGImageSourceCreateWithData(subData as CFData, nil),
                          CGImageSourceGetCount(imgSource) > 0 else { return }

                    let props = CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [String: Any]
                    let pw = props?[kCGImagePropertyPixelWidth as String] as? Int ?? 0
                    let ph = props?[kCGImagePropertyPixelHeight as String] as? Int ?? 0
                    let ar = pw > ph ? Double(pw) / max(Double(ph), 1) : Double(ph) / max(Double(pw), 1)
                    if ar > 4.0 { return }

                    let opts: [NSString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ]
                    if let cg = CGImageSourceCreateThumbnailAtIndex(imgSource, 0, opts as CFDictionary),
                       cg.width > bestWidth {
                        bestWidth = cg.width
                        bestImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    }
                }
            }
        }
        return bestImage
    }

    /// Load RAW file using CIRAWFilter for accurate color management (macOS 12+)
    @available(macOS 12.0, *)
    static func loadRAWWithCIFilter(url: URL, maxPixel: CGFloat) -> NSImage? {
        // autoreleasepool로 감싸 RAW 디코딩 중간 CIImage 즉시 해제 (메모리 피크 완화)
        let cgImage: CGImage? = autoreleasepool {
            guard let rawFilter = CIRAWFilter(imageURL: url) else { return nil }

            // Preserve original look (no auto-boost)
            rawFilter.boostAmount = 0
            rawFilter.isGamutMappingEnabled = true

            guard let ciImage = rawFilter.outputImage else { return nil }

            // Scale down to maxPixel
            let scale: CGFloat
            let maxDim = max(ciImage.extent.width, ciImage.extent.height)
            if maxDim > maxPixel {
                scale = maxPixel / maxDim
            } else {
                scale = 1.0
            }

            let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            // Render with target color space
            let ctx = CIContext(options: [.workingColorSpace: targetColorSpace])
            return ctx.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: targetColorSpace)
        }

        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

// MARK: - PreviewViewState (zoom / pan / loupe observable)

final class PreviewViewState: ObservableObject {
    // Zoom
    @Published var zoomPreset: ZoomPreset = .fit
    @Published var customScale: CGFloat = 1.0
    @Published var panOffset: CGPoint = .zero
    @Published var dragStart: CGPoint = .zero
    @Published var magnifyBaseScale: CGFloat = 1.0

    // Loupe
    @Published var loupePosition: CGPoint? = nil
    @Published var loupeActive: Bool = false
    @Published var loupeImage: NSImage? = nil
    var loupeWorkItem: DispatchWorkItem?
    var loupeCachedImage: CGImage? = nil
    var loupeCachedURL: URL? = nil

    // View tracking
    @Published var viewSize: CGSize = .zero
    @Published var mousePosition: CGPoint = .zero
    @Published var isMouseOverPreview: Bool = false
    var stableImageSize: CGSize? = nil
    var scrollMonitor: Any? = nil
}

// MARK: - PhotoPreviewView

struct PhotoPreviewView: View {
    let photo: PhotoItem
    /// 듀얼 뷰어 등에서 별점/라벨/회전 버튼 등 하단 chrome 을 숨길 때 사용.
    var hideChrome: Bool = false
    @EnvironmentObject var store: PhotoStore
    @StateObject private var viewState = PreviewViewState()

    @State private var image: NSImage?          // Currently displayed image (low-res or hi-res)
    @State private var lowResImage: NSImage?     // Fast preview (1200px) — used at fit zoom
    @State private var hiResImage: NSImage?      // Full resolution — loaded on zoom in
    @State private var isHiResLoaded = false      // Whether hi-res is currently active
    @State private var hiResLoadWork: DispatchWorkItem?
    @State private var showCorrectionPanel = false
    @State private var showUprightGuide = false
    @State private var correctionResult: CorrectionResult?
    @State private var isOriginal = true
    @State private var isCorrecting = false
    @State private var pendingPhotoID: UUID? = nil
    @State private var showHistogram: Bool = false
    @State private var showZebraWarning: Bool = false
    @State private var showFocusPeaking: Bool = false
    @State private var hexInput: String = "333333"
    @State private var rotationAngle: Double = 0  // 0, 90, 180, 270
    @State private var rotatedImage: NSImage?  // Actual rotated pixel data
    /// v8.6.2: Stage 1 로드 성공 시 기준 aspect 기록. 후속 로드(Stage2/HiRes/developed)가 이 aspect
    /// 와 다르면 EXIF orient 으로 강제 회전해서 "처음엔 세로, 나중에 가로로 뒤집힘" 버그 차단.
    @State private var firstLoadIsPortrait: Bool? = nil
    @State private var firstLoadPhotoID: UUID? = nil

    // MARK: - Non-Destructive Develop (v8.5)
    /// DevelopSettings 적용된 이미지. isDefault (보정 없음) 이면 nil.
    @State private var developedImage: NSImage?
    /// 현재 개발된 이미지가 어느 photoID 에 대한 것인지 (캐시 무효화용).
    @State private var developedForPhotoID: UUID? = nil
    /// 진행 중인 렌더링 작업 (사진 전환 시 취소).
    @State private var developRenderTask: Task<Void, Never>? = nil
    /// 디바운스 타이머 (150ms) — 슬라이더 드래그 중 연속 변경 시 마지막만 실행
    @State private var developRenderDebounce: DispatchWorkItem? = nil
    /// Shared pipeline (Metal CIContext 공유).
    private static let developPipelineShared = DevelopPipeline()
    /// 인라인 크롭 모드 활성화 여부 (C 키 토글).
    @State private var isCroppingMode: Bool = false
    /// 실제 프리뷰에 렌더된 이미지 frame (크롭 오버레이 정확 정렬용)
    @State private var previewImageFrame: CGRect = .zero
    /// 보정 관련 토스트 메시지 ("보정값 복사됨" 등). 1.5초 후 사라짐.
    @State private var adjustmentToast: String? = nil
    @State private var adjustmentToastTask: Task<Void, Never>? = nil
    @State private var showAIResult: Bool = false
    @State private var aiResultText: String = ""
    @State private var hiResWorkItem: DispatchWorkItem? = nil
    @State private var imageLoadWork: DispatchWorkItem? = nil
    @State private var preloadWork: DispatchWorkItem? = nil
    @State private var lastPrefetchScheduled: Date = .distantPast
    @State private var showCropView = false
    @State private var showColorPicker = false
    @State private var customBgColor = Color(nsColor: .controlBackgroundColor)

    private static let imageLoadQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    private var isFitMode: Bool { viewState.zoomPreset == .fit }

    // 미리보기 테두리: 컬러라벨 > 별점 > SP > 없음
    // PhotoItem이 id-only Equatable이라 prop diff로는 갱신이 안 되므로,
    // store에서 최신 photo를 매번 조회해서 실시간 반영한다.
    private var livePhoto: PhotoItem {
        if let idx = store._photoIndex[photo.id], idx < store.photos.count {
            return store.photos[idx]
        }
        return photo
    }
    private var previewBorderColor: Color {
        let p = livePhoto
        if p.isSpacePicked { return .red }
        if p.colorLabel != .none, let c = p.colorLabel.color { return c }
        if p.rating > 0 { return AppTheme.starGold }
        return .clear
    }
    private var previewBorderWidth: CGFloat {
        let p = livePhoto
        if p.isSpacePicked { return 4 }
        if p.colorLabel != .none && p.colorLabel.color != nil { return 3 }
        if p.rating > 0 { return 3 }
        return 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Image area
            GeometryReader { geo in
                let vSize = geo.size

                Group {
                // 비디오 파일이면 비디오 플레이어 표시
                if photo.isVideoFile {
                    VideoPlayerView(url: photo.jpgURL)
                        .frame(width: vSize.width, height: vSize.height)
                } else if let image = image {
                    // v8.6.2: 현재 photo 의 metadata 크기 우선 사용 (image 가 이전 사진 것일 수 있음).
                    //   빠른 이동 중 image 교체 전에 aspect/크기 차이로 "순간 작아졌다 커짐" 방지.
                    let stableW = viewState.stableImageSize?.width ?? image.size.width
                    let stableH = viewState.stableImageSize?.height ?? image.size.height
                    let imgW: CGFloat = stableW
                    let imgH: CGFloat = stableH
                    let imgSize = CGSize(width: imgW, height: imgH)
                    let fitScale = min(vSize.width / imgW, vSize.height / imgH)
                    let activeScale = isFitMode ? 1.0 : viewState.customScale
                    let scaledW = imgW * fitScale * activeScale
                    let scaledH = imgH * fitScale * activeScale
                    let isZoomed = !isFitMode && activeScale > 1.0

                    let clampedOffset = clampPan(
                        pan: viewState.panOffset, scaledSize: CGSize(width: scaledW, height: scaledH), viewSize: vSize
                    )

                    ZStack {
                        // view frame = vSize/scaledSize 고정, 이미지는 내부 aspect fit.
                        // 크롭 모드 중엔 cropModeLayer 가 이 이미지를 대체하므로 투명 처리.
                        Image(nsImage: developedImage ?? rotatedImage ?? image)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: isFitMode ? vSize.width : scaledW,
                                   height: isFitMode ? vSize.height : scaledH)
                            .opacity(isCroppingMode ? 0 : 1)
                            .offset(
                                x: isZoomed ? clampedOffset.x : 0,
                                y: isZoomed ? clampedOffset.y : 0
                            )
                            .frame(width: vSize.width, height: vSize.height, alignment: .center)
                            .clipped()
                            .gesture(
                                isZoomed ?
                                DragGesture()
                                    .onChanged { value in
                                        viewState.panOffset = CGPoint(
                                            x: viewState.dragStart.x + value.translation.width,
                                            y: viewState.dragStart.y + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in
                                        let clamped = clampPan(
                                            pan: viewState.panOffset,
                                            scaledSize: CGSize(width: scaledW, height: scaledH),
                                            viewSize: vSize
                                        )
                                        viewState.panOffset = CGPoint(x: clamped.x, y: clamped.y)
                                        viewState.dragStart = viewState.panOffset
                                    }
                                : nil
                            )
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { location in
                                if isFitMode {
                                    // Zoom to 350% centered on clicked point
                                    let targetScale: CGFloat = 3.5
                                    viewState.zoomPreset = .p100  // Will be overridden
                                    viewState.customScale = targetScale
                                    // Calculate pan offset so clicked point stays at center
                                    let displayW = imgW * fitScale
                                    let displayH = imgH * fitScale
                                    let clickRelX = location.x - vSize.width / 2
                                    let clickRelY = location.y - vSize.height / 2
                                    let newScaledW = imgW * fitScale * targetScale
                                    let newScaledH = imgH * fitScale * targetScale
                                    let panX = -clickRelX * (newScaledW / displayW - 1)
                                    let panY = -clickRelY * (newScaledH / displayH - 1)
                                    let offset = clampPan(
                                        pan: CGPoint(x: panX, y: panY),
                                        scaledSize: CGSize(width: newScaledW, height: newScaledH),
                                        viewSize: vSize
                                    )
                                    viewState.panOffset = CGPoint(x: offset.x, y: offset.y)
                                    viewState.dragStart = viewState.panOffset
                                    viewState.magnifyBaseScale = targetScale
                                    syncSlider()
                                    loadHiResForZoom()  // Load full resolution
                                } else {
                                    // Reset to fit → switch back to low-res
                                    viewState.zoomPreset = .fit
                                    viewState.panOffset = .zero
                                    viewState.dragStart = .zero
                                    viewState.magnifyBaseScale = 1.0
                                    syncSlider()
                                    switchToLowRes()  // Restore fast preview
                                }
                            }
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    viewState.mousePosition = location
                                    viewState.isMouseOverPreview = true
                                    guard viewState.loupeActive else { return }
                                    let displayScale = fitScale * activeScale
                                    let displayW = imgW * displayScale
                                    let displayH = imgH * displayScale
                                    let imgCenterX = vSize.width / 2 + (isZoomed ? clampedOffset.x : 0)
                                    let imgCenterY = vSize.height / 2 + (isZoomed ? clampedOffset.y : 0)
                                    let normalX = (location.x - (imgCenterX - displayW / 2)) / displayW
                                    let normalY = (location.y - (imgCenterY - displayH / 2)) / displayH
                                    guard normalX >= 0 && normalX <= 1 && normalY >= 0 && normalY <= 1 else {
                                        viewState.loupePosition = nil
                                        viewState.loupeImage = nil
                                        return
                                    }
                                    viewState.loupePosition = location
                                    // Throttle loupe generation using DispatchWorkItem cancellation
                                    viewState.loupeWorkItem?.cancel()
                                    let capturedNX = normalX
                                    let capturedNY = normalY
                                    let work = DispatchWorkItem { [self] in
                                        generateLoupeNormalized(normalX: capturedNX, normalY: capturedNY)
                                    }
                                    viewState.loupeWorkItem = work
                                    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.1, execute: work)
                                case .ended:
                                    viewState.isMouseOverPreview = false
                                    break
                                }
                            }
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        let newScale = max(0.25, min(20.0, viewState.magnifyBaseScale * value))
                                        viewState.customScale = newScale
                                        viewState.zoomPreset = ZoomPreset.fromScale(newScale) ?? .p100
                                        syncSlider()
                                    }
                                    .onEnded { value in
                                        let newScale = max(0.25, min(20.0, viewState.magnifyBaseScale * value))
                                        viewState.customScale = newScale
                                        viewState.magnifyBaseScale = newScale
                                        viewState.zoomPreset = ZoomPreset.fromScale(newScale) ?? .p100
                                        syncSlider()
                                    }
                            )

                        // 얼룩말 경고 오버레이
                        if showZebraWarning, let img = self.image {
                            ZebraWarningOverlay(image: img)
                                .allowsHitTesting(false)
                        }
                        // 포커스 피킹 오버레이
                        if showFocusPeaking, let img = self.image {
                            FocusPeakingOverlay(image: img)
                                .allowsHitTesting(false)
                        }

                        // Overlays (fixed to view size, not image size)
                        VStack {
                            // Top-right: Histogram
                            HStack {
                                Spacer()
                                VStack(spacing: 4) {
                                    if showHistogram {
                                        HistogramOverlay(photo: photo)
                                    }
                                }
                                .padding(8)
                            }
                            Spacer()
                            // Bottom-left: Client comment (클라이언트 코멘트)
                            HStack {
                                if let comment = store.clientComments[photo.id] {
                                    HStack(spacing: 6) {
                                        Image(systemName: "bubble.left.fill")
                                            .font(.system(size: 12))
                                        Text("클라이언트: \(comment)")
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(2)
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.85))
                                    .cornerRadius(6)
                                    .padding(8)
                                }
                                Spacer()
                                // Bottom-right: Mini navigator
                                VStack(alignment: .trailing, spacing: 6) {
                                    if isZoomed && !isFitMode {
                                        MiniNavigator(
                                            image: image,
                                            imageSize: imgSize,
                                            scaledSize: CGSize(width: scaledW, height: scaledH),
                                            viewSize: vSize,
                                            panOffset: $viewState.panOffset,
                                            dragStart: $viewState.dragStart
                                        )
                                    }
                                    // Zoom percentage badge
                                    Text(isFitMode ? "맞춤" : "\(Int(viewState.customScale * 100))%")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.black.opacity(0.55))
                                        .cornerRadius(5)
                                }
                                .padding(8)
                            }
                        }

                        // MARK: - Metadata Overlay (nomacs-style, toggle with "i" key)
                        if store.showMetadataOverlay {
                            MetadataOverlayView(photo: photo)
                                .allowsHitTesting(false)
                        }

                        // MARK: - 🎨 고객 펜 오버레이 (F 키로 토글, 기본 ON)
                        if store.showClientPenOverlay,
                           let penJSON = photo.clientPenDrawingsJSON,
                           !penJSON.isEmpty {
                            ClientPenOverlayView(
                                penDrawingsJSON: penJSON,
                                imageSize: CGSize(width: 1000, height: 1000),
                                displaySize: vSize
                            )
                            .frame(width: vSize.width, height: vSize.height)
                        }
                    }
                    .frame(width: vSize.width, height: vSize.height)
                    .background(store.previewBackgroundColor)
                    .coordinateSpace(name: "previewContainer")
                    .onPreferenceChange(PreviewImageFrameKey.self) { newFrame in
                        previewImageFrame = newFrame
                        fputs("[CROP-FIT] imageFrame=\(newFrame) vSize=\(vSize)\n", stderr)
                    }
                    .overlay(
                        Rectangle()
                            .stroke(previewBorderColor, lineWidth: previewBorderWidth)
                            .allowsHitTesting(false)
                    )
                    .overlay(alignment: .bottom) {
                        // v8.5 — 비파괴 보정 플로팅 필 (크롭 모드 중 / 듀얼뷰어 chrome 숨김 시 비표시)
                        // v8.6.3: Debug 에서만 활성화 (보정 기능 완성 전 Release 숨김)
                        #if DEBUG
                        if !photo.isFolder && !photo.isParentFolder && !photo.isVideoFile && !isCroppingMode && !hideChrome {
                            FloatingAdjustmentPill(photoURL: photo.jpgURL)
                                .padding(.bottom, 16)
                                .allowsHitTesting(true)
                        }
                        #endif
                    }
                    .overlay {
                        cropOverlayIfNeeded(vSize: vSize, image: image)
                    }
                    .overlay(alignment: .top) {
                        // v8.5 — 보정 토스트 (보정값 복사됨 등)
                        if let msg = adjustmentToast {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color(red: 1.0, green: 0.76, blue: 0.03))
                                Text(msg).font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(
                                Capsule().fill(Color.black.opacity(0.82))
                                    .overlay(Capsule().stroke(Color(red: 1.0, green: 0.76, blue: 0.03).opacity(0.35), lineWidth: 1))
                            )
                            .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
                            .padding(.top, 24)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .allowsHitTesting(false)
                        }
                    }
                    .contextMenu { previewBgMenu }
                } else {
                    // No image yet - show empty background
                    store.previewBackgroundColor
                        .contextMenu { previewBgMenu }
                        .frame(width: vSize.width, height: vSize.height)
                }
                }
                .onAppear {
                    viewState.viewSize = vSize
                }
                .onChange(of: vSize) { _, newSize in
                    viewState.viewSize = newSize
                }
            }


            Divider()

            // Toolbar: Correction | Stars + SP | Zoom — 듀얼뷰어에선 숨김 (zoomBar 는 별도 노출)
            if !hideChrome {
            HStack(spacing: 6) {
                correctionBar

                Divider().frame(height: 20).opacity(0.2)

                HStack(spacing: 8) {
                    StarRatingView(rating: photo.rating) { newRating in
                        store.setRating(newRating, for: photo.id)
                    }

                    // 컬러 라벨 선택
                    HStack(spacing: 3) {
                        ForEach(ColorLabel.allCases.filter { $0 != .none }, id: \.self) { label in
                            Button(action: { store.setColorLabel(label, for: photo.id) }) {
                                Circle()
                                    .fill(label.color ?? .clear)
                                    .frame(width: 16, height: 16)
                                    .overlay(
                                        photo.colorLabel == label
                                            ? Circle().stroke(Color.white, lineWidth: 2)
                                            : nil
                                    )
                            }
                            .buttonStyle(.plain)
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                            .help("\(label.rawValue) (키: \(label.key.isEmpty ? "없음" : label.key))")
                        }
                    }
                }

                Divider().frame(height: 20).opacity(0.2)

                // v8.6.2: 회전 버튼 — 일괄 회전 파이프라인 사용 + 클릭 시 아이콘 회전 애니메이션
                RotateToolbarButton(systemImage: "arrow.counterclockwise", clockwise: false) {
                    store.batchRotate(ids: [photo.id], degreesCW: 270)
                }
                RotateToolbarButton(systemImage: "arrow.clockwise", clockwise: true) {
                    store.batchRotate(ids: [photo.id], degreesCW: 90)
                }

                Divider().frame(height: 20).opacity(0.2)

                zoomBar
            }
            .padding(.horizontal, AppTheme.space8)
            } else {
                // 듀얼뷰어: zoomBar 만 우측 끝에 표시 (별점/라벨/회전 숨김)
                HStack {
                    Spacer()
                    zoomBar
                        .padding(.horizontal, AppTheme.space8)
                }
            }
        }
        .sheet(isPresented: $showUprightGuide) {
            UprightGuideView(photo: photo) { correctedImage in
                correctionResult = CorrectionResult(correctedImage: correctedImage, applied: ["가이드 원근 보정"])
                image = correctedImage
                isOriginal = false
            }
        }
        .sheet(isPresented: $showCropView) {
            CropView(photo: photo) { croppedImage in
                self.image = croppedImage
            }
        }
        .popover(isPresented: $showColorPicker, arrowEdge: .leading) {
            VStack(spacing: 12) {
                Text("커스텀 배경색")
                    .font(.system(size: 13, weight: .semibold))
                ColorPicker("", selection: $customBgColor, supportsOpacity: false)
                    .labelsHidden()

                // HEX 코드 입력
                HStack(spacing: 8) {
                    Text("#")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                    TextField("FF0000", text: $hexInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 80)
                        .onSubmit {
                            let clean = hexInput.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                            guard clean.count == 6, let val = UInt64(clean, radix: 16) else { return }
                            let r = Double((val >> 16) & 0xFF) / 255.0
                            let g = Double((val >> 8) & 0xFF) / 255.0
                            let b = Double(val & 0xFF) / 255.0
                            customBgColor = Color(nsColor: NSColor(red: r, green: g, blue: b, alpha: 1))
                        }

                    RoundedRectangle(cornerRadius: 4)
                        .fill(customBgColor)
                        .frame(width: 30, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4), lineWidth: 1))
                }

                HStack {
                    Button("취소") { showColorPicker = false }
                    Spacer()
                    Button("적용") {
                        // 안전한 RGB 변환 (색공간 변환 후 접근)
                        let ns = NSColor(customBgColor).usingColorSpace(.sRGB) ?? NSColor.darkGray
                        let r = Int(ns.redComponent * 255)
                        let g = Int(ns.greenComponent * 255)
                        let b = Int(ns.blueComponent * 255)
                        store.previewBgCustomHex = String(format: "#%02X%02X%02X", r, g, b)
                        store.previewBgMode = "custom"
                        showColorPicker = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 260)
        }
        .popover(isPresented: $showCorrectionPanel) {
            if store.selectionCount > 1 {
                BatchCorrectionView(
                    photos: store.multiSelectedPhotos,
                    onComplete: {
                        showCorrectionPanel = false
                    }
                )
                .environmentObject(store)
            } else {
                CorrectionOptionsView(
                    photo: photo,
                    onApply: { result in
                        correctionResult = result
                        if let img = result.correctedImage {
                            image = img
                            isOriginal = false
                        }
                        showCorrectionPanel = false
                    },
                    isCorrecting: $isCorrecting
                )
            }
        }
        .onAppear {
            pendingPhotoID = photo.id
            viewState.stableImageSize = Self.readImageDimensions(url: photo.jpgURL)
            loadImageDirect(for: photo.jpgURL, id: photo.id)
            viewState.magnifyBaseScale = viewState.customScale

            // v8.6.2 fix: 첫 마운트 시 (앱 진입 직후) 는 selectedPhotoID 가 이미 설정돼 있어
            //   .onChange 가 fire 안 됨 → HiRes 예약이 누락됐던 버그. 여기서 동일 스케줄링 추가.
            let firstID = photo.id
            let firstURL = photo.jpgURL
            let firstWork = DispatchWorkItem {
                guard self.pendingPhotoID == firstID else { return }
                self.loadHiResForZoom()
            }
            hiResWorkItem = firstWork
            let alreadyCached: Bool = {
                return Self.hiResCache.object(forKey: firstURL as NSURL) != nil
            }()
            let delay: TimeInterval = alreadyCached ? 0.0 : 0.15
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: firstWork)

            // 빠른 탐색 콜백: 캐시 히트 시에만 즉시 표시.
            // 캐시 miss 시 동기 썸네일 추출은 main thread 에 5~15ms 비용 + NSImage 인스턴스 누적 →
            // key repeat 꾹 누르기 시 이동당 interval 90ms → 200ms+ 로 저하. 미스면 비동기 경로에 맡김.
            store.onQuickPreview = { [self] url in
                guard url == store.selectedPhoto?.jpgURL else { return }
                if let thumb = ThumbnailCache.shared.get(url) {
                    self.image = thumb
                }
                // cache miss: 비워두고 onChange(selectedPhotoID) 의 비동기 로드 대기
            }

            // Scroll wheel zoom monitor (only when mouse is over preview)
            if let existing = viewState.scrollMonitor {
                NSEvent.removeMonitor(existing)
                viewState.scrollMonitor = nil
            }
            viewState.scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown]) { [self] event in
                // Verify monitor is still active
                guard viewState.scrollMonitor != nil else { return event }
                guard let window = event.window,
                      window.isKeyWindow else { return event }

                // Middle mouse button click → fit to screen
                if event.type == .otherMouseDown && event.buttonNumber == 2 {
                    guard self.viewState.isMouseOverPreview else { return event }
                    self.setZoom(.fit)
                    return nil
                }

                // Scroll wheel → zoom (only if mouse is over preview area)
                guard self.viewState.isMouseOverPreview else { return event }

                let deltaY = event.scrollingDeltaY
                guard abs(deltaY) > 0.01 else { return event }

                let zoomFactor: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 + deltaY * 0.005 : 1.0 + deltaY * 0.03
                let oldScale = self.isFitMode ? 1.0 : self.viewState.customScale
                let newScale = max(0.25, min(20.0, oldScale * zoomFactor))

                let viewCenter = CGPoint(x: self.viewState.viewSize.width / 2, y: self.viewState.viewSize.height / 2)
                let mouseOff = CGPoint(
                    x: self.viewState.mousePosition.x - viewCenter.x,
                    y: self.viewState.mousePosition.y - viewCenter.y
                )
                let ratio = newScale / oldScale
                let newPanX = self.viewState.panOffset.x * ratio + mouseOff.x * (1 - ratio)
                let newPanY = self.viewState.panOffset.y * ratio + mouseOff.y * (1 - ratio)

                self.viewState.customScale = newScale
                self.viewState.panOffset = CGPoint(x: newPanX, y: newPanY)
                self.viewState.dragStart = self.viewState.panOffset
                self.viewState.zoomPreset = ZoomPreset.fromScale(newScale) ?? .p100
                self.viewState.magnifyBaseScale = newScale
                self.syncSlider()
                // Auto-disable loupe when zoomed >= 100%
                if newScale >= 1.0 && self.viewState.loupeActive {
                    self.viewState.loupeActive = false
                    self.viewState.loupePosition = nil
                    self.viewState.loupeImage = nil
                }

                return nil
            }
        }
        .onDisappear {
            if let monitor = viewState.scrollMonitor {
                NSEvent.removeMonitor(monitor)
                viewState.scrollMonitor = nil
            }
            store.onQuickPreview = nil
        }
        .onChange(of: store.selectedPhotoID) { _, newID in
            guard let newID = newID else { return }
            pendingPhotoID = newID
            hiResWorkItem?.cancel()
            preloadWork?.cancel()

            correctionResult = nil
            isOriginal = true
            rotationAngle = 0
            rotatedImage = nil
            hiResImage = nil
            lowResImage = nil  // Release previous hi-res memory
            // v8.6.2: 빠른 행이동 시 blank 방지 — image 를 nil 로 즉시 리셋하지 않음.
            //   아래 cache lookup 이 성공하면 교체. 실패해도 async 로드 후 교체.
            //   (이전 사진이 잠깐 보이는 게 빈 화면보다 낫다)
            if !store.isKeyRepeat {
                image = nil   // 단일 이동일 때만 즉시 리셋 (메모리 스파이크 방지)
            }
            isHiResLoaded = false
            firstLoadIsPortrait = nil  // v8.6.2: 사진 바뀌면 aspect 기준 리셋
            firstLoadPhotoID = nil
            hiResLoadWork?.cancel()
            // v8.5 — 비파괴 보정 프리뷰 초기화
            developRenderTask?.cancel()
            developedImage = nil
            developedForPhotoID = nil

            // 사진 전환 즉시 hi-res 캐시 사전 purge (memory pressure 대기 X)
            // 현재 선택된 사진을 제외한 나머지는 모두 해제해서 피크 메모리 스파이크 방지
            let currentHiResURL: NSURL? = {
                guard let sel = store.selectedPhoto, !sel.isFolder, !sel.isParentFolder else { return nil }
                let jpgExt = sel.jpgURL.pathExtension.lowercased()
                let hasRealJPG = !FileMatchingService.rawExtensions.contains(jpgExt)
                let hiResURL = hasRealJPG ? sel.jpgURL : (sel.rawURL ?? sel.jpgURL)
                return hiResURL as NSURL
            }()
            Self.purgeHiResCacheExcept(currentURL: currentHiResURL)
            viewState.loupeActive = false
            viewState.loupePosition = nil
            viewState.loupeImage = nil
            viewState.loupeCachedImage = nil
            viewState.loupeCachedURL = nil

            guard let selected = store.selectedPhoto else { return }
            guard !selected.isFolder && !selected.isParentFolder else {
                self.image = nil
                return
            }
            // 비디오 파일: VideoPlayerView가 별도 렌더링 → image state clear해서 이전 이미지 잔상 방지
            // CGImageSource로 MP4 열면 잘못된 프레임이 추출될 수 있음 → 임베디드 썸네일 추출도 스킵
            if selected.isVideoFile {
                self.image = nil
                self.lowResImage = nil
                self.rotatedImage = nil
                imageLoadWork?.cancel()
                hiResWorkItem?.cancel()
                preloadWork?.cancel()
                return
            }
            let url = selected.jpgURL

            // v8.6.2: stableImageSize 를 가장 먼저 업데이트 — 이미지 표시 전에 layout aspect 고정
            //   (이전 사진 image 가 표시되는 동안에도 새 사진의 크기 기반 aspect 로 컨테이너 잡힘)
            viewState.stableImageSize = Self.readImageDimensions(url: url)

            // Fast path: cache hit → show immediately
            let res = store.previewResolution
            let cacheKey = res > 0 ? url.appendingPathExtension("r\(res)") : url.appendingPathExtension("orig")
            if let cached = PreviewImageCache.shared.get(cacheKey) {
                image = cached
                lowResImage = cached
                // 캐시 히트 → 아래 debounce 로직으로 계속 진행 (멈추면 고화질 보장)
            }

            // Show thumbnail instantly while full image loads
            // v8.6.2: 빠른 네비게이션 시 미리보기가 표시 안 되는 문제 대응.
            //   순서: Memory ThumbnailCache → DiskThumbnailCache (빠름) → [비키리피트] CGImage sync
            //   키 꾹 누르기 중에도 디스크 썸네일 히트면 즉시 표시 (blank 방지).
            if let thumb = ThumbnailCache.shared.get(url) {
                image = thumb
            } else if let diskThumb = DiskThumbnailCache.shared.getByPath(url: url) {
                image = diskThumb
                ThumbnailCache.shared.set(url, image: diskThumb)
            } else if !store.isKeyRepeat,
                      let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceThumbnailMaxPixelSize: 800,
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) {
                let img = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
                image = img
                ThumbnailCache.shared.set(url, image: img)
            }

            // 미리보기 로딩 (키 연타 시 디바운스)
            preloadWork?.cancel()
            preloadWork = nil
            imageLoadWork?.cancel()
            hiResWorkItem?.cancel()
            viewState.stableImageSize = Self.readImageDimensions(url: url)

            if store.isKeyRepeat {
                // 빠른 이동 중 → 짧은 디바운스 (캐시 히트만 즉시, 미스는 대기)
                let cacheKey2 = store.previewResolution > 0
                    ? url.appendingPathExtension("r\(store.previewResolution)")
                    : url.appendingPathExtension("orig")
                if let cached = PreviewImageCache.shared.get(cacheKey2) {
                    image = cached
                    lowResImage = cached
                } else if let thumb = ThumbnailCache.shared.get(url) {
                    image = thumb  // 썸네일이라도 즉시 표시
                }

                let delayedWork = DispatchWorkItem {
                    guard self.pendingPhotoID == newID else { return }
                    self.loadImageDirect(for: url, id: newID)
                }
                imageLoadWork = delayedWork
                // ⚠️ main 큐에서 dispatch — loadImageDirect의 캐시 HIT 분기가 self.image를 직접 쓰므로
                // 백그라운드에서 실행 시 SwiftUI @State 업데이트가 누락되어 미리보기가 비어 보임.
                // 무거운 디코드는 loadImageDirect 내부에서 별도 global 큐로 보냄.
                // 디바운스 20ms — 키 떼는 즉시 고화질 로딩 (50ms 체감 지연 제거)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: delayedWork)

                // 빠른 탐색 중 ±3장 임베디드 JPEG 프리페치 (다음 이동 instant hit)
                Self.prefetchEmbeddedNeighbors(store: store, currentURL: url, range: 3)
            } else {
                // 단일 이동 → 즉시 로딩
                loadImageDirect(for: url, id: newID)
            }

            // v8.6.2: hi-res 로딩 지연 800ms → 150ms 로 단축.
            //   이유: loadHiResImage 가 parent CGImageSource 경로로 10배 빨라졌고(1400→140ms),
            //   idle sweep 으로 캐시도 채워지기 때문. 방향키 꾹 누르기엔 hiResWorkItem.cancel() 이
            //   이미 다음 사진 선택 시 호출되어 전작업이 cancel 됨.
            let newURL = url
            let work = DispatchWorkItem {
                guard self.pendingPhotoID == newID else { return }
                self.loadHiResForZoom()
            }
            hiResWorkItem = work
            // hiResCache 에 이미 있으면 debounce 없이 즉시 실행 (표시 지연 0)
            let alreadyCached: Bool = {
                let key = newURL as NSURL
                return Self.hiResCache.object(forKey: key) != nil
            }()
            // v8.6.2: 저사양(8GB) 은 HiRes 지연 400ms — 빠른 네비 중 HiRes 스킵해 CPU 여유 확보
            let tier = SystemSpec.shared.effectiveTier
            let missDelay: TimeInterval = tier == .low ? 0.4 : 0.15
            let delay: TimeInterval = alreadyCached ? 0.0 : missDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in zoomIn() }
        .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in zoomOut() }
        .onChange(of: viewState.zoomPreset) { _, newPreset in
            if newPreset == .fit {
                switchToLowRes()
            }
        }
        // v8.5 — 원본 image 가 로드되면 비파괴 보정 프리뷰 갱신
        .onChange(of: image) { _, _ in refreshDevelopedImage() }
        // 보정값이 외부(슬라이더 등)에서 바뀌면 즉시 반영
        .onReceive(DevelopStore.shared.objectWillChange) { _ in
            // objectWillChange 는 변경 직전 발행 → 다음 runloop 에서 읽어야 반영됨
            DispatchQueue.main.async { refreshDevelopedImage() }
        }
        // C 키 — 크롭 모드 토글
        .onReceive(NotificationCenter.default.publisher(for: .toggleCropMode)) { _ in
            guard !photo.isFolder, !photo.isParentFolder, !photo.isVideoFile else { return }
            isCroppingMode.toggle()
        }
        // 크롭 모드 진입/종료 시 프리뷰 재렌더 (회전/크롭 적용 여부 달라짐)
        .onChange(of: isCroppingMode) { _, _ in refreshDevelopedImage() }
        // 보정 토스트 (object: String)
        .onReceive(NotificationCenter.default.publisher(for: .pickShotAdjustmentToast)) { notif in
            guard let msg = notif.object as? String else { return }
            withAnimation(.easeOut(duration: 0.22)) { adjustmentToast = msg }
            adjustmentToastTask?.cancel()
            adjustmentToastTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    withAnimation(.easeIn(duration: 0.2)) { adjustmentToast = nil }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleHistogram)) { _ in showHistogram.toggle() }
        // v8.6.2: 일괄 회전 알림 — 현재 선택된 사진이 회전 대상에 포함되면 강제 재로드
        .onReceive(NotificationCenter.default.publisher(for: AsyncThumbnailView.rotationInvalidateNotification)) { note in
            guard let rotatedURL = note.object as? URL else { return }
            guard let sel = store.selectedPhoto else { return }
            if rotatedURL == sel.jpgURL || rotatedURL == sel.rawURL || rotatedURL == sel.displayURL {
                // 내부 상태 리셋 → loadImageDirect 재실행
                image = nil
                lowResImage = nil
                rotatedImage = nil
                developedImage = nil
                loadImageDirect(for: sel.jpgURL, id: sel.id)
            }
        }
        .sheet(isPresented: $showAIResult) {
            VStack(alignment: .leading, spacing: 12) {
                Text(aiResultText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    if correctionResult?.savedJPGURL != nil {
                        Button("폴더 열기") {
                            if let dir = correctionResult?.savedJPGURL?.deletingLastPathComponent() {
                                NSWorkspace.shared.open(dir)
                            }
                            showAIResult = false
                        }
                        .help("보정된 파일 폴더 열기")
                    }
                    Spacer()
                    Button("확인") { showAIResult = false }
                        .buttonStyle(.borderedProminent)
                        .help("결과 창 닫기")
                }
            }
            .padding(20)
            .frame(width: 400, height: 300)
        }
    }

    // MARK: - Pan Clamping

    private func clampPan(pan: CGPoint, scaledSize: CGSize, viewSize: CGSize) -> CGPoint {
        let maxX = max(0, (scaledSize.width - viewSize.width) / 2)
        let maxY = max(0, (scaledSize.height - viewSize.height) / 2)
        return CGPoint(
            x: max(-maxX, min(maxX, pan.x)),
            y: max(-maxY, min(maxY, pan.y))
        )
    }

    // MARK: - Zoom Bar

    // Slider value: 0~1 mapped to log scale for smooth zoom feel
    @State private var sliderValue: Double = 0

    // MARK: - Correction Bar

    private var correctionBar: some View {
        HStack(spacing: 8) {
            // 수평/수직 보정 — 추후 활성화 예정
            // Menu { ... } label: { Label("수평/수직", systemImage: "level") }

            // 보정 전후 비교 + 저장
            if correctionResult != nil {
                Divider().frame(height: 20)

                // 보정 정보 표시
                if let angle = correctionResult?.horizonAngle, angle != 0 {
                    Text("\(String(format: "%.1f", angle))°")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                }

                // 원본/보정 토글
                Button(action: {
                    if isOriginal {
                        if let img = correctionResult?.correctedImage {
                            image = img
                            isOriginal = false
                        }
                    } else {
                        loadImage(for: photo.jpgURL)
                        isOriginal = true
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isOriginal ? "eye" : "eye.fill")
                            .font(.system(size: 11))
                        Text(isOriginal ? "원본 보는 중" : "보정 보는 중")
                            .font(.system(size: AppTheme.fontBody, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: AppTheme.buttonHeight)
                .foregroundColor(.white)
                .background(isOriginal ? Color.gray.opacity(0.6) : Color.blue.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("클릭하여 원본/보정 전환")

                // 저장 버튼
                Button(action: { saveCorrectedImage() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 11))
                        Text("JPG 저장")
                            .font(.system(size: AppTheme.fontBody, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: AppTheme.buttonHeight)
                .foregroundColor(.white)
                .background(Color.orange.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("보정된 사진을 JPG로 저장 (원본 옆에 _corrected 파일 생성)")

                // 되돌리기
                Button(action: {
                    correctionResult = nil
                    loadImage(for: photo.jpgURL)
                    isOriginal = true
                }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .frame(height: AppTheme.buttonHeight)
                .foregroundColor(.white)
                .background(Color.red.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("보정 취소")
            }

            if isCorrecting {
                ProgressView()
                    .scaleEffect(0.5)
            }
        }
        .padding(.horizontal, 8)
    }

    private func saveCorrectedImage() {
        guard let img = correctionResult?.correctedImage else { return }
        if let savedURL = ImageCorrectionService.saveCorrected(image: img, originalURL: photo.jpgURL) {
            NSWorkspace.shared.activateFileViewerSelecting([savedURL])
        }
    }

    @ViewBuilder
    private var previewBgMenu: some View {
        Button { store.previewBgMode = "default" } label: {
            Label("디폴트", systemImage: store.previewBgMode == "default" ? "checkmark" : "")
        }
        Divider()
        Button { store.previewBgMode = "black" } label: {
            Label("검정 계열", systemImage: store.previewBgMode == "black" ? "checkmark" : "")
        }
        Button { store.previewBgMode = "white" } label: {
            Label("흰색 계열", systemImage: store.previewBgMode == "white" ? "checkmark" : "")
        }
        Button { store.previewBgMode = "darkGray" } label: {
            Label("다크 그레이", systemImage: store.previewBgMode == "darkGray" ? "checkmark" : "")
        }
        Button { store.previewBgMode = "mediumGray" } label: {
            Label("미디엄 그레이", systemImage: store.previewBgMode == "mediumGray" ? "checkmark" : "")
        }
        Button { store.previewBgMode = "lightGray" } label: {
            Label("라이트 그레이", systemImage: store.previewBgMode == "lightGray" ? "checkmark" : "")
        }
        Divider()
        Button {
            store.previewBgMode = "custom"
            showColorPicker = true
        } label: {
            Label("커스텀 컬러...", systemImage: store.previewBgMode == "custom" ? "checkmark" : "")
        }
    }

    private var zoomBar: some View {
        HStack(spacing: 6) {
            Spacer()
            // Current zoom percentage
            Text(currentZoomText)
                .font(.system(size: AppTheme.fontBody, weight: .semibold, design: .monospaced))
                .foregroundColor(.accentColor)
                .frame(width: 50, alignment: .trailing)

            // Zoom out
            Button(action: { zoomOut() }) {
                Image(systemName: "minus")
                    .font(.system(size: AppTheme.iconSmall, weight: .bold))
                    .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(AppTheme.toolbarButtonBg)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("축소 (Cmd-)")

            // Zoom slider
            Slider(value: $sliderValue, in: 0...1)
                .frame(minWidth: 60, maxWidth: 120)
                .controlSize(.small)
                .help("확대/축소 (더블클릭: 화면 맞춤)")
                .onChange(of: sliderValue) { _, newVal in
                    let scale = sliderToScale(newVal)
                    viewState.customScale = scale
                    if abs(scale - currentFitScale()) < 0.02 {
                        viewState.zoomPreset = .fit
                    } else {
                        viewState.zoomPreset = ZoomPreset.fromScale(scale) ?? .p100
                        // 확대 시 고화질 로딩 (debounce)
                        hiResWorkItem?.cancel()
                        let work = DispatchWorkItem { loadHiResForZoom() }
                        hiResWorkItem = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                    }
                }
                .onTapGesture(count: 2) {
                    setZoom(.fit)
                    syncSlider()
                }

            // Zoom in
            Button(action: { zoomIn() }) {
                Image(systemName: "plus")
                    .font(.system(size: AppTheme.iconSmall, weight: .bold))
                    .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(AppTheme.toolbarButtonBg)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("확대 (Cmd+)")

            // Fit button
            Button(action: { setZoom(.fit); syncSlider() }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                    Text("맞춤")
                        .font(.system(size: AppTheme.fontBody, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: AppTheme.buttonHeight)
            .foregroundColor(isFitMode ? .white : .primary)
            .background(isFitMode ? Color.accentColor : AppTheme.toolbarButtonBg)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("화면 맞춤 (Cmd+0)")

        }
        .padding(.horizontal, 8)
        .onAppear { syncSlider() }
    }

    private var currentZoomText: String {
        isFitMode ? "맞춤" : "\(Int(viewState.customScale * 100))%"
    }

    // Log scale mapping: slider 0~1 → scale 0.25~20.0
    private func sliderToScale(_ val: Double) -> CGFloat {
        // log mapping: 0.25 * (80 ^ val) gives 0.25 at 0, 20.0 at 1
        CGFloat(0.25 * pow(80.0, val))
    }

    private func scaleToSlider(_ scale: CGFloat) -> Double {
        // inverse: val = log(scale/0.25) / log(80)
        guard scale > 0 else { return 0 }
        return log(Double(scale) / 0.25) / log(80.0)
    }

    private func syncSlider() {
        let scale = isFitMode ? currentFitScale() : viewState.customScale
        sliderValue = scaleToSlider(scale)
    }

    // MARK: - Zoom Actions

    private func setZoom(_ preset: ZoomPreset) {
        viewState.zoomPreset = preset
        if let scale = preset.scale {
            viewState.customScale = scale
        }
        viewState.panOffset = .zero
        viewState.dragStart = .zero
        syncSlider()
    }

    func zoomIn() {
        let steps: [CGFloat] = [0.25, 0.50, 0.75, 1.0, 1.5, 2.0, 5.0, 10.0, 20.0]
        let current: CGFloat = isFitMode ? 1.0 : viewState.customScale
        if let next = steps.first(where: { $0 > current + 0.01 }) {
            viewState.customScale = next
            viewState.zoomPreset = ZoomPreset.fromScale(next) ?? .p150
            syncSlider()
            // hi-res debounce (연속 +키 입력 시 마지막만 실행)
            hiResWorkItem?.cancel()
            let work = DispatchWorkItem { loadHiResForZoom() }
            hiResWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    func zoomOut() {
        let steps: [CGFloat] = [0.25, 0.50, 0.75, 1.0, 1.5, 2.0, 5.0, 10.0, 20.0]
        let current: CGFloat = isFitMode ? 1.0 : viewState.customScale
        print("⚡ [ZOOM OUT] current=\(current) isFit=\(isFitMode)")
        if let prev = steps.last(where: { $0 < current - 0.01 }) {
            print("⚡ [ZOOM OUT] → \(prev)")
            viewState.customScale = prev
            viewState.zoomPreset = ZoomPreset.fromScale(prev) ?? .p75
            viewState.panOffset = .zero
            viewState.dragStart = .zero
            syncSlider()
        }
    }

    private func currentFitScale() -> CGFloat {
        // For slider sync: fit = 1.0 in our scale system
        return 1.0
    }

    // MARK: - Image Loading

    /// Load image at configured resolution
    private func loadImageDirect(for url: URL, id: UUID) {
        let resolution = store.previewResolution
        let fileName = url.lastPathComponent

        // v8.6.2: Nikon NEF+JPG 같은 RAW+JPG 쌍이면 RAW 의 임베디드 JPEG 프리뷰가 훨씬 빠름.
        //   이유: Nikon JPG 는 20-30MB → SubsampleFactor 4로도 풀 스캔 필요.
        //   NEF 의 임베디드 프리뷰(~1616×1080)는 직접 추출 가능 → Strategy 1 로 즉시 리턴.
        //   Cache key 는 원본 url(jpgURL) 기준 유지 → sweep/DevelopStore 와 일관.
        let decodeURL: URL = {
            // selectedPhoto 와 url 이 일치하면 거기서 직접 rawURL 얻기 (선형 탐색 회피)
            if let sel = store.selectedPhoto, sel.jpgURL == url,
               let raw = sel.rawURL, raw != url { return raw }
            // 그 외는 선형 탐색 (prefetch 등)
            for p in store.photos {
                if p.jpgURL == url {
                    if let raw = p.rawURL, raw != url { return raw }
                    break
                }
            }
            return url
        }()
        if decodeURL != url {
            fputs("[LD] RAW-pair decode: \(url.lastPathComponent) → \(decodeURL.lastPathComponent)\n", stderr)
        }

        // Cache key includes resolution
        let cacheKey = resolution > 0 ? url.appendingPathExtension("r\(resolution)") : url.appendingPathExtension("orig")
        if let cached = PreviewImageCache.shared.get(cacheKey) {
            fputs("[LD] HIT \(fileName) \(Int(cached.size.width))x\(Int(cached.size.height))\n", stderr)
            // ⚠️ 메인 스레드 보장 — bg 큐에서 호출 시 @State 업데이트 누락 방지
            if Thread.isMainThread {
                self.image = cached
                self.lowResImage = cached
            } else {
                RunLoop.main.perform(inModes: [.common]) {
                    guard self.pendingPhotoID == id else { return }
                    self.image = cached
                    self.lowResImage = cached
                }
            }
            // 캐시 히트라도 해상도가 낮으면 고화질 계속 로딩
            if cached.size.width > 1500 { return }
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        // Cancel previous loading work
        imageLoadWork?.cancel()
        let work = DispatchWorkItem(qos: .userInitiated) { [self] in
            // v8.6.2: GCD worker 는 autorelease pool 이 없음 → ImageIO autoreleased 객체 누적 방지
            autoreleasepool {
            guard self.pendingPhotoID == id else { return }

            // v8.6.2: decodeURL 기반 분기 (RAW+JPG 쌍이면 RAW 로 디코드해 속도 업)
            let ext = decodeURL.pathExtension.lowercased()
            let isJPG = ["jpg", "jpeg"].contains(ext)

            if isJPG {
                // JPG: load at target resolution
                let targetPx = resolution > 0 ? CGFloat(resolution) : 0
                let img: NSImage?
                if targetPx == 0 {
                    img = NSImage(contentsOf: decodeURL)
                } else {
                    img = PreviewImageCache.loadOptimized(url: decodeURL, maxPixel: targetPx)
                }
                guard let loaded = img, self.pendingPhotoID == id else { return }
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                fputs("[LD] JPG \(fileName) \(Int(loaded.size.width))x\(Int(loaded.size.height)) \(ms)ms\n", stderr)
                PreviewImageCache.shared.set(cacheKey, image: loaded)
                store.notePreviewLoaded(url: url)  // v8.6.2: 진행률 게이지
                // 미리보기 이미지로 썸네일 캐시도 채우기 (디스크 I/O 없이 즉시)
                ThumbnailCache.shared.set(url, image: loaded)
                RunLoop.main.perform(inModes: [.common]) {
                    guard self.pendingPhotoID == id,
                          store.selectedPhoto?.jpgURL == url else { return }
                    self.image = loaded
                    self.lowResImage = loaded
                }
            } else {
                // RAW: 2-stage loading (tier 기반)
                let optimalPx = resolution > 0 ? CGFloat(resolution) : PreviewImageCache.optimalPreviewSize()
                let stage1MaxPx = SystemSpec.shared.previewStage1MaxPixel()

                // Stage 1: Fast load — low: 800px / standard: 1200px / high+: 1600px
                // v8.6.2: decodeURL 사용 (NEF+JPG 쌍이면 NEF 의 임베디드 프리뷰로 고속화)
                let fastImage = PreviewImageCache.loadOptimized(url: decodeURL, maxPixel: min(stage1MaxPx, optimalPx))

                // v8.6.2 fix: loadOptimized 내부의 correctThumbnailOrientationIfNeeded 가 이미
                // 방향 보정을 마친 결과를 리턴. 여기서 또 applyOrientation 을 호출하면 Sony ARW 처럼
                // metadata 해석이 엇갈리는 파일에서 이중 회전이 발생 → 세로 사진이 가로로 뒤집힘.
                _ = fastImage

                guard let fast = fastImage, self.pendingPhotoID == id else { return }
                let ms1 = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                let dinfo = Self.readImageDimensionInfo(url: url)
                fputs("[LD] RAW-S1 \(fileName) loaded=\(Int(fast.size.width))x\(Int(fast.size.height)) raw=\(Int(dinfo?.size.width ?? 0))x\(Int(dinfo?.size.height ?? 0)) orient=\(dinfo?.orientation ?? -1) \(ms1)ms\n", stderr)
                // v8.6.2: Stage 1 aspect 를 이 사진의 기준으로 기록 (후속 로드가 따라갈 목표)
                RunLoop.main.perform(inModes: [.common]) {
                    if self.pendingPhotoID == id {
                        self.firstLoadIsPortrait = fast.size.height > fast.size.width
                        self.firstLoadPhotoID = id
                    }
                }

                // 미리보기 이미지로 썸네일 캐시 채우기
                ThumbnailCache.shared.set(url, image: fast)
                store.notePreviewLoaded(url: url)  // v8.6.2: 진행률 게이지 (RAW Stage1)

                RunLoop.main.perform(inModes: [.common]) {
                    guard self.pendingPhotoID == id,
                          store.selectedPhoto?.jpgURL == url else { return }
                    self.image = fast
                    self.lowResImage = fast
                }

                // Stage 2: Higher res preview (tier 기반)
                // low: 1600px (메모리 ~40% 절감) / standard: 2400px / high: 3200px / extreme: 원본
                // 느린 디스크(HDD/SD/NAS): stage2 스킵 — stage1만으로 충분, 사용자가 줌하면 별도 풀해상도
                guard self.pendingPhotoID == id else { return }
                if store.currentFolderIsSlowDisk {
                    fputs("[LD] RAW-S2 SKIP (slow disk) \(fileName)\n", stderr)
                    PreviewImageCache.shared.set(cacheKey, image: fast)
                    DispatchQueue.main.async {
                        guard self.pendingPhotoID == id else { return }
                        self.scheduleSmartPreload(currentID: id, resolution: resolution)
                    }
                    return
                }
                let stage2MaxPx = SystemSpec.shared.previewStage2MaxPixel()
                let stage2Px: CGFloat = stage2MaxPx == 0 ? optimalPx : stage2MaxPx
                if stage2Px > stage1MaxPx, let hr = PreviewImageCache.loadOptimized(url: decodeURL, maxPixel: stage2Px) {
                    let hrAfterEnforce = Self.enforceAspectOfStage1(hr, url: url, stage1Portrait: self.firstLoadIsPortrait)
                    let finalHR = hrAfterEnforce
                    fputs("[LD] RAW-S2 \(fileName) loaded=\(Int(hr.size.width))x\(Int(hr.size.height)) → \(Int(finalHR.size.width))x\(Int(finalHR.size.height)) stage2Px=\(Int(stage2Px))\n", stderr)
                    guard self.pendingPhotoID == id else { return }
                    PreviewImageCache.shared.set(cacheKey, image: finalHR)
                    RunLoop.main.perform(inModes: [.common]) {
                        if self.pendingPhotoID == id {
                            self.image = finalHR
                            self.lowResImage = finalHR
                        }
                    }
                } else {
                    PreviewImageCache.shared.set(cacheKey, image: fast)
                }
            }

            // Prefetch neighbors for instant navigation
            DispatchQueue.main.async {
                guard self.pendingPhotoID == id else { return }
                self.scheduleSmartPreload(currentID: id, resolution: resolution)
            }
            }  // autoreleasepool end (v8.6.2)
        }
        imageLoadWork = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    private func loadImage(for url: URL) {
        loadImageDirect(for: url, id: pendingPhotoID ?? UUID())
    }

    // MARK: - Crop overlay builder (type-checker 폭주 방지용 분리)

    @ViewBuilder
    private func cropOverlayIfNeeded(vSize: CGSize, image: NSImage) -> some View {
        if isCroppingMode && !photo.isFolder && !photo.isParentFolder && !photo.isVideoFile {
            cropModeLayer(vSize: vSize, image: image)
        } else {
            EmptyView()
        }
    }

    private func cropModeLayer(vSize: CGSize, image: NSImage) -> some View {
        // v8.6.1: AppKit NSCropView 기반 — 이미지와 크롭 박스를 단일 NSView draw() 로
        // 픽셀 단위 렌더. SwiftUI aspect fit 레이아웃 오차 원천 차단.
        // (기존에 SwiftUI ZStack 에서 수동 fit 계산 + 별도 Image + InlineCropOverlay 로 분리했던
        //  iter1~22 전부 불필요 — NSCropView 가 내부에서 직접 처리.)
        InlineCropOverlay(
            photoURL: photo.jpgURL,
            image: image,
            onDismiss: { isCroppingMode = false }
        )
        .frame(width: vSize.width, height: vSize.height)
        .allowsHitTesting(true)
    }

    // MARK: - Non-Destructive Develop (v8.5)

    /// 현재 사진의 DevelopSettings 를 읽고, 필요하면 비동기 렌더링해 `developedImage` 업데이트.
    /// 설정이 기본값이면 developedImage 를 nil 로 설정 (원본 표시).
    ///
    /// v8.6 — 슬라이더 반응성을 위해 디바운스 150ms + 저해상도 프록시 (1024).
    /// 크롭 모드 중엔 rotation/cropRect 적용 안 함 (오버레이가 시각 처리).
    private func refreshDevelopedImage() {
        // 기존 디바운스/작업 취소
        developRenderDebounce?.cancel()
        developRenderTask?.cancel()

        let url = photo.jpgURL
        let photoID = photo.id
        var settings = DevelopStore.shared.get(for: url)

        // 크롭 모드 중엔 회전/크롭 프리뷰 적용 안 함 — 오버레이가 정확히 정렬되도록
        let cropMode = isCroppingMode
        if cropMode {
            settings.cropRotation = 0
            settings.cropRect = nil
        }

        // 보정 없음 → 원본 사용
        if settings.isDefault {
            if developedImage != nil {
                developedImage = nil
                developedForPhotoID = nil
            }
            return
        }

        // v8.6.2: 2단계 렌더링 (라이트룸 스타일)
        //   1) 빠른 프리뷰: Stage 1 NSImage 기반 CI 필터 (~20-50ms, 즉시 반응)
        //   2) 고품질: CIRAWFilter 기반 (300ms idle 뒤 실행, JPG→RAW 품질 업그레이드)

        let baseImage = self.image  // 현재 표시 중인 Stage 1/2 NSImage 캡처

        // Step 1: 빠른 프리뷰 — 즉시 실행 (debounce X, 이전 fast task 는 취소)
        if let base = baseImage {
            let fastTask = Task.detached(priority: .userInteractive) { [url, settings] in
                let t0 = CFAbsoluteTimeGetCurrent()
                let quick = Self.developPipelineShared.renderFast(baseImage: base, settings: settings)
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                fputs("[DEV-FAST] \(url.lastPathComponent) \(quick == nil ? "FAILED" : "OK") \(ms)ms\n", stderr)
                await MainActor.run {
                    guard self.photo.id == photoID else { return }
                    guard let quick = quick else { return }
                    let aligned = Self.enforceAspectOfStage1(quick, url: url, stage1Portrait: self.firstLoadIsPortrait)
                    self.developedImage = aligned
                    self.developedForPhotoID = photoID
                }
            }
            developRenderTask = fastTask
        }

        // Step 2: 고품질 follow-up — 300ms idle 뒤 CIRAWFilter 기반 재렌더
        let work = DispatchWorkItem { [settings] in
            fputs("[DEV-QUALITY] refresh — \(url.lastPathComponent) exp=\(settings.exposure) temp=\(settings.temperature)\n", stderr)
            let previewSize = CGSize(width: 1400, height: 1000)
            let task = Task.detached(priority: .userInitiated) { [url, settings, previewSize] in
                let t0 = CFAbsoluteTimeGetCurrent()
                let rendered = Self.developPipelineShared.render(
                    url: url,
                    settings: settings,
                    targetSize: previewSize
                )
                let elapsed = CFAbsoluteTimeGetCurrent() - t0
                fputs("[DEV-QUALITY] rendered \(rendered == nil ? "FAILED" : "OK") in \(String(format: "%.2f", elapsed))s\n", stderr)
                await MainActor.run {
                    guard self.photo.id == photoID else { return }
                    let aligned = rendered.map { Self.enforceAspectOfStage1($0, url: url, stage1Portrait: self.firstLoadIsPortrait) }
                    self.developedImage = aligned
                    self.developedForPhotoID = photoID
                }
            }
            DispatchQueue.main.async { self.developRenderTask = task }
        }
        developRenderDebounce = work
        // 300ms idle — 드래그 끝나고 조용해지면 고품질로 업그레이드
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Schedule smart preload of ±20 neighbors, cancelling any previous batch
    private func scheduleSmartPreload(currentID: UUID, resolution: Int) {
        // v8.6.2 fix: debounce 는 연속 키 입력 중 cancel/reschedule 반복으로 **영원히 실행 안 됨**.
        //   throttle 패턴으로 교체 — 마지막 실행으로부터 200ms 지났으면 즉시 실행.
        //   그리고 실행 시점의 **최신 selectedPhotoID** 를 사용 (currentID 는 stale 일 수 있음).
        let now = Date()
        let throttleInterval: TimeInterval = store.isKeyRepeat ? 0.2 : 0.0
        if now.timeIntervalSince(lastPrefetchScheduled) < throttleInterval {
            return  // 너무 빠름 — 직후 호출에 양보
        }
        lastPrefetchScheduled = now
        preloadWork?.cancel()
        let work = DispatchWorkItem {
            // 실행 시점의 최신 ID 사용
            let latestID = self.pendingPhotoID ?? currentID
            self.preloadNeighborsBatch(currentID: latestID, resolution: resolution)
        }
        preloadWork = work
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    /// Preload neighbors into PreviewImageCache with smart resolution selection.
    /// v8.6.2: 열/행 이동 모두 cover — ±10 순차(열) + ±cols*5 행 방향(행) 프리페치.
    private func preloadNeighborsBatch(currentID: UUID, resolution: Int) {
        let photos = store.filteredPhotos
        // v8.6.2: O(n) firstIndex → O(1) _filteredIndex dict (하위폴더 포함 10k 폴더 대응)
        store.ensureFilteredIndex()
        guard let currentIdx = store._filteredIndex[currentID] else { return }
        let cols = max(1, store.actualColumnsPerRow)

        // v8.6.2: 저사양(8GB M1)에선 프리페치 범위 축소 → CPU 과포화 방지.
        //   - low: 열 ±5 + 행 ±2cols  (약 14장)
        //   - standard+: 열 ±10 + 행 ±5cols (약 30-40장)
        let tier = SystemSpec.shared.effectiveTier
        let colRange = tier == .low ? 5 : 10
        let rowMult = tier == .low ? 2 : 5

        // 수집 대상 오프셋 집합 (중복 제거용 Set)
        var offsets = Set<Int>()
        for o in 1...colRange { offsets.insert(o); offsets.insert(-o) }
        for k in 1...rowMult {
            offsets.insert(cols * k)
            offsets.insert(-cols * k)
        }

        // 가까운 거리 우선 (|offset| 작은 순) — preview cache 에 먼저 들어가서 즉시 사용 가능
        var entries: [(url: URL, isRAW: Bool)] = []
        for offset in offsets.sorted(by: { abs($0) < abs($1) }) {
            let idx = currentIdx + offset
            guard idx >= 0 && idx < photos.count else { continue }
            let p = photos[idx]
            guard !p.isFolder && !p.isParentFolder else { continue }
            let url = p.jpgURL
            let ext = url.pathExtension.lowercased()
            let isRAW = FileMatchingService.rawExtensions.contains(ext)
            entries.append((url: url, isRAW: isRAW))
        }

        let cache = PreviewImageCache.shared
        for entry in entries {
            // autoreleasepool 로 엔트리마다 CGImageSource/NSImage 임시 객체 즉시 해제
            // 이게 없으면 key repeat 꾹 누르기 시 preview 객체가 쌓여 RAM 폭발 (이동당 ~20MB)
            autoreleasepool {
                // v8.6.2 fix: 기존 `pendingPhotoID != currentID` 체크는 key repeat 중 거의 항상 true 가 되어
                //   prefetch 가 첫 entry 에서 exit → 실질 preload 0 개. 제거하고 cache-check 만 사용.
                //   (이미 캐시에 있으면 skip 되므로 선택 변경 후 무의미한 로드는 최소화됨)

                // v8.6.2 CRITICAL FIX: cacheKey 포맷을 loadImageDirect 와 정확히 일치시킴.
                //   이전엔 `path.__cache_r1200` 에 저장 vs 실제 읽기 `path.r1000` → 100% 버려짐.
                //   저장: url.appendingPathExtension("r\(resolution)")  또는  ".orig"
                let cacheKey = resolution > 0
                    ? entry.url.appendingPathExtension("r\(resolution)")
                    : entry.url.appendingPathExtension("orig")

                // Skip if already cached (RAM or disk)
                if cache.has(cacheKey) { return }

                // 디코드 해상도: 실제 미리보기 경로와 동일하게 resolution 사용 (RAW/JPG 구분 없이)
                //   - resolution=1000 이면 stage1 최대 1000px
                //   - loadOptimized 가 RAW 임베디드/JPG SubsampleFactor 자동 선택
                let maxPx = resolution > 0 ? CGFloat(resolution) : PreviewImageCache.optimalPreviewSize()

                // v8.6.2: RAW+JPG 쌍에선 RAW 임베디드 프리뷰로 디코드 (loadImageDirect 와 동일 정책)
                let decodeURL: URL = {
                    if entry.isRAW { return entry.url }
                    // JPG 에 RAW 형제가 있으면 RAW 로
                    if let idx = store._filteredIndex[currentID] {
                        _ = idx  // unused
                    }
                    // 간단히: 파일명 매칭으로 RAW 찾기
                    for p in store.photos {
                        if p.jpgURL == entry.url {
                            if let raw = p.rawURL, raw != entry.url { return raw }
                            break
                        }
                    }
                    return entry.url
                }()

                if let img = PreviewImageCache.loadOptimized(url: decodeURL, maxPixel: maxPx) {
                    cache.set(cacheKey, image: img)
                }
            }
        }
    }

    private func applyAutoUpright(mode: UprightMode) {
        isCorrecting = true
        let url = photo.jpgURL

        DispatchQueue.global(qos: .userInitiated).async {
            // CIImage로 각도 감지
            guard let ciImage = CIImage(contentsOf: url) else {
                DispatchQueue.main.async { isCorrecting = false }
                return
            }

            let (_, angle, applied) = PerspectiveCorrectionService.autoUpright(image: ciImage, mode: mode)

            guard applied, angle > 0.2 else {
                DispatchQueue.main.async {
                    isCorrecting = false
                    fputs("[Upright] 보정 불필요 — 스킵\n", stderr)
                }
                return
            }

            // NSImage 직접 회전 — 색공간 변환 없이 원본 색감 100% 유지
            guard let originalNSImage = NSImage(contentsOf: url) else {
                DispatchQueue.main.async { isCorrecting = false }
                return
            }

            let rotatedImg = Self.rotateNSImage(originalNSImage, degrees: -angle)

            DispatchQueue.main.async {
                isCorrecting = false
                correctionResult = CorrectionResult(correctedImage: rotatedImg, horizonAngle: angle, applied: ["수평/수직 보정 (\(String(format: "%.1f", angle))°)"])
                image = rotatedImg
                isOriginal = false
            }
        }
    }

    /// NSImage 직접 회전 + 자동 크롭 (색공간 변환 없음)
    private static func rotateNSImage(_ img: NSImage, degrees: Double) -> NSImage {
        let rads = CGFloat(degrees * .pi / 180.0)
        let origSize = img.size

        // 회전 후 바운딩 박스 (현재 미사용 — 크롭은 원본 aspect 기반)
        let cosA = abs(cos(rads))
        let sinA = abs(sin(rads))
        _ = origSize.width * cosA + origSize.height * sinA
        _ = origSize.height * cosA + origSize.width * sinA

        // 검은 영역 없는 최대 크롭 사각형 (원본 종횡비 유지)
        let aspect = origSize.width / origSize.height
        let cropW: CGFloat
        let cropH: CGFloat
        let innerW = origSize.width * cosA - origSize.height * sinA
        let innerH = origSize.height * cosA - origSize.width * sinA
        if innerW > 0 && innerH > 0 {
            if innerW / innerH > aspect {
                cropH = innerH; cropW = cropH * aspect
            } else {
                cropW = innerW; cropH = cropW / aspect
            }
        } else {
            let margin = abs(tan(rads)) * min(origSize.width, origSize.height) * 0.5
            cropW = origSize.width - margin * 2
            cropH = origSize.height - margin * 2
        }

        let result = NSImage(size: NSSize(width: cropW, height: cropH))
        result.lockFocus()

        let ctx = NSGraphicsContext.current!
        ctx.imageInterpolation = .high

        // 중앙으로 이동 → 회전 → 다시 이동
        let transform = NSAffineTransform()
        transform.translateX(by: cropW / 2, yBy: cropH / 2)
        transform.rotate(byRadians: rads)
        transform.translateX(by: -origSize.width / 2, yBy: -origSize.height / 2)
        transform.concat()

        img.draw(in: NSRect(origin: .zero, size: origSize),
                 from: NSRect(origin: .zero, size: origSize),
                 operation: .copy, fraction: 1.0)

        result.unlockFocus()
        return result
    }

    private func applyAICorrection() {
        isCorrecting = true
        let currentPhoto = photo
        let url = currentPhoto.jpgURL

        Task {
            do {
                // Step 1: Ask AI for correction values
                let values = try await ClaudeVisionService.getAICorrectionValues(url: url)

                // Step 2: Apply corrections to JPG using Core Image
                let result = ClaudeVisionService.applyAICorrection(url: url, values: values, photo: currentPhoto)

                // Step 3: Build result summary
                let cost = APIUsageTracker.shared.estimatedCostUSD
                var summary = "🤖 AI 보정 완료\n\n"
                summary += "📷 \(currentPhoto.fileName)\n"
                summary += "━━━━━━━━━━━━━━━━\n"
                for item in result.applied {
                    summary += "✓ \(item)\n"
                }
                summary += "━━━━━━━━━━━━━━━━\n"
                if let jpg = result.savedJPGURL {
                    summary += "💾 JPG: 자동보정/\(jpg.lastPathComponent)\n"
                }
                if let raw = result.savedRAWURL {
                    summary += "💾 RAW: 자동보정/\(raw.lastPathComponent)\n"
                }
                summary += "\n💰 API 비용: $\(String(format: "%.3f", cost))"

                await MainActor.run {
                    correctionResult = result
                    if let img = result.correctedImage {
                        image = img
                        isOriginal = false
                    }
                    isCorrecting = false
                    aiResultText = summary
                    showAIResult = true
                }
            } catch {
                await MainActor.run {
                    isCorrecting = false
                    aiResultText = "❌ AI 보정 실패: \(error.localizedDescription)\n\nAPI 키와 잔액을 확인하세요."
                    showAIResult = true
                }
            }
        }
    }

    // MARK: - NPU 보정 모드
    enum NPUCorrectionMode {
        case aiEnhance      // AI 톤/색감 자동 보정
        case denoise        // 디노이즈
        case personAware    // 인물 인식 보정
    }

    private func applyNPUCorrection(mode: NPUCorrectionMode) {
        isCorrecting = true
        let url = photo.jpgURL

        DispatchQueue.global(qos: .userInitiated).async {
            guard let ciImage = CIImage(contentsOf: url) else {
                DispatchQueue.main.async { isCorrecting = false }
                return
            }

            let result: CIImage
            let label: String
            switch mode {
            case .aiEnhance:
                result = AIEnhanceService.enhance(image: ciImage)
                label = "AI 보정"
            case .denoise:
                result = AIEnhanceService.denoise(image: ciImage, strength: 0.5)
                label = "디노이즈"
            case .personAware:
                result = AIEnhanceService.enhanceWithPersonMask(image: ciImage)
                label = "인물 인식 보정"
            }

            let ctx = CIContext(options: [.useSoftwareRenderer: false])
            guard let cgImg = ctx.createCGImage(result, from: result.extent) else {
                DispatchQueue.main.async { isCorrecting = false }
                return
            }
            let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))

            DispatchQueue.main.async {
                image = nsImg
                isOriginal = false
                isCorrecting = false
                // 원본/보정 토글 활성화 (되돌리기 가능)
                correctionResult = CorrectionResult(correctedImage: nsImg, applied: [label])
            }
        }
    }

    private func applyRotation(degrees: Double) {
        guard let selected = store.selectedPhoto else { return }
        let fileURL = selected.jpgURL
        let ext = fileURL.pathExtension.lowercased()
        let isJPEG = (ext == "jpg" || ext == "jpeg")

        if isJPEG {
            applyLosslessRotation(fileURL: fileURL, degrees: degrees)
        } else {
            applyPixelRotation(degrees: degrees)
        }
    }

    /// Lossless JPEG rotation by modifying EXIF orientation tag (no re-encoding)
    private func applyLosslessRotation(fileURL: URL, degrees: Double) {
        let clockwise = (degrees == 90 || degrees == -270)

        // Orientation mapping for 90 deg clockwise:  1->6, 2->5, 3->8, 4->7, 5->4, 6->3, 7->2, 8->1
        let cwMap: [Int: Int] = [1:6, 2:5, 3:8, 4:7, 5:4, 6:3, 7:2, 8:1]
        // Orientation mapping for 90 deg counter-clockwise: 1->8, 2->7, 3->6, 4->5, 5->2, 6->1, 7->4, 8->3
        let ccwMap: [Int: Int] = [1:8, 2:7, 3:6, 4:5, 5:2, 6:1, 7:4, 8:3]
        let map = clockwise ? cwMap : ccwMap

        // Read current EXIF orientation from the file
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let currentOrientation = (properties?[kCGImagePropertyOrientation] as? Int) ?? 1
        let newOrientation = map[currentOrientation] ?? (clockwise ? 6 : 8)

        // Get the UTI of the source
        guard let sourceUTI = CGImageSourceGetType(imageSource) else { return }

        // Create destination — write to temp file then replace
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).tmp")

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL, sourceUTI, CGImageSourceGetCount(imageSource), nil
        ) else { return }

        // Copy all images with updated orientation on the first one
        let count = CGImageSourceGetCount(imageSource)
        for i in 0..<count {
            if i == 0 {
                // Merge existing properties with new orientation
                var updatedProps = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
                updatedProps[kCGImagePropertyOrientation] = newOrientation

                // Also update TIFF and EXIF orientation sub-dictionaries
                if var tiffDict = updatedProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiffDict[kCGImagePropertyTIFFOrientation] = newOrientation
                    updatedProps[kCGImagePropertyTIFFDictionary] = tiffDict
                }

                CGImageDestinationAddImageFromSource(destination, imageSource, 0, updatedProps as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(destination, imageSource, i, nil)
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        // Replace original with modified file
        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        // Clear caches and reload the image
        PreviewImageCache.shared.remove(url: fileURL)
        rotationAngle = 0
        rotatedImage = nil

        // Reload the image from disk
        DispatchQueue.global(qos: .userInitiated).async {
            guard let reloaded = NSImage(contentsOf: fileURL) else { return }
            DispatchQueue.main.async {
                self.image = reloaded
                self.lowResImage = reloaded
            }
        }
    }

    /// Fallback: pixel-based rotation for non-JPEG files
    private func applyPixelRotation(degrees: Double) {
        guard let source = rotatedImage ?? image else { return }
        rotationAngle += degrees

        // Reset if back to 0
        if rotationAngle.truncatingRemainder(dividingBy: 360) == 0 {
            rotationAngle = 0
            rotatedImage = nil
            return
        }

        // Rotate the actual image pixels (CGImage 직접 추출 — TIFF 중간 단계 제거)
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
                ?? { guard let t = source.tiffRepresentation, let b = NSBitmapImageRep(data: t) else { return nil }; return b.cgImage }()
        else { return }

        let w = cgImage.width
        let h = cgImage.height
        let isSwap = abs(degrees) == 90 || abs(degrees) == 270
        let outW = isSwap ? h : w
        let outH = isSwap ? w : h

        let radians = degrees * .pi / 180.0
        guard let context = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: cgImage.bitmapInfo.rawValue
        ) else { return }

        context.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        context.rotate(by: CGFloat(radians))
        context.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let rotated = context.makeImage() else { return }
        rotatedImage = NSImage(cgImage: rotated, size: NSSize(width: outW, height: outH))
    }

    // MARK: - Zoom-aware Resolution Switching

    private func switchToLowRes() {
        // v8.6.2: HiRes 이미 로드된 상태에서 fit 으로 돌아갈 때 저해상도로 다운그레이드하지 않음.
        //   이전엔 메모리 절약 목적이었으나 hiResCache LRU 로 이미 관리되므로 화질 유지가 낫다.
        //   진행 중 hiResLoadWork 만 취소 (loaded 가 아니면 불필요한 작업 중단).
        hiResLoadWork?.cancel()
        if !isHiResLoaded, let low = lowResImage {
            image = low
            print("🔍 [ZOOM] low-res restored: \(Int(low.size.width))x\(Int(low.size.height))")
        }
    }

    // MARK: - Hi-Res Cache (for zoom)
    static func clearHiResCache() {
        hiResCacheLock.lock()
        hiResCache.removeAllObjects()
        hiResCacheOrder.removeAll()
        hiResCacheLock.unlock()
    }

    private static var hiResCache = NSCache<NSURL, NSImage>()
    private static var hiResCacheInitialized = false
    private static var hiResMemorySource: DispatchSourceMemoryPressure?
    // 명시적 LRU 추적: NSCache 자동 evict는 타이밍이 늦어서 피크 메모리 스파이크를 막지 못함
    private static var hiResCacheOrder: [NSURL] = []
    private static let hiResCacheLock = NSLock()
    // RAM 기반으로 결정된 countLimit (purgeOldestIfNeeded에서 사용)
    private static var hiResCacheCountLimit: Int = 2

    private static func initHiResCache() {
        guard !hiResCacheInitialized else { return }

        // SystemSpec tier 기반 캐시 사이징 (중앙화 — standard tier = M1 Pro 16GB 타겟)
        let countLimit = SystemSpec.shared.hiResCacheCount()
        let costMB = SystemSpec.shared.hiResCacheCostMB()
        let totalCostLimit = costMB * 1024 * 1024

        hiResCache.countLimit = countLimit
        hiResCache.totalCostLimit = totalCostLimit
        hiResCacheCountLimit = countLimit
        hiResCacheInitialized = true

        let tier = SystemSpec.shared.effectiveTier.rawValue
        let ramGB = SystemSpec.shared.ramGB
        AppLogger.log(.general, "🧠 hiResCache 초기화: tier=\(tier), RAM=\(ramGB)GB, countLimit=\(countLimit), totalCostLimit=\(costMB)MB")

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            hiResCacheLock.lock()
            hiResCache.removeAllObjects()
            hiResCacheOrder.removeAll()
            hiResCacheLock.unlock()
            AppLogger.log(.general, "⚠️ hiResCache cleared due to memory pressure")
        }
        source.resume()
        hiResMemorySource = source
    }

    /// 새 hi-res 이미지 삽입 시 countLimit 초과 전에 oldest 엔트리를 명시적으로 제거.
    /// NSCache의 자동 evict는 타이밍이 느려서 피크 메모리 스파이크를 막지 못하므로 사전에 purge.
    private static func insertHiRes(_ image: NSImage, forKey url: NSURL, cost: Int) {
        hiResCacheLock.lock()
        defer { hiResCacheLock.unlock() }

        // 이미 존재하면 순서 갱신을 위해 기존 엔트리 제거
        if let existingIdx = hiResCacheOrder.firstIndex(of: url) {
            hiResCacheOrder.remove(at: existingIdx)
        }

        // countLimit 도달 시 oldest 수동 제거 (새 삽입 전에)
        while hiResCacheOrder.count >= hiResCacheCountLimit {
            if let oldest = hiResCacheOrder.first {
                hiResCache.removeObject(forKey: oldest)
                hiResCacheOrder.removeFirst()
                AppLogger.log(.general, "♻️ hiResCache 사전 LRU purge: \(oldest.lastPathComponent ?? "?")")
            } else {
                break
            }
        }

        hiResCache.setObject(image, forKey: url, cost: cost)
        hiResCacheOrder.append(url)
    }

    /// 현재 사진을 제외한 모든 hi-res 캐시를 즉시 해제 (사진 전환 시 사전 예방용).
    /// 사후 memory pressure 대응이 아니라 사진이 바뀔 때마다 선제적으로 정리.
    private static func purgeHiResCacheExcept(currentURL: NSURL?) {
        hiResCacheLock.lock()
        defer { hiResCacheLock.unlock() }

        var removedCount = 0
        let toRemove = hiResCacheOrder.filter { $0 != currentURL }
        for url in toRemove {
            hiResCache.removeObject(forKey: url)
            removedCount += 1
        }
        if let current = currentURL {
            hiResCacheOrder = hiResCacheOrder.contains(current) ? [current] : []
        } else {
            hiResCacheOrder.removeAll()
        }

        if removedCount > 0 {
            AppLogger.log(.general, "🧹 hiResCache 사진 전환 purge: \(removedCount)개 해제, 현재=\(currentURL?.lastPathComponent ?? "nil")")
        }
    }

    /// 빠른 탐색 시 ±range 이웃 사진의 임베디드 JPEG 썸네일을 백그라운드에서 미리 추출.
    /// 다음 키 입력 시 ThumbnailCache HIT으로 즉시 표시 (디스크 I/O 회피).
    private static let prefetchQueue = DispatchQueue(label: "preview.prefetch", qos: .userInitiated, attributes: .concurrent)
    private static func prefetchEmbeddedNeighbors(store: PhotoStore, currentURL: URL, range: Int) {
        let photos = store.filteredPhotos
        // v8.6.2: 방향키 꾹 누르기 중 매 호출마다 O(n) 선형 탐색이면 10k 폴더에서 눈에 띄게 느려짐.
        //   selectedPhoto 와 currentURL 이 일치하면 _filteredIndex 에서 O(1) 로, 아니면 폴백으로 선형.
        store.ensureFilteredIndex()
        let curIdx: Int
        if let selID = store.selectedPhotoID,
           let sel = store.selectedPhoto, sel.jpgURL == currentURL,
           let idx = store._filteredIndex[selID] {
            curIdx = idx
        } else if let idx = photos.firstIndex(where: { $0.jpgURL == currentURL }) {
            curIdx = idx
        } else {
            return
        }

        var targets: [URL] = []
        for offset in 1...range {
            for sign in [1, -1] {
                let i = curIdx + sign * offset
                guard i >= 0 && i < photos.count else { continue }
                let p = photos[i]
                guard !p.isFolder && !p.isParentFolder else { continue }
                let url = p.jpgURL
                if ThumbnailCache.shared.get(url) == nil {
                    targets.append(url)
                }
            }
        }

        for url in targets {
            prefetchQueue.async {
                // 이미 채워졌으면 스킵 (race condition 방지)
                if ThumbnailCache.shared.get(url) != nil { return }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceThumbnailMaxPixelSize: 800,
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return }
                let img = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
                ThumbnailCache.shared.set(url, image: img)
            }
        }
    }

    private func loadHiResForZoom() {
        guard let selected = store.selectedPhoto,
              !selected.isFolder, !selected.isParentFolder else { return }
        guard !isHiResLoaded else { return }
        // 보정 적용된 이미지를 원본으로 덮어쓰지 않음
        if !isOriginal { return }

        Self.initHiResCache()

        // Prefer JPG (fast + correct orientation) over RAW
        let jpgExt = selected.jpgURL.pathExtension.lowercased()
        let hasRealJPG = !FileMatchingService.rawExtensions.contains(jpgExt)
        let hiResURL = hasRealJPG ? selected.jpgURL : (selected.rawURL ?? selected.jpgURL)

        if let cached = Self.hiResCache.object(forKey: hiResURL as NSURL) {
            image = cached
            hiResImage = cached
            isHiResLoaded = true
            prefetchHiResNeighbors()  // Prefetch next photos
            return
        }

        // If already have hi-res from this session
        if let hi = hiResImage {
            image = hi
            isHiResLoaded = true
            return
        }

        let url = hiResURL
        let photoID = selected.id
        fputs("[HIRES] url=\(url.lastPathComponent) hasRealJPG=\(hasRealJPG) jpgURL=\(selected.jpgURL.lastPathComponent) rawURL=\(selected.rawURL?.lastPathComponent ?? "nil")\n", stderr)

        hiResLoadWork?.cancel()
        let work = DispatchWorkItem {
            let t0 = CFAbsoluteTimeGetCurrent()
            let hiRes = Self.loadHiResImage(url: url)
            guard self.pendingPhotoID == photoID else { return }

            // v8.6.2 fix: loadHiResImage 경로도 내부에서 orientation 보정.
            // 여기서 중복 applyOrientation 호출 금지 (Sony ARW 이중 회전 버그).
            _ = hiRes

            RunLoop.main.perform(inModes: [.common]) {
                guard self.pendingPhotoID == photoID else { return }
                // 현재 선택된 사진 URL과도 재확인
                guard url == self.store.selectedPhoto?.jpgURL || url == self.store.selectedPhoto?.rawURL else { return }
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                if let rawHi = hiRes {
                    // v8.6.2 debug: NSImage.size vs 실제 픽셀 dimension 일치 확인
                    let rawPxW = rawHi.representations.first?.pixelsWide ?? 0
                    let rawPxH = rawHi.representations.first?.pixelsHigh ?? 0
                    // v8.6.2: Stage 1 aspect 강제 (HiRes 경로에서 가로/세로 뒤집힘 방지)
                    let hi = Self.enforceAspectOfStage1(rawHi, url: url, stage1Portrait: self.firstLoadIsPortrait)
                    let pxW = hi.representations.first?.pixelsWide ?? 0
                    let pxH = hi.representations.first?.pixelsHigh ?? 0
                    fputs("[HIRES] loaded \(url.lastPathComponent) size=\(Int(rawHi.size.width))x\(Int(rawHi.size.height)) px=\(rawPxW)x\(rawPxH) → size=\(Int(hi.size.width))x\(Int(hi.size.height)) px=\(pxW)x\(pxH) in \(String(format: "%.0f", elapsed))ms\n", stderr)
                    let currentSize = max(self.image?.size.width ?? 0, self.image?.size.height ?? 0)
                    let hiResSize = max(hi.size.width, hi.size.height)
                    guard hiResSize > currentSize else {
                        fputs("[HIRES] ⚠️ skip — hi-res \(Int(hiResSize))px < current \(Int(currentSize))px\n", stderr)
                        return
                    }
                    let cost = hi.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 1
                    // 명시적 LRU 사전 purge 후 삽입 (NSCache 자동 evict 타이밍 보완)
                    Self.insertHiRes(hi, forKey: url as NSURL, cost: cost)
                    self.hiResImage = hi
                    self.image = hi
                    self.isHiResLoaded = true
                    // No prefetch — saves memory (each hi-res is ~50MB)
                } else {
                    fputs("[HIRES] FAILED \(url.lastPathComponent) in \(String(format: "%.0f", elapsed))ms\n", stderr)
                    self.isHiResLoaded = true  // 실패해도 재시도 방지
                }
            }
        }
        hiResLoadWork = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    /// Prefetch hi-res for ±2 neighboring photos (background, 메모리 절약)
    private func prefetchHiResNeighbors() {
        let list = store.filteredPhotos
        guard let currentID = store.selectedPhotoID,
              let currentIdx = list.firstIndex(where: { $0.id == currentID }) else { return }

        let range = 2
        let start = max(0, currentIdx - range)
        let end = min(list.count - 1, currentIdx + range)

        DispatchQueue.global(qos: .utility).async {
            for i in start...end {
                if i == currentIdx { continue }
                let photo = list[i]
                guard !photo.isFolder, !photo.isParentFolder else { continue }

                let hasJPG = !FileMatchingService.rawExtensions.contains(photo.jpgURL.pathExtension.lowercased())
                let url = hasJPG ? photo.jpgURL : (photo.rawURL ?? photo.jpgURL)

                // Skip if already cached
                if Self.hiResCache.object(forKey: url as NSURL) != nil { continue }

                // Load hi-res
                let img = Self.loadHiResImage(url: url)
                if let img = img {
                    let cost = img.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 1
                    Self.hiResCache.setObject(img, forKey: url as NSURL, cost: cost)
                }
            }
        }
    }

    /// Static hi-res loader (reusable for prefetch)
    /// v8.6.2: RAW 경로 색감 일치화 — parent CGImageSource + transform=true 를 먼저 시도해서
    /// Display P3 등 ICC 프로파일이 유지되도록. 실패 시만 FFD8 스캔 폴백 (sRGB 로 풀백).
    private static func loadHiResImage(url: URL) -> NSImage? {
        let ext = url.pathExtension.lowercased()
        let isRAW = FileMatchingService.rawExtensions.contains(ext)

        if !isRAW {
            // JPG/PNG: 전체 해상도 로딩. 5MB 이상은 mmap 사용 (디스크 I/O 최적화)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if fileSize > 5_000_000, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                return NSImage(data: data)
            }
            return NSImage(contentsOf: url)
        }

        // v8.6.2: RAW 주경로 — parent CGImageSource 로 고해상도 썸네일 추출 (색 프로파일 + orient 자동 처리)
        // screenPx cap: backingScaleFactor 를 곱하지 않음 — Retina 2x 픽셀은 불필요하게 2배 디코딩 유발
        //   (13"1512px × 2 = 3024 필요치 않음. 1.25 × 논리해상도면 줌 여유 충분)
        //   + origMax 로도 cap (센서 원본보다 크게 요청해봤자 무의미, ImageIO 가 더 느려짐)
        let screenLogicalMax = max(NSScreen.main?.frame.width ?? 1440, NSScreen.main?.frame.height ?? 900)
        let screenPxPrimary = screenLogicalMax * 1.25  // 줌 여유 25% 만
        if let parentSrc = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
            let props = CGImageSourceCopyPropertiesAtIndex(parentSrc, 0, nil) as? [String: Any]
            let origW = props?[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let origH = props?[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            let origMax = max(origW, origH)
            // 센서 raw 보다 크게 요청 금지 (ImageIO 가 상한 넘으면 풀 디코드 시도해서 느려짐)
            let effectiveMaxPx = origMax > 0 ? min(Int(screenPxPrimary), origMax) : Int(screenPxPrimary)
            let opts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: effectiveMaxPx,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(parentSrc, 0, opts as CFDictionary) {
                // 최소 화질 기준: 장변 2000px 이상이면 채택 (그 이하면 FFD8 폴백)
                if max(cg.width, cg.height) >= 2000 {
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
        }

        // 폴백: FFD8 스캔 (parent source 에서 충분한 해상도 얻지 못한 경우에만)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let scanLimit = min(data.count, 15_000_000)  // Scan up to 15MB for embedded JPEG

        // Find ALL FFD8 markers, pick the LARGEST embedded JPEG
        let ffd8: [UInt8] = [0xFF, 0xD8]
        var bestImage: NSImage? = nil
        var bestPixels = 0

        // Cache screen resolution before loop to avoid repeated NSScreen.main access
        let screenPx = max(NSScreen.main?.frame.width ?? 1440, NSScreen.main?.frame.height ?? 900) * (NSScreen.main?.backingScaleFactor ?? 2.0)

        for i in 0..<(scanLimit - 2) {
            guard data[i] == ffd8[0] && data[i + 1] == ffd8[1] else { continue }
            let end = min(i + 10_000_000, data.count)
            let subData = data.subdata(in: i..<end)
            guard let imgSource = CGImageSourceCreateWithData(subData as CFData, nil),
                  CGImageSourceGetCount(imgSource) > 0 else { continue }

            // Check size without full decode
            let props = CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [String: Any]
            let w = props?[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            let pixels = w * h

            // Only decode if this is larger than what we already have
            guard pixels > bestPixels else { continue }

            // DJI DNG 등에서 썸네일 스트립(가로로 이어붙인 이미지) 제외
            // 정상 사진은 가로:세로 비율이 5:1을 초과하지 않음
            let aspectRatio = w > h ? Double(w) / max(Double(h), 1) : Double(h) / max(Double(w), 1)
            if aspectRatio > 4.0 { continue }

            // Limit to screen resolution to save memory (50MP = 200MB, 3600px = 50MB)
            let opts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: Int(screenPx),
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(imgSource, 0, opts as CFDictionary) {
                bestPixels = cgImage.width * cgImage.height
                bestImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                // If we found a really big one (>= 3000px), stop scanning
                if max(cgImage.width, cgImage.height) >= 3000 { break }
            }
        }
        // v8.6.2: Sony ARW 등 embedded JPEG 에 orient 태그가 없는 케이스 대응.
        // 부모 RAW 파일의 main orient 를 읽어 필요 시 회전 적용.
        if let img = bestImage,
           let parentSource = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
            return correctThumbnailOrientationIfNeeded(img, source: parentSource)
        }
        return bestImage
    }

    private func reloadCurrentImage() {
        guard let selected = store.selectedPhoto else { return }
        loadImageDirect(for: selected.jpgURL, id: pendingPhotoID ?? UUID())
    }

    /// Read image pixel dimensions + EXIF orientation from file header only (no decode, very fast).
    /// v8.6.1: orient 도 반환해서 Stage1 하드코딩 `orientation: 6` 이 orient=3/8 파일을 잘못
    /// 회전시키던 깜빡임 버그 수정.
    struct ImageDimensionInfo {
        let size: CGSize       // orientation 적용 후의 display size (5-8 케이스는 swap 됨)
        let orientation: Int   // 1~8 EXIF orientation
    }
    private static var _dimensionCache: [URL: ImageDimensionInfo] = [:]
    private static let _dimensionCacheLock = NSLock()
    private static let maxDimensionCacheSize = 2000
    static func readImageDimensionInfo(url: URL) -> ImageDimensionInfo? {
        _dimensionCacheLock.lock()
        if let cached = _dimensionCache[url] {
            _dimensionCacheLock.unlock()
            return cached
        }
        // Evict oldest entries when cache grows too large
        if _dimensionCache.count > maxDimensionCacheSize {
            let removeCount = maxDimensionCacheSize / 4
            let keys = Array(_dimensionCache.keys.prefix(removeCount))
            for key in keys { _dimensionCache.removeValue(forKey: key) }
        }
        _dimensionCacheLock.unlock()
        // 헤더만 읽기 — ShouldCacheImmediately로 I/O 파이프라인 최적화
        let dimOpts: [NSString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, dimOpts as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int,
              w > 0, h > 0 else { return nil }
        let orient = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        let size: CGSize
        if orient >= 5 && orient <= 8 {
            size = CGSize(width: h, height: w)
        } else {
            size = CGSize(width: w, height: h)
        }
        let info = ImageDimensionInfo(size: size, orientation: orient)
        _dimensionCacheLock.lock()
        _dimensionCache[url] = info
        _dimensionCacheLock.unlock()
        return info
    }

    /// 하위 호환 — 기존 호출처용 (dimension 만 반환).
    private static func readImageDimensions(url: URL) -> CGSize? {
        return readImageDimensionInfo(url: url)?.size
    }

    /// v8.6.1: 삭제된 URL 의 dimension cache 엔트리 제거 (메모리 누수 방지)
    static func invalidateImageDimensions(for url: URL) {
        _dimensionCacheLock.lock()
        _dimensionCache.removeValue(forKey: url)
        _dimensionCacheLock.unlock()
    }

    /// v8.6.1: 삭제된 URL 의 hiRes cache 엔트리 제거 (메모리 누수 방지)
    /// (hi-res 한 장당 50-200MB — 누적되면 치명적)
    static func removeHiResCache(for url: URL) {
        let nsurl = url as NSURL
        hiResCache.removeObject(forKey: nsurl)
        hiResCacheOrder.removeAll { $0.isEqual(nsurl) }
    }

    /// v8.6.1: MemoryLeakTracker HUD 가 hiResCache 엔트리 수 조회.
    static func debugHiResCount() -> Int {
        return hiResCacheOrder.count
    }

    /// v8.6.1: 메모리 긴급 해제 — hiResCache 전체 비우기.
    static func clearAllHiResCache() {
        hiResCache.removeAllObjects()
        hiResCacheOrder.removeAll()
    }

    /// Apply EXIF orientation to an NSImage that lacks proper orientation metadata
    /// Apply EXIF orientation to an NSImage that lacks proper orientation metadata
    /// 원래 CGContext 기반 구현으로 복원 — CIImage.oriented()는 일부 케이스에서 예상과 다른 방향 적용
    /// 썸네일 방향 보정.
    ///
    /// 배경: iOS Photos.app에서 편집 후 저장된 일부 JPEG는 main image의
    /// `kCGImagePropertyOrientation`이 6(CW 90°)로 저장돼 있지만, 파일에 박힌
    /// embedded thumbnail은 "회전 전 landscape" 상태 그대로 박혀있음.
    /// `kCGImageSourceCreateThumbnailWithTransform: true`를 써도 embedded thumbnail
    /// 디코딩 경로에서는 회전이 적용되지 않아 landscape로 반환됨.
    ///
    /// 전략: 썸네일 반환 직후 main image 메타데이터와 aspect를 비교.
    /// - main orientation 적용 후의 display aspect가 썸네일 aspect와 다르면 수동 회전.
    /// - orientation=1 또는 이미 일치하는 경우 no-op (정상 파일 영향 없음).
    static func correctThumbnailOrientationIfNeeded(_ image: NSImage, source: CGImageSource) -> NSImage {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return image }
        let mainOrient = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        guard mainOrient != 1 else { return image }
        let mainPw = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let mainPh = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        guard mainPw > 0, mainPh > 0 else { return image }

        // main image의 "display aspect" (orientation 적용 후)
        let displayLandscape: Bool
        if mainOrient >= 5 && mainOrient <= 8 {
            // orientation 5-8 → width/height가 swap됨 (raw가 landscape면 display는 portrait)
            displayLandscape = mainPh > mainPw
        } else {
            // orientation 1-4 → aspect 그대로
            displayLandscape = mainPw > mainPh
        }
        let thumbLandscape = image.size.width > image.size.height
        if displayLandscape == thumbLandscape { return image }
        // 불일치: transform=true가 적용되지 않은 케이스 → 수동 회전
        return applyOrientation(image, orientation: mainOrient)
    }

    /// v8.6.2: orient 과 raw sensor 치수를 받아 **이미 올바른 방향으로 로드되었는지** 판정.
    ///
    /// EXIF orient 5~8 은 디스플레이 방향이 sensor raw 의 90° 회전이라 w/h 가 swap 된다.
    /// `kCGImageSourceCreateThumbnailWithTransform: true` 로 로드하면 대부분 이미 회전이
    /// 적용돼서 `loaded.size` 가 swap 된 상태로 돌아온다. 이 경우 `applyOrientation` 을
    /// 또 호출하면 90° 더 돌려서 세로 사진이 뒤집히는 원인이 된다.
    /// v8.6.2: Stage 1 이 기록한 `firstLoadIsPortrait` 와 new 가 다르면 EXIF orient 로 강제 회전.
    /// "처음엔 세로로 뜨다가 나중에 가로로 뒤집힘" 버그 차단용.
    /// - Parameters:
    ///   - new: 후속 경로(Stage2/HiRes/developed)의 NSImage
    ///   - url: 원본 파일 (EXIF orient 참조)
    ///   - stage1Portrait: Stage 1 이 기록한 기준 aspect. nil 이면 기준 없음 → 그대로 반환.
    static func enforceAspectOfStage1(_ new: NSImage, url: URL, stage1Portrait: Bool?) -> NSImage {
        guard let stage1Portrait = stage1Portrait else { return new }
        let newPortrait = new.size.height > new.size.width
        guard newPortrait != stage1Portrait else { return new }
        // Mismatch — EXIF orient 으로 회전해서 Stage 1 과 동일한 aspect 를 만든다.
        // orient 없으면 90° (orient 6) 임시 적용.
        let info = readImageDimensionInfo(url: url)
        let orient = (info?.orientation ?? 6) > 1 ? (info?.orientation ?? 6) : 6
        fputs("[LD-ENFORCE] \(url.lastPathComponent) aspect mismatch — new=\(newPortrait ? "P" : "L") stage1=\(stage1Portrait ? "P" : "L") → applyOrientation(\(orient))\n", stderr)
        return applyOrientation(new, orientation: orient)
    }

    static func orientationAlreadyApplied(loadedSize: CGSize, rawSize: CGSize, orientation: Int) -> Bool {
        guard orientation > 1 else { return true }
        let needs90 = (5...8).contains(orientation)
        let rawPortrait = rawSize.height > rawSize.width
        let loadedPortrait = loadedSize.height > loadedSize.width
        // orient 5~8 은 로드된 방향이 raw 와 swap 되어야 정상 (이미 회전 적용됨).
        // orient 2/3/4 (mirror/180°) 는 방향이 유지되어야 정상.
        return needs90 ? (loadedPortrait != rawPortrait) : (loadedPortrait == rawPortrait)
    }

    static func applyOrientation(_ image: NSImage, orientation: Int) -> NSImage {
        return autoreleasepool {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    ?? { guard let t = image.tiffRepresentation, let b = NSBitmapImageRep(data: t) else { return nil }; return b.cgImage }()
            else { return image }
            // v8.6.2 fix: 자체 CGAffineTransform 구현이 orient=8 에서 CCW 대신 CW 를 적용해서
            // 180° 뒤집힘 발생. Apple 검증된 `CIImage.oriented(_:)` 로 교체 (모든 1~8 케이스 처리).
            guard orientation >= 2 && orientation <= 8,
                  let cgOri = CGImagePropertyOrientation(rawValue: UInt32(orientation))
            else { return image }
            let ci = CIImage(cgImage: cgImage).oriented(cgOri)
            // v8.6.2: source CGImage 의 colorSpace 보존해서 Display P3 → sRGB 색 변환 방지.
            let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            let ctx = CIContext(options: [.useSoftwareRenderer: false, .workingColorSpace: cs, .outputColorSpace: cs])
            guard let rotated = ctx.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: cs) else { return image }
            return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
        }
    }

    /// 썸네일/미리보기 orientation 보정 — 현재는 no-op.
    /// 이유: loadOptimized(maxPixel 크게) 경로로 통일하면 CGImageSource가 메인 이미지 preview를
    /// transform=true와 함께 처리해서 대부분 정상. 수동 보정은 오히려 일부 RAW/iPhone JPG의
    /// PixelWidth/Height metadata를 잘못 해석해 정상 이미지를 뒤집는 회귀를 유발함.
    /// 추후 특정 케이스만 확인되면 file-type-specific 보정으로 재활성화.
    static func ensureCorrectOrientation(_ image: NSImage, sourceURL: URL) -> NSImage {
        return image
    }

    // MARK: - Loupe (magnifying bubble at click point)

    /// Generate loupe using normalized coordinates (0~1), independent of displayed image size
    private func generateLoupeNormalized(normalX: CGFloat, normalY: CGFloat) {
        let url = photo.jpgURL

        // Use cached full image if same URL (avoid re-reading from disk every hover)
        if let cached = viewState.loupeCachedImage, viewState.loupeCachedURL == url {
            // Crop directly from cached image (instant - no disk I/O)
            let fullW = CGFloat(cached.width)
            let fullH = CGFloat(cached.height)
            let centerX = normalX * fullW
            let centerY = normalY * fullH
            let cropSize = min(fullW, fullH) * 0.06
            let cropRect = CGRect(
                x: max(0, centerX - cropSize / 2),
                y: max(0, centerY - cropSize / 2),
                width: cropSize,
                height: cropSize
            ).intersection(CGRect(x: 0, y: 0, width: fullW, height: fullH))
            guard !cropRect.isEmpty, let cropped = cached.cropping(to: cropRect) else { return }
            self.viewState.loupeImage = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
            return
        }

        // First time for this photo: load image once and cache
        DispatchQueue.global(qos: .userInteractive).async {
            // Load at reasonable size for loupe (1500px — 메모리 절약, 충분한 디테일)
            let opts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 1500,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return }

            let fullW = CGFloat(cgImage.width)
            let fullH = CGFloat(cgImage.height)
            let centerX = normalX * fullW
            let centerY = normalY * fullH
            let cropSize = min(fullW, fullH) * 0.06
            let cropRect = CGRect(
                x: max(0, centerX - cropSize / 2),
                y: max(0, centerY - cropSize / 2),
                width: cropSize,
                height: cropSize
            ).intersection(CGRect(x: 0, y: 0, width: fullW, height: fullH))
            guard !cropRect.isEmpty, let cropped = cgImage.cropping(to: cropRect) else { return }

            let result = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
            DispatchQueue.main.async {
                self.viewState.loupeCachedImage = cgImage
                self.viewState.loupeCachedURL = url
                self.viewState.loupeImage = result
            }
        }
    }

}

// MARK: - Metadata Overlay (nomacs-style)

struct MetadataOverlayView: View {
    let photo: PhotoItem

    var body: some View {
        VStack {
            // Top row
            HStack(alignment: .top) {
                // Top-left: Camera + Lens
                VStack(alignment: .leading, spacing: 3) {
                    if let model = photo.exifData?.cameraModel {
                        Text(model)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    if let lens = photo.exifData?.lensModel {
                        Text(lens)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    if let place = photo.exifData?.placeName {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                            Text(place)
                                .font(.system(size: 10))
                        }
                    }
                }
                .foregroundColor(.white)
                .padding(8)
                .background(Color.black.opacity(0.75))
                .cornerRadius(6)

                Spacer()

                // Top-right: ISO / Shutter / Aperture / Focal
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 10) {
                        if let iso = photo.exifData?.iso {
                            Text("ISO \(iso)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        if let shutter = photo.exifData?.shutterSpeed {
                            Text(shutter)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                    }
                    HStack(spacing: 10) {
                        if let aperture = photo.exifData?.aperture {
                            Text("f/\(String(format: "%.1f", aperture))")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        if let focal = photo.exifData?.focalLength {
                            Text("\(Int(focal))mm")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                    }
                }
                .foregroundColor(.white)
                .padding(8)
                .background(Color.black.opacity(0.75))
                .cornerRadius(6)
            }
            .padding(10)

            Spacer()

            // Bottom row — 좌: 파일 정보 + 고객 피드백 카드, 우: 여유 공간
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    // 파일명 + 레이팅 + 씬 태그
                    VStack(alignment: .leading, spacing: 3) {
                        Text(photo.fileName)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))

                        StarDisplayView(rating: photo.rating, size: 10, compact: false)

                        if let tag = photo.sceneTag {
                            Text(tag)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.7))
                                .cornerRadius(3)
                        }
                    }
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(6)

                    // 🆕 고객 피드백 카드 — 고객 셀렉/코멘트/펜 있을 때만 표시
                    if photo.clientSelected || !photo.clientComments.isEmpty || photo.clientPenDrawingsJSON != nil {
                        clientFeedbackCard
                    }
                }

                Spacer()
            }
            .padding(10)
        }
    }

    // MARK: - 고객 피드백 카드 (조건부 표시)

    @ViewBuilder
    private var clientFeedbackCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 헤더: 고객 이름 + 뱃지
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(
                        LinearGradient(colors: [.pink, .purple, .blue], startPoint: .leading, endPoint: .trailing)
                    )
                let clientLabel = photo.clientName?.isEmpty == false ? (photo.clientName ?? "고객") : "고객"
                Text("\(clientLabel) 피드백")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [.pink, .purple, .blue], startPoint: .leading, endPoint: .trailing)
                    )

                if photo.clientSelected {
                    Text("✓ 셀렉")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.green.opacity(0.35))
                        .foregroundColor(.green)
                        .cornerRadius(3)
                }
                if photo.clientPenDrawingsJSON != nil {
                    Text("✏️ 펜")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.orange.opacity(0.35))
                        .foregroundColor(.orange)
                        .cornerRadius(3)
                }
            }

            // 코멘트 목록
            if !photo.clientComments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(photo.clientComments.enumerated()), id: \.offset) { _, comment in
                        HStack(alignment: .top, spacing: 5) {
                            Text("💬")
                                .font(.system(size: 10))
                            Text(comment)
                                .font(.system(size: 11))
                                .foregroundColor(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding(8)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.78), Color.purple.opacity(0.25)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    LinearGradient(
                        colors: [.pink.opacity(0.6), .purple.opacity(0.6), .blue.opacity(0.6)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    lineWidth: 1.2
                )
        )
        .cornerRadius(6)
    }
}

// MARK: - Triangle Shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Mini Navigator

struct MiniNavigator: View {
    let image: NSImage
    let imageSize: CGSize
    let scaledSize: CGSize
    let viewSize: CGSize
    @Binding var panOffset: CGPoint
    @Binding var dragStart: CGPoint

    private let navSize: CGFloat = 140

    var body: some View {
        let aspect = imageSize.width / imageSize.height
        let navW = aspect >= 1 ? navSize : navSize * aspect
        let navH = aspect >= 1 ? navSize / aspect : navSize

        let scaleToNav = navW / scaledSize.width
        let scaleFromNav = scaledSize.width / navW

        // Viewport rect in nav coordinates
        let vpW = viewSize.width * scaleToNav
        let vpH = viewSize.height * scaleToNav

        // Center of viewport in image space, then map to nav
        let centerX = (scaledSize.width / 2 - panOffset.x) * scaleToNav
        let centerY = (scaledSize.height / 2 - panOffset.y) * scaleToNav

        let vpX = centerX - vpW / 2
        let vpY = centerY - vpH / 2

        let clampedVpX = max(0, min(vpX, navW - vpW))
        let clampedVpY = max(0, min(vpY, navH - vpH))

        ZStack(alignment: .topLeading) {
            // Thumbnail
            Image(nsImage: image)
                .resizable()
                .frame(width: navW, height: navH)
                .cornerRadius(4)

            // Dim area outside viewport
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: navW, height: navH)
                .cornerRadius(4)

            // Draggable viewport rect
            Rectangle()
                .fill(Color.green.opacity(0.15))
                .frame(width: min(vpW, navW), height: min(vpH, navH))
                .border(Color.green, width: 2)
                .offset(x: clampedVpX, y: clampedVpY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            // Convert drag delta in nav space to image pan space
                            let dx = -value.translation.width * scaleFromNav
                            let dy = -value.translation.height * scaleFromNav
                            let newPan = CGPoint(
                                x: dragStart.x + dx,
                                y: dragStart.y + dy
                            )
                            // Clamp
                            let maxX = max(0, (scaledSize.width - viewSize.width) / 2)
                            let maxY = max(0, (scaledSize.height - viewSize.height) / 2)
                            panOffset = CGPoint(
                                x: max(-maxX, min(maxX, newPan.x)),
                                y: max(-maxY, min(maxY, newPan.y))
                            )
                        }
                        .onEnded { _ in
                            dragStart = panOffset
                        }
                )
                .cursor(.openHand)
        }
        .frame(width: navW, height: navH)
        .contentShape(Rectangle())
        .gesture(
            // Click anywhere on navigator to jump to that position
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let clickX = value.location.x
                    let clickY = value.location.y
                    // Convert click position to pan offset
                    let targetCenterX = clickX * scaleFromNav
                    let targetCenterY = clickY * scaleFromNav
                    let newPanX = scaledSize.width / 2 - targetCenterX
                    let newPanY = scaledSize.height / 2 - targetCenterY
                    let maxX = max(0, (scaledSize.width - viewSize.width) / 2)
                    let maxY = max(0, (scaledSize.height - viewSize.height) / 2)
                    panOffset = CGPoint(
                        x: max(-maxX, min(maxX, newPanX)),
                        y: max(-maxY, min(maxY, newPanY))
                    )
                    dragStart = panOffset
                }
        )
        .background(Color.black.opacity(0.6))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.green.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Correction Options Popover

struct CorrectionOptionsView: View {
    let photo: PhotoItem
    let onApply: (CorrectionResult) -> Void
    @Binding var isCorrecting: Bool

    @State private var options = CorrectionOptions()
    @State private var result: CorrectionResult?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 고정 헤더
            VStack(alignment: .leading, spacing: 4) {
                Text("자동 보정")
                    .font(.system(size: 14, weight: .bold))
                Text(photo.fileName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 8)

            Divider()

            // 스크롤 가능한 옵션 영역
            ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {

            // 수평/수직 보정 + 원근 보정 — 추후 활성화 예정
            // Toggle(isOn: $options.autoHorizon) { ... }
            // Toggle(isOn: $options.autoUpright) { ... }

            Toggle(isOn: $options.faceBalance) {
                HStack(spacing: 8) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 12))
                        .frame(width: 20)
                        .foregroundColor(.pink)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("얼굴 기준 보정")
                            .font(.system(size: 12, weight: .medium))
                        Text("피부톤 기준 화이트밸런스 + 얼굴 밝기 보정")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help("얼굴 피부톤 기준 색감/밝기 자동 보정")

            Toggle(isOn: $options.skinSmoothing) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .frame(width: 20)
                        .foregroundColor(.mint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("피부 스무딩")
                            .font(.system(size: 12, weight: .medium))
                        Text("피부 질감 부드럽게 (인물 사진)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help("High Pass 필터로 피부 부드럽게")

            Toggle(isOn: $options.autoLevel) {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 12))
                        .frame(width: 20)
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("자동 노출 보정")
                            .font(.system(size: 12, weight: .medium))
                        Text("밝기, 톤커브 자동 조정")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help("밝기/톤커브 자동 조정")

            Toggle(isOn: $options.autoWhiteBalance) {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 12))
                        .frame(width: 20)
                        .foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("자동 화이트밸런스")
                            .font(.system(size: 12, weight: .medium))
                        Text("색온도, 틴트 자동 보정")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help("색온도/틴트 자동 보정")

            // MARK: - NPU 고급 보정
            Divider()

            Text("NPU 고급 보정")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            Toggle(isOn: $options.aiEnhance) {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 12))
                        .frame(width: 20)
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AI 보정")
                            .font(.system(size: 12, weight: .medium))
                        Text("NPU 가속 자동 화질 향상")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help("Neural Engine 기반 자동 화질 향상")

            Toggle(isOn: $options.denoise) {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.right")
                        .font(.system(size: 12))
                        .frame(width: 20)
                        .foregroundColor(.teal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("디노이즈")
                            .font(.system(size: 12, weight: .medium))
                        Text("고감도 노이즈 제거")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help("AI 기반 노이즈 제거")

            // 디노이즈 강도 슬라이더 (디노이즈 활성 시에만 표시)
            if options.denoise {
                HStack(spacing: 8) {
                    Spacer()
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("강도")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(options.denoiseStrength * 100))%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $options.denoiseStrength, in: 0...1, step: 0.05)
                            .controlSize(.small)
                    }
                }
                .padding(.leading, 8)
            }

            Toggle(isOn: $options.personAwareEnhance) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.rectangle")
                        .font(.system(size: 12))
                        .frame(width: 20)
                        .foregroundColor(.indigo)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("인물 인식 보정")
                            .font(.system(size: 12, weight: .medium))
                        Text("배경/인물 영역 분리 후 선택적 보정")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help("인물 세그멘테이션 기반 선택적 보정")

            // Result info
            if let r = result {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    if r.applied.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("보정할 항목이 없습니다 (이미 양호)")
                                .font(.caption)
                        }
                    } else {
                        Text("적용된 보정:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(r.applied, id: \.self) { item in
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9))
                                    .foregroundColor(.green)
                                Text(item)
                                    .font(.system(size: 11))
                            }
                        }

                        // Show saved paths
                        if let jpgURL = r.savedJPGURL {
                            Divider()
                            HStack(spacing: 4) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.accentColor)
                                Text("자동보정/\(jpgURL.lastPathComponent)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if let rawURL = r.savedRAWURL {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.green)
                                Text("자동보정/\(rawURL.lastPathComponent)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            }  // VStack (스크롤 내부)
            }  // ScrollView
            .frame(maxHeight: 400)

            Divider()

            HStack {
                Button("닫기") { dismiss() }
                    .font(.caption)
                    .help("보정 패널 닫기")

                Spacer()

                Button(action: { applyCorrection() }) {
                    Label(isCorrecting ? "보정 중..." : "보정 적용", systemImage: "wand.and.rays")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(isCorrecting)
                .help("선택한 옵션으로 보정 적용")
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func applyCorrection() {
        isCorrecting = true
        options.save()  // 체크박스 상태 저장
        let currentPhoto = photo
        let opts = options

        DispatchQueue.global(qos: .userInitiated).async {
            var correctionResult = ImageCorrectionService.autoCorrect(
                url: currentPhoto.jpgURL,
                options: opts
            )

            // Save corrected JPG + copy RAW to "자동보정" folder
            if let correctedImage = correctionResult.correctedImage {
                let saved = ImageCorrectionService.saveWithRAW(image: correctedImage, photo: currentPhoto)
                correctionResult.savedJPGURL = saved.jpgURL
                correctionResult.savedRAWURL = saved.rawURL
            }

            DispatchQueue.main.async {
                if correctionResult.applied.isEmpty {
                    // 보정할 항목 없음
                    correctionResult.applied.append("보정할 항목이 감지되지 않았습니다")
                }
                result = correctionResult
                isCorrecting = false
                if correctionResult.correctedImage != nil {
                    onApply(correctionResult)
                }
            }
        }
    }
}

// MARK: - Batch Correction View

struct BatchCorrectionView: View {
    let photos: [PhotoItem]
    let onComplete: () -> Void
    @EnvironmentObject var store: PhotoStore

    @State private var options = CorrectionOptions()
    @State private var saveMode: SaveMode = .separate
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var completed: Int = 0
    @State private var succeeded: Int = 0
    @State private var failed: Int = 0
    @State private var isDone = false
    @State private var savedFolder: URL?
    @State private var currentFile: String = ""
    @Environment(\.dismiss) var dismiss

    enum SaveMode: String, CaseIterable {
        case separate = "별도 파일 (_corrected)"
        case overwrite = "원본 덮어쓰기"
        case folder = "보정 폴더에 저장"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("일괄 자동 보정")
                .font(.system(size: 14, weight: .bold))

            Text("\(photos.count)장 선택됨")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Divider()

            // 수평/수직 + 원근 보정 — 추후 활성화 예정
            // Toggle(isOn: $options.autoHorizon) { ... }
            // Toggle(isOn: $options.autoUpright) { ... }

            if !AppConfig.hideAIFeatures {
                Toggle(isOn: $options.faceBalance) {
                    Label("얼굴 기준 보정", systemImage: "face.smiling").font(.system(size: 12))
                }.toggleStyle(.checkbox).disabled(isProcessing)
                .help("피부톤 기준 색감/밝기 보정")

                Toggle(isOn: $options.skinSmoothing) {
                    Label("피부 스무딩", systemImage: "sparkles").font(.system(size: 12))
                }.toggleStyle(.checkbox).disabled(isProcessing)
                .help("피부 부드럽게")
            }

            Toggle(isOn: $options.autoLevel) {
                Label("자동 노출 보정", systemImage: "sun.max").font(.system(size: 12))
            }.toggleStyle(.checkbox).disabled(isProcessing)
            .help("밝기/톤커브 자동 조정")

            Toggle(isOn: $options.autoWhiteBalance) {
                Label("자동 화이트밸런스", systemImage: "thermometer.medium").font(.system(size: 12))
            }.toggleStyle(.checkbox).disabled(isProcessing)
            .help("색온도/틴트 자동 보정")

            // NPU 고급 보정 (AI) — 출시 단계에서는 숨김
            if !AppConfig.hideAIFeatures {
                Divider()

                Text("NPU 고급 보정")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Toggle(isOn: $options.aiEnhance) {
                    Label("AI 보정", systemImage: "brain").font(.system(size: 12))
                }.toggleStyle(.checkbox).disabled(isProcessing)
                .help("NPU 가속 자동 화질 향상")

                Toggle(isOn: $options.denoise) {
                    Label("디노이즈", systemImage: "dot.radiowaves.right").font(.system(size: 12))
                }.toggleStyle(.checkbox).disabled(isProcessing)
                .help("AI 기반 노이즈 제거")

                if options.denoise {
                    HStack(spacing: 8) {
                        Spacer().frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("강도")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(options.denoiseStrength * 100))%")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $options.denoiseStrength, in: 0...1, step: 0.05)
                                .controlSize(.small)
                        }
                    }
                    .padding(.leading, 8)
                    .disabled(isProcessing)
                }

                Toggle(isOn: $options.personAwareEnhance) {
                    Label("인물 인식 보정", systemImage: "person.crop.rectangle").font(.system(size: 12))
                }.toggleStyle(.checkbox).disabled(isProcessing)
                .help("인물 세그멘테이션 기반 선택적 보정")
            }

            Divider()

            // Save mode
            Text("저장 방식")
                .font(.system(size: 11, weight: .semibold))
            Picker("", selection: $saveMode) {
                ForEach(SaveMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .font(.system(size: 11))
            .disabled(isProcessing)
            .help("보정 파일 저장 방식 선택")

            Divider()

            // Progress
            if isProcessing || isDone {
                VStack(spacing: 6) {
                    ProgressView(value: progress) {
                        HStack {
                            Text("\(completed)/\(photos.count)장")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }

                    if isProcessing {
                        Text("처리 중: \(currentFile)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if isDone {
                        HStack(spacing: 12) {
                            Label("\(succeeded)장 성공", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                            if failed > 0 {
                                Label("\(failed)장 실패", systemImage: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }

                Divider()
            }

            HStack {
                Button("닫기") { dismiss() }
                    .font(.caption)
                    .help("일괄 보정 패널 닫기")

                Spacer()

                if isDone {
                    if let folder = savedFolder {
                        Button("폴더 열기") {
                            NSWorkspace.shared.open(folder)
                        }
                        .font(.caption)
                        .help("보정된 파일 폴더 열기")
                    }
                    Button("완료") {
                        dismiss()
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help("일괄 보정 완료")
                } else {
                    Button(action: { startBatchCorrection() }) {
                        Label(isProcessing ? "보정 중..." : "일괄 보정 시작 (\(photos.count)장)", systemImage: "wand.and.rays")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isProcessing)
                    .help("선택한 사진 일괄 보정 시작")
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func startBatchCorrection() {
        // If folder mode, ask for destination
        var destFolder: URL?
        if saveMode == .folder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.message = "보정된 사진을 저장할 폴더를 선택하세요"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destFolder = url
            savedFolder = url
        }

        isProcessing = true
        progress = 0
        completed = 0
        succeeded = 0
        failed = 0
        isDone = false

        let batchPhotos = photos
        let total = batchPhotos.count
        let opts = options
        let mode = saveMode

        DispatchQueue.global(qos: .userInitiated).async {
            for (i, photo) in batchPhotos.enumerated() {
                DispatchQueue.main.async {
                    currentFile = photo.fileName
                }

                let result = ImageCorrectionService.autoCorrect(url: photo.jpgURL, options: opts)

                guard let correctedImage = result.correctedImage else {
                    DispatchQueue.main.async { failed += 1 }
                    DispatchQueue.main.async {
                        completed = i + 1
                        progress = Double(i + 1) / Double(total)
                    }
                    continue
                }

                var saveSuccess = false

                switch mode {
                case .separate:
                    // Save as filename_corrected.jpg next to original
                    saveSuccess = ImageCorrectionService.saveCorrected(image: correctedImage, originalURL: photo.jpgURL) != nil
                    if savedFolder == nil { savedFolder = photo.jpgURL.deletingLastPathComponent() }

                case .overwrite:
                    // Overwrite original file
                    saveSuccess = saveOverwrite(image: correctedImage, url: photo.jpgURL)
                    if savedFolder == nil { savedFolder = photo.jpgURL.deletingLastPathComponent() }

                case .folder:
                    // Save to destination folder
                    if let dest = destFolder {
                        let destURL = dest.appendingPathComponent(photo.jpgURL.lastPathComponent)
                        saveSuccess = saveToURL(image: correctedImage, url: destURL)
                    }
                }

                DispatchQueue.main.async {
                    if saveSuccess {
                        succeeded += 1
                        // Mark as corrected in store
                        if let idx = store.photos.firstIndex(where: { $0.id == photo.id }) {
                            store.photos[idx].isCorrected = true
                        }
                    } else {
                        failed += 1
                    }
                    completed = i + 1
                    progress = Double(i + 1) / Double(total)
                }
            }

            DispatchQueue.main.async {
                isProcessing = false
                isDone = true
            }
        }
    }

    /// NSImage → JPEG 직접 변환 (TIFF 중간 단계 제거로 60% 빠름)
    private static func jpegData(from image: NSImage, quality: CGFloat = 0.95) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // fallback: tiffRepresentation
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private func saveOverwrite(image: NSImage, url: URL) -> Bool {
        guard let jpegData = Self.jpegData(from: image) else { return false }
        do {
            try jpegData.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private func saveToURL(image: NSImage, url: URL) -> Bool {
        guard let jpegData = Self.jpegData(from: image) else { return false }
        do {
            try jpegData.write(to: url)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Rotate Toolbar Button (v8.6.2)
// 회전 버튼: 클릭 시 아이콘이 해당 방향으로 90° 스핀 애니메이션 → 즉시 피드백
struct RotateToolbarButton: View {
    let systemImage: String
    let clockwise: Bool
    let action: () -> Void

    @State private var angle: Double = 0
    @State private var pressed: Bool = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                angle += clockwise ? 90 : -90
                pressed = true
            }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeOut(duration: 0.18)) { pressed = false }
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)
                .rotationEffect(.degrees(angle))
                .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                .background(pressed ? Color.accentColor.opacity(0.25) : AppTheme.toolbarButtonBg)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .scaleEffect(pressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .help(clockwise ? "시계방향 90° 회전" : "반시계 90° 회전")
    }
}
