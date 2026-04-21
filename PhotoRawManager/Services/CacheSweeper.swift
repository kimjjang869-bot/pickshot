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
    /// v8.8.1: 적극적 캐시 모드 여부 (PhotoStore.aggressiveCache 바인딩).
    ///   true → idle 대기 0초, 사용자 활동 감지해도 중단 안 함, 병렬성 증가, 전체 미리보기 캐싱.
    var aggressiveModeProvider: (() -> Bool)?
    /// 현재 선택된 사진 인덱스 (0-based, photos 배열 내에서).
    var selectedIndexProvider: (() -> Int?)?
    /// 미리보기 카운트 업데이트 콜백 (CacheProgressGauge 연동). main thread 외에서도 호출 안전해야 함.
    var storeNotePreview: ((URL) -> Void)?
    /// v8.6.2: jpgURL → decode URL 매핑 (RAW+JPG 쌍에서 RAW 를 decode 소스로 사용)
    var resolveDecodeURLProvider: ((URL) -> URL?)?

    private init() {}

    // MARK: - Public API

    /// 사용자 활동 발생 — 진행 중 sweep 즉시 중단, idle 타이머 리셋.
    /// v8.8.1: 적극 모드에선 사용자 활동 있어도 sweep 중단 안 함 (캐시 빌드 우선).
    func notifyActivity() {
        lastActivity = Date()
        let aggressive = aggressiveModeProvider?() ?? false
        if !aggressive {
            sweepWork?.cancel()
            sweepWork = nil
            if isSweeping {
                DispatchQueue.main.async { [weak self] in
                    self?.isSweeping = false
                    self?.sweepMessage = "사용자 활동으로 sweep 중단"
                }
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
        // v8.8.1: 적극 모드면 대기 없이 즉시 시작.
        if aggressiveModeProvider?() ?? false { return 0 }
        return (isSlowDiskProvider?() ?? false) ? idleThresholdSlow : idleThresholdFast
    }

    private func rescheduleIdleTimer() {
        idleTimer?.invalidate()
        let threshold = currentIdleThreshold
        // 적극 모드 (threshold=0): Timer 대신 최소 100ms 딜레이로 throttle.
        //   이전엔 DispatchQueue.main.async 로 즉시 실행 → notifyActivity 연타 시 concurrent
        //   startSweepIfIdle 가 16개 이상 돌면서 thread storm + swift_deallocClassInstance 크래시.
        if threshold <= 0 {
            idleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                self?.startSweepIfIdle()
            }
            return
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            self?.startSweepIfIdle()
        }
    }

    private func startSweepIfIdle() {
        // v8.8.1 fix: main thread 에서 호출 보장 (Timer fire = main, 이외 경로도 main 으로 통일).
        //   race 방지를 위해 isSweeping 체크 + 설정을 같은 tick 에 동기 처리.
        assert(Thread.isMainThread, "startSweepIfIdle must run on main")

        let aggressive = aggressiveModeProvider?() ?? false
        // 활동이 다시 발생했으면 취소 (적극 모드 제외)
        if !aggressive {
            guard Date().timeIntervalSince(lastActivity) >= currentIdleThreshold * 0.9 else { return }
            // 무거운 foreground 작업 중이면 skip (적극 모드는 무시)
            if isBusyProvider?() ?? false { return }
        }
        // 이미 sweep 중이면 skip (동기 체크 — main thread 라 race 없음)
        if isSweeping { return }
        if let existing = sweepWork, !existing.isCancelled {
            // 이전 sweepWork 가 아직 정리 안 됐으면 skip
            return
        }
        // 할 일이 없으면 skip
        sweepLock.lock()
        let hasWork = !pendingThumbnails.isEmpty || !pendingPreviews.isEmpty
        sweepLock.unlock()
        guard hasWork else { return }

        let slow = isSlowDiskProvider?() ?? false
        // isSweeping 을 동기 세팅 (@Published 지만 main thread 에서 직접 대입 가능)
        isSweeping = true
        sweepMessage = "idle sweep 시작"
        let work = DispatchWorkItem { [weak self] in
            self?.runSweep(slowDisk: slow)
        }
        sweepWork = work
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    /// Sweep 본체. 작업 전후로 `sweepWork.isCancelled` 체크해서 즉시 중단.
    private func runSweep(slowDisk: Bool) {
        let aggressive = aggressiveModeProvider?() ?? false
        // 적극 모드: per-item 지연 제거 (슬로우 디스크도 강제 풀스피드)
        let perItemDelay = (aggressive || !slowDisk) ? 0 : slowDiskPerItemDelay
        // 적극 모드 썸네일 병렬성: tier 기반. 기본 모드는 1 (기존 동작).
        let thumbConcurrency: Int = {
            guard aggressive else { return 1 }
            switch SystemSpec.shared.effectiveTier {
            case .low: return 2
            case .standard: return 4
            case .high: return 6
            case .extreme: return 8
            }
        }()
        var thumbsDone = 0
        var previewsDone = 0

        // 1) 썸네일 먼저 (디스크 캐시 영속)
        if thumbConcurrency > 1 {
            // 적극 모드 병렬 썸네일 생성
            let thumbQueue = OperationQueue()
            thumbQueue.maxConcurrentOperationCount = thumbConcurrency
            thumbQueue.qualityOfService = .utility
            sweepLock.lock()
            let allThumbs = pendingThumbnails
            pendingThumbnails.removeAll()
            sweepLock.unlock()
            let total = allThumbs.count
            let counter = ThumbCounter()
            for url in allThumbs {
                if let work = sweepWork, work.isCancelled { break }
                thumbQueue.addOperation {
                    if let work = self.sweepWork, work.isCancelled { return }
                    autoreleasepool {
                        _ = ThumbnailLoader.shared.generateThumbnailSync(url: url)
                    }
                    let done = counter.increment()
                    if done % 20 == 0 {
                        fputs("[SWEEP-AGG] thumbs +\(done)/\(total)\n", stderr)
                    }
                }
            }
            while thumbQueue.operationCount > 0 {
                if let work = sweepWork, work.isCancelled {
                    thumbQueue.cancelAllOperations()
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            thumbQueue.waitUntilAllOperationsAreFinished()
            thumbsDone = counter.value
        } else {
            // 기본 모드: 기존 순차 처리
            while true {
                guard let work = sweepWork, !work.isCancelled else {
                    fputs("[SWEEP] 중단 — thumbs=\(thumbsDone) previews=\(previewsDone)\n", stderr)
                    break
                }
                sweepLock.lock()
                let next = pendingThumbnails.isEmpty ? nil : pendingThumbnails.removeFirst()
                sweepLock.unlock()
                guard let url = next else { break }

                // foreground 가 바빠지면 양보 (적극 모드는 이 경로 안 탐)
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
        }

        // 2) 미리보기 — 기본: 선택 인덱스 ±N 범위 / 적극 모드: 전체
        if !(sweepWork?.isCancelled ?? true) {
            let selIdx = selectedIndexProvider?() ?? 0
            sweepLock.lock()
            let total = pendingPreviews.count
            let window: [URL]
            if aggressive {
                // 적극 모드: 전체 대상
                window = pendingPreviews
            } else {
                // v8.6.2 fix: lo/hi 를 [0, total] 범위로 clamp + lo <= hi 보장.
                //   이전엔 selIdx 가 total 보다 크면 lo > hi 가 되어 Array slice 크래시.
                let loRaw = selIdx - previewRangeAroundSelection
                let hiRaw = selIdx + previewRangeAroundSelection
                let lo = max(0, min(loRaw, total))
                let hi = max(lo, min(hiRaw, total))
                window = (total > 0 && lo < hi) ? Array(pendingPreviews[lo..<hi]) : []
            }
            sweepLock.unlock()

            // v8.8.1 fix: PhotoPreviewView.previewResolution 과 동일 파싱 로직 사용.
            //   이전 코드는 "original" → Int(nil) → 1000 fallback → cacheKey="r1000" 로 저장했는데
            //   뷰는 "original" → 0 → cacheKey="orig" 로 조회해서 스윕 캐시 전부 ORPHAN 됨.
            //   (캐시 완료 표시돼도 네비가 느리고 진행률이 99%에서 정체).
            let resStr = UserDefaults.standard.string(forKey: "previewMaxResolution") ?? "original"
            let res: Int = (resStr == "original") ? 0 : (Int(resStr) ?? 0)
            // maxPx: 0 일 때는 화면 해상도 기반 optimalPreviewSize 사용 (PhotoPreviewView 와 일치)
            let maxPx: CGFloat = res > 0 ? CGFloat(res) : PreviewImageCache.optimalPreviewSize()

            // 병렬 프리페치 — 적극 모드에선 tier 기반 대폭 증가.
            let opQueue = OperationQueue()
            let tier = SystemSpec.shared.effectiveTier
            if aggressive {
                switch tier {
                case .low: opQueue.maxConcurrentOperationCount = 2
                case .standard: opQueue.maxConcurrentOperationCount = 4
                case .high: opQueue.maxConcurrentOperationCount = 6
                case .extreme: opQueue.maxConcurrentOperationCount = 8
                }
            } else {
                opQueue.maxConcurrentOperationCount = (slowDisk || tier == .low) ? 1 : 2
            }
            opQueue.qualityOfService = .utility
            let resolveDecodeURL = self.resolveDecodeURLProvider  // capture closure
            let bust = isBusyProvider
            let notePreview = storeNotePreview

            var previewsSkipped = 0
            for url in window {
                if let work = sweepWork, work.isCancelled { break }
                // 적극 모드면 busy 체크 스킵 (캐시 빌드 우선)
                if !aggressive, bust?() ?? false { break }
                let cacheKey = res > 0 ? url.appendingPathExtension("r\(res)") : url.appendingPathExtension("orig")
                if PreviewImageCache.shared.has(cacheKey) {
                    previewsSkipped += 1
                    // v8.8.1 fix: 이미 캐시된 항목도 진행률에 반영 (이전 세션 잔존 캐시 / 뷰가 선로드한 것 포함).
                    //   이전 버전은 이들을 카운트 안 해서 진행률이 99% 에서 정체됐음.
                    notePreview?(url)
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
            self?.sweepWork = nil  // v8.8.1 fix: 다음 sweep 재진입 가능하도록 정리
            self?.sweepMessage = "sweep 완료 thumbs=\(thumbsDone) previews=\(previewsDone)"
            fputs("[SWEEP] 완료 thumbs=\(thumbsDone) previews=\(previewsDone)\n", stderr)
        }
    }
}

/// v8.8.1: 스레드 안전 카운터 — 적극 모드 병렬 썸네일 생성 진행률 집계용.
final class ThumbCounter {
    private var _value: Int = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        _value += 1
        return _value
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}
