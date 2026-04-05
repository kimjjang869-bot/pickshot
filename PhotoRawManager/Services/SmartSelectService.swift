import Foundation

/// 스마트 자동 셀렉: 연사/버스트 그룹 감지 → 베스트샷 자동 선택
struct SmartSelectService {

    struct Config {
        var burstTimeThreshold: TimeInterval = 2.0
        var filenameNumberGap: Int = 1
        var minGroupSize: Int = 2
        var criteria: SelectionCriteria = .sharpness

        enum SelectionCriteria: String, CaseIterable {
            case sharpness = "선명도 우선"
            case score = "종합 점수 우선"
            case noIssues = "문제 없는 사진 우선"
        }
    }

    struct BurstGroup {
        let groupIndex: Int
        let photoIndices: [Int]
        let bestIndex: Int
        var count: Int { photoIndices.count }
    }

    struct Result {
        let groups: [BurstGroup]
        let selectedIndices: Set<Int>
        let totalGroups: Int
        let totalPhotosInGroups: Int
        var selectedCount: Int { selectedIndices.count }
    }

    static func detectAndSelect(photos: [PhotoItem], config: Config = Config()) -> Result {
        let groups = detectBurstGroups(photos: photos, config: config)
        var selectedIndices = Set<Int>()
        var burstGroups: [BurstGroup] = []

        for (groupIdx, indices) in groups.enumerated() {
            let bestIdx = selectBest(from: indices, photos: photos, criteria: config.criteria)
            burstGroups.append(BurstGroup(groupIndex: groupIdx, photoIndices: indices, bestIndex: bestIdx))
            selectedIndices.insert(bestIdx)
        }

        return Result(
            groups: burstGroups,
            selectedIndices: selectedIndices,
            totalGroups: groups.count,
            totalPhotosInGroups: groups.reduce(0) { $0 + $1.count }
        )
    }

    private static func detectBurstGroups(photos: [PhotoItem], config: Config) -> [[Int]] {
        guard photos.count > 1 else { return [] }
        let hasDateCount = photos.filter { $0.exifData?.dateTaken != nil }.count
        if Double(hasDateCount) / Double(photos.count) > 0.5 {
            return detectByTimestamp(photos: photos, config: config)
        } else {
            return detectByFilename(photos: photos, config: config)
        }
    }

    private static func detectByTimestamp(photos: [PhotoItem], config: Config) -> [[Int]] {
        var indexed: [(index: Int, date: Date)] = []
        for (i, photo) in photos.enumerated() {
            if let date = photo.exifData?.dateTaken { indexed.append((i, date)) }
        }
        indexed.sort { $0.date < $1.date }
        guard indexed.count > 1 else { return [] }

        var groups: [[Int]] = []
        var currentGroup: [Int] = [indexed[0].index]

        for i in 1..<indexed.count {
            let timeDiff = indexed[i].date.timeIntervalSince(indexed[i-1].date)
            if timeDiff <= config.burstTimeThreshold && timeDiff >= 0 {
                currentGroup.append(indexed[i].index)
            } else {
                if currentGroup.count >= config.minGroupSize { groups.append(currentGroup) }
                currentGroup = [indexed[i].index]
            }
        }
        if currentGroup.count >= config.minGroupSize { groups.append(currentGroup) }
        return groups
    }

    private static func detectByFilename(photos: [PhotoItem], config: Config) -> [[Int]] {
        var indexed: [(index: Int, prefix: String, number: Int)] = []
        for (i, photo) in photos.enumerated() {
            if let (prefix, number) = extractFileNumber(photo.fileName) {
                indexed.append((i, prefix, number))
            }
        }
        let byPrefix = Dictionary(grouping: indexed) { $0.prefix }
        var groups: [[Int]] = []

        for (_, items) in byPrefix {
            let sorted = items.sorted { $0.number < $1.number }
            guard sorted.count > 1 else { continue }
            var currentGroup: [Int] = [sorted[0].index]
            for i in 1..<sorted.count {
                if sorted[i].number - sorted[i-1].number <= config.filenameNumberGap {
                    currentGroup.append(sorted[i].index)
                } else {
                    if currentGroup.count >= config.minGroupSize { groups.append(currentGroup) }
                    currentGroup = [sorted[i].index]
                }
            }
            if currentGroup.count >= config.minGroupSize { groups.append(currentGroup) }
        }
        return groups
    }

    private static func extractFileNumber(_ name: String) -> (String, Int)? {
        let chars = Array(name)
        var endIdx = chars.count - 1
        while endIdx >= 0 && !chars[endIdx].isNumber { endIdx -= 1 }
        guard endIdx >= 0 else { return nil }
        var startIdx = endIdx
        while startIdx > 0 && chars[startIdx - 1].isNumber { startIdx -= 1 }
        let prefix = String(chars[0..<startIdx])
        guard let number = Int(String(chars[startIdx...endIdx])) else { return nil }
        return (prefix, number)
    }

    private static func selectBest(from indices: [Int], photos: [PhotoItem], criteria: Config.SelectionCriteria) -> Int {
        guard !indices.isEmpty else { return 0 }
        var bestIdx = indices[0]
        var bestScore: Double = -1

        for idx in indices {
            let photo = photos[idx]
            let score: Double
            switch criteria {
            case .sharpness:
                // NIMA 점수 우선, 없으면 기존 선명도
                let nima = photo.quality?.nimaScore ?? 0
                if nima > 0 {
                    score = nima * 10  // 1~10 → 10~100
                } else {
                    score = (photo.quality?.sharpnessScore ?? 0) * 0.7 + Double(photo.quality?.score ?? 50) * 0.3
                }
            case .score:
                score = Double(photo.quality?.score ?? 50)
            case .noIssues:
                let bad = photo.quality?.gradingIssues.filter { $0.severity == .bad }.count ?? 0
                let warn = photo.quality?.gradingIssues.filter { $0.severity == .warning }.count ?? 0
                score = (photo.quality?.sharpnessScore ?? 0) - Double(bad) * 100 - Double(warn) * 30
            }
            if score > bestScore { bestScore = score; bestIdx = idx }
        }
        return bestIdx
    }
}
