//
//  BurstDetectionService.swift
//  PhotoRawManager
//
//  v8.9: 연사 그룹 감지.
//  - 기준: 촬영 시각 간격 (기본 5초) + 이미 인덱싱된 CLIP 임베딩 유사도.
//  - 반환: [[PhotoItem]] — 각 배열이 한 연사 그룹.
//

import Foundation

struct BurstDetectionConfig {
    var timeWindowSeconds: Double = 5.0
    var minSimilarity: Float = 0.88   // CLIP cosine — 같은 장면 ~0.90+
    var minGroupSize: Int = 2         // 2장 이상만 그룹으로 간주
}

final class BurstDetectionService {
    static let shared = BurstDetectionService()
    private init() {}

    /// photos 배열을 연사 그룹으로 묶어서 반환. 혼자인 사진은 반환되지 않음 (minGroupSize=2).
    /// - Parameters:
    ///   - photos: 대상 사진 (폴더 전체 또는 선택된 부분)
    ///   - config: 감지 설정
    /// - Returns: 각 그룹은 촬영 시각 순으로 정렬됨.
    func detect(photos: [PhotoItem], config: BurstDetectionConfig = BurstDetectionConfig()) -> [[PhotoItem]] {
        // 폴더/parent 는 제외하고 촬영 시각으로 정렬
        let items = photos
            .filter { !$0.isFolder && !$0.isParentFolder }
            .sorted { lhs, rhs in
                let l = lhs.exifData?.dateTaken ?? lhs.fileModDate
                let r = rhs.exifData?.dateTaken ?? rhs.fileModDate
                return l < r
            }
        guard items.count >= 2 else { return [] }

        var groups: [[PhotoItem]] = []
        var current: [PhotoItem] = [items[0]]
        var currentTime = items[0].exifData?.dateTaken ?? items[0].fileModDate
        var currentEmbedding: [Float]? = embedding(for: items[0].jpgURL)

        for i in 1..<items.count {
            let photo = items[i]
            let t = photo.exifData?.dateTaken ?? photo.fileModDate
            let dt = t.timeIntervalSince(currentTime)

            var isSameBurst = false
            if dt <= config.timeWindowSeconds {
                // 시간 조건 충족 — CLIP 유사도로 추가 검증 (있을 때만)
                if let a = currentEmbedding, let b = embedding(for: photo.jpgURL) {
                    let sim = cosineSimilarity(a, b)
                    isSameBurst = sim >= config.minSimilarity
                    if !isSameBurst {
                        // 시간 가깝지만 장면이 바뀐 경우 (예: 신부 → 신랑 연사)
                        fputs("[BURST] 시간 \(String(format: "%.1f", dt))s 안에 있지만 장면 유사도 \(String(format: "%.2f", sim)) < \(config.minSimilarity) — 별도 그룹\n", stderr)
                    }
                } else {
                    // 임베딩 없을 경우 — 시간만으로 판단 (CLIP 인덱스 미완료 대응)
                    isSameBurst = true
                }
            }

            if isSameBurst {
                current.append(photo)
                currentTime = t
                // embedding 은 그룹 내 첫 장 기준 유지 — 중간에 조금씩 변해도 같은 시퀀스로 인정
            } else {
                if current.count >= config.minGroupSize {
                    groups.append(current)
                }
                current = [photo]
                currentTime = t
                currentEmbedding = embedding(for: photo.jpgURL)
            }
        }
        if current.count >= config.minGroupSize {
            groups.append(current)
        }

        fputs("[BURST] 감지 완료: \(groups.count) 그룹, 총 \(groups.reduce(0) { $0 + $1.count })장 / 원본 \(items.count)장\n", stderr)
        return groups
    }

    // MARK: - Helpers

    private func embedding(for url: URL) -> [Float]? {
        EmbeddingIndex.shared.get(url: url)
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }
}
