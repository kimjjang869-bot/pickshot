import Foundation
import AVFoundation
import AVKit
import CoreImage
import AppKit
import os

// MARK: - 비디오 재생 매니저
// AVPlayer 싱글 인스턴스 재활용 + HW 디코딩 자동 + 메모리 최적화

class VideoPlayerManager: ObservableObject {
    static let shared = VideoPlayerManager()

    // MARK: - Published 상태
    @Published var isPlaying = false
    @Published var currentTime: Double = 0       // 초
    @Published var duration: Double = 0          // 초
    @Published var progress: Double = 0          // 0.0~1.0
    @Published var currentTimeText = "0:00"
    @Published var durationText = "0:00"
    @Published var isReady = false
    @Published var playbackRate: Float = 1.0
    @Published var volume: Float = 1.0
    @Published var isMuted = false
    @Published var audioLevelL: Float = 0    // 좌 채널 레벨 (0~1)
    @Published var audioLevelR: Float = 0    // 우 채널 레벨 (0~1)
    private var meterTimer: Timer?
    @Published var isLOGVideo = false             // LOG/RAW 영상 감지
    @Published var lutApplied = false             // LUT 적용 여부
    @Published var videoMetadata: VideoMetadata?

    // MARK: - LUT 히스토리
    @Published var recentLUTs: [LUTService.LUTData] = []
    @Published var activeLUT: LUTService.LUTData?   // 현재 적용 중인 LUT
    @Published var autoApplyLUT: Bool = true          // LOG 영상에 자동 적용

    // MARK: - IN/OUT 마커
    /// 현재 영상의 IN/OUT 마커 (XMP 사이드카 에 저장됨).
    @Published var markers: VideoMarkers = VideoMarkers()

    // MARK: - AVPlayer
    let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    /// v9.0.2: loadVideo 마다 추가되던 익명 observer 3개를 토큰으로 저장 → cleanup() 에서 일괄 제거.
    ///   이전엔 매 영상 재생마다 observer 3개씩 누적되어 NotificationCenter 가 점차 느려짐.
    private var failedObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    private var currentURL: URL?
    private var originalComposition: AVVideoComposition?
    private var metadataTask: Task<Void, Never>?
    private var lutTask: Task<Void, Never>?
    /// v9.1.4: 프레임 저장 detached Task 핸들 — deinit 시 cancel 보장 (보안 감사 H-5).
    private var frameSaveTask: Task<Void, Never>?

    // MARK: - 비디오 메타데이터
    struct VideoMetadata {
        var width: Int = 0
        var height: Int = 0
        var fps: Float = 0
        var duration: Double = 0
        var codec: String = ""
        var codecDescription: String = ""
        var bitrate: Float = 0        // Mbps
        var audioChannels: Int = 0
        var audioSampleRate: Double = 0
        var colorPrimaries: String?
        var transferFunction: String?
        var captureGamma: String?      // Sony CaptureGammaEquation 등 카메라 독점 메타
        var isLOG: Bool = false
        var isRAWVideo: Bool = false
        var fileSize: Int64 = 0

        var resolutionText: String {
            "\(width) × \(height)"
        }

        var fpsText: String {
            fps == Float(Int(fps)) ? "\(Int(fps))fps" : String(format: "%.2ffps", fps)
        }

        var bitrateText: String {
            bitrate > 1 ? String(format: "%.1f Mbps", bitrate) : String(format: "%.0f kbps", bitrate * 1000)
        }

        var codecBadge: String {
            if isRAWVideo { return "ProRes RAW" }
            return codecDescription
        }

        var isSlowMotion: Bool { fps >= 100 }
        var slowMoText: String? {
            if fps >= 200 { return "SUPER SLO-MO" }
            if fps >= 100 { return "SLO-MO" }
            return nil
        }
    }

    // MARK: - 초기화

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        loadRecentLUTs()

        // 재생 상태 관찰
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            DispatchQueue.main.async {
                let playing = (change.newValue ?? 0) != 0
                self?.isPlaying = playing
                if playing { self?.startAudioMeter() } else { self?.stopAudioMeter() }
            }
        }
    }

    deinit {
        cleanup()
    }

    // MARK: - 로드 & 재생

    func loadVideo(url: URL) {
        guard url != currentURL else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        plog("[Video] ▶️ loadVideo \(url.lastPathComponent)\n")
        cleanup()
        currentURL = url

        // IN/OUT 마커 XMP 사이드카에서 로드
        markers = VideoMarkerService.shared.markers(for: url)

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.volume = isMuted ? 0 : volume

        // 상태 관찰 (readyToPlay + failed 처리)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isReady = true
                    self.duration = CMTimeGetSeconds(item.duration)
                    self.durationText = Self.formatTime(CMTimeGetSeconds(item.duration))
                    let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    plog("[Video] ✅ readyToPlay \(url.lastPathComponent) dur=\(String(format: "%.1f", self.duration))s loadTime=\(ms)ms\n")
                case .failed:
                    self.isReady = false
                    let err = item.error?.localizedDescription ?? "unknown"
                    let code = (item.error as NSError?)?.code ?? 0
                    plog("[Video] ❌ 로드 실패 \(url.lastPathComponent) err=\(err) code=\(code)\n")
                case .unknown:
                    plog("[Video] ⏳ unknown status \(url.lastPathComponent)\n")
                @unknown default: break
                }
            }
        }

        // 재생 중 에러 감지 (버퍼 고갈, 디코딩 실패 등)
        // v9.0.2: 토큰 저장 — cleanup() 에서 removeObserver 가능하게.
        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { notification in
            let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            plog("[Video] ❌ 재생 중 실패: \(err?.localizedDescription ?? "unknown")\n")
        }
        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { _ in
            plog("[Video] ⚠️ 재생 정체 (버퍼 고갈 또는 디코딩 지연)\n")
        }
        errorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, let log = self.player.currentItem?.errorLog(),
                  let entry = log.events.last else { return }
            plog("[Video] ⚠️ errorLog: \(entry.errorStatusCode) \(entry.errorComment ?? "")\n")
        }

        // 재생 끝 감지 → 처음으로 리와인드
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.isPlaying = false
            self?.progress = 0
            self?.currentTime = 0
            self?.currentTimeText = "0:00"
        }

        // 주기적 시간 업데이트 (30fps)
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, let dur = self.player.currentItem?.duration,
                  dur.isNumeric, dur != .zero else { return }
            let sec = CMTimeGetSeconds(time)
            let total = CMTimeGetSeconds(dur)
            guard total > 0.001 else { return }  // 0 나누기 / 극소값 방지
            self.currentTime = sec
            self.progress = min(1.0, max(0.0, sec / total))
            self.currentTimeText = Self.formatTime(sec)
        }

        // 메타데이터 비동기 추출 (이전 Task 취소)
        metadataTask?.cancel()
        metadataTask = Task { await extractMetadata(asset: asset, url: url) }
    }

    func play() {
        // playbackRate 가 0 이면 정상 속도 1.0 으로 복원 (JKL 후 상태 보정)
        if playbackRate <= 0 { playbackRate = 1.0 }
        // JKL 역재생 타이머가 살아있으면 정지 (정방향 재생 전환)
        stopJklReverseTimer()
        jklReverseLevel = 0
        player.rate = playbackRate
    }

    func pause() {
        player.pause()
        // JKL 타이머도 함께 정지 (pause 는 모든 재생 중지)
        stopJklReverseTimer()
        jklReverseLevel = 0
    }

    func togglePlayPause() {
        // JKL 타이머가 돌고 있으면 "재생 중" 으로 간주 (rate=0 이지만 실제로 움직이는 중)
        let effectivelyPlaying = isPlaying || jklReverseLevel > 0
        effectivelyPlaying ? pause() : play()
    }

    // MARK: - 시킹 (chase-time 패턴)

    private var isSeekInProgress = false
    private var chaseTime = CMTime.zero
    /// 마지막 seek 이후 정밀 재seek 예약 (스크러빙 끝나면 정확한 위치로 보정)
    private var preciseRefineWork: DispatchWorkItem?
    /// 스크러빙 중 재생 상태 기억 (완료 후 복원)
    private var wasPlayingBeforeSeek: Bool = false
    /// 마지막 실제 seek 발사 시각 (throttle 용)
    private var lastSeekFiredAt: CFAbsoluteTime = 0
    /// 스로틀 예약 워크 (최신 chaseTime 으로 0.1초 후 seek)
    private var throttleWork: DispatchWorkItem?

    func seek(to progress: Double) {
        // 아직 준비되지 않은 item 에 seek 시도하면 FigFilePlayer err=-12860 발생
        guard isReady,
              let item = player.currentItem,
              item.status == .readyToPlay,
              item.duration.isNumeric else { return }
        let target = CMTimeMultiplyByFloat64(item.duration, multiplier: max(0, min(1, progress)))
        seekCoarse(to: target)
    }

    func seekRelative(seconds: Double) {
        guard isReady, player.currentItem?.status == .readyToPlay else { return }
        let current = player.currentTime()
        let target = CMTimeAdd(current, CMTime(seconds: seconds, preferredTimescale: 600))
        seekCoarse(to: target)
    }

    /// 통합 seek — 한 번의 정밀 seek. 튐/바운스 없음.
    /// 드래그 중에도 throttle(100ms) 로 제한하지만, 매번 정확한 위치로 이동.
    private func seekCoarse(to time: CMTime) {
        chaseTime = time

        // Throttle: 마지막 seek 이후 100ms 내면 예약만 업데이트, 실제 seek 은 지연
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastSeekFiredAt
        let throttleInterval: Double = 0.1

        if elapsed >= throttleInterval && !isSeekInProgress {
            performPreciseSeek()
            lastSeekFiredAt = now
        } else {
            throttleWork?.cancel()
            let delay = max(throttleInterval - elapsed, 0.01)
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, !self.isSeekInProgress else { return }
                self.performPreciseSeek()
                self.lastSeekFiredAt = CFAbsoluteTimeGetCurrent()
            }
            throttleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func performPreciseSeek() {
        guard player.currentItem?.status == .readyToPlay else { return }
        isSeekInProgress = true
        let target = chaseTime
        // tolerance zero → 한 번에 정확한 위치로 이동 (바운스 없음)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSeekInProgress = false
                // chaseTime 이 더 최신이면 후속 seek 필요
                if CMTimeCompare(target, self.chaseTime) != 0 {
                    let now = CFAbsoluteTimeGetCurrent()
                    let elapsed = now - self.lastSeekFiredAt
                    if elapsed >= 0.1 {
                        self.performPreciseSeek()
                        self.lastSeekFiredAt = now
                    }
                    // 아니면 throttleWork 가 곧 fire 할 것
                }
            }
        }
    }

    // refine 함수 제거됨 — performPreciseSeek 가 이미 정확한 위치로 이동하므로 보정 불필요

    // MARK: - IN/OUT 마커 조작

    /// 현재 재생 위치를 IN 포인트로 마킹.
    /// - IN 이 OUT 보다 크면 OUT 을 초기화.
    func markInAtCurrent() {
        guard let url = currentURL, isReady, duration > 0 else { return }
        let now = currentTime
        var m = markers
        m.inSeconds = now
        // in > out 이면 out 무효화
        if let o = m.outSeconds, now >= o {
            m.outSeconds = nil
        }
        markers = m
        VideoMarkerService.shared.save(m, for: url)
        NotificationCenter.default.post(name: .videoMarkersChanged, object: url)
    }

    /// 현재 재생 위치를 OUT 포인트로 마킹.
    /// - OUT 이 IN 보다 작으면 IN 을 초기화.
    func markOutAtCurrent() {
        guard let url = currentURL, isReady, duration > 0 else { return }
        let now = currentTime
        var m = markers
        m.outSeconds = now
        if let i = m.inSeconds, now <= i {
            m.inSeconds = nil
        }
        markers = m
        VideoMarkerService.shared.save(m, for: url)
        NotificationCenter.default.post(name: .videoMarkersChanged, object: url)
    }

    /// IN 포인트로 재생헤드 점프.
    func jumpToIn() {
        guard let t = markers.inSeconds, isReady, duration > 0 else { return }
        seek(to: t / duration)
    }

    /// OUT 포인트로 재생헤드 점프.
    func jumpToOut() {
        guard let t = markers.outSeconds, isReady, duration > 0 else { return }
        seek(to: t / duration)
    }

    /// 모든 마커 제거 (XMP 사이드카 삭제).
    func clearMarkers() {
        guard let url = currentURL else { return }
        markers = VideoMarkers()
        VideoMarkerService.shared.save(markers, for: url)
        NotificationCenter.default.post(name: .videoMarkersChanged, object: url)
    }

    /// IN 포인트만 제거.
    func clearInMarker() {
        guard let url = currentURL else { return }
        var m = markers
        m.inSeconds = nil
        markers = m
        VideoMarkerService.shared.save(m, for: url)
        NotificationCenter.default.post(name: .videoMarkersChanged, object: url)
    }

    /// OUT 포인트만 제거.
    func clearOutMarker() {
        guard let url = currentURL else { return }
        var m = markers
        m.outSeconds = nil
        markers = m
        VideoMarkerService.shared.save(m, for: url)
        NotificationCenter.default.post(name: .videoMarkersChanged, object: url)
    }

    // seekPrecise / performSeek 는 seekCoarse + refineToExact 로 교체됨 (위쪽 참조)

    // MARK: - 프레임 스텝

    func stepForward() {
        pause()
        player.currentItem?.step(byCount: 1)
    }

    func stepBackward() {
        pause()
        player.currentItem?.step(byCount: -1)
    }

    // MARK: - 프레임 스냅샷 내보내기

    /// 현재 재생 위치의 프레임을 JPG로 내보내기
    func exportCurrentFrame() {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        let time = player.currentTime()

        let panel = NSSavePanel()
        panel.title = "프레임 저장"
        panel.allowedContentTypes = [.jpeg, .png]
        panel.nameFieldStringValue = "frame_\(Self.formatTime(CMTimeGetSeconds(time)).replacingOccurrences(of: ":", with: "-")).jpg"

        guard panel.runModal() == .OK, let saveURL = panel.url else { return }

        // v9.1.4: Task 핸들 보존 + 이전 작업 cancel — deinit 시 누수 방지 (H-5).
        frameSaveTask?.cancel()
        frameSaveTask = Task.detached { [weak self] in
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero

            do {
                try Task.checkCancellation()
                let cgImage = try gen.copyCGImage(at: time, actualTime: nil)
                try Task.checkCancellation()
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                let ext = saveURL.pathExtension.lowercased()

                if ext == "png" {
                    guard let tiff = nsImage.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let data = rep.representation(using: .png, properties: [:]) else { return }
                    try data.write(to: saveURL)
                } else {
                    guard let tiff = nsImage.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else { return }
                    try data.write(to: saveURL)
                }
                plog("[Video] 프레임 저장 완료: \(saveURL.lastPathComponent)\n")
            } catch is CancellationError {
                plog("[Video] 프레임 저장 취소됨\n")
            } catch {
                plog("[Video] 프레임 저장 실패: \(error.localizedDescription)\n")
            }
            // 작업 종료 시 핸들 비우기 (메인에서만 접근).
            await MainActor.run { [weak self] in
                self?.frameSaveTask = nil
            }
        }
    }

    // MARK: - J/K/L 스크러빙

    /// JKL 스크러빙 — 편집 툴 표준.
    /// H.264/H.265 는 역방향 디코딩이 극히 느림 → rate 기반 대신 seek 점프로 fast reverse 구현.
    private var jklReverseTimer: DispatchSourceTimer?
    private var jklReverseLevel: Int = 0  // 1~4 단계 (J 누른 횟수)

    func jklScrub(key: Character) {
        switch key {
        case "j":
            // 역재생 — 최대 2x (3x 이상은 H.264/H.265 에서 프레임 드롭 심함)
            stopJklReverseTimer()
            jklReverseLevel = min(jklReverseLevel + 1, 2)

            // LUT composition 이 켜져있으면 역재생 중엔 임시 비활성화 (에러 폭발 + 렉 방지)
            // 사용자가 K 또는 L 누르면 복원
            if lutApplied {
                suspendLUTForJKL()
            }

            let canPlayReverseNative = player.currentItem?.canPlayReverse ?? false
            let canFastReverse = player.currentItem?.canPlayFastReverse ?? false

            // 오디오 음소거 (역재생 중 FAQ 에러 폭발 방지)
            player.isMuted = true

            if jklReverseLevel == 1 && canPlayReverseNative {
                player.rate = -1.0
            } else if jklReverseLevel == 2 && canFastReverse {
                player.rate = -2.0
            } else {
                // 네이티브 미지원 → seek 기반 micro-jump
                player.rate = 0
                startJklReverseTimer(interval: 0.06)
            }
        case "k":
            player.rate = 0
            stopJklReverseTimer()
            jklReverseLevel = 0
            // 음소거 복원 + LUT 복원
            player.isMuted = isMuted
            restoreLUTAfterJKL()
        case "l":
            stopJklReverseTimer()
            jklReverseLevel = 0
            // 음소거 복원 + LUT 복원
            player.isMuted = isMuted
            restoreLUTAfterJKL()
            let newRate = player.rate >= 0 ? player.rate + 1.0 : 1.0
            player.rate = min(newRate, 4.0)
        default: break
        }
        DispatchQueue.main.async {
            // UI 표시용: 역재생일 때 음수가 아닌 절대값 표시, 단계 정보 반영
            if self.jklReverseLevel > 0 {
                self.playbackRate = Float(self.jklReverseLevel)
            } else {
                self.playbackRate = abs(self.player.rate)
            }
        }
    }

    private func startJklReverseTimer(interval: Double) {
        // 부드러운 역재생: 작은 간격으로 작은 점프 (프레임 드롭 최소화)
        // interval 파라미터 대신 고정 60ms, 점프 거리로 속도 조절
        let tickInterval: Double = 0.06  // ~16 ticks/sec
        let jumpDistance: Double = Double(jklReverseLevel) * 0.06  // 1x=60ms, 2x=120ms, 3x=180ms, 4x=240ms jumps

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self,
                  let item = self.player.currentItem,
                  item.status == .readyToPlay,
                  !self.isSeekInProgress else { return }  // 이전 seek 완료 대기
            let current = self.player.currentTime()
            let target = CMTimeSubtract(current, CMTime(seconds: jumpDistance, preferredTimescale: 600))
            if CMTimeGetSeconds(target) < 0 {
                self.stopJklReverseTimer()
                self.jklReverseLevel = 0
                self.player.seek(to: .zero)
                return
            }
            // 작은 jump 는 tolerance 도 작게 → 키프레임 약간 벗어나도 정확도 유지
            self.isSeekInProgress = true
            self.player.seek(to: target,
                             toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                             toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600)) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isSeekInProgress = false
                }
            }
        }
        timer.resume()
        jklReverseTimer = timer
    }

    private func stopJklReverseTimer() {
        jklReverseTimer?.cancel()
        jklReverseTimer = nil
    }

    // MARK: - 속도 조절

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player.rate = rate }
    }

    func toggleMute() {
        isMuted.toggle()
        player.volume = isMuted ? 0 : volume
    }

    func setVolume(_ vol: Float) {
        volume = vol
        if !isMuted { player.volume = vol }
    }

    // MARK: - LUT 적용

    func applyLUT(_ lutData: Data, dimension: Int) {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        let expectedURL = currentURL  // stale 방지용 스냅샷

        lutTask?.cancel()
        lutTask = Task { [weak self] in
            guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let size = try? await videoTrack.load(.naturalSize)
            let fps = try? await videoTrack.load(.nominalFrameRate)

            let composition = AVMutableVideoComposition(propertiesOf: asset)
            composition.renderSize = size ?? CGSize(width: 1920, height: 1080)
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps ?? 30))
            composition.colorPrimaries = nil  // 자동
            composition.colorTransferFunction = nil
            composition.colorYCbCrMatrix = nil

            composition.customVideoCompositorClass = nil

            // CIFilter 기반 비디오 합성 (GPU 가속)
            // 주의: 콜백은 멀티스레드에서 호출됨 → CIFilter는 스레드 안전하지 않으므로
            //       매 프레임마다 새 인스턴스 생성 또는 불변 파라미터만 캡처
            let lutDim = dimension
            let lutBytes = lutData
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

            let filteredComposition = AVMutableVideoComposition(asset: asset) { request in
                guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
                    request.finish(with: request.sourceImage, context: nil)
                    return
                }
                filter.setValue(lutDim, forKey: "inputCubeDimension")
                filter.setValue(lutBytes, forKey: "inputCubeData")
                filter.setValue(colorSpace, forKey: "inputColorSpace")
                let source = request.sourceImage.clampedToExtent()
                filter.setValue(source, forKey: kCIInputImageKey)
                if let output = filter.outputImage?.cropped(to: request.sourceImage.extent) {
                    request.finish(with: output, context: nil)
                } else {
                    request.finish(with: source, context: nil)
                }
            }
            // v8.8.1 fix: AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:) 는 preferredTransform
            //   을 자동 반영한 renderSize 를 설정. 여기서 naturalSize 로 덮어쓰면 세로 4K (2160×3840) 가
            //   1920×1080 landscape frame 에 잘려 렌더링됨. 덮어쓰지 않고 인이트가 계산한 값을 그대로 사용.
            filteredComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps ?? 30))

            DispatchQueue.main.async { [weak self] in
                // stale 체크: 비디오가 바뀌었으면 적용하지 않음
                guard let self, self.currentURL == expectedURL else { return }
                item.videoComposition = filteredComposition
                self.lutApplied = true
            }
        }
    }

    /// 사용자가 명시적으로 LUT 끄기 — composition + activeLUT 둘 다 클리어.
    func removeLUT() {
        player.currentItem?.videoComposition = nil
        lutApplied = false
        activeLUT = nil
    }

    /// v9.0.2: 일반 영상으로 자동 전환 시 — composition 만 제거.
    ///   activeLUT 은 그대로 유지해야 다음 LOG 영상에서 자동 재적용됨.
    private func removeLUTCompositionOnly() {
        player.currentItem?.videoComposition = nil
        lutApplied = false
    }

    // MARK: - JKL 역재생 중 LUT 임시 보류/복원
    /// JKL 역재생 전 적용 중이던 composition 과 LUT 상태 기억
    private var _jklSuspendedComposition: AVVideoComposition?
    private var _jklSuspendedLUT: LUTService.LUTData?

    /// LUT composition 을 임시 제거 (역재생 시 seek 성능 + 에러 방지)
    private func suspendLUTForJKL() {
        guard let item = player.currentItem, item.videoComposition != nil else { return }
        _jklSuspendedComposition = item.videoComposition
        _jklSuspendedLUT = activeLUT
        item.videoComposition = nil
        // lutApplied 는 UI 상 false 로 반영하지 않음 — 사용자 관점에서 계속 적용 상태
        plog("[Video] LUT suspended (JKL reverse)\n")
    }

    /// 역재생 끝나면 LUT composition 복원
    private func restoreLUTAfterJKL() {
        guard let item = player.currentItem, let comp = _jklSuspendedComposition else { return }
        item.videoComposition = comp
        _jklSuspendedComposition = nil
        _jklSuspendedLUT = nil
        plog("[Video] LUT restored\n")
    }

    /// LUT 켜기/끄기 토글 (마지막 적용 LUT 기억)
    private var _lastLUT: LUTService.LUTData?
    func toggleLUT() {
        if lutApplied {
            _lastLUT = activeLUT
            removeLUT()
        } else if let last = _lastLUT {
            applyLUTFromFile(last)
        } else if let first = recentLUTs.first {
            applyLUTFromFile(first)
        }
    }

    /// LUT 적용 + 히스토리에 추가
    func applyLUTFromFile(_ lut: LUTService.LUTData) {
        activeLUT = lut
        addToRecentLUTs(lut)
        applyLUT(lut.data, dimension: lut.dimension)
    }

    // MARK: - LUT 히스토리 관리

    private static let maxRecentLUTs = 10
    private static let recentLUTsKey = "recentLUTURLs"

    private func addToRecentLUTs(_ lut: LUTService.LUTData) {
        // 중복 제거 후 맨 앞에 추가
        recentLUTs.removeAll { $0.url == lut.url }
        recentLUTs.insert(lut, at: 0)
        if recentLUTs.count > Self.maxRecentLUTs {
            recentLUTs = Array(recentLUTs.prefix(Self.maxRecentLUTs))
        }
        saveRecentLUTs()
    }

    private func saveRecentLUTs() {
        let urls = recentLUTs.map { $0.url.path }
        UserDefaults.standard.set(urls, forKey: Self.recentLUTsKey)
        SandboxBookmarkService.saveBookmarks(for: recentLUTs.map { $0.url }, keyPrefix: "recentLUTs")
    }

    private func loadRecentLUTs() {
        // Try security-scoped bookmarks first (App Sandbox)
        let bookmarkedURLs = SandboxBookmarkService.resolveBookmarks(keyPrefix: "recentLUTs")
        if !bookmarkedURLs.isEmpty {
            var loaded: [LUTService.LUTData] = []
            for url in bookmarkedURLs.prefix(3) {
                guard let lut = LUTService.parseLUT(url: url) else { continue }
                loaded.append(lut)
            }
            recentLUTs = loaded
            activeLUT = loaded.first
            return
        }
        // Fallback to path strings (backward compat)
        guard let paths = UserDefaults.standard.stringArray(forKey: Self.recentLUTsKey) else { return }
        var loaded: [LUTService.LUTData] = []
        for path in paths.prefix(3) {  // 초기화 시 최대 3개만 파싱 (메모리/속도)
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path),
                  let lut = LUTService.parseLUT(url: url) else { continue }
            loaded.append(lut)
        }
        recentLUTs = loaded
        activeLUT = loaded.first
        // stale 경로 정리
        if loaded.count < paths.count { saveRecentLUTs() }
    }

    func removeFromRecentLUTs(at index: Int) {
        guard index >= 0, index < recentLUTs.count else { return }
        let removed = recentLUTs.remove(at: index)
        if activeLUT?.url == removed.url { activeLUT = nil }
        saveRecentLUTs()
    }

    func clearRecentLUTs() {
        recentLUTs.removeAll()
        activeLUT = nil
        saveRecentLUTs()
    }

    // MARK: - 메타데이터 추출

    @MainActor
    private func extractMetadata(asset: AVURLAsset, url: URL) async {
        var meta = VideoMetadata()

        // 파일 크기
        meta.fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        // Duration
        if let dur = try? await asset.load(.duration) {
            meta.duration = CMTimeGetSeconds(dur)
        }

        // 비디오 트랙
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize) {
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let corrected = size.applying(transform)
                meta.width = Int(abs(corrected.width))
                meta.height = Int(abs(corrected.height))
            }
            if let fps = try? await track.load(.nominalFrameRate) {
                meta.fps = fps
            }
            if let rate = try? await track.load(.estimatedDataRate) {
                meta.bitrate = rate / 1_000_000  // Mbps
            }

            // 코덱 감지
            if let descs = try? await track.load(.formatDescriptions),
               let desc = descs.first,
               let cmDesc = desc as? CMFormatDescription {
                let subType = CMFormatDescriptionGetMediaSubType(cmDesc)
                meta.codec = fourCC(subType)
                meta.codecDescription = codecName(subType)

                // LOG/RAW 감지: color primaries & transfer function
                if let ext = CMFormatDescriptionGetExtensions(cmDesc) as? [String: Any] {
                    meta.colorPrimaries = ext["ColorPrimaries"] as? String
                    meta.transferFunction = ext["TransferFunction"] as? String
                }
            }
        }

        // 오디오 트랙
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let descs = try? await audioTrack.load(.formatDescriptions),
           let desc = descs.first,
           let audioDesc = desc as? CMAudioFormatDescription {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioDesc) {
                meta.audioChannels = Int(asbd.pointee.mChannelsPerFrame)
                meta.audioSampleRate = asbd.pointee.mSampleRate
            }
        }

        // Sony/Canon/Panasonic 독점 XML 메타데이터에서 감마 정보 추출
        meta.captureGamma = await extractCaptureGamma(asset: asset)

        // LOG 감지
        meta.isLOG = detectLOGProfile(meta: meta, url: url)
        meta.isRAWVideo = detectRAWVideo(meta: meta)

        // 디버그 로그 — LOG 감지 실패 시 어떤 정보가 있었는지 확인용
        fputs("[LUT detect] \(url.lastPathComponent) codec=\(meta.codec) " +
              "primaries=\(meta.colorPrimaries ?? "-") " +
              "transfer=\(meta.transferFunction ?? "-") " +
              "gamma=\(meta.captureGamma ?? "-") " +
              "bitrate=\(Int(meta.bitrate))Mbps " +
              "→ isLOG=\(meta.isLOG) isRAW=\(meta.isRAWVideo)\n", stderr)

        self.videoMetadata = meta
        let isLOGish = meta.isLOG || meta.isRAWVideo
        self.isLOGVideo = isLOGish

        // LOG 자동 LUT 토글:
        //  - LOG/RAW 영상 → 저장된 activeLUT 있으면 자동 ON
        //  - 일반 영상 → autoApplyLUT 활성화 상태면 LUT 자동 OFF
        if autoApplyLUT {
            if isLOGish, let lut = activeLUT {
                if !lutApplied {
                    plog("[LUT] LOG 영상 감지 → LUT 자동 적용: \(lut.name)\n")
                    applyLUT(lut.data, dimension: lut.dimension)
                }
            } else if !isLOGish && lutApplied {
                // 일반 영상으로 전환 → composition 만 끄고 activeLUT 은 유지 (다음 LOG 영상 재적용 위해).
                plog("[LUT] 일반 영상 감지 → LUT 자동 해제 (activeLUT 유지)\n")
                removeLUTCompositionOnly()
            }
        }
    }

    /// LOG 프로파일 감지 (S-Log, C-Log, V-Log, N-Log, F-Log 등)
    /// Sony S-Log는 CMFormatDescription에 BT.709으로 태깅되므로
    /// 독점 XML 메타데이터 (CaptureGammaEquation)도 반드시 확인
    private func detectLOGProfile(meta: VideoMetadata, url: URL) -> Bool {
        // 1) 카메라 독점 메타데이터에서 감마 정보 (가장 신뢰도 높음)
        if let gamma = meta.captureGamma?.lowercased() {
            let logGammas = ["s-log", "slog", "c-log", "clog", "v-log", "vlog",
                             "n-log", "nlog", "f-log", "flog", "log-c", "logc",
                             "log3g", "redlog", "red log", "bmdfilm", "davinci",
                             "arri log", "alexa log"]
            if logGammas.contains(where: { gamma.contains($0) }) { return true }
            // S-Gamut 계열은 반드시 LOG와 함께 사용
            if gamma.contains("s-gamut") || gamma.contains("sgamut") { return true }
        }

        // 2) 파일명 기반 감지
        let fileName = url.lastPathComponent.uppercased()
        let logPatterns = ["SLOG", "S-LOG", "CLOG", "C-LOG", "VLOG", "V-LOG",
                           "NLOG", "N-LOG", "FLOG", "F-LOG", "LOG-C", "LOGC",
                           "DLOG", "D-LOG", "DLOGM", "D-LOG-M",
                           "BRAW", "BMPCC", "RED", "ARRI"]
        if logPatterns.contains(where: { fileName.contains($0) }) { return true }

        // Sony XAVC 네이밍 패턴 (C####.MP4) — FX3/FX6/α7S III/α1 등
        // C0001~C9999.MP4 또는 Cxxxx.MXF 규약 (Sony SxS/XQD/CFexpress)
        // 이 경우 대부분 XAVC-S 10bit 또는 XAVC HS 로 S-Log3 가능성 매우 높음
        if fileName.range(of: #"^C\d{4}\.(MP4|MXF)$"#, options: .regularExpression) != nil {
            // Sony XAVC 클립 + 10bit 이상 (bitrate > 40Mbps) → S-Log3/HLG 강력 추정
            if meta.bitrate > 40 { return true }
        }

        // v8.8.1: Panasonic / DJI / 기타 Mxx_#### 클립 네이밍 + 고비트레이트 → LOG 강력 추정.
        //   예: Panasonic S5M2 = "M51_0280.MP4" (V-Log), DJI Ronin 4D 일부 모델, Lumix 라인업.
        //   transfer function/gamma 메타데이터가 없어도 80Mbps 이상이면 flat/LOG 프로파일 가능성 매우 높음.
        if fileName.range(of: #"^M\d{2,3}_\d{4}\.(MP4|MOV)$"#, options: .regularExpression) != nil {
            if meta.bitrate > 60 { return true }
        }
        // DJI 파일명 패턴 (DJI_xxxxxxxx.MP4)
        if fileName.hasPrefix("DJI_") && meta.bitrate > 60 { return true }

        // 3) 폴더명 기반 감지 (카메라에서 복사 시 폴더명에 LOG 포함)
        let parentFolder = url.deletingLastPathComponent().lastPathComponent.uppercased()
        if logPatterns.contains(where: { parentFolder.contains($0) }) { return true }

        // 4) Transfer function 기반 감지
        if let tf = meta.transferFunction?.lowercased() {
            let logTransfers = ["log", "hlg", "pq", "smpte2084", "smpte_st_2084",
                                "arib-std-b67", "itu_r_2100_hlg", "itu_r_2100_pq",
                                "apple-log", "linear"]
            if logTransfers.contains(where: { tf.contains($0) }) { return true }
        }

        // 5) Color primaries 기반 감지 (wide gamut = 보통 LOG)
        if let cp = meta.colorPrimaries?.lowercased() {
            if cp.contains("2020") || cp.contains("p3") || cp.contains("dci") { return true }
        }

        // 6) ProRes 4444 이상은 보통 LOG/RAW
        if meta.codec == "ap4h" || meta.codec == "ap4x" { return true }

        // 7) Sony XAVC S 파일 구조 감지
        let path = url.path.uppercased()
        if path.contains("M4ROOT") || path.contains("CLIP") || path.contains("PRIVATE") {
            if meta.bitrate > 50 { return true }
        }

        // 8) 고비트레이트 HEVC 10bit + 넓은 색역 → LOG 강력 추정
        // HEVC Main10 에서 S-Log3 는 보통 100Mbps+
        if (meta.codec == "hvc1" || meta.codec == "hev1") && meta.bitrate > 80 {
            return true
        }

        return false
    }

    /// RAW 비디오 감지 (ProRes RAW, CinemaDNG 등)
    private func detectRAWVideo(meta: VideoMetadata) -> Bool {
        let rawCodecs = ["aprn", "aprh"]  // ProRes RAW, ProRes RAW HQ
        return rawCodecs.contains(meta.codec.lowercased())
    }

    /// Sony/Canon/Panasonic 카메라 독점 메타데이터에서 감마/색역 정보 추출
    private func extractCaptureGamma(asset: AVURLAsset) async -> String? {
        // 1. Asset 레벨 metadata (Sony MXF/XAVC 는 주로 여기에)
        let assetMeta = (try? await asset.load(.metadata)) ?? []
        // 2. Video track 레벨 metadata (일부 Sony MP4 는 트랙에만 있음)
        var trackMeta: [AVMetadataItem] = []
        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            trackMeta = (try? await videoTrack.load(.metadata)) ?? []
        }
        let metadata = assetMeta + trackMeta

        for item in metadata {
            guard let value = try? await item.load(.value) as? String else { continue }
            let valueLower = value.lowercased()

            // Sony: CaptureGammaEquation (e.g., "s-gamut3.cine/s-log3", "s-log2")
            // Canon: GammaProfile
            // Panasonic: GammaTable
            if let key = item.key as? String {
                let keyLower = key.lowercased()
                if keyLower.contains("gamma") || keyLower.contains("gamut") ||
                   keyLower.contains("colorprofile") || keyLower.contains("pictureprofile") ||
                   keyLower.contains("creativelook") || keyLower.contains("picprofile") {
                    if valueLower.contains("log") || valueLower.contains("gamut") ||
                       valueLower.contains("film") || valueLower.contains("flat") ||
                       valueLower.contains("cine") || valueLower.contains("hlg") {
                        return value
                    }
                }
            }

            // 일반 identifier 기반 검색
            if let id = item.identifier {
                let idStr = id.rawValue.lowercased()
                if idStr.contains("gamma") || idStr.contains("gamut") || idStr.contains("color") ||
                   idStr.contains("profile") {
                    if valueLower.contains("log") || valueLower.contains("gamut") ||
                       valueLower.contains("film") || valueLower.contains("flat") ||
                       valueLower.contains("cine") {
                        return value
                    }
                }
            }

            // 값 자체에 log 문자열 들어있으면 — 키 무관하게 감지
            if valueLower.contains("s-log") || valueLower.contains("slog") ||
               valueLower.contains("c-log") || valueLower.contains("clog") ||
               valueLower.contains("v-log") || valueLower.contains("vlog") ||
               valueLower.contains("n-log") || valueLower.contains("f-log") ||
               valueLower.contains("log-c") || valueLower.contains("s-gamut") {
                return value
            }
        }

        // CommonMetadata에서도 검색
        guard let commonMeta = try? await asset.load(.commonMetadata) else { return nil }
        for item in commonMeta {
            guard let value = try? await item.load(.value) as? String else { continue }
            let valueLower = value.lowercased()
            if valueLower.contains("s-log") || valueLower.contains("slog") ||
               valueLower.contains("c-log") || valueLower.contains("clog") ||
               valueLower.contains("v-log") || valueLower.contains("vlog") ||
               valueLower.contains("n-log") || valueLower.contains("f-log") ||
               valueLower.contains("log-c") || valueLower.contains("s-gamut") {
                return value
            }
        }

        return nil
    }

    // MARK: - 정리

    func cleanup() {
        metadataTask?.cancel()
        metadataTask = nil
        lutTask?.cancel()
        lutTask = nil
        // v9.1.4: detached frame save task 도 cleanup 에서 cancel (H-5)
        frameSaveTask?.cancel()
        frameSaveTask = nil
        // seek refine / throttle / JKL 역재생 timer 정리
        preciseRefineWork?.cancel()
        preciseRefineWork = nil
        throttleWork?.cancel()
        throttleWork = nil
        stopJklReverseTimer()
        jklReverseLevel = 0
        wasPlayingBeforeSeek = false
        isSeekInProgress = false
        lastSeekFiredAt = 0
        _jklSuspendedComposition = nil
        _jklSuspendedLUT = nil
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        // v9.0.2: 누적 누수 픽스 — loadVideo 에서 추가한 3개 observer 도 제거.
        if let obs = failedObserver {
            NotificationCenter.default.removeObserver(obs)
            failedObserver = nil
        }
        if let obs = stalledObserver {
            NotificationCenter.default.removeObserver(obs)
            stalledObserver = nil
        }
        if let obs = errorLogObserver {
            NotificationCenter.default.removeObserver(obs)
            errorLogObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)

        currentURL = nil
        isReady = false
        isPlaying = false
        currentTime = 0
        duration = 0
        progress = 0
        currentTimeText = "0:00"
        durationText = "0:00"
        lutApplied = false
        isLOGVideo = false
        videoMetadata = nil
        stopAudioMeter()
    }

    // MARK: - Audio Metering

    private func startAudioMeter() {
        guard meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            let vol = self.isMuted ? Float(0) : self.volume
            // 자연스러운 VU 미터 시뮬레이션: 볼륨 기반 + 미세 변동
            let base = vol * 0.7
            let noise = Float.random(in: -0.15...0.15)
            let targetL = min(1.0, max(0, base + noise + Float.random(in: 0...0.1)))
            let targetR = min(1.0, max(0, base + noise + Float.random(in: 0...0.1)))
            // 스무딩 (빠른 attack, 느린 release)
            let attackL = targetL > self.audioLevelL ? Float(0.6) : Float(0.15)
            let attackR = targetR > self.audioLevelR ? Float(0.6) : Float(0.15)
            DispatchQueue.main.async {
                self.audioLevelL += (targetL - self.audioLevelL) * attackL
                self.audioLevelR += (targetR - self.audioLevelR) * attackR
            }
        }
    }

    private func stopAudioMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        DispatchQueue.main.async {
            self.audioLevelL = 0
            self.audioLevelR = 0
        }
    }

    // MARK: - 유틸리티

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "unknown"
    }

    private func codecName(_ code: FourCharCode) -> String {
        switch code {
        case 0x61766331: return "H.264"       // 'avc1'
        case 0x68766331: return "HEVC"        // 'hvc1'
        case 0x68657631: return "HEVC"        // 'hev1'
        case 0x76703039: return "VP9"         // 'vp09'
        case 0x61763031: return "AV1"         // 'av01'
        case 0x61706368: return "ProRes 422 HQ"
        case 0x61706373: return "ProRes 422"
        case 0x6170636e: return "ProRes 422 LT"
        case 0x6170636f: return "ProRes 422 Proxy"
        case 0x61703468: return "ProRes 4444"
        case 0x61703478: return "ProRes 4444 XQ"
        case 0x6170726e: return "ProRes RAW"
        case 0x61707268: return "ProRes RAW HQ"
        default: return fourCC(code).uppercased()
        }
    }
}
