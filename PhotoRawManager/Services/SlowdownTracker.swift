//
//  SlowdownTracker.swift
//  PickShot v9.0.2 — 시간 경과 슬로우다운 진단 도구.
//
//  사용:
//    SlowdownTracker.shared.dumpSnapshot()
//
//  Settings → 성능 최적화 탭 또는 Cmd+Shift+P 단축키로 호출.
//

import Foundation
import AppKit

@MainActor
final class SlowdownTracker {
    static let shared = SlowdownTracker()

    private init() {}

    /// 전체 진단 dump — stderr + 옵션으로 텍스트 반환.
    @discardableResult
    func dumpSnapshot() -> String {
        let lines = collectMetrics()
        let text = lines.joined(separator: "\n")
        plog("\n[SLOWDOWN-DIAG] ────────────────────────\n")
        plog(text + "\n")
        plog("[SLOWDOWN-DIAG] ────────────────────────\n\n")
        return text
    }

    private func collectMetrics() -> [String] {
        var L: [String] = []
        L.append("📊 PickShot 슬로우다운 진단")
        L.append("시각: \(formattedNow())")
        L.append("")

        // ── 메모리 ──
        L.append("[MEMORY]")
        let memMB = MemoryGuardService.shared.debugSnapshot()
        L.append("  현재 RSS: \(memMB.currentMB) MB")
        L.append("  Soft target: \(memMB.softMB) MB / Warning: \(memMB.warnMB) MB / Emerg: \(memMB.emergMB) MB")
        L.append("  활성 layer: \(memMB.layer)")
        L.append("")

        // ── NotificationCenter observer 누수 추적 ──
        L.append("[OBSERVERS]")
        L.append("  비공식 API 라 정확한 count 안 보이지만, AVPlayer notification 누적 의심 시")
        L.append("  cleanup() 후 재로드해서 비교 가능.")
        L.append("")

        // ── ThumbnailCache ──
        let tc = ThumbnailCache.shared.debugCountAndLimit()
        L.append("[THUMBNAIL CACHE]")
        L.append("  count limit: \(tc.count) / cost limit: \(tc.limitMB) MB")
        L.append("")

        // ── DispatchWorkItem / queue depths ──
        L.append("[BACKGROUND QUEUES]")
        let loaderOps = ThumbnailLoader.shared.queue.operationCount
        L.append("  ThumbnailLoader ops: \(loaderOps)")
        L.append("")

        // ── 활성 폴더 ──
        L.append("[STATE]")
        if let store = SlowdownTracker.weakStore {
            let s = store
            L.append("  사진 수: \(s.photos.count) / 필터드: \(s.filteredPhotos.count)")
            L.append("  현재 폴더: \(s.folderURL?.lastPathComponent ?? "nil")")
            L.append("  체험: \(SubscriptionManager.shared.trialDaysRemaining)일 / 티어: \(SubscriptionManager.shared.currentTier.rawValue)")
        }
        L.append("")

        // ── 권장 액션 ──
        L.append("[ACTIONS]")
        L.append("  - MemGuard.flushAll() : 모든 캐시 즉시 해제")
        L.append("  - VideoPlayerManager.cleanup() : observer 누수 정리")
        L.append("  - ThumbnailCache.removeAll() : 썸네일 캐시 비우기")

        return L
    }

    private func formattedNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// PhotoStore 참조 — ContentView 시작 시 set.
    static weak var weakStore: PhotoStore?
}
