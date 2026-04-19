//
//  CustomPromptView.swift
//  PhotoRawManager
//
//  Extracted from ContentView.swift split.
//

import SwiftUI

struct CustomPromptView: View {
    @ObservedObject var store: PhotoStore
    @State private var promptText: String = ""
    @State private var selectedPreset: Int = -1
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI 분류 커스텀 프롬프트")
                .font(.headline)

            Text("사진을 어떻게 분류할지 자유롭게 작성하세요")
                .font(.caption)
                .foregroundColor(.secondary)

            // 프리셋 버튼
            HStack(spacing: 6) {
                Text("프리셋:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(Array(ClaudeVisionService.classifyPresets.enumerated()), id: \.offset) { idx, preset in
                    Button(preset.name) {
                        promptText = preset.prompt
                        selectedPreset = idx
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(selectedPreset == idx ? .accentColor : .secondary)
                }
            }

            // 프롬프트 입력
            TextEditor(text: $promptText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 200)
                .border(Color.gray.opacity(0.3))
                .onChange(of: promptText) { _, _ in selectedPreset = -1 }

            Text("⚠️ JSON 출력 형식을 포함해야 결과가 정상적으로 파싱됩니다")
                .font(.system(size: 10))
                .foregroundColor(.orange)

            HStack {
                Button("취소") { dismiss() }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    let count = store.filteredPhotos.count
                    let engine = UserDefaults.standard.string(forKey: "aiClassifyEngine") ?? "claudeHaiku"
                    let modelName: String = {
                        switch engine {
                        case "claudeHaiku": return "Haiku"
                        case "claudeSonnet": return "Sonnet"
                        case "geminiFlash": return "Gemini Flash"
                        case "geminiPro": return "Gemini Pro"
                        default: return engine
                        }
                    }()
                    Text("\(count)장 · \(modelName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    let costPerPhoto: Double = {
                        switch engine {
                        case "claudeHaiku": return 0.00025
                        case "claudeSonnet": return 0.003
                        case "geminiFlash": return 0.00008
                        case "geminiPro": return 0.00125
                        default: return 0.00025
                        }
                    }()
                    let cost = Double(count) * costPerPhoto
                    let batchSize: Double = {
                        switch engine {
                        case "claudeHaiku": return 5
                        case "claudeSonnet": return 3
                        case "geminiFlash": return 3
                        case "geminiPro": return 1
                        default: return 3
                        }
                    }()
                    let secPerPhoto: Double = engine.contains("Flash") || engine.contains("Haiku") ? 1.0 : 2.0
                    let seconds = Double(count) / batchSize * secPerPhoto
                    let minutes = Int(seconds / 60)
                    let secs = Int(seconds) % 60
                    Text("예상: $\(String(format: "%.2f", cost)) · \(minutes > 0 ? "\(minutes)분 " : "")\(secs)초")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
                Button("분류 실행") {
                    store.runAIClassification(customPrompt: promptText)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 450)
        .onAppear {
            promptText = ClaudeVisionService.defaultClassifyPrompt
            selectedPreset = 0
        }
    }
}
