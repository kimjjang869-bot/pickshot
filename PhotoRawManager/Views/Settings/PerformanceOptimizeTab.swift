//
//  PerformanceOptimizeTab.swift
//  PhotoRawManager
//
//  Extracted from SettingsView.swift split.
//

import SwiftUI
import Metal

struct PerformanceOptimizeTab: View {
    @State private var isBenchmarking = false
    @State private var benchmarkDone = false
    @State private var cpuScore: String = "—"
    @State private var gpuScore: String = "—"
    @State private var ramInfo: String = "—"
    @State private var diskSpeed: String = "—"
    @State private var recommendedProfile: String = "—"
    @State private var applied = false
    @State private var selectedProfile: String = ""

    @AppStorage("previewMaxResolution") private var previewMaxResolution = "original"
    @AppStorage("previewCacheSize") private var previewCacheSize = 20.0
    @AppStorage("defaultThumbnailSize") private var defaultThumbnailSize = 150.0
    @AppStorage("thumbnailCacheMaxGB") private var thumbnailCacheMaxGB: Double = 2.0
    @AppStorage("userPerformanceProfile") private var userPerformanceProfileRaw: String = "auto"

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 헤더
                VStack(spacing: 4) {
                    Image(systemName: "bolt.circle.fill").font(.system(size: 32)).foregroundColor(.accentColor)
                    Text("성능 최적화").font(.system(size: 16, weight: .bold))
                    Text("시스템을 분석하고 최적의 설정을 자동으로 적용합니다").font(.system(size: 12)).foregroundColor(.secondary)
                }

                Divider()

                // 시스템 정보
                GroupBox("시스템 정보") {
                    VStack(alignment: .leading, spacing: 8) {
                        infoRow("Mac", SystemSpec.shared.macModelMarketing)
                        infoRow("CPU", "\(SystemSpec.shared.cpuBrand) (\(SystemSpec.shared.coreCount)코어)")
                        infoRow("RAM", "\(SystemSpec.shared.ramGB)GB")
                        infoRow("GPU", SystemSpec.shared.gpuName)
                        infoRow("macOS", SystemSpec.shared.osVersion)
                        infoRow("성능 티어", "\(tierDisplayName(SystemSpec.shared.effectiveTier)) (자동: \(tierDisplayName(SystemSpec.shared.autoTier)))")
                    }.padding(4)
                }

                // 성능 프로필 선택 (SystemSpec 연동)
                GroupBox("성능 프로필") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("성능 프로필", selection: $userPerformanceProfileRaw) {
                            Text("자동").tag("auto")
                            Text("속도 우선").tag("speed")
                            Text("균형").tag("balanced")
                            Text("화질 우선").tag("quality")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: userPerformanceProfileRaw) { newValue in
                            if let p = UserPerformanceProfile(rawValue: newValue) {
                                SystemSpec.shared.userProfile = p
                            }
                        }
                        Text("자동: 하드웨어에 맞춘 기본값 · 속도/화질: 한 단계 티어 조정")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }.padding(4)
                }

                // 벤치마크 결과
                GroupBox("성능 측정") {
                    VStack(spacing: 12) {
                        if isBenchmarking {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("측정 중... (약 5초)").font(.system(size: 13)).foregroundColor(.secondary)
                            }
                        } else if benchmarkDone {
                            HStack(spacing: 20) {
                                benchBox(title: "CPU", value: cpuScore, color: .blue)
                                benchBox(title: "GPU", value: gpuScore, color: .green)
                                benchBox(title: "디스크", value: diskSpeed, color: .orange)
                                benchBox(title: "RAM", value: ramInfo, color: .purple)
                            }

                            Divider()

                            HStack {
                                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                                Text("추천 프로필: ").font(.system(size: 13, weight: .medium))
                                Text(recommendedProfile).font(.system(size: 13, weight: .bold)).foregroundColor(.accentColor)
                            }
                        }

                        Button(action: { runBenchmark() }) {
                            Label(benchmarkDone ? "다시 측정" : "성능 측정 시작", systemImage: "speedometer")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBenchmarking)
                    }.padding(4)
                }

                // 원클릭 최적화
                if benchmarkDone {
                    GroupBox("원클릭 최적화") {
                        VStack(spacing: 10) {
                            Text("측정 결과를 기반으로 미리보기, 캐시, 썸네일 설정을 자동으로 최적화합니다")
                                .font(.system(size: 12)).foregroundColor(.secondary)

                            HStack(spacing: 12) {
                                profileButton("speed", icon: "hare", title: "속도 우선", desc: "낮은 해상도\n빠른 탐색")
                                profileButton("balanced", icon: "scale.3d", title: "균형 (추천)", desc: "적정 해상도\n적정 캐시")
                                profileButton("quality", icon: "eye", title: "화질 우선", desc: "최대 해상도\n큰 캐시")
                            }

                            if applied {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    Text("설정 적용 완료!").font(.system(size: 12, weight: .medium)).foregroundColor(.green)
                                }
                            }
                        }.padding(4)
                    }
                }

                // 현재 설정 요약
                GroupBox("현재 설정") {
                    VStack(alignment: .leading, spacing: 6) {
                        settingRow("미리보기 해상도", previewMaxResolution == "original" ? "원본" : "\(previewMaxResolution)px")
                        settingRow("미리보기 캐시", "\(Int(previewCacheSize))장")
                        settingRow("썸네일 크기", "\(Int(defaultThumbnailSize))px")
                        settingRow("디스크 캐시 제한", "\(String(format: "%.1f", thumbnailCacheMaxGB))GB")
                    }.padding(4)
                }

            }.padding(20)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("SettingsResetTab"))) { _ in
            resetDefaults()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium)).frame(width: 60, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private func tierDisplayName(_ tier: PerformanceTier) -> String {
        switch tier {
        case .low: return "Low"
        case .standard: return "Standard"
        case .high: return "High"
        case .extreme: return "Extreme"
        }
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).frame(width: 140, alignment: .leading)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(.accentColor)
        }
    }

    private func benchBox(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
        }.frame(width: 80)
    }

    private func profileButton(_ profile: String, icon: String, title: String, desc: String) -> some View {
        let isSelected = selectedProfile == profile
        return Button(action: { applyProfile(profile) }) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.system(size: 11, weight: .bold))
                Text(desc).font(.system(size: 9)).foregroundColor(isSelected ? .white.opacity(0.8) : .secondary).multilineTextAlignment(.center)
            }
            .frame(width: 110, height: 85)
            .foregroundColor(isSelected ? .white : .primary)
            .background(isSelected ? Color.accentColor : Color.gray.opacity(0.15))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Benchmark

    private func runBenchmark() {
        isBenchmarking = true
        benchmarkDone = false
        applied = false

        DispatchQueue.global(qos: .userInitiated).async {
            let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024*1024*1024))
            let cores = ProcessInfo.processInfo.activeProcessorCount

            // CPU 벤치마크: 1000x1000 이미지 리사이즈 속도
            let cpuStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<10 {
                autoreleasepool {
                    let w = 1000, h = 1000
                    if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
                        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                        let _ = ctx.makeImage()
                    }
                }
            }
            let cpuTime = (CFAbsoluteTimeGetCurrent() - cpuStart) * 1000
            let cpuScoreVal = cpuTime < 50 ? "매우 빠름" : cpuTime < 100 ? "빠름" : cpuTime < 200 ? "보통" : "느림"

            // GPU 체크
            let hasGPU = MTLCreateSystemDefaultDevice() != nil
            let gpuName = MTLCreateSystemDefaultDevice()?.name ?? "없음"
            let gpuScoreVal = gpuName.contains("M4") || gpuName.contains("M3") ? "최고" :
                              gpuName.contains("M2") || gpuName.contains("M1") ? "우수" : "보통"

            // 디스크 속도 (임시 파일 쓰기/읽기)
            let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("pickshot_bench.tmp")
            let testData = Data(repeating: 0xAA, count: 10_000_000) // 10MB
            let diskStart = CFAbsoluteTimeGetCurrent()
            try? testData.write(to: tmpFile)
            let _ = try? Data(contentsOf: tmpFile)
            try? FileManager.default.removeItem(at: tmpFile)
            let diskTime = (CFAbsoluteTimeGetCurrent() - diskStart) * 1000
            let diskSpeedVal = diskTime < 50 ? "SSD 고속" : diskTime < 100 ? "SSD" : diskTime < 500 ? "HDD" : "느림"

            // 추천 프로필 결정
            let profile: String
            if ramGB >= 32 && cores >= 8 && gpuScoreVal == "최고" {
                profile = "🚀 고성능 — 최대 설정 가능"
            } else if ramGB >= 16 && cores >= 4 {
                profile = "⚡ 균형 — 표준 설정 추천"
            } else {
                profile = "🐢 절약 — 속도 우선 설정 추천"
            }

            DispatchQueue.main.async {
                self.cpuScore = cpuScoreVal
                self.gpuScore = gpuScoreVal
                self.ramInfo = "\(ramGB)GB"
                self.diskSpeed = diskSpeedVal
                self.recommendedProfile = profile
                self.isBenchmarking = false
                self.benchmarkDone = true
            }
        }
    }

    // MARK: - Apply Profile

    private func applyProfile(_ profile: String) {
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))

        switch profile {
        case "speed":
            // 속도 우선: 빠른 탐색, 메모리 절약
            previewMaxResolution = ramGB >= 16 ? "original" : "3000"
            previewCacheSize = Double(min(15, max(5, ramGB / 4)))
            defaultThumbnailSize = 100
            thumbnailCacheMaxGB = Double(min(2.0, max(0.5, Double(ramGB) / 16)))
        case "balanced":
            // 균형 (추천): RAM에 맞는 최적 설정
            previewMaxResolution = "original"
            previewCacheSize = Double(min(25, max(10, ramGB / 3)))
            defaultThumbnailSize = 100
            thumbnailCacheMaxGB = Double(min(3.0, max(0.5, Double(ramGB) / 10)))
        case "quality":
            // 화질 우선: 최대 해상도, 큰 캐시
            previewMaxResolution = "original"
            previewCacheSize = Double(min(40, max(15, ramGB / 2)))
            defaultThumbnailSize = 100
            thumbnailCacheMaxGB = Double(min(6.0, max(1.0, Double(ramGB) / 8)))
        default: break
        }

        selectedProfile = profile
        applied = true
        NotificationCenter.default.post(name: Notification.Name("SettingsChanged"), object: nil)
    }
}

extension PerformanceOptimizeTab {
    func resetDefaults() {
        previewMaxResolution = "original"; previewCacheSize = 20.0
        defaultThumbnailSize = 150.0; thumbnailCacheMaxGB = 2.0
        selectedProfile = ""; applied = false
    }
}
