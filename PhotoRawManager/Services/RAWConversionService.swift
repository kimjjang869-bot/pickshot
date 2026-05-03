import Foundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// High-speed RAW → JPG batch conversion using CIRAWFilter (GPU) + CGImageDestination (HW JPEG encoder).
struct RAWConversionService {

    // MARK: - Sharpening Preset Values (v9.0.2)

    /// 자연/선명/또렷 프리셋 → (amount, radius, threshold).
    /// 작은 반경 → 헤일로 sub-pixel 레벨 → 안 보임. threshold 로 평탄 영역 보호.
    private static func sharpeningValues(for sharpening: Sharpening) -> (Double, Double, Double)? {
        switch sharpening {
        case .natural: return (0.40, 0.55, 0.012)
        case .sharp:   return (0.65, 0.65, 0.012)
        case .crisp:   return (0.95, 0.75, 0.010)
        default:       return nil
        }
    }

    // MARK: - Sharpening

    enum Sharpening: String, CaseIterable {
        case off = "없음"
        /// v9.0.2: 작은 반경 USM 프리셋 — 약하게 (헤일로 안 보임, 밝기 보존).
        case natural = "자연"
        /// v9.0.2: 작은 반경 USM 프리셋 — 기본 (라이트룸 export 비슷).
        case sharp   = "선명"
        /// v9.0.2: 작은 반경 USM 프리셋 — 강하게 (인쇄/SNS 업로드용).
        case crisp   = "또렷"
        /// v9.0.2: Photoshop 식 언샵마스크 (Amount/Radius/Threshold) — ExportOptions 의 unsharp* 슬라이더 사용.
        case unsharpMask = "직접 조절"
        /// v9.0.2: 매거진 에디토리얼 스타일 — Clarity + Detail + Pop 3-pass 합성.
        case editorial = "화보 느낌"
    }

    // MARK: - Color Space

    enum OutputColorSpace: String, CaseIterable {
        case srgb = "sRGB"
        case displayP3 = "Display P3"
        case adobeRGB = "Adobe RGB"

        var cgColorSpace: CGColorSpace {
            switch self {
            case .srgb: return CGColorSpace(name: CGColorSpace.sRGB)!
            case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
            case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
            }
        }
    }

    // MARK: - Filename Pattern

    enum FilenamePattern: String, CaseIterable {
        case original = "원본 유지"
        case dateOriginal = "날짜_원본"
        case prefixNumber = "접두사_번호"
        case dateTimeNumber = "날짜_시간_번호"
    }

    // MARK: - Export Options

    struct ExportOptions {
        var resolution: Resolution = .original
        /// v9.0.2: 사용자 직접 입력 해상도 (px). resolution == .custom 일 때만 사용.
        var customMaxPixel: Int = 3000
        var quality: Quality = .high
        var sharpening: Sharpening = .off
        var autoHorizon: Bool = false
        var colorSpace: OutputColorSpace = .srgb
        var filenamePattern: FilenamePattern = .original
        var filenamePrefix: String = "Photo"
        /// v9.0.2: 출력 JPG 의 DPI 메타데이터.
        var dpi: Int = 72
        /// v9.0.2: Photoshop 식 언샵마스크 파라미터 (Sharpening == .unsharpMask 일 때만 사용).
        ///   amount: 강도 (10~300%, 기본 50%). radius: 가우시안 블러 반경 (0.3~5.0px).
        ///   threshold: 노이즈 보호 (0~50, sRGB 0-255 기준).
        var unsharpAmount: Double = 0.3
        var unsharpRadius: Double = 0.8
        var unsharpThreshold: Double = 0.015
        /// v9.0.2: 하위폴더 포함 모드에서 원본 폴더 구조 유지 여부.
        var preserveFolderStructure: Bool = false
        /// v9.0.2: 상대 경로 계산용 베이스 폴더 (preserveFolderStructure ON 시 필수).
        var baseFolder: URL? = nil

        /// 실제 적용할 maxPixel (custom 모드 지원).
        var effectiveMaxPixel: CGFloat? {
            if case .custom = resolution {
                return customMaxPixel > 0 ? CGFloat(customMaxPixel) : nil
            }
            return resolution.maxPixel
        }
    }

    enum Resolution: String, CaseIterable {
        case original = "원본"
        case px4000 = "4000px"
        case px2000 = "2000px"
        case px1200 = "1200px"
        case custom = "직접 입력"

        var maxPixel: CGFloat? {
            switch self {
            case .original: return nil
            case .px4000: return 4000
            case .px2000: return 2000
            case .px1200: return 1200
            case .custom: return nil  // ExportOptions.effectiveMaxPixel 에서 customMaxPixel 사용
            }
        }
    }

    enum Quality: String, CaseIterable {
        case max = "최고 (95%)"
        case high = "높음 (90%)"
        case medium = "보통 (85%)"
        case web = "웹용 (80%)"

        var value: CGFloat {
            switch self {
            case .max: return 0.95
            case .high: return 0.90
            case .medium: return 0.85
            case .web: return 0.80
            }
        }
    }

    struct ConversionResult {
        let succeeded: Int
        let failed: Int
        let totalTime: Double
        let failedFiles: [String]
    }

    // Shared Metal-backed CIContext (reused across all conversions)
    static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    /// Batch convert RAW files to JPG (supports cancellation via cancelFlag)
    static func batchConvert(
        photos: [PhotoItem],
        outputFolder: URL,
        options: ExportOptions = ExportOptions(),
        cancelFlag: UnsafeMutablePointer<Bool>? = nil,
        progress: @escaping (Int, Int) -> Void
    ) -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let rawPhotos = photos.filter { !$0.isFolder && !$0.isParentFolder }

        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        let total = rawPhotos.count
        var succeeded = 0
        var failed = 0
        var failedFiles: [String] = []
        let lock = NSLock()

        let cores = ProcessInfo.processInfo.activeProcessorCount
        _ = min(cores, 8)
        print("🔄 [RAW→JPG] Start: \(total) files, sharp=\(options.sharpening.rawValue), horizon=\(options.autoHorizon), color=\(options.colorSpace.rawValue)")

        // Pre-generate filenames
        let dateStr = { () -> String in
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date())
        }()
        let timeStr = { () -> String in
            let f = DateFormatter(); f.dateFormat = "HHmm"; return f.string(from: Date())
        }()

        DispatchQueue.concurrentPerform(iterations: total) { idx in
            autoreleasepool {
                if cancelFlag?.pointee == true { return }

                let photo = rawPhotos[idx]
                let url = photo.rawURL ?? photo.jpgURL
                let baseName = url.deletingPathExtension().lastPathComponent

                // Generate output filename
                let outputName: String
                switch options.filenamePattern {
                case .original:
                    outputName = baseName + ".jpg"
                case .dateOriginal:
                    outputName = "\(dateStr)_\(baseName).jpg"
                case .prefixNumber:
                    outputName = "\(options.filenamePrefix)_\(String(format: "%04d", idx + 1)).jpg"
                case .dateTimeNumber:
                    outputName = "\(dateStr)_\(timeStr)_\(String(format: "%04d", idx + 1)).jpg"
                }
                // v9.0.2: 원본 폴더 구조 유지 옵션 — preserveFolderStructure & baseFolder 가 있으면
                //   원본 위치의 상대 경로를 outputFolder 아래에 그대로 재현.
                let outputURL: URL = {
                    if options.preserveFolderStructure, let base = options.baseFolder {
                        let relativeDir = url.deletingLastPathComponent().path
                            .replacingOccurrences(of: base.path, with: "")
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if !relativeDir.isEmpty {
                            let dir = outputFolder.appendingPathComponent(relativeDir, isDirectory: true)
                            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            return dir.appendingPathComponent(outputName)
                        }
                    }
                    return outputFolder.appendingPathComponent(outputName)
                }()

                let success = convertSingle(
                    inputURL: url,
                    outputURL: outputURL,
                    options: options
                )

                lock.lock()
                if success {
                    succeeded += 1
                } else {
                    failed += 1
                    failedFiles.append(url.lastPathComponent)
                }
                let done = succeeded + failed
                lock.unlock()

                if done % 5 == 0 || done == total {
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let rate = elapsed > 0 ? Double(done) / elapsed * 60 : 0
                    print("🔄 [RAW→JPG] \(done)/\(total) (\(String(format: "%.0f", rate)) files/min)")
                    DispatchQueue.main.async { progress(done, total) }
                }
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let rate = elapsed > 0 ? Double(total) / elapsed * 60 : 0
        print("🔄 [RAW→JPG] DONE: \(succeeded) OK, \(failed) failed in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", rate)) files/min)")

        return ConversionResult(succeeded: succeeded, failed: failed, totalTime: elapsed, failedFiles: failedFiles)
    }

    /// Convert a single RAW file to JPG with all options
    private static func convertSingle(
        inputURL: URL,
        outputURL: URL,
        options: ExportOptions
    ) -> Bool {
        let maxPixel = options.effectiveMaxPixel
        let jpegQuality = options.quality.value

        // Step 1~5: 디코딩/리사이즈/필터/CGImage 렌더를 autoreleasepool로 감싸
        // 큰 중간 CIImage가 run loop 종료까지 남지 않도록 즉시 해제
        let targetColorSpace = options.colorSpace.cgColorSpace
        let cgImage: CGImage? = autoreleasepool {
            // v9.0.2: Stage 3 (deep embedded JPEG) 추출 — 프리뷰와 100% 동일 색감.
            //   loadHiResImage 와 같은 로직: index 0 → 부족하면 RAW 파일 바이트 스캔으로 deep embedded 찾기.
            //   Sony ARW: index 0 = 1616px, deep scan = 4096px. PickShot 프리뷰가 보여주는 "Stage 3" 가 이거.
            let ciImage: CIImage? = autoreleasepool {
                if let cgImage = extractDeepEmbeddedJPEG(url: inputURL) {
                    let pxMax = max(cgImage.width, cgImage.height)
                    plog("[CONVERT] deep embedded selected \(cgImage.width)x\(cgImage.height) (max=\(pxMax)) — \(inputURL.lastPathComponent)\n")
                    var img = CIImage(cgImage: cgImage)
                    // v9.0.2: 부모 RAW orientation 적용 — 임베디드 JPEG 는 회전 전 sensor 방향으로 박혀있는 경우 多.
                    //   세로 사진 (orient 5-8) 은 추출하면 가로로 나오므로 명시적 회전 필요.
                    img = applyParentOrientationIfNeeded(img, url: inputURL, embeddedSize: CGSize(width: cgImage.width, height: cgImage.height))
                    return img
                }
                // 폴백: 임베디드 추출 실패 시에만 CIRAWFilter.
                plog("[CONVERT] embedded extraction FAILED → CIRAW fallback — \(inputURL.lastPathComponent)\n")
                if #available(macOS 12.0, *), let rawFilter = CIRAWFilter(imageURL: inputURL) {
                    rawFilter.boostAmount = 0
                    rawFilter.isGamutMappingEnabled = true
                    if let maxPx = maxPixel {
                        let props = rawFilter.nativeSize
                        let origMax = max(props.width, props.height)
                        if origMax > maxPx {
                            rawFilter.scaleFactor = Float(maxPx / origMax)
                        }
                    }
                    return rawFilter.outputImage
                }
                return CIImage(contentsOf: inputURL)
            }

            guard var output = ciImage else { return nil }

            // Step 2: Resize — v9.0.2 Lanczos (긴축 기준).
            //   다운샘플: multi-step Lanczos.
            //   업샘플: Lanczos 한 번 (임베디드 1616px → 타깃 2000px 같은 경우).
            //     색감 일치를 위해 임베디드 사용 → 약간의 업샘플 감수.
            if let maxPx = maxPixel {
                let extent = output.extent
                let origMax = max(extent.width, extent.height)
                if origMax > maxPx {
                    output = highQualityDownscale(output, targetMax: maxPx)
                } else if origMax < maxPx * 0.98 {
                    // 업샘플 (1.02× 이상 차이날 때만) — Lanczos 한 번.
                    let scale = maxPx / origMax
                    output = lanczosScale(output, scale: scale)
                    plog("[RESIZE] \(Int(origMax))→\(Int(maxPx))px (Lanczos UPSAMPLE \(String(format: "%.2f", scale))×)\n")
                }
            }

            // Step 3: Auto Horizon correction
            if options.autoHorizon {
                if let corrected = applyAutoHorizon(output) {
                    output = corrected
                }
            }

            // Step 4: Sharpening — v9.0.2: 모든 프리셋 USM small-radius 기반 (밝기 보존 + 헤일로 안 보임).
            if options.sharpening == .unsharpMask {
                // 직접 조절 — Photoshop 식 USM (Amount/Radius/Threshold).
                output = applyUnsharpMask(
                    output,
                    amount: options.unsharpAmount,
                    radius: options.unsharpRadius,
                    threshold: options.unsharpThreshold
                )
            } else if options.sharpening == .editorial {
                // 화보 느낌 — Clarity + Detail + Pop 3-pass.
                //   Detail pass 는 "선명" 프리셋 값 기반 (amount 0.65 / radius 0.65 / threshold 0.012).
                output = applyUnsharpMask(output, amount: 0.12, radius: 30.0,  threshold: 0.0)   // Clarity (mid-tone 깊이)
                output = applyUnsharpMask(output, amount: 0.65, radius: 0.65,  threshold: 0.012) // Detail (선명 프리셋)
                output = applyUnsharpMask(output, amount: 0.18, radius: 4.0,   threshold: 0.010) // Pop (입체감)
            } else if let (amount, radius, threshold) = Self.sharpeningValues(for: options.sharpening) {
                // 자연 / 선명 / 또렷 — 작은 반경 USM 프리셋.
                output = applyUnsharpMask(output, amount: amount, radius: radius, threshold: threshold)
            }

            // Step 5: Render to CGImage with target color space
            let extent = output.extent
            return ciContext.createCGImage(output, from: extent,
                                           format: .RGBA8,
                                           colorSpace: targetColorSpace)
        }

        guard let cgImage else { return false }

        // Step 6: Write JPEG via CGImageDestination
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1, nil
        ) else { return false }

        // v9.0.2: DPI 메타데이터 — JFIF + TIFF + EXIF 모두 셋팅 (관용적 호환성).
        let dpiValue = max(1, options.dpi)
        let tiffDict: [CFString: Any] = [
            kCGImagePropertyTIFFXResolution: dpiValue,
            kCGImagePropertyTIFFYResolution: dpiValue,
            kCGImagePropertyTIFFResolutionUnit: 2  // 2 = inches
        ]
        let jfifDict: [CFString: Any] = [
            kCGImagePropertyJFIFXDensity: dpiValue,
            kCGImagePropertyJFIFYDensity: dpiValue,
            kCGImagePropertyJFIFDensityUnit: 1  // 1 = dots per inch
        ]
        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
            kCGImageDestinationOptimizeColorForSharing: options.colorSpace == .srgb,
            kCGImagePropertyDPIWidth: dpiValue,
            kCGImagePropertyDPIHeight: dpiValue,
            kCGImagePropertyTIFFDictionary: tiffDict,
            kCGImagePropertyJFIFDictionary: jfifDict
        ]

        CGImageDestinationAddImage(destination, cgImage, destOptions as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: - Unsharp Mask (Photoshop-style)

    /// Photoshop 식 언샵마스크 — Amount/Radius/Threshold.
    /// 알고리즘: result = input + amount * (input - blurred)
    ///         = (1 + amount) * input - amount * blurred
    /// Core Image 만으로 구현 (Metal 가속).
    /// threshold 는 |detail| < threshold 인 영역에서 sharpening 약화시켜 노이즈 증폭 방지.
    private static func applyUnsharpMask(
        _ input: CIImage,
        amount: Double,
        radius: Double,
        threshold: Double
    ) -> CIImage {
        guard amount > 0, radius > 0 else { return input }

        // Step 1: Gaussian blur
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return input }
        blurFilter.setValue(input, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurred = blurFilter.outputImage?.cropped(to: input.extent) else { return input }

        // Step 2: scaledInput = (1 + amount) * input
        let amountF = CGFloat(amount)
        let oneVec = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let upScale = CIFilter(name: "CIColorMatrix") else { return input }
        upScale.setValue(input, forKey: kCIInputImageKey)
        upScale.setValue(CIVector(x: 1 + amountF, y: 0, z: 0, w: 0), forKey: "inputRVector")
        upScale.setValue(CIVector(x: 0, y: 1 + amountF, z: 0, w: 0), forKey: "inputGVector")
        upScale.setValue(CIVector(x: 0, y: 0, z: 1 + amountF, w: 0), forKey: "inputBVector")
        upScale.setValue(oneVec, forKey: "inputAVector")
        guard let scaledInput = upScale.outputImage else { return input }

        // Step 3: scaledBlur = amount * blurred
        guard let dnScale = CIFilter(name: "CIColorMatrix") else { return input }
        dnScale.setValue(blurred, forKey: kCIInputImageKey)
        dnScale.setValue(CIVector(x: amountF, y: 0, z: 0, w: 0), forKey: "inputRVector")
        dnScale.setValue(CIVector(x: 0, y: amountF, z: 0, w: 0), forKey: "inputGVector")
        dnScale.setValue(CIVector(x: 0, y: 0, z: amountF, w: 0), forKey: "inputBVector")
        dnScale.setValue(oneVec, forKey: "inputAVector")
        guard let scaledBlur = dnScale.outputImage else { return input }

        // Step 4: sharpened = scaledInput - scaledBlur (CISubtractBlendMode: bg - fg)
        guard let subFilter = CIFilter(name: "CISubtractBlendMode") else { return input }
        subFilter.setValue(scaledBlur, forKey: kCIInputImageKey)             // foreground
        subFilter.setValue(scaledInput, forKey: kCIInputBackgroundImageKey)   // background
        guard let sharpened = subFilter.outputImage?.cropped(to: input.extent) else { return input }

        // Step 5: Threshold — |input - blurred| < threshold 인 영역은 원본 유지 (노이즈 증폭 방지).
        //   구현: edgeMask = step(threshold, |detail|), result = mix(input, sharpened, edgeMask).
        //   threshold == 0 이면 mask 1.0 → sharpened 그대로 반환.
        guard threshold > 0 else { return sharpened }

        // |input - blurred| via two CISubtractBlendMode 의 합 (양/음 영역 각각 클램프 후 더함).
        let posDiff: CIImage = {
            guard let f = CIFilter(name: "CISubtractBlendMode") else { return input }
            f.setValue(blurred, forKey: kCIInputImageKey)
            f.setValue(input, forKey: kCIInputBackgroundImageKey)
            return f.outputImage?.cropped(to: input.extent) ?? input
        }()
        let negDiff: CIImage = {
            guard let f = CIFilter(name: "CISubtractBlendMode") else { return input }
            f.setValue(input, forKey: kCIInputImageKey)
            f.setValue(blurred, forKey: kCIInputBackgroundImageKey)
            return f.outputImage?.cropped(to: input.extent) ?? input
        }()
        let mag: CIImage = {
            guard let f = CIFilter(name: "CIAdditionCompositing") else { return posDiff }
            f.setValue(posDiff, forKey: kCIInputImageKey)
            f.setValue(negDiff, forKey: kCIInputBackgroundImageKey)
            return f.outputImage?.cropped(to: input.extent) ?? posDiff
        }()
        // edgeMask: mag 가 threshold 이상이면 1, 이하면 0 (CIColorThreshold 또는 CIColorMatrix 스케일+클램프).
        //   Core Image 기본 필터로 hard step 만들기: scale by (1/threshold) then clamp.
        let scale = 1.0 / max(threshold, 0.001)
        guard let maskScale = CIFilter(name: "CIColorMatrix") else { return sharpened }
        maskScale.setValue(mag, forKey: kCIInputImageKey)
        maskScale.setValue(CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0), forKey: "inputRVector")
        maskScale.setValue(CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0), forKey: "inputGVector")
        maskScale.setValue(CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0), forKey: "inputBVector")
        maskScale.setValue(oneVec, forKey: "inputAVector")
        guard let edgeMask = maskScale.outputImage?
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
                ])
                .cropped(to: input.extent) else { return sharpened }

        // result = mix(input, sharpened, edgeMask) via CIBlendWithMask.
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return sharpened }
        blend.setValue(sharpened, forKey: kCIInputImageKey)
        blend.setValue(input, forKey: kCIInputBackgroundImageKey)
        blend.setValue(edgeMask, forKey: "inputMaskImage")
        return blend.outputImage?.cropped(to: input.extent) ?? sharpened
    }

    // MARK: - Deep Embedded JPEG Extractor (v9.0.2 — Stage 3 동일 로직)

    /// PhotoPreviewView.loadHiResImage 의 deep scan 과 동일 — Sony ARW 등은 index 0 (1616px) 외에
    /// 파일 바이트 안에 더 큰 embedded JPEG (4096px+) 가 박혀있어 0xFFD8 마커 스캔으로 추출.
    /// v9.0.2: ClientSelectService 에서도 사용 (internal 노출).
    static func extractDeepEmbeddedJPEG(url: URL) -> CGImage? {
        // 1차: 표준 CGImageSource index 0 (Canon CR3 / Nikon NEF 는 보통 여기서 4000+px 나옴).
        var bestImage: CGImage? = nil
        var bestPixels = 0

        if let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) {
            let opts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 10000,  // 임베디드 한계 충분히 커버
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,  // 임베디드만, RAW demosaic 안 함
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceShouldCache: false
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
                bestImage = cg
                bestPixels = cg.width * cg.height
            }
        }

        // 2차: 파일 바이트 스캔 (Sony ARW 처럼 deep embedded 가 index 0 안 잡히는 경우).
        //   첫 16MB 안에 보통 위치. 0xFFD8 (JPEG SOI) 마커 찾아서 디코드 시도.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return bestImage
        }
        let scanLimit = min(data.count, 16_000_000)
        let ffd8: [UInt8] = [0xFF, 0xD8]

        var i = 0
        while i < scanLimit - 2 {
            if data[i] == ffd8[0] && data[i + 1] == ffd8[1] {
                if let jpegRange = completeJPEGRange(in: data, from: i, maxLength: 10_000_000),
                   jpegRange.count > 4_096 {
                    let subData = data.subdata(in: jpegRange)
                    if let imgSource = CGImageSourceCreateWithData(subData as CFData, nil),
                       CGImageSourceGetCount(imgSource) > 0 {
                        let props = CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [String: Any]
                        let w = props?[kCGImagePropertyPixelWidth as String] as? Int ?? 0
                        let h = props?[kCGImagePropertyPixelHeight as String] as? Int ?? 0
                        let pixels = w * h
                        let aspect = w > h ? Double(w) / max(Double(h), 1) : Double(h) / max(Double(w), 1)

                        if pixels > bestPixels && aspect <= 4.0 {
                            let opts: [NSString: Any] = [
                                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceShouldCacheImmediately: false
                            ]
                            if let cg = CGImageSourceCreateThumbnailAtIndex(imgSource, 0, opts as CFDictionary) {
                                bestImage = cg
                                bestPixels = cg.width * cg.height
                            }
                        }
                    }
                    // SOI 점프 — 이 JPEG 다음 위치부터 다시 스캔.
                    i = jpegRange.upperBound
                    continue
                }
            }
            i += 1
        }
        return bestImage
    }

    /// v9.0.2: 부모 RAW 파일의 orientation tag 를 임베디드 JPEG 에 적용 (필요 시).
    ///   Sony ARW 등은 deep embedded JPEG 가 sensor raw 방향으로 박혀있어,
    ///   부모 orientation 이 5~8 (세로) 인데 임베디드 가 가로 aspect 면 회전 필요.
    ///   loadHiResImage 의 correctThumbnailOrientationIfNeeded 와 같은 전략.
    static func applyParentOrientationIfNeeded(_ ci: CIImage, url: URL, embeddedSize: CGSize) -> CIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return ci }

        // top-level orientation 또는 TIFF dictionary 안의 orientation.
        let mainOrient: Int = {
            if let o = props[kCGImagePropertyOrientation as String] as? Int { return o }
            if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
               let o = tiff[kCGImagePropertyTIFFOrientation as String] as? Int { return o }
            return 1
        }()
        guard mainOrient > 1 else { return ci }

        // 부모 raw 의 PixelWidth/Height — 일부 RAW 는 못 읽음.
        let mainPw = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let mainPh = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let embLandscape = embeddedSize.width > embeddedSize.height

        let needsRotation: Bool = {
            if mainPw == 0 || mainPh == 0 {
                // 부모 dim 정보 없으면 orient 5-8 + 임베디드 가로면 회전 필요로 추정.
                return (mainOrient >= 5 && mainOrient <= 8) && embLandscape
            }
            // 부모 display aspect 계산 (orient 적용 후) → 임베디드와 비교.
            let displayLandscape: Bool = (mainOrient >= 5 && mainOrient <= 8) ? (mainPh > mainPw) : (mainPw > mainPh)
            return displayLandscape != embLandscape
        }()

        guard needsRotation else { return ci }

        // CGImagePropertyOrientation 매핑.
        let cgOrient: CGImagePropertyOrientation = {
            switch mainOrient {
            case 2: return .upMirrored
            case 3: return .down
            case 4: return .downMirrored
            case 5: return .leftMirrored
            case 6: return .right        // CW 90°
            case 7: return .rightMirrored
            case 8: return .left         // CCW 90°
            default: return .up
            }
        }()
        plog("[CONVERT] orientation correction \(mainOrient) → \(cgOrient.rawValue) for \(url.lastPathComponent)\n")
        return ci.oriented(cgOrient)
    }

    /// JPEG SOI 마커 (0xFFD8) 부터 EOI (0xFFD9) 까지 범위 반환.
    private static func completeJPEGRange(in data: Data, from start: Int, maxLength: Int) -> Range<Int>? {
        let end = min(start + maxLength, data.count - 1)
        var i = start + 2
        while i < end {
            if data[i] == 0xFF && data[i + 1] == 0xD9 {
                return start..<(i + 2)
            }
            i += 1
        }
        return nil
    }

    // MARK: - High-Quality Multi-Step Lanczos Downscale (v9.0.2)

    /// Lightroom/Photoshop 식 고품질 다운스케일.
    /// - 단일 step: scale ≥ 0.5 (≤ 2× 다운샘플) → Lanczos 한 번.
    /// - 2-step: 0.25 ≤ scale < 0.5 (2~4× 다운샘플) → 0.5× Lanczos + 최종 Lanczos.
    /// - 3-step: scale < 0.25 (4×+ 다운샘플) → 0.5× × 0.5× + 최종.
    /// 다단계 이유: Lanczos 도 한 번에 4×+ 다운샘플 시 aliasing/blur 발생 → step 별로 처리하면 sinc filter 가 더 정확히 동작.
    static func highQualityDownscale(_ input: CIImage, targetMax: CGFloat) -> CIImage {
        let extent = input.extent
        let origMax = max(extent.width, extent.height)
        guard origMax > targetMax else { return input }
        let finalScale = targetMax / origMax

        var current = input
        var currentMax = origMax
        var steps: [String] = ["\(Int(origMax))"]   // 시작 사이즈

        // 0.5× 단계 반복 (final scale 까지 절반 거리에 가까울 때까지).
        while currentMax * 0.5 > targetMax * 1.4 {
            current = lanczosScale(current, scale: 0.5)
            currentMax *= 0.5
            steps.append("\(Int(currentMax))")
        }

        // 최종 step — 남은 비율을 한 번에.
        let remaining = targetMax / currentMax
        if remaining < 0.999 {
            current = lanczosScale(current, scale: remaining)
            steps.append("\(Int(targetMax))")
        }
        // extent crop — Lanczos 가 미세하게 extent 변형할 수 있어 정수 영역으로 정렬.
        let finalW = round(extent.width * finalScale)
        let finalH = round(extent.height * finalScale)

        // v9.0.2: 다단계 리사이즈 검증용 로그 — stderr 1줄.
        let stepCount = steps.count - 1
        plog("[RESIZE] \(steps.joined(separator: "→"))px (\(stepCount)-step Lanczos)\n")

        return current.cropped(to: CGRect(x: 0, y: 0, width: finalW, height: finalH))
    }

    /// Single Lanczos pass — Core Image 의 CILanczosScaleTransform 사용. 업/다운 샘플 모두 지원.
    private static func lanczosScale(_ input: CIImage, scale: CGFloat) -> CIImage {
        guard scale > 0, abs(scale - 1.0) > 0.001,
              let f = CIFilter(name: "CILanczosScaleTransform") else {
            if abs(scale - 1.0) < 0.001 { return input }
            return input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(scale, forKey: kCIInputScaleKey)
        f.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return f.outputImage ?? input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Richardson-Lucy Deconvolution (Lightroom/Capture One/RawTherapee 식)

    /// Richardson-Lucy 디컨볼루션 — Lightroom Detail 슬라이더 / Capture One Diffraction / RawTherapee Capture Sharpening 의 핵심 엔진.
    /// USM 과 달리 헤일로 거의 없음 + 미세 디테일 복원 우수. 단점: iteration 당 4 번 가우시안 → USM 보다 5~10x 느림.
    /// Reference: https://www.strollswithmydog.com/richardson-lucy-algorithm/
    /// 알고리즘:
    ///   estimate = input
    ///   for i in 1..N:
    ///     reblurred  = gaussian_blur(estimate, radius)
    ///     ratio      = input / reblurred
    ///     correction = gaussian_blur(ratio, radius)
    ///     estimate   = estimate * correction
    ///   return estimate
    private static func applyRLDeconvolution(
        _ input: CIImage,
        radius: Double,
        iterations: Int = 6,
        amount: Double = 1.0
    ) -> CIImage {
        guard radius > 0, iterations > 0 else { return input }
        let extent = input.extent
        var estimate = input

        for _ in 0..<iterations {
            // 1. reblurred = gaussian(estimate, radius)
            guard let blur1 = CIFilter(name: "CIGaussianBlur") else { return input }
            blur1.setValue(estimate, forKey: kCIInputImageKey)
            blur1.setValue(radius, forKey: kCIInputRadiusKey)
            guard let reblurred = blur1.outputImage?.cropped(to: extent) else { return input }

            // 2. ratio = input / reblurred  (CIDivideBlendMode: bg / fg, 0 으로 나누기 방지를 위해 작은 값 더함)
            guard let div = CIFilter(name: "CIDivideBlendMode") else { return input }
            div.setValue(reblurred, forKey: kCIInputImageKey)             // foreground = denominator
            div.setValue(input, forKey: kCIInputBackgroundImageKey)        // background = numerator
            guard let ratio = div.outputImage?.cropped(to: extent) else { return input }

            // 3. correction = gaussian(ratio, radius)
            guard let blur2 = CIFilter(name: "CIGaussianBlur") else { return input }
            blur2.setValue(ratio, forKey: kCIInputImageKey)
            blur2.setValue(radius, forKey: kCIInputRadiusKey)
            guard let correction = blur2.outputImage?.cropped(to: extent) else { return input }

            // 4. estimate *= correction
            guard let mul = CIFilter(name: "CIMultiplyCompositing") else { return input }
            mul.setValue(correction, forKey: kCIInputImageKey)
            mul.setValue(estimate, forKey: kCIInputBackgroundImageKey)
            guard let updated = mul.outputImage?.cropped(to: extent) else { return input }
            estimate = updated
        }

        // amount < 1.0 이면 input 과 보간 (약화).
        if amount < 0.999 {
            guard let mixIn = CIFilter(name: "CIColorMatrix") else { return estimate }
            let a = CGFloat(amount)
            mixIn.setValue(estimate, forKey: kCIInputImageKey)
            mixIn.setValue(CIVector(x: a, y: 0, z: 0, w: 0), forKey: "inputRVector")
            mixIn.setValue(CIVector(x: 0, y: a, z: 0, w: 0), forKey: "inputGVector")
            mixIn.setValue(CIVector(x: 0, y: 0, z: a, w: 0), forKey: "inputBVector")
            mixIn.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            guard let mixOrig = CIFilter(name: "CIColorMatrix") else { return estimate }
            let b = CGFloat(1.0 - amount)
            mixOrig.setValue(input, forKey: kCIInputImageKey)
            mixOrig.setValue(CIVector(x: b, y: 0, z: 0, w: 0), forKey: "inputRVector")
            mixOrig.setValue(CIVector(x: 0, y: b, z: 0, w: 0), forKey: "inputGVector")
            mixOrig.setValue(CIVector(x: 0, y: 0, z: b, w: 0), forKey: "inputBVector")
            mixOrig.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            if let a1 = mixIn.outputImage, let a2 = mixOrig.outputImage,
               let add = CIFilter(name: "CIAdditionCompositing") {
                add.setValue(a1, forKey: kCIInputImageKey)
                add.setValue(a2, forKey: kCIInputBackgroundImageKey)
                return add.outputImage?.cropped(to: extent) ?? estimate
            }
        }
        return estimate
    }

    // MARK: - Auto Horizon (Vision-based)

    private static func applyAutoHorizon(_ image: CIImage) -> CIImage? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch { return nil }

        guard let result = request.results?.first,
              abs(result.angle) > 0.003 else { return nil }  // Skip if < 0.17°

        let angle = result.angle  // radians
        let straightened = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(angle)))

        // Auto-crop to remove black edges from rotation
        let cropInset = abs(CGFloat(angle)) * max(image.extent.width, image.extent.height) * 0.5
        let cropped = straightened.extent.insetBy(dx: cropInset, dy: cropInset)
        return straightened.cropped(to: cropped)
    }
}
