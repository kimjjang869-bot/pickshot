import SwiftUI
import Combine
import CoreImage

extension Notification.Name {
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let toggleHistogram = Notification.Name("toggleHistogram")
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
    private var accessOrder: [URL] = []  // LRU tracking
    private let lock = NSLock()
    private var maxEntries: Int
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let diskCacheDir: URL

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
        diskCacheDir = URL(fileURLWithPath: "/tmp/pickshot_cache")
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)

        // Listen for memory pressure → auto-clear cache
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            self?.clearCache()
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

    func get(_ url: URL) -> NSImage? {
        lock.lock()
        // RAM hit
        if let img = cache[url] {
            // Move to end of access order (most recently used)
            if let idx = accessOrder.firstIndex(of: url) {
                accessOrder.remove(at: idx)
            }
            accessOrder.append(url)
            lock.unlock()
            return img
        }
        lock.unlock()

        // Disk cache hit
        let diskPath = diskKey(for: url)
        if let img = NSImage(contentsOf: diskPath) {
            // Promote back to RAM cache
            set(url, image: img)
            return img
        }
        return nil
    }

    func set(_ url: URL, image: NSImage) {
        lock.lock()
        if cache.count >= maxEntries {
            // Evict oldest ~1/3 entries to disk cache
            let removeCount = maxEntries / 3
            let evictKeys = Array(accessOrder.prefix(removeCount))
            for key in evictKeys {
                if let evictedImg = cache.removeValue(forKey: key) {
                    // Write evicted image to disk asynchronously
                    let diskPath = diskKey(for: key)
                    let capturedImg = evictedImg
                    DispatchQueue.global(qos: .utility).async {
                        if let tiffData = capturedImg.tiffRepresentation,
                           let bitmap = NSBitmapImageRep(data: tiffData),
                           let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                            try? jpegData.write(to: diskPath, options: .atomic)
                        }
                    }
                }
            }
            accessOrder.removeFirst(min(removeCount, accessOrder.count))
        }
        cache[url] = image
        // Update LRU order
        if let idx = accessOrder.firstIndex(of: url) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(url)
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
        accessOrder.removeAll(where: { $0 == url })
        lock.unlock()
        // Also remove from disk cache
        let diskPath = diskKey(for: url)
        try? FileManager.default.removeItem(at: diskPath)
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        accessOrder.removeAll()
        lock.unlock()
    }

    /// Prefetch previews at given resolution
    private static let prefetchQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
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
            Self.prefetchQueue.addOperation { [weak self] in
                autoreleasepool {
                    guard let self = self, !self.has(key) else { return }
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
                    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
            if isJPG && subsample > 1 {
                genOpts[kCGImageSourceSubsampleFactor as NSString] = subsample
            }
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, genOpts as CFDictionary) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
                let end = min(i + 5_000_000, data.count)  // Allow up to 5MB per JPEG
                let subData = data.subdata(in: i..<end)
                if let imgSource = CGImageSourceCreateWithData(subData as CFData, nil),
                   CGImageSourceGetCount(imgSource) > 0 {
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
        guard let cgImage = ctx.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: targetColorSpace) else { return nil }

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
    @State private var rotationAngle: Double = 0  // 0, 90, 180, 270
    @State private var rotatedImage: NSImage?  // Actual rotated pixel data
    @State private var showAIResult: Bool = false
    @State private var aiResultText: String = ""
    @State private var hiResWorkItem: DispatchWorkItem? = nil
    @State private var imageLoadWork: DispatchWorkItem? = nil
    @State private var preloadWork: DispatchWorkItem? = nil
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

    var body: some View {
        VStack(spacing: 0) {
            // Image area
            GeometryReader { geo in
                let vSize = geo.size

                Group {
                if let image = image {
                    let imgW: CGFloat = image.size.width
                    let imgH: CGFloat = image.size.height
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
                        Image(nsImage: rotatedImage ?? image)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: isFitMode ? vSize.width : scaledW,
                                   height: isFitMode ? vSize.height : scaledH)
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
                                    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05, execute: work)
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

                        // Overlays (fixed to view size, not image size)
                        VStack {
                            // Top-right: Histogram (toggleable)
                            HStack {
                                Spacer()
                                if showHistogram {
                                    HistogramOverlay(photo: photo)
                                        .padding(8)
                                }
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
                    }
                    .frame(width: vSize.width, height: vSize.height)
                    .background(store.previewBackgroundColor)
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
                .onChange(of: vSize) { newSize in
                    viewState.viewSize = newSize
                }
            }

            Divider()

            // Toolbar: Correction | Stars + SP | Zoom
            HStack(spacing: 6) {
                correctionBar

                Divider().frame(height: 20).opacity(0.2)

                StarRatingView(rating: photo.rating) { newRating in
                    store.setRating(newRating, for: photo.id)
                }

                Button(action: { store.toggleSpacePick(for: photo.id) }) {
                    Text("SP")
                        .font(.system(size: AppTheme.fontCaption, weight: .black))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .frame(height: AppTheme.buttonHeight)
                .foregroundColor(photo.isSpacePicked ? .white : AppTheme.error)
                .background(photo.isSpacePicked ? AppTheme.error : AppTheme.mutedRed)
                .clipShape(Capsule())
                .help("스페이스 셀렉 토글 (Space)")

                Divider().frame(height: 20).opacity(0.2)

                // Rotation buttons
                Button(action: { applyRotation(degrees: -90) }) {
                    Image(systemName: "rotate.left")
                        .font(.system(size: AppTheme.iconSmall))
                }
                .buttonStyle(.plain)
                .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                .contentShape(Rectangle())
                .foregroundColor(rotatedImage != nil ? .white : .secondary)
                .background(rotatedImage != nil ? Color.blue : AppTheme.toolbarButtonBg)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("왼쪽 90° 회전")

                Button(action: { applyRotation(degrees: 90) }) {
                    Image(systemName: "rotate.right")
                        .font(.system(size: AppTheme.iconSmall))
                }
                .buttonStyle(.plain)
                .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                .contentShape(Rectangle())
                .foregroundColor(rotatedImage != nil ? .white : .secondary)
                .background(rotatedImage != nil ? Color.blue : AppTheme.toolbarButtonBg)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("오른쪽 90° 회전")

                Divider().frame(height: 20).opacity(0.2)

                zoomBar
            }
            .padding(.horizontal, AppTheme.space8)
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
        .sheet(isPresented: $showColorPicker) {
            VStack(spacing: 16) {
                Text("커스텀 배경색").font(.headline)
                ColorPicker("컬러 선택", selection: $customBgColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 200, height: 40)
                HStack {
                    Button("취소") { showColorPicker = false }
                    Spacer()
                    Button("적용") {
                        // NSColor → hex
                        let ns = NSColor(customBgColor)
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
            .padding(20)
            .frame(width: 280, height: 160)
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

            // 빠른 탐색 콜백: 썸네일 즉시 표시 + 멈추면 0.5초 후 고화질 + hi-res
            store.onQuickPreview = { [self] url in
                // 현재 선택된 사진인지 확인 (이전 사진 섞임 방지)
                guard url == store.selectedPhoto?.jpgURL else { return }
                if let thumb = ThumbnailCache.shared.get(url) {
                    self.image = thumb
                } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                            kCGImageSourceThumbnailMaxPixelSize: 300,
                            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                            kCGImageSourceCreateThumbnailWithTransform: true
                          ] as CFDictionary) {
                    self.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }

            // Scroll wheel zoom monitor (only when mouse is over preview)
            if let existing = viewState.scrollMonitor {
                NSEvent.removeMonitor(existing)
                viewState.scrollMonitor = nil
            }
            viewState.scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown]) { [self] event in
                // Verify monitor is still active (guard against stale callbacks)
                guard self.viewState.scrollMonitor != nil else { return event }
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
        .onChange(of: store.selectedPhotoID) { newID in
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
            isHiResLoaded = false
            hiResLoadWork?.cancel()
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
            let url = selected.jpgURL

            // Fast path: cache hit → show immediately
            let res = store.previewResolution
            let cacheKey = res > 0 ? url.appendingPathExtension("r\(res)") : url.appendingPathExtension("orig")
            if let cached = PreviewImageCache.shared.get(cacheKey) {
                image = cached
                lowResImage = cached
                // 캐시 히트 → 아래 debounce 로직으로 계속 진행 (멈추면 고화질 보장)
            }

            // Show thumbnail instantly while full image loads
            if let thumb = ThumbnailCache.shared.get(url) {
                image = thumb
            } else if ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) {
                // JPG만 동기 추출 (~1ms) — RAW는 느려서 스킵
                if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceThumbnailMaxPixelSize: 300,
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                    kCGImageSourceCreateThumbnailWithTransform: true
                   ] as CFDictionary) {
                    image = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
                }
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
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05, execute: delayedWork)
            } else {
                // 단일 이동 → 즉시 로딩
                loadImageDirect(for: url, id: newID)
            }

            // hi-res 로딩 (방향키 꾹 누르면 cancel)
            let work = DispatchWorkItem {
                guard self.pendingPhotoID == newID else { return }
                self.loadHiResForZoom()
            }
            hiResWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in zoomIn() }
        .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in zoomOut() }
        .onChange(of: viewState.zoomPreset) { newPreset in
            if newPreset == .fit {
                switchToLowRes()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleHistogram)) { _ in showHistogram.toggle() }
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
            // Correction menu (local + AI)
            Menu {
                Button(action: { showCorrectionPanel = true }) {
                    Label("자동 보정", systemImage: "wand.and.rays")
                }
                .disabled(isCorrecting)

                Button(action: {
                    if isCorrecting {
                        DisabledGuide.showCorrectionInProgress()
                    } else if !ClaudeVisionService.hasAPIKey {
                        DisabledGuide.showAIDisabled()
                    } else {
                        applyAICorrection()
                    }
                }) {
                    Label("AI 보정 (Pro)", systemImage: "sparkles")
                }
                .disabled(isCorrecting || !ClaudeVisionService.hasAPIKey)

                Divider()

                Button(action: { showUprightGuide = true }) {
                    Label("가이드 보정", systemImage: "perspective")
                }
                .disabled(isCorrecting)

                Divider()

                // NPU 고급 보정
                Button(action: { applyNPUCorrection(mode: .aiEnhance) }) {
                    Label("AI 보정 (NPU)", systemImage: "brain")
                }
                .disabled(isCorrecting)

                Button(action: { applyNPUCorrection(mode: .denoise) }) {
                    Label("디노이즈", systemImage: "dot.radiowaves.right")
                }
                .disabled(isCorrecting)

                Button(action: { applyNPUCorrection(mode: .personAware) }) {
                    Label("인물 인식 보정", systemImage: "person.crop.rectangle")
                }
                .disabled(isCorrecting)
            } label: {
                Label(isCorrecting ? "보정 중..." : "보정", systemImage: "wand.and.rays")
                    .font(.system(size: AppTheme.fontCaption, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 8)
            .frame(height: AppTheme.buttonHeight)
            .foregroundColor(.white)
            .background(Color.green.opacity(isCorrecting ? 0.3 : 0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("자동 보정 / AI 보정 선택")

            // Crop button
            Button(action: { showCropView = true }) {
                Label("크롭", systemImage: "crop")
                    .font(.system(size: AppTheme.fontCaption, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: AppTheme.buttonHeight)
            .background(Color.orange.opacity(0.7))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("사진 크롭")

            // Original / Corrected toggle
            if correctionResult != nil {
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
                    HStack(spacing: 3) {
                        Image(systemName: isOriginal ? "photo" : "photo.fill")
                            .font(.system(size: 10))
                        Text(isOriginal ? "원본" : "보정됨")
                            .font(.system(size: AppTheme.fontBody, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .frame(height: AppTheme.buttonHeight)
                .foregroundColor(isOriginal ? .primary : .white)
                .background(isOriginal ? AppTheme.toolbarButtonBg : Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("원본/보정 전환")

                // Save corrected
                Button(action: { saveCorrectedImage() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10))
                        Text("저장")
                            .font(.system(size: AppTheme.fontBody, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .frame(height: AppTheme.buttonHeight)
                .background(AppTheme.toolbarButtonBg)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("보정된 사진 저장")
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
                .onChange(of: sliderValue) { newVal in
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

        // Cache key includes resolution
        let cacheKey = resolution > 0 ? url.appendingPathExtension("r\(resolution)") : url.appendingPathExtension("orig")
        if let cached = PreviewImageCache.shared.get(cacheKey) {
            fputs("[LD] HIT \(fileName)\n", stderr)
            self.image = cached
            return
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        // Cancel previous loading work
        imageLoadWork?.cancel()
        let work = DispatchWorkItem(qos: .userInitiated) { [self] in
            guard self.pendingPhotoID == id else { return }

            let ext = url.pathExtension.lowercased()
            let isJPG = ["jpg", "jpeg"].contains(ext)

            if isJPG {
                // JPG: load at target resolution
                let targetPx = resolution > 0 ? CGFloat(resolution) : 0
                let img: NSImage?
                if targetPx == 0 {
                    img = NSImage(contentsOf: url)
                } else {
                    img = PreviewImageCache.loadOptimized(url: url, maxPixel: targetPx)
                }
                guard let loaded = img, self.pendingPhotoID == id else { return }
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                fputs("[LD] JPG \(fileName) \(Int(loaded.size.width))x\(Int(loaded.size.height)) \(ms)ms\n", stderr)
                PreviewImageCache.shared.set(cacheKey, image: loaded)
                // 미리보기 이미지로 썸네일 캐시도 채우기 (디스크 I/O 없이 즉시)
                ThumbnailCache.shared.set(url, image: loaded)
                RunLoop.main.perform(inModes: [.common]) {
                    guard self.pendingPhotoID == id,
                          store.selectedPhoto?.jpgURL == url else { return }
                    self.image = loaded
                    self.lowResImage = loaded
                }
            } else {
                // RAW: 2-stage loading
                let optimalPx = resolution > 0 ? CGFloat(resolution) : PreviewImageCache.optimalPreviewSize()

                // Stage 1: Fast load at 1200px for rapid navigation
                var fastImage = PreviewImageCache.loadOptimized(url: url, maxPixel: min(1200, optimalPx))

                // Fix orientation: compare with stableImageSize (which has correct orientation)
                if let fast = fastImage, let stable = self.viewState.stableImageSize {
                    let stableIsPortrait = stable.height > stable.width
                    let fastIsPortrait = fast.size.height > fast.size.width
                    if stableIsPortrait != fastIsPortrait {
                        fastImage = Self.applyOrientation(fast, orientation: 6)
                    }
                }

                guard let fast = fastImage, self.pendingPhotoID == id else { return }
                let ms1 = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                fputs("[LD] RAW-S1 \(fileName) \(Int(fast.size.width))x\(Int(fast.size.height)) \(ms1)ms\n", stderr)

                // 미리보기 이미지로 썸네일 캐시 채우기
                ThumbnailCache.shared.set(url, image: fast)

                RunLoop.main.perform(inModes: [.common]) {
                    guard self.pendingPhotoID == id,
                          store.selectedPhoto?.jpgURL == url else { return }
                    self.image = fast
                    self.lowResImage = fast
                }

                // Stage 2: Higher res preview (2400px — good enough for most screens)
                guard self.pendingPhotoID == id else { return }
                let stage2Px: CGFloat = 2400
                if optimalPx > 1200, let hr = PreviewImageCache.loadOptimized(url: url, maxPixel: stage2Px) {
                    var finalHR = hr
                    if let stable = self.viewState.stableImageSize {
                        let sp = stable.height > stable.width
                        let hp = hr.size.height > hr.size.width
                        if sp != hp { finalHR = Self.applyOrientation(hr, orientation: 6) }
                    }
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
        }
        imageLoadWork = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    private func loadImage(for url: URL) {
        loadImageDirect(for: url, id: pendingPhotoID ?? UUID())
    }

    /// Schedule smart preload of ±20 neighbors, cancelling any previous batch
    private func scheduleSmartPreload(currentID: UUID, resolution: Int) {
        // Cancel previous preload batch when selection changes rapidly
        preloadWork?.cancel()

        let work = DispatchWorkItem {
            self.preloadNeighborsBatch(currentID: currentID, resolution: resolution)
        }
        preloadWork = work
        // Small delay so rapid arrow-key navigation cancels stale batches
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Preload ±20 neighbors into PreviewImageCache with smart resolution selection
    private func preloadNeighborsBatch(currentID: UUID, resolution: Int) {
        let photos = store.filteredPhotos
        guard let currentIdx = photos.firstIndex(where: { $0.id == currentID }) else { return }

        // Collect neighbors: ±20, closest first for priority ordering
        var entries: [(url: URL, isRAW: Bool)] = []
        for offset in 1...20 {
            // Forward
            let fwd = currentIdx + offset
            if fwd < photos.count && !photos[fwd].isFolder && !photos[fwd].isParentFolder {
                let url = photos[fwd].jpgURL
                let ext = url.pathExtension.lowercased()
                let isRAW = FileMatchingService.rawExtensions.contains(ext)
                entries.append((url: url, isRAW: isRAW))
            }
            // Backward
            let bwd = currentIdx - offset
            if bwd >= 0 && !photos[bwd].isFolder && !photos[bwd].isParentFolder {
                let url = photos[bwd].jpgURL
                let ext = url.pathExtension.lowercased()
                let isRAW = FileMatchingService.rawExtensions.contains(ext)
                entries.append((url: url, isRAW: isRAW))
            }
        }

        let cache = PreviewImageCache.shared
        for entry in entries {
            // Check cancellation between each load (selection changed = abort)
            if self.pendingPhotoID != currentID {
                return
            }

            // RAW files: preload at 1200px (fast embedded preview)
            // JPG files: preload at original (resolution 0) or requested resolution
            let preloadRes: Int
            if entry.isRAW {
                preloadRes = 1200
            } else {
                preloadRes = resolution  // 0 means original for JPG
            }

            let cacheKey: URL
            if preloadRes > 0 {
                cacheKey = entry.url.appendingPathExtension("r\(preloadRes)")
            } else {
                cacheKey = entry.url.appendingPathExtension("orig")
            }

            // Skip if already cached (RAM or disk)
            if cache.has(cacheKey) { continue }

            // Load the image
            let maxPx = preloadRes > 0 ? CGFloat(preloadRes) : PreviewImageCache.optimalPreviewSize()
            if let img = PreviewImageCache.loadOptimized(url: entry.url, maxPixel: maxPx) {
                // For JPG at original resolution, load full image
                if !entry.isRAW && preloadRes == 0 {
                    if let full = NSImage(contentsOf: entry.url) {
                        cache.set(cacheKey, image: full)
                    } else {
                        cache.set(cacheKey, image: img)
                    }
                } else {
                    cache.set(cacheKey, image: img)
                }
            }
        }
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

        // Rotate the actual image pixels
        guard let tiffData = source.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return }

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
        hiResLoadWork?.cancel()
        if let low = lowResImage {
            image = low
            isHiResLoaded = false
            print("🔍 [ZOOM] low-res restored: \(Int(low.size.width))x\(Int(low.size.height))")
        }
    }

    // MARK: - Hi-Res Cache (for zoom)
    private static var hiResCache = NSCache<NSURL, NSImage>()
    private static var hiResCacheInitialized = false
    private static var hiResMemorySource: DispatchSourceMemoryPressure?

    private static func initHiResCache() {
        guard !hiResCacheInitialized else { return }
        hiResCache.countLimit = 3  // Reduce from 5 to 3
        hiResCache.totalCostLimit = 300 * 1024 * 1024  // 300MB max
        hiResCacheInitialized = true

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            hiResCache.removeAllObjects()
            AppLogger.log(.general, "⚠️ hiResCache cleared due to memory pressure")
        }
        source.resume()
        hiResMemorySource = source
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
            var hiRes = Self.loadHiResImage(url: url)
            guard self.pendingPhotoID == photoID else { return }

            // Fix orientation: match lowRes aspect ratio
            if var img = hiRes, let low = self.lowResImage {
                let lowIsPortrait = low.size.height > low.size.width
                let hiIsPortrait = img.size.height > img.size.width
                if lowIsPortrait != hiIsPortrait {
                    img = Self.applyOrientation(img, orientation: 6)
                    hiRes = img
                }
            }

            RunLoop.main.perform(inModes: [.common]) {
                guard self.pendingPhotoID == photoID else { return }
                // 현재 선택된 사진 URL과도 재확인
                guard url == self.store.selectedPhoto?.jpgURL || url == self.store.selectedPhoto?.rawURL else { return }
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                if let hi = hiRes {
                    fputs("[HIRES] loaded \(url.lastPathComponent) \(Int(hi.size.width))x\(Int(hi.size.height)) in \(String(format: "%.0f", elapsed))ms\n", stderr)
                    let currentSize = max(self.image?.size.width ?? 0, self.image?.size.height ?? 0)
                    let hiResSize = max(hi.size.width, hi.size.height)
                    guard hiResSize > currentSize else {
                        fputs("[HIRES] ⚠️ skip — hi-res \(Int(hiResSize))px < current \(Int(currentSize))px\n", stderr)
                        return
                    }
                    let cost = hi.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 1
                    Self.hiResCache.setObject(hi, forKey: url as NSURL, cost: cost)
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

    /// Prefetch hi-res for ±3 neighboring photos (background)
    private func prefetchHiResNeighbors() {
        let list = store.filteredPhotos
        guard let currentID = store.selectedPhotoID,
              let currentIdx = list.firstIndex(where: { $0.id == currentID }) else { return }

        let range = 3
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
    /// Strategy: JPG direct (fastest) → RAW CGImageSource with SubsampleFactor (fast + orientation correct)
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

        // RAW: extract largest embedded JPEG (same color as camera preview, fast)
        // This is the same approach as Photo Mechanic — use camera's JPEG, not RAW decode
        // mmap whole file (OS handles paging, no actual full read until accessed)
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
        return bestImage
    }

    private func reloadCurrentImage() {
        guard let selected = store.selectedPhoto else { return }
        loadImageDirect(for: selected.jpgURL, id: pendingPhotoID ?? UUID())
    }

    /// Read image pixel dimensions from file header only (no decode, very fast)
    private static var _dimensionCache: [URL: CGSize] = [:]
    private static let _dimensionCacheLock = NSLock()
    private static let maxDimensionCacheSize = 2000
    private static func readImageDimensions(url: URL) -> CGSize? {
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
        // Check orientation for swap
        let orient = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        let size: CGSize
        if orient >= 5 && orient <= 8 {
            size = CGSize(width: h, height: w)
        } else {
            size = CGSize(width: w, height: h)
        }
        _dimensionCacheLock.lock()
        _dimensionCache[url] = size
        _dimensionCacheLock.unlock()
        return size
    }

    /// Apply EXIF orientation to an NSImage that lacks proper orientation metadata
    private static func applyOrientation(_ image: NSImage, orientation: Int) -> NSImage {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return image }

        let w = cgImage.width
        let h = cgImage.height

        // For orientations 5-8, the output size is swapped
        let outputSize: CGSize
        let transform: CGAffineTransform

        switch orientation {
        case 6: // 90° CW (most common for portrait photos)
            outputSize = CGSize(width: h, height: w)
            transform = CGAffineTransform(translationX: CGFloat(h), y: 0).rotated(by: .pi / 2)
        case 8: // 90° CCW
            outputSize = CGSize(width: h, height: w)
            transform = CGAffineTransform(translationX: 0, y: CGFloat(w)).rotated(by: -.pi / 2)
        case 5: // Mirrored + 90° CW
            outputSize = CGSize(width: h, height: w)
            transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: CGFloat(-h), y: 0).rotated(by: .pi / 2)
        case 7: // Mirrored + 90° CCW
            outputSize = CGSize(width: h, height: w)
            transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: 0, y: CGFloat(-w)).rotated(by: -.pi / 2)
        default:
            return image
        }

        guard let context = CGContext(data: nil,
                                       width: Int(outputSize.width),
                                       height: Int(outputSize.height),
                                       bitsPerComponent: cgImage.bitsPerComponent,
                                       bytesPerRow: 0,
                                       space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: cgImage.bitmapInfo.rawValue) else { return image }

        context.concatenate(transform)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let rotated = context.makeImage() else { return image }
        return NSImage(cgImage: rotated, size: outputSize)
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
            // Load at reasonable size for loupe (not full 60MP, but enough for 250% zoom)
            let opts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 3000,
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

            // Bottom row
            HStack(alignment: .bottom) {
                // Bottom-left: Filename + Rating stars
                VStack(alignment: .leading, spacing: 3) {
                    Text(photo.fileName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))

                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= photo.rating ? "star.fill" : "star")
                                .font(.system(size: 10))
                                .foregroundColor(star <= photo.rating ? .yellow : .gray.opacity(0.5))
                        }
                    }

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

                Spacer()
            }
            .padding(10)
        }
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

            Toggle(isOn: $options.autoHorizon) {
                HStack(spacing: 8) {
                    Image(systemName: "level")
                        .font(.system(size: 12))
                        .frame(width: 20)
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("수평/수직 보정")
                            .font(.system(size: 12, weight: .medium))
                        Text("기울어진 수평선을 자동으로 맞춤")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help("수평선 자동 보정")

            Toggle(isOn: $options.autoUpright) {
                HStack(spacing: 8) {
                    Image(systemName: "perspective")
                        .font(.system(size: 12))
                        .frame(width: 20)
                        .foregroundColor(.cyan)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("원근 보정 (Upright)")
                            .font(.system(size: 12, weight: .medium))
                        Text("건축물 수직선을 자동으로 세움")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help("건축 사진 수직선 원근 보정")

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

            // Correction options
            Toggle(isOn: $options.autoHorizon) {
                Label("수평/수직 보정", systemImage: "level").font(.system(size: 12))
            }.toggleStyle(.checkbox).disabled(isProcessing)
            .help("수평선 자동 보정")

            Toggle(isOn: $options.autoUpright) {
                Label("원근 보정 (Upright)", systemImage: "perspective").font(.system(size: 12))
            }.toggleStyle(.checkbox).disabled(isProcessing)
            .help("건축 사진 수직선 원근 보정")

            Toggle(isOn: $options.faceBalance) {
                Label("얼굴 기준 보정", systemImage: "face.smiling").font(.system(size: 12))
            }.toggleStyle(.checkbox).disabled(isProcessing)
            .help("피부톤 기준 색감/밝기 보정")

            Toggle(isOn: $options.skinSmoothing) {
                Label("피부 스무딩", systemImage: "sparkles").font(.system(size: 12))
            }.toggleStyle(.checkbox).disabled(isProcessing)
            .help("피부 부드럽게")

            Toggle(isOn: $options.autoLevel) {
                Label("자동 노출 보정", systemImage: "sun.max").font(.system(size: 12))
            }.toggleStyle(.checkbox).disabled(isProcessing)
            .help("밝기/톤커브 자동 조정")

            Toggle(isOn: $options.autoWhiteBalance) {
                Label("자동 화이트밸런스", systemImage: "thermometer.medium").font(.system(size: 12))
            }.toggleStyle(.checkbox).disabled(isProcessing)
            .help("색온도/틴트 자동 보정")

            // NPU 고급 보정
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

    private func saveOverwrite(image: NSImage, url: URL) -> Bool {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
            return false
        }
        do {
            try jpegData.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private func saveToURL(image: NSImage, url: URL) -> Bool {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
            return false
        }
        do {
            try jpegData.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
