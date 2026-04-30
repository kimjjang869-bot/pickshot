import SwiftUI

// MARK: - App Design System (macOS Ventura/Sonoma inspired)

enum AppTheme {
    // MARK: - Spacing System (4pt grid)
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24

    // MARK: - Primary Colors
    static let accent = Color(red: 10/255, green: 132/255, blue: 255/255)       // #0A84FF macOS system blue
    static let success = Color(red: 48/255, green: 209/255, blue: 88/255)       // #30D158 green
    static let warning = Color(red: 255/255, green: 159/255, blue: 10/255)      // #FF9F0A orange
    static let error = Color(red: 255/255, green: 69/255, blue: 58/255)         // #FF453A red

    // MARK: - Muted Accent Colors
    static let mutedBlue = Color(red: 10/255, green: 132/255, blue: 255/255).opacity(0.12)
    static let mutedGreen = Color(red: 48/255, green: 209/255, blue: 88/255).opacity(0.12)
    static let mutedOrange = Color(red: 255/255, green: 159/255, blue: 10/255).opacity(0.12)
    static let mutedRed = Color(red: 255/255, green: 69/255, blue: 58/255).opacity(0.12)
    static let mutedPurple = Color(red: 175/255, green: 82/255, blue: 222/255).opacity(0.12)

    // MARK: - Badge Colors
    static let rawBadge = success
    static let spBadge = error
    static let pickBadge = Color(red: 175/255, green: 82/255, blue: 222/255)    // purple
    static let correctedBadge = Color.teal
    static let sceneBadge = Color.cyan

    // MARK: - Quality Grade Colors
    static func gradeColor(_ grade: QualityAnalysis.Grade) -> Color {
        switch grade {
        case .excellent: return success
        case .good: return accent
        case .average: return Color.yellow
        case .belowAverage: return warning
        case .poor: return error
        }
    }

    // MARK: - Star Color
    static let starGold = Color(red: 255/255, green: 184/255, blue: 0/255)     // #FFB800 (별 아이콘용)
    /// v8.7: ★5 썸네일 테두리 전용 — 노란 컬러 라벨과 명확히 구분되도록 오렌지 계열
    static let ratingFiveBorder = Color(red: 255/255, green: 110/255, blue: 0/255)  // #FF6E00 (vivid orange)

    // MARK: - Text Colors
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textDim = Color.secondary.opacity(0.5)
    static let textMuted = Color.white.opacity(0.7)

    // MARK: - Thumbnail Grid
    static let selectionBorder = Color(red: 50/255, green: 140/255, blue: 255/255)  // vivid blue
    static let focusBorder = Color(red: 80/255, green: 180/255, blue: 255/255)  // bright cyan-blue
    static let spPickBorder = error
    static let cellCornerRadius: CGFloat = 6
    static let cellBorderWidth: CGFloat = 3
    static let focusBorderWidth: CGFloat = 3

    // MARK: - Star Rating
    static let starFilled = starGold
    static let starEmpty = Color.gray.opacity(0.25)

    // MARK: - Toolbar
    static let toolbarDivider = Color.gray.opacity(0.15)
    static let toolbarButtonBg = Color.gray.opacity(0.08)
    static let toolbarButtonActiveBg = accent
    static let toolbarDividerHeight: CGFloat = 16

    // MARK: - Selection & Hover
    static let selectionBg = accent.opacity(0.15)
    static let hoverBg = Color.gray.opacity(0.08)

    // MARK: - Corner Radius System
    static let radiusSmall: CGFloat = 4     // 배지, 태그
    static let radiusMedium: CGFloat = 6    // 버튼, 입력 필드
    static let radiusLarge: CGFloat = 10    // 카드, 큰 영역

    // MARK: - Grid
    static let gridSpacing: CGFloat = 12

    // MARK: - Sidebar
    static let sidebarCollapsed: CGFloat = 36
    static let sidebarExpanded: CGFloat = 250

    // MARK: - UI 스케일 팩터
    //   v8.8.2: 사용자 설정 (UserDefaults "uiScale", 기본 1.0) 우선.
    //   자동 모드 (uiScale=0) 는 해상도 기반이지만 cap 을 1.0 으로 낮춤 — 5K 환경에서 너무 커지지 않도록.
    static let displayScale: CGFloat = {
        let userScale = UserDefaults.standard.double(forKey: "uiScale")
        if userScale > 0 {
            return max(0.7, min(1.5, CGFloat(userScale)))
        }
        // 자동 — 3200px 기준 비례, 범위 [0.85, 1.0]
        let screenW = NSScreen.main?.frame.width ?? 2560
        return max(0.85, min(1.0, screenW / 3200.0))
    }()

    /// 해상도별 자동 조정값
    static func scaled(_ base: CGFloat) -> CGFloat {
        return round(base * displayScale)
    }

    // MARK: - 모든 값 앱 시작 시 1회 계산 (모니터 변경/포커스 변경 시 안 바뀜)
    // v8.7: base 값 상향 — 5K 환경 가독성 개선
    static let buttonHeight: CGFloat = scaled(30)   // v8.9.7+: 38 → 30 (높이 축소)
    static let pillSize: CGFloat = scaled(32)       // 30 → 32

    static let iconSmall: CGFloat = scaled(15)      // 13 → 15
    static let iconMedium: CGFloat = scaled(17)     // 15 → 17
    static let iconLarge: CGFloat = scaled(20)      // 18 → 20

    static let fontMicro: CGFloat = scaled(12)      // 11 → 12
    static let fontCaption: CGFloat = scaled(13)    // 12 → 13
    static let fontBody: CGFloat = scaled(14)       // 13 → 14
    static let fontSubhead: CGFloat = scaled(15)    // 14 → 15
    static let fontHeading: CGFloat = scaled(16)    // 15 → 16

    // MARK: - Min Touch Target
    static let minTouchTarget: CGFloat = 24
}

// MARK: - v8.9.7+ Delayed Tooltip (1초)

/// 마우스 오버 후 1초 delay 시 표시되는 커스텀 툴팁. 시스템 .help() (~1.5-2s) 보다 빠르고 일관됨.
struct DelayedTooltipModifier: ViewModifier {
    let text: String
    let delay: TimeInterval

    @State private var isHovering: Bool = false
    @State private var isShowing: Bool = false
    @State private var hoverGeneration: Int = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isShowing && !text.isEmpty {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                        .shadow(radius: 3)
                        .offset(y: 28)
                        .fixedSize()
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(1000)
                }
            }
            .onHover { hovering in
                isHovering = hovering
                hoverGeneration += 1
                let gen = hoverGeneration
                if hovering {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if isHovering && gen == hoverGeneration {
                            withAnimation(.easeIn(duration: 0.1)) {
                                isShowing = true
                            }
                        }
                    }
                } else {
                    isShowing = false
                }
            }
    }
}

extension View {
    /// 1초 hover delay 후 표시되는 커스텀 툴팁. (v8.9.7+)
    /// 사용: `.tooltip("도움말")`. 기존 `.help()` 대체 가능.
    func tooltip(_ text: String, delay: TimeInterval = 1.0) -> some View {
        modifier(DelayedTooltipModifier(text: text, delay: delay))
    }
}

// MARK: - v8.9.7+ 초기 미리보기 사전 생성 (Lightroom 식)

import ImageIO

/// 폴더 진입 시 모든 사진의 미리보기를 3단계로 background 사전 생성 → 모든 stage cache 채움.
/// 라이트룸 의 "초기 미리보기 가져오는 중" 과 동일 패턴. 모든 사진이 즉시 Stage 3 까지 표시 가능.
///
/// v8.9.7+ 3-Phase 구조:
///   Phase 1: 900px embedded — 모든 사진 빠르게 (썸네일/burst nav 용)
///   Phase 2: 1800px embedded — 중간 화질 (Stage 2 fit-screen 용)
///   Phase 3: full RAW demosaic — 풀사이즈 hi-res (Stage 3 zoom/100% 표시)
final class InitialPreviewGenerator: ObservableObject {
    static let shared = InitialPreviewGenerator()

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var current: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var phase: Int = 0  // 0=idle, 1=900px, 2=1800px, 3=full RAW
    private var allURLs: [URL] = []

    // v9.0.2: QoS .utility 로 강등 — .userInitiated 는 main 과 동등 우선순위 경쟁으로 응답없음 유발.
    //   concurrency 1 + .utility + op 사이 5ms yield → main runloop 블록 방지.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "preview.initial-generator"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    /// op 사이 main 에 양보할 시간 (ms). Phase 별 부하에 따라 조정.
    private static let yieldMs: [Int: UInt32] = [1: 3, 2: 8, 3: 12]

    func cancel() {
        queue.cancelAllOperations()
        allURLs = []
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
            self?.current = 0
            self?.total = 0
            self?.phase = 0
        }
    }

    /// 사용자 토글이 켜졌고 폴더가 너무 크지 않으면 호출.
    /// Phase 1 (900px) → Phase 2 (1800px) → Phase 3 (full RAW hi-res).
    /// 각 Phase 는 모든 사진에 대해 순차 처리 후 다음 Phase 로 진행 (Lightroom 식).
    func start(urls: [URL]) {
        cancel()
        guard !urls.isEmpty else { return }

        // 이미 disk cache 에 큰 미리보기가 있는 url 은 Phase 1 SKIP (≥800px 면 OK).
        var alreadyCached = 0
        let phase1Targets = urls.filter { url in
            if let existing = DiskThumbnailCache.shared.getByPath(url: url),
               max(Int(existing.size.width), Int(existing.size.height)) >= 800 {
                ThumbnailCache.shared.set(url, image: existing)
                alreadyCached += 1
                return false
            }
            return true
        }
        // Phase 2/3 후보 = 모든 url (각 Phase 시점에 또 체크)
        allURLs = urls
        fputs("[INITIAL-PREVIEW] start total=\(urls.count) phase1=\(phase1Targets.count) cached=\(alreadyCached)\n", stderr)

        if phase1Targets.isEmpty {
            // Phase 1 이미 완료 상태 → Phase 2 바로 시작
            startPhase2()
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.total = phase1Targets.count
            self?.current = 0
            self?.isRunning = true
            self?.phase = 1
        }
        enqueueOps(urls: phase1Targets, maxPixel: 900)
    }

    private func startPhase2() {
        // v8.9.7+: Phase 2 = embedded camera preview 1800px (RAW demosaic 금지) → 카메라 색감 일관 유지.
        //   embedded preview 만 사용해 Phase 1 색감과 동일.
        let phase2Targets = allURLs.filter { url in
            if let existing = DiskThumbnailCache.shared.getByPath(url: url),
               max(Int(existing.size.width), Int(existing.size.height)) >= 1500 {
                return false
            }
            return true
        }
        if phase2Targets.isEmpty {
            fputs("[INITIAL-PREVIEW] phase2 skip (all cached) → phase3\n", stderr)
            startPhase3()
            return
        }
        fputs("[INITIAL-PREVIEW] phase2 start \(phase2Targets.count) photos (embedded 1800px)\n", stderr)
        DispatchQueue.main.async { [weak self] in
            self?.total = phase2Targets.count
            self?.current = 0
            self?.phase = 2
            self?.isRunning = true
        }
        // allowRawDecode=false → embedded 만. maxPixel 1800 = 일반 ARW embedded 한계.
        enqueueOps(urls: phase2Targets, maxPixel: 1800, allowRawDecode: false)
    }

    private func startPhase3() {
        // v8.9.7+: Phase 3 = deep embedded JPEG (4096px 까지) — 카메라 색감 일관 유지.
        //   풀 RAW demosaic 안 함 (색감 변경 방지). RAW 안에 더 큰 embedded JPEG 있으면 추출,
        //   없으면 Phase 2 결과 그대로 (Sony ARW 1616 카메라 등). Canon CR3/Nikon NEF 는 4000+px 추출 가능.
        let phase3Targets = allURLs.filter { url in
            if let existing = DiskThumbnailCache.shared.getByPath(url: url),
               max(Int(existing.size.width), Int(existing.size.height)) >= 3000 {
                return false
            }
            return true
        }
        if phase3Targets.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
                self?.phase = 0
                self?.current = 0
                self?.total = 0
            }
            allURLs = []
            fputs("[INITIAL-PREVIEW] phase3 skip (all cached) — all done\n", stderr)
            return
        }
        fputs("[INITIAL-PREVIEW] phase3 start \(phase3Targets.count) photos (deep embedded 4096px)\n", stderr)
        DispatchQueue.main.async { [weak self] in
            self?.total = phase3Targets.count
            self?.current = 0
            self?.phase = 3
            self?.isRunning = true
        }
        // allowRawDecode=false → embedded JPEG 만 (색감 일관). maxPixel 4096 → 카메라가 가진
        //   가장 큰 embedded JPEG 추출 (Sony ARW 보통 1616, Canon CR3/Nikon NEF 4000+).
        enqueueOps(urls: phase3Targets, maxPixel: 4096, allowRawDecode: false)
    }

    private func enqueueOps(urls: [URL], maxPixel: Int, allowRawDecode: Bool = false) {
        // v9.0.2: 큐 크기 cap — 한 번에 너무 많은 op 적재되면 OperationQueue 내부 자료구조
        //   메모리 무거워짐 + cancel 시 검사 비용 ↑. 100 단위로 나누지 않고 그냥 cap 만 둠.
        let maxQueueLength = 200
        for url in urls {
            // 큐가 너무 길면 짧게 대기 — 시스템 부하 방지.
            while queue.operationCount > maxQueueLength {
                Thread.sleep(forTimeInterval: 0.05)
                if queue.isSuspended || PhotoStore.navigationBusy { break }
            }
            queue.addOperation { [weak self] in
                guard let self else { return }
                // v9.0.2: 네비 burst 동안엔 디스크/CPU 양보 — STALL/Stage3 지연 원인이었음.
                //   busy 가 풀릴 때까지 짧게 대기 (최대 1초). 그래도 busy 면 다음 op 로 미룸.
                var waited = 0
                while PhotoStore.navigationBusy && waited < 20 {
                    usleep(50_000) // 50ms
                    waited += 1
                }

                autoreleasepool {
                    let existing = DiskThumbnailCache.shared.getByPath(url: url) ?? ThumbnailCache.shared.get(url)
                    let existingMax = existing.map { max(Int($0.size.width), Int($0.size.height)) } ?? 0
                    let threshold: Int = allowRawDecode ? 3000 : 800
                    if existingMax >= threshold {
                        DispatchQueue.main.async { [weak self] in self?.advance() }
                        return
                    }
                    // Phase 2 (allowRawDecode): FromImageAlways=true → embedded 무시하고 전체 RAW
                    //   demosaic 디코드 (RawCamera/LibRaw) → 4000-6000px 진짜 풀사이즈 생성.
                    //   Phase 1 (allowRawDecode=false): embedded 만 사용 (빠름, 작아도 OK).
                    var thumbOpts: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCache: false
                    ]
                    if allowRawDecode {
                        thumbOpts[kCGImageSourceCreateThumbnailFromImageAlways] = true
                    } else {
                        thumbOpts[kCGImageSourceCreateThumbnailFromImageIfAbsent] = false
                    }
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                              kCGImageSourceShouldCache: false,
                              kCGImageSourceShouldCacheImmediately: false
                          ] as CFDictionary),
                          let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary)
                    else {
                        DispatchQueue.main.async { [weak self] in self?.advance() }
                        return
                    }
                    let img = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
                    ThumbnailCache.shared.set(url, image: img)
                    // v9.0.2: 디스크 쓰기는 별도 백그라운드 큐로 분리 — 메인 nav 와 디스크 contention 회피.
                    let modDate = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
                    DispatchQueue.global(qos: .background).async {
                        DiskThumbnailCache.shared.set(url: url, modDate: modDate, image: img)
                    }
                }
                // v9.0.2: op 사이 main 에 양보 — phase 별 부하 비례.
                let yieldUs = UInt32(Self.yieldMs[self.phase] ?? 5) * 1000
                usleep(yieldUs)
                DispatchQueue.main.async { [weak self] in self?.advance() }
            }
        }
    }

    private func advance() {
        current += 1
        if current >= total {
            let completedPhase = phase
            fputs("[INITIAL-PREVIEW] phase\(completedPhase) complete \(total) photos\n", stderr)
            if completedPhase == 1 {
                // Phase 1 끝 → Phase 2 시작
                DispatchQueue.main.async { [weak self] in
                    self?.startPhase2()
                }
            } else if completedPhase == 2 {
                // Phase 2 끝 → Phase 3 시작 (풀 hi-res)
                DispatchQueue.main.async { [weak self] in
                    self?.startPhase3()
                }
            } else {
                // Phase 3 끝 → 전체 완료
                isRunning = false
                phase = 0
                allURLs = []
            }
        }
    }
}

// MARK: - Initial Preview Toggle Button (v8.9.7+)

/// 초기 미리보기 사전 생성 토글 + 진행률 표시. 정렬 메뉴 옆에 배치.
struct InitialPreviewToggle: View {
    @AppStorage("autoInitialPreview") private var autoInitialPreview: Bool = false
    @ObservedObject private var generator = InitialPreviewGenerator.shared
    @EnvironmentObject var store: PhotoStore
    @State private var hovering = false

    private var isOn: Bool { autoInitialPreview }

    var body: some View {
        Button {
            if generator.isRunning {
                generator.cancel()
            } else {
                autoInitialPreview.toggle()
                if autoInitialPreview {
                    // v8.9.7+: 재귀 모드 또는 10000장 초과 폴더에서 사전 생성 차단 — 디스크 saturate +
                    //   main page fault 로 5초+ STALL 유발. 토글 ON 만 저장하고 다음 작은 폴더 진입 시 자동 발사.
                    let isRecursive = store.isRecursiveMode
                    let total = store.photos.count
                    if isRecursive {
                        fputs("[INITIAL-PREVIEW] BLOCKED (recursive mode, \(total) photos) — 단일 폴더에서 재시도\n", stderr)
                    } else if total > 10000 {
                        fputs("[INITIAL-PREVIEW] BLOCKED (\(total)장 > 10000)\n", stderr)
                    } else {
                        let urls = store.photos.compactMap { p -> URL? in
                            (p.isFolder || p.isParentFolder) ? nil : p.jpgURL
                        }
                        if !urls.isEmpty {
                            InitialPreviewGenerator.shared.start(urls: urls)
                        }
                    }
                }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn
                          ? Color.green.opacity(hovering ? 0.35 : 0.25)
                          : (hovering ? Color.white.opacity(0.08) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isOn ? Color.green.opacity(0.6) : Color.white.opacity(0.15), lineWidth: 1)
                    )
                if generator.isRunning {
                    HStack(spacing: 3) {
                        ZStack {
                            Circle()
                                .stroke(Color.green.opacity(0.25), lineWidth: 2)
                                .frame(width: 12, height: 12)
                            Circle()
                                .trim(from: 0, to: CGFloat(generator.current) / CGFloat(max(1, generator.total)))
                                .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .frame(width: 12, height: 12)
                                .rotationEffect(.degrees(-90))
                        }
                        Text("P\(generator.phase) \(Int(Double(generator.current) / Double(max(1, generator.total)) * 100))%")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundColor(.green)
                            .monospacedDigit()
                    }
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: isOn ? "photo.stack.fill" : "photo.stack")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(
                                isOn
                                    ? AnyShapeStyle(LinearGradient(colors: [.green, Color(red: 0.1, green: 0.55, blue: 0.2)],
                                                                    startPoint: .top, endPoint: .bottom))
                                    : AnyShapeStyle(Color.white.opacity(0.7))
                            )
                        Text(isOn ? "ON" : "OFF")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundColor(isOn ? .green : .white.opacity(0.6))
                            .monospacedDigit()
                    }
                }
            }
            .frame(width: 50, height: 22)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tooltip(generator.isRunning
                 ? "Phase \(generator.phase) (\(generator.phase == 1 ? "900px burst용" : "풀사이즈 hi-res")) — \(generator.current)/\(generator.total) · 클릭하여 취소"
                 : (isOn ? "초기 미리보기 ON — Phase1 (900) + Phase2 (풀사이즈). 클릭하여 OFF" : "초기 미리보기 OFF — 클릭하여 ON + 즉시 시작"))
    }
}
