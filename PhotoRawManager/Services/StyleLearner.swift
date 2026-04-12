import Foundation
import Vision
import AppKit
import Accelerate

// MARK: - 사용자 스타일 학습 서비스

class StyleLearner: ObservableObject {
    static let shared = StyleLearner()

    @Published var isOnboarded: Bool = UserDefaults.standard.bool(forKey: "styleOnboarded")
    @Published var sessionCount: Int = UserDefaults.standard.integer(forKey: "styleSessionCount")

    // 선호/비선호 벡터 프로필
    private var selectedVectors: [[Float]] = []
    private var rejectedVectors: [[Float]] = []
    // 벡터 캐시 (동일 사진 재추출 방지)
    private var vectorCache: [URL: [Float]] = [:]

    private let profileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pickshot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("style_profile.json")
    }()

    init() {
        loadProfile()
    }

    // MARK: - 학습

    func learnFromSelection(selected: [PhotoItem], rejected: [PhotoItem]) {
        guard !selected.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let selVectors = selected.compactMap { Self.extractFeatureVector(url: $0.jpgURL) }
            let rejVectors = rejected.prefix(selected.count * 2).compactMap { Self.extractFeatureVector(url: $0.jpgURL) }

            DispatchQueue.main.async {
                self?.selectedVectors.append(contentsOf: selVectors)
                self?.rejectedVectors.append(contentsOf: rejVectors)
                self?.sessionCount += 1
                UserDefaults.standard.set(self?.sessionCount ?? 0, forKey: "styleSessionCount")
                self?.saveProfile()
                fputs("[STYLE] 학습 완료: 선택 \(selVectors.count)장, 탈락 \(rejVectors.count)장, 세션 \(self?.sessionCount ?? 0)\n", stderr)
            }
        }
    }

    // MARK: - 추천 (배치)

    func batchStyleScores(photos: [PhotoItem], completion: @escaping ([UUID: Double]) -> Void) {
        guard !selectedVectors.isEmpty else {
            completion([:])
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            // 1. 모든 사진의 벡터 추출 (캐시 활용)
            var photoVectors: [(UUID, [Float])] = []
            for photo in photos {
                if let cached = self.vectorCache[photo.jpgURL] {
                    photoVectors.append((photo.id, cached))
                } else if let vector = Self.extractFeatureVector(url: photo.jpgURL) {
                    self.vectorCache[photo.jpgURL] = vector
                    photoVectors.append((photo.id, vector))
                }
            }

            guard !photoVectors.isEmpty else {
                DispatchQueue.main.async { completion([:]) }
                return
            }

            // 2. 각 사진의 raw 점수 계산
            var rawScores: [UUID: Double] = [:]
            for (id, vector) in photoVectors {
                let score = self.rawStyleScore(vector: vector)
                rawScores[id] = score
            }

            // 3. 상대 점수 정규화 (min-max → 0~100)
            let allScores = rawScores.values
            let minScore = allScores.min() ?? 0
            let maxScore = allScores.max() ?? 1
            let range = maxScore - minScore

            var normalizedScores: [UUID: Double] = [:]
            if range > 0.001 {
                for (id, score) in rawScores {
                    // min-max 정규화 → 20~95 범위로 매핑
                    let normalized = ((score - minScore) / range) * 75 + 20
                    normalizedScores[id] = normalized
                }
            } else {
                // 모든 점수가 동일 → 전부 50
                for (id, _) in rawScores {
                    normalizedScores[id] = 50
                }
            }

            fputs("[STYLE] 점수 범위: raw \(String(format: "%.4f", minScore))~\(String(format: "%.4f", maxScore)), 정규화 20~95\n", stderr)

            DispatchQueue.main.async { completion(normalizedScores) }
        }
    }

    /// 단일 사진 raw 점수 (정규화 전)
    private func rawStyleScore(vector: [Float]) -> Double {
        // Top-K 유사도 (가장 가까운 벡터 3개 평균) — 평균보다 민감
        let k = min(3, selectedVectors.count)
        let selSims = selectedVectors.map { cosineSimilarity(vector, $0) }.sorted(by: >)
        let topSelSim = selSims.prefix(k).reduce(0, +) / Double(k)

        if rejectedVectors.isEmpty {
            return topSelSim
        }

        let rejK = min(3, rejectedVectors.count)
        let rejSims = rejectedVectors.map { cosineSimilarity(vector, $0) }.sorted(by: >)
        let topRejSim = rejSims.prefix(rejK).reduce(0, +) / Double(rejK)

        // 선호 유사도 - 비선호 유사도 (차이를 증폭)
        return topSelSim - topRejSim * 0.8
    }

    // MARK: - 프로필 저장/로드

    private func saveProfile() {
        let data: [String: Any] = [
            "selectedVectors": selectedVectors.map { $0.map { Double($0) } },
            "rejectedVectors": rejectedVectors.map { $0.map { Double($0) } },
            "sessionCount": sessionCount
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
            try? json.write(to: profileURL)
        }
    }

    private func loadProfile() {
        guard let data = try? Data(contentsOf: profileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let sel = dict["selectedVectors"] as? [[Double]] {
            selectedVectors = sel.map { $0.map { Float($0) } }
        }
        if let rej = dict["rejectedVectors"] as? [[Double]] {
            rejectedVectors = rej.map { $0.map { Float($0) } }
        }
        sessionCount = dict["sessionCount"] as? Int ?? 0
    }

    func resetProfile() {
        selectedVectors = []
        rejectedVectors = []
        sessionCount = 0
        UserDefaults.standard.set(0, forKey: "styleSessionCount")
        UserDefaults.standard.set(false, forKey: "styleOnboarded")
        isOnboarded = false
        try? FileManager.default.removeItem(at: profileURL)
    }

    // MARK: - VNFeaturePrint 추출

    private static func extractFeatureVector(url: URL) -> [Float]? {
        let cgImage: CGImage?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
           ] as CFDictionary) {
            cgImage = thumb
        } else if let nsImage = NSImage(contentsOf: url),
                  let img = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cgImage = img
        } else {
            return nil
        }

        guard let image = cgImage else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        guard let result = request.results?.first as? VNFeaturePrintObservation else { return nil }

        let data = result.data
        let count = data.count / MemoryLayout<Float>.stride
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBufferPointer { buffer in
            data.copyBytes(to: buffer)
        }
        return floats
    }

    // MARK: - 코사인 유사도

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(a.count))
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? Double(dotProduct / denom) : 0
    }
}
