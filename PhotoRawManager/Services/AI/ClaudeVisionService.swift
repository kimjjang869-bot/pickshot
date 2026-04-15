//
//  ClaudeVisionService.swift
//  PhotoRawManager
//
//  Extracted from AIVisionService.swift split.
//

import Foundation
import AppKit

struct ClaudeVisionService {
    private static let keychainKey = "claude_api_key"
    private static let legacyDefaultsKey = "ClaudeVisionAPIKey"
    private static let apiEndpoint = "https://api.anthropic.com/v1/messages"
    // 설정의 aiClassifyEngine으로 모델 결정
    static var model: String {
        let engine = UserDefaults.standard.string(forKey: "aiClassifyEngine") ?? "claudeHaiku"
        switch engine {
        case "claudeSonnet": return "claude-sonnet-4-6"
        case "claudeHaiku": return "claude-haiku-4-5-20251001"
        default: return "claude-haiku-4-5-20251001"
        }
    }
    private static let maxImageDimension: CGFloat = 768  // 분류용 — 작을수록 빠르고 토큰 절약

    static func setAPIKey(_ key: String) {
        _ = KeychainService.save(key: keychainKey, value: key)
    }

    private static var _apiKeyCache: String?
    private static var _apiKeyCacheChecked = false

    static func getAPIKey() -> String? {
        if _apiKeyCacheChecked { return _apiKeyCache }
        // Try Keychain first, then migrate from UserDefaults
        if let key = KeychainService.read(key: keychainKey) {
            _apiKeyCache = key; _apiKeyCacheChecked = true; return key
        }
        KeychainService.migrateFromUserDefaults(userDefaultsKey: legacyDefaultsKey, keychainKey: keychainKey)
        let key = KeychainService.read(key: keychainKey)
        _apiKeyCache = key; _apiKeyCacheChecked = true
        return key
    }
    static func invalidateAPIKeyCache() { _apiKeyCacheChecked = false; _hasAPIKeyCache = nil }

    // Cached to avoid keychain read on every SwiftUI body evaluation
    private static var _hasAPIKeyCache: Bool?
    static var hasAPIKey: Bool {
        if let cached = _hasAPIKeyCache { return cached }
        let result: Bool
        if let key = getAPIKey() { result = !key.isEmpty } else { result = false }
        _hasAPIKeyCache = result
        return result
    }
    enum ClaudeVisionError: LocalizedError {
        case noAPIKey, imageLoadFailed, encodingFailed
        case requestFailed(String), invalidResponse, apiError(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "Claude API 키가 설정되지 않았습니다."
            case .imageLoadFailed: return "이미지를 불러올 수 없습니다."
            case .encodingFailed: return "이미지 인코딩 실패."
            case .requestFailed(let m): return "요청 실패: \(m)"
            case .invalidResponse: return "잘못된 응답."
            case .apiError(let m): return "API 오류: \(m)"
            }
        }
    }

    // MARK: - Core

    static func analyzeImage(url: URL, prompt: String) async throws -> String {
        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
            throw ClaudeVisionError.noAPIKey
        }

        guard let imageData = try? loadAndEncodeImage(from: url) else {
            throw ClaudeVisionError.imageLoadFailed
        }

        let base64String = imageData.base64EncodedString()
        let mediaType = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 1500,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": base64String]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw ClaudeVisionError.encodingFailed
        }

        guard let apiURL = URL(string: apiEndpoint) else { throw ClaudeVisionError.encodingFailed }
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let responseStr = String(data: data, encoding: .utf8) ?? "(no body)"
            FileHandle.standardError.write(Data("[AI-API] HTTP \(http.statusCode) response: \(responseStr)\n".utf8))
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = body["error"] as? [String: Any],
               let msg = err["message"] as? String {
                throw ClaudeVisionError.apiError(msg)
            }
            throw ClaudeVisionError.requestFailed("HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw ClaudeVisionError.invalidResponse
        }

        // Track usage from response
        if let usage = json["usage"] as? [String: Any] {
            let inputTokens = usage["input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0
            await MainActor.run {
                APIUsageTracker.shared.addUsage(inputTokens: inputTokens, outputTokens: outputTokens)
            }
        }

        return text
    }

    // MARK: - Convenience

    static func describePhoto(url: URL) async throws -> String {
        try await analyzeImage(url: url, prompt: """
        이 사진을 한국어로 자세히 설명해주세요. 피사체, 배경, 분위기, 조명, 구도를 포함해서 간결하게 작성해주세요.
        """)
    }

    static func suggestCorrections(url: URL) async throws -> String {
        try await analyzeImage(url: url, prompt: """
        이 사진의 보정 방향을 한국어로 제안해주세요:
        1. 노출 (과다/부족 영역)
        2. 화이트밸런스, 색감
        3. 구도 개선점
        4. 선명도, 초점 문제
        5. 크롭 제안
        6. 방해 요소
        라이트룸에서 적용할 수 있는 구체적인 수치를 포함해주세요.
        """)
    }

    static func analyzeStyle(url: URL) async throws -> String {
        try await analyzeImage(url: url, prompt: """
        이 사진의 스타일을 한국어로 분석해주세요:
        1. 장르 (인물, 풍경, 스트릿, 매크로 등)
        2. 조명 (자연광, 스튜디오, 골든아워 등)
        3. 색감과 톤
        4. 피사계심도 활용
        5. 구도 기법
        6. 전체적인 분위기와 예술적 의도
        7. 비슷한 유명 사진작가나 스타일
        """)
    }

    static func ratePhoto(url: URL) async throws -> String {
        try await analyzeImage(url: url, prompt: """
        이 사진을 프로 사진작가 관점에서 한국어로 평가해주세요:
        1. 기술 점수 (노출, 초점, 화밸) /10
        2. 구도 점수 /10
        3. 스토리/감성 점수 /10
        4. 종합 점수 /10
        5. 이 사진의 강점 (2줄)
        6. 개선할 점 (2줄)
        간결하게 작성해주세요.
        """)
    }

    // MARK: - AI Auto Correction (analyze → get values → apply)

    struct AICorrectionValues: Codable {
        var exposure: Double = 0        // EV (-2 ~ +2)
        var contrast: Double = 0        // (-30 ~ +30) 부드럽게
        var highlights: Double = 0      // (-50 ~ +50)
        var shadows: Double = 0         // (-50 ~ +50)
        var temperature: Double = 0     // shift in Kelvin (-1000 ~ +1000)
        var saturation: Double = 0      // (-30 ~ +30) 부드럽게
        var sharpness: Double = 0       // (0 ~ 40)
        var horizonAngle: Double = 0    // 수평 보정 각도 (-5 ~ +5)
        var cropTop: Double = 0         // 크롭 비율 (0~0.15)
        var cropBottom: Double = 0
        var cropLeft: Double = 0
        var cropRight: Double = 0
        var description: String = ""
        var skipToneCurve: Bool = false
    }

    /// Ask Claude to analyze photo and return correction values as JSON
    static func getAICorrectionValues(url: URL) async throws -> AICorrectionValues {
        let response = try await analyzeImage(url: url, prompt: """
        당신은 조선희, 김중만, 목나정 급의 한국 탑 포토그래퍼입니다.
        20년 경력의 베테랑으로, 당신이 직접 촬영한 사진을 최종 납품 전에 보정하는 상황입니다.

        당신의 보정 철학:
        - "좋은 보정은 보정한 티가 안 나는 것"
        - 원본의 빛과 분위기를 최대한 살리면서, 한 단계 더 끌어올린다
        - 클라이언트가 "원본이 이랬나?" 할 정도로 자연스럽게
        - 사진의 장르(공연/인물/풍경/스냅)를 먼저 파악하고 그에 맞는 톤 적용

        장르별 보정 방향:
        [공연/콘서트] 무대 조명 살리기, 피사체 강조, 관객석 살짝 밝히기, 따뜻한 톤
        [인물/화보] 피부톤 맑고 깨끗하게, 쿨톤, 공기감, W매거진/보그코리아 느낌
        [풍경/건축] 선명하고 깊은 색감, 약간의 대비, 하늘 강조
        [스냅/스트릿] 필름 느낌, 살짝 따뜻한 톤, 자연스러운 그레인 느낌
        [행사/웨딩] 밝고 화사하게, 하이라이트 부드럽게, 피부톤 최우선

        핵심 규칙:
        - 이 사진이 어떤 장르인지 먼저 판단하고 그에 맞는 보정
        - exposure: 최대 ±1.0
        - contrast: -10 ~ +8
        - saturation: -15 ~ +5
        - highlights: -25 ~ +5
        - shadows: 0 ~ +20
        - temperature: -400 ~ +400
        - sharpness: 3 ~ 15

        ★ 수평/수직 보정 (매우 중요 - 반드시 분석할 것):
        - 사진의 수평선, 건물 수직선, 무대 라인 등을 분석하여 기울어져 있는지 확인
        - 0.3도라도 기울어져 있으면 horizonAngle 값을 반드시 넣을 것
        - 양수 = 시계방향 회전 필요, 음수 = 반시계방향 회전 필요

        ★ 크롭 (매우 중요 - 반드시 분석할 것):
        - 사진의 주 피사체 위치를 분석
        - 삼분할법/황금분할에 피사체가 오도록 크롭 제안
        - 불필요한 여백, 방해 요소가 있으면 잘라내기
        - 인물 사진: 머리 위 여백 적절히, 시선 방향에 여유 공간
        - 공연 사진: 무대 위 불필요한 검은 공간 제거
        - cropTop/Bottom/Left/Right 값이 모두 0인 경우는 거의 없음 (최소한 미세 크롭이라도 제안)
        - 각 변 최대 0.12 (12%)

        ★ skipToneCurve:
        - 공연/콘서트 사진은 true (무대 조명 톤을 보존)
        - 그 외 장르는 false

        순수 JSON만 출력:
        {
          "exposure": 0.0,
          "contrast": 0,
          "highlights": 0,
          "shadows": 0,
          "temperature": 0,
          "saturation": 0,
          "sharpness": 0,
          "horizonAngle": 0.0,
          "cropTop": 0, "cropBottom": 0, "cropLeft": 0, "cropRight": 0,
          "description": "장르: OO | 보정 의도 한 줄",
          "skipToneCurve": false
        }
        """)

        // Parse JSON from response
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            print("AI response parse failed: \(cleaned.prefix(200))")
            throw ClaudeVisionError.invalidResponse
        }
        do {
            let values = try JSONDecoder().decode(AICorrectionValues.self, from: data)
            return values
        } catch {
            print("AI response parse failed: \(error) — \(cleaned.prefix(200))")
            throw ClaudeVisionError.invalidResponse
        }
    }

    /// Apply AI correction values to image using Core Image (soft, natural feel)
    static func applyAICorrection(url: URL, values: AICorrectionValues, photo: PhotoItem) -> CorrectionResult {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        var result = CorrectionResult()

        // Use RAW file if available (better quality), fallback to JPG
        let rawURL = photo.rawURL
        let sourceURL = rawURL ?? url
        guard let originalImage = CIImage(contentsOf: sourceURL) else { return result }
        var image = originalImage
        let softness: Double = 0.75  // 75% of AI suggestion (veteran touch = confident but restrained)
        let isRAW = rawURL != nil

        // 1. Horizon straighten
        if abs(values.horizonAngle) > 0.2 {
            let radians = values.horizonAngle * .pi / 180.0
            if let filter = CIFilter(name: "CIStraightenFilter") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(Float(-radians), forKey: "inputAngle")
                if let output = filter.outputImage { image = output }
                result.applied.append("수평 보정 \(String(format: "%+.1f", values.horizonAngle))°")
            }
        }

        // 2. Crop (golden ratio / rule of thirds)
        let hasCrop = values.cropTop > 0.005 || values.cropBottom > 0.005 ||
                      values.cropLeft > 0.005 || values.cropRight > 0.005
        if hasCrop {
            let ext = image.extent
            let x = ext.origin.x + ext.width * CGFloat(values.cropLeft)
            let y = ext.origin.y + ext.height * CGFloat(values.cropBottom)
            let w = ext.width * CGFloat(1.0 - values.cropLeft - values.cropRight)
            let h = ext.height * CGFloat(1.0 - values.cropTop - values.cropBottom)
            let cropRect = CGRect(x: x, y: y, width: w, height: h)
            image = image.cropped(to: cropRect)
            result.applied.append("크롭 (황금분할)")
        }

        // 3. Exposure (softened)
        let expo = values.exposure * softness
        if abs(expo) > 0.05 {
            if let filter = CIFilter(name: "CIExposureAdjust") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(Float(expo), forKey: "inputEV")
                if let output = filter.outputImage { image = output }
                result.applied.append("노출 \(String(format: "%+.1f", expo))EV")
            }
        }

        // 4. Highlights & Shadows (softened)
        let hi = values.highlights * softness
        let sh = values.shadows * softness
        if abs(hi) > 3 || abs(sh) > 3 {
            if let filter = CIFilter(name: "CIHighlightShadowAdjust") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(Float(1.0 + hi / 200.0), forKey: "inputHighlightAmount")
                filter.setValue(Float(sh / 200.0 * -1), forKey: "inputShadowAmount")
                if let output = filter.outputImage { image = output }
                result.applied.append("하이라이트 \(Int(hi)), 쉐도우 \(Int(sh))")
            }
        }

        // 5. Contrast + Saturation (very gentle)
        let con = values.contrast * softness * 0.5  // Extra soft for contrast
        let sat = values.saturation * softness * 0.5
        if abs(con) > 2 || abs(sat) > 2 {
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(Float(1.0 + con / 200.0), forKey: "inputContrast")
                filter.setValue(Float(1.0 + sat / 200.0), forKey: "inputSaturation")
                if let output = filter.outputImage { image = output }
                if abs(con) > 2 { result.applied.append("대비 \(Int(con))") }
                if abs(sat) > 2 { result.applied.append("채도 \(Int(sat))") }
            }
        }

        // 6. Temperature (gentle)
        let temp = values.temperature * softness
        if abs(temp) > 50 {
            if let filter = CIFilter(name: "CITemperatureAndTint") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(CIVector(x: CGFloat(6500 + temp), y: 0), forKey: "inputNeutral")
                filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
                if let output = filter.outputImage { image = output }
                result.applied.append("색온도 \(Int(temp))K")
            }
        }

        // 7. Sharpness (subtle, skin-safe)
        let sharp = values.sharpness * softness
        if sharp > 3 {
            if let filter = CIFilter(name: "CIUnsharpMask") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(Float(2.0), forKey: "inputRadius")
                filter.setValue(Float(sharp / 150.0), forKey: "inputIntensity")
                if let output = filter.outputImage { image = output }
                result.applied.append("선명도 +\(Int(sharp))")
            }
        }

        // 8. Subtle tone curve (professional finish)
        // Light fade for airy feel - skip for stage/concert photos
        if !values.skipToneCurve {
            if let filter = CIFilter(name: "CIToneCurve") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(CIVector(x: 0.0, y: 0.02), forKey: "inputPoint0")
                filter.setValue(CIVector(x: 0.25, y: 0.23), forKey: "inputPoint1")
                filter.setValue(CIVector(x: 0.5, y: 0.50), forKey: "inputPoint2")
                filter.setValue(CIVector(x: 0.75, y: 0.76), forKey: "inputPoint3")
                filter.setValue(CIVector(x: 1.0, y: 0.99), forKey: "inputPoint4")
                if let output = filter.outputImage { image = output }
                result.applied.append("톤커브 미세 조정")
            }
        }

        // Render
        if let cgImage = context.createCGImage(image, from: image.extent) {
            result.correctedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        // Save to 자동보정 folder
        if let correctedImage = result.correctedImage {
            let saved = ImageCorrectionService.saveWithRAW(image: correctedImage, photo: photo)
            result.savedJPGURL = saved.jpgURL
            result.savedRAWURL = saved.rawURL
        }

        if !result.applied.isEmpty {
            let source = isRAW ? "RAW 원본 기반" : "JPG 기반"
            result.applied.insert("🤖 \(values.description) [\(source)]", at: 0)
        }

        return result
    }

    // MARK: - AI Smart Classification (Event/Commercial Photography)

    struct AIPhotoClassification: Codable {
        var category: String = ""          // 클린샷/인물/군중/분위기/디테일/무대
        var subcategory: String = ""       // 세부 분류
        var mood: String = ""              // 분위기
        var peopleCount: String = ""       // 없음/1명/2-5명/6-10명/다수
        var cameraAwareness: String = ""   // 카메라 인식 여부
        var usability: String = ""         // 즉시사용/편집후사용/참고용/삭제후보
        var bestFor: String = ""           // 용도 추천
        var description: String = ""       // 한 줄 설명
        var score: Int = 0                 // 0~100 활용도 점수
    }

    /// AI 기반 스마트 분류 - 행사/이벤트/상업 사진에 최적화
    /// 기본 프롬프트 (행사/이벤트)
    static let defaultClassifyPrompt = """
    당신은 행사/이벤트/상업 사진 전문 에디터입니다. 이 사진을 분류해주세요.

    분류 기준:
    [category] 대분류 - 반드시 아래 중 하나:
    - 클린샷: 사람 없이 공간/제품/세트만 보이는 깨끗한 구도
    - 인물: 특정 인물이 주 피사체 (1~3명)
    - 그룹: 소규모 그룹 포즈 (4~10명)
    - 군중: 많은 사람, 관객석, 대규모 모임
    - 무대: 공연/발표/MC/무대 위 장면
    - 분위기: 공간 전체 분위기, 조명, 장식 등
    - 디테일: 음식, 소품, 간판, 클로즈업
    - 비하인드: 준비 과정, 리허설, 백스테이지
    - 기념: 포토월, 시상, 기념촬영, 공식 행사

    [subcategory] 세부 분류 (예: "MC토크", "단체기념", "포토월", "무대공연", "관객반응", "음식클로즈업")
    [mood] 분위기 (예: "역동적", "차분한", "화려한", "감성적", "긴장감", "축제")
    [peopleCount] "없음"/"1명"/"2-3명"/"4-10명"/"다수"
    [cameraAwareness] "정면응시"/"자연스러운"/"무의식"/"뒷모습"
    [usability] "즉시사용"/"편집후사용"/"참고용"/"삭제후보"
    [bestFor] 용도 (예: "SNS게시", "보도자료", "포트폴리오", "클라이언트납품", "내부기록")
    [score] 0~100 활용도 점수 (구도+초점+표정+조명+활용성 종합)
    [description] 사진 한 줄 설명

    순수 JSON만 출력:
    {"category":"","subcategory":"","mood":"","peopleCount":"","cameraAwareness":"","usability":"","bestFor":"","description":"","score":0}
    """

    /// 프리셋 프롬프트 목록
    static let classifyPresets: [(name: String, prompt: String)] = [
        ("행사/이벤트", defaultClassifyPrompt),
        ("웨딩", """
        웨딩 사진 전문가로서 이 사진을 분류해주세요.
        [category] 대분류: 본식/피로연/스냅/준비/야외/스튜디오/단체/디테일
        [subcategory] 세부 (예: "신랑신부입장", "부케토스", "케이크커팅", "축가")
        [mood] 분위기, [usability] 즉시사용/편집후사용/참고용/삭제후보
        [bestFor] 용도, [score] 0~100, [description] 한 줄 설명
        순수 JSON만: {"category":"","subcategory":"","mood":"","usability":"","bestFor":"","description":"","score":0}
        """),
        ("여행", """
        여행 사진 에디터로서 이 사진을 분류해주세요.
        [category] 대분류: 풍경/건축/음식/거리/인물/야경/해변/산/문화재/교통
        [subcategory] 세부 설명, [mood] 분위기
        [usability] 즉시사용/편집후사용/참고용/삭제후보
        [bestFor] 용도, [score] 0~100, [description] 한 줄 설명
        순수 JSON만: {"category":"","subcategory":"","mood":"","usability":"","bestFor":"","description":"","score":0}
        """),
        ("제품/상품", """
        상업 제품 사진 전문가로서 이 사진을 분류해주세요.
        [category] 대분류: 제품단독/라이프스타일/디테일/패키지/모델착용/배경/비교
        [subcategory] 세부, [mood] 분위기
        [usability] 즉시사용/편집후사용/참고용/삭제후보
        [bestFor] 용도 (쇼핑몰/SNS/카탈로그/상세페이지)
        [score] 0~100, [description] 한 줄 설명
        순수 JSON만: {"category":"","subcategory":"","mood":"","usability":"","bestFor":"","description":"","score":0}
        """),
    ]

    static func classifyPhoto(url: URL, customPrompt: String? = nil) async throws -> AIPhotoClassification {
        let prompt = customPrompt ?? defaultClassifyPrompt

        // 최대 2회 시도 (파싱 실패 시 재시도)
        for attempt in 0..<2 {
            let response = try await analyzeImageWithCurrentEngine(url: url, prompt: prompt)

            // JSON 추출: 응답에서 { } 블록만 꺼냄
            let cleaned = extractJSON(from: response)

            guard let data = cleaned.data(using: .utf8) else {
                if attempt == 0 { continue }
                fputs("[API] parse fail (no data): \(response.prefix(100))\n", stderr)
                throw ClaudeVisionError.invalidResponse
            }
            do {
                let classification = try JSONDecoder().decode(AIPhotoClassification.self, from: data)
                return classification
            } catch {
                if attempt == 0 {
                    fputs("[API] parse retry: \(error)\n", stderr)
                    continue  // 재시도
                }
                fputs("[API] parse fail: \(error) — \(cleaned.prefix(150))\n", stderr)
                throw ClaudeVisionError.invalidResponse
            }
        }
        throw ClaudeVisionError.invalidResponse
    }

    /// 응답 텍스트에서 JSON 블록만 추출
    private static func extractJSON(from text: String) -> String {
        var s = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // { } 블록 추출 (앞뒤 텍스트 제거)
        if let startIdx = s.firstIndex(of: "{"),
           let endIdx = s.lastIndex(of: "}") {
            s = String(s[startIdx...endIdx])
        }
        return s
    }

    /// Batch classify multiple photos with progress
    static func batchClassify(
        photos: [PhotoItem],
        customPrompt: String? = nil,
        progress: @escaping (Int, Int) -> Void,
        onClassified: ((PhotoItem, AIPhotoClassification) -> Void)? = nil,
        onError: ((PhotoItem, String) -> Void)? = nil
    ) async throws -> [UUID: AIPhotoClassification] {
        var results: [UUID: AIPhotoClassification] = [:]
        let total = photos.count

        // 엔진별 최적 동시 처리 수 (Tier 1 기준 안전값)
        let engine = UserDefaults.standard.string(forKey: "aiClassifyEngine") ?? "claudeHaiku"
        let batchSize: Int = {
            switch engine {
            case "claudeHaiku": return 5      // 50 RPM
            case "claudeSonnet": return 3     // 50 RPM, 느림
            case "geminiFlash": return 10     // 1000 RPM(유료), 빠름
            case "geminiPro": return 3        // 360 RPM(유료)
            default: return 3
            }
        }()
        for batchStart in stride(from: 0, to: total, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, total)
            let batch = Array(photos[batchStart..<batchEnd])

            await withTaskGroup(of: (UUID, AIPhotoClassification?, String?).self) { group in
                for photo in batch {
                    group.addTask {
                        do {
                            let classification = try await classifyPhoto(url: photo.jpgURL, customPrompt: customPrompt)
                            return (photo.id, classification, nil)
                        } catch {
                            fputs("[API] ERROR \(photo.jpgURL.lastPathComponent): \(error.localizedDescription)\n", stderr)
                            return (photo.id, nil, error.localizedDescription)
                        }
                    }
                }
                for await (id, classification, errorMsg) in group {
                    if let c = classification {
                        results[id] = c
                        fputs("[API] classified \(id.uuidString.prefix(6)) cat=\(c.category)\n", stderr)
                        // 분류 즉시 콜백 (폴더 이동 등)
                        if let photo = batch.first(where: { $0.id == id }) {
                            onClassified?(photo, c)
                        }
                    } else {
                        fputs("[API] FAILED \(id.uuidString.prefix(6))\n", stderr)
                        // 에러 콜백 호출
                        if let photo = batch.first(where: { $0.id == id }) {
                            onError?(photo, errorMsg ?? "알 수 없는 오류")
                        }
                    }
                }
            }

            await MainActor.run {
                progress(results.count, total)  // 성공한 것만 카운트
            }
        }

        return results
    }

    /// Select best shots from a group of similar photos
    static func selectBestShots(urls: [(id: UUID, url: URL)], count: Int = 1) async throws -> [UUID] {
        // Encode all images compactly
        var imageDescriptions: [String] = []
        for (i, item) in urls.enumerated() {
            imageDescriptions.append("사진 \(i+1) (ID: \(item.id.uuidString.prefix(8)))")
        }

        // For groups up to 6, send all. For larger, send first 6
        let maxPhotos = min(urls.count, 6)
        let selected = Array(urls.prefix(maxPhotos))

        // Build multi-image prompt
        let prompt = """
        이 \(selected.count)장의 사진은 비슷한 장면에서 연속 촬영된 것입니다.
        프로 에디터 관점에서 가장 좋은 \(count)장을 선택해주세요.

        선택 기준:
        1. 초점이 가장 정확한 것
        2. 표정이 가장 자연스러운 것 (인물인 경우)
        3. 구도가 가장 좋은 것
        4. 눈 감김/흔들림이 없는 것

        각 사진의 ID 앞 8자리와 선택 이유를 JSON으로:
        {"best": ["ID1", "ID2"], "reasons": {"ID1": "이유", "ID2": "이유"}}
        """

        let response = try await analyzeImage(url: selected[0].url, prompt: prompt)
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse best IDs
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bestIDs = json["best"] as? [String] else {
            return []
        }

        // Match short IDs back to full UUIDs
        return urls.filter { item in
            bestIDs.contains(where: { item.id.uuidString.lowercased().hasPrefix($0.lowercased()) })
        }.map { $0.id }
    }

    // MARK: - 엔진 라우팅 (Claude / Gemini)

    /// 현재 설정된 엔진에 따라 적절한 API로 이미지 분석
    static func analyzeImageWithCurrentEngine(url: URL, prompt: String) async throws -> String {
        let engine = UserDefaults.standard.string(forKey: "aiClassifyEngine") ?? "claudeHaiku"
        if engine.hasPrefix("gemini") {
            return try await GeminiService.analyzeImage(url: url, prompt: prompt)
        } else {
            return try await analyzeImage(url: url, prompt: prompt)
        }
    }

    // MARK: - Image Encoding

    static func loadAndEncodeImage(from url: URL) throws -> Data {
        let jpeg: Data? = try autoreleasepool {
            // 빠른 경로: CGImageSource로 임베디드 썸네일 추출 (RAW 전체 디코딩 회피)
            let targetPx = maxImageDimension
            let opts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: targetPx,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
                throw ClaudeVisionError.imageLoadFailed
            }

            let bmp = NSBitmapImageRep(cgImage: cgImage)
            // 분류용: 압축률 높여서 파일 크기 줄임 (전송 속도 향상)
            guard let jpegData = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
                throw ClaudeVisionError.encodingFailed
            }
            return jpegData
        }

        guard let result = jpeg else {
            throw ClaudeVisionError.encodingFailed
        }
        return result
    }
}
