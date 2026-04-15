//
//  AIClassifyProgressBar.swift
//  PhotoRawManager
//
//  Extracted from ContentView.swift split.
//

import SwiftUI

struct AIClassifyProgressBar: View {
    @ObservedObject var store: PhotoStore
    @State private var dragOffset: CGSize = .zero
    @State private var position: CGPoint = .zero
    @State private var startTime = CFAbsoluteTimeGetCurrent()

    var body: some View {
        let (done, total) = store.aiClassifyProgress
        let progress = total > 0 ? Double(done) / Double(total) : 0
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let eta: String = {
            guard done > 0, elapsed > 1 else { return "계산 중..." }
            let rate = Double(done) / elapsed
            let remaining = Double(total - done) / rate
            if remaining < 60 { return "\(Int(remaining))초 남음" }
            return "\(Int(remaining / 60))분 \(Int(remaining) % 60)초 남음"
        }()
        let cost = Double(done) * (ClaudeVisionService.model.contains("haiku") ? 0.00025 : 0.003)

        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundColor(.purple)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("AI 분류 중...")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    // 에러 카운트 표시
                    if !store.aiClassifyErrors.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.red)
                            Text("\(store.aiClassifyErrors.count) 실패")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.red)
                        }
                        .help(store.aiClassifyErrors.last.map { "\($0.0): \($0.1)" } ?? "")
                    }
                    Text("\(done)/\(total)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 80, alignment: .trailing)
                }

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.purple)

                HStack {
                    Text("$\(String(format: "%.3f", cost))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                    Spacer()
                    Text(eta)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Button(action: {
                store.isAIClassifying = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("분류 취소")
        }
        .padding(12)
        .frame(width: 400)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 5)
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    position.x += value.translation.width
                    position.y += value.translation.height
                    dragOffset = .zero
                }
        )
        .offset(x: position.x, y: position.y)
        .onAppear { startTime = CFAbsoluteTimeGetCurrent() }
    }
}

// MARK: - Vision 로컬 분석 진행 패널
