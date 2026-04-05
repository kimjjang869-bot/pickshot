import SwiftUI

struct AIAnalysisView: View {
    let photo: PhotoItem
    @ObservedObject private var sub = SubscriptionManager.shared
    @State private var isAnalyzing = false
    @State private var analysisType: String = ""
    @State private var result: String = ""
    @State private var errorMessage: String = ""
    @State private var showAPIKeyInput = false
    @State private var showPaywall = false
    @State private var apiKeyInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                Text("AI 분석")
                    .font(.system(size: 12, weight: .bold))

                Spacer()

                // API Key settings
                Button(action: { showAPIKeyInput.toggle() }) {
                    Image(systemName: ClaudeVisionService.hasAPIKey ? "key.fill" : "key")
                        .font(.system(size: 10))
                        .foregroundColor(ClaudeVisionService.hasAPIKey ? .green : .red)
                }
                .buttonStyle(.plain)
                .help("Claude API 키 설정")
            }

            // API Key input
            if showAPIKeyInput {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude API Key")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    HStack {
                        SecureField("sk-ant-...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .onAppear {
                                apiKeyInput = ClaudeVisionService.getAPIKey() ?? ""
                            }
                        Button("저장") {
                            ClaudeVisionService.setAPIKey(apiKeyInput)
                            showAPIKeyInput = false
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(6)
            }

            // Coming soon notice
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.purple)
                Text("AI 기능은 추후 업데이트에서 오픈됩니다")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.purple.opacity(0.05))
            .cornerRadius(6)

            // Analysis buttons (Pro subscription required)
            if !isAnalyzing {
                let needsPro = sub.currentTier == .free
                HStack(spacing: 6) {
                    aiButton(title: "설명", icon: "text.bubble", color: .blue, locked: needsPro) {
                        runAnalysis("설명") { try await ClaudeVisionService.describePhoto(url: photo.jpgURL) }
                    }
                    aiButton(title: "보정제안", icon: "slider.horizontal.3", color: .orange, locked: needsPro) {
                        runAnalysis("보정제안") { try await ClaudeVisionService.suggestCorrections(url: photo.jpgURL) }
                    }
                    aiButton(title: "스타일", icon: "paintpalette", color: .purple, locked: needsPro) {
                        runAnalysis("스타일") { try await ClaudeVisionService.analyzeStyle(url: photo.jpgURL) }
                    }
                    aiButton(title: "평가", icon: "star.circle", color: .green, locked: needsPro) {
                        runAnalysis("평가") { try await ClaudeVisionService.ratePhoto(url: photo.jpgURL) }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("\(analysisType) 분석 중...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // Error
            if !errorMessage.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
            }

            // Result
            if !result.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("AI \(analysisType)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.purple)

                        // Cost estimate
                        Text("~$\(String(format: "%.3f", estimateCost))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(3)

                        Spacer()

                        Button(action: { copyResult() }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("복사")

                        Button(action: { result = ""; errorMessage = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("닫기")
                    }

                    ScrollView {
                        Text(result)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)

                    // Action buttons for correction suggestions
                    if analysisType == "보정제안" {
                        Divider()
                        HStack {
                            Text("이 보정 내용을 자동 보정에 적용하시겠습니까?")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: { applyAICorrection() }) {
                                Label("자동 보정 적용", systemImage: "wand.and.rays")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(8)
                .background(Color.purple.opacity(0.05))
                .cornerRadius(6)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func aiButton(title: String, icon: String, color: Color, locked: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: {
            if locked {
                showPaywall = true
            } else {
                action()
            }
        }) {
            VStack(spacing: 2) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 7))
                            .offset(x: 8, y: -6)
                    }
                }
                Text(title)
                    .font(.system(size: 9, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundColor(locked ? .gray : color)
            .background(locked ? Color.gray.opacity(0.05) : color.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func runAnalysis(_ type: String, task: @escaping () async throws -> String) {
        guard ClaudeVisionService.hasAPIKey else {
            errorMessage = "API 키를 먼저 설정해주세요"
            showAPIKeyInput = true
            return
        }

        isAnalyzing = true
        analysisType = type
        errorMessage = ""
        result = ""

        Task {
            do {
                let response = try await task()
                await MainActor.run {
                    result = response
                    isAnalyzing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAnalyzing = false
                }
            }
        }
    }

    // Rough cost estimate per request (~1600 input tokens for image + prompt, output varies)
    private var estimateCost: Double {
        // Sonnet: $3/M input, $15/M output
        // Typical: ~1600 input tokens (image+prompt), ~500 output tokens
        return (1600.0 / 1_000_000.0 * 3.0) + (Double(result.count) / 4.0 / 1_000_000.0 * 15.0)
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    private func applyAICorrection() {
        // Apply auto correction based on AI suggestion
        var options = CorrectionOptions()
        options.autoLevel = true
        options.autoWhiteBalance = true
        options.autoHorizon = true
        Task {
            let correctionResult = await Task.detached {
                ImageCorrectionService.autoCorrect(url: photo.jpgURL, options: options)
            }.value

            if let img = correctionResult.correctedImage {
                if ImageCorrectionService.saveCorrected(image: img, originalURL: photo.jpgURL) != nil {
                    await MainActor.run {
                        result = result + "\n\n--- 자동 보정 적용 완료 ---\n" + correctionResult.applied.joined(separator: "\n")
                    }
                }
            }
        }
    }
}
