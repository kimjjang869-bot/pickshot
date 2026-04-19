import SwiftUI
import AVKit
import AVFoundation

// MARK: - 비디오 플레이어 뷰
// AVPlayerView (NSViewRepresentable) + 커스텀 SwiftUI 컨트롤바
// HW 가속 자동 + LUT 실시간 적용 지원

struct VideoPlayerView: View {
    let url: URL
    @ObservedObject var manager = VideoPlayerManager.shared
    @State private var showControls = true
    @State private var hideTimer: DispatchWorkItem?
    @State private var isHovering = false
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            // AVPlayer 렌더링
            AVPlayerLayerView(player: manager.player)
                .background(Color.black)

            // 컨트롤바 오버레이
            if showControls || isHovering || isScrubbing {
                VStack {
                    Spacer()
                    controlBar
                        .transition(.opacity)
                }
            }

            // JKL 속도 오버레이 — 배속 표시 (x1/x2/x3/x4, 역재생 포함)
            // 1.0x 외 속도거나 JKL 역재생 중일 때 표시
            if shouldShowSpeedOverlay {
                Text(speedOverlayText)
                    .font(.system(size: 88, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: isReverse ? [.orange, .red] : [.cyan, .blue],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .black.opacity(0.6), radius: 10, y: 4)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
            // 재생 버튼은 숨김 (사용자 요구)
        }
        .onAppear {
            manager.loadVideo(url: url)
            scheduleHideControls()
        }
        .onDisappear {
            hideTimer?.cancel()
            hideTimer = nil
            manager.pause()
        }
        .onChange(of: url) { _, newURL in
            manager.loadVideo(url: newURL)
            showControls = true
            scheduleHideControls()
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                showControls = true
                scheduleHideControls()
            }
        }
        .onTapGesture {
            manager.togglePlayPause()
            showControls = true
            scheduleHideControls()
        }
    }

    // MARK: - 속도 오버레이

    private var isReverse: Bool {
        // JKL 역재생 중 (jklReverseLevel > 0) 또는 player.rate 가 음수
        manager.player.rate < 0 || (manager.playbackRate > 0 && manager.player.rate == 0 &&
                                    (manager.player.currentItem?.canPlayReverse ?? false) == false)
    }

    private var shouldShowSpeedOverlay: Bool {
        // 1x 정상 재생/정지 상태일 땐 숨김
        // 2x 이상이거나 역재생 중일 때만 표시
        let rate = abs(manager.player.rate)
        if rate > 0 && abs(rate - 1.0) > 0.01 { return true }
        // JKL 역재생 중 (rate=0 이지만 타이머로 움직이는 상태)
        if manager.playbackRate > 1 { return true }
        return false
    }

    private var speedOverlayText: String {
        let n = max(Int(round(manager.playbackRate)), 2)
        let arrow = isReverse ? "◀" : "▶"
        return "\(arrow)\(arrow) x\(n)"
    }

    // MARK: - 컨트롤바

    private var controlBar: some View {
        VStack(spacing: 8) {
            // IN/OUT 마커 상태 라인 (마커 있을 때만)
            if !manager.markers.isEmpty {
                markerStatusLine
                    .padding(.horizontal, 16)
            }

            // 시크바
            scrubber
                .padding(.horizontal, 16)

            HStack(spacing: 16) {
                // 재생/일시정지
                Button(action: { manager.togglePlayPause() }) {
                    Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // 프레임 스텝
                Button(action: { manager.stepBackward() }) {
                    Image(systemName: "backward.frame.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("이전 프레임 (←)")

                Button(action: { manager.stepForward() }) {
                    Image(systemName: "forward.frame.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("다음 프레임 (→)")

                // 시간 표시
                Text("\(manager.currentTimeText) / \(manager.durationText)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))

                Spacer()

                // 우측 컨트롤 그룹 — 여유 있는 간격
                HStack(spacing: 16) {
                    // LUT 버튼
                    lutButton

                    // 구분선
                    Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 20)

                    // 속도
                    speedMenu

                    // 구분선
                    Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 20)

                    // 볼륨
                    volumeControl
                }

            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .padding(.top, 10)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6), .black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - IN/OUT 마커 상태 라인

    private var markerStatusLine: some View {
        HStack(spacing: 10) {
            // IN
            if let i = manager.markers.inSeconds {
                Button(action: { manager.jumpToIn() }) {
                    HStack(spacing: 4) {
                        Text("IN")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                        Text(Self.format(i))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .overlay(Capsule().stroke(Color.green.opacity(0.4), lineWidth: 0.5))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("IN 포인트로 점프 (Shift+I)")
            }

            // 중간 화살표
            if manager.markers.hasRange {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }

            // OUT
            if let o = manager.markers.outSeconds {
                Button(action: { manager.jumpToOut() }) {
                    HStack(spacing: 4) {
                        Text("OUT")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                        Text(Self.format(o))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.15))
                    .overlay(Capsule().stroke(Color.red.opacity(0.4), lineWidth: 0.5))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("OUT 포인트로 점프 (Shift+O)")
            }

            // 구간 길이
            if let dur = manager.markers.duration {
                Text("· \(Self.format(dur))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
            }

            Spacer()

            // 클리어 버튼
            Button(action: { manager.clearMarkers() }) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                    Text("클리어")
                        .font(.system(size: 10))
                }
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("마커 전체 클리어 (X)")
        }
    }

    /// 초 → "m:ss.fr" 포맷 (예: 12.456 → "0:12.45")
    private static func format(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let cs = Int((seconds - floor(seconds)) * 100)
        return String(format: "%d:%02d.%02d", m, s, cs)
    }

    // MARK: - 시크바

    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = manager.progress
            let duration = max(manager.duration, 0.001)
            let inFrac = manager.markers.inSeconds.map { max(0, min(1, $0 / duration)) }
            let outFrac = manager.markers.outSeconds.map { max(0, min(1, $0 / duration)) }

            ZStack(alignment: .leading) {
                // 배경 트랙
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 6)

                // IN/OUT 구간 하이라이트 (둘 다 있을 때)
                if let i = inFrac, let o = outFrac, o > i {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.2, green: 0.85, blue: 0.4), Color(red: 0.2, green: 0.6, blue: 1.0)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(0, width * (o - i)), height: 6)
                        .offset(x: width * i)
                        .opacity(0.5)
                }

                // 진행 바
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .frame(width: max(0, width * progress), height: 6)

                // IN 마커 (초록 깃발, 오른쪽으로 펄럭)
                if let i = inFrac {
                    markerGlyph(color: Color(red: 0.2, green: 0.85, blue: 0.35), isIn: true)
                        .offset(x: max(0, min(width - 2, width * i - 1)), y: -12)
                }
                // OUT 마커 (빨간 깃발, 왼쪽으로 펄럭)
                if let o = outFrac {
                    markerGlyph(color: Color(red: 1.0, green: 0.3, blue: 0.3), isIn: false)
                        .offset(x: max(0, min(width - 2, width * o - 1)), y: -12)
                }

                // 재생 헤드 핸들 (마커 위에 표시)
                Circle()
                    .fill(Color.white)
                    .frame(width: isScrubbing ? 18 : 14, height: isScrubbing ? 18 : 14)
                    .shadow(radius: 2)
                    .offset(x: max(0, min(width - 14, width * progress - 7)))
            }
            .contentShape(Rectangle().size(width: 9999, height: 28).offset(y: -10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        let pct = max(0, min(1, value.location.x / width))
                        manager.seek(to: pct)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                    }
            )
        }
        .frame(height: 22)
    }

    /// IN 또는 OUT 마커 글리프 — 깃발 (폴대 + 삼각 깃발 + 스크러버까지 이어지는 수직선).
    /// 글리프 좌표: x=0 에 폴대가 위치, 높이 30pt (상단 깃발 12pt + 폴대 18pt)
    @ViewBuilder
    private func markerGlyph(color: Color, isIn: Bool) -> some View {
        let flagW: CGFloat = 14
        let flagH: CGFloat = 11
        let poleH: CGFloat = 28
        ZStack(alignment: .topLeading) {
            // 깃발 (폴대 꼭대기에서 isIn → 오른쪽, else → 왼쪽으로 휘날림)
            Path { p in
                if isIn {
                    // 폴대 오른쪽으로 뻗는 삼각 깃발
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: flagW, y: flagH * 0.4))
                    p.addLine(to: CGPoint(x: 0, y: flagH))
                } else {
                    // 폴대 왼쪽으로 뻗는 삼각 깃발
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: -flagW, y: flagH * 0.4))
                    p.addLine(to: CGPoint(x: 0, y: flagH))
                }
                p.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [color, color.opacity(0.75)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .shadow(color: color.opacity(0.5), radius: 2, y: 1)
            .frame(width: flagW, height: flagH, alignment: .topLeading)

            // 폴대 (수직선, 스크러버 트랙까지 닿음)
            Rectangle()
                .fill(color)
                .frame(width: 2, height: poleH)
                .offset(x: -1, y: 0)
        }
        .frame(width: 2, height: poleH, alignment: .topLeading)
    }

    // MARK: - LUT 버튼

    private var lutButton: some View {
        let isOn = manager.lutApplied
        let labelText = isOn ? "LUT" : (manager.isLOGVideo ? "LOG" : "LUT")
        // LOG = 회색, LUT 적용 = 무지개 그라데이션
        let textColor: Color = isOn ? .white : (manager.isLOGVideo ? .gray : .white.opacity(0.7))
        let bgColor: Color = isOn ? Color.white.opacity(0.12) : (manager.isLOGVideo ? Color.gray.opacity(0.15) : Color.white.opacity(0.08))

        return HStack(spacing: 0) {
            // 아이콘 클릭 → LUT 켜기/끄기 토글
            Button(action: { manager.toggleLUT() }) {
                HStack(spacing: 5) {
                    // 아이콘: LUT 적용 시 무지개, 아닐 때 회색
                    Image(systemName: "camera.filters")
                        .font(.system(size: 14))
                        .foregroundStyle(
                            isOn
                                ? AnyShapeStyle(LinearGradient(
                                    colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(manager.isLOGVideo ? Color.gray : Color.white.opacity(0.5))
                        )
                    Text(labelText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(textColor)
                }
                .padding(.leading, 10)
                .padding(.trailing, 2)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOn ? "LUT 끄기" : "LUT 켜기")

            // 드롭다운 화살표 → 메뉴 (화살표 1개만)
            Menu {
                Button(action: { loadAndApplyLUT() }) {
                    Label("LUT 파일 불러오기...", systemImage: "doc.badge.plus")
                }

                if !manager.recentLUTs.isEmpty {
                    Divider()
                    Section("최근 LUT") {
                        ForEach(Array(manager.recentLUTs.enumerated()), id: \.offset) { idx, lut in
                            Button(action: { manager.applyLUTFromFile(lut) }) {
                                let isActive = manager.activeLUT?.url == lut.url && manager.lutApplied
                                if isActive {
                                    Label(lut.name, systemImage: "checkmark")
                                } else {
                                    Text(lut.name)
                                }
                            }
                        }
                    }
                }

                if manager.lutApplied {
                    Divider()
                    Button(action: { manager.removeLUT() }) {
                        Label("LUT 제거", systemImage: "xmark.circle")
                    }
                }

                if !manager.recentLUTs.isEmpty {
                    Divider()
                    Button(action: { manager.autoApplyLUT.toggle() }) {
                        if manager.autoApplyLUT {
                            Label("LOG 자동 적용 끄기", systemImage: "checkmark.circle.fill")
                        } else {
                            Label("LOG 자동 적용 켜기", systemImage: "circle")
                        }
                    }
                    Button(action: { manager.clearRecentLUTs() }) {
                        Label("히스토리 지우기", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 10))
                    .foregroundColor(textColor.opacity(0.5))
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)  // 시스템 화살표 숨김
            .fixedSize()
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(bgColor)
        )
    }

    // MARK: - 속도 메뉴

    private var speedMenu: some View {
        Menu {
            ForEach([0.25, 0.5, 1.0, 1.5, 2.0, 4.0], id: \.self) { rate in
                Button(action: { manager.setRate(Float(rate)) }) {
                    let label = rate == 1.0 ? "보통" : "\(rate)x"
                    if abs(Double(manager.playbackRate) - rate) < 0.01 {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Text(manager.playbackRate == 1.0 ? "1x" : String(format: "%.1gx", manager.playbackRate))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - 볼륨

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Button(action: { manager.toggleMute() }) {
                Image(systemName: manager.isMuted ? "speaker.slash.fill" :
                        manager.volume > 0.5 ? "speaker.wave.2.fill" :
                        manager.volume > 0 ? "speaker.wave.1.fill" : "speaker.fill")
                    .font(.system(size: 14))
                    .foregroundColor(manager.isMuted ? .white.opacity(0.4) : .white.opacity(0.85))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Slider(value: Binding(
                get: { Double(manager.volume) },
                set: { manager.setVolume(Float($0)) }
            ), in: 0...1)
            .frame(width: 70)
            .controlSize(.small)

            // VU 미터 (좌/우 채널, 가로 방향)
            audioMeter
        }
    }

    private var audioMeter: some View {
        VStack(spacing: 2) {
            meterBar(level: CGFloat(manager.audioLevelL))
            meterBar(level: CGFloat(manager.audioLevelR))
        }
        .frame(width: 60, height: 12)
    }

    private func meterBar(level: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 배경
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.1))
                // 레벨 바 (초록 → 노랑 → 빨강 그라데이션)
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            colors: [.green, .green, .yellow, .red],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * min(level, 1.0))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }

    // MARK: - LUT 로드

    private func loadAndApplyLUT() {
        guard let lut = LUTService.openLUTFile() else { return }
        manager.applyLUTFromFile(lut)
    }

    // MARK: - 컨트롤 자동 숨기기

    private func scheduleHideControls() {
        hideTimer?.cancel()
        let work = DispatchWorkItem {
            if manager.isPlaying && !isHovering && !isScrubbing {
                withAnimation(.easeOut(duration: 0.3)) {
                    showControls = false
                }
            }
        }
        hideTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

// MARK: - AVPlayerLayer NSView 래퍼

struct AVPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? AVPlayerNSView else { return }
        view.player = player
    }

    /// CALayer 기반 AVPlayerLayer 호스팅 (가볍고 빠름)
    class AVPlayerNSView: NSView {
        var player: AVPlayer? {
            didSet {
                (layer as? AVPlayerLayer)?.player = player
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let playerLayer = AVPlayerLayer()
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer = playerLayer
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            layer?.frame = bounds
        }
    }
}
