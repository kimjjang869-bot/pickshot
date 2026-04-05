import SwiftUI

struct CompareView: View {
    @ObservedObject var store: PhotoStore
    @State private var currentPhotos: [PhotoItem]
    private let compareCount: Int
    @Environment(\.dismiss) var dismiss
    @State private var syncScale: CGFloat = 1.0
    @State private var syncOffset: CGPoint = .zero
    @State private var dragStart: CGPoint = .zero
    @State private var isSynced: Bool = true

    init(photoA: PhotoItem, photoB: PhotoItem, store: PhotoStore) {
        self.store = store
        let photos = [photoA, photoB]
        self._currentPhotos = State(initialValue: photos)
        self.compareCount = 2
    }

    init(photos: [PhotoItem], store: PhotoStore) {
        self.store = store
        let p = Array(photos.prefix(4))
        self._currentPhotos = State(initialValue: p)
        self.compareCount = p.count
    }

    var photos: [PhotoItem] { currentPhotos }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("사진 비교 (\(photos.count)장)")
                    .font(.system(size: 14, weight: .bold))

                Spacer()

                // Sync toggle
                Toggle(isOn: $isSynced) {
                    HStack(spacing: 3) {
                        Image(systemName: isSynced ? "lock.fill" : "lock.open")
                            .font(.system(size: 10))
                        Text("동기화")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                // Zoom controls
                HStack(spacing: 6) {
                    Button(action: { zoomOut() }) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)

                    Text("\(Int(syncScale * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 45)

                    Button(action: { zoomIn() }) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)

                    Button(action: { resetZoom() }) {
                        Text("맞춤")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(4)
                }

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)
            }
            .padding(12)

            Divider()

            // Side by side (2-4 photos)
            GeometryReader { geo in
                let panelCount = photos.count
                let useGrid = panelCount > 2

                if useGrid {
                    // 2x2 grid for 3-4 photos
                    let cols = 2
                    let rows = (panelCount + 1) / 2
                    let panelW = geo.size.width / CGFloat(cols) - 1
                    let panelH = geo.size.height / CGFloat(rows) - 1

                    VStack(spacing: 1) {
                        ForEach(0..<rows, id: \.self) { row in
                            HStack(spacing: 1) {
                                ForEach(0..<cols, id: \.self) { col in
                                    let idx = row * cols + col
                                    if idx < photos.count {
                                        comparePanel(
                                            photo: photos[idx],
                                            panelSize: CGSize(width: panelW, height: panelH)
                                        )
                                    } else {
                                        Color.clear
                                            .frame(width: panelW, height: panelH)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // Side-by-side for 2 photos
                    HStack(spacing: 1) {
                        ForEach(0..<panelCount, id: \.self) { idx in
                            comparePanel(
                                photo: photos[idx],
                                panelSize: CGSize(
                                    width: geo.size.width / CGFloat(panelCount) - 1,
                                    height: geo.size.height
                                )
                            )
                            if idx < panelCount - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 900, idealWidth: 1400, minHeight: 600, idealHeight: 900)
        .onExitCommand { dismiss() }
        .background(CompareKeyHandler(onLeft: { cyclePhotos(direction: -1) }, onRight: { cyclePhotos(direction: 1) }))
    }

    private func cyclePhotos(direction: Int) {
        let all = store.filteredPhotos
        guard all.count > compareCount else { return }
        guard let firstID = currentPhotos.first?.id,
              let firstIdx = all.firstIndex(where: { $0.id == firstID }) else { return }
        let newStart = (firstIdx + direction + all.count) % all.count
        var newPhotos: [PhotoItem] = []
        for i in 0..<compareCount {
            let idx = (newStart + i) % all.count
            newPhotos.append(all[idx])
        }
        currentPhotos = newPhotos
        syncScale = 1.0
        syncOffset = .zero
        dragStart = .zero
    }

    private func comparePanel(photo: PhotoItem, panelSize: CGSize) -> some View {
        VStack(spacing: 0) {
            // Image with synchronized zoom/pan
            SyncedCompareImage(
                url: photo.jpgURL,
                panelSize: panelSize,
                syncScale: $syncScale,
                syncOffset: $syncOffset,
                dragStart: $dragStart,
                isSynced: isSynced
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Info bar
            VStack(spacing: 4) {
                Text(photo.fileName)
                    .font(.system(size: 12, weight: .medium))

                HStack(spacing: 8) {
                    if let exif = photo.exifData {
                        if let iso = exif.iso {
                            Text("ISO \(iso)")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        if let shutter = exif.shutterSpeed {
                            Text(shutter)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        if let aperture = exif.aperture {
                            Text("f/\(String(format: "%.1f", aperture))")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        if let focal = exif.focalLength {
                            Text("\(Int(focal))mm")
                                .font(.system(size: 10, design: .monospaced))
                        }
                    }
                }
                .foregroundColor(.secondary)

                // Rating
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= photo.rating ? "star.fill" : "star")
                            .font(.system(size: 10))
                            .foregroundColor(star <= photo.rating ? .yellow : .gray.opacity(0.3))
                    }
                }

                // Quality + Scene tag
                HStack(spacing: 6) {
                    if let quality = photo.quality, quality.isAnalyzed {
                        Text(quality.overallGrade.rawValue)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(gradeColor(quality.overallGrade))
                            .cornerRadius(4)
                    }
                    if let tag = photo.sceneTag {
                        Text(tag)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.7))
                            .cornerRadius(4)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func gradeColor(_ grade: QualityAnalysis.Grade) -> Color {
        switch grade {
        case .excellent: return .green
        case .good: return .blue
        case .average: return .yellow
        case .belowAverage: return .orange
        case .poor: return .red
        }
    }

    private func zoomIn() {
        let steps: [CGFloat] = [0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0]
        if let next = steps.first(where: { $0 > syncScale + 0.01 }) {
            syncScale = next
        }
    }

    private func zoomOut() {
        let steps: [CGFloat] = [0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0]
        if let prev = steps.last(where: { $0 < syncScale - 0.01 }) {
            syncScale = prev
            syncOffset = .zero
            dragStart = .zero
        }
    }

    private func resetZoom() {
        syncScale = 1.0
        syncOffset = .zero
        dragStart = .zero
    }
}

// MARK: - Synced Compare Image with Zoom/Pan

struct SyncedCompareImage: View {
    let url: URL
    let panelSize: CGSize
    @Binding var syncScale: CGFloat
    @Binding var syncOffset: CGPoint
    @Binding var dragStart: CGPoint
    let isSynced: Bool

    @State private var image: NSImage?
    @State private var localScale: CGFloat = 1.0
    @State private var localOffset: CGPoint = .zero
    @State private var localDragStart: CGPoint = .zero

    private var activeScale: CGFloat { isSynced ? syncScale : localScale }
    private var activeOffset: CGPoint { isSynced ? syncOffset : localOffset }
    private var isZoomed: Bool { activeScale > 1.01 }

    var body: some View {
        GeometryReader { geo in
            let vSize = geo.size

            Group {
                if let image = image {
                    let imgW = image.size.width
                    let imgH = image.size.height
                    let fitScale = min(vSize.width / imgW, vSize.height / imgH)
                    let scaledW = imgW * fitScale * activeScale
                    let scaledH = imgH * fitScale * activeScale

                    let clampedOffset = clampPan(
                        pan: activeOffset,
                        scaledSize: CGSize(width: scaledW, height: scaledH),
                        viewSize: vSize
                    )

                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: max(scaledW, vSize.width), height: max(scaledH, vSize.height))
                        .offset(x: isZoomed ? clampedOffset.x : 0,
                                y: isZoomed ? clampedOffset.y : 0)
                        .frame(width: vSize.width, height: vSize.height, alignment: .center)
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    guard isZoomed else { return }
                                    let start = isSynced ? dragStart : localDragStart
                                    let newOffset = CGPoint(
                                        x: start.x + value.translation.width,
                                        y: start.y + value.translation.height
                                    )
                                    if isSynced { syncOffset = newOffset }
                                    else { localOffset = newOffset }
                                }
                                .onEnded { _ in
                                    guard isZoomed else { return }
                                    let clamped = clampPan(
                                        pan: isSynced ? syncOffset : localOffset,
                                        scaledSize: CGSize(width: scaledW, height: scaledH),
                                        viewSize: vSize
                                    )
                                    if isSynced { syncOffset = clamped; dragStart = clamped }
                                    else { localOffset = clamped; localDragStart = clamped }
                                }
                        )
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.1))
                        .overlay(ProgressView().scaleEffect(0.5))
                }
            }
        }
        .onAppear { loadImage() }
    }

    private func loadImage() {
        let capturedURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                // 썸네일 캐시에서 즉시 표시
                if let thumb = ThumbnailCache.shared.get(capturedURL) {
                    DispatchQueue.main.async { image = thumb }
                }
                // 고화질 로딩
                guard let img = PreviewImageCache.loadOptimized(url: capturedURL, maxPixel: 2000) else { return }
                DispatchQueue.main.async { image = img }
            }
        }
    }

    private func clampPan(pan: CGPoint, scaledSize: CGSize, viewSize: CGSize) -> CGPoint {
        let maxX = max(0, (scaledSize.width - viewSize.width) / 2)
        let maxY = max(0, (scaledSize.height - viewSize.height) / 2)
        return CGPoint(
            x: max(-maxX, min(maxX, pan.x)),
            y: max(-maxY, min(maxY, pan.y))
        )
    }
}

// MARK: - Arrow Key Handler for Compare View

struct CompareKeyHandler: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void

    func makeNSView(context: Context) -> CompareKeyView {
        let view = CompareKeyView()
        view.onLeft = onLeft
        view.onRight = onRight
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: CompareKeyView, context: Context) {
        nsView.onLeft = onLeft
        nsView.onRight = onRight
    }
}

class CompareKeyView: NSView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onLeft?()   // left arrow
        case 124: onRight?()  // right arrow
        default: super.keyDown(with: event)
        }
    }
}
