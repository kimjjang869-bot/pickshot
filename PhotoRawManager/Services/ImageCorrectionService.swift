import Foundation
import AppKit
import CoreImage
import Vision

struct CorrectionOptions {
    var autoLevel: Bool = true
    var autoWhiteBalance: Bool = true
    var autoHorizon: Bool = true
}

struct CorrectionResult {
    var correctedImage: NSImage?
    var horizonAngle: Double = 0        // detected rotation in degrees
    var exposureAdjust: Double = 0      // EV adjustment applied
    var temperatureShift: Double = 0    // Kelvin shift applied
    var applied: [String] = []          // list of corrections applied
    var savedJPGURL: URL?               // saved corrected JPG path
    var savedRAWURL: URL?               // copied RAW path
}

struct ImageCorrectionService {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Auto Correct

    static func autoCorrect(url: URL, options: CorrectionOptions) -> CorrectionResult {
        var result = CorrectionResult()

        guard let originalImage = CIImage(contentsOf: url) else { return result }
        var image = originalImage

        // 1. Auto Horizon (straighten)
        if options.autoHorizon {
            let angle = detectHorizonAngle(image: image)
            if abs(angle) > 0.3 {
                let radians = angle * .pi / 180.0
                if let filter = CIFilter(name: "CIStraightenFilter") {
                    filter.setValue(image, forKey: kCIInputImageKey)
                    filter.setValue(Float(-radians), forKey: "inputAngle")
                    if let output = filter.outputImage {
                        image = output
                        result.horizonAngle = angle
                        result.applied.append("수평 보정 (\(String(format: "%.1f", angle))°)")
                    }
                }
            }
        }

        // 2. Apple Auto Enhancement (exposure, tone, vibrance, face balance, red-eye)
        if options.autoLevel || options.autoWhiteBalance {
            var enhanceOptions: [CIImageAutoAdjustmentOption: Any] = [:]
            // Provide orientation for accurate face detection
            if let orientation = originalImage.properties[kCGImagePropertyOrientation as String] {
                enhanceOptions[.enhance] = true
                enhanceOptions[CIImageAutoAdjustmentOption(rawValue: "CIDetectorImageOrientation")] = orientation
            }
            // Skip red-eye if only doing white balance
            if !options.autoLevel {
                enhanceOptions[.redEye] = false
            }

            let autoFilters = image.autoAdjustmentFilters(options: enhanceOptions)

            for filter in autoFilters {
                let filterName = filter.name
                filter.setValue(image, forKey: kCIInputImageKey)
                if let output = filter.outputImage {
                    image = output

                    // Log what was applied
                    switch filterName {
                    case "CIFaceBalance":
                        result.applied.append("얼굴 피부톤 보정")
                    case "CIVibrance":
                        result.applied.append("채도 자동 보정")
                    case "CIToneCurve":
                        result.applied.append("톤 커브 보정")
                    case "CIHighlightShadowAdjust":
                        result.applied.append("하이라이트/섀도우 보정")
                    case "CIRedEyeCorrection":
                        result.applied.append("적목 보정")
                    default:
                        result.applied.append("\(filterName) 보정")
                    }
                }
            }

            // Additional fine-tune: exposure if Apple's auto didn't adjust enough
            if options.autoLevel {
                let adjustment = calculateExposureAdjustment(image: image)
                if abs(adjustment) > 0.15 {
                    if let filter = CIFilter(name: "CIExposureAdjust") {
                        filter.setValue(image, forKey: kCIInputImageKey)
                        filter.setValue(Float(adjustment), forKey: "inputEV")
                        if let output = filter.outputImage {
                            image = output
                            result.exposureAdjust = adjustment
                            result.applied.append("노출 미세 보정 (\(String(format: "%+.2f", adjustment))EV)")
                        }
                    }
                }
            }

            // Additional fine-tune: white balance if still off
            if options.autoWhiteBalance {
                let wb = calculateWhiteBalance(image: image)
                if abs(wb.temperature - 6500) > 400 || abs(wb.tint) > 10 {
                    if let filter = CIFilter(name: "CITemperatureAndTint") {
                        filter.setValue(image, forKey: kCIInputImageKey)
                        filter.setValue(CIVector(x: CGFloat(wb.temperature), y: CGFloat(wb.tint)), forKey: "inputNeutral")
                        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
                        if let output = filter.outputImage {
                            image = output
                            result.temperatureShift = wb.temperature - 6500
                            result.applied.append("화이트밸런스 미세 보정 (\(Int(wb.temperature))K → 6500K)")
                        }
                    }
                }
            }
        }

        // Render final image
        if let cgImage = context.createCGImage(image, from: image.extent) {
            result.correctedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        return result
    }

    // MARK: - Save Corrected Image + RAW Copy

    /// Save corrected JPG and copy matching RAW to "자동보정" folder
    static func saveWithRAW(image: NSImage, photo: PhotoItem) -> (jpgURL: URL?, rawURL: URL?) {
        let sourceDir = photo.jpgURL.deletingLastPathComponent()
        let correctedDir = sourceDir.appendingPathComponent("자동보정")

        // Create folder
        try? FileManager.default.createDirectory(at: correctedDir, withIntermediateDirectories: true)

        let baseName = photo.jpgURL.deletingPathExtension().lastPathComponent
        let timestamp = Int(Date().timeIntervalSince1970) % 10000

        // Save corrected JPG
        let jpgName = "\(baseName)_corrected_\(timestamp).jpg"
        let jpgDest = correctedDir.appendingPathComponent(jpgName)

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
            return (nil, nil)
        }

        var savedJPG: URL? = nil
        var savedRAW: URL? = nil

        do {
            try jpegData.write(to: jpgDest)
            savedJPG = jpgDest
        } catch { }

        // Copy RAW file
        if let rawURL = photo.rawURL {
            let rawExt = rawURL.pathExtension
            let rawName = "\(baseName)_corrected_\(timestamp).\(rawExt)"
            let rawDest = correctedDir.appendingPathComponent(rawName)

            do {
                try FileManager.default.copyItem(at: rawURL, to: rawDest)
                savedRAW = rawDest
            } catch { }
        }

        return (savedJPG, savedRAW)
    }

    /// Legacy save (JPG only, same folder)
    static func saveCorrected(image: NSImage, originalURL: URL) -> URL? {
        let dir = originalURL.deletingLastPathComponent()
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let newName = "\(baseName)_corrected.jpg"
        let destURL = dir.appendingPathComponent(newName)

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
            return nil
        }

        do {
            try jpegData.write(to: destURL)
            return destURL
        } catch {
            return nil
        }
    }

    // MARK: - Horizon Detection

    private static func detectHorizonAngle(image: CIImage) -> Double {
        // Primary: Vision framework VNDetectHorizonRequest (most accurate)
        if let angle = detectHorizonWithVision(image: image), abs(angle) > 0.3 && abs(angle) < 15 {
            return angle
        }

        // Fallback 1: CIDetector rectangle detection
        let detector = CIDetector(
            ofType: CIDetectorTypeRectangle,
            context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        if let features = detector?.features(in: image) as? [CIRectangleFeature], let rect = features.first {
            let dx = rect.topRight.x - rect.topLeft.x
            let dy = rect.topRight.y - rect.topLeft.y
            let angle = atan2(dy, dx) * 180.0 / .pi
            if abs(angle) > 0.3 && abs(angle) < 15 {
                return angle
            }
        }

        // Fallback 2: edge gradient analysis
        return detectHorizonFromEdges(image: image)
    }

    private static func detectHorizonWithVision(image: CIImage) -> Double? {
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }

        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let result = request.results?.first as? VNHorizonObservation else { return nil }

        let angleDegrees = result.angle * 180.0 / .pi
        return angleDegrees
    }

    private static func detectHorizonFromEdges(image: CIImage) -> Double {
        // Downsample for speed
        let scale = min(400.0 / image.extent.width, 400.0 / image.extent.height, 1.0)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return 0 }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Accumulate edge angles using Sobel gradients
        var angleBins = [Int](repeating: 0, count: 360)

        for y in stride(from: 2, to: height - 2, by: 3) {
            for x in stride(from: 2, to: width - 2, by: 3) {
                let idx = y * width + x
                let gx = Int(pixels[idx + 1]) - Int(pixels[idx - 1])
                let gy = Int(pixels[idx + width]) - Int(pixels[idx - width])
                let magnitude = gx * gx + gy * gy

                if magnitude > 200 {  // Edge threshold (lowered for soft scenes)
                    var angle = atan2(Double(gy), Double(gx)) * 180.0 / .pi
                    if angle < 0 { angle += 360 }
                    let bin = Int(angle) % 360
                    angleBins[bin] += 1
                }
            }
        }

        // Find dominant near-horizontal angle (around 0° or 180°)
        var bestAngle = 0.0
        var bestCount = 0

        for offset in -15...15 {
            let bin0 = (0 + offset + 360) % 360
            let bin180 = (180 + offset + 360) % 360
            let count = angleBins[bin0] + angleBins[bin180]
            if count > bestCount {
                bestCount = count
                bestAngle = Double(offset)
            }
        }

        return bestAngle
    }

    // MARK: - Exposure Analysis

    private static func calculateExposureAdjustment(image: CIImage) -> Double {
        let stats = analyzeHistogram(image: image)
        let targetMean = 0.45  // Target: slightly below middle gray

        let diff = targetMean - stats.meanBrightness
        // Clamp adjustment to reasonable range
        return max(-2.0, min(2.0, diff * 3.0))
    }

    private struct HistogramStats {
        var meanBrightness: Double = 0.5
        var shadowLevel: Double = 0.0
        var highlightLevel: Double = 1.0
    }

    private static func analyzeHistogram(image: CIImage) -> HistogramStats {
        // Downsample
        let scale = min(200.0 / image.extent.width, 200.0 / image.extent.height, 1.0)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return HistogramStats()
        }

        // Try GPU histogram via Metal
        if MetalImageProcessor.isAvailable, let gpuHist = MetalImageProcessor.histogram(image: cgImage) {
            let histogram = gpuHist.l
            let total = histogram.reduce(0, +)
            guard total > 0 else { return HistogramStats() }

            // Mean brightness from luminance histogram
            var weightedSum: Int = 0
            for i in 0..<256 { weightedSum += i * histogram[i] }
            let mean = Double(weightedSum) / Double(total) / 255.0

            // Find 1% and 99% percentile for shadow/highlight
            var cumulative = 0
            var shadowLevel = 0.0
            var highlightLevel = 1.0
            let p1 = total / 100
            let p99 = total * 99 / 100

            for i in 0..<256 {
                cumulative += histogram[i]
                if cumulative >= p1 && shadowLevel == 0 {
                    shadowLevel = Double(i) / 255.0
                }
                if cumulative >= p99 {
                    highlightLevel = Double(i) / 255.0
                    break
                }
            }

            return HistogramStats(
                meanBrightness: mean,
                shadowLevel: shadowLevel * 0.3,
                highlightLevel: min(1.0, highlightLevel + (1.0 - highlightLevel) * 0.3)
            )
        }

        // CPU fallback
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return HistogramStats() }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum: Int = 0
        var histogram = [Int](repeating: 0, count: 256)
        for val in pixels {
            sum += Int(val)
            histogram[Int(val)] += 1
        }

        let total = pixels.count
        let mean = Double(sum) / Double(total) / 255.0

        // Find 1% and 99% percentile for shadow/highlight
        var cumulative = 0
        var shadowLevel = 0.0
        var highlightLevel = 1.0
        let p1 = total / 100
        let p99 = total * 99 / 100

        for i in 0..<256 {
            cumulative += histogram[i]
            if cumulative >= p1 && shadowLevel == 0 {
                shadowLevel = Double(i) / 255.0
            }
            if cumulative >= p99 {
                highlightLevel = Double(i) / 255.0
                break
            }
        }

        return HistogramStats(
            meanBrightness: mean,
            shadowLevel: shadowLevel * 0.3,  // Gentle lift
            highlightLevel: min(1.0, highlightLevel + (1.0 - highlightLevel) * 0.3)
        )
    }

    // MARK: - White Balance Detection

    private struct WhiteBalanceInfo {
        var temperature: Double = 6500
        var tint: Double = 0
    }

    private static func calculateWhiteBalance(image: CIImage) -> WhiteBalanceInfo {
        let scale = min(200.0 / image.extent.width, 200.0 / image.extent.height, 1.0)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return WhiteBalanceInfo()
        }

        let width = cgImage.width
        let height = cgImage.height
        let totalPixels = width * height

        // Get RGB data
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return WhiteBalanceInfo() }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sumR: Int = 0, sumG: Int = 0, sumB: Int = 0

        for i in stride(from: 0, to: totalPixels * 4, by: 4) {
            sumR += Int(pixels[i])
            sumG += Int(pixels[i + 1])
            sumB += Int(pixels[i + 2])
        }

        let avgR = Double(sumR) / Double(totalPixels)
        let avgG = Double(sumG) / Double(totalPixels)
        let avgB = Double(sumB) / Double(totalPixels)

        // Estimate color temperature from R/B ratio
        // Higher R/B = warmer (lower Kelvin), Lower R/B = cooler (higher Kelvin)
        let rbRatio = avgR / max(avgB, 1)

        var temperature: Double
        if rbRatio > 1.2 {
            temperature = 4000 + (1.5 - rbRatio) * 2000  // Warm image
        } else if rbRatio < 0.8 {
            temperature = 8000 + (0.8 - rbRatio) * 3000  // Cool image
        } else {
            temperature = 6500  // Neutral
        }
        temperature = max(3000, min(10000, temperature))

        // Tint from G channel deviation
        let gRatio = avgG / ((avgR + avgB) / 2.0)
        let tint = (gRatio - 1.0) * 50.0

        return WhiteBalanceInfo(temperature: temperature, tint: tint)
    }
}
