import Foundation
import AppKit
import CoreImage
import Vision

struct CorrectionOptions {
    var autoLevel: Bool
    var autoWhiteBalance: Bool
    var autoHorizon: Bool
    var autoUpright: Bool
    var faceBalance: Bool
    var skinSmoothing: Bool
    var aiEnhance: Bool              // AI 자동보정 (NPU 가속)
    var denoise: Bool                // AI 디노이즈
    var denoiseStrength: Float       // 디노이즈 강도 (0.0~1.0)
    var personAwareEnhance: Bool     // 인물 인식 선택적 보정

    init() {
        let d = UserDefaults.standard
        autoLevel = d.object(forKey: "corr_autoLevel") as? Bool ?? false
        autoWhiteBalance = d.object(forKey: "corr_autoWB") as? Bool ?? false
        autoHorizon = d.object(forKey: "corr_autoHorizon") as? Bool ?? true
        autoUpright = d.object(forKey: "corr_autoUpright") as? Bool ?? false
        faceBalance = d.object(forKey: "corr_faceBalance") as? Bool ?? false
        skinSmoothing = d.object(forKey: "corr_skinSmoothing") as? Bool ?? false
        aiEnhance = d.object(forKey: "corr_aiEnhance") as? Bool ?? false
        denoise = d.object(forKey: "corr_denoise") as? Bool ?? false
        denoiseStrength = d.object(forKey: "corr_denoiseStrength") as? Float ?? 0.5
        personAwareEnhance = d.object(forKey: "corr_personAwareEnhance") as? Bool ?? false
    }

    func save() {
        let d = UserDefaults.standard
        d.set(autoLevel, forKey: "corr_autoLevel")
        d.set(autoWhiteBalance, forKey: "corr_autoWB")
        d.set(autoHorizon, forKey: "corr_autoHorizon")
        d.set(autoUpright, forKey: "corr_autoUpright")
        d.set(faceBalance, forKey: "corr_faceBalance")
        d.set(skinSmoothing, forKey: "corr_skinSmoothing")
        d.set(aiEnhance, forKey: "corr_aiEnhance")
        d.set(denoise, forKey: "corr_denoise")
        d.set(denoiseStrength, forKey: "corr_denoiseStrength")
        d.set(personAwareEnhance, forKey: "corr_personAwareEnhance")
    }
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
        // low tier: 전체를 autoreleasepool로 감싸 중간 CIImage/CGImage 즉시 해제 (피크 메모리 ~30% 절감)
        return autoreleasepool { () -> CorrectionResult in
            return autoCorrectInner(url: url, options: options)
        }
    }

    private static func autoCorrectInner(url: URL, options: CorrectionOptions) -> CorrectionResult {
        var result = CorrectionResult()

        // 수평/원근만 할 때는 CIImage 색공간 변환을 피하기 위해 별도 처리
        let onlyGeometry = options.autoHorizon || options.autoUpright
        let needsColor = options.autoLevel || options.autoWhiteBalance || options.faceBalance || options.skinSmoothing || options.aiEnhance || options.denoise || options.personAwareEnhance

        guard var originalImage = CIImage(contentsOf: url) else { return result }

        // low tier: 입력을 미리 다운샘플 (4K → 2K) — 메모리 스파이크 ~75% 감소
        // 자동보정은 시각적 결과가 우선이므로 2K도 충분 (저장 시 다시 풀해상도)
        if SystemSpec.shared.effectiveTier == .low {
            let maxSide: CGFloat = 2400
            let w = originalImage.extent.width
            let h = originalImage.extent.height
            let m = max(w, h)
            if m > maxSide {
                let scale = maxSide / m
                originalImage = originalImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                fputs("[CORRECT] low tier 다운샘플 \(Int(w))x\(Int(h)) → \(Int(w*scale))x\(Int(h*scale))\n", stderr)
            }
        }

        var image = originalImage

        // 1. Auto Horizon — Vision 프레임워크
        if options.autoHorizon {
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            let horizonRequest = VNDetectHorizonRequest()
            do {
                try handler.perform([horizonRequest])
            } catch {
                AppLogger.log(.general, "Horizon detect error: \(error)")
            }

            let observation = horizonRequest.results?.first
            let rawAngle = observation?.angle ?? 0
            let angleDeg = rawAngle * 180.0 / .pi
            AppLogger.log(.general, "Horizon: raw=\(String(format: "%.4f", rawAngle))rad deg=\(String(format: "%.2f", angleDeg))° results=\(horizonRequest.results?.count ?? 0)")

            if abs(angleDeg) > 0.3 && abs(angleDeg) < 5.0, let obs = observation {
                if let filter = CIFilter(name: "CIStraightenFilter") {
                    filter.setValue(image, forKey: kCIInputImageKey)
                    filter.setValue(Float(obs.angle), forKey: "inputAngle")
                    if let output = filter.outputImage {
                        image = output
                        result.horizonAngle = angleDeg
                        result.applied.append("수평 보정 (\(String(format: "%.1f", angleDeg))°)")
                    }
                }
            }
        }

        // 1.5 Auto Upright (수직선 원근 보정)
        if options.autoUpright {
            let (uprighted, tiltAngle, applied) = PerspectiveCorrectionService.autoUpright(image: image)
            if applied {
                image = uprighted
                result.applied.append("원근 보정 (\(String(format: "%.1f", tiltAngle))°)")
            }
        }

        // 기하 보정만 했고 색감 보정 안 할 때 → 여기서 리턴 (색공간 변환 방지)
        if onlyGeometry && !needsColor && result.applied.isEmpty {
            // 아무 보정도 안 됨
            return result
        }
        if onlyGeometry && !needsColor && !result.applied.isEmpty {
            // 기하 보정만 적용 → 색 변환 없이 렌더링
            let oriented = image.oriented(forExifOrientation: Int32(
                originalImage.properties[kCGImagePropertyOrientation as String] as? Int ?? 1
            ))
            if let cgImage = context.createCGImage(oriented, from: oriented.extent) {
                result.correctedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            return result
        }

        // 2. Apple Auto Enhancement — 색감 보정이 켜진 경우만
        if needsColor {
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

        // 3. 얼굴 기준 보정 (CIFaceBalance + 얼굴 밝기 보정)
        if options.faceBalance {
            // 3a. CIFaceBalance — Apple 내장 얼굴 피부톤 보정
            let faceOpts: [CIImageAutoAdjustmentOption: Any] = [
                .redEye: false  // 적목만 스킵
            ]
            let faceFilters = image.autoAdjustmentFilters(options: faceOpts)
            for filter in faceFilters where filter.name == "CIFaceBalance" {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let output = filter.outputImage {
                    image = output
                    result.applied.append("얼굴 피부톤 보정")
                }
            }

            // 3b. 얼굴 영역 밝기 측정 → 어두우면 노출 보정
            let faceHandler = VNImageRequestHandler(ciImage: image, options: [:])
            let faceRequest = VNDetectFaceRectanglesRequest()
            try? faceHandler.perform([faceRequest])

            if let faces = faceRequest.results, !faces.isEmpty,
               let largest = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                // 가장 큰 얼굴의 밝기 측정
                let faceRect = CGRect(
                    x: largest.boundingBox.origin.x * image.extent.width,
                    y: largest.boundingBox.origin.y * image.extent.height,
                    width: largest.boundingBox.width * image.extent.width,
                    height: largest.boundingBox.height * image.extent.height
                )
                let faceCrop = image.cropped(to: faceRect)
                if let faceCG = context.createCGImage(faceCrop, from: faceCrop.extent) {
                    let brightness = measureBrightness(cgImage: faceCG)
                    // 얼굴이 어두우면 (0.35 미만) 밝게 보정
                    if brightness < 0.35 {
                        let ev = (0.45 - brightness) * 3.0  // 최대 ~1.0 EV
                        if let filter = CIFilter(name: "CIExposureAdjust") {
                            filter.setValue(image, forKey: kCIInputImageKey)
                            filter.setValue(Float(ev), forKey: "inputEV")
                            if let output = filter.outputImage {
                                image = output
                                result.applied.append("얼굴 밝기 보정 (+\(String(format: "%.1f", ev))EV)")
                            }
                        }
                    }
                }
            }
        }

        // 4. 피부 스무딩 (High Pass Filter)
        if options.skinSmoothing {
            if let smoothed = applySkinSmoothing(image: image) {
                image = smoothed
                result.applied.append("피부 스무딩")
            }
        }

        // 5. AI 자동보정 (NPU 가속 또는 고급 CIFilter)
        if options.aiEnhance {
            image = AIEnhanceService.enhance(image: image)
            let method = AIEnhanceService.isAIModelAvailable ? "NPU" : "CIFilter"
            result.applied.append("AI 자동보정 (\(method))")
        }

        // 6. AI 디노이즈 (NPU 가속 또는 CIFilter)
        if options.denoise {
            image = AIEnhanceService.denoise(image: image, strength: options.denoiseStrength)
            let pct = Int(options.denoiseStrength * 100)
            result.applied.append("AI 디노이즈 (\(pct)%)")
        }

        // 7. 인물 인식 선택적 보정 (Vision 세그멘테이션)
        if options.personAwareEnhance {
            image = AIEnhanceService.enhanceWithPersonMask(image: image)
            result.applied.append("인물 인식 보정")
        }

        // Render final image — orientation 보존
        // CIImage에서 orientation을 적용한 상태로 렌더링
        let oriented = image.oriented(forExifOrientation: Int32(
            originalImage.properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        ))
        if let cgImage = context.createCGImage(oriented, from: oriented.extent) {
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

    // MARK: - Face Brightness Measurement

    /// CGImage의 평균 밝기 측정 (0~1)
    private static func measureBrightness(cgImage: CGImage) -> Double {
        let w = min(cgImage.width, 100)
        let h = min(cgImage.height, 100)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0.5 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var sum: Double = 0
        let count = w * h
        for i in 0..<count {
            let r = Double(pixels[i * 4])
            let g = Double(pixels[i * 4 + 1])
            let b = Double(pixels[i * 4 + 2])
            sum += (r * 0.299 + g * 0.587 + b * 0.114) / 255.0
        }
        return sum / Double(count)
    }

    // MARK: - Skin Smoothing (High Pass Filter)

    /// 피부 스무딩: 가우시안 블러 + 원본 블렌딩 (High Pass 방식)
    private static func applySkinSmoothing(image: CIImage) -> CIImage? {
        // 1. 가우시안 블러 (피부 질감 제거)
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(image, forKey: kCIInputImageKey)
        blur.setValue(8.0, forKey: "inputRadius")  // 적당한 블러
        guard let blurred = blur.outputImage else { return nil }

        // 2. 원본과 블러된 이미지를 80:20 블렌딩 (자연스럽게)
        guard let blend = CIFilter(name: "CISourceAtopCompositing") else { return nil }

        // opacity 조절용: 블러에 투명도 적용
        guard let opacity = CIFilter(name: "CIColorMatrix") else { return nil }
        opacity.setValue(blurred, forKey: kCIInputImageKey)
        opacity.setValue(CIVector(x: 0, y: 0, z: 0, w: 0.3), forKey: "inputAVector")  // 30% 블러
        guard let semiBlur = opacity.outputImage else { return nil }

        blend.setValue(semiBlur, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)

        return blend.outputImage
    }
}
