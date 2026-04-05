import Foundation
import CoreImage
import CoreML
import Vision

// MARK: - NPU 가속 AI 사진 보정 서비스

struct AIEnhanceService {

    // GPU 가속 CIContext (스레드 안전)
    private static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ]
        return CIContext(options: options)
    }()

    // MARK: - CoreML 모델 가용성

    /// PhotoEnhancer CoreML 모델이 번들에 존재하는지 확인
    static var isAIModelAvailable: Bool {
        Bundle.main.url(forResource: "PhotoEnhancer", withExtension: "mlmodelc") != nil
    }

    /// Denoiser CoreML 모델 가용성
    private static var isDenoiserAvailable: Bool {
        Bundle.main.url(forResource: "Denoiser", withExtension: "mlmodelc") != nil
    }

    // MARK: - AI 톤/색감 보정

    /// 프로급 자동 보정 (CoreML NPU 또는 고급 CIFilter 파이프라인)
    static func enhance(image: CIImage) -> CIImage {
        // CoreML 모델이 있으면 NPU 추론 사용
        if isAIModelAvailable, let enhanced = enhanceWithCoreML(image: image) {
            return enhanced
        }

        // Fallback: 고급 CIFilter 파이프라인 (프로 편집 시뮬레이션)
        return enhanceWithFilters(image: image)
    }

    /// CoreML NPU 추론으로 보정
    private static func enhanceWithCoreML(image: CIImage) -> CIImage? {
        guard let modelURL = Bundle.main.url(forResource: "PhotoEnhancer", withExtension: "mlmodelc") else {
            return nil
        }

        do {
            // Neural Engine 우선 사용 설정
            let config = MLModelConfiguration()
            config.computeUnits = .all  // NPU > GPU > CPU 자동 선택
            let model = try MLModel(contentsOf: modelURL, configuration: config)

            // 입력 이미지 리사이즈 (모델 입력 크기에 맞춤)
            let targetSize = CGSize(width: 512, height: 512)
            let scaleX = targetSize.width / image.extent.width
            let scaleY = targetSize.height / image.extent.height
            let resized = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            guard let pixelBuffer = createPixelBuffer(from: resized, size: targetSize) else {
                return nil
            }

            let input = try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)]
            )
            let output = try model.prediction(from: input)

            // 출력에서 보정된 이미지 추출
            if let outputImage = output.featureValue(for: "enhanced")?.imageBufferValue {
                let ciOutput = CIImage(cvPixelBuffer: outputImage)
                // 원본 크기로 복원
                let restoreX = image.extent.width / targetSize.width
                let restoreY = image.extent.height / targetSize.height
                return ciOutput.transformed(by: CGAffineTransform(scaleX: restoreX, y: restoreY))
            }
        } catch {
            AppLogger.log(.general, "AI Enhance CoreML 오류: \(error.localizedDescription)")
        }

        return nil
    }

    /// 고급 CIFilter 파이프라인 (프로 편집 시뮬레이션)
    private static func enhanceWithFilters(image: CIImage) -> CIImage {
        var result = image

        // 1. 컬러 컨트롤: 약간의 대비 + 채도 향상
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(Float(1.05), forKey: "inputContrast")       // +0.05 미세 대비
            filter.setValue(Float(1.08), forKey: "inputSaturation")     // +0.08 미세 채도
            if let output = filter.outputImage {
                result = output
            }
        }

        // 2. Vibrance: 채도보다 자연스러운 색감 향상
        if let filter = CIFilter(name: "CIVibrance") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(Float(0.15), forKey: "inputAmount")  // 자연스러운 수준
            if let output = filter.outputImage {
                result = output
            }
        }

        // 3. 하이라이트/섀도우 복구: 다이나믹 레인지 확보
        if let filter = CIFilter(name: "CIHighlightShadowAdjust") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(Float(0.8), forKey: "inputHighlightAmount")   // 하이라이트 -0.2
            filter.setValue(Float(0.3), forKey: "inputShadowAmount")     // 섀도우 +0.3
            if let output = filter.outputImage {
                result = output
            }
        }

        // 4. 톤 커브: 부드러운 S커브 (필름 느낌 대비)
        if let filter = CIFilter(name: "CIToneCurve") {
            filter.setValue(result, forKey: kCIInputImageKey)
            // 부드러운 S커브: 섀도우 살짝 올리고, 하이라이트 살짝 내림
            filter.setValue(CIVector(x: 0.0, y: 0.0), forKey: "inputPoint0")
            filter.setValue(CIVector(x: 0.25, y: 0.28), forKey: "inputPoint1")  // 섀도우 리프트
            filter.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")    // 미드톤 유지
            filter.setValue(CIVector(x: 0.75, y: 0.72), forKey: "inputPoint3")  // 하이라이트 롤오프
            filter.setValue(CIVector(x: 1.0, y: 1.0), forKey: "inputPoint4")
            if let output = filter.outputImage {
                result = output
            }
        }

        // 5. 화이트밸런스 자동 보정: 평균 색상 분석 기반
        result = autoWhiteBalanceByAverage(image: result)

        return result
    }

    /// 평균 색상 분석으로 화이트밸런스 추정
    private static func autoWhiteBalanceByAverage(image: CIImage) -> CIImage {
        // 다운샘플로 평균 색상 계산
        let scale = min(200.0 / image.extent.width, 200.0 / image.extent.height, 1.0)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return image
        }

        let width = cgImage.width
        let height = cgImage.height
        let totalPixels = width * height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: totalPixels * 4)

        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sumR: Double = 0, sumG: Double = 0, sumB: Double = 0
        for i in stride(from: 0, to: totalPixels * 4, by: 4) {
            sumR += Double(pixels[i])
            sumG += Double(pixels[i + 1])
            sumB += Double(pixels[i + 2])
        }

        let avgR = sumR / Double(totalPixels)
        let avgG = sumG / Double(totalPixels)
        let avgB = sumB / Double(totalPixels)

        // R/B 비율로 색온도 추정
        let rbRatio = avgR / max(avgB, 1)
        var temperature: Double
        if rbRatio > 1.15 {
            temperature = 4500 + (1.5 - rbRatio) * 1500  // 따뜻한 이미지
        } else if rbRatio < 0.85 {
            temperature = 7500 + (0.85 - rbRatio) * 2000  // 차가운 이미지
        } else {
            return image  // 이미 중립 — 보정 불필요
        }
        temperature = max(3500, min(9000, temperature))

        let tint = (avgG / ((avgR + avgB) / 2.0) - 1.0) * 30.0

        // 편차가 작으면 스킵
        if abs(temperature - 6500) < 300 && abs(tint) < 5 {
            return image
        }

        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: CGFloat(temperature), y: CGFloat(tint)), forKey: "inputNeutral")
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")

        return filter.outputImage ?? image
    }

    // MARK: - AI 디노이즈

    /// AI 기반 노이즈 제거 (CoreML NPU 또는 CIFilter 폴백)
    /// - Parameters:
    ///   - image: 원본 이미지
    ///   - strength: 디노이즈 강도 (0.0~1.0, 기본 0.5)
    static func denoise(image: CIImage, strength: Float = 0.5) -> CIImage {
        let clampedStrength = max(0.0, min(1.0, strength))

        // CoreML Denoiser 모델이 있으면 NPU 추론
        if isDenoiserAvailable, let denoised = denoiseWithCoreML(image: image, strength: clampedStrength) {
            return denoised
        }

        // Fallback: CIFilter 조합
        return denoiseWithFilters(image: image, strength: clampedStrength)
    }

    /// CoreML NPU 추론 디노이즈
    private static func denoiseWithCoreML(image: CIImage, strength: Float) -> CIImage? {
        guard let modelURL = Bundle.main.url(forResource: "Denoiser", withExtension: "mlmodelc") else {
            return nil
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all  // NPU 우선
            let model = try MLModel(contentsOf: modelURL, configuration: config)

            let targetSize = CGSize(width: 512, height: 512)
            let scaleX = targetSize.width / image.extent.width
            let scaleY = targetSize.height / image.extent.height
            let resized = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            guard let pixelBuffer = createPixelBuffer(from: resized, size: targetSize) else {
                return nil
            }

            let input = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: pixelBuffer),
                "strength": MLFeatureValue(double: Double(strength))
            ])
            let output = try model.prediction(from: input)

            if let outputImage = output.featureValue(for: "denoised")?.imageBufferValue {
                let ciOutput = CIImage(cvPixelBuffer: outputImage)
                let restoreX = image.extent.width / targetSize.width
                let restoreY = image.extent.height / targetSize.height
                return ciOutput.transformed(by: CGAffineTransform(scaleX: restoreX, y: restoreY))
            }
        } catch {
            AppLogger.log(.general, "AI Denoise CoreML 오류: \(error.localizedDescription)")
        }

        return nil
    }

    /// CIFilter 기반 디노이즈 (폴백)
    private static func denoiseWithFilters(image: CIImage, strength: Float) -> CIImage {
        var result = image

        // 1. CINoiseReduction: 주요 노이즈 제거
        if let filter = CIFilter(name: "CINoiseReduction") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(strength * 0.06, forKey: "inputNoiseLevel")   // 강도에 비례
            filter.setValue(Float(0.3), forKey: "inputSharpness")         // 선명도 보존
            if let output = filter.outputImage {
                result = output
            }
        }

        // 2. CIMedianFilter: 솔트앤페퍼 노이즈 제거 (강도 높을 때만)
        if strength > 0.6 {
            if let filter = CIFilter(name: "CIMedianFilter") {
                filter.setValue(result, forKey: kCIInputImageKey)
                if let output = filter.outputImage {
                    result = output
                }
            }
        }

        return result
    }

    // MARK: - 인물 인식 선택적 보정

    /// 인물 세그멘테이션 마스크 기반 차별 보정
    /// - 인물: 피부톤 보존 + 약간 따뜻한 톤
    /// - 배경: 더 공격적인 색감 보정 + 미세 블러 (보케 효과)
    static func enhanceWithPersonMask(image: CIImage) -> CIImage {
        // Vision 인물 세그멘테이션 요청
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            AppLogger.log(.general, "인물 세그멘테이션 실패: \(error.localizedDescription)")
            // 인물 감지 실패 시 일반 enhance 적용
            return enhance(image: image)
        }

        guard let observation = request.results?.first,
              let maskBuffer = observation.pixelBuffer as CVPixelBuffer? else {
            return enhance(image: image)
        }

        // 마스크 → CIImage (인물=흰색, 배경=검정)
        let maskCI = CIImage(cvPixelBuffer: maskBuffer)
        // 마스크를 원본 크기로 리사이즈
        let maskScaleX = image.extent.width / maskCI.extent.width
        let maskScaleY = image.extent.height / maskCI.extent.height
        let scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: maskScaleX, y: maskScaleY))

        // 인물 영역 보정: 피부톤 보존 + 약간 따뜻한 톤
        let personEnhanced = enhancePerson(image: image)

        // 배경 영역 보정: 공격적 색감 + 미세 블러 (보케 효과)
        let backgroundEnhanced = enhanceBackground(image: image)

        // CIBlendWithMask로 합성
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else {
            return enhance(image: image)
        }
        blendFilter.setValue(personEnhanced, forKey: kCIInputImageKey)
        blendFilter.setValue(backgroundEnhanced, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(scaledMask, forKey: "inputMaskImage")

        return blendFilter.outputImage ?? enhance(image: image)
    }

    /// 인물 영역 보정: 피부톤 보존, 약간 따뜻한 톤
    private static func enhancePerson(image: CIImage) -> CIImage {
        var result = image

        // 미세한 따뜻한 톤 (피부 보정)
        if let filter = CIFilter(name: "CITemperatureAndTint") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 6200, y: 0), forKey: "inputNeutral")
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            if let output = filter.outputImage {
                result = output
            }
        }

        // 약간의 대비 + Vibrance (자연스러운 피부)
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(Float(1.03), forKey: "inputContrast")
            filter.setValue(Float(1.0), forKey: "inputSaturation")    // 피부 채도 유지
            if let output = filter.outputImage {
                result = output
            }
        }

        return result
    }

    /// 배경 영역 보정: 공격적 색감 보정 + 미세 블러
    private static func enhanceBackground(image: CIImage) -> CIImage {
        var result = image

        // 더 공격적인 색감 보정
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(Float(1.08), forKey: "inputContrast")
            filter.setValue(Float(1.12), forKey: "inputSaturation")
            if let output = filter.outputImage {
                result = output
            }
        }

        if let filter = CIFilter(name: "CIVibrance") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(Float(0.2), forKey: "inputAmount")
            if let output = filter.outputImage {
                result = output
            }
        }

        // 미세 블러 (보케 효과 시뮬레이션)
        if let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(Float(2.0), forKey: "inputRadius")  // 미세한 블러
            if let output = filter.outputImage {
                // 블러로 확장된 영역을 원본 크기로 크롭
                result = output.cropped(to: image.extent)
            }
        }

        return result
    }

    // MARK: - 유틸리티

    /// CIImage → CVPixelBuffer 변환 (CoreML 입력용)
    private static func createPixelBuffer(from image: CIImage, size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        context.render(image, to: buffer)
        return buffer
    }
}
