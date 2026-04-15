//
//  VisionAnalysisProgressPanel.swift
//  PhotoRawManager
//
//  Extracted from ContentView.swift split.
//

import SwiftUI

struct VisionAnalysisProgressPanel: View {
    @ObservedObject var store: PhotoStore
    @ObservedObject var cullService = SmartCullService.shared

    /// 활성 작업 수
    private var activeCount: Int {
        (store.isClassifyingScenes ? 1 : 0) +
        (store.isGroupingFaces ? 1 : 0) +
        (cullService.isProcessing ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 14))
                    .foregroundColor(.cyan)
                    .symbolEffect(.pulse, isActive: true)
                Text("Vision 분석")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("\(activeCount)개 작업")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))

            Divider()

            VStack(spacing: 6) {
                // 장면 분류
                if store.isClassifyingScenes {
                    analysisRow(
                        icon: "eye.fill",
                        title: "장면 분류",
                        color: .blue,
                        done: store.classifyDoneCount,
                        total: store.classifyTotalCount,
                        progress: store.classifyProgress,
                        message: store.classifyStatusMessage,
                        startTime: store.classifyStartTime
                    )
                }

                // 얼굴 그룹핑
                if store.isGroupingFaces {
                    analysisRow(
                        icon: "person.crop.rectangle.stack",
                        title: "얼굴 그룹",
                        color: .orange,
                        done: store.faceGroupDoneCount,
                        total: store.faceGroupTotalCount,
                        progress: store.faceGroupProgress,
                        message: store.faceGroupStatusMessage,
                        startTime: store.faceGroupStartTime
                    )
                }

                // SmartCull
                if cullService.isProcessing {
                    analysisRow(
                        icon: "sparkles",
                        title: "스마트 셀렉",
                        color: .purple,
                        done: Int(cullService.progress * 100),
                        total: 100,
                        progress: cullService.progress,
                        message: cullService.statusMessage,
                        startTime: 0 // SmartCull은 자체 ETA 표시
                    )
                }
            }
            .padding(10)
        }
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    private func analysisRow(
        icon: String, title: String, color: Color,
        done: Int, total: Int, progress: Double,
        message: String, startTime: CFAbsoluteTime
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))

                Spacer()

                // 처리량 카운터
                Text("\(done)/\(total)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // 진행바
            ProgressView(value: min(progress, 1.0))
                .progressViewStyle(.linear)
                .tint(color)

            // 상세 메시지
            HStack {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                // 경과 시간
                if startTime > 0 {
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    Text(elapsed < 60 ? "\(Int(elapsed))초" : "\(Int(elapsed/60)):\(String(format: "%02d", Int(elapsed) % 60))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                // 퍼센트
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
        }
        .padding(8)
        .background(color.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - 커스텀 프롬프트 입력
