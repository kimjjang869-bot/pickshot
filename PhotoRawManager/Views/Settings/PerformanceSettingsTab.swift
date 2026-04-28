//
//  PerformanceSettingsTab.swift
//  PhotoRawManager
//
//  Extracted from SettingsView.swift split.
//

import SwiftUI


struct PerformanceSettingsTab: View {
    @AppStorage("thumbnailCacheSize") private var thumbnailCacheSize = 3000.0
    @AppStorage("memoryLimit") private var memoryLimit = "auto"
    @AppStorage("prefetchRange") private var prefetchRange = 5
    @AppStorage("useGPUAcceleration") private var useGPUAcceleration = true
    @AppStorage("analysisCPULimit") private var analysisCPULimit = 75.0
    @AppStorage("rawDecodeQuality") private var rawDecodeQuality = "balanced"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("퍼포먼스 설정")
                    .font(.title3.bold())
                Text("캐시, 메모리, GPU 등 성능 관련 옵션을 조정합니다.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                GroupBox("캐시 및 메모리") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("썸네일 캐시 크기: \(Int(thumbnailCacheSize))장")
                            Slider(value: $thumbnailCacheSize, in: 1000...10000, step: 500)
                        }

                        Divider()

                        Picker("메모리 제한", selection: $memoryLimit) {
                            Text("자동").tag("auto")
                            Text("2GB").tag("2gb")
                            Text("4GB").tag("4gb")
                            Text("8GB").tag("8gb")
                        }

                        Divider()

                        Stepper("프리패치 범위: \(prefetchRange)장", value: $prefetchRange, in: 3...20)
                    }
                    .padding(4)
                }

                GroupBox("처리 성능") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("GPU 가속 사용", isOn: $useGPUAcceleration)

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("백그라운드 분석 CPU 제한: \(Int(analysisCPULimit))%")
                            Slider(value: $analysisCPULimit, in: 25...100, step: 5)
                        }

                        Divider()

                        Picker("RAW 디코딩 품질", selection: $rawDecodeQuality) {
                            Text("빠름").tag("fast")
                            Text("균형").tag("balanced")
                            Text("최고품질").tag("best")
                        }
                    }
                    .padding(4)
                }

                GroupBox("성능 모니터 & 로그") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("성능 로그가 자동으로 기록됩니다")
                                    .font(.system(size: 11))
                                Text("메모리, CPU, 응답시간 이상 시 경고 기록")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text("경로: ~/Library/Logs/PickShot/")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text("앱 로그: ~/Library/Caches/PickShot/logs/")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(spacing: 6) {
                                Button("성능 로그 열기") {
                                    PerformanceMonitor.shared.openLogFolder()
                                }
                                .font(.system(size: 11))

                                Button("앱 로그 열기") {
                                    AppLogger.openLogFolder()
                                }
                                .font(.system(size: 11))

                                Button("성능 리포트 복사") {
                                    let report = PerformanceMonitor.shared.generateReport()
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(report, forType: .string)
                                }
                                .font(.system(size: 11))
                            }
                        }
                    }
                    .padding(4)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Tab 6: 단축키 (Shortcuts)
