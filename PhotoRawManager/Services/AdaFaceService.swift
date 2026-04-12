import Foundation
import CoreML
import AppKit
import Vision
import Accelerate

/// AdaFace R18 기반 얼굴 임베딩 서비스 (MIT License)
/// 512차원 임베딩 벡터로 얼굴 유사도 비교
struct AdaFaceService {

    // MARK: - Model Loading

    private static var _model: MLModel?
    private static let modelLock = NSLock()

    /// CoreML 모델 로드 (lazy, thread-safe)
    static func loadModel() -> MLModel? {
        modelLock.lock()
        defer { modelLock.unlock() }

        if let m = _model { return m }

        // 컴파일된 모델 우선
        if let url = Bundle.main.url(forResource: "AdaFaceR18", withExtension: "mlmodelc") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all  // ANE + GPU + CPU
                _model = try MLModel(contentsOf: url, configuration: config)
                fputs("[ADAFACE] 모델 로딩 성공 (mlmodelc)\n", stderr)
                return _model
            } catch {
                fputs("[ADAFACE] mlmodelc 로딩 실패: \(error)\n", stderr)
            }
        }

        // mlpackage fallback (Xcode 자동 컴파일)
        if let url = Bundle.main.url(forResource: "AdaFaceR18", withExtension: "mlpackage") {
            do {
                let compiled = try MLModel.compileModel(at: url)
                let config = MLModelConfiguration()
                config.computeUnits = .all
                _model = try MLModel(contentsOf: compiled, configuration: config)
                fputs("[ADAFACE] 모델 로딩 성공 (mlpackage 컴파일)\n", stderr)
                return _model
            } catch {
                fputs("[ADAFACE] mlpackage 컴파일 실패: \(error)\n", stderr)
            }
        }

        fputs("[ADAFACE] 모델 파일 없음\n", stderr)
        return nil
    }

    /// 모델 사용 가능 여부
    static var isAvailable: Bool {
        Bundle.main.url(forResource: "AdaFaceR18", withExtension: "mlmodelc") != nil ||
        Bundle.main.url(forResource: "AdaFaceR18", withExtension: "mlpackage") != nil
    }

    // MARK: - Face Embedding

    /// 얼굴 CGImage → 512차원 임베딩 벡터
    /// - Parameter faceCrop: 얼굴 영역이 크롭된 CGImage (자동 112x112 리사이즈)
    /// - Returns: 512차원 Float 배열 (L2 정규화됨)
    static func embedding(from faceCrop: CGImage) -> [Float]? {
        guard let model = loadModel() else {
            fputs("[ADAFACE] 모델 로드 실패\n", stderr)
            return nil
        }

        // 112x112로 리사이즈
        guard let resized = resizeTo112(faceCrop) else {
            fputs("[ADAFACE] 리사이즈 실패 (원본: \(faceCrop.width)x\(faceCrop.height))\n", stderr)
            return nil
        }

        // CoreML 입력 생성
        let pixelBuffer = createPixelBuffer(from: resized)
        guard let pb = pixelBuffer else {
            fputs("[ADAFACE] PixelBuffer 생성 실패\n", stderr)
            return nil
        }

        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "faceImage": MLFeatureValue(pixelBuffer: pb)
            ])
            let output = try model.prediction(from: input)

            // 첫 번째 출력이 임베딩 (512차원)
            guard let embeddingArray = output.featureValue(for: "var_498")?.multiArrayValue else {
                // 출력 이름이 다를 수 있으므로 첫 번째 출력 시도
                let names = output.featureNames
                for name in names {
                    if let arr = output.featureValue(for: name)?.multiArrayValue,
                       arr.count >= 512 {
                        return extractAndNormalize(arr)
                    }
                }
                fputs("[ADAFACE] 임베딩 출력을 찾을 수 없음. 출력 이름: \(Array(output.featureNames))\n", stderr)
                return nil
            }

            return extractAndNormalize(embeddingArray)
        } catch {
            fputs("[ADAFACE] 추론 실패: \(error)\n", stderr)
            return nil
        }
    }

    /// MLMultiArray → [Float] + L2 정규화
    /// 모델 출력이 FLOAT16일 수 있으므로 안전한 subscript 접근 사용
    private static func extractAndNormalize(_ arr: MLMultiArray) -> [Float] {
        let count = min(arr.count, 512)
        var vec = [Float](repeating: 0, count: count)

        // MLMultiArray subscript로 안전하게 읽기 (FLOAT16/FLOAT32 모두 대응)
        if arr.shape.count == 2 {
            // shape: [1, 512]
            for i in 0..<count {
                vec[i] = arr[[0, i] as [NSNumber]].floatValue
            }
        } else if arr.shape.count == 1 {
            // shape: [512]
            for i in 0..<count {
                vec[i] = arr[[i] as [NSNumber]].floatValue
            }
        } else {
            // fallback: 순차 접근
            for i in 0..<count {
                vec[i] = arr[i].floatValue
            }
        }

        // L2 정규화
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, vDSP_Length(count))
        norm = sqrt(norm)
        if norm > 0 {
            var invNorm = 1.0 / norm
            vDSP_vsmul(vec, 1, &invNorm, &vec, 1, vDSP_Length(count))
        }

        // 디버그: 첫 번째 호출 시 임베딩 통계 출력
        if _debugEmbeddingCount == 0 {
            let minVal = vec.min() ?? 0
            let maxVal = vec.max() ?? 0
            fputs("[ADAFACE] 첫 임베딩 통계 - shape: \(arr.shape), dtype: \(arr.dataType.rawValue), min: \(minVal), max: \(maxVal), norm: \(norm)\n", stderr)
        }
        _debugEmbeddingCount += 1

        return vec
    }

    private static var _debugEmbeddingCount = 0

    // MARK: - Similarity

    /// 코사인 유사도 (0~1, 높을수록 같은 사람)
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot  // 이미 L2 정규화됨 → dot product = cosine similarity
    }

    /// 같은 사람 판정 threshold (0.4 이상이면 같은 사람)
    static let samePersonThreshold: Float = 0.4

    // MARK: - Image Processing

    /// CGImage → 112x112 리사이즈
    private static func resizeTo112(_ image: CGImage) -> CGImage? {
        let size = 112
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    /// CGImage → CVPixelBuffer (BGRA)
    private static func createPixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }

    // MARK: - Batch Processing

    /// 여러 얼굴의 임베딩을 배치로 추출
    static func batchEmbeddings(faceCrops: [(id: UUID, cgImage: CGImage)]) -> [(id: UUID, embedding: [Float])] {
        var results: [(id: UUID, embedding: [Float])] = []
        let lock = NSLock()

        // CoreML 모델은 thread-safe하지 않으므로 직렬 처리
        // 하지만 이미지 전처리는 병렬 가능
        for (id, crop) in faceCrops {
            autoreleasepool {
                if let emb = embedding(from: crop) {
                    lock.lock()
                    results.append((id: id, embedding: emb))
                    lock.unlock()
                }
            }
        }

        return results
    }
}
