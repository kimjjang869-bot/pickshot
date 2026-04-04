import Foundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// High-speed RAW → JPG batch conversion using CIRAWFilter (GPU) + CGImageDestination (HW JPEG encoder).
struct RAWConversionService {

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

    /// Batch convert RAW files to JPG
    static func batchConvert(
        photos: [PhotoItem],
        outputFolder: URL,
        resolution: Resolution = .original,
        quality: Quality = .high,
        progress: @escaping (Int, Int) -> Void
    ) -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let rawPhotos = photos.filter { !$0.isFolder && !$0.isParentFolder }

        // Create output folder
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        let total = rawPhotos.count
        var succeeded = 0
        var failed = 0
        var failedFiles: [String] = []
        let lock = NSLock()

        // Optimal concurrency: balance GPU load and I/O
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let concurrency = min(cores, 8)  // Cap at 8 to avoid VRAM contention
        print("🔄 [RAW→JPG] Start: \(total) files, concurrency=\(concurrency), res=\(resolution.rawValue), quality=\(quality.rawValue)")

        DispatchQueue.concurrentPerform(iterations: total) { idx in
            autoreleasepool {
                let photo = rawPhotos[idx]
                let url = photo.rawURL ?? photo.jpgURL  // Prefer RAW, fallback to JPG
                let outputName = url.deletingPathExtension().lastPathComponent + ".jpg"
                let outputURL = outputFolder.appendingPathComponent(outputName)

                let success = convertSingle(
                    inputURL: url,
                    outputURL: outputURL,
                    maxPixel: resolution.maxPixel,
                    jpegQuality: quality.value
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

    /// Convert a single RAW file to JPG
    private static func convertSingle(
        inputURL: URL,
        outputURL: URL,
        maxPixel: CGFloat?,
        jpegQuality: CGFloat
    ) -> Bool {
        // Step 1: Load RAW with CIRAWFilter (GPU-accelerated demosaicing)
        let ciImage: CIImage?

        if #available(macOS 12.0, *) {
            if let rawFilter = CIRAWFilter(imageURL: inputURL) {
                rawFilter.boostAmount = 0  // Preserve original look
                rawFilter.isGamutMappingEnabled = true

                // Set scale factor for resize (faster than post-resize)
                if let maxPx = maxPixel {
                    let props = rawFilter.nativeSize
                    let origMax = max(props.width, props.height)
                    if origMax > maxPx {
                        rawFilter.scaleFactor = Float(maxPx / origMax)
                    }
                }

                ciImage = rawFilter.outputImage
            } else {
                // Fallback: CIImage direct load
                ciImage = CIImage(contentsOf: inputURL)
            }
        } else {
            ciImage = CIImage(contentsOf: inputURL)
        }

        guard var output = ciImage else { return false }

        // Step 2: Resize if needed (and CIRAWFilter scaleFactor wasn't used)
        if let maxPx = maxPixel {
            let extent = output.extent
            let origMax = max(extent.width, extent.height)
            if origMax > maxPx {
                let scale = maxPx / origMax
                output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }

        // Step 3: Render to CGImage via Metal CIContext
        let extent = output.extent
        guard let cgImage = ciContext.createCGImage(output, from: extent,
                                                     format: .RGBA8,
                                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            return false
        }

        // Step 4: Write JPEG via CGImageDestination (HW-accelerated encoder)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1, nil
        ) else { return false }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
            kCGImageDestinationOptimizeColorForSharing: true  // sRGB for maximum compatibility
        ]

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
