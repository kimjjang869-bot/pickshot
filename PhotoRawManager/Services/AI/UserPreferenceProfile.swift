//
//  UserPreferenceProfile.swift
//  PhotoRawManager
//
//  v8.9: 개인 취향 임베딩 profile.
//  - 셀렉본 평균 임베딩 ("positive centroid") 과 탈락본 평균 ("negative centroid") 의 차를 저장.
//  - 새 사진의 CLIP 임베딩과 내적 → "내 취향 유사도" (−1 ~ +1).
//  - 셀렉본이 1000장+ 되면 실제 사용자 스타일을 꽤 정확히 재현.
//

import Foundation

struct UserPreferenceProfile: Codable {
    var positiveVector: [Float]   // 셀렉본 평균 (L2 normalized)
    var negativeVector: [Float]   // 탈락본 평균 (L2 normalized, 비어있을 수 있음)
    var positiveCount: Int
    var negativeCount: Int
    var updatedAt: Date

    static let empty = UserPreferenceProfile(
        positiveVector: [], negativeVector: [],
        positiveCount: 0, negativeCount: 0, updatedAt: .distantPast
    )

    var isTrained: Bool { positiveCount >= 30 }
}

final class UserPreferenceService {
    static let shared = UserPreferenceService()

    private(set) var profile: UserPreferenceProfile = .empty
    private let queue = DispatchQueue(label: "com.pickshot.prefs", qos: .utility)

    private var profileURL: URL {
        let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let base = dir?.appendingPathComponent("PickShot", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("user_preference.json")
    }

    private init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: profileURL),
              let p = try? JSONDecoder().decode(UserPreferenceProfile.self, from: data) else {
            return
        }
        profile = p
        fputs("[PREFS] profile 로드: pos=\(p.positiveCount) neg=\(p.negativeCount)\n", stderr)
    }

    func save() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? JSONEncoder().encode(self.profile) {
                try? data.write(to: self.profileURL, options: .atomic)
            }
        }
    }

    /// 셀렉본 URL 배열로 profile 학습/업데이트. 임베딩은 EmbeddingIndex 또는 on-the-fly 계산.
    /// - Parameters:
    ///   - positiveURLs: "좋다" 로 분류된 사진들
    ///   - negativeURLs: "나쁘다" 로 분류된 사진들 (옵션, 없으면 중립 비교)
    ///   - onProgress: (done, total) 콜백
    func train(
        positiveURLs: [URL],
        negativeURLs: [URL] = [],
        onProgress: @escaping (Int, Int) -> Void = { _, _ in },
        onComplete: @escaping (UserPreferenceProfile) -> Void
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let total = positiveURLs.count + negativeURLs.count
            var done = 0

            let pos = self.averageEmbedding(urls: positiveURLs, onProgress: {
                done += 1
                DispatchQueue.main.async { onProgress(done, total) }
            })
            let neg = self.averageEmbedding(urls: negativeURLs, onProgress: {
                done += 1
                DispatchQueue.main.async { onProgress(done, total) }
            })

            var profile = UserPreferenceProfile(
                positiveVector: pos,
                negativeVector: neg,
                positiveCount: positiveURLs.count,
                negativeCount: negativeURLs.count,
                updatedAt: Date()
            )
            if pos.isEmpty { profile = .empty }
            self.profile = profile
            self.save()
            fputs("[PREFS] 학습 완료: pos=\(profile.positiveCount) neg=\(profile.negativeCount) dim=\(profile.positiveVector.count)\n", stderr)
            DispatchQueue.main.async { onComplete(profile) }
        }
    }

    // MARK: - 협업: 프로필 export / import

    /// 현재 profile 을 JSON 파일로 export. 다른 사용자에게 공유 가능.
    func exportProfile(to url: URL) throws {
        let data = try JSONEncoder().encode(profile)
        try data.write(to: url, options: .atomic)
        fputs("[PREFS] export → \(url.lastPathComponent) (\(data.count) bytes)\n", stderr)
    }

    enum MergeStrategy {
        case replace        // 기존 profile 덮어쓰기
        case averageEqual   // 두 profile 50/50 평균
        case weightedByMine(myWeight: Double)  // 내 profile 가중치 (0~1)
    }

    /// 다른 사람 profile 을 import 해서 내 profile 과 병합.
    func importProfile(from url: URL, strategy: MergeStrategy) throws {
        let data = try Data(contentsOf: url)
        let other = try JSONDecoder().decode(UserPreferenceProfile.self, from: data)
        guard !other.positiveVector.isEmpty else {
            throw NSError(domain: "UserPreference", code: -1, userInfo: [NSLocalizedDescriptionKey: "빈 프로필 파일입니다"])
        }

        let merged: UserPreferenceProfile
        switch strategy {
        case .replace:
            merged = other
        case .averageEqual:
            merged = blend(base: profile, other: other, myWeight: 0.5)
        case .weightedByMine(let w):
            merged = blend(base: profile, other: other, myWeight: w)
        }
        self.profile = merged
        self.save()
        fputs("[PREFS] import 완료 from \(url.lastPathComponent), posCount=\(merged.positiveCount)\n", stderr)
    }

    private func blend(base: UserPreferenceProfile, other: UserPreferenceProfile, myWeight: Double) -> UserPreferenceProfile {
        if base.positiveVector.isEmpty { return other }
        if other.positiveVector.isEmpty { return base }
        guard base.positiveVector.count == other.positiveVector.count else { return base }
        let w1 = Float(myWeight), w2 = Float(1.0 - myWeight)
        var pos = [Float](repeating: 0, count: base.positiveVector.count)
        for i in 0..<pos.count {
            pos[i] = base.positiveVector[i] * w1 + other.positiveVector[i] * w2
        }
        // 재정규화
        var n: Float = 0
        for v in pos { n += v * v }
        n = sqrt(max(n, 1e-8))
        for i in 0..<pos.count { pos[i] /= n }

        var neg: [Float] = []
        if base.negativeVector.count == other.negativeVector.count && !base.negativeVector.isEmpty {
            neg = [Float](repeating: 0, count: base.negativeVector.count)
            for i in 0..<neg.count {
                neg[i] = base.negativeVector[i] * w1 + other.negativeVector[i] * w2
            }
            n = 0
            for v in neg { n += v * v }
            n = sqrt(max(n, 1e-8))
            for i in 0..<neg.count { neg[i] /= n }
        }

        return UserPreferenceProfile(
            positiveVector: pos,
            negativeVector: neg,
            positiveCount: base.positiveCount + other.positiveCount,
            negativeCount: base.negativeCount + other.negativeCount,
            updatedAt: Date()
        )
    }

    /// 주어진 사진의 "내 취향 점수" — 0(비호감) ~ 1(호감).
    /// positive 와의 유사도 - negative 와의 유사도 + 0.5 오프셋 → [0, 1] 클램프.
    func preferenceScore(for url: URL) -> Double {
        guard profile.isTrained,
              let emb = EmbeddingIndex.shared.get(url: url) ??
                        ImageEmbeddingService.shared.embed(url: url) else {
            return 0.5  // 중립
        }
        let posSim = cosineSimilarity(emb, profile.positiveVector)
        let negSim = profile.negativeVector.isEmpty ? 0 : cosineSimilarity(emb, profile.negativeVector)
        let diff = Double(posSim - negSim)
        return max(0, min(1, diff * 2.0 + 0.5))
    }

    // MARK: - Helpers

    private func averageEmbedding(urls: [URL], onProgress: () -> Void) -> [Float] {
        guard !urls.isEmpty else { return [] }
        var sum: [Float] = []
        var count = 0
        for url in urls {
            autoreleasepool {
                let emb = EmbeddingIndex.shared.get(url: url) ?? ImageEmbeddingService.shared.embed(url: url)
                if let v = emb, !v.isEmpty {
                    if sum.isEmpty { sum = [Float](repeating: 0, count: v.count) }
                    if sum.count == v.count {
                        for i in 0..<v.count { sum[i] += v[i] }
                        count += 1
                    }
                }
            }
            onProgress()
        }
        guard count > 0, !sum.isEmpty else { return [] }
        for i in 0..<sum.count { sum[i] /= Float(count) }
        // L2 normalize
        var norm: Float = 0
        for v in sum { norm += v * v }
        norm = sqrt(max(norm, 1e-8))
        for i in 0..<sum.count { sum[i] /= norm }
        return sum
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var s: Float = 0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }
}
