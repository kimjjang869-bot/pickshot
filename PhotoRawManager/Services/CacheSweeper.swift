//
//  CacheSweeper.swift
//  PhotoRawManager
//
//  v8.6.2: Idle-time 백그라운드 캐시 sweep.
//  철학: "이미 빠름. 더 쾌적하기 위한 작업. 사용자에게 부하 주지 말 것."
//
//  동작:
//  - 사용자 활동(사진 선택 변경, 스크롤, 키 입력) 이 2초 이상 없으면 sweep 시작
//  - 활동 감지 즉시 진행 중 sweep 취소 (중단점에서 멈춤)
//  - 동시성 1 — 시각 썸네일 로딩(4-way)과 별도 큐
//  - 슬로우 디스크(HDD/NAS/SD)면 idle 기준 5초 + 각 작업 간격 150ms
//  - 썸네일 먼저(영속 디스크 캐시), 미리보기는 현재 선택 ±100 범위만 (메모리 50장 캡 내)
//

import Foundation
import AppKit
import Combine

final class CacheSweeper: ObservableObject {
    static let shared = CacheSweeper()

    // MARK: - 공개 상태
    @Published private(set) var isSweeping: Bool = false
    @Published private(set) var sweepMessage: String = ""

    // MARK: - 내부 상태
    private var lastActivity: Date = Date()
    private var idleTimer: Timer?
    private var sweepWork: DispatchWorkItem?

    private var pendingThumbnails: [URL] = []
    private var pendingPreviews: [URL] = []
    private var currentFolder: URL?
    private let sweepLock = NSLock()

    // MARK: - 설정
    private let idleThresholdFast: TimeInterval = 2.0
    private let idleThresholdSlow: TimeInterval = 5.0
    private let slowDiskPerItemDelay: TimeInterval = 0.15
    // v8.6.3: tier 기반 범위 — low 100 / standard 200 / high 400 / extreme 600
    private var previewRangeAroundSelection: Int {
        switch SystemSpec.shared.effectiveTier {
        case .low: return 100
        case .standard: return 200
        case .high: return 400
        case .extreme: return 600
        }
    }

    // MARK: - 외부 의존
    /// 현재 폴더가 슬로우 디스크인지 판단. ContentView.onAppear 에서 주입.
    var isSlowDiskProvider: (() -> Bool)?
    /// 사용자가 지금 "바쁜" 작업 중인지 (로딩/변환/분석/스트레스 테스트).
    var isBusyProvider: (() -> Bool)?
    /// 현재 선택된 사진 인덱스 (0-based, photos 배열 내에서).
    var selectedIndexProvider: (() -> Int?)?
    /// 미리보기 카운트 업데이트 콜백 (CacheProgressGauge 연동). main thread 외에서도 호출 안전해야 함.
    var storeNotePreview: ((URL) -> Void)?
    /// v8.6.2: jpgURL → decode URL 매핑 (RAW+JPG 쌍에서 RAW 를 decode 소스로 사용)
    var resolveDecodeURLProvider: ((URL) -> URL?)?

    private init() {}

    // MARK: - Public API

    /// 사용자 활동 발생 — 진행 중 sweep 즉시 중단, idle 타이머 리셋.
    func notifyActivity() {
        lastActivity = Date()
        sweepWork?.cancel()
        sweepWork = nil
        if isSweeping {
            DispatchQueue.main.async { [weak self] in
                self?.isSweeping = false
                self?.sweepMessage = "사용자 활동으로 sweep 중단"
            }
        }
        rescheduleIdleTimer()
    }

    /// 폴더 로드 완료 시 호출. sweep 대상 재구성.
    func prepareForFolder(url: URL, photos: [URL]) {
        sweepLock.lock()
        currentFolder = url
        // 썸네일: 디스크 캐시 miss 인 것만 대상
        pendingThumbnails = photos.filter {
            !DiskThumbnailCache.shared.hasThumb(for: $0)
        }
        pendingPreviews = photos
        sweepLock.unlock()
        fputs("[SWEEP] prepared folder \(url.lastPathComponent): \(pendingThumbnails.count) thumbs / \(pendingPreviews.count) previews pending\n", stderr)
        rescheduleIdleTimer()
    }

    /// 앱 종료 등 전역 취소.
    func cancel() {
        sweepWork?.cancel()
        sweepWork = nil
        idleTimer?.invalidate()
        idleTimer = nil
        DispatchQueue.main.async { [weak self] in
            self?.isSweeping = false
        }
    }

    // MARK: - 내부

    private var currentIdleThreshold: TimeInterval {
        (isSlowDiskProvider?() ?? false) ? idleThresholdSlow : idleThresholdFast
    }

    private func rescheduleIdleTimer() {
        idleTimer?.invalidate()
        let threshold = currentIdleThreshold
        idleTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            self?.startSweepIfIdle()
        }
    }

    private func startSweepIfIdle() {
        // 활동이 다시 발생했으면 취소
        guard Date().timeIntervalSince(lastActivity) >= currentIdleThreshold * 0.9 else { return }
        // 무거운 foreground 작업 중이면 skip
        if isBusyProvider?() ?? false { return }
        // 이미 sweep 중이면 skip
        if isSweeping { return }
        // 할 일이 없으면 skip
        sweepLock.lock()
        let hasWork = !pendingThumbnails.isEmpty || !pendingPreviews.isEmpty
        sweepLock.unlock()
        guard hasWork else { return }

        let slow = isSlowDiskProvider?() ?? false
        let work = DispatchWorkItem { [weak self] in
            self?.runSweep(slowDisk: slow)
        }
        sweepWork = work
        DispatchQueue.main.async { [weak self] in
            self?.isSweeping = true
            self?.sweepMessage = "idle sweep 시작"
        }
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    /// Sweep 본체. 작업 전후로 `sweepWork.isCancelled` 체크해서 즉시 중단.
    private func runSweep(slowDisk: Bool) {
        let perItemDelay = slowDisk ? slowDiskPerItemDelay : 0
        var thumbsDone = 0
        var previewsDone = 0

        // 1) 썸네일 먼저 (디스크 캐시 영속)
        while true {
            guard let work = sweepWork, !work.isCancelled else {
                fputs("[SWEEP] 중단 — thumbs=\(thumbsDone) previews=\(previewsDone)\n", stderr)
                break
            }
            sweepLock.lock()
            let next = pendingThumbnails.isEmpty ? nil : pendingThumbnails.removeFirst()
            sweepLock.unlock()
            guard let url = next else { break }

            // foreground 가 바빠지면 양보
            if isBusyProvider?() ?? false {
                sweepLock.lock()
                pendingThumbnails.insert(url, at: 0)  // 되돌려 넣기
                sweepLock.unlock()
                fputs("[SWEEP] 양보 (busy) — thumbs 남음=\(pendingThumbnails.count)\n", stderr)
                break
            }

            autoreleasepool {
                _ = ThumbnailLoader.shared.generateThumbnailSync(url: url)
            }
            thumbsDone += 1
            if thumbsDone % 20 == 0 {
                fputs("[SWEEP] thumbs +\(thumbsDone) (남음=\(pendingThumbnails.count))\n", stderr)
            }
            if perItemDelay > 0 { Thread.sleep(forTimeInterval: perItemDelay) }
        }

        // 2) 미리보기 — 선택 인덱스 ±N 범위만
        if !(sweepWork?.isCancelled ?? true) {
            let selIdx = selectedIndexProvider?() ?? 0
            sweepLock.lock()
            let total = pendingPreviews.count
            // v8.6.2 fix: lo/hi 를 [0, total] 범위로 clamp + lo <= hi 보장.
            //   이전엔 selIdx 가 total 보다 크면 lo > hi 가 되어 Array slice 크래시.
            let loRaw = selIdx - previewRangeAroundSelection
            let hiRaw = selIdx + previewRangeAroundSelection
            let lo = max(0, min(loRaw, total))
            let hi = max(lo, min(hiRaw, total))
            let window = (total > 0 && lo < hi) ? Array(pendingPreviews[lo..<hi]) : []
            sweepLock.unlock()

            // UserDefaults 의 previewResolution (기본 1000) 와 동일한 cacheKey 규칙으로 저장
            let res = UserDefaults.standard.string(forKey: "previewMaxResolution").flatMap { Int($0) } ?? 1000
            let maxPx: CGFloat = res > 0 ? CGFloat(res) : 1600

            // v8.6.2: 병렬 프리페치 — 하드웨어 tier 기반 조정
            //   - low (8GB M1 MBA): 1개 (CPU 과포화 방지 — 실측 로그에서 300% 지속 확인)
            //   - standard/high/extreme: 2개
            //   - slow disk: 항상 1개
            let opQueue = OperationQueue()
            let tier = SystemSpec.shared.effectiveTier
            opQueue.maxConcurrentOperationCount = (slowDisk || tier == .low) ? 1 : 2
            opQueue.qualityOfService = .utility
            let resolveDecodeURL = self.resolveDecodeURLProvider  // capture closure
            let bust = isBusyProvider
            let notePreview = storeNotePreview

            var previewsSkipped = 0
            for url in window {
                if let work = sweepWork, work.isCancelled { break }
                if bust?() ?? false { break }
                let cacheKey = res > 0 ? url.appendingPathExtension("r\(res)") : url.appendingPathExtension("orig")
                if PreviewImageCache.shared.has(cacheKey) {
                    previewsSkipped += 1
                    continue
                }

                opQueue.addOperation {
                    autoreleasepool {
                        // RAW+JPG 쌍이면 RAW 임베디드 프리뷰로 디코드 (JPG 20MB → 1/10)
                        let decodeURL = resolveDecodeURL?(url) ?? url
                        if let img = PreviewImageCache.loadOptimized(url: decodeURL, maxPixel: maxPx) {
                            PreviewImageCache.shared.set(cacheKey, image: img)
                            notePreview?(url)
                        }
                    }
                }
                previewsDone += 1
                if perItemDelay > 0 { Thread.sleep(forTimeInterval: perItemDelay) }
            }
            if previewsSkipped > 0 {
                fputs("[SWEEP] previews already cached (skipped): \(previewsSkipped)\n", stderr)
            }
            // 대기 — 모든 op 완료 or 취소
            while opQueue.operationCount > 0 {
                if let work = sweepWork, work.isCancelled {
                    opQueue.cancelAllOperations()
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            opQueue.waitUntilAllOperationsAreFinished()
        }

        DispatchQueue.main.async { [weak self] in
            self?.isSweeping = false
            self?.sweepMessage = "sweep 완료 thumbs=\(thumbsDone) previews=\(previewsDone)"
            fputs("[SWEEP] 완료 thumbs=\(thumbsDone) previews=\(previewsDone)\n", stderr)
        }
    }
}
