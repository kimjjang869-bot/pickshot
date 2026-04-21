//
//  TextEncoderService.swift
//  PhotoRawManager
//
//  v8.9: MobileCLIP-BLT text encoder 래퍼.
//  - 입력: 한국어/영어 자연어 문자열
//  - 출력: 512-dim L2-normalized embedding (이미지와 같은 공간)
//  - 전처리: CLIPTokenizer (49408 vocab, context_length=77)
//  - ANE 우선 (MLComputeUnits.all)
//

import Foundation
import CoreML

final class TextEncoderService {
    static let shared = TextEncoderService()

    private var _model: MLModel?
    private let modelLock = NSLock()
    private var hasLoggedShape = false
    private var inputName: String = "text"
    private var outputName: String = "final_emb_1"
    private(set) var embeddingDim: Int = 512

    var isAvailable: Bool {
        (Bundle.main.url(forResource: "MobileCLIPText", withExtension: "mlmodelc") != nil ||
         Bundle.main.url(forResource: "MobileCLIPText", withExtension: "mlpackage") != nil) &&
        Bundle.main.url(forResource: "bpe_simple_vocab_16e6", withExtension: "txt.gz") != nil
    }

    private init() {}

    /// 지연 로딩 — 첫 사용 시 ANE/GPU 컴파일
    func ensureLoaded() throws -> MLModel {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let m = _model { return m }

        let url: URL
        if let compiled = Bundle.main.url(forResource: "MobileCLIPText", withExtension: "mlmodelc") {
            url = compiled
        } else if let pkg = Bundle.main.url(forResource: "MobileCLIPText", withExtension: "mlpackage") {
            url = pkg
        } else {
            throw NSError(domain: "TextEncoder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "MobileCLIPText model not found"])
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: config)
        inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "text"
        outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "final_emb_1"
        _model = model
        fputs("[CLIP-TXT] loaded input=\(inputName) output=\(outputName)\n", stderr)
        return model
    }

    /// 자연어 문자열 → 512-dim L2-normalized embedding.
    /// - 검색 쿼리처럼 짧은 문장 기준. 긴 문장은 context_length(77)에서 잘림.
    func embed(text: String) -> [Float]? {
        let tokens = CLIPTokenizer.shared.tokenize(text)
        return embed(tokens: tokens)
    }

    /// 사전에 토큰화 된 ID 배열 → embedding.
    ///   배열 길이는 context_length(77)에 맞춰야 함 (CLIPTokenizer.tokenize 는 자동 패딩).
    func embed(tokens: [Int32]) -> [Float]? {
        guard let model = try? ensureLoaded() else { return nil }

        // v8.9 진단: 모델 input/output 상세 로그 (첫 호출만)
        if !hasLoggedShape {
            hasLoggedShape = true
            let inputDesc = model.modelDescription.inputDescriptionsByName
            for (k, v) in inputDesc {
                fputs("[CLIP-TXT-DBG] input='\(k)' type=\(v.type.rawValue) mult=\(v.multiArrayConstraint?.shape ?? []) dtype=\(v.multiArrayConstraint?.dataType.rawValue ?? 0)\n", stderr)
            }
            let outDesc = model.modelDescription.outputDescriptionsByName
            for (k, v) in outDesc {
                fputs("[CLIP-TXT-DBG] output='\(k)' type=\(v.type.rawValue)\n", stderr)
            }
            fputs("[CLIP-TXT-DBG] tokens[0..10]=\(tokens.prefix(10))\n", stderr)
        }

        // MLMultiArray 로 변환 — 입력 shape 확인 후 적절히 세팅
        let inputDesc = model.modelDescription.inputDescriptionsByName[inputName]
        let targetShape: [NSNumber] = inputDesc?.multiArrayConstraint?.shape ?? [1, NSNumber(value: tokens.count)]
        let targetDType: MLMultiArrayDataType = inputDesc?.multiArrayConstraint?.dataType ?? .int32
        guard let arr = try? MLMultiArray(shape: targetShape, dataType: targetDType) else { return nil }
        for i in 0..<min(tokens.count, arr.count) {
            arr[i] = NSNumber(value: tokens[i])
        }
        guard let feat = try? MLDictionaryFeatureProvider(
            dictionary: [inputName: MLFeatureValue(multiArray: arr)]
        ) else { return nil }
        guard let out = try? model.prediction(from: feat),
              let raw = out.featureValue(for: outputName)?.multiArrayValue else { return nil }

        let count = raw.count
        var vec = [Float](repeating: 0, count: count)
        for i in 0..<count { vec[i] = raw[i].floatValue }
        // L2 normalize
        var norm: Float = 0
        for v in vec { norm += v * v }
        norm = sqrt(max(norm, 1e-8))
        for i in 0..<count { vec[i] /= norm }
        embeddingDim = count
        return vec
    }

    /// 여러 쿼리 일괄 처리 — 내부적으로 직렬 호출.
    func embedBatch(texts: [String]) -> [String: [Float]] {
        var result: [String: [Float]] = [:]
        for t in texts {
            if let emb = embed(text: t) {
                result[t] = emb
            }
        }
        return result
    }
}
