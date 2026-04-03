import SwiftUI

// MARK: - Transition Effect Enum

enum SlideshowTransition: String, CaseIterable {
    case fade = "페이드"
    case slide = "슬라이드"
    case zoom = "확대/축소"
    case dissolve = "디졸브"

    var icon: String {
        switch self {
        case .fade: return "circle.lefthalf.filled"
        case .slide: return "rectangle.righthalf.inset.filled.arrow.right"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        case .dissolve: return "sparkles"
        }
    }
}

struct SlideshowView: View {
    let photos: [PhotoItem]
    let interval: Double
    @Environment(\.dismiss) var dismiss

    @State private var currentIndex = 0
    @State private var image: NSImage?
    @State private var isPlaying = true
    @State private var timer: Timer?
    @State private var transition: SlideshowTransition = .fade
    @State private var imageID = UUID()
    @State private var showControls = true
    @State private var controlsTimer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Image with transition
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .id(imageID)
                    .transition(currentTransition)
            }

            // Controls overlay
            if showControls {
                VStack {
                    // Top bar
                    HStack {
                        Text("\(currentIndex + 1) / \(photos.count)")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)

                        if !photos.isEmpty && currentIndex < photos.count {
                            Text(photos[currentIndex].fileName)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                        }

                        Spacer()

                        // Transition picker
                        Menu {
                            ForEach(SlideshowTransition.allCases, id: \.self) { t in
                                Button(action: { transition = t }) {
                                    HStack {
                                        Image(systemName: t.icon)
                                        Text(t.rawValue)
                                        if transition == t {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: transition.icon)
                                Text(transition.rawValue)
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(16)
                    .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))

                    Spacer()

                    // Bottom controls
                    HStack(spacing: 20) {
                        Button(action: { goTo(currentIndex - 1) }) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)

                        Button(action: { togglePlay() }) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)

                        Button(action: { goTo(currentIndex + 1) }) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(16)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                }
                .transition(.opacity)
            }

            // Progress bar
            VStack {
                Spacer()
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(
                            width: photos.isEmpty ? 0 : geo.size.width * CGFloat(currentIndex + 1) / CGFloat(photos.count),
                            height: 2
                        )
                }
                .frame(height: 2)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            loadImage(at: 0)
            startTimer()
            startControlsAutoHide()
        }
        .onDisappear { stopTimer(); controlsTimer?.invalidate() }
        .onHover { _ in
            showControls = true
            startControlsAutoHide()
        }
    }

    // MARK: - Transition

    private var currentTransition: AnyTransition {
        switch transition {
        case .fade:
            return .opacity
        case .slide:
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )
        case .zoom:
            return .asymmetric(
                insertion: .scale(scale: 1.2).combined(with: .opacity),
                removal: .scale(scale: 0.8).combined(with: .opacity)
            )
        case .dissolve:
            return .opacity.combined(with: .scale(scale: 1.02))
        }
    }

    private func goTo(_ index: Int) {
        guard !photos.isEmpty else { return }
        let newIndex = (index + photos.count) % photos.count

        // Pre-load new image
        let url = photos[newIndex].jpgURL
        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async {
                let duration: Double
                switch transition {
                case .fade: duration = 0.5
                case .slide: duration = 0.4
                case .zoom: duration = 0.6
                case .dissolve: duration = 0.8
                }

                withAnimation(.easeInOut(duration: duration)) {
                    currentIndex = newIndex
                    image = img
                    imageID = UUID()
                }
            }
        }
    }

    private func togglePlay() {
        isPlaying.toggle()
        if isPlaying { startTimer() } else { stopTimer() }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            goTo(currentIndex + 1)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func loadImage(at index: Int) {
        guard index >= 0 && index < photos.count else { return }
        let url = photos[index].jpgURL
        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async {
                image = img
                imageID = UUID()
            }
        }
    }

    private func startControlsAutoHide() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            if isPlaying {
                withAnimation(.easeOut(duration: 0.3)) {
                    showControls = false
                }
            }
        }
    }
}
