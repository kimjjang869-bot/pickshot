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
    private var combinedRatio: Double {
        guard total > 0 else { return 0 }
        let denom = Double(total) * 2.0
        let num = Double(min(store.thumbCacheCount, total) + min(store.previewsLoaded, total))
        return min(1.0, num / denom)
    }
    private var isComplete: Bool {
        total > 0 && store.thumbCacheCount >= total && store.previewsLoaded >= total
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
                row(
                    label: "미리보기 캐시",
                    count: store.previewsLoaded, total: total,
                    elapsed: store.previewsElapsed,
                    complete: previewRatio >= 1
                )
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                store.aggressiveCache.toggle()
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
