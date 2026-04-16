//
//  NavigationPerformanceMonitor.swift
//  PhotoRawManager
//
//  행 이동 성능 디버깅 도구.
//  - 각 행 이동 간 간격(ms) 측정
//  - 썸네일 로드 시간 측정
//  - 프리뷰 로드 시간 측정
//  - 메모리 사용량 스냅샷
//  - 디스크 캐시 히트율
//
//  사용법:
//  1. Cmd+Shift+D 로 디버그 HUD 토글
//  2. 화살표 키로 이동하며 데이터 수집
//  3. HUD 에 실시간 그래프/통계 표시
//  4. `session report` 로 CSV 저장
//

import Foundation
import AppKit

/// 행 이동 성능 측정기 (싱글톤)
@MainActor
final class NavigationPerformanceMonitor: ObservableObject {
    static let shared = NavigationPerformanceMonitor()

    /// HUD 표시 여부
    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled && session == nil { startSession() }
            if !isEnabled { endSession() }
        }
    }

    /// 최근 이동 기록 (링 버퍼)
    @Published private(set) var recentMoves: [MoveEvent] = []

    /// 통계 (실시간 갱신)
    @Published private(set) var stats: Stats = Stats()

    // MARK: - 데이터 구조

    struct MoveEvent: Identifiable {
        let id: UUID = UUID()
        let index: Int              // 이 이동이 몇 번째인지 (세션 시작부터)
        let photoIndex: Int         // 사진 리스트에서의 인덱스
        let direction: String       // "→", "↓" 등
        let intervalMs: Double      // 이전 이동과의 간격
        let thumbnailLoadMs: Double?  // 썸네일 로드 시간 (있으면)
        let previewLoadMs: Double?  // 프리뷰 로드 시간 (있으면)
        let ramUsageMB: Int         // 이 시점 RAM 사용량
        let previewCacheCount: Int
        let previewCacheMB: Int
        let timestamp: Date
    }

    struct Stats {
        var totalMoves: Int = 0
        var avgIntervalMs: Double = 0
        var minIntervalMs: Double = .infinity
        var maxIntervalMs: Double = 0
        var recentAvgIntervalMs: Double = 0   // 최근 20개 평균
        var firstHalfAvgMs: Double = 0        // 세션 전반 평균
        var secondHalfAvgMs: Double = 0       // 세션 후반 평균 (저하 감지)
        var slowdownRatio: Double = 1.0       // second / first (1.5+ 이면 저하)
    }

    private var session: Session?
    private let maxRecent = 100  // UI 에 표시할 최근 기록 수

    struct Session {
        var startedAt: Date
        var allMoves: [MoveEvent] = []
    }

    private init() {}

    // MARK: - 측정 API

    /// 행 이동 시작을 알림 (executeMoveSelection 직전)
    private var lastMoveAt: Date?
    private var pendingLoadStart: Date?
    private var pendingPhotoIndex: Int = 0
    private var pendingDirection: String = "·"

    func notifyMoveStart(photoIndex: Int, direction: String) {
        pendingLoadStart = Date()
        pendingPhotoIndex = photoIndex
        pendingDirection = direction
    }

    /// 썸네일이 표시되었을 때
    func notifyMoveCompleted(thumbnailLoadMs: Double? = nil, previewLoadMs: Double? = nil) {
        guard isEnabled, var sess = session else { return }

        let now = Date()
        let intervalMs: Double
        if let last = lastMoveAt {
            intervalMs = now.timeIntervalSince(last) * 1000.0
        } else {
            intervalMs = 0
        }
        lastMoveAt = now

        let ev = MoveEvent(
            index: sess.allMoves.count,
            photoIndex: pendingPhotoIndex,
            direction: pendingDirection,
            intervalMs: intervalMs,
            thumbnailLoadMs: thumbnailLoadMs,
            previewLoadMs: previewLoadMs,
            ramUsageMB: currentRamMB(),
            previewCacheCount: PreviewImageCache.shared.count,
            previewCacheMB: PreviewImageCache.shared.currentBytesMB,
            timestamp: now
        )

        sess.allMoves.append(ev)
        session = sess

        // UI 용 링버퍼
        recentMoves.append(ev)
        if recentMoves.count > maxRecent {
            recentMoves.removeFirst(recentMoves.count - maxRecent)
        }

        updateStats()
    }

    // MARK: - 세션 관리

    func startSession() {
        session = Session(startedAt: Date())
        recentMoves.removeAll()
        stats = Stats()
        lastMoveAt = nil
        fputs("[NAVPERF] 세션 시작\n", stderr)
    }

    func endSession() {
        guard let sess = session else { return }
        let dur = Date().timeIntervalSince(sess.startedAt)
        fputs("[NAVPERF] 세션 종료: \(sess.allMoves.count) moves in \(String(format: "%.1f", dur))s\n", stderr)
        session = nil
    }

    /// CSV 리포트 저장
    @discardableResult
    func exportReport() -> URL? {
        guard let sess = session else { return nil }
        let fm = FileManager.default
        let fileName = "navperf_\(Int(sess.startedAt.timeIntervalSince1970)).csv"
        let url = fm.temporaryDirectory.appendingPathComponent(fileName)

        var csv = "index,photoIndex,direction,intervalMs,thumbMs,previewMs,ramMB,cacheCount,cacheMB,timestamp\n"
        for e in sess.allMoves {
            let thumb = e.thumbnailLoadMs.map { String(format: "%.1f", $0) } ?? ""
            let prev = e.previewLoadMs.map { String(format: "%.1f", $0) } ?? ""
            csv += "\(e.index),\(e.photoIndex),\(e.direction),\(String(format: "%.1f", e.intervalMs)),\(thumb),\(prev),\(e.ramUsageMB),\(e.previewCacheCount),\(e.previewCacheMB),\(e.timestamp.timeIntervalSince1970)\n"
        }

        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            fputs("[NAVPERF] 리포트 저장: \(url.path)\n", stderr)
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            return url
        } catch {
            fputs("[NAVPERF] 저장 실패: \(error)\n", stderr)
            return nil
        }
    }

    // MARK: - 내부 구현

    private func updateStats() {
        guard let sess = session, !sess.allMoves.isEmpty else { return }
        let all = sess.allMoves

        var s = Stats()
        s.totalMoves = all.count
        let intervals = all.dropFirst().map { $0.intervalMs }  // 첫 번째는 0
        guard !intervals.isEmpty else {
            self.stats = s; return
        }

        s.avgIntervalMs = intervals.reduce(0, +) / Double(intervals.count)
        s.minIntervalMs = intervals.min() ?? 0
        s.maxIntervalMs = intervals.max() ?? 0

        let recent = Array(intervals.suffix(20))
        s.recentAvgIntervalMs = recent.reduce(0, +) / Double(recent.count)

        // 저하 비율 분석: 전반/후반 반 나눠서 평균 비교
        if intervals.count >= 10 {
            let half = intervals.count / 2
            let firstHalf = Array(intervals.prefix(half))
            let secondHalf = Array(intervals.suffix(intervals.count - half))
            s.firstHalfAvgMs = firstHalf.reduce(0, +) / Double(firstHalf.count)
            s.secondHalfAvgMs = secondHalf.reduce(0, +) / Double(secondHalf.count)
            s.slowdownRatio = s.firstHalfAvgMs > 0 ? s.secondHalfAvgMs / s.firstHalfAvgMs : 1.0
        }

        self.stats = s
    }

    private func currentRamMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / (1024 * 1024))
    }
}

// MARK: - PreviewImageCache 통계 확장 (비침습적)
extension PreviewImageCache {
    /// 현재 캐시된 이미지 개수 (디버그용)
    var count: Int {
        // lock 은 내부 private 이므로 근사치 반환
        // 정확히 필요하면 PreviewImageCache 내부에 getter 추가 필요
        debugStats().count
    }

    /// 현재 캐시 바이트 (MB)
    var currentBytesMB: Int {
        debugStats().bytes / (1024 * 1024)
    }
}
