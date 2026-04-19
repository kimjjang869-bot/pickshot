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
        let thumbMemMB: Int      // ThumbnailCache (추정)
        let previewMemMB: Int    // PreviewImageCache
        let hiResMB: Int         // hiResCache (추정)
        let developCount: Int    // DevelopStore memory dict 엔트리 수
        let photosCount: Int     // 현재 폴더의 photos 개수
        let trigger: String      // "timer" | "stress" | "manual" | "spike"
    }

    private var timer: Timer?
    private let sampleInterval: TimeInterval = 5.0  // 5초마다 샘플
    private let spikeThresholdMB: Int = 100          // 단일 샘플 간격에 +100MB 이상이면 spike
    private var logFileURL: URL?

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

    // MARK: - Sampling

    func sampleOnce(trigger: String) {
        let rssMB = Self.currentProcessRSSMB()
        currentRSSMB = rssMB
        if rssMB > peakRSSMB { peakRSSMB = rssMB }

        // Spike detection
        if let last = snapshots.last, rssMB - last.rssMB >= spikeThresholdMB {
            let dt = Date().timeIntervalSince(last.timestamp)
            let rate = Double(rssMB - last.rssMB) / max(dt, 0.001) * 60.0
            growthRateMBPerMin = rate
            let spikeSnap = makeSnapshot(rssMB: rssMB, trigger: "spike(+\(rssMB - last.rssMB)MB)")
            appendSnapshot(spikeSnap)
            logToFile(spikeSnap)
            // stderr 경고
            fputs("[LEAK-TRACKER] ⚠️ SPIKE \(rssMB - last.rssMB)MB in \(String(format: "%.1f", dt))s (rate=\(Int(rate))MB/min) — peak=\(peakRSSMB)MB\n", stderr)
        }

        let snap = makeSnapshot(rssMB: rssMB, trigger: trigger)
        appendSnapshot(snap)
        logToFile(snap)
    }

    private func makeSnapshot(rssMB: Int, trigger: String) -> Snapshot {
        let thumbMB = ThumbnailCache.shared.debugCountAndLimit().limitMB
        let previewInfo = PreviewImageCache.shared.debugStats()
        let previewMB = previewInfo.bytes / 1024 / 1024
        return Snapshot(
            timestamp: Date(),
            rssMB: rssMB,
            thumbMemMB: thumbMB,
            previewMemMB: previewMB,
            hiResMB: 0,  // NSCache 내부 bytes 노출 안 됨
            developCount: 0,
            photosCount: externalPhotosCount,
            trigger: trigger
        )
    }

    /// ContentView 같은 외부에서 store.photos.count 를 주기적으로 업데이트.
    var externalPhotosCount: Int = 0

    private func appendSnapshot(_ s: Snapshot) {
        snapshots.append(s)
        // 링버퍼 500개 유지
        if snapshots.count > 500 {
            snapshots.removeFirst(snapshots.count - 500)
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
        // CSV 헤더
        let header = "timestamp,rss_mb,peak_mb,growth_rate_mbmin,thumb_mb,preview_mb,photos_count,trigger\n"
        try? header.data(using: .utf8)?.write(to: logFileURL!)
    }

    private func logToFile(_ s: Snapshot) {
        guard let url = logFileURL else { return }
        let line = "\(s.timestamp.timeIntervalSince1970),\(s.rssMB),\(peakRSSMB),\(String(format: "%.1f", growthRateMBPerMin)),\(s.thumbMemMB),\(s.previewMemMB),\(s.photosCount),\(s.trigger)\n"
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

    // MARK: - Stress Test
    //
    // 외부에서 PhotoStore 주입 — callback 으로 다음 사진 선택.
    // UI 를 직접 클릭하지는 않고 프로그래밍 방식으로 순환.
    var stressPhotoProvider: (() -> [UUID])?       // UUID 배열 제공
    var stressPhotoSelector: ((UUID) -> Void)?     // 선택 콜백

    func runStressTest(cycles: Int = 50) {
        guard !isStressTesting else { return }
        guard let provider = stressPhotoProvider, let selector = stressPhotoSelector else {
            stressProgress = "❌ 스트레스 테스트 provider 미연결 (ContentView 에서 설정 필요)"
            return
        }
        let photoIDs = provider()
        guard !photoIDs.isEmpty else {
            stressProgress = "❌ 사진이 없습니다 — 폴더를 먼저 열어주세요"
            return
        }
        isStressTesting = true
        sampleOnce(trigger: "stress_start")
        let initialMB = currentRSSMB

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for cycle in 0..<cycles {
                for (i, id) in photoIDs.enumerated() {
                    DispatchQueue.main.async { selector(id) }
                    Thread.sleep(forTimeInterval: 0.05)  // 20 photos/sec
                    if i % 50 == 0 {
                        DispatchQueue.main.async {
                            self.stressProgress = "cycle \(cycle+1)/\(cycles) — photo \(i)/\(photoIDs.count)  RSS=\(self.currentRSSMB)MB"
                        }
                        self.sampleOnce(trigger: "stress_c\(cycle)_p\(i)")
                    }
                }
            }
            DispatchQueue.main.async {
                self.sampleOnce(trigger: "stress_end")
                let delta = self.currentRSSMB - initialMB
                self.stressProgress = "✅ 완료 — \(cycles) cycles × \(photoIDs.count) photos. RSS: \(initialMB)→\(self.currentRSSMB)MB (Δ\(delta > 0 ? "+" : "")\(delta)MB)"
                self.isStressTesting = false
                fputs("[STRESS] 완료 초기=\(initialMB)MB 최종=\(self.currentRSSMB)MB Δ\(delta)MB peak=\(self.peakRSSMB)MB\n", stderr)
            }
        }
    }
}
