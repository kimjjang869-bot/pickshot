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
    @State private var cpuLabel: String = "—"
    @State private var gpuLabel: String = "—"
    @State private var ramLabel: String = "—"
    @State private var diskLabel: String = "—"
    @State private var totalScore: Int = 0
    @State private var recommendedProfile: String = "—"
    @State private var applied = false
    @State private var selectedProfile: String = ""

    @AppStorage("previewMaxResolution") private var previewMaxResolution = "original"
    @AppStorage("previewCacheSize") private var previewCacheSize = 20.0
    @AppStorage("defaultThumbnailSize") private var defaultThumbnailSize = 150.0
    @AppStorage("thumbnailCacheMaxGB") private var thumbnailCacheMaxGB: Double = 2.0

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
                        infoRow("성능 티어", tierDisplayName(SystemSpec.shared.autoTier))
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
                                benchBox(title: "CPU", value: cpuLabel, color: .blue)
                                benchBox(title: "GPU", value: gpuLabel, color: .green)
                                benchBox(title: "디스크", value: diskLabel, color: .orange)
                                benchBox(title: "RAM", value: ramLabel, color: .purple)
                            }

                            Divider()

                            // 종합 점수 (RAM 40% 가중)
                            HStack(spacing: 8) {
                                Text("종합 점수")
                                    .font(.system(size: 12, weight: .medium))
                                Text("\(totalScore) / 100")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundColor(scoreColor(totalScore))
                                Spacer()
                            }

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
                                profileButton("quality", icon: "eye", title: "화질 우선", desc: "높은 해상도\n충분한 캐시")
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
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
        }.frame(width: 80)
    }

    private func scoreColor(_ score: Int) -> Color {
        if score >= 80 { return .green }
        if score >= 60 { return .blue }
        if score >= 40 { return .orange }
        return .red
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

    // MARK: - Benchmark (종합 점수 도입: RAM 40% + CPU 25% + GPU 15% + Disk 20%)

    private func runBenchmark() {
        isBenchmarking = true
        benchmarkDone = false
        applied = false

        DispatchQueue.global(qos: .userInitiated).async {
            let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024*1024*1024))

            // --- CPU 벤치마크: 1000×1000 이미지 생성 10회 ---
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
            // 재조정된 임계값 — M1 8GB 는 ~40-50ms 로 "보통" 에 들어감
            let cpuScoreVal: Int
            let cpuLabelVal: String
            if cpuTime < 20      { cpuScoreVal = 100; cpuLabelVal = "최고" }
            else if cpuTime < 40 { cpuScoreVal = 80;  cpuLabelVal = "빠름" }
            else if cpuTime < 80 { cpuScoreVal = 60;  cpuLabelVal = "보통" }
            else if cpuTime < 160{ cpuScoreVal = 30;  cpuLabelVal = "느림" }
            else                 { cpuScoreVal = 10;  cpuLabelVal = "매우 느림" }

            // --- GPU: 칩 세대 기반 ---
            let gpuName = MTLCreateSystemDefaultDevice()?.name ?? ""
            let gpuScoreVal: Int
            let gpuLabelVal: String
            if gpuName.contains("M4")      { gpuScoreVal = 100; gpuLabelVal = "최고" }
            else if gpuName.contains("M3") { gpuScoreVal = 85;  gpuLabelVal = "우수" }
            else if gpuName.contains("M2") { gpuScoreVal = 70;  gpuLabelVal = "양호" }
            else if gpuName.contains("M1") { gpuScoreVal = 55;  gpuLabelVal = "보통" }
            else if gpuName.contains("Intel") { gpuScoreVal = 20; gpuLabelVal = "낮음" }
            else                           { gpuScoreVal = 40;  gpuLabelVal = "보통" }

            // --- RAM: PickShot 의 최대 병목 — 가중치 40% ---
            let ramScoreVal: Int
            let ramLabelVal: String
            if ramGB >= 24      { ramScoreVal = 100; ramLabelVal = "최고" }
            else if ramGB >= 16 { ramScoreVal = 65;  ramLabelVal = "보통" }
            else if ramGB >= 8  { ramScoreVal = 30;  ramLabelVal = "낮음" }
            else                { ramScoreVal = 10;  ramLabelVal = "매우 낮음" }

            // --- Disk: 10MB write+read ---
            let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("pickshot_bench.tmp")
            let testData = Data(repeating: 0xAA, count: 10_000_000)
            let diskStart = CFAbsoluteTimeGetCurrent()
            try? testData.write(to: tmpFile)
            let _ = try? Data(contentsOf: tmpFile)
            try? FileManager.default.removeItem(at: tmpFile)
            let diskTime = (CFAbsoluteTimeGetCurrent() - diskStart) * 1000
            let diskScoreVal: Int
            let diskLabelVal: String
            if diskTime < 30       { diskScoreVal = 100; diskLabelVal = "고속 SSD" }
            else if diskTime < 80  { diskScoreVal = 75;  diskLabelVal = "SSD" }
            else if diskTime < 200 { diskScoreVal = 40;  diskLabelVal = "HDD" }
            else                   { diskScoreVal = 15;  diskLabelVal = "느림" }

            // --- 종합 점수 (가중 평균) ---
            let total = Int(
                Double(cpuScoreVal) * 0.25 +
                Double(gpuScoreVal) * 0.15 +
                Double(ramScoreVal) * 0.40 +
                Double(diskScoreVal) * 0.20
            )

            // --- 추천 프로필 (종합 점수 기반) ---
            let recommended: String
            if total >= 75      { recommended = "화질 우선" }
            else if total >= 50 { recommended = "균형 (추천)" }
            else                { recommended = "속도 우선" }

            DispatchQueue.main.async {
                self.cpuLabel = cpuLabelVal
                self.gpuLabel = gpuLabelVal
                self.ramLabel = "\(ramGB)GB (\(ramLabelVal))"
                self.diskLabel = diskLabelVal
                self.totalScore = total
                self.recommendedProfile = recommended
                self.isBenchmarking = false
                self.benchmarkDone = true
            }
        }
    }

    // MARK: - Apply Profile
    // 마진 원칙: "쾌적하고 빠르게" 모토 — 모든 프로필에서 폴더 이동 끊김 없게 장수 충분히 확보.
    // 최대 해상도도 3000px 에서 상한 (줌 시에는 loadHiResImage 가 full-res 로 대체).
    //
    // RAM 구간 × 프로필:
    //   8GB   / speed: 300px×80장×1.5GB   balanced: 500px×50장×2GB   quality: 800px×35장×2GB
    //   16GB  / speed: 600px×80장×2GB     balanced: 1000px×60장×3GB  quality: 1600px×40장×3GB
    //   24GB+ / speed: 1200px×80장×3GB    balanced: 1800px×60장×4GB  quality: 3000px×40장×5GB

    private func applyProfile(_ profile: String) {
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))

        // RAM 구간: low(<16), mid(16~23), high(24+)
        enum RamBand { case low, mid, high }
        let band: RamBand = ramGB < 16 ? .low : (ramGB < 24 ? .mid : .high)

        let res: String
        let cache: Double
        let diskGB: Double

        switch (profile, band) {
        // 속도 우선 — 해상도 작게, 장수 많이
        case ("speed", .low):   res = "300";  cache = 80; diskGB = 1.5
        case ("speed", .mid):   res = "600";  cache = 80; diskGB = 2.0
        case ("speed", .high):  res = "1200"; cache = 80; diskGB = 3.0
        // 균형 — 적정 해상도, 적정 장수
        case ("balanced", .low):  res = "500";  cache = 50; diskGB = 2.0
        case ("balanced", .mid):  res = "1000"; cache = 60; diskGB = 3.0
        case ("balanced", .high): res = "1800"; cache = 60; diskGB = 4.0
        // 화질 우선 — 해상도 크게, 장수 약간 적게 (but 30+ 유지)
        case ("quality", .low):   res = "800";  cache = 35; diskGB = 2.0
        case ("quality", .mid):   res = "1600"; cache = 40; diskGB = 3.0
        case ("quality", .high):  res = "3000"; cache = 40; diskGB = 5.0
        default: return
        }

        previewMaxResolution = res
        previewCacheSize = cache
        thumbnailCacheMaxGB = diskGB
        defaultThumbnailSize = 100

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
