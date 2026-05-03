//
//  ImageEmbeddingService.swift
//  PhotoRawManager
//
//  v8.9: MobileCLIP-BLT image encoder 래퍼.
//  - 512-dim normalized embedding
//  - ANE 우선 실행 (MLComputeUnits.all)
//  - 배치 추론 지원 (8장 기본)
//

import Foundation
import CoreML
import CoreImage
import AppKit

final class ImageEmbeddingService {
    static let shared = ImageEmbeddingService()

    private var _model: MLModel?
    private let modelLock = NSLock()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 입력 이미지 해상도 (BLT = 224, S2 = 256 등 모델마다 다름 — constraint 에서 읽음)
    private(set) var inputSize: Int = 224
    private(set) var embeddingDim: Int = 512
    private var inputName: String = "image"
    private var outputName: String = "final_emb_1"

    /// 모델 로딩 여부
    var isAvailable: Bool {
        Bundle.main.url(forResource: "MobileCLIPImage", withExtension: "mlmodelc") != nil ||
        Bundle.main.url(forResource: "MobileCLIPImage", withExtension: "mlpackage") != nil
    }

    private init() {}

    /// 지연 로딩 — 첫 사용 시점에만 ANE/GPU 컴파일
    func ensureLoaded() throws -> MLModel {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let m = _model { return m }

        let url: URL
        if let compiled = Bundle.main.url(forResource: "MobileCLIPImage", withExtension: "mlmodelc") {
            url = compiled
        } else if let pkg = Bundle.main.url(forResource: "MobileCLIPImage", withExtension: "mlpackage") {
            // Debug 빌드: mlpackage 직접 로드 가능
            url = pkg
        } else {
            throw NSError(domain: "ImageEmbeddingService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "MobileCLIPImage model not found in bundle"])
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: config)

        // 입출력 이름 + 이미지 크기 추출
        let inputDesc = model.modelDescription.inputDescriptionsByName
        inputName = inputDesc.keys.first ?? "image"
        outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "final_emb_1"
        if let constraint = inputDesc[inputName]?.imageConstraint {
            inputSize = Int(constraint.pixelsWide)
        }
        _model = model
        plog("[CLIP-IMG] loaded input=\(inputSize)x\(inputSize) output=\(embeddingDim)-dim\n")
        return model
    }

    /// 이미지 파일 → 512-dim L2-normalized embedding.
    /// - RAW/NEF/JPG 모두 지원 (CGImageSource 경유).
    /// - 실패 시 nil.
    func embed(url: URL) -> [Float]? {
        guard let pb = preprocessPixelBuffer(url: url) else { return nil }
        return embed(pixelBuffer: pb)
    }

    /// CVPixelBuffer → embedding (전처리 이미 된 상태).
    func embed(pixelBuffer: CVPixelBuffer) -> [Float]? {
        guard let model = try? ensureLoaded() else { return nil }
        guard let feat = try? MLDictionaryFeatureProvider(
            dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)]
        ) else { return nil }
        guard let out = try? model.prediction(from: feat),
              let arr = out.featureValue(for: outputName)?.multiArrayValue else { return nil }
        return extractAndNormalize(arr)
    }

    /// 배치 추론 — 더 빠른 처리량 (내부적으로 직렬 호출, CoreML 이 알아서 스케줄링).
    func embedBatch(urls: [URL]) -> [URL: [Float]] {
        var result: [URL: [Float]] = [:]
        for url in urls {
            if let emb = embed(url: url) {
                result[url] = emb
            }
        }
        return result
    }

    // MARK: - Internal

    private func extractAndNormalize(_ arr: MLMultiArray) -> [Float] {
        let count = arr.count
        var vec = [Float](repeating: 0, count: count)
        for i in 0..<count {
            vec[i] = arr[i].floatValue
        }
        // L2 normalize (CLIP 관례 — 코사인 유사도 계산 단순화)
        var norm: Float = 0
        for v in vec { norm += v * v }
        norm = sqrt(max(norm, 1e-8))
        for i in 0..<count { vec[i] /= norm }
        embeddingDim = count
        return vec
    }

    /// 이미지 파일 → 224/256 정사각 RGB CVPixelBuffer.
    /// 중앙 크롭 + 스케일. CLIP 은 센터 크롭 전처리가 표준.
    func preprocessPixelBuffer(url: URL, sizeOverride: Int? = nil) -> CVPixelBuffer? {
        // inputSize 는 모델 로드 전 224 기본. 첫 호출 전에 최소 한 번 ensureLoaded 호출 권장.
        let targetSize = sizeOverride ?? inputSize
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(512, targetSize * 2),
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return preprocessPixelBuffer(cgImage: cg, size: targetSize)
    }

    func preprocessPixelBuffer(cgImage: CGImage, size: Int) -> CVPixelBuffer? {
        let ci = CIImage(cgImage: cgImage)
        let w = ci.extent.width, h = ci.extent.height
        let side = min(w, h)
        let x = (w - side) / 2, y = (h - side) / 2
        let cropped = ci.cropped(to: CGRect(x: x, y: y, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
        let scale = CGFloat(size) / side
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pixelBuffer = pb else { return nil }
        ciContext.render(scaled, to: pixelBuffer)
        return pixelBuffer
    }

    /// 두 임베딩 벡터의 코사인 유사도 (-1 ~ 1). 둘 다 L2-normalized 가정.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }
}
