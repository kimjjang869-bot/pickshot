import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - CropView

struct CropView: View {
    let photo: PhotoItem
    let onApply: (NSImage) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var cropRect: CGRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9) // normalized 0~1
    @State private var aspectRatio: AspectRatio = .free
    @State private var image: NSImage?
    @State private var dragHandle: DragHandle? = nil
    @State private var dragStartRect: CGRect = .zero
    @State private var dragStartPoint: CGPoint = .zero
    @State private var showHeatmap: Bool = false
    @State private var heatmapImage: NSImage?
    @State private var isComputingSmartCrop: Bool = false

    enum AspectRatio: String, CaseIterable, Identifiable {
        case free = "자유"
        case square = "1:1"
        case ratio4x3 = "4:3"
        case ratio3x2 = "3:2"
        case ratio16x9 = "16:9"
        case ratio5x4 = "5:4"

        var id: String { rawValue }

        var ratio: CGFloat? {
            switch self {
            case .free: return nil
            case .square: return 1.0
            case .ratio4x3: return 4.0 / 3.0
            case .ratio3x2: return 3.0 / 2.0
            case .ratio16x9: return 16.0 / 9.0
            case .ratio5x4: return 5.0 / 4.0
            }
        }
    }

    enum DragHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        case inside
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("크롭")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let img = image {
                    let pw = Int(CGFloat(Int(img.size.width)) * cropRect.width)
                    let ph = Int(CGFloat(Int(img.size.height)) * cropRect.height)
                    Text("\(pw) x \(ph) px")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // 비율 프리셋 + 스마트 크롭
            HStack(spacing: 6) {
                ForEach(AspectRatio.allCases) { ratio in
                    Button(action: { selectAspectRatio(ratio) }) {
                        Text(ratio.rawValue)
                            .font(.system(size: 11, weight: aspectRatio == ratio ? .bold : .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(aspectRatio == ratio ? Color.accentColor : Color.gray.opacity(0.15))
                            .foregroundColor(aspectRatio == ratio ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .frame(height: 20)

                // 스마트 크롭 버튼
                Button(action: { performSmartCrop() }) {
                    HStack(spacing: 4) {
                        if isComputingSmartCrop {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 11))
                        }
                        Text("스마트 크롭")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.2))
                    .foregroundColor(.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isComputingSmartCrop || image == nil)
                .help("AI가 최적 크롭 영역을 자동으로 제안합니다")

                // 히트맵 오버레이 토글
                Button(action: { toggleHeatmap() }) {
                    Image(systemName: showHeatmap ? "eye.fill" : "eye.slash")
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(showHeatmap ? Color.red.opacity(0.2) : Color.gray.opacity(0.15))
                        .foregroundColor(showHeatmap ? .red : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(image == nil)
                .help("어텐션 히트맵 오버레이 표시/숨김")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Image with crop overlay
            GeometryReader { geo in
                let imageArea = geo.size
                if let img = image {
                    let imgSize = img.size
                    let fitted = fitSize(imgSize, in: imageArea)
                    let originX = (imageArea.width - fitted.width) / 2
                    let originY = (imageArea.height - fitted.height) / 2

                    ZStack {
                        // The image
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: fitted.width, height: fitted.height)

                        // Dimming overlay outside crop
                        cropOverlay(fitted: fitted, origin: CGPoint(x: originX, y: originY))
                            .frame(width: fitted.width, height: fitted.height)

                        // Grid lines (rule of thirds)
                        gridLines(fitted: fitted)
                            .frame(width: fitted.width, height: fitted.height)

                        // 어텐션 히트맵 오버레이
                        if showHeatmap, let heatmap = heatmapImage {
                            Image(nsImage: heatmap)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: fitted.width, height: fitted.height)
                                .opacity(0.45)
                                .allowsHitTesting(false)
                        }

                        // Drag handles
                        dragHandles(fitted: fitted)
                            .frame(width: fitted.width, height: fitted.height)
                    }
                    .frame(width: imageArea.width, height: imageArea.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                handleDrag(value: value, fitted: fitted, origin: CGPoint(x: originX, y: originY))
                            }
                            .onEnded { _ in
                                dragHandle = nil
                            }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let pt):
                            let localPt = CGPoint(x: pt.x - originX, y: pt.y - originY)
                            updateCursor(at: localPt, fitted: fitted)
                        case .ended:
                            NSCursor.arrow.set()
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
            .background(Color.black.opacity(0.85))

            // Bottom buttons
            HStack {
                Button("취소") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("초기화") {
                    cropRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
                    aspectRatio = .free
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button("적용") { applyCrop() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 700, minHeight: 550)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadSourceImage() }
    }

    // MARK: - Overlay

    private func cropOverlay(fitted: CGSize, origin: CGPoint) -> some View {
        Canvas { context, size in
            // Full dim rect
            let fullRect = CGRect(origin: .zero, size: size)
            context.fill(Path(fullRect), with: .color(.black.opacity(0.55)))

            // Clear the crop area
            let cropPixelRect = CGRect(
                x: cropRect.minX * size.width,
                y: cropRect.minY * size.height,
                width: cropRect.width * size.width,
                height: cropRect.height * size.height
            )
            context.blendMode = .destinationOut
            context.fill(Path(cropPixelRect), with: .color(.white))

            // Border
            context.blendMode = .normal
            context.stroke(Path(cropPixelRect), with: .color(.white), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Grid Lines

    private func gridLines(fitted: CGSize) -> some View {
        Canvas { context, size in
            let cx = cropRect.minX * size.width
            let cy = cropRect.minY * size.height
            let cw = cropRect.width * size.width
            let ch = cropRect.height * size.height

            let style = StrokeStyle(lineWidth: 0.5, dash: [])
            let color: Color = .white.opacity(0.35)

            // Vertical thirds
            for i in 1...2 {
                let x = cx + cw * CGFloat(i) / 3
                var path = Path()
                path.move(to: CGPoint(x: x, y: cy))
                path.addLine(to: CGPoint(x: x, y: cy + ch))
                context.stroke(path, with: .color(color), style: style)
            }
            // Horizontal thirds
            for i in 1...2 {
                let y = cy + ch * CGFloat(i) / 3
                var path = Path()
                path.move(to: CGPoint(x: cx, y: y))
                path.addLine(to: CGPoint(x: cx + cw, y: y))
                context.stroke(path, with: .color(color), style: style)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Drag Handles

    private func dragHandles(fitted: CGSize) -> some View {
        let cx = cropRect.minX * fitted.width
        let cy = cropRect.minY * fitted.height
        let cw = cropRect.width * fitted.width
        let ch = cropRect.height * fitted.height
        let handleSize: CGFloat = 10

        return ZStack {
            // Corner handles
            handleRect(at: CGPoint(x: cx, y: cy), size: handleSize) // topLeft
            handleRect(at: CGPoint(x: cx + cw, y: cy), size: handleSize) // topRight
            handleRect(at: CGPoint(x: cx, y: cy + ch), size: handleSize) // bottomLeft
            handleRect(at: CGPoint(x: cx + cw, y: cy + ch), size: handleSize) // bottomRight

            // Edge handles (midpoints)
            handleRect(at: CGPoint(x: cx + cw / 2, y: cy), size: handleSize) // top
            handleRect(at: CGPoint(x: cx + cw / 2, y: cy + ch), size: handleSize) // bottom
            handleRect(at: CGPoint(x: cx, y: cy + ch / 2), size: handleSize) // left
            handleRect(at: CGPoint(x: cx + cw, y: cy + ch / 2), size: handleSize) // right
        }
        .allowsHitTesting(false)
    }

    private func handleRect(at center: CGPoint, size: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: size, height: size)
            .border(Color.gray.opacity(0.5), width: 0.5)
            .position(center)
    }

    // MARK: - Hit Test

    private func hitTest(at point: CGPoint, fitted: CGSize) -> DragHandle? {
        let cx = cropRect.minX * fitted.width
        let cy = cropRect.minY * fitted.height
        let cw = cropRect.width * fitted.width
        let ch = cropRect.height * fitted.height
        let threshold: CGFloat = 14

        // Corners first
        if dist(point, CGPoint(x: cx, y: cy)) < threshold { return .topLeft }
        if dist(point, CGPoint(x: cx + cw, y: cy)) < threshold { return .topRight }
        if dist(point, CGPoint(x: cx, y: cy + ch)) < threshold { return .bottomLeft }
        if dist(point, CGPoint(x: cx + cw, y: cy + ch)) < threshold { return .bottomRight }

        // Edges
        let cropPixelRect = CGRect(x: cx, y: cy, width: cw, height: ch)
        if abs(point.y - cy) < threshold && point.x >= cx && point.x <= cx + cw { return .top }
        if abs(point.y - (cy + ch)) < threshold && point.x >= cx && point.x <= cx + cw { return .bottom }
        if abs(point.x - cx) < threshold && point.y >= cy && point.y <= cy + ch { return .left }
        if abs(point.x - (cx + cw)) < threshold && point.y >= cy && point.y <= cy + ch { return .right }

        // Inside
        if cropPixelRect.contains(point) { return .inside }

        return nil
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))
    }

    // MARK: - Cursor

    private func updateCursor(at localPt: CGPoint, fitted: CGSize) {
        guard let handle = hitTest(at: localPt, fitted: fitted) else {
            NSCursor.arrow.set()
            return
        }
        switch handle {
        case .topLeft, .bottomRight: NSCursor(image: NSImage(size: .zero), hotSpot: .zero).set(); NSCursor.crosshair.set()
        case .topRight, .bottomLeft: NSCursor.crosshair.set()
        case .top, .bottom: NSCursor.resizeUpDown.set()
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .inside: NSCursor.openHand.set()
        }
    }

    // MARK: - Drag Handling

    private func handleDrag(value: DragGesture.Value, fitted: CGSize, origin: CGPoint) {
        let localStart = CGPoint(x: value.startLocation.x - origin.x, y: value.startLocation.y - origin.y)
        let localCurrent = CGPoint(x: value.location.x - origin.x, y: value.location.y - origin.y)

        // On first drag, detect handle
        if dragHandle == nil {
            dragHandle = hitTest(at: localStart, fitted: fitted)
            dragStartRect = cropRect
            dragStartPoint = localStart
        }

        guard let handle = dragHandle else { return }

        let dx = (localCurrent.x - dragStartPoint.x) / fitted.width
        let dy = (localCurrent.y - dragStartPoint.y) / fitted.height
        let minSize: CGFloat = 0.05

        var newRect = dragStartRect

        switch handle {
        case .inside:
            newRect.origin.x = clamp(dragStartRect.origin.x + dx, min: 0, max: 1 - dragStartRect.width)
            newRect.origin.y = clamp(dragStartRect.origin.y + dy, min: 0, max: 1 - dragStartRect.height)

        case .topLeft:
            newRect.origin.x = clamp(dragStartRect.origin.x + dx, min: 0, max: dragStartRect.maxX - minSize)
            newRect.origin.y = clamp(dragStartRect.origin.y + dy, min: 0, max: dragStartRect.maxY - minSize)
            newRect.size.width = dragStartRect.maxX - newRect.origin.x
            newRect.size.height = dragStartRect.maxY - newRect.origin.y

        case .topRight:
            newRect.origin.y = clamp(dragStartRect.origin.y + dy, min: 0, max: dragStartRect.maxY - minSize)
            newRect.size.width = clamp(dragStartRect.width + dx, min: minSize, max: 1 - dragStartRect.origin.x)
            newRect.size.height = dragStartRect.maxY - newRect.origin.y

        case .bottomLeft:
            newRect.origin.x = clamp(dragStartRect.origin.x + dx, min: 0, max: dragStartRect.maxX - minSize)
            newRect.size.width = dragStartRect.maxX - newRect.origin.x
            newRect.size.height = clamp(dragStartRect.height + dy, min: minSize, max: 1 - dragStartRect.origin.y)

        case .bottomRight:
            newRect.size.width = clamp(dragStartRect.width + dx, min: minSize, max: 1 - dragStartRect.origin.x)
            newRect.size.height = clamp(dragStartRect.height + dy, min: minSize, max: 1 - dragStartRect.origin.y)

        case .top:
            newRect.origin.y = clamp(dragStartRect.origin.y + dy, min: 0, max: dragStartRect.maxY - minSize)
            newRect.size.height = dragStartRect.maxY - newRect.origin.y

        case .bottom:
            newRect.size.height = clamp(dragStartRect.height + dy, min: minSize, max: 1 - dragStartRect.origin.y)

        case .left:
            newRect.origin.x = clamp(dragStartRect.origin.x + dx, min: 0, max: dragStartRect.maxX - minSize)
            newRect.size.width = dragStartRect.maxX - newRect.origin.x

        case .right:
            newRect.size.width = clamp(dragStartRect.width + dx, min: minSize, max: 1 - dragStartRect.origin.x)
        }

        // Enforce aspect ratio if needed
        if let ratio = aspectRatio.ratio, handle != .inside {
            // Adjust height to match width based on ratio, considering image aspect
            if let img = image {
                let imageRatio = img.size.width / img.size.height
                let normalizedRatio = ratio / imageRatio
                // Keep width, adjust height
                let desiredHeight = newRect.width / normalizedRatio
                if desiredHeight <= 1 - newRect.origin.y && desiredHeight >= minSize {
                    newRect.size.height = desiredHeight
                } else {
                    // Keep height, adjust width
                    let desiredWidth = newRect.height * normalizedRatio
                    newRect.size.width = clamp(desiredWidth, min: minSize, max: 1 - newRect.origin.x)
                    newRect.size.height = newRect.width / normalizedRatio
                }
            }
        }

        cropRect = newRect
    }

    private func clamp(_ value: CGFloat, min minVal: CGFloat, max maxVal: CGFloat) -> CGFloat {
        Swift.min(maxVal, Swift.max(minVal, value))
    }

    // MARK: - Aspect Ratio Selection

    private func selectAspectRatio(_ ratio: AspectRatio) {
        aspectRatio = ratio
        guard let r = ratio.ratio, let img = image else { return }

        let imageRatio = img.size.width / img.size.height
        let normalizedRatio = r / imageRatio

        // Center crop rect with new aspect ratio
        let centerX = cropRect.midX
        let centerY = cropRect.midY

        var newW = cropRect.width
        var newH = newW / normalizedRatio

        if newH > 0.9 {
            newH = 0.9
            newW = newH * normalizedRatio
        }
        if newW > 0.9 {
            newW = 0.9
            newH = newW / normalizedRatio
        }

        let newX = clamp(centerX - newW / 2, min: 0, max: 1 - newW)
        let newY = clamp(centerY - newH / 2, min: 0, max: 1 - newH)

        cropRect = CGRect(x: newX, y: newY, width: newW, height: newH)
    }

    // MARK: - Image Loading

    private func loadSourceImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let nsImage = NSImage(contentsOf: photo.jpgURL) else { return }
            DispatchQueue.main.async {
                self.image = nsImage
            }
        }
    }

    // MARK: - Apply Crop

    private func applyCrop() {
        guard let sourceImage = image else { return }
        guard let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let pixelW = CGFloat(cgImage.width)
        let pixelH = CGFloat(cgImage.height)

        let cropPixelRect = CGRect(
            x: (cropRect.origin.x * pixelW).rounded(),
            y: (cropRect.origin.y * pixelH).rounded(),
            width: (cropRect.width * pixelW).rounded(),
            height: (cropRect.height * pixelH).rounded()
        ).intersection(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        guard !cropPixelRect.isEmpty,
              let croppedCG = cgImage.cropping(to: cropPixelRect) else { return }

        let croppedImage = NSImage(cgImage: croppedCG, size: NSSize(width: croppedCG.width, height: croppedCG.height))

        // 크롭된 이미지 파일로 저장 (_cropped 접미사)
        saveCroppedFile(cgImage: croppedCG)

        onApply(croppedImage)
        dismiss()
    }

    private func saveCroppedFile(cgImage: CGImage) {
        let originalURL = photo.jpgURL
        let dir = originalURL.deletingLastPathComponent()
        let name = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension.lowercased()

        // _cropped 파일명 (이미 있으면 번호 추가)
        var destURL = dir.appendingPathComponent("\(name)_cropped.\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: destURL.path) {
            destURL = dir.appendingPathComponent("\(name)_cropped_\(counter).\(ext)")
            counter += 1
        }

        // JPEG로 저장 (원본 확장자에 맞게). v8.6.3: UTType 으로 교체 (kUTTypePNG 등 deprecated)
        let uti: UTType = (ext == "png") ? .png : .jpeg
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, uti.identifier as CFString, 1, nil) else { return }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)

        if CGImageDestinationFinalize(dest) {
            AppLogger.log(.export, "Crop saved: \(destURL.lastPathComponent) (\(cgImage.width)x\(cgImage.height))")
        }
    }

    // MARK: - Smart Crop

    /// AI 기반 최적 크롭 영역 계산 및 적용
    private func performSmartCrop() {
        guard let sourceImage = image,
              let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        isComputingSmartCrop = true

        DispatchQueue.global(qos: .userInitiated).async {
            let suggested = SmartCropService.suggestCrop(
                cgImage: cgImage,
                aspectRatio: aspectRatio.ratio
            )

            DispatchQueue.main.async {
                // 애니메이션으로 크롭 영역 이동
                withAnimation(.easeInOut(duration: 0.4)) {
                    cropRect = suggested
                }
                isComputingSmartCrop = false
            }
        }
    }

    /// 어텐션 히트맵 오버레이 토글
    private func toggleHeatmap() {
        if showHeatmap {
            showHeatmap = false
            return
        }

        guard let sourceImage = image,
              let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        // 히트맵이 없으면 생성
        if heatmapImage == nil {
            DispatchQueue.global(qos: .userInitiated).async {
                if let heatmapCI = SmartCropService.attentionHeatmap(cgImage: cgImage) {
                    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
                    if let cgResult = ciContext.createCGImage(heatmapCI, from: heatmapCI.extent) {
                        let nsImage = NSImage(cgImage: cgResult, size: NSSize(width: cgResult.width, height: cgResult.height))
                        DispatchQueue.main.async {
                            heatmapImage = nsImage
                            showHeatmap = true
                        }
                    }
                }
            }
        } else {
            showHeatmap = true
        }
    }

    // MARK: - Helpers

    private func fitSize(_ imageSize: CGSize, in container: CGSize) -> CGSize {
        let wRatio = container.width / imageSize.width
        let hRatio = container.height / imageSize.height
        let scale = min(wRatio, hRatio)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
