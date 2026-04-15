//
//  GeminiService.swift
//  PhotoRawManager
//
//  Extracted from AIVisionService.swift split.
//

import Foundation
import AppKit

// MARK: - GeminiService

struct GeminiService {
    // Gemini 모델 매핑
    static var model: String {
        let engine = UserDefaults.standard.string(forKey: "aiClassifyEngine") ?? "geminiFlash"
        switch engine {
        case "geminiPro": return "gemini-2.5-pro"
        case "geminiFlash": return "gemini-2.5-flash"
        default: return "gemini-2.5-flash"
        }
    }

    enum GeminiError: LocalizedError {
        case noAPIKey
        case imageLoadFailed
        case encodingFailed
        case requestFailed(String)
        case invalidResponse
        case apiError(String)
        case rateLimited(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "Gemini API 키가 설정되지 않았습니다. (설정 → AI 분류)"
            case .imageLoadFailed: return "이미지를 불러올 수 없습니다."
            case .encodingFailed: return "이미지 인코딩 실패."
            case .requestFailed(let m): return "요청 실패: \(m)"
            case .invalidResponse: return "잘못된 Gemini 응답."
            case .apiError(let m): return "Gemini API 오류: \(m)"
            case .rateLimited(let m): return "Gemini 속도 제한: \(m)"
            }
        }
    }

    /// UserDefaults에서 Gemini API 키 읽기
    static func getAPIKey() -> String? {
        let key = UserDefaults.standard.string(forKey: "GeminiAPIKey")
        return (key?.isEmpty == false) ? key : nil
    }

    /// API 키 존재 여부
    static var hasAPIKey: Bool {
        return getAPIKey() != nil
    }

    /// Gemini API로 이미지 분석
    static func analyzeImage(url: URL, prompt: String) async throws -> String {
        guard let apiKey = getAPIKey() else {
            throw GeminiError.noAPIKey
        }

        // 이미지 로드 + 리사이즈 (Claude와 동일한 방식)
        guard let imageData = try? ClaudeVisionService.loadAndEncodeImage(from: url) else {
            throw GeminiError.imageLoadFailed
        }

        let base64String = imageData.base64EncodedString()

        // Gemini API 요청 구성
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let apiURL = URL(string: endpoint) else {
            throw GeminiError.encodingFailed
        }

        // Gemini 요청 바디: inline_data 형식
        // 프롬프트에 JSON 출력 강제 지시 추가
        let enforceJSON = prompt + "\n\n중요: 반드시 순수 JSON만 출력하세요. 설명, 마크다운, 코드블록 없이 { }만 출력하세요."

        let requestBody: [String: Any] = [
            "contents": [[
                "parts": [
                    [
                        "inline_data": [
                            "mime_type": "image/jpeg",
                            "data": base64String
                        ]
                    ],
                    [
                        "text": enforceJSON
                    ]
                ]
            ]],
            "generationConfig": [
                "maxOutputTokens": 2048,
                "temperature": 0.1,
                "responseMimeType": "application/json"  // JSON 출력 강제
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw GeminiError.encodingFailed
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        // HTTP 에러 처리
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = body["error"] as? [String: Any],
               let message = error["message"] as? String {
                // 429 = 속도 제한
                if http.statusCode == 429 {
                    throw GeminiError.rateLimited(message)
                }
                throw GeminiError.apiError(message)
            }
            throw GeminiError.requestFailed("HTTP \(http.statusCode)")
        }

        // 응답 파싱: candidates[0].content.parts[0].text
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw GeminiError.invalidResponse
        }

        // 토큰 사용량 추적
        if let usageMetadata = json["usageMetadata"] as? [String: Any] {
            let promptTokens = usageMetadata["promptTokenCount"] as? Int ?? 0
            let candidatesTokens = usageMetadata["candidatesTokenCount"] as? Int ?? 0
            await MainActor.run {
                APIUsageTracker.shared.addUsage(inputTokens: promptTokens, outputTokens: candidatesTokens)
            }
        }

        return text
    }
}
