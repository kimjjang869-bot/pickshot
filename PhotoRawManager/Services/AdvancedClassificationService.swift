import Foundation
import Vision
import AppKit
import CoreImage

/// 고급 사진 분류 서비스
/// Vision 프레임워크의 다중 요청을 하나의 파이프라인으로 결합하여
/// 장면, 물체, 텍스트, 동물, 포즈, 색상/분위기, 구도를 한번에 분석
struct AdvancedClassificationService {

    // MARK: - Result Types

    struct ClassificationResult {
        var sceneTag: String?
        var keywords: [String] = []
        var detectedObjects: [String] = []    // 감지된 물체/동물
        var hasText: Bool = false              // 문서/텍스트 포함
        var textAmount: TextAmount = .none     // 텍스트 양
        var colorMood: ColorMood = .neutral    // 색상 분위기
        var dominantColors: [String] = []      // 주요 색상
        var compositionType: CompositionType = .unknown // 구도 유형
        var timeOfDay: TimeOfDay = .unknown    // 촬영 시간대
        var faceCount: Int = 0
        var maxFaceSize: Double = 0
        var hasPerson: Bool = false
        var personCoverage: Double = 0         // 인물 비율 (0~1)
        var bodyPoseDetected: Bool = false     // 바디 포즈 감지 여부
    }

    enum TextAmount: String {
        case none = "없음"
        case some = "일부"       // 1~3 텍스트 영역
        case heavy = "문서"     // 4+ 텍스트 영역 — 문서/스크린샷
    }

    enum ColorMood: String {
        case warm = "따뜻한"       // 오렌지/노랑 톤
        case cool = "차가운"       // 파랑/시안 톤
        case vibrant = "비비드"    // 높은 채도
        case muted = "차분한"      // 낮은 채도
        case dark = "어두운"       // 로우키
        case bright = "밝은"       // 하이키
        case neutral = "중립"
        case bw = "흑백"          // 극도로 낮은 채도
    }

    enum CompositionType: String {
        case centered = "중앙 배치"
        case ruleOfThirds = "삼등분"
        case symmetry = "대칭"
        case diagonal = "대각선"
        case wideShot = "와이드"
        case closeup = "클로즈업"
        case topDown = "탑다운"
        case lowAngle = "로우앵글"
        case unknown = "기타"
    }

    enum TimeOfDay: String {
        case dawn = "새벽"
        case morning = "아침"
        case afternoon = "오후"
        case goldenHour = "골든아워"
        case blueHour = "블루아워"
        case night = "야간"
        case unknown = "미분류"
    }

    // MARK: - Main Classification

    /// 단일 이미지 고급 분류 (모든 Vision 요청 배치 실행)
    static func classify(cgImage: CGImage) -> ClassificationResult {
        var result = ClassificationResult()

        // === 1단계: Vision 요청 배치 실행 ===
        let sceneReq = VNClassifyImageRequest()
        // v8.6.3: usesCPUOnly deprecated — GPU 기본 동작

        let faceReq = VNDetectFaceRectanglesRequest()
        if #available(macOS 13.0, *) {
            faceReq.revision = VNDetectFaceRectanglesRequestRevision3
        }

        let faceLandmarkReq = VNDetectFaceLandmarksRequest()

        let textReq = VNDetectTextRectanglesRequest()
        textReq.reportCharacterBoxes = false

        let saliencyReq = VNGenerateAttentionBasedSaliencyImageRequest()

        // 동물 인식 (macOS 13+)
        var animalReq: VNRecognizeAnimalsRequest?
        if #available(macOS 13.0, *) {
            animalReq = VNRecognizeAnimalsRequest()
        }

        var requests: [VNRequest] = [sceneReq, faceReq, faceLandmarkReq, textReq, saliencyReq]
        if let animal = animalReq { requests.append(animal) }

        // 인물 세그멘테이션 (별도 — 크로스 요청과 호환 안될 수 있음)
        let personReq = VNGeneratePersonSegmentationRequest()
        personReq.qualityLevel = .fast

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform(requests)
            // 인물 세그멘테이션은 별도 실행 (호환성)
            try handler.perform([personReq])
        } catch {
            // 부분 실패 허용 — 개별 결과 체크
        }

        // === 2단계: 결과 파싱 ===

        // 장면 분류
        let sceneResults = (sceneReq.results ?? [])
            .filter { $0.confidence > 0.2 }
            .sorted { $0.confidence > $1.confidence }
        let topIdentifiers = sceneResults.prefix(8).map { $0.identifier }

        // 얼굴
        let faces = (faceReq.results ?? []).filter { $0.confidence > 0.5 }
        result.faceCount = faces.count
        result.maxFaceSize = faces.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0

        // 얼굴 랜드마크 (표정 분석)
        let landmarks = faceLandmarkReq.results ?? []
        let expressionKeywords = analyzeExpressions(landmarks: landmarks)
        result.keywords.append(contentsOf: expressionKeywords)

        // 텍스트 감지
        let textResults = textReq.results ?? []
        if textResults.count >= 4 {
            result.hasText = true
            result.textAmount = .heavy
        } else if !textResults.isEmpty {
            result.hasText = true
            result.textAmount = .some
        }

        // 동물 감지
        if let animalResults = animalReq?.results {
            for animal in animalResults {
                for label in animal.labels where label.confidence > 0.5 {
                    let animalName = mapAnimalLabel(label.identifier)
                    result.detectedObjects.append(animalName)
                    result.keywords.append(animalName)
                }
            }
        }

        // 인물 세그멘테이션
        if let personResult = personReq.results?.first {
            let mask = personResult.pixelBuffer
            let coverage = calculateMaskCoverage(mask)
            result.hasPerson = coverage > 0.03
            result.personCoverage = coverage
        }

        // === 3단계: 색상/분위기 분석 ===
        let colorAnalysis = analyzeColors(cgImage: cgImage)
        result.colorMood = colorAnalysis.mood
        result.dominantColors = colorAnalysis.dominantNames
        result.timeOfDay = colorAnalysis.timeOfDay

        // === 4단계: 구도 분석 ===
        if let saliencyResult = saliencyReq.results?.first {
            result.compositionType = analyzeComposition(saliency: saliencyResult, imageSize: CGSize(width: cgImage.width, height: cgImage.height))
        }

        // === 5단계: 종합 장면 태그 결정 ===
        result.sceneTag = determineFinalTag(
            sceneResults: sceneResults,
            faces: faces,
            textAmount: result.textAmount,
            animalObjects: result.detectedObjects,
            hasPerson: result.hasPerson,
            personCoverage: result.personCoverage,
            topIdentifiers: topIdentifiers
        )

        // === 6단계: 키워드 생성 ===
        var allKeywords = Set(result.keywords)

        // 기존 KeywordTaggingService 키워드
        let basicKeywords = KeywordTaggingService.generateKeywords(
            sceneTag: result.sceneTag,
            topIdentifiers: topIdentifiers,
            faceCount: result.faceCount,
            maxFaceSize: result.maxFaceSize
        )
        for kw in basicKeywords { allKeywords.insert(kw) }

        // 색상/분위기 키워드
        if result.colorMood != .neutral {
            allKeywords.insert(result.colorMood.rawValue)
        }
        for color in result.dominantColors.prefix(2) {
            allKeywords.insert(color)
        }

        // 시간대 키워드
        if result.timeOfDay != .unknown {
            allKeywords.insert(result.timeOfDay.rawValue)
        }

        // 구도 키워드
        if result.compositionType != .unknown {
            allKeywords.insert(result.compositionType.rawValue)
        }

        // 텍스트 키워드
        if result.textAmount == .heavy {
            allKeywords.insert("문서")
            allKeywords.insert("텍스트")
        }

        result.keywords = allKeywords.sorted()
        return result
    }

    // MARK: - Expression Analysis (얼굴 표정)

    private static func analyzeExpressions(landmarks: [VNFaceObservation]) -> [String] {
        var keywords: [String] = []

        for face in landmarks {
            guard let lm = face.landmarks, face.confidence > 0.5 else { continue }

            // 눈 감김 체크
            if let leftEye = lm.leftEye, let rightEye = lm.rightEye {
                let leftEAR = eyeAspectRatio(leftEye)
                let rightEAR = eyeAspectRatio(rightEye)
                if leftEAR < 0.18 && rightEAR < 0.18 {
                    keywords.append("눈감음")
                }
            }

            // 미소 체크
            if let outerLips = lm.outerLips {
                let points = outerLips.normalizedPoints
                if points.count >= 6 {
                    let leftCorner = points[0]
                    let rightCorner = points[points.count / 2]
                    let bottomCenter = points[points.count * 3 / 4]
                    let avgCornerY = (leftCorner.y + rightCorner.y) / 2
                    let uplift = avgCornerY - bottomCenter.y
                    if uplift > 0.15 {
                        keywords.append("웃음")
                    }
                }
            }

            // 얼굴 방향 (고개 돌림)
            if face.yaw != nil {
                let yawDeg = (face.yaw?.doubleValue ?? 0) * 180 / .pi
                if abs(yawDeg) > 30 {
                    keywords.append("프로필")
                }
            }
        }

        return keywords
    }

    private static func eyeAspectRatio(_ region: VNFaceLandmarkRegion2D) -> Double {
        let pts = region.normalizedPoints
        guard pts.count >= 4 else { return 0.3 }
        let maxY = pts.map { $0.y }.max() ?? 0
        let minY = pts.map { $0.y }.min() ?? 0
        let maxX = pts.map { $0.x }.max() ?? 0
        let minX = pts.map { $0.x }.min() ?? 0
        let width = maxX - minX
        guard width > 0 else { return 0.3 }
        return Double(maxY - minY) / Double(width)
    }

    // MARK: - Color/Mood Analysis

    struct ColorAnalysis {
        var mood: ColorMood
        var dominantNames: [String]
        var timeOfDay: TimeOfDay
    }

    private static func analyzeColors(cgImage: CGImage) -> ColorAnalysis {
        _ = cgImage.width
        _ = cgImage.height

        // 작은 이미지로 리샘플 (빠른 분석)
        let sampleSize = 64
        guard let context = CGContext(
            data: nil, width: sampleSize, height: sampleSize,
            bitsPerComponent: 8, bytesPerRow: sampleSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return ColorAnalysis(mood: .neutral, dominantNames: [], timeOfDay: .unknown)
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        guard let data = context.data else {
            return ColorAnalysis(mood: .neutral, dominantNames: [], timeOfDay: .unknown)
        }
        let ptr = data.bindMemory(to: UInt8.self, capacity: sampleSize * sampleSize * 4)

        var totalR: Double = 0, totalG: Double = 0, totalB: Double = 0
        var totalH: Double = 0, totalS: Double = 0, totalV: Double = 0
        var colorCounts: [String: Int] = [:]
        let pixelCount = sampleSize * sampleSize

        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Double(ptr[offset]) / 255.0
            let g = Double(ptr[offset + 1]) / 255.0
            let b = Double(ptr[offset + 2]) / 255.0

            totalR += r; totalG += g; totalB += b

            // RGB → HSV
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC

            var h: Double = 0, s: Double = 0, v: Double = maxC
            if delta > 0.01 {
                s = delta / maxC
                if maxC == r { h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
                else if maxC == g { h = 60 * ((b - r) / delta + 2) }
                else { h = 60 * ((r - g) / delta + 4) }
                if h < 0 { h += 360 }
            }
            totalH += h; totalS += s; totalV += v

            // 색상 분류
            let colorName = classifyPixelColor(h: h, s: s, v: v)
            colorCounts[colorName, default: 0] += 1
        }

        let n = Double(pixelCount)
        _ = (totalR / n, totalG / n, totalB / n)  // v8.6.3: 미사용 평균 RGB — 향후 톤 분석용 자리 보존
        let avgH = totalH / n, avgS = totalS / n, avgV = totalV / n

        // 분위기 결정
        let mood: ColorMood
        if avgS < 0.08 {
            mood = .bw
        } else if avgV < 0.25 {
            mood = .dark
        } else if avgV > 0.8 && avgS < 0.2 {
            mood = .bright
        } else if avgS > 0.6 {
            mood = .vibrant
        } else if avgS < 0.25 {
            mood = .muted
        } else if avgH > 10 && avgH < 60 {
            mood = .warm
        } else if avgH > 180 && avgH < 270 {
            mood = .cool
        } else {
            mood = .neutral
        }

        // 주요 색상 (상위 3개)
        let dominantColors = colorCounts.sorted { $0.value > $1.value }
            .prefix(3)
            .filter { Double($0.value) / n > 0.1 }
            .map { $0.key }

        // 시간대 추정 (색온도 기반)
        let timeOfDay: TimeOfDay
        if avgV < 0.15 {
            timeOfDay = .night
        } else if avgV < 0.3 && avgH > 200 && avgH < 260 {
            timeOfDay = .blueHour
        } else if avgH > 15 && avgH < 50 && avgV > 0.5 && avgS > 0.3 {
            timeOfDay = .goldenHour
        } else {
            timeOfDay = .unknown
        }

        return ColorAnalysis(mood: mood, dominantNames: dominantColors, timeOfDay: timeOfDay)
    }

    private static func classifyPixelColor(h: Double, s: Double, v: Double) -> String {
        if v < 0.15 { return "검정" }
        if v > 0.85 && s < 0.1 { return "흰색" }
        if s < 0.12 { return "회색" }

        // 색상환 기반 분류
        if h < 15 || h >= 345 { return "빨강" }
        if h < 45 { return "주황" }
        if h < 70 { return "노랑" }
        if h < 165 { return "초록" }
        if h < 195 { return "시안" }
        if h < 260 { return "파랑" }
        if h < 290 { return "보라" }
        if h < 345 { return "핑크" }
        return "기타"
    }

    // MARK: - Composition Analysis

    private static func analyzeComposition(saliency: VNSaliencyImageObservation, imageSize: CGSize) -> CompositionType {
        guard let salientObjects = saliency.salientObjects, !salientObjects.isEmpty else {
            return .unknown
        }

        // 주요 관심 영역의 중심점
        let primary = salientObjects[0].boundingBox
        let centerX = primary.midX
        let centerY = primary.midY
        let areaRatio = primary.width * primary.height

        // 클로즈업: 주 피사체가 화면의 50% 이상
        if areaRatio > 0.5 {
            return .closeup
        }

        // 와이드: 주 피사체가 화면의 5% 이하
        if areaRatio < 0.05 {
            return .wideShot
        }

        // 중앙 배치: 중심에서 ±15%
        if abs(centerX - 0.5) < 0.15 && abs(centerY - 0.5) < 0.15 {
            // 좌우 대칭 체크
            if salientObjects.count >= 2 {
                let symScore = checkSymmetry(objects: salientObjects)
                if symScore > 0.7 { return .symmetry }
            }
            return .centered
        }

        // 삼등분: 교차점 근처 (±10%)
        let thirdPoints: [(CGFloat, CGFloat)] = [
            (0.33, 0.33), (0.33, 0.67), (0.67, 0.33), (0.67, 0.67)
        ]
        for (tx, ty) in thirdPoints {
            if abs(centerX - tx) < 0.12 && abs(centerY - ty) < 0.12 {
                return .ruleOfThirds
            }
        }

        // 대각선: 주 피사체가 코너 쪽에 위치
        let cornerDist = min(
            hypot(centerX, centerY),
            hypot(centerX - 1, centerY),
            hypot(centerX, centerY - 1),
            hypot(centerX - 1, centerY - 1)
        )
        if cornerDist < 0.3 && areaRatio > 0.1 && areaRatio < 0.4 {
            return .diagonal
        }

        return .unknown
    }

    private static func checkSymmetry(objects: [VNRectangleObservation]) -> Double {
        guard objects.count >= 2 else { return 0 }
        // 좌우 대칭 점수: 왼쪽과 오른쪽 객체 면적/위치 유사도
        var leftArea: CGFloat = 0, rightArea: CGFloat = 0
        for obj in objects {
            let area = obj.boundingBox.width * obj.boundingBox.height
            if obj.boundingBox.midX < 0.5 {
                leftArea += area
            } else {
                rightArea += area
            }
        }
        guard leftArea > 0 && rightArea > 0 else { return 0 }
        let ratio = min(leftArea, rightArea) / max(leftArea, rightArea)
        return Double(ratio)
    }

    // MARK: - Final Tag Determination

    private static func determineFinalTag(
        sceneResults: [VNClassificationObservation],
        faces: [VNFaceObservation],
        textAmount: TextAmount,
        animalObjects: [String],
        hasPerson: Bool,
        personCoverage: Double,
        topIdentifiers: [String]
    ) -> String? {
        let faceCount = faces.count
        let maxFaceSize = faces.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0

        // 문서/텍스트 감지 (높은 우선순위)
        if textAmount == .heavy && faceCount == 0 {
            return "문서/텍스트"
        }

        // 동물 감지
        if !animalObjects.isEmpty && faceCount == 0 {
            return "동물/식물"
        }

        // 기존 sceneMapping 로직
        var tagScores: [(tag: String, confidence: Float)] = []
        for obs in sceneResults.prefix(5) {
            if let tag = mapToSceneTag(identifier: obs.identifier) {
                tagScores.append((tag, obs.confidence))
            }
        }

        let bestTag = tagScores.first?.tag

        // 얼굴 기반 오버라이드
        if faceCount >= 5 {
            return "단체/군중"
        } else if faceCount >= 3 && bestTag != "공연/콘서트" {
            return "단체/군중"
        } else if faceCount >= 1 && faceCount <= 2 && maxFaceSize > 0.08 {
            if bestTag == nil || bestTag == "실내" || bestTag == "풍경" ||
               bestTag == "건물/건축" || bestTag == "도시/야경" {
                return maxFaceSize > 0.15 ? "인물 (클로즈업)" : "인물"
            }
            return bestTag
        }

        // 인물 세그멘테이션 보완
        if hasPerson && personCoverage > 0.2 && faceCount == 0 {
            // 얼굴은 안 보이지만 사람이 크게 있음 (뒷모습, 실루엣 등)
            return "인물"
        }

        if let tag = bestTag {
            return tag
        }

        if faceCount >= 1 {
            return "인물"
        }

        return nil
    }

    // MARK: - Scene Mapping (PhotoStore와 동일, 확장)

    private static let sceneMapping: [String: String] = [
        // 인물
        "portrait": "인물", "selfie": "인물", "headshot": "인물",
        "person": "인물", "people": "인물", "man": "인물", "woman": "인물",
        "child": "인물", "girl": "인물", "boy": "인물", "baby": "인물",
        "fashion": "인물", "model": "인물",
        // 단체
        "crowd": "단체/군중", "audience": "단체/군중", "group": "단체/군중",
        "team": "단체/군중", "gathering": "단체/군중",
        // 이벤트
        "wedding": "웨딩", "bride": "웨딩", "groom": "웨딩", "ceremony": "웨딩",
        "concert": "공연/콘서트", "stage": "공연/콘서트", "performance": "공연/콘서트",
        "band": "공연/콘서트", "singer": "공연/콘서트", "microphone": "공연/콘서트",
        "party": "파티/축제", "celebration": "파티/축제", "birthday": "파티/축제",
        "festival": "파티/축제", "carnival": "파티/축제",
        "conference": "발표/회의", "presentation": "발표/회의", "meeting": "발표/회의",
        "podium": "발표/회의", "lecture": "발표/회의",
        "exhibition": "전시/팝업", "museum": "전시/팝업", "gallery": "전시/팝업",
        "display": "전시/팝업", "booth": "전시/팝업",
        // 자연/풍경
        "landscape": "풍경", "mountain": "풍경", "valley": "풍경",
        "field": "풍경", "countryside": "풍경", "prairie": "풍경", "hill": "풍경",
        "waterfall": "풍경", "canyon": "풍경", "cliff": "풍경",
        "sunset": "하늘/일몰", "sunrise": "하늘/일몰", "sky": "하늘/일몰",
        "cloud": "하늘/일몰", "dawn": "하늘/일몰", "dusk": "하늘/일몰", "rainbow": "하늘/일몰",
        "ocean": "바다/해변", "sea": "바다/해변", "beach": "바다/해변",
        "coast": "바다/해변", "wave": "바다/해변", "shore": "바다/해변",
        "lake": "바다/해변", "river": "바다/해변",
        // 도시/건축
        "cityscape": "도시/야경", "urban": "도시/야경", "downtown": "도시/야경",
        "street": "도시/야경", "night": "도시/야경", "neon": "도시/야경",
        "alley": "도시/야경", "highway": "도시/야경",
        "building": "건물/건축", "architecture": "건물/건축", "house": "건물/건축",
        "church": "건물/건축", "tower": "건물/건축", "bridge": "건물/건축",
        "skyscraper": "건물/건축", "temple": "건물/건축", "castle": "건물/건축",
        "mosque": "건물/건축", "cathedral": "건물/건축",
        // 실내
        "indoor": "실내", "room": "실내", "interior": "실내",
        "office": "실내", "studio": "실내", "gym": "실내", "classroom": "실내",
        "library": "실내", "corridor": "실내", "hallway": "실내",
        // 음식/음료
        "food": "음식/음료", "meal": "음식/음료", "dish": "음식/음료", "cooking": "음식/음료",
        "kitchen": "음식/음료", "sushi": "음식/음료", "pizza": "음식/음료", "cake": "음식/음료",
        "dessert": "음식/음료", "restaurant": "음식/음료", "bakery": "음식/음료",
        "drink": "음식/음료", "coffee": "음식/음료", "wine": "음식/음료", "beer": "음식/음료",
        "cocktail": "음식/음료", "beverage": "음식/음료", "cup": "음식/음료", "tea": "음식/음료",
        "fruit": "음식/음료", "vegetable": "음식/음료",
        // 동물/식물
        "animal": "동물/식물", "dog": "동물/식물", "cat": "동물/식물", "bird": "동물/식물",
        "pet": "동물/식물", "wildlife": "동물/식물", "horse": "동물/식물", "fish": "동물/식물",
        "insect": "동물/식물", "butterfly": "동물/식물", "rabbit": "동물/식물",
        "flower": "동물/식물", "plant": "동물/식물", "garden": "동물/식물",
        "tree": "동물/식물", "forest": "동물/식물", "leaf": "동물/식물", "botanical": "동물/식물",
        "floral": "동물/식물", "blossom": "동물/식물",
        // 사물
        "car": "차량/교통", "vehicle": "차량/교통", "motorcycle": "차량/교통",
        "bicycle": "차량/교통", "airplane": "차량/교통", "train": "차량/교통", "boat": "차량/교통",
        "ship": "차량/교통", "taxi": "차량/교통", "bus": "차량/교통",
        "product": "제품/상품", "merchandise": "제품/상품", "package": "제품/상품",
        "commercial": "제품/상품", "bottle": "제품/상품", "watch": "제품/상품",
        "shoes": "제품/상품", "jewelry": "제품/상품", "cosmetic": "제품/상품",
        "texture": "디테일/클로즈업", "pattern": "디테일/클로즈업",
        "abstract": "디테일/클로즈업", "macro": "디테일/클로즈업",
        "closeup": "디테일/클로즈업", "detail": "디테일/클로즈업",
        "document": "문서/텍스트", "text": "문서/텍스트", "sign": "문서/텍스트",
        "book": "문서/텍스트", "newspaper": "문서/텍스트", "screen": "문서/텍스트",
        "screenshot": "문서/텍스트", "menu": "문서/텍스트",
        // 스포츠
        "sport": "스포츠", "soccer": "스포츠", "basketball": "스포츠",
        "tennis": "스포츠", "swimming": "스포츠", "running": "스포츠",
        "baseball": "스포츠", "golf": "스포츠", "skiing": "스포츠",
        "climbing": "스포츠", "surfing": "스포츠", "yoga": "스포츠",
        "hiking": "스포츠", "martial": "스포츠", "boxing": "스포츠",
    ]

    private static func mapToSceneTag(identifier: String) -> String? {
        let words = identifier.lowercased()
            .split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" })
            .map(String.init)
        for word in words {
            if let tag = sceneMapping[word] { return tag }
        }
        if let tag = sceneMapping[identifier.lowercased()] { return tag }
        return nil
    }

    // MARK: - Animal Label Mapping

    private static func mapAnimalLabel(_ identifier: String) -> String {
        let map: [String: String] = [
            "Dog": "강아지", "Cat": "고양이", "Bird": "새",
            "Horse": "말", "Rabbit": "토끼", "Deer": "사슴",
            "Fish": "물고기", "Turtle": "거북이", "Lizard": "도마뱀",
        ]
        return map[identifier] ?? identifier
    }

    // MARK: - Mask Coverage

    private static func calculateMaskCoverage(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var personPixels = 0
        _ = width * height
        let step = max(1, min(width, height) / 64)  // 샘플링

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                if ptr[y * bytesPerRow + x] > 128 {
                    personPixels += 1
                }
            }
        }

        let totalSampled = (width / step) * (height / step)
        return totalSampled > 0 ? Double(personPixels) / Double(totalSampled) : 0
    }

    // MARK: - Batch Classification

    /// 배치 분류 (모든 사진에 대해 고급 분류 실행)
    static func classifyBatch(
        photos: [PhotoItem],
        cancelCheck: @escaping () -> Bool,
        progress: @escaping (Int) -> Void
    ) -> [UUID: ClassificationResult] {
        var results: [UUID: ClassificationResult] = [:]
        let lock = NSLock()
        let total = photos.count

        // v9.1.4: tier 차등 — 8GB Air 발열 / 스로틀 방지.
        let concurrency = SystemSpec.shared.visionBatchConcurrency()
        let semaphore = DispatchSemaphore(value: concurrency)

        // v9.1.4: low tier 는 직렬 for-loop — concurrentPerform 이 8 코어 점유 → 발열.
        let useSerial = SystemSpec.shared.effectiveTier == .low
        let runIter: (Int) -> Void = { idx in
            if cancelCheck() { return }
            semaphore.wait()
            defer { semaphore.signal() }

            let photo = photos[idx]
            guard !photo.isFolder && !photo.isParentFolder else {
                progress(idx + 1)
                return
            }

            autoreleasepool {
                let opts: [NSString: Any] = [
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480
                ]
                guard let source = CGImageSourceCreateWithURL(photo.jpgURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
                    progress(idx + 1)
                    return
                }

                let result = classify(cgImage: cgImage)

                lock.lock()
                results[photo.id] = result
                lock.unlock()
            }

            progress(idx + 1)
        }

        if useSerial {
            for i in 0..<total { runIter(i) }
        } else {
            DispatchQueue.concurrentPerform(iterations: total, execute: runIter)
        }

        return results
    }
}
