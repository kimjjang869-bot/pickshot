//
//  AnalysisOptionsView.swift
//  PhotoRawManager
//
//  Extracted from ContentView+SupportingViews.swift split.
//

import SwiftUI
import AppKit

// MARK: - Analysis Options Popover

struct AnalysisOptionsView: View {
    @ObservedObject var store: PhotoStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("품질 분석 항목")
                .font(.system(size: 14, weight: .bold))

            Text("\(store.photos.count)장의 사진을 분석합니다")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            // Analysis options with toggles
            VStack(alignment: .leading, spacing: 8) {
                AnalysisToggle(
                    isOn: $store.analysisOptions.checkBlur,
                    icon: "camera.metering.spot",
                    title: "블러 / 초점 분석",
                    description: "흔들림, 초점 나감, 인물 초점 미스 감지"
                )

                AnalysisToggle(
                    isOn: $store.analysisOptions.checkClosedEyes,
                    icon: "eye.slash",
                    title: "눈 감김 감지",
                    description: "인물 사진에서 눈 감은 얼굴 감지 (Vision 프레임워크)"
                )

                AnalysisToggle(
                    isOn: $store.analysisOptions.checkFaceFocus,
                    icon: "person.crop.circle",
                    title: "인물 초점 분석",
                    description: "얼굴 영역의 선명도 검사 (흔들림/초점 미스)"
                )
            }

            Divider()

            HStack {
                Button("전체 선택") {
                    store.analysisOptions = AnalysisOptions(
                        checkBlur: true, checkClosedEyes: true,
                        checkFaceFocus: true
                    )
                }
                .font(.caption)
                .help("모든 분석 항목 선택")

                Button("전체 해제") {
                    store.analysisOptions = AnalysisOptions(
                        checkBlur: false, checkClosedEyes: false,
                        checkFaceFocus: false
                    )
                }
                .font(.caption)
                .help("모든 분석 항목 해제")

                Spacer()

                Button(action: {
                    store.showAnalysisOptions = false
                    store.runQualityAnalysis()
                }) {
                    Label("분석 시작", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .help("선택한 항목으로 분석 시작")
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

struct AnalysisToggle: View {
    @Binding var isOn: Bool
    let icon: String
    let title: String
    let description: String

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 20)
                    .foregroundColor(isOn ? .accentColor : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Analysis Progress Bar

struct AnalysisProgressBar: View {
    let progress: Double
    let total: Int
    let onStop: () -> Void

    var analyzed: Int {
        Int(progress * Double(total))
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12))
                    .foregroundColor(.purple)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [.purple, .blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * progress, height: 8)
                            .animation(.easeInOut(duration: 0.3), value: progress)
                    }
                }
                .frame(height: 8)

                Text("\(analyzed)/\(total)장")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)

                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.purple)
                    .frame(width: 40, alignment: .trailing)

                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.red)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("분석 중지")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
