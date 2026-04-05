import Foundation
import CoreImage
import CoreML
import Vision
import AppKit

/// Super Resolution 서비스
/// 썸네일을 고품질 업스케일하여 풀해상도 로딩 전 즉시 선명한 프리뷰 제공
/// CoreML 모델(Real-ESRGAN) 있으면 NPU 가속, 없으면 Lanczos + 샤프닝 파이프라인 사용
struct SuperResolutionService {

    // MARK: - Shared CIContext (GPU 가속)

    private static let ciContext: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }()

    // MARK: - CoreML 모델 (lazy, thread-safe)

    private static var mlModel: MLModel?
    private static let modelLock = NSLock()
    private static var modelLoadAttempted = false

    /// CoreML SR 모델 로딩 (RealESRGAN)
    private static func loadModel() -> MLModel? {
        modelLock.lock()
        defer { modelLock.unlock() }

        if let cached = mlModel { return cached }
        if modelLoadAttempted { return nil }
        modelLoadAttempted = true

        // .mlmodelc (컴파일됨) 먼저 시도
        if let modelURL = Bundle.main.url(forResource: "RealESRGAN", withExtension: "mlmodelc") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all  // Neural Engine(NPU) + GPU + CPU 전부 활용
                let model = try MLModel(contentsOf: modelURL, configuration: config)
                mlModel = model
                AppLogger.log(.general, "SuperResolution: CoreML 모델 로딩 성공 (mlmodelc)")
                return model
            } catch {
                AppLogger.log(.error, "SuperResolution: CoreML 모델 로딩 실패 - \(error)")
            }
        }

        // .mlpackage 시도 (첫 실행 시 자동 컴파일)
        if let rawURL = Bundle.main.url(forResource: "RealESRGAN", withExtension: "mlpackage") {
            do {
                let compiledURL = try MLModel.compileModel(at: rawURL)
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let model = try MLModel(contentsOf: compiledURL, configuration: config)
                mlModel = model
                AppLogger.log(.general, "SuperResolution: CoreML 모델 로딩 성공 (mlpackage 컴파일)")
                return model
            } catch {
                AppLogger.log(.error, "SuperResolution: CoreML 모델 컴파일 실패 - \(error)")
            }
        }

        AppLogger.log(.general, "SuperResolution: CoreML 모델 없음 → Lanczos 폴백 사용")
        return nil
    }

    /// CoreML SR 모델 사용 가능 여부
    static var isModelAvailable: Bool {
        return Bundle.main.url(forResource: "RealESRGAN", withExtension: "mlmodelc") != nil ||
               Bundle.main.url(forResource: "RealESRGAN", withExtension: "mlpackage") != nil
    }

    // MARK: - Built-in 업스케일 (Lanczos + 샤프닝)

    /// CGImage를 2배 업스케일 (Lanczos 보간 + CAS 샤프닝)
    /// 썸네일 → 프리뷰 전환 시 즉시 선명한 이미지 제공
    static func upscale2x(cgImage: CGImage) -> CGImage? {
        let targetW = cgImage.width * 2
        let targetH = cgImage.height * 2
        return upscale(cgImage: cgImage, targetWidth: targetW, targetHeight: targetH)
    }

    /// CGImage를 지정 크기로 업스케일 (Lanczos + 멀티스테이지 샤프닝)
    static func upscale(cgImage: CGImage, targetWidth: Int, targetHeight: Int) -> CGImage? {
        let sourceW = cgImage.width
        let sourceH = cgImage.height

        // 원본보다 작으면 업스케일 불필요
        guard targetWidth > sourceW || targetHeight > sourceH else { return cgImage }

        let ciImage = CIImage(cgImage: cgImage)

        // 스케일 계산
        let scaleX = Double(targetWidth) / Double(sourceW)
        let scaleY = Double(targetHeight) / Double(sourceH)
        let scale = max(scaleX, scaleY)

        // 1단계: Lanczos 리샘플링 (고품질 보간)
        guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        lanczos.setValue(ciImage, forKey: kCIInputImageKey)
        lanczos.setValue(scale, forKey: kCIInputScaleKey)
        lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let scaled = lanczos.outputImage else { return nil }

        // 2단계: Unsharp Mask (에지 선명도 향상)
        guard let unsharp = CIFilter(name: "CIUnsharpMask") else { return nil }
        unsharp.setValue(scaled, forKey: kCIInputImageKey)
        unsharp.setValue(1.5, forKey: kCIInputRadiusKey)       // 반경 1.5px
        unsharp.setValue(0.5, forKey: kCIInputIntensityKey)     // 강도 50%

        guard let sharpened = unsharp.outputImage else { return nil }

        // 3단계: 루미넌스 샤프닝 (색상 변경 없이 밝기 채널만 샤프닝)
        guard let lumSharpen = CIFilter(name: "CISharpenLuminance") else { return nil }
        lumSharpen.setValue(sharpened, forKey: kCIInputImageKey)
        lumSharpen.setValue(0.3, forKey: kCIInputSharpnessKey)  // 샤프니스 0.3

        guard let finalImage = lumSharpen.outputImage else { return nil }

        // CIContext로 렌더링 (GPU 가속)
        let outputRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        return ciContext.createCGImage(finalImage, from: outputRect)
    }

    // MARK: - CoreML Super Resolution (NPU 가속)

    /// CoreML 기반 초해상도 업스케일
    /// RealESRGAN 모델이 있으면 Neural Engine으로 추론, 없으면 Lanczos 폴백
    /// - Parameters:
    ///   - cgImage: 입력 이미지
    ///   - scale: 업스케일 배율 (기본 2x)
    /// - Returns: 업스케일된 CGImage, 실패 시 nil
    static func superResolve(cgImage: CGImage, scale: Int = 2) -> CGImage? {
        // CoreML 모델 로딩 시도
        guard let model = loadModel() else {
            // 모델 없으면 Lanczos 폴백
            AppLogger.log(.general, "SuperResolution: CoreML 모델 없음 → Lanczos \(scale)x 폴백")
            return upscale(
                cgImage: cgImage,
                targetWidth: cgImage.width * scale,
                targetHeight: cgImage.height * scale
            )
        }

        // CoreML 추론 (NPU 가속)
        do {
            // 입력 이미지 → CVPixelBuffer 변환
            let width = cgImage.width
            let height = cgImage.height

            var pixelBuffer: CVPixelBuffer?
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width, height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )

            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                AppLogger.log(.error, "SuperResolution: PixelBuffer 생성 실패")
                return upscale2x(cgImage: cgImage)
            }

            // CGImage → PixelBuffer 복사
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])

            // MLFeatureProvider로 입력 구성
            let inputFeature = try MLDictionaryFeatureProvider(dictionary: [
                "input": MLFeatureValue(pixelBuffer: buffer)
            ])

            // 모델 추론 실행 (NPU/GPU/CPU 자동 선택)
            let output = try model.prediction(from: inputFeature)

            // 출력 PixelBuffer → CGImage 변환
            guard let outputValue = output.featureValue(for: "output"),
                  let outputBuffer = outputValue.imageBufferValue else {
                AppLogger.log(.error, "SuperResolution: 모델 출력 파싱 실패")
                return upscale2x(cgImage: cgImage)
            }

            let ciOutput = CIImage(cvPixelBuffer: outputBuffer)
            let outputW = CVPixelBufferGetWidth(outputBuffer)
            let outputH = CVPixelBufferGetHeight(outputBuffer)

            guard let resultImage = ciContext.createCGImage(
                ciOutput,
                from: CGRect(x: 0, y: 0, width: outputW, height: outputH)
            ) else {
                return upscale2x(cgImage: cgImage)
            }

            AppLogger.log(.general, "SuperResolution: CoreML 추론 완료 \(width)x\(height) → \(outputW)x\(outputH)")
            return resultImage

        } catch {
            AppLogger.log(.error, "SuperResolution: CoreML 추론 실패 - \(error)")
            return upscale(
                cgImage: cgImage,
                targetWidth: cgImage.width * scale,
                targetHeight: cgImage.height * scale
            )
        }
    }

    // MARK: - 편의 메서드

    /// NSImage 입력 → 업스케일된 NSImage 출력
    static func upscale2x(image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard let upscaled = superResolve(cgImage: cgImage, scale: 2) else { return nil }
        return NSImage(cgImage: upscaled, size: NSSize(width: upscaled.width, height: upscaled.height))
    }

    /// URL에서 썸네일 로딩 + 업스케일 (메모리 효율적)
    static func upscaledThumbnail(url: URL, maxEdge: Int = 1280) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }

        // 먼저 작은 썸네일 추출
        let thumbSize = maxEdge / 2  // 업스케일 전 절반 크기
        let opts: [NSString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: thumbSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }

        // 2x 업스케일로 선명도 향상
        return superResolve(cgImage: thumbnail, scale: 2)
    }
}
