//
//  CacheProgressGauge.swift
//  PhotoRawManager
//
//  v8.6.2: 폴더 경로 옆의 원형 진행률 게이지.
//  - 썸네일 캐시 = ThumbnailCache 인입 카운트 (현재 폴더 내 파일만)
//  - 미리보기 캐시 = PhotoPreviewView 가 해당 파일을 로딩 완료한 횟수
//  마우스 호버 1초 후 popover 툴팁으로 상세 표시 (SwiftUI `.help()` 보다 훨씬 빠름).
//

import SwiftUI

extension Notification.Name {
    static let thumbnailCacheInserted = Notification.Name("PickShot.ThumbnailCacheInserted")
}

struct CacheProgressGauge: View {
    @ObservedObject var store: PhotoStore

    @State private var hovering: Bool = false
    @State private var showTooltip: Bool = false
    @State private var hoverWorkItem: DispatchWorkItem?
    @State private var refreshTick: Int = 0

    /// 현재 폴더의 유효 이미지 총 개수 (폴더/상위폴더 제외).
    private var total: Int {
        store.photos.reduce(0) { $0 + (($1.isFolder || $1.isParentFolder) ? 0 : 1) }
    }

    private var thumbRatio: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(store.thumbCacheCount) / Double(total))
    }
    private var previewRatio: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(store.previewsLoaded) / Double(total))
    }
    // v8.9.4: 미리보기 캐시 비활성화 → combinedRatio = 썸네일만
    private var combinedRatio: Double { thumbRatio }
    private var isComplete: Bool {
        total > 0 && store.thumbCacheCount >= total
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: combinedRatio)
                .stroke(
                    isComplete
                        ? AnyShapeStyle(Color.green)
                        : AnyShapeStyle(LinearGradient(
                            colors: [Color.blue, Color.cyan],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: combinedRatio)
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.green)
            } else if total > 0 {
                Text("\(Int(combinedRatio * 100))")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            hoverWorkItem?.cancel()
            if inside {
                let work = DispatchWorkItem { [self] in
                    if hovering { showTooltip = true }
                }
                hoverWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
            } else {
                showTooltip = false
            }
        }
        .popover(isPresented: $showTooltip, arrowEdge: .bottom) {
            tooltipContent
                .padding(10)
                .onDisappear { showTooltip = false }
        }
        // v8.6.2: Timer 는 tooltip 표시 중에만 작동 (main queue 부담 최소화)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            // tooltip 이 보일 때만 업데이트. 평상시엔 no-op.
            if showTooltip && !isComplete { refreshTick += 1 }
        }
    }

    private var tooltipContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if total == 0 {
                Text("폴더에 이미지가 없습니다")
                    .font(.system(size: 11))
            } else {
                row(
                    label: "썸네일 캐시",
                    count: store.thumbCacheCount, total: total,
                    elapsed: store.cacheProgressElapsed,
                    complete: thumbRatio >= 1
                )
                // v8.9.4: 미리보기 캐시 비활성화 (PreviewImageCache.maxBytes=0).
                //          neighbor preload(±5~10) 만으로 충분 → 게이지 행 숨김.
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    @ViewBuilder
    private func row(label: String, count: Int, total: Int, elapsed: TimeInterval, complete: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: complete ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 10))
                .foregroundColor(complete ? .green : .blue)
            Text("\(label): \(count) / \(total)")
                .font(.system(size: 11, weight: .medium))
            if elapsed > 0 {
                Text(complete ? "✓ \(formatElapsed(elapsed))" : "\(formatElapsed(elapsed)) 경과")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatElapsed(_ sec: TimeInterval) -> String {
        if sec < 1 { return "0초" }
        if sec < 60 { return "\(Int(sec))초" }
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return "\(m)분 \(s)초"
    }
}

// MARK: - v8.8.1 적극 캐시 모드 토글 버튼

/// 툴바에 표시되는 "캐시 적극 로딩" 토글 버튼.
/// - OFF (기본): 폴더 진입 후 idle 대기 → 백그라운드 순차 로딩 (시스템 부하 낮음)
/// - ON: 폴더 진입 즉시 병렬 로딩 (CPU/디스크 집중 사용, 캐시 빠르게 생성)
struct AggressiveCacheToggle: View {
    @ObservedObject var store: PhotoStore
    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        Button(action: {
            // v9.0.2: Pro 게이트 — 무료 사용자는 잠금 모달.
            if FeatureGate.allows(.aggressiveCache) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    store.aggressiveCache.toggle()
                }
            } else {
                store.proLockedFeature = .aggressiveCache
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(store.aggressiveCache
                          ? Color.orange.opacity(hovering ? 0.35 : 0.25)
                          : (hovering ? Color.white.opacity(0.08) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(store.aggressiveCache ? Color.orange.opacity(0.6) : Color.white.opacity(0.15),
                                    lineWidth: 1)
                    )
                ZStack {
                    // 베이스: 미리보기/캐시 스택 느낌의 아이콘
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            store.aggressiveCache
                                ? AnyShapeStyle(LinearGradient(colors: [.orange, .yellow],
                                                               startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(Color.white.opacity(0.7))
                        )
                    // ON 상태에선 번개 오버레이 (빠른 로딩 표시)
                    if store.aggressiveCache {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(.yellow)
                            .offset(x: 7, y: -6)
                            .shadow(color: .orange.opacity(0.8), radius: 2)
                            .scaleEffect(pulse ? 1.15 : 1.0)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    }
                }
            }
            .frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
        .onHover { hovering = $0 }
        .help(store.aggressiveCache
              ? "캐시 적극 로딩 ON — 폴더 진입 즉시 병렬 로딩 (시스템 부하 ↑)"
              : "캐시 적극 로딩 OFF — 기본 (백그라운드 천천히)")
    }
}

// MARK: - v8.9.4 Fast Culling Mode 토글

/// 빠른 셀렉 모드 — 무거운 작업 OFF, viewport 우선.
/// FastRawViewer 식의 "현재 화면만" 처리하는 모드.
struct FastCullingToggle: View {
    @ObservedObject var store: PhotoStore
    @State private var hovering = false
    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                store.fastCullingMode.toggle()
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(store.fastCullingMode
                          ? Color.cyan.opacity(hovering ? 0.35 : 0.25)
                          : (hovering ? Color.white.opacity(0.08) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(store.fastCullingMode ? Color.cyan.opacity(0.6) : Color.white.opacity(0.15),
                                    lineWidth: 1)
                    )
                Image(systemName: store.fastCullingMode ? "hare.fill" : "hare")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        store.fastCullingMode
                            ? AnyShapeStyle(LinearGradient(colors: [.cyan, .blue],
                                                           startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Color.white.opacity(0.7))
                    )
            }
            .frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(store.fastCullingMode
              ? "빠른 셀렉 모드 ON — preload ↓, AI/스테이지2 OFF (FastRawViewer식)"
              : "빠른 셀렉 모드 OFF — 기본 (정확 분석/풀 미리보기)")
    }
}

// MARK: - v9.1 통합 성능 프로파일 picker (4개 토글 → 1개) + 라이브 진행 게이지

/// 툴바용 segmented control. 표준 / 빠른 셀렉 / 사전 생성 라디오.
/// 라디오 전환으로 fastCullingMode + aggressiveCache + SuperCullMode + autoInitialPreview 동시 동기화.
/// 활성 프로파일 옆에 라이브 상태 게이지/텍스트 표시.
struct PerformanceProfilePicker: View {
    @ObservedObject var store: PhotoStore
    @ObservedObject private var prewarmGen = InitialPreviewGenerator.shared

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(PhotoStore.PerformanceProfile.allCases) { p in
                    segmentButton(p)
                }
            }
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            // 활성 프로파일 라이브 상태 게이지
            statusView(for: store.performanceProfile)
                .transition(.opacity.combined(with: .move(edge: .leading)))
        }
        .animation(.easeInOut(duration: 0.2), value: store.performanceProfile)
    }

    // MARK: - Segment

    private func segmentButton(_ p: PhotoStore.PerformanceProfile) -> some View {
        let isOn = store.performanceProfile == p
        let tint = tintColor(for: p)
        return Button {
            if p == .prewarm && !FeatureGate.allows(.aggressiveCache) {
                store.proLockedFeature = .aggressiveCache
                return
            }
            // v9.1.1: 즉시 발사/중단 부수효과 제거 — 모드 전환 자체를 가볍게.
            //   사용자가 prewarm 실행은 옆 ▶︎ 버튼으로 명시 트리거.
            store.performanceProfile = p
        } label: {
            HStack(spacing: 4) {
                Image(systemName: p.iconName)
                    .font(.system(size: 11, weight: .semibold))
                Text(p.displayName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundColor(isOn ? .white : Color.white.opacity(0.35))
            .background(isOn ? tint.opacity(0.85) : Color.clear)
            .overlay(
                Rectangle()
                    .frame(width: isOn ? 0 : 1, height: 14)
                    .foregroundColor(Color.white.opacity(0.08)),
                alignment: .trailing
            )
        }
        .buttonStyle(.plain)
        .help(p.helpText)
    }

    private func tintColor(for p: PhotoStore.PerformanceProfile) -> Color {
        switch p {
        case .standard: return Color(red: 0.45, green: 0.55, blue: 0.65)
        case .fastCull: return .cyan
        case .prewarm:  return .orange
        }
    }

    // MARK: - Live status

    @ViewBuilder
    private func statusView(for p: PhotoStore.PerformanceProfile) -> some View {
        let tint = tintColor(for: p)
        switch p {
        case .standard:
            standardStatus(tint: tint)
        case .fastCull:
            fastCullStatus(tint: tint)
        case .prewarm:
            prewarmStatus(tint: tint)
        }
    }

    // 표준: 평소엔 "준비", 백그라운드 분석/프리로드 중이면 진행 표시
    private func standardStatus(tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            if store.isAnalyzing {
                Text("AI 분석 \(Int(store.analyzeProgress * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(tint)
                ProgressView(value: store.analyzeProgress)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(width: 60)
            } else if store.isPreloadingThumbs {
                Text("썸네일 \(store.thumbsLoaded)/\(store.thumbsTotal)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(tint)
                ProgressView(value: progress(store.thumbsLoaded, store.thumbsTotal))
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(width: 60)
            } else {
                Text("표준 — 모든 단계 자동")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(tint.opacity(0.85))
            }
        }
    }

    // 빠른 셀렉: Stage 3 차단/AI OFF/Prefetch ½ 표시
    private func fastCullStatus(tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 9))
                .foregroundColor(tint.opacity(0.9))
            Text("Stage 3 차단 · AI OFF · Prefetch ½")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(tint)
            if store.isPreloadingThumbs {
                ProgressView(value: progress(store.thumbsLoaded, store.thumbsTotal))
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(width: 50)
            }
        }
    }

    // 사전 생성: InitialPreviewGenerator 의 phase/current/total + 취소 버튼
    private func prewarmStatus(tint: Color) -> some View {
        HStack(spacing: 6) {
            if prewarmGen.isRunning {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .scaleEffect(prewarmGen.isRunning ? 1.0 : 0.6)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: prewarmGen.isRunning)
                Text("사전 생성 P\(prewarmGen.phase) · \(prewarmGen.current)/\(prewarmGen.total)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(tint)
                    .monospacedDigit()
                ProgressView(value: progress(prewarmGen.current, prewarmGen.total))
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(width: 80)
                Text("\(Int(progress(prewarmGen.current, prewarmGen.total) * 100))%")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundColor(tint)
                    .monospacedDigit()
                Button { InitialPreviewGenerator.shared.cancel() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(tint.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("사전 생성 중단")
            } else {
                // v9.1.1: store.photos.filter 메인 블로킹 제거 — store.photos.count 만 사용 (folder 항목 포함 가능하나 표시용).
                Circle().fill(tint).frame(width: 6, height: 6)
                let approxTotal = store.photos.count
                if store.isRecursiveMode {
                    Text("재귀 모드 — 사전 생성 비활성")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(tint.opacity(0.7))
                } else if approxTotal > 5000 {
                    Text("\(approxTotal)장 — 5000장 초과 비활성")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(tint.opacity(0.7))
                } else if approxTotal == 0 {
                    Text("사전 생성 대기")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(tint.opacity(0.7))
                } else {
                    Text("사전 생성 준비 (\(approxTotal)장)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(tint)
                    Button {
                        // 백그라운드에서 URL 수집 → 메인큐 블로킹 회피
                        DispatchQueue.global(qos: .userInitiated).async { [weak store] in
                            guard let store = store else { return }
                            let snapshot = DispatchQueue.main.sync { store.photos }
                            let urls = snapshot.compactMap { p -> URL? in
                                (p.isFolder || p.isParentFolder) ? nil : p.jpgURL
                            }
                            guard urls.count > 0, urls.count <= 5000 else { return }
                            DispatchQueue.main.async {
                                InitialPreviewGenerator.shared.start(urls: urls)
                            }
                        }
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(tint)
                    }
                    .buttonStyle(.plain)
                    .help("사전 생성 시작")
                }
            }
        }
    }

    private func progress(_ done: Int, _ total: Int) -> Double {
        total > 0 ? min(1.0, Double(done) / Double(total)) : 0
    }
}
