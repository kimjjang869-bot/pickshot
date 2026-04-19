import Foundation
import AppKit
import CoreImage
import Vision

/// Detected photographer intent based on EXIF + image pattern
struct ShootingIntent {
    var isOutOfFocus: Bool = false
    var isLongExposure: Bool = false
    var isHighKey: Bool = false
    var isLowKey: Bool = false
    var description: String?
}

struct ImageAnalysisService {

    // MARK: - Public API

    static func analyze(photo: PhotoItem, options: AnalysisOptions = AnalysisOptions()) -> QualityAnalysis {
        var analysis = QualityAnalysis()
        analysis.isAnalyzed = true

        let intent = detectIntent(photo: photo)
        analysis.detectedIntent = intent

        analyzeImage(photo: photo, intent: intent, options: options, analysis: &analysis)

        // 얼굴 관련 분석: 이미지 1회 로드 + 랜드마크 1회 실행으로 통합
        if options.checkClosedEyes || options.checkFaceFocus {
            if let (faceCGImage, faces) = loadFaceLandmarks(url: photo.jpgURL) {
                if options.checkClosedEyes {
                    detectClosedEyes(faces: faces, analysis: &analysis)
                    detectSmile(faces: faces, analysis: &analysis)
                }
                if options.checkFaceFocus {
                    detectFaceFocus(cgImage: faceCGImage, faces: faces, analysis: &analysis)
                }
            }
        }

        if options.checkExifInfo {
            addExifInfo(photo: photo, analysis: &analysis)
        }

        return analysis
    }

    /// Parallel batch analysis using all CPU cores
    static func analyzeBatch(
        photos: [PhotoItem],
        options: AnalysisOptions = AnalysisOptions(),
        cancelCheck: @escaping () -> Bool,
        progress: @escaping (Int) -> Void
    ) -> [UUID: QualityAnalysis] {

        let results = ConcurrentDict<UUID, QualityAnalysis>()
        let total = photos.count
        let completed = AtomicCounter()

        let queue = OperationQueue()
        // CPU 과부하 방지: 각 분석이 1280px CGImage + landmarks + saliency를 메모리에 유지(~20MB/분석)
        // SystemSpec tier 기반 (M1 Pro 16GB = standard → 3으로 한 단계 더 조임)
        let cappedConcurrency = SystemSpec.shared.imageAnalysisConcurrency()
        let cores = ProcessInfo.processInfo.activeProcessorCount
        queue.maxConcurrentOperationCount = cappedConcurrency
        queue.qualityOfService = .userInitiated
        AppLogger.log(.general, "🧠 ImageAnalysisService 배치 동시성 캡: \(cappedConcurrency) (tier=\(SystemSpec.shared.effectiveTier.rawValue), cores=\(cores))")

        for photo in photos {
            queue.addOperation {
                if cancelCheck() {
                    queue.cancelAllOperations()
                    return
                }

                autoreleasepool {
                    let quality = analyze(photo: photo, options: options)
                    results.set(photo.id, value: quality)
                }

                let done = completed.increment()
                if done % 20 == 0 || done == total {
                    progress(done)
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        return results.snapshot()
    }

    // MARK: - Intent Detection

    private static func detectIntent(photo: PhotoItem) -> ShootingIntent {
        guard let exif = photo.exifData else { return ShootingIntent() }
        var intent = ShootingIntent()

        if let aperture = exif.aperture, aperture <= 2.8 {
            intent.isOutOfFocus = true
            intent.description = "아웃포커싱 (f/\(String(format: "%.1f", aperture)))"
        }
        if let aperture = exif.aperture, let focal = exif.focalLength,
           aperture <= 4.0 && focal >= 85 {
            intent.isOutOfFocus = true
            intent.description = "아웃포커싱 (f/\(String(format: "%.1f", aperture)), \(Int(focal))mm)"
        }

        if let exposure = exif.exposureTime, exposure >= 0.5 {
            intent.isLongExposure = true
            let shutterStr = exif.shutterSpeed ?? String(format: "%.1fs", exposure)
            intent.description = "장노출 (\(shutterStr))"
        }

        if let bias = exif.exposureBias, bias >= 1.0 { intent.isHighKey = true }
        if let bias = exif.exposureBias, bias <= -1.0 { intent.isLowKey = true }

        return intent
    }

    // MARK: - Optimized Image Analysis

    private static func analyzeImage(photo: PhotoItem, intent: ShootingIntent, options opts: AnalysisOptions, analysis: inout QualityAnalysis) {
        let url = photo.jpgURL
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())

        // Try hardware JPEG decode, fall back to CGImageSource
        let cgImage: CGImage
        if isJPEG, HWJPEGDecoder.isAvailable, let hwImage = HWJPEGDecoder.decode(url: url, maxPixel: 400) {
            cgImage = hwImage
        } else {
            let imgOptions: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 400,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let swImage = CGImageSourceCreateThumbnailAtIndex(source, 0, imgOptions as CFDictionary) else {
                return
            }
            cgImage = swImage
        }

        let width = cgImage.width
        let height = cgImage.height
        let totalPixels = width * height
        guard totalPixels > 0 else { return }

        // Work directly with UInt8 - no Float conversion needed
        guard let pixels = extractGrayscaleRaw(from: cgImage, width: width, height: height) else { return }

        // === Single-pass brightness, contrast, clipping ===
        var sumBrightness: Int = 0
        var sumBrightnessSq: Int = 0
        var shadowCount = 0
        var highlightCount = 0

        for val in pixels {
            let v = Int(val)
            sumBrightness += v
            sumBrightnessSq += v * v
            if val < 8 { shadowCount += 1 }      // ~3% of 255
            if val > 247 { highlightCount += 1 }   // ~97% of 255
        }

        let meanBrightness = Double(sumBrightness) / Double(totalPixels) / 255.0
        let varianceBr = Double(sumBrightnessSq) / Double(totalPixels) - (Double(sumBrightness) / Double(totalPixels)) * (Double(sumBrightness) / Double(totalPixels))
        let stdDev = sqrt(max(0, varianceBr)) / 255.0

        analysis.brightnessScore = meanBrightness
        analysis.contrastScore = stdDev
        analysis.shadowClipping = Double(shadowCount) / Double(totalPixels)
        analysis.highlightClipping = Double(highlightCount) / Double(totalPixels)

        // === Composition (attention saliency) ===
        analysis.compositionScore = computeCompositionScore(cgImage: cgImage)

        // === Sharpness ===
        // GPU-accelerated Laplacian (Accelerate + parallel dispatch), fallback to CPU
        let sharpness = MetalImageProcessor.laplacianSharpness(pixels: pixels, width: width, height: height)
        analysis.sharpnessScore = sharpness

        // --- Blur / Shake check ---
        if !opts.checkBlur {
            // skip
        } else if intent.isLongExposure {
            // intentional motion blur - skip
        } else if intent.isOutOfFocus {
            let sharpRatio = calculateSharpRegionFast(pixels: pixels, width: width, height: height)
            analysis.sharpRegionRatio = sharpRatio
            if sharpRatio < 0.02 {
                analysis.issues.append(QualityIssue(
                    type: .outOfFocus, severity: .warning,
                    message: "피사체 초점 의심 - 선명 영역 \(Int(sharpRatio * 100))% (아웃포커싱)"
                ))
            }
        } else {
            // Check sharp region ratio for focus miss detection
            let sharpRatio = calculateSharpRegionFast(pixels: pixels, width: width, height: height)
            analysis.sharpRegionRatio = sharpRatio

            // Check if fast shutter but still blurry = camera/subject shake
            let hasFastShutter = (analysis.detectedIntent != nil) ? false :
                (photo.exifData?.exposureTime ?? 1.0) <= (1.0 / 250.0)
            let isMotionBlur = detectMotionBlur(pixels: pixels, width: width, height: height)

            if hasFastShutter && (sharpness < 45 || isMotionBlur) {
                let shutterStr = photo.exifData?.shutterSpeed ?? ""
                if sharpness < 15 || isMotionBlur {
                    analysis.issues.append(QualityIssue(
                        type: .blur, severity: .bad,
                        message: "흔들림 감지 - 셔터 \(shutterStr)인데 블러 발생 (선명도: \(Int(sharpness)))"
                    ))
                } else if sharpness < 30 {
                    analysis.issues.append(QualityIssue(
                        type: .blur, severity: .warning,
                        message: "흔들림 의심 - 셔터 \(shutterStr)인데 다소 흐릿 (선명도: \(Int(sharpness)))"
                    ))
                }
            } else if sharpness < 10 || sharpRatio < 0.015 {
                // Completely out of focus - no sharp area at all
                analysis.issues.append(QualityIssue(
                    type: .outOfFocus, severity: .bad,
                    message: "초점 미스 - 선명 영역 없음 (선명도: \(Int(sharpness)), 선명 영역: \(Int(sharpRatio * 100))%)"
                ))
            } else if sharpness < 20 && sharpRatio < 0.05 {
                // Likely missed focus
                analysis.issues.append(QualityIssue(
                    type: .outOfFocus, severity: .warning,
                    message: "초점 의심 - 선명 영역 부족 (선명도: \(Int(sharpness)), 선명 영역: \(Int(sharpRatio * 100))%)"
                ))
            }
        }

        // --- Overexposure ---
        if opts.checkExposure {
            let hlBad: Double = intent.isHighKey ? 0.40 : 0.25
            let hlWarn: Double = intent.isHighKey ? 0.25 : 0.12
            let hlClip = analysis.highlightClipping

            if hlClip > hlBad {
                analysis.issues.append(QualityIssue(
                    type: .overexposed, severity: .bad,
                    message: "심한 노출 과다 - 하이라이트 \(Int(hlClip * 100))% 날아감"
                ))
            } else if hlClip > hlWarn && meanBrightness > 0.80 && !intent.isHighKey {
                analysis.issues.append(QualityIssue(
                    type: .overexposed, severity: .warning,
                    message: "노출 과다 주의 - 하이라이트 \(Int(hlClip * 100))% 클리핑"
                ))
            }

            // --- Underexposure ---
            let shBad: Double = intent.isLowKey ? 0.55 : 0.35
            let shWarn: Double = intent.isLowKey ? 0.35 : 0.20
            let shClip = analysis.shadowClipping

            if shClip > shBad {
                analysis.issues.append(QualityIssue(
                    type: .underexposed, severity: .bad,
                    message: "심한 노출 부족 - 섀도우 \(Int(shClip * 100))% 뭉개짐"
                ))
            } else if shClip > shWarn && meanBrightness < 0.20 && !intent.isLowKey {
                analysis.issues.append(QualityIssue(
                    type: .underexposed, severity: .warning,
                    message: "노출 부족 주의 - 섀도우 \(Int(shClip * 100))% 클리핑"
                ))
            }
        }

        // --- Low contrast ---
        let contrast = analysis.contrastScore
        if contrast < 0.06 {
            analysis.issues.append(QualityIssue(
                type: .lowContrast, severity: .warning,
                message: "콘트라스트 부족 - 대비 \(Int(contrast * 1000))/1000"
            ))
        }

    }

    // MARK: - Motion Blur Detection

    /// Detects directional blur (motion/shake).
    /// Motion blur has edges mostly in one direction, unlike focus blur which is uniform.
    private static func detectMotionBlur(pixels: [UInt8], width: Int, height: Int) -> Bool {
        var horizontalEnergy: Int64 = 0
        var verticalEnergy: Int64 = 0

        let step = 3  // sample every 3rd pixel for speed
        let totalPixels = width * height
        for y in stride(from: 1, to: height - 1, by: step) {
            for x in stride(from: 1, to: width - 1, by: step) {
                let idx = y * width + x
                guard idx >= width && idx + width < totalPixels else { continue }

                // Horizontal gradient (Sobel-like)
                let gx = Int(pixels[idx + 1]) - Int(pixels[idx - 1])
                // Vertical gradient
                let gy = Int(pixels[idx + width]) - Int(pixels[idx - width])

                horizontalEnergy += Int64(gx * gx)
                verticalEnergy += Int64(gy * gy)
            }
        }

        // If energy is heavily biased in one direction = directional blur (motion)
        let total = horizontalEnergy + verticalEnergy
        guard total > 0 else { return false }

        let ratio = Double(max(horizontalEnergy, verticalEnergy)) / Double(min(horizontalEnergy, verticalEnergy) + 1)

        // ratio > 4.0 means edges are 4x stronger in one direction = motion blur (strict)
        return ratio > 4.0
    }

    // MARK: - Shared Face Landmarks Loader (1회 로드 + 1회 Vision 실행)

    private static func loadFaceLandmarks(url: URL) -> (CGImage, [VNFaceObservation])? {
        guard let cgImage = loadCGImage(url: url, maxSize: 1280) else { return nil }

        let request = VNDetectFaceLandmarksRequest()
        if #available(macOS 13.0, *) {
            request.revision = VNDetectFaceLandmarksRequestRevision3
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch { return nil }

        guard let faces = request.results?.filter({ $0.confidence > 0.5 }), !faces.isEmpty else { return nil }
        return (cgImage, faces)
    }

    // MARK: - Closed Eyes Detection (Vision Framework)

    private static func detectClosedEyes(faces: [VNFaceObservation], analysis: inout QualityAnalysis) {
        var closedCount = 0
        let totalFaces = faces.count

        for face in faces {
            guard let landmarks = face.landmarks else { continue }

            var leftClosed = false
            var rightClosed = false

            if let leftEye = landmarks.leftEye {
                leftClosed = isEyeClosed(eye: leftEye)
            }
            if let rightEye = landmarks.rightEye {
                rightClosed = isEyeClosed(eye: rightEye)
            }

            if leftClosed && rightClosed {
                closedCount += 1
            }
        }

        if closedCount > 0 {
            let severity: QualityIssue.Severity = closedCount == totalFaces ? .bad : .warning
            analysis.issues.append(QualityIssue(
                type: .closedEyes, severity: severity,
                message: "눈 감김 감지 - \(totalFaces)명 중 \(closedCount)명 눈 감음"
            ))
        }
    }

    private static func isEyeClosed(eye: VNFaceLandmarkRegion2D) -> Bool {
        let points = eye.normalizedPoints
        guard points.count >= 4 else { return false }

        // Calculate eye aspect ratio (EAR)
        // Eye height vs width - closed eyes have very small height
        var minY: CGFloat = 1.0
        var maxY: CGFloat = 0.0
        var minX: CGFloat = 1.0
        var maxX: CGFloat = 0.0

        for point in points {
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
        }

        let height = maxY - minY
        let width = maxX - minX
        guard width > 0 else { return false }

        let aspectRatio = height / width
        // Typical open eye: 0.25~0.35, squinting: 0.12~0.18, closed: < 0.10
        return aspectRatio < 0.18
    }

    // MARK: - Smile / Expression Detection

    private static func detectSmile(faces: [VNFaceObservation], analysis: inout QualityAnalysis) {
        var totalSmile: Double = 0
        var faceCount = 0

        for face in faces {
            guard let landmarks = face.landmarks,
                  let outerLips = landmarks.outerLips else { continue }

            let score = calculateSmileScore(outerLips: outerLips)
            totalSmile += score
            faceCount += 1
        }

        guard faceCount > 0 else { return }
        let avgSmile = totalSmile / Double(faceCount)
        analysis.smileScore = avgSmile
        analysis.faceExpressionGood = avgSmile >= 0.3
    }

    /// Calculate smile score from outer lip landmarks.
    /// Measures how much the lip corners are raised relative to the center bottom of the mouth.
    private static func calculateSmileScore(outerLips: VNFaceLandmarkRegion2D) -> Double {
        let points = outerLips.normalizedPoints
        guard points.count >= 6 else { return 0 }

        // Outer lips typically: left corner -> bottom -> right corner -> top (clockwise or counter-clockwise)
        // Find leftmost, rightmost, and bottom-most points
        var leftCorner = points[0]
        var rightCorner = points[0]
        var bottomCenter = points[0]

        for point in points {
            if point.x < leftCorner.x { leftCorner = point }
            if point.x > rightCorner.x { rightCorner = point }
            if point.y < bottomCenter.y { bottomCenter = point }  // Vision: y=0 is bottom
        }

        // Smile: corners are higher (larger y) than center bottom
        let cornerAvgY = (leftCorner.y + rightCorner.y) / 2.0
        let mouthWidth = rightCorner.x - leftCorner.x
        guard mouthWidth > 0.01 else { return 0 }

        // Corner uplift relative to bottom center, normalized by mouth width
        let uplift = (cornerAvgY - bottomCenter.y) / mouthWidth

        // Map uplift to 0~1 score. Typical smile uplift: 0.1~0.4
        let score = max(0, min(1, uplift / 0.35))
        return score
    }

    private static func loadCGImage(url: URL, maxSize: Int) -> CGImage? {
        // Try hardware JPEG decode first
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        if isJPEG, HWJPEGDecoder.isAvailable, let hwImage = HWJPEGDecoder.decode(url: url, maxPixel: CGFloat(maxSize)) {
            return hwImage
        }
        // CPU fallback
        let options: [NSString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - EXIF Info

    private static func addExifInfo(photo: PhotoItem, analysis: inout QualityAnalysis) {
        guard let exif = photo.exifData else { return }

        if let iso = exif.iso, iso >= 12800 {
            analysis.issues.append(QualityIssue(
                type: .highISO, severity: .info,
                message: "고감도 ISO \(iso) (의도된 설정일 수 있음)"
            ))
        }

        if let exposureTime = exif.exposureTime, let focalLength = exif.focalLength {
            let safeShutter = 1.0 / max(focalLength, 30)
            if exposureTime > safeShutter * 3.0 && exposureTime < 0.5 {
                analysis.issues.append(QualityIssue(
                    type: .shakeRisk, severity: .info,
                    message: "저속 셔터 \(exif.shutterSpeed ?? "") @ \(Int(focalLength))mm"
                ))
            }
        }

        if let bias = exif.exposureBias, abs(bias) >= 2.5 {
            analysis.issues.append(QualityIssue(
                type: .exposureBias, severity: .info,
                message: "노출보정 \(String(format: "%+.1f", bias))EV"
            ))
        }
    }

    // MARK: - Optimized Grayscale (UInt8, no Float)

    private static func extractGrayscaleRaw(from cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixelData = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &pixelData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelData
    }

    // (calculateLaplacianFast 는 MetalImageProcessor.laplacianSharpness 로 대체되어 제거됨 — v8.6.1 dead code cleanup)

    // MARK: - Attention Saliency (Composition Score)

    /// Uses Vision's attention-based saliency to score composition (0-1).
    /// Strong focal point = high score, dispersed/flat attention = low score.
    static func computeCompositionScore(cgImage: CGImage) -> Double {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return 0
        }

        guard let result = request.results?.first else { return 0 }
        let pixelBuffer = result.pixelBuffer

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let totalPixels = width * height
        guard totalPixels > 0 else { return 0 }

        let floatPtr = base.assumingMemoryBound(to: Float32.self)

        // Single pass: find peak and accumulate for mean
        var sum: Double = 0
        var peak: Float32 = 0
        for y in 0..<height {
            let rowStart = y * bytesPerRow / MemoryLayout<Float32>.size
            for x in 0..<width {
                let val = floatPtr[rowStart + x]
                sum += Double(val)
                if val > peak { peak = val }
            }
        }

        guard peak > 0 else { return 0 }

        let mean = sum / Double(totalPixels)

        // Concentration: how focused is the attention?
        // High peak-to-mean ratio = strong focal point = good composition.
        // Clamp to 0-1 range. A ratio of ~5+ is very focused.
        let concentration = min(Double(peak) / max(mean, 1e-6), 10.0) / 10.0

        // Peak strength: absolute brightness of hottest spot
        let peakScore = min(Double(peak), 1.0)

        // Combine: 60% concentration + 40% peak strength
        return concentration * 0.6 + peakScore * 0.4
    }

    // MARK: - Center-weighted Sharp Region (64px blocks)

    private static func calculateSharpRegionFast(pixels: [UInt8], width: Int, height: Int) -> Double {
        let blockSize = 64
        let blocksX = width / blockSize
        let blocksY = height / blockSize
        guard blocksX > 0 && blocksY > 0 else { return 0 }

        // Higher threshold: LED edges/text shouldn't count as "sharp subject"
        let threshold: Double = 0.005
        var weightedSharp: Double = 0
        var totalWeight: Double = 0

        let centerBX = Double(blocksX) / 2.0
        let centerBY = Double(blocksY) / 2.0
        let maxDist = sqrt(centerBX * centerBX + centerBY * centerBY)

        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                var sum: Int64 = 0
                var sumSq: Int64 = 0
                var count = 0

                let startY = by * blockSize + 1
                let startX = bx * blockSize + 1
                let endY = min(startY + blockSize - 2, height - 2)
                let endX = min(startX + blockSize - 2, width - 2)

                for y in stride(from: startY, to: endY, by: 3) {
                    for x in stride(from: startX, to: endX, by: 3) {
                        let idx = y * width + x
                        let lap = -4 * Int(pixels[idx])
                            + Int(pixels[idx - 1])
                            + Int(pixels[idx + 1])
                            + Int(pixels[idx - width])
                            + Int(pixels[idx + width])
                        sum += Int64(lap)
                        sumSq += Int64(lap) * Int64(lap)
                        count += 1
                    }
                }

                guard count > 0 else { continue }
                let mean = Double(sum) / Double(count)
                let variance = (Double(sumSq) / Double(count) - mean * mean) / 255.0 / 255.0

                // Center-weighted: blocks near center matter more
                let dx = Double(bx) - centerBX
                let dy = Double(by) - centerBY
                let dist = sqrt(dx * dx + dy * dy) / maxDist // 0~1
                let weight = 1.0 + (1.0 - dist) * 2.0 // center=3x, edge=1x

                totalWeight += weight
                if variance > threshold {
                    weightedSharp += weight
                }
            }
        }

        return totalWeight > 0 ? weightedSharp / totalWeight : 0
    }
    // MARK: - Face Focus Detection

    private static func detectFaceFocus(cgImage: CGImage, faces: [VNFaceObservation], analysis: inout QualityAnalysis) {
        let width = cgImage.width
        let height = cgImage.height
        let imgSize = CGSize(width: width, height: height)

        // Convert to grayscale for sharpness check
        let graySpace = CGColorSpaceCreateDeviceGray()
        guard let grayCtx = CGContext(data: nil, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: width,
                                       space: graySpace, bitmapInfo: 0) else { return }
        grayCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let grayData = grayCtx.data else { return }
        let pixels = grayData.bindMemory(to: UInt8.self, capacity: width * height)

        var blurryFaces = 0
        for face in faces {
            // Build check regions: prefer eye landmarks, fall back to face box
            var checkRects: [CGRect] = []

            if let landmarks = face.landmarks {
                for eye in [landmarks.leftEye, landmarks.rightEye].compactMap({ $0 }) {
                    let pts = eye.pointsInImage(imageSize: imgSize)
                    var minX = CGFloat.greatestFiniteMagnitude, maxX: CGFloat = 0
                    var minY = CGFloat.greatestFiniteMagnitude, maxY: CGFloat = 0
                    for p in pts {
                        minX = min(minX, p.x); maxX = max(maxX, p.x)
                        minY = min(minY, p.y); maxY = max(maxY, p.y)
                    }
                    // Expand eye region by 50% for reliable Laplacian sampling
                    let eyeW = maxX - minX, eyeH = maxY - minY
                    // Vision coords origin bottom-left -> flip Y for pixel access (top-left)
                    let cy = CGFloat(height) - ((minY + maxY) / 2)
                    checkRects.append(CGRect(
                        x: minX - eyeW * 0.25, y: cy - eyeH * 0.75,
                        width: eyeW * 1.5, height: eyeH * 1.5
                    ))
                }
            }

            if checkRects.isEmpty {
                let box = face.boundingBox
                let fx = box.origin.x * CGFloat(width)
                let fy = (1 - box.origin.y - box.height) * CGFloat(height)
                checkRects.append(CGRect(x: fx, y: fy,
                                         width: box.width * CGFloat(width),
                                         height: box.height * CGFloat(height)))
            }

            // Calculate Laplacian variance across check regions
            var sumSq: Int64 = 0
            var count = 0
            let totalPixels = width * height

            for rect in checkRects {
                let rx = max(2, Int(rect.origin.x))
                let ry = max(2, Int(rect.origin.y))
                let rw = Int(rect.width)
                let rh = Int(rect.height)

                for y in stride(from: ry, to: min(height - 2, ry + rh), by: 2) {
                    for x in stride(from: rx, to: min(width - 2, rx + rw), by: 2) {
                        let idx = y * width + x
                        guard idx >= width && idx + width < totalPixels else { continue }
                        let lap = -4 * Int(pixels[idx])
                            + Int(pixels[idx - 1]) + Int(pixels[idx + 1])
                            + Int(pixels[idx - width]) + Int(pixels[idx + width])
                        sumSq += Int64(lap * lap)
                        count += 1
                    }
                }
            }

            guard count > 0 else { continue }
            let variance = Double(sumSq) / Double(count) / 255.0 / 255.0 * 10000
            if variance < 30 { blurryFaces += 1 }
        }

        if blurryFaces > 0 {
            let severity: QualityIssue.Severity = blurryFaces == faces.count ? .bad : .warning
            analysis.issues.append(QualityIssue(
                type: .faceOutOfFocus, severity: severity,
                message: "인물 초점 미스 - \(faces.count)명 중 \(blurryFaces)명 흐림"
            ))
        }
    }

    // MARK: - Duplicate Photo Grouping

    /// Group similar photos by histogram comparison. Returns groupID assignments.
    static func findDuplicateGroups(photos: [PhotoItem]) -> [UUID: (groupID: Int, isBest: Bool)] {
        guard photos.count > 1 else { return [:] }

        // Compute compact histogram for each photo
        var histograms: [(id: UUID, hist: [Int], sharpness: Double)] = []

        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: photos.count) { i in
            autoreleasepool {
                let photo = photos[i]
                if let hist = computeCompactHistogram(url: photo.jpgURL) {
                    let sharp = photo.quality?.sharpnessScore ?? 0
                    lock.lock()
                    defer { lock.unlock() }
                    histograms.append((id: photo.id, hist: hist, sharpness: sharp))
                }
            }
        }

        // Compare histograms to find similar photos (consecutive shots)
        // Sort by filename to group consecutive shots
        histograms.sort { $0.id.uuidString < $1.id.uuidString }

        var groups: [UUID: (groupID: Int, isBest: Bool)] = [:]
        var groupID = 0
        var currentGroup: [(id: UUID, sharpness: Double)] = []
        var groupFirstHistIdx = 0  // Index of first histogram in current group

        for i in 0..<histograms.count {
            if currentGroup.isEmpty {
                currentGroup.append((histograms[i].id, histograms[i].sharpness))
                groupFirstHistIdx = i
                continue
            }

            // Compare with first member of current group (not just previous)
            let similarity = histogramSimilarity(histograms[i].hist, histograms[groupFirstHistIdx].hist)

            if similarity > 0.92 {
                currentGroup.append((histograms[i].id, histograms[i].sharpness))
            } else {
                if currentGroup.count > 1, let best = currentGroup.enumerated().max(by: { $0.element.sharpness < $1.element.sharpness }) {
                    for (j, member) in currentGroup.enumerated() {
                        groups[member.id] = (groupID: groupID, isBest: j == best.offset)
                    }
                    groupID += 1
                }
                currentGroup = [(histograms[i].id, histograms[i].sharpness)]
                groupFirstHistIdx = i
            }
        }

        // Finalize last group
        if currentGroup.count > 1, let best = currentGroup.enumerated().max(by: { $0.element.sharpness < $1.element.sharpness }) {
            for (j, member) in currentGroup.enumerated() {
                groups[member.id] = (groupID: groupID, isBest: j == best.offset)
            }
        }

        return groups
    }

    /// Compact 64-bin histogram (R+G+B combined luminance)
    private static func computeCompactHistogram(url: URL) -> [Int]? {
        // Load thumbnail: try HW JPEG decode first
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        let cgImage: CGImage
        if isJPEG, HWJPEGDecoder.isAvailable, let hwImage = HWJPEGDecoder.decode(url: url, maxPixel: 200) {
            cgImage = hwImage
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 200,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let swImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
            cgImage = swImage
        }

        // Try GPU histogram via Metal, then collapse 256 -> 64 bins
        if MetalImageProcessor.isAvailable, let gpuHist = MetalImageProcessor.histogram(image: cgImage) {
            var hist = [Int](repeating: 0, count: 64)
            for i in 0..<256 {
                let bin = i / 4  // 256 -> 64 bins
                hist[bin] += gpuHist.l[i]
            }
            return hist
        }

        // CPU fallback
        let w = cgImage.width, h = cgImage.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var hist = [Int](repeating: 0, count: 64)
        let total = w * h
        for i in stride(from: 0, to: total * 4, by: 8) { // Sample every 2nd pixel
            let lum = (Int(pixels[i]) * 299 + Int(pixels[i+1]) * 587 + Int(pixels[i+2]) * 114) / 1000
            hist[lum >> 2] += 1  // 256 bins → 64 bins
        }
        return hist
    }

    /// Histogram intersection similarity (0~1, higher = more similar)
    private static func histogramSimilarity(_ a: [Int], _ b: [Int]) -> Double {
        guard a.count == b.count else { return 0 }
        var intersection = 0
        var totalA = 0
        for i in 0..<a.count {
            intersection += min(a[i], b[i])
            totalA += a[i]
        }
        return totalA > 0 ? Double(intersection) / Double(totalA) : 0
    }
    // MARK: - Person Segmentation

    /// Result of person segmentation analysis
    struct PersonSegmentationResult {
        /// Whether a person was detected in the image
        let personDetected: Bool
        /// Ratio of image area covered by person (0.0 - 1.0)
        let coverageRatio: Double
    }

    /// Detect person presence and coverage using VNGeneratePersonSegmentationRequest.
    /// Uses .fast quality for speed. Downsamples to max 512px before processing.
    static func analyzePersonSegmentation(url: URL) -> PersonSegmentationResult {
        guard let cgImage = loadCGImage(url: url, maxSize: 512) else {
            return PersonSegmentationResult(personDetected: false, coverageRatio: 0)
        }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return PersonSegmentationResult(personDetected: false, coverageRatio: 0)
        }

        guard let result = request.results?.first else {
            return PersonSegmentationResult(personDetected: false, coverageRatio: 0)
        }
        let mask = result.pixelBuffer

        // Calculate coverage ratio from the mask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else {
            return PersonSegmentationResult(personDetected: false, coverageRatio: 0)
        }

        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        var personPixels = 0
        let totalPixels = maskWidth * maskHeight
        let threshold: UInt8 = 128

        for y in 0..<maskHeight {
            let rowStart = y * bytesPerRow
            for x in 0..<maskWidth {
                if buffer[rowStart + x] > threshold {
                    personPixels += 1
                }
            }
        }

        let coverage = totalPixels > 0 ? Double(personPixels) / Double(totalPixels) : 0
        return PersonSegmentationResult(personDetected: coverage > 0.01, coverageRatio: coverage)
    }
}

// MARK: - Thread-safe helpers

private class ConcurrentDict<K: Hashable, V> {
    private var dict: [K: V] = [:]
    private let lock = NSLock()

    func set(_ key: K, value: V) {
        lock.lock()
        defer { lock.unlock() }
        dict[key] = value
    }

    func snapshot() -> [K: V] {
        lock.lock()
        defer { lock.unlock() }
        return dict
    }
}

private class AtomicCounter {
    private var value: Int = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        let result = value
        return result
    }
}
