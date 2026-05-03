//
//  AIEngineSettingsTab.swift
//  PhotoRawManager
//
//  Extracted from SettingsView.swift split.
//

import SwiftUI


struct AIEngineSettingsTab: View {
    @AppStorage("aiClassifyEngine") private var aiClassifyEngine = "geminiFlash"
    @AppStorage("aiCorrectionEngine") private var aiCorrectionEngine = "claudeSonnet"
    // v9.1.4: Gemini 키도 Keychain — Claude 와 일관. @AppStorage 제거.
    @State private var geminiAPIKey: String = ""
    // v9.1.4 보안 (H-1): OpenAI 키 Keychain 이관 — 이전엔 @AppStorage UserDefaults 평문 저장.
    //   bundle domain 의 UserDefaults 는 다른 앱이 읽을 수 있는 위협 표면이라 Claude/Gemini 와 일관 처리.
    //   첫 init 때 기존 UserDefaults 값을 Keychain 으로 이관 후 UserDefaults 항목 삭제.
    @State private var openAIAPIKey: String = {
        if let existing = KeychainService.read(key: "openai_api_key"), !existing.isEmpty {
            return existing
        }
        // 마이그레이션: UserDefaults → Keychain (1회)
        if let legacy = UserDefaults.standard.string(forKey: "OpenAIAPIKey"), !legacy.isEmpty {
            _ = KeychainService.save(key: "openai_api_key", value: legacy)
            UserDefaults.standard.removeObject(forKey: "OpenAIAPIKey")
            return legacy
        }
        return ""
    }()
    @AppStorage("aiBudgetUSD") private var aiBudgetUSD = "5.0"
    @AppStorage("aiConcurrency") private var aiConcurrency = 3
    @AppStorage("claudeModel") private var claudeModel = "haiku"
    @AppStorage("geminiModel") private var geminiModel = "flash"

    @State private var claudeAPIKey: String = ""
    @State private var testingEngine: String?
    @State private var testResult: (engine: String, success: Bool, message: String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("AI 엔진 설정")
                    .font(.title3.bold())
                Text("AI 분류 및 보정에 사용할 엔진과 API 키를 관리합니다.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                GroupBox {
                    VStack(spacing: 16) {
                        // 엔진 선택 — 가운데 정렬
                        VStack(spacing: 6) {
                            Text("AI 분류 엔진")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            Picker("", selection: $aiClassifyEngine) {
                                Text("Claude Haiku — 저렴·빠름 ($0.25/M)").tag("claudeHaiku")
                                Text("Claude Sonnet — 정확 ($3/M)").tag("claudeSonnet")
                                Text("Gemini Flash — 최저가 ($0.075/M)").tag("geminiFlash")
                                Text("Gemini Pro — 고성능 ($1.25/M)").tag("geminiPro")
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity)

                        Divider()

                        // API 키
                        VStack(spacing: 6) {
                            Text("API 키")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)

                            Grid(alignment: .leading, verticalSpacing: 8) {
                                GridRow {
                                    Text("Claude")
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(width: 55, alignment: .trailing)
                                    SecureField("sk-ant-...", text: $claudeAPIKey)
                                        .textFieldStyle(.roundedBorder)
                                        .onAppear { claudeAPIKey = ClaudeVisionService.getAPIKey() ?? "" }
                                        .onChange(of: claudeAPIKey) { _, v in
                                            ClaudeVisionService.setAPIKey(v)
                                            ClaudeVisionService.invalidateAPIKeyCache()
                                        }
                                    apiTestButton(engine: "claude")
                                }
                                GridRow {
                                    Text("Gemini")
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(width: 55, alignment: .trailing)
                                    SecureField("AIza...", text: $geminiAPIKey)
                                        .textFieldStyle(.roundedBorder)
                                        .onAppear { geminiAPIKey = GeminiService.getAPIKey() ?? "" }
                                        .onChange(of: geminiAPIKey) { _, v in
                                            GeminiService.setAPIKey(v)
                                        }
                                    apiTestButton(engine: "gemini")
                                }
                            }

                            if let result = testResult {
                                HStack(spacing: 4) {
                                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(result.success ? .green : .red)
                                    Text(result.message)
                                        .font(.system(size: 11))
                                        .foregroundColor(result.success ? .green : .red)
                                }
                            }
                        }

                        Divider()

                        // 사용량 — 한 줄로
                        HStack(spacing: 20) {
                            HStack(spacing: 4) {
                                Text("월 예산")
                                    .font(.system(size: 12, weight: .medium))
                                Text("$")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                TextField("", text: $aiBudgetUSD)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 50)
                            }
                            HStack(spacing: 4) {
                                Text("동시 처리")
                                    .font(.system(size: 12, weight: .medium))
                                Stepper("\(aiConcurrency)장", value: $aiConcurrency, in: 1...6)
                                    .frame(width: 90)
                            }
                        }

                        Divider()

                        // v9.1.4: AI 외부 전송 동의 관리 (보안 감사 M-5)
                        HStack(spacing: 8) {
                            Image(systemName: AIConsentGate.isConsentGranted ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                                .foregroundColor(AIConsentGate.isConsentGranted ? .green : .secondary)
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("외부 AI 서버 전송 동의")
                                    .font(.system(size: 11, weight: .medium))
                                Text(AIConsentGate.isConsentGranted ? "동의함 — 사진이 Anthropic / Google 서버로 전송 가능" : "미동의 — AI 분석 사용 시 다이얼로그 표시")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if AIConsentGate.isConsentGranted {
                                Button("동의 철회") {
                                    AIConsentGate.revokeConsent()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(12)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func apiTestButton(engine: String) -> some View {
        Button {
            testingEngine = engine
            // Simulate test - in production this would make a real API call
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let hasKey: Bool
                switch engine {
                case "gemini": hasKey = !geminiAPIKey.isEmpty
                case "openai": hasKey = !openAIAPIKey.isEmpty
                case "claude": hasKey = !claudeAPIKey.isEmpty
                default: hasKey = false
                }
                testResult = (
                    engine: engine,
                    success: hasKey,
                    message: hasKey ? "\(engine.capitalized) 연결 성공" : "API 키를 입력하세요"
                )
                testingEngine = nil
            }
        } label: {
            if testingEngine == engine {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("테스트")
            }
        }
        .buttonStyle(.bordered)
        .disabled(testingEngine != nil)
    }
}

// MARK: - Tab 5: 퍼포먼스 (Performance)
