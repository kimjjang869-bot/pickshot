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

    // MARK: - AVPlayer
    let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var currentURL: URL?
    private var originalComposition: AVVideoComposition?
    private var metadataTask: Task<Void, Never>?
    private var lutTask: Task<Void, Never>?

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
        cleanup()
        currentURL = url

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
                case .failed:
                    self.isReady = false
                    fputs("[Video] 로드 실패: \(item.error?.localizedDescription ?? "unknown")\n", stderr)
                default: break
                }
            }
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
        player.rate = playbackRate
    }

    func pause() {
        player.pause()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    // MARK: - 시킹 (chase-time 패턴)

    private var isSeekInProgress = false
    private var chaseTime = CMTime.zero

    func seek(to progress: Double) {
        guard let dur = player.currentItem?.duration, dur.isNumeric else { return }
        let target = CMTimeMultiplyByFloat64(dur, multiplier: max(0, min(1, progress)))
        seekPrecise(to: target)
    }

    func seekRelative(seconds: Double) {
        let current = player.currentTime()
        let target = CMTimeAdd(current, CMTime(seconds: seconds, preferredTimescale: 600))
        seekPrecise(to: target)
    }

    private func seekPrecise(to time: CMTime) {
        chaseTime = time
        if !isSeekInProgress {
            performSeek()
        }
    }

    private func performSeek() {
        guard player.currentItem?.status == .readyToPlay else { return }
        isSeekInProgress = true
        let target = chaseTime
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if CMTimeCompare(target, self.chaseTime) == 0 {
                    self.isSeekInProgress = false
                } else {
                    self.performSeek()
                }
            }
        }
    }

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

        Task.detached {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero

            do {
                let cgImage = try gen.copyCGImage(at: time, actualTime: nil)
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
                fputs("[Video] 프레임 저장 완료: \(saveURL.lastPathComponent)\n", stderr)
            } catch {
                fputs("[Video] 프레임 저장 실패: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    // MARK: - J/K/L 스크러빙

    func jklScrub(key: Character) {
        switch key {
        case "j":
            let newRate = player.rate <= 0 ? player.rate - 1.0 : -1.0
            player.rate = max(newRate, -4.0)
        case "k":
            player.rate = 0
        case "l":
            let newRate = player.rate >= 0 ? player.rate + 1.0 : 1.0
            player.rate = min(newRate, 4.0)
        default: break
        }
        DispatchQueue.main.async {
            self.playbackRate = abs(self.player.rate)
        }
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
            filteredComposition.renderSize = size ?? CGSize(width: 1920, height: 1080)
            filteredComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps ?? 30))

            DispatchQueue.main.async { [weak self] in
                // stale 체크: 비디오가 바뀌었으면 적용하지 않음
                guard let self, self.currentURL == expectedURL else { return }
                item.videoComposition = filteredComposition
                self.lutApplied = true
            }
        }
    }

    func removeLUT() {
        player.currentItem?.videoComposition = nil
        lutApplied = false
        activeLUT = nil
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
    }

    private func loadRecentLUTs() {
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

        self.videoMetadata = meta
        self.isLOGVideo = meta.isLOG || meta.isRAWVideo

        // LOG 영상 + 저장된 LUT 있으면 자동 적용
        if (meta.isLOG || meta.isRAWVideo) && autoApplyLUT, let lut = activeLUT {
            applyLUT(lut.data, dimension: lut.dimension)
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
                           "BRAW", "BMPCC", "RED", "ARRI"]
        if logPatterns.contains(where: { fileName.contains($0) }) { return true }

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

        // 7) Sony XAVC S 파일 구조 감지: 파일 경로에 PRIVATE/M4ROOT 포함 (Sony 카메라 폴더 구조)
        let path = url.path.uppercased()
        if path.contains("M4ROOT") || path.contains("CLIP") {
            // Sony 카메라 폴더 구조 → PP 설정에 따라 LOG일 수 있음
            // 10bit 이상이면 LOG 가능성 높음
            if meta.bitrate > 50 { return true }  // 고비트레이트 = LOG 가능성
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
        guard let metadata = try? await asset.load(.metadata) else { return nil }

        for item in metadata {
            guard let value = try? await item.load(.value) as? String else { continue }
            let valueLower = value.lowercased()

            // Sony: CaptureGammaEquation (e.g., "s-gamut3.cine/s-log3", "s-log2")
            // Canon: GammaProfile
            // Panasonic: GammaTable
            if let key = item.key as? String {
                let keyLower = key.lowercased()
                if keyLower.contains("gamma") || keyLower.contains("gamut") ||
                   keyLower.contains("colorprofile") || keyLower.contains("pictureprofile") {
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
                if idStr.contains("gamma") || idStr.contains("gamut") || idStr.contains("color") {
                    if valueLower.contains("log") || valueLower.contains("gamut") ||
                       valueLower.contains("film") || valueLower.contains("flat") ||
                       valueLower.contains("cine") {
                        return value
                    }
                }
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
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
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
