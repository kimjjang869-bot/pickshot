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

    // MARK: - Batch Scoring

    /// 배치 NIMA 점수 계산
    static func scoreBatch(
        photos: [PhotoItem],
        cancelCheck: @escaping () -> Bool,
        progress: @escaping (Int) -> Void
    ) -> [UUID: Double] {
        guard isAvailable else { return [:] }

        var results: [UUID: Double] = [:]
        let lock = NSLock()

        // 동시 처리 (CPU 코어 수 기반, 최대 4)
        let concurrency = min(4, ProcessInfo.processInfo.activeProcessorCount)
        DispatchQueue.concurrentPerform(iterations: photos.count) { i in
            if cancelCheck() { return }

            let photo = photos[i]
            guard !photo.isFolder && !photo.isParentFolder else { return }

            autoreleasepool {
                if let nimaScore = score(url: photo.jpgURL) {
                    lock.lock()
                    results[photo.id] = nimaScore
                    lock.unlock()
                }
            }

            progress(i + 1)
        }

        return results
    }
}
