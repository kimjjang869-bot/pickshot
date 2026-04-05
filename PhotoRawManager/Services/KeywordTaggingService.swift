import Foundation
import Vision

/// Generates IPTC-compatible keywords from Vision scene classification results and face detection data.
/// Works with the existing `classifySceneTag` output in PhotoStore.
struct KeywordTaggingService {

    /// Result of keyword generation for a single photo
    struct KeywordResult {
        var keywords: [String]
    }

    // MARK: - Scene tag to keyword expansion

    /// Maps a Korean scene tag (from PhotoStore.sceneMapping) to multiple IPTC keywords
    private static let tagKeywords: [String: [String]] = [
        // 인물
        "인물":             ["인물", "portrait"],
        "인물 (클로즈업)":   ["인물", "클로즈업", "portrait", "closeup"],
        // 단체
        "단체/군중":         ["단체", "군중", "group"],
        // 이벤트
        "웨딩":             ["웨딩", "wedding", "이벤트"],
        "공연/콘서트":       ["공연", "콘서트", "concert", "이벤트"],
        "파티/축제":         ["파티", "축제", "party", "이벤트"],
        "발표/회의":         ["발표", "회의", "conference"],
        "전시/팝업":         ["전시", "팝업", "exhibition"],
        // 자연/풍경
        "풍경":             ["풍경", "landscape", "자연"],
        "하늘/일몰":         ["하늘", "일몰", "sky", "자연"],
        "바다/해변":         ["바다", "해변", "sea", "자연"],
        // 도시/건축
        "도시/야경":         ["도시", "야경", "city", "urban"],
        "건물/건축":         ["건물", "건축", "architecture"],
        // 실내
        "실내":             ["실내", "indoor"],
        // 음식/음료
        "음식/음료":         ["음식", "음료", "food"],
        // 동물/식물
        "동물/식물":         ["동물", "식물", "nature"],
        // 사물
        "차량/교통":         ["차량", "교통", "vehicle"],
        "제품/상품":         ["제품", "상품", "product"],
        "디테일/클로즈업":    ["디테일", "클로즈업", "detail", "macro"],
        "문서/텍스트":       ["문서", "텍스트", "document"],
        // 스포츠
        "스포츠":           ["스포츠", "sports"],
    ]

    // MARK: - Indoor / Outdoor keywords from Vision identifiers

    private static let outdoorIdentifiers: Set<String> = [
        "landscape", "mountain", "valley", "field", "countryside", "prairie", "hill",
        "sunset", "sunrise", "sky", "cloud", "dawn", "dusk",
        "ocean", "sea", "beach", "coast", "wave", "shore", "lake", "river", "waterfall",
        "cityscape", "urban", "downtown", "street",
        "garden", "forest", "park",
    ]

    private static let indoorIdentifiers: Set<String> = [
        "indoor", "room", "interior", "office", "studio", "gym", "classroom",
        "restaurant", "bakery", "kitchen", "museum", "gallery",
    ]

    /// Generate keywords from Vision classification results + face analysis
    /// - Parameters:
    ///   - sceneTag: The Korean scene tag already assigned by classifySceneTag
    ///   - topIdentifiers: Top Vision classification identifiers (raw English labels)
    ///   - faceCount: Number of detected faces (confidence > 0.5)
    ///   - maxFaceSize: Largest face bounding box area (normalized, 0~1)
    ///   - hasSmile: Whether any face has a smile detected (reserved for future use)
    static func generateKeywords(
        sceneTag: String?,
        topIdentifiers: [String],
        faceCount: Int,
        maxFaceSize: Double
    ) -> [String] {
        var keywords = Set<String>()

        // 1. Expand scene tag into keywords
        if let tag = sceneTag, let mapped = tagKeywords[tag] {
            for kw in mapped { keywords.insert(kw) }
        }

        // 2. Face count keywords
        if faceCount == 1 {
            keywords.insert("1명")
        } else if faceCount == 2 {
            keywords.insert("2명")
        } else if faceCount >= 3 && faceCount < 5 {
            keywords.insert("\(faceCount)명")
            keywords.insert("소그룹")
        } else if faceCount >= 5 {
            keywords.insert("\(faceCount)명")
            keywords.insert("대그룹")
        }

        // 3. Face size: portrait vs group shot
        if faceCount >= 1 {
            if maxFaceSize > 0.15 {
                keywords.insert("클로즈업")
            } else if maxFaceSize > 0.05 {
                keywords.insert("반신")
            } else if faceCount >= 1 {
                keywords.insert("전신")
            }
        }

        // 4. Indoor/Outdoor from raw identifiers
        let allWords = topIdentifiers.flatMap {
            $0.lowercased().split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" }).map(String.init)
        }
        let wordsSet = Set(allWords)

        if !wordsSet.isDisjoint(with: outdoorIdentifiers) {
            keywords.insert("실외")
            keywords.insert("outdoor")
        }
        if !wordsSet.isDisjoint(with: indoorIdentifiers) {
            keywords.insert("실내")
            keywords.insert("indoor")
        }

        // 5. Additional contextual keywords from raw identifiers
        for word in allWords {
            switch word {
            case "night", "neon", "dusk": keywords.insert("야간")
            case "sunset", "sunrise", "dawn": keywords.insert("골든아워")
            case "rain", "snow", "fog": keywords.insert("날씨")
            case "wedding", "bride", "groom": keywords.insert("웨딩")
            default: break
            }
        }

        // Return sorted for consistent display
        return keywords.sorted()
    }
}
