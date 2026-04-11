import Foundation
import Vision
import AppKit

// MARK: - 사용자 스타일 학습 서비스

class StyleLearner: ObservableObject {
    static let shared = StyleLearner()

    @Published var isOnboarded: Bool = UserDefaults.standard.bool(forKey: "styleOnboarded")
    @Published var sessionCount: Int = UserDefaults.standard.integer(forKey: "styleSessionCount")

    // 선호/비선호 벡터 프로필
    private var selectedVectors: [[Float]] = []
    private var rejectedVectors: [[Float]] = []

    private let profileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pickshot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("style_profile.json")
    }()

    init() {
        loadProfile()
    }

    // MARK: - 학습 (현재 폴더에서 사용자 셀렉 분석)

    /// 사용자가 셀렉한 사진 vs 안 한 사진 비교 → 스타일 학습
    func learnFromSelection(selected: [PhotoItem], rejected: [PhotoItem]) {
        guard !selected.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 선택된 사진 특징 벡터
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

    // MARK: - 추천 (학습된 스타일로 점수 매기기)

    /// 사진의 스타일 점수 (0~100) — 학습 데이터가 많을수록 정확
    func styleScore(for photo: PhotoItem) -> Double {
        guard !selectedVectors.isEmpty else { return 50 } // 학습 안 됐으면 중립

        guard let vector = Self.extractFeatureVector(url: photo.jpgURL) else { return 50 }

        // 선호 벡터들과의 평균 코사인 유사도
        let selSimilarity = selectedVectors.map { cosineSimilarity(vector, $0) }.reduce(0, +) / Double(selectedVectors.count)

        // 비선호 벡터들과의 평균 유사도
        let rejSimilarity = rejectedVectors.isEmpty ? 0 :
            rejectedVectors.map { cosineSimilarity(vector, $0) }.reduce(0, +) / Double(rejectedVectors.count)

        // 선호에 가까울수록 높은 점수
        let score = (selSimilarity - rejSimilarity + 1) / 2 * 100
        return max(0, min(100, score))
    }

    /// 배치 스타일 점수
    func batchStyleScores(photos: [PhotoItem], completion: @escaping ([UUID: Double]) -> Void) {
        guard !selectedVectors.isEmpty else {
            completion([:])
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var scores: [UUID: Double] = [:]
            for photo in photos {
                guard let vector = Self.extractFeatureVector(url: photo.jpgURL) else { continue }
                let selSim = self.selectedVectors.map { self.cosineSimilarity(vector, $0) }.reduce(0, +) / Double(self.selectedVectors.count)
                let rejSim = self.rejectedVectors.isEmpty ? 0 :
                    self.rejectedVectors.map { self.cosineSimilarity(vector, $0) }.reduce(0, +) / Double(self.rejectedVectors.count)
                scores[photo.id] = max(0, min(100, (selSim - rejSim + 1) / 2 * 100))
            }
            DispatchQueue.main.async { completion(scores) }
        }
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

    /// 프로필 초기화
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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceThumbnailMaxPixelSize: 400,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let result = request.results?.first as? VNFeaturePrintObservation else { return nil }

        // VNFeaturePrint → Float 배열
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
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? Double(dotProduct / denom) : 0
    }
}
