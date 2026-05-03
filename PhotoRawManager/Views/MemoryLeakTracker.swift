//
//  MemoryLeakTracker.swift
//  PhotoRawManager
//
//  v8.6.1 메모리 누수 추적 툴.
//  - 주기적으로 프로세스 RSS + 각 캐시 크기 샘플링
//  - 급격한 증가(≥100MB / 10초) 감지 시 알림 + 로그 파일 기록
//  - 스트레스 테스트 내장: 프로그래밍 방식 사진 탐색/삭제 시뮬레이션해서 breakpoint 측정
//

import Foundation
import Darwin
import Darwin.Mach
import Combine
import AppKit

/// 메모리 누수 추적 + 스트레스 테스트 싱글톤.
final class MemoryLeakTracker: ObservableObject {
    static let shared = MemoryLeakTracker()

    /// 실시간 표시용 현재 메모리 (MB)
    @Published private(set) var currentRSSMB: Int = 0
    @Published private(set) var peakRSSMB: Int = 0
    @Published private(set) var growthRateMBPerMin: Double = 0
    @Published private(set) var snapshots: [Snapshot] = []
    @Published var isTracking: Bool = false
    @Published var isStressTesting: Bool = false
    @Published var stressProgress: String = ""

    struct Snapshot: Identifiable {
        let id = UUID()
        let timestamp: Date
        let rssMB: Int
        let thumbLimitMB: Int    // ThumbnailCache.totalCostLimit (제한치)
        let previewMemMB: Int    // PreviewImageCache 실 사용 bytes
        let previewCount: Int    // PreviewImageCache 엔트리 개수
        let hiResCount: Int      // hiResCache orderlist 엔트리 개수
        let vmSwapMB: Int        // 스왑 영역 추정 (task_vm_info)
        let photosCount: Int
        let trigger: String
    }

    private var timer: Timer?
    private let sampleInterval: TimeInterval = 5.0  // 5초마다 샘플
    private let spikeThresholdMB: Int = 100          // 단일 샘플 간격에 +100MB 이상이면 spike
    private var logFileURL: URL?

    // v8.6.1: 하드 메모리 캡 — 이 값 초과 시 강제 emergency cleanup.
    // 기본 6GB. 사용자가 "6GB 정도가 마지노선" 이라고 지정.
    private let hardCapMB: Int = 6144
    private let warnCapMB: Int = 4096   // 4GB 초과 시 경고 + 선제적 evict
    private var lastAutoCleanupTime: Date = Date.distantPast
    private let autoCleanupCooldown: TimeInterval = 2.0  // v8.6.2: 10→2초 (캡 초과 시 빠르게 회수)
    /// v8.6.2: 하드캡 초과 시 진행 중 스트레스 테스트 강제 중단 플래그
    private var stressAbortRequested: Bool = false

    private init() {
        setupLogFile()
    }

    // MARK: - Start/Stop

    func start() {
        guard timer == nil else { return }
        isTracking = true
        sampleOnce(trigger: "start")
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.sampleOnce(trigger: "timer")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isTracking = false
    }

    /// v8.6.2: HUD "중단" 버튼에서 호출 — 진행 중 스트레스 테스트 즉시 중단.
    func abortStressTest() {
        stressAbortRequested = true
        plog("[LEAK-TRACKER] ⏹ 사용자가 스트레스 테스트 중단 요청\n")
    }

    // MARK: - Sampling

    func sampleOnce(trigger: String) {
        // v8.9.3 fix: background thread 에서 호출되면 전체 함수를 main 으로 dispatch.
        //   여러 @Published 변수 (currentRSSMB, peakRSSMB, growthRateMBPerMin, snapshots) 가
        //   background 에서 modify 될 때 SwiftUI body 동기 재계산 → stack overflow.
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.sampleOnce(trigger: trigger) }
            return
        }
        let rssMB = Self.currentProcessRSSMB()
        currentRSSMB = rssMB
        if rssMB > peakRSSMB { peakRSSMB = rssMB }

        // v8.6.1: 하드 메모리 캡 체크 — 6GB 초과 시 자동 emergency cleanup
        //   10초 쿨다운 (무한 루프 방지) + 트리거 자체 내에서는 호출 X (재귀 방지)
        if rssMB > hardCapMB && !trigger.hasPrefix("autocap") && !trigger.hasPrefix("cleanup") {
            // v8.6.2: 하드캡 초과 → 즉시 stress test 중단 요청 + emergency cleanup
            if isStressTesting { stressAbortRequested = true }
            let now = Date()
            if now.timeIntervalSince(lastAutoCleanupTime) > autoCleanupCooldown {
                lastAutoCleanupTime = now
                plog("[LEAK-TRACKER] 🚨 HARD CAP \(hardCapMB)MB 초과 (\(rssMB)MB) → 자동 emergency cleanup + stress 중단\n")
                DispatchQueue.main.async { [weak self] in
                    _ = self?.emergencyCleanup()
                }
            }
        } else if rssMB > warnCapMB {
            // 4GB 초과 — 선제적 NSCache evict 유도
            PreviewImageCache.shared.reduceCacheLimit()
            ThumbnailCache.shared.reduceCacheLimit()
        }

        // Spike detection
        if let last = snapshots.last, rssMB - last.rssMB >= spikeThresholdMB {
            let dt = Date().timeIntervalSince(last.timestamp)
            let rate = Double(rssMB - last.rssMB) / max(dt, 0.001) * 60.0
            growthRateMBPerMin = rate
            let spikeSnap = makeSnapshot(rssMB: rssMB, trigger: "spike(+\(rssMB - last.rssMB)MB)")
            appendSnapshot(spikeSnap)
            logToFile(spikeSnap)
            // stderr 경고
            plog("[LEAK-TRACKER] ⚠️ SPIKE \(rssMB - last.rssMB)MB in \(String(format: "%.1f", dt))s (rate=\(Int(rate))MB/min) — peak=\(peakRSSMB)MB\n")
        }

        let snap = makeSnapshot(rssMB: rssMB, trigger: trigger)
        appendSnapshot(snap)
        logToFile(snap)
    }

    private func makeSnapshot(rssMB: Int, trigger: String) -> Snapshot {
        let thumbLimit = ThumbnailCache.shared.debugCountAndLimit().limitMB
        let previewInfo = PreviewImageCache.shared.debugStats()
        let previewMB = previewInfo.bytes / 1024 / 1024
        return Snapshot(
            timestamp: Date(),
            rssMB: rssMB,
            thumbLimitMB: thumbLimit,
            previewMemMB: previewMB,
            previewCount: previewInfo.count,
            hiResCount: PhotoPreviewView.debugHiResCount(),
            vmSwapMB: Self.currentSwapMB(),
            photosCount: externalPhotosCount,
            trigger: trigger
        )
    }

    /// task_vm_info 의 swap 사용량 (스왑 총합).
    static func currentSwapMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.compressed / 1024 / 1024)
    }

    /// ContentView 같은 외부에서 store.photos.count 를 주기적으로 업데이트.
    var externalPhotosCount: Int = 0

    private func appendSnapshot(_ s: Snapshot) {
        // v8.9.3 fix: snapshots 도 @Published — background 에서 modify 시 SwiftUI body 동기 재계산으로 stack overflow.
        if Thread.isMainThread {
            snapshots.append(s)
            if snapshots.count > 500 {
                snapshots.removeFirst(snapshots.count - 500)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.snapshots.append(s)
                if self.snapshots.count > 500 {
                    self.snapshots.removeFirst(self.snapshots.count - 500)
                }
            }
        }
    }

    // MARK: - Process RSS

    /// 현재 프로세스의 resident memory (MB).
    static func currentProcessRSSMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return Int(info.resident_size / 1024 / 1024)
        }
        return 0
    }

    // MARK: - Log File

    private func setupLogFile() {
        let logsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/PickShot")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        logFileURL = logsDir.appendingPathComponent("memleak_\(formatter.string(from: Date())).csv")
        // CSV 헤더 (v8.6.1 확장: hiResCount, previewCount, vmSwapMB)
        let header = "timestamp,rss_mb,peak_mb,growth_rate_mbmin,thumb_limit_mb,preview_mb,preview_count,hires_count,swap_mb,photos_count,trigger\n"
        try? header.data(using: .utf8)?.write(to: logFileURL!)
    }

    private func logToFile(_ s: Snapshot) {
        guard let url = logFileURL else { return }
        let line = "\(s.timestamp.timeIntervalSince1970),\(s.rssMB),\(peakRSSMB),\(String(format: "%.1f", growthRateMBPerMin)),\(s.thumbLimitMB),\(s.previewMemMB),\(s.previewCount),\(s.hiResCount),\(s.vmSwapMB),\(s.photosCount),\(s.trigger)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    func openLogFolder() {
        guard let url = logFileURL?.deletingLastPathComponent() else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Emergency Memory Cleanup
    //
    // v8.6.1: 메모리 누수 수정에도 OS 레벨 VM 이 해제 안 되는 경우를 위한 강제 cleanup.
    // NSCache 들 removeAllObjects + OperationQueue 취소 + prefetch queue drain +
    // autoreleasepool 강제 drain + GPU texture flush.
    func emergencyCleanup() -> String {
        let before = Self.currentProcessRSSMB()
        var log = [String]()

        // 1) 모든 in-memory 캐시 비우기
        PreviewImageCache.shared.clearCache()
        ThumbnailCache.shared.removeAll()
        log.append("✓ Preview/Thumbnail cache 해제")

        // 2) hiResCache (PhotoPreviewView static)
        PhotoPreviewView.clearAllHiResCache()
        log.append("✓ hiResCache 해제")

        // 3) DevelopPipeline CIRAWFilter
        DevelopPipeline.clearRAWCache()
        log.append("✓ Develop 캐시")

        // 4) FolderPreviewCache
        FolderPreviewCache.shared.invalidateAll()
        log.append("✓ FolderPreviewCache")

        // 5) autoreleasepool 강제 drain — 여러 pool 실행
        for _ in 0..<3 {
            autoreleasepool { _ = NSImage(size: NSSize(width: 1, height: 1)) }
        }

        // 6) malloc_zone_pressure_relief — macOS 가 내부 buffer 반환
        //    Darwin.malloc 의 C 함수라 런타임 로딩으로 호출.
        if let sym = dlsym(dlopen(nil, RTLD_NOW), "malloc_zone_pressure_relief") {
            typealias FP = @convention(c) (UnsafeMutableRawPointer?, Int) -> Int
            let fn = unsafeBitCast(sym, to: FP.self)
            _ = fn(nil, 0)
            log.append("✓ malloc pressure relief")
        }

        // 7) 샘플 즉시 다시 찍어 감소 확인
        Thread.sleep(forTimeInterval: 0.3)  // OS 가 반환할 시간
        let after = Self.currentProcessRSSMB()
        let delta = before - after
        log.append("RSS: \(before)MB → \(after)MB  (Δ -\(delta)MB)")
        let result = log.joined(separator: " | ")
        plog("[MEM-CLEANUP] \(result)\n")
        sampleOnce(trigger: "cleanup_\(delta)MB")
        return result
    }

    // MARK: - Stress Test providers (ContentView 에서 주입)
    var stressPhotoProvider: (() -> [UUID])?        // 현재 폴더의 photo ID 배열
    var stressPhotoSelector: ((UUID) -> Void)?      // 선택 콜백
    var stressGridColsProvider: (() -> Int)?        // 그리드 열 수 (행 이동 계산용)
    var stressDeleteAction: ((Set<UUID>) -> Void)?  // 실제 삭제 (휴지통, Cmd+Z 복원 가능)
    var stressCacheInvalidator: (([URL]) -> Void)?  // 삭제 시뮬레이션 (파일 안 건드리고 캐시만)
    var stressURLProvider: ((UUID) -> URL?)?        // UUID → URL
    // v8.9.3: 랜덤 폴더 전환용
    var stressFolderProvider: (() -> [URL])?        // 후보 폴더 URL 배열 (현재 폴더의 형제들)
    var stressFolderSwitcher: ((URL, Bool) -> Void)? // (URL, includeSubfolders) → 폴더 로드

    enum StressMode: String {
        case columnNav          // 열 이동 (20/sec) — 프리뷰 로드 부하
        case rowNav             // 행 이동 (10/sec) — 실제 검토 패턴
        case deleteSimulation   // safe — 캐시 정리 코드만 호출
        case actualDelete       // 실제 휴지통 이동 (35장, Cmd+Z 복원 가능)
        case randomFolderNav    // v8.9.3: 랜덤 폴더 전환 + 행/열/삭제 혼합 + 하위 폴더 포함 50%
    }

    func runStressTest(mode: StressMode, cycles: Int = 50) {
        guard !isStressTesting else { return }
        guard let provider = stressPhotoProvider, let selector = stressPhotoSelector else {
            stressProgress = "❌ provider 미연결"
            return
        }
        let photoIDs = provider()
        guard !photoIDs.isEmpty else {
            stressProgress = "❌ 사진이 없습니다"
            return
        }
        isStressTesting = true
        stressAbortRequested = false
        sampleOnce(trigger: "stress_start_\(mode.rawValue)")
        let initialMB = currentRSSMB

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            switch mode {
            case .columnNav: self.runColumnNav(photoIDs: photoIDs, cycles: cycles, selector: selector)
            case .rowNav: self.runRowNav(photoIDs: photoIDs, cycles: cycles, selector: selector)
            case .deleteSimulation: self.runDeleteSimulation(photoIDs: photoIDs, cycles: cycles)
            case .actualDelete: self.runActualDelete(photoIDs: photoIDs)
            case .randomFolderNav: self.runRandomFolderNav(cycles: cycles, selector: selector)
            }
            DispatchQueue.main.async {
                self.sampleOnce(trigger: "stress_end_\(mode.rawValue)")
                let deltaBefore = self.currentRSSMB - initialMB
                // v8.6.1: 스트레스 테스트 종료 시 자동 emergency cleanup → 메모리 해소 확인
                let cleanupResult = self.emergencyCleanup()
                let deltaAfter = self.currentRSSMB - initialMB
                self.stressProgress = "✅ \(mode.rawValue) 완료\n    테스트 중: \(initialMB)→\(initialMB + deltaBefore)MB (Δ+\(deltaBefore)MB)\n    cleanup 후: \(self.currentRSSMB)MB (Δ+\(deltaAfter)MB)\n    \(cleanupResult)"
                self.isStressTesting = false
                plog("[STRESS-\(mode.rawValue)] 완료 초기=\(initialMB)MB 테스트종료=\(initialMB + deltaBefore)MB cleanup후=\(self.currentRSSMB)MB\n")
            }
        }
    }

    private func runColumnNav(photoIDs: [UUID], cycles: Int, selector: @escaping (UUID) -> Void) {
        var currentIDs = photoIDs
        for cycle in 0..<cycles {
            for (i, id) in currentIDs.enumerated() {
                if stressAbortRequested { return }
                DispatchQueue.main.sync { autoreleasepool { selector(id) } }
                Thread.sleep(forTimeInterval: 0.05)  // 20/sec
                if i % 50 == 0 { logCycle("col", cycle+1, cycles, i, currentIDs.count) }
            }
            // v8.9.3: cycle 끝에 50% 확률 랜덤 폴더 전환 (하위 포함 25%)
            if let next = maybeSwitchFolder() { currentIDs = next }
        }
    }

    /// 행 이동 — gridCols 만큼 점프. 사용자의 실제 검토 패턴(↑↓).
    private func runRowNav(photoIDs: [UUID], cycles: Int, selector: @escaping (UUID) -> Void) {
        var currentIDs = photoIDs
        let cols = max(1, stressGridColsProvider?() ?? 6)
        DispatchQueue.main.async { self.stressProgress = "행 이동 시작 (cols=\(cols))" }
        for cycle in 0..<cycles {
            var i = 0
            while i < currentIDs.count {
                if stressAbortRequested { return }
                let id = currentIDs[i]
                DispatchQueue.main.sync { autoreleasepool { selector(id) } }
                Thread.sleep(forTimeInterval: 0.1)  // 10/sec
                i += cols
                if (i / cols) % 20 == 0 { logCycle("row↓", cycle+1, cycles, i, currentIDs.count) }
            }
            // 역방향
            i = currentIDs.count - 1
            while i >= 0 {
                if stressAbortRequested { return }
                let id = currentIDs[i]
                DispatchQueue.main.sync { autoreleasepool { selector(id) } }
                Thread.sleep(forTimeInterval: 0.1)
                i -= cols
            }
            // v8.9.3: cycle 끝에 50% 확률 랜덤 폴더 전환
            if let next = maybeSwitchFolder() { currentIDs = next }
        }
    }

    /// v8.9.3: 50% 확률로 랜덤 폴더로 전환. 그 중 50% 는 "하위 폴더 포함 열기" 모드.
    /// 반환: 전환됐으면 새 photoIDs, 아니면 nil.
    private func maybeSwitchFolder() -> [UUID]? {
        guard Bool.random() else { return nil }  // 50% 만 전환
        guard let folderProvider = stressFolderProvider,
              let folderSwitcher = stressFolderSwitcher,
              let photoProvider = stressPhotoProvider else { return nil }
        let folders = folderProvider()
        guard let target = folders.randomElement() else { return nil }
        let includeSub = Bool.random()
        DispatchQueue.main.sync { folderSwitcher(target, includeSub) }
        Thread.sleep(forTimeInterval: 0.6)  // 폴더 로드 대기
        let newIDs = DispatchQueue.main.sync { photoProvider() }
        DispatchQueue.main.async {
            self.stressProgress = "🎲 → \(target.lastPathComponent)\(includeSub ? " [+sub]" : "") (\(newIDs.count)장)"
        }
        sampleOnce(trigger: "switch_\(includeSub ? "sub" : "flat")")
        return newIDs.isEmpty ? nil : newIDs
    }

    /// 삭제 시뮬레이션 (파일 건드리지 않고 캐시 정리만) — safe 테스트
    private func runDeleteSimulation(photoIDs: [UUID], cycles: Int) {
        guard let urlProvider = stressURLProvider,
              let invalidator = stressCacheInvalidator else {
            DispatchQueue.main.async { self.stressProgress = "❌ invalidator 미연결" }
            return
        }
        for cycle in 0..<cycles {
            if stressAbortRequested { return }
            let batch = photoIDs.compactMap { urlProvider($0) }
            DispatchQueue.main.sync { invalidator(batch) }  // v8.6.2: main.sync 로 backlog 방지 + 즉시 실행
            // v8.6.2: 0.3s → 0.05s (6배 빠름). 매 cycle 메모리 샘플링도 1/5 로 줄여 오버헤드 최소화.
            Thread.sleep(forTimeInterval: 0.05)
            if cycle % 5 == 0 { sampleOnce(trigger: "del_sim_c\(cycle)") }
            if cycle % 5 == 0 {
                DispatchQueue.main.async {
                    self.stressProgress = "del_sim cycle \(cycle+1)/\(cycles) — \(batch.count) URLs  RSS=\(self.currentRSSMB)MB"
                }
            }
        }
    }

    /// 실제 삭제 35장 (튜브짱 시나리오 재현, Cmd+Z 로 복원 가능)
    private func runActualDelete(photoIDs: [UUID]) {
        guard let deleter = stressDeleteAction else {
            DispatchQueue.main.async { self.stressProgress = "❌ deleter 미연결" }
            return
        }
        let targetCount = min(35, photoIDs.count)
        let targets = Array(photoIDs.prefix(targetCount))
        for (i, id) in targets.enumerated() {
            if stressAbortRequested { return }
            DispatchQueue.main.sync { deleter([id]) }  // v8.6.2: main.sync 로 즉시 실행
            // v8.6.2: 1.5s → 0.1s (15배 빠름). 파일시스템 휴지통 이동이 병목이니 너무 빠르면
            // moveItem 동시성 이슈 가능 → 100ms 정도 안전 마진 확보.
            Thread.sleep(forTimeInterval: 0.1)
            if i % 5 == 0 { sampleOnce(trigger: "del_actual_\(i)") }
            DispatchQueue.main.async {
                self.stressProgress = "삭제 \(i+1)/\(targetCount)  RSS=\(self.currentRSSMB)MB"
            }
        }
    }

    private func logCycle(_ name: String, _ cycle: Int, _ total: Int, _ i: Int, _ n: Int) {
        DispatchQueue.main.async {
            self.stressProgress = "\(name) cycle \(cycle)/\(total) — photo \(i)/\(n)  RSS=\(self.currentRSSMB)MB"
        }
        sampleOnce(trigger: "\(name)_c\(cycle)_p\(i)")
    }

    // MARK: - Random Folder Nav (v8.9.3)

    /// 랜덤 폴더 전환 + 행/열/삭제 혼합 — 50% 확률로 "하위 폴더 포함 열기" 모드.
    /// 형제 폴더들을 무작위로 진입하며 사진 클릭 / 행 점프 / 캐시 무효화를 섞는다.
    private func runRandomFolderNav(cycles: Int, selector: @escaping (UUID) -> Void) {
        guard let folderProvider = stressFolderProvider,
              let folderSwitcher = stressFolderSwitcher,
              let photoProvider = stressPhotoProvider else {
            DispatchQueue.main.async { self.stressProgress = "❌ folder provider 미연결" }
            return
        }
        let folders = folderProvider()
        guard !folders.isEmpty else {
            DispatchQueue.main.async { self.stressProgress = "❌ 후보 폴더 없음 (부모 디렉토리 확인)" }
            return
        }
        DispatchQueue.main.async { self.stressProgress = "🎲 랜덤 폴더 전환 시작 (\(folders.count)개 후보)" }

        for cycle in 0..<cycles {
            if stressAbortRequested { return }
            // 랜덤 폴더 + 50% 확률 하위 폴더 포함
            guard let target = folders.randomElement() else { continue }
            let includeSub = Bool.random()
            DispatchQueue.main.sync { folderSwitcher(target, includeSub) }
            // 폴더 로드 + 첫 사진 표시 대기
            Thread.sleep(forTimeInterval: 0.6)
            if stressAbortRequested { return }
            // 현재 로드된 사진들에서 무작위 클릭
            let photoIDs = DispatchQueue.main.sync { photoProvider() }
            if photoIDs.isEmpty {
                logCycle("rndFolder", cycle+1, cycles, 0, 0)
                continue
            }
            // 5~12장 무작위 점프
            let jumps = Int.random(in: 5...12)
            for j in 0..<jumps {
                if stressAbortRequested { return }
                let id = photoIDs.randomElement()!
                DispatchQueue.main.sync { autoreleasepool { selector(id) } }
                Thread.sleep(forTimeInterval: Double.random(in: 0.05...0.15))
                if j == jumps - 1 {
                    DispatchQueue.main.async {
                        self.stressProgress = "🎲 \(target.lastPathComponent)\(includeSub ? " [+sub]" : "") cycle \(cycle+1)/\(cycles) — \(jumps)장 \(self.currentRSSMB)MB"
                    }
                }
            }
            sampleOnce(trigger: "rndFolder_c\(cycle)_\(includeSub ? "sub" : "flat")")
        }
    }
}
