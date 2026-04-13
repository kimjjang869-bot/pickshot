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

            // 재생/일시정지 중앙 인디케이터
            if !manager.isPlaying && manager.isReady && !isScrubbing {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 72))
                    .foregroundColor(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.4), radius: 8)
                    .allowsHitTesting(false)
            }
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
        .onChange(of: url) { newURL in
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

    // MARK: - 컨트롤바

    private var controlBar: some View {
        VStack(spacing: 8) {
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

                // LUT 버튼 (항상 표시, LOG 감지 시 강조)
                lutButton

                // 속도
                speedMenu

                // 볼륨
                volumeControl

            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
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

    // MARK: - 시크바

    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = manager.progress

            ZStack(alignment: .leading) {
                // 배경 트랙
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 6)

                // 진행 바
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .frame(width: max(0, width * progress), height: 6)

                // 핸들
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

    // MARK: - LUT 버튼

    private var lutButton: some View {
        let labelText = manager.lutApplied ? "LUT" : (manager.isLOGVideo ? "LOG" : "LUT")
        let labelColor: Color = manager.lutApplied ? .orange : (manager.isLOGVideo ? .yellow : .white.opacity(0.7))
        let bgColor: Color = manager.lutApplied ? Color.orange.opacity(0.2) : (manager.isLOGVideo ? Color.yellow.opacity(0.15) : Color.white.opacity(0.08))

        return Menu {
            // 새 LUT 불러오기
            Button(action: { loadAndApplyLUT() }) {
                Label("LUT 파일 불러오기...", systemImage: "doc.badge.plus")
            }

            // 최근 사용한 LUT 목록
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

            // LOG 자동 적용 토글
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
            HStack(spacing: 4) {
                Image(systemName: "camera.filters")
                    .font(.system(size: 14))
                Text(labelText)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(labelColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(bgColor)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
                Image(systemName: manager.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Slider(value: Binding(
                get: { Double(manager.volume) },
                set: { manager.setVolume(Float($0)) }
            ), in: 0...1)
            .frame(width: 75)
            .controlSize(.small)
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
