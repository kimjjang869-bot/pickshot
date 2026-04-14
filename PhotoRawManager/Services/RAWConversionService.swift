import Foundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// High-speed RAW → JPG batch conversion using CIRAWFilter (GPU) + CGImageDestination (HW JPEG encoder).
struct RAWConversionService {

    // MARK: - Sharpening

    enum Sharpening: String, CaseIterable {
        case off = "없음"
        case light = "약하게"
        case medium = "보통"
        case strong = "강하게"

        var radius: Float { switch self { case .off: return 0; case .light: return 1.5; case .medium: return 2.5; case .strong: return 4.0 } }
        var intensity: Float { switch self { case .off: return 0; case .light: return 0.3; case .medium: return 0.5; case .strong: return 0.8 } }
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
        var quality: Quality = .high
        var sharpening: Sharpening = .off
        var autoHorizon: Bool = false
        var colorSpace: OutputColorSpace = .srgb
        var filenamePattern: FilenamePattern = .original
        var filenamePrefix: String = "Photo"
    }

    enum Resolution: String, CaseIterable {
        case original = "원본"
        case px4000 = "4000px"
        case px2000 = "2000px"
        case px1200 = "1200px"

        var maxPixel: CGFloat? {
            switch self {
            case .original: return nil
            case .px4000: return 4000
            case .px2000: return 2000
            case .px1200: return 1200
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
    private static let ciContext: CIContext = {
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
        let concurrency = min(cores, 8)
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
                let outputURL = outputFolder.appendingPathComponent(outputName)

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
        let maxPixel = options.resolution.maxPixel
        let jpegQuality = options.quality.value

        // Step 1~5: RAW 디코딩/리사이즈/필터/CGImage 렌더를 autoreleasepool로 감싸
        // 큰 중간 CIImage가 run loop 종료까지 남지 않도록 즉시 해제
        let targetColorSpace = options.colorSpace.cgColorSpace
        let cgImage: CGImage? = autoreleasepool {
            // Step 1: Load RAW with CIRAWFilter (GPU-accelerated demosaicing)
            let ciImage: CIImage?

            if #available(macOS 12.0, *) {
                if let rawFilter = CIRAWFilter(imageURL: inputURL) {
                    rawFilter.boostAmount = 0
                    rawFilter.isGamutMappingEnabled = true

                    if let maxPx = maxPixel {
                        let props = rawFilter.nativeSize
                        let origMax = max(props.width, props.height)
                        if origMax > maxPx {
                            rawFilter.scaleFactor = Float(maxPx / origMax)
                        }
                    }

                    ciImage = rawFilter.outputImage
                } else {
                    ciImage = CIImage(contentsOf: inputURL)
                }
            } else {
                ciImage = CIImage(contentsOf: inputURL)
            }

            guard var output = ciImage else { return nil }

            // Step 2: Resize if needed
            if let maxPx = maxPixel {
                let extent = output.extent
                let origMax = max(extent.width, extent.height)
                if origMax > maxPx {
                    let scale = maxPx / origMax
                    output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                }
            }

            // Step 3: Auto Horizon correction
            if options.autoHorizon {
                if let corrected = applyAutoHorizon(output) {
                    output = corrected
                }
            }

            // Step 4: Sharpening (CIUnsharpMask — GPU accelerated)
            if options.sharpening != .off {
                if let sharp = CIFilter(name: "CIUnsharpMask") {
                    sharp.setValue(output, forKey: kCIInputImageKey)
                    sharp.setValue(options.sharpening.radius, forKey: kCIInputRadiusKey)
                    sharp.setValue(options.sharpening.intensity, forKey: kCIInputIntensityKey)
                    if let result = sharp.outputImage {
                        output = result
                    }
                }
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

        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
            kCGImageDestinationOptimizeColorForSharing: options.colorSpace == .srgb
        ]

        CGImageDestinationAddImage(destination, cgImage, destOptions as CFDictionary)
        return CGImageDestinationFinalize(destination)
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
