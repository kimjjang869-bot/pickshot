//
//  NavigationPerformanceMonitor.swift
//  PhotoRawManager
//
//  행 이동 성능 디버깅 — 키 꾹 누르기(key repeat burst) 최적화된 계측.
//
//  측정 지표:
//  1. 이동 간격 (interval): 이전 이동 시작 ~ 현재 이동 시작
//  2. Main thread 처리 시간 (processingMs): executeMoveSelection 동기 구간
//  3. Burst fps: key repeat 꾹 누르기 구간의 실제 이동 속도
//  4. Burst slowdown: burst 초반 vs 후반 처리 시간 비교
//  5. RAM / PreviewCache / Memory pressure
//
//  사용법:
//  - Cmd+Shift+D 로 HUD 토글
//  - 화살표 키를 꾹 누르면 burst 가 시작됨 (간격 < 100ms)
//  - 릴리즈 후 100ms 지나면 burst 종료 + 최종 통계
//

import Foundation
import AppKit

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

    /// 최근 이동 기록 (링 버퍼, 최근 120개)
    @Published private(set) var recentMoves: [MoveEvent] = []

    /// 현재 활성 burst (꾹 누르기 중) — nil 이면 대기 상태
    @Published private(set) var activeBurst: BurstInfo?

    /// 마지막 완료된 burst (통계 조회용)
    @Published private(set) var lastBurst: BurstInfo?

    /// 전체 통계 (세션)
    @Published private(set) var stats: Stats = Stats()

    // MARK: - 데이터 구조

    struct MoveEvent: Identifiable {
        let id: UUID = UUID()
        let index: Int              // 세션 내 순번
        let photoIndex: Int         // 사진 리스트 인덱스
        let direction: String       // "→", "↓" 등
        let intervalMs: Double      // 이전 이동 시작과의 간격
        let processingMs: Double    // main thread 동기 처리 시간
        let isRepeat: Bool          // key repeat 여부 (interval < 100ms)
        let ramUsageMB: Int
        let previewCacheCount: Int
        let previewCacheMB: Int
        let timestamp: Date
    }

    struct BurstInfo: Identifiable {
        let id: UUID = UUID()
        var startedAt: Date
        var endedAt: Date? = nil
        var moves: [MoveEvent] = []
        var movesCount: Int { moves.count }
        var durationMs: Double {
            let end = endedAt ?? Date()
            return end.timeIntervalSince(startedAt) * 1000.0
        }
        /// 실측 fps (moves / duration)
        var fps: Double {
            guard durationMs > 0 else { return 0 }
            return Double(movesCount) / (durationMs / 1000.0)
        }
        /// burst 초반 1/3 평균 간격
        var earlyAvgIntervalMs: Double {
            let third = max(1, moves.count / 3)
            let early = Array(moves.prefix(third).dropFirst())
            guard !early.isEmpty else { return 0 }
            return early.map(\.intervalMs).reduce(0, +) / Double(early.count)
        }
        /// burst 후반 1/3 평균 간격 — 저하 감지
        var lateAvgIntervalMs: Double {
            let third = max(1, moves.count / 3)
            let late = Array(moves.suffix(third))
            guard !late.isEmpty else { return 0 }
            return late.map(\.intervalMs).reduce(0, +) / Double(late.count)
        }
        /// burst 내 저하 비율 (late / early) — 1.0 이 정상, 1.5+ 면 저하
        var internalSlowdown: Double {
            guard earlyAvgIntervalMs > 0 else { return 1.0 }
            return lateAvgIntervalMs / earlyAvgIntervalMs
        }
        /// main thread 평균 처리 시간
        var avgProcessingMs: Double {
            guard !moves.isEmpty else { return 0 }
            return moves.map(\.processingMs).reduce(0, +) / Double(moves.count)
        }
        /// main thread 최대 처리 시간
        var maxProcessingMs: Double {
            moves.map(\.processingMs).max() ?? 0
        }
    }

    struct Stats {
        var totalMoves: Int = 0
        var totalBursts: Int = 0
        var avgBurstFps: Double = 0          // 모든 burst 의 평균 fps
        var worstBurstSlowdown: Double = 1.0 // 가장 심한 burst 내 저하
        var lastBurstFps: Double = 0
        var lastBurstSlowdown: Double = 1.0
        var avgProcessingMs: Double = 0
        var maxProcessingMs: Double = 0

        // 메모리 누수 추적
        var sessionStartRamMB: Int = 0       // 세션 시작 시 RAM
        var currentRamMB: Int = 0
        var ramGrowthMB: Int = 0             // 시작 대비 증가량
        var ramPerMoveKB: Double = 0         // 이동당 평균 RAM 증가 (KB)
    }

    // MARK: - 설정

    /// 이 간격 이하면 같은 burst 로 그룹화 (key repeat rate = 30Hz = 33ms, 여유 있게)
    private let burstThresholdMs: Double = 100.0

    /// 이 시간 동안 이벤트 없으면 burst 종료
    private let burstEndGraceMs: Double = 150.0

    private let maxRecent = 120

    // MARK: - 내부 상태

    private var session: Session?
    private var allBursts: [BurstInfo] = []

    // 현재 이동 처리 중 (notifyMoveStart → notifyMoveCompleted 사이)
    private var currentMoveStartTime: Date?
    private var currentMovePhotoIndex: Int = 0
    private var currentMoveDirection: String = "·"
    private var previousMoveStartTime: Date?

    // burst 종료 타이머
    private var burstEndTimer: DispatchWorkItem?

    struct Session {
        var startedAt: Date
    }

    private init() {}

    // MARK: - Public API (호출 지점에서 사용)

    /// 이동 시작 (executeMoveSelection 내부에서 호출)
    /// - 반환: 없음 (processing 시간 측정은 notifyMoveCompleted 와 쌍)
    func notifyMoveStart(photoIndex: Int, direction: String) {
        guard isEnabled else { return }
        currentMoveStartTime = Date()
        currentMovePhotoIndex = photoIndex
        currentMoveDirection = direction
    }

    /// 이동 완료 (동기 처리 끝난 뒤, 예: scrollTrigger 증가 직후)
    /// - 핵심: 이 함수가 main thread 를 블록하면 측정 자체가 관찰 대상을 왜곡.
    ///         그래서 RAM/cache 같은 무거운 호출은 꾹 누르기 중엔 스킵.
    func notifyMoveCompleted() {
        guard isEnabled, let startTime = currentMoveStartTime else { return }
        let now = Date()
        let processingMs = now.timeIntervalSince(startTime) * 1000.0

        // 이전 move 시작과 지금 시작 간 간격 (사용자가 체감하는 이동 fps)
        let intervalMs: Double
        if let prev = previousMoveStartTime {
            intervalMs = startTime.timeIntervalSince(prev) * 1000.0
        } else {
            intervalMs = 0
        }
        previousMoveStartTime = startTime

        // burst 판정
        let isRepeat = intervalMs > 0 && intervalMs < burstThresholdMs

        // 꾹 누르기 중엔 무거운 metrics 는 N 번에 한 번만 샘플링 (RAM/cache 조회 최소화)
        // 매 이동마다 mach_task_basic_info + lock 조회는 main thread 에 10ms+ 비용 발생
        let shouldSampleHeavy = !isRepeat || (currentMoveIndex % 10 == 0)
        let ramMB = shouldSampleHeavy ? currentRamMB() : lastSampledRam
        let cacheCount = shouldSampleHeavy ? PreviewImageCache.shared.count : lastSampledCacheCount
        let cacheMB = shouldSampleHeavy ? PreviewImageCache.shared.currentBytesMB : lastSampledCacheMB
        if shouldSampleHeavy {
            lastSampledRam = ramMB
            lastSampledCacheCount = cacheCount
            lastSampledCacheMB = cacheMB
        }
        currentMoveIndex &+= 1

        let event = MoveEvent(
            index: currentMoveIndex,
            photoIndex: currentMovePhotoIndex,
            direction: currentMoveDirection,
            intervalMs: intervalMs,
            processingMs: processingMs,
            isRepeat: isRepeat,
            ramUsageMB: ramMB,
            previewCacheCount: cacheCount,
            previewCacheMB: cacheMB,
            timestamp: startTime
        )

        // burst 업데이트 (경량)
        if isRepeat, activeBurst != nil {
            activeBurst!.moves.append(event)
        } else if isRepeat {
            var newBurst = BurstInfo(startedAt: event.timestamp)
            newBurst.moves.append(event)
            activeBurst = newBurst
        } else {
            if activeBurst != nil {
                activeBurst!.endedAt = now
                activeBurst!.moves.append(event)
                finalizeBurst(activeBurst!)
            } else {
                var single = BurstInfo(startedAt: event.timestamp)
                single.endedAt = now
                single.moves.append(event)
                finalizeBurst(single)
            }
        }

        // 링 버퍼 (append 만 — @Published 변경 감지는 메인 스레드 end-of-runloop coalescing)
        recentMoves.append(event)
        if recentMoves.count > maxRecent {
            recentMoves.removeFirst(recentMoves.count - maxRecent)
        }

        currentMoveStartTime = nil

        // 꾹 누르기 중엔 stats 업데이트/burst end 체크도 드물게 — main thread 보호
        if shouldSampleHeavy {
            scheduleBurstEndCheck()
            updateStats()

            // 자동 안전장치: 세션 시작 대비 RAM 이 2GB 이상 증가 시 강제 캐시 해제
            // 꾹 누르기 중에도 주기적으로 (자동 방어선)
            let growth = ramMB - sessionStartRam
            if growth > 2000 && ramMB - lastAutoFlushRam > 1000 {
                fputs("[NAVPERF] RAM 증가 \(growth)MB 초과 → 자동 캐시 해제\n", stderr)
                _ = forceFlushAllCaches()
                lastAutoFlushRam = ramMB
            }
        }
    }

    private var lastAutoFlushRam: Int = 0

    // 경량 샘플링용 캐시
    private var currentMoveIndex: Int = 0
    private var lastSampledRam: Int = 0
    private var lastSampledCacheCount: Int = 0
    private var lastSampledCacheMB: Int = 0

    // MARK: - Session / Export

    func startSession() {
        session = Session(startedAt: Date())
        recentMoves.removeAll()
        allBursts.removeAll()
        activeBurst = nil
        lastBurst = nil
        previousMoveStartTime = nil
        stats = Stats()
        sessionStartRam = currentRamMB()
        fputs("[NAVPERF] 세션 시작 — RAM \(sessionStartRam)MB\n", stderr)
    }

    private var sessionStartRam: Int = 0

    /// 모든 이미지 캐시 강제 해제 — 누수가 캐시 내부인지 외부인지 판별용
    /// 호출 후 RAM 이 크게 줄면 → 캐시 문제, 안 줄면 → 다른 곳 누수
    func forceFlushAllCaches() -> String {
        let before = currentRamMB()
        PreviewImageCache.shared.clearCache()
        ThumbnailCache.shared.removeAll()
        AggressiveImageCache.shared.removeAll()
        PhotoPreviewView.clearHiResCache()
        // GC 유도: allocation 많이 해제되고 나면 malloc zone 가 OS 에 돌려주도록
        DispatchQueue.global(qos: .utility).async {
            autoreleasepool { }
        }
        let after = currentRamMB()
        let msg = "캐시 해제: \(before)MB → \(after)MB (감소 \(before - after)MB)"
        fputs("[NAVPERF] \(msg)\n", stderr)
        return msg
    }

    func endSession() {
        guard let sess = session else { return }
        // 진행 중 burst 마감
        if var current = activeBurst {
            current.endedAt = Date()
            finalizeBurst(current)
        }
        let dur = Date().timeIntervalSince(sess.startedAt)
        fputs("[NAVPERF] 세션 종료: \(allBursts.count) bursts, \(recentMoves.count) moves in \(String(format: "%.1f", dur))s\n", stderr)
        session = nil
    }

    /// CSV 리포트 저장
    @discardableResult
    func exportReport() -> URL? {
        guard session != nil else { return nil }
        let fm = FileManager.default
        let fileName = "navperf_\(Int(Date().timeIntervalSince1970)).csv"
        let url = fm.temporaryDirectory.appendingPathComponent(fileName)

        var csv = "burst,move,photoIndex,dir,intervalMs,processingMs,isRepeat,ramMB,cacheCount,cacheMB,timestamp\n"
        // 완료된 burst + 진행 중 burst
        var allToExport = allBursts
        if let current = activeBurst { allToExport.append(current) }
        for (bi, b) in allToExport.enumerated() {
            for (mi, m) in b.moves.enumerated() {
                csv += "\(bi),\(mi),\(m.photoIndex),\(m.direction),\(String(format: "%.2f", m.intervalMs)),\(String(format: "%.2f", m.processingMs)),\(m.isRepeat),\(m.ramUsageMB),\(m.previewCacheCount),\(m.previewCacheMB),\(m.timestamp.timeIntervalSince1970)\n"
            }
        }
        // burst 요약
        csv += "\n--- BURST SUMMARY ---\n"
        csv += "burst,moves,durationMs,fps,earlyIntervalMs,lateIntervalMs,internalSlowdown,avgProcMs,maxProcMs\n"
        for (bi, b) in allToExport.enumerated() {
            csv += "\(bi),\(b.movesCount),\(String(format: "%.1f", b.durationMs)),\(String(format: "%.2f", b.fps)),\(String(format: "%.2f", b.earlyAvgIntervalMs)),\(String(format: "%.2f", b.lateAvgIntervalMs)),\(String(format: "%.2f", b.internalSlowdown)),\(String(format: "%.2f", b.avgProcessingMs)),\(String(format: "%.2f", b.maxProcessingMs))\n"
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

    private func scheduleBurstEndCheck() {
        burstEndTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if var current = self.activeBurst {
                current.endedAt = Date()
                self.finalizeBurst(current)
            }
        }
        burstEndTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(burstEndGraceMs)), execute: work)
    }

    private func finalizeBurst(_ burst: BurstInfo) {
        allBursts.append(burst)
        lastBurst = burst
        activeBurst = nil
        updateStats()
    }

    private func updateStats() {
        var s = Stats()
        s.totalMoves = recentMoves.count
        // allBursts 기반 통계
        let allMoves = allBursts.flatMap { $0.moves } + (activeBurst?.moves ?? [])
        s.totalMoves = allMoves.count

        let multiMoveBursts = allBursts.filter { $0.movesCount >= 3 }  // 의미 있는 burst 만
        s.totalBursts = multiMoveBursts.count

        if !multiMoveBursts.isEmpty {
            s.avgBurstFps = multiMoveBursts.map(\.fps).reduce(0, +) / Double(multiMoveBursts.count)
            s.worstBurstSlowdown = multiMoveBursts.map(\.internalSlowdown).max() ?? 1.0
        }
        if let last = lastBurst {
            s.lastBurstFps = last.fps
            s.lastBurstSlowdown = last.internalSlowdown
        }
        if !allMoves.isEmpty {
            s.avgProcessingMs = allMoves.map(\.processingMs).reduce(0, +) / Double(allMoves.count)
            s.maxProcessingMs = allMoves.map(\.processingMs).max() ?? 0
        }

        // 메모리 누수 추적
        s.sessionStartRamMB = sessionStartRam
        s.currentRamMB = currentRamMB()
        s.ramGrowthMB = s.currentRamMB - sessionStartRam
        if !allMoves.isEmpty && s.ramGrowthMB > 0 {
            s.ramPerMoveKB = Double(s.ramGrowthMB) * 1024.0 / Double(allMoves.count)
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

// MARK: - PreviewImageCache 통계 확장
extension PreviewImageCache {
    var count: Int { debugStats().count }
    var currentBytesMB: Int { debugStats().bytes / (1024 * 1024) }
}
