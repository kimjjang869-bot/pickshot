import Foundation
import CoreML
import Vision
import AppKit

/// NIMA (Neural Image Assessment) 서비스
/// CoreML 모델로 사진의 미적 품질을 1~10점으로 평가
struct NIMAService {

    // MARK: - Singleton Model

    private static var model: VNCoreMLModel?
    private static let modelLock = NSLock()

    /// CoreML 모델 로딩 (lazy, thread-safe)
    private static func loadModel() -> VNCoreMLModel? {
        modelLock.lock()
        defer { modelLock.unlock() }

        if let cached = model { return cached }

        // 번들에서 .mlmodelc 로딩
        guard let modelURL = Bundle.main.url(forResource: "NIMAAesthetic", withExtension: "mlmodelc") else {
            // .mlmodel도 시도 (첫 실행 시 자동 컴파일)
            guard let rawURL = Bundle.main.url(forResource: "NIMAAesthetic", withExtension: "mlmodel") else {
                AppLogger.log(.general, "NIMA: 모델 파일 없음 (NIMAAesthetic.mlmodel)")
                return nil
            }
            do {
                let compiledURL = try MLModel.compileModel(at: rawURL)
                let config = MLModelConfiguration()
                config.computeUnits = .all  // GPU 가속
                let mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
                let vnModel = try VNCoreMLModel(for: mlModel)
                model = vnModel
                AppLogger.log(.general, "NIMA: 모델 로딩 성공 (컴파일)")
                return vnModel
            } catch {
                AppLogger.log(.general, "NIMA: 모델 컴파일 실패 - \(error)")
                return nil
            }
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            let vnModel = try VNCoreMLModel(for: mlModel)
            model = vnModel
            AppLogger.log(.general, "NIMA: 모델 로딩 성공")
            return vnModel
        } catch {
            AppLogger.log(.general, "NIMA: 모델 로딩 실패 - \(error)")
            return nil
        }
    }

    /// 모델 사용 가능 여부
    static var isAvailable: Bool {
        return Bundle.main.url(forResource: "NIMAAesthetic", withExtension: "mlmodelc") != nil ||
               Bundle.main.url(forResource: "NIMAAesthetic", withExtension: "mlmodel") != nil
    }

    // MARK: - Single Image Score

    /// 단일 이미지 미적 품질 점수 (1.0 ~ 10.0)
    /// - Returns: 미적 점수 (높을수록 좋음), 실패 시 nil
    static func score(cgImage: CGImage) -> Double? {
        guard let vnModel = loadModel() else { return nil }

        var result: Double?
        let request = VNCoreMLRequest(model: vnModel) { request, error in
            guard let observations = request.results as? [VNCoreMLFeatureValueObservation],
                  let first = observations.first,
                  let multiArray = first.featureValue.multiArrayValue else { return }

            // 10-element softmax → mean score
            var meanScore: Double = 0
            for i in 0..<min(10, multiArray.count) {
                meanScore += multiArray[i].doubleValue * Double(i + 1)
            }
            result = meanScore
        }

        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        return result
    }

    /// URL에서 이미지 로딩 + 점수 계산
    static func score(url: URL) -> Double? {
        // 224×224로 리사이즈된 썸네일 사용 (빠름)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [NSString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 224,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        return score(cgImage: cgImage)
    }

    // MARK: - Technical Quality Model

    private static var technicalModel: VNCoreMLModel?

    /// Technical 모델 로딩
    private static func loadTechnicalModel() -> VNCoreMLModel? {
        modelLock.lock()
        defer { modelLock.unlock() }

        if let cached = technicalModel { return cached }

        guard let modelURL = Bundle.main.url(forResource: "NIMATechnical", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "NIMATechnical", withExtension: "mlmodel") else {
            return nil
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all

            let compiledURL: URL
            if modelURL.pathExtension == "mlmodel" {
                compiledURL = try MLModel.compileModel(at: modelURL)
            } else {
                compiledURL = modelURL
            }

            let mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
            let vnModel = try VNCoreMLModel(for: mlModel)
            technicalModel = vnModel
            AppLogger.log(.general, "NIMA Technical: 모델 로딩 성공")
            return vnModel
        } catch {
            AppLogger.log(.general, "NIMA Technical: 모델 로딩 실패 - \(error)")
            return nil
        }
    }

    static var isTechnicalAvailable: Bool {
        Bundle.main.url(forResource: "NIMATechnical", withExtension: "mlmodelc") != nil ||
        Bundle.main.url(forResource: "NIMATechnical", withExtension: "mlmodel") != nil
    }

    /// 기술적 품질 점수 (1.0 ~ 10.0) — 선명도, 노이즈, 노출, 색상 정확성
    static func technicalScore(cgImage: CGImage) -> Double? {
        guard let vnModel = loadTechnicalModel() else { return nil }

        var result: Double?
        let request = VNCoreMLRequest(model: vnModel) { request, error in
            guard let observations = request.results as? [VNCoreMLFeatureValueObservation],
                  let first = observations.first,
                  let multiArray = first.featureValue.multiArrayValue else { return }

            var meanScore: Double = 0
            for i in 0..<min(10, multiArray.count) {
                meanScore += multiArray[i].doubleValue * Double(i + 1)
            }
            result = meanScore
        }

        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return result
    }

    /// 종합 점수: aesthetic 60% + technical 40% (둘 다 있을 때)
    static func combinedScore(cgImage: CGImage) -> (aesthetic: Double, technical: Double?, combined: Double)? {
        guard let aesthetic = score(cgImage: cgImage) else { return nil }
        let technical = technicalScore(cgImage: cgImage)

        let combined: Double
        if let tech = technical {
            combined = aesthetic * 0.6 + tech * 0.4
        } else {
            combined = aesthetic
        }

        return (aesthetic: aesthetic, technical: technical, combined: combined)
    }

    // MARK: - Batch Scoring

    /// 배치 NIMA 점수 계산 (aesthetic + technical 종합)
    static func scoreBatch(
        photos: [PhotoItem],
        cancelCheck: @escaping () -> Bool,
        progress: @escaping (Int) -> Void
    ) -> [UUID: Double] {
        guard isAvailable else { return [:] }

        var results: [UUID: Double] = [:]
        let lock = NSLock()

        // 동시 처리 (CPU 코어 수 기반, 최대 4)
        DispatchQueue.concurrentPerform(iterations: photos.count) { i in
            if cancelCheck() { return }

            let photo = photos[i]
            guard !photo.isFolder && !photo.isParentFolder else { return }

            autoreleasepool {
                // 224×224 썸네일 한 번만 생성
                let opts: [NSString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 224,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let source = CGImageSourceCreateWithURL(photo.jpgURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return }

                if let result = combinedScore(cgImage: cgImage) {
                    lock.lock()
                    results[photo.id] = result.combined
                    lock.unlock()
                }
            }

            progress(i + 1)
        }

        return results
    }
}
