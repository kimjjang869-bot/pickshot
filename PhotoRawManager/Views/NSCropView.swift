import SwiftUI
import AppKit

/// AppKit NSView 기반 크롭 뷰.
/// 이미지와 크롭 박스를 **같은 draw(_:) 에서 픽셀 단위로** 그려
/// SwiftUI 레이아웃 엔진의 불일치를 원천 차단.
final class CropNSView: NSView {

    // MARK: - Public (setter)

    var image: NSImage? { didSet { needsDisplay = true } }
    /// 이미지 공간의 0~1 정규화 크롭 rect.
    /// v8.6.1: `isApplyingExternal` 플래그로 updateNSView 의 외부 binding 업데이트 시
    /// onCropChanged 콜백이 재호출되어 didSet 피드백 루프 발생하는 문제 차단.
    var cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet {
            needsDisplay = true
            if !isApplyingExternal { onCropChanged?(cropRect, rotationDegrees, aspectLabel) }
        }
    }
    /// -45 ~ +45 도. 크롭 박스 내부 회전 프리뷰용.
    var rotationDegrees: Double = 0 {
        didSet {
            needsDisplay = true
            if !isApplyingExternal { onCropChanged?(cropRect, rotationDegrees, aspectLabel) }
        }
    }
    /// 종횡비 라벨 ("Free", "1:1", "3:2" 등). 드래그 중 비율 잠금 계산에 사용
    var aspectLabel: String = "Original" {
        didSet {
            if !isApplyingExternal { onCropChanged?(cropRect, rotationDegrees, aspectLabel) }
        }
    }
    /// 종횡비 픽셀 비율 (nil = 자유). preset 선택 시 외부에서 세팅
    var aspectRatio: Double? = nil

    /// 크롭 값 변경 콜백 (rect, rotation, label)
    var onCropChanged: ((CGRect, Double, String) -> Void)?

    /// updateNSView 에서 외부 binding 을 반영 중임을 표시 — 이 때의 didSet 은
    /// onCropChanged 를 호출하지 않아 SwiftUI <-> AppKit 피드백 루프를 방지.
    fileprivate var isApplyingExternal: Bool = false

    // MARK: - Internal state

    private enum HandleType {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, leading, trailing
        case move
    }

    private var activeHandle: HandleType?
    private var dragStartRect: CGRect = .zero
    private var dragStartPoint: CGPoint = .zero

    // MARK: - Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }  // 좌상단 원점 사용 (SwiftUI 와 일치)

    // MARK: - Computed (image fit rect)

    /// 이미지가 실제로 그려지는 rect (bounds 안에서 aspect fit).
    private var imageRect: CGRect {
        guard let img = image else { return .zero }
        let s = img.size
        guard s.width > 0 && s.height > 0 else { return .zero }
        let imgAR = s.width / s.height
        let viewAR = bounds.width / max(bounds.height, 1)
        if imgAR > viewAR {
            let h = bounds.width / imgAR
            return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        } else {
            let w = bounds.height * imgAR
            return CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
    }

    /// 크롭 박스의 **스크린 좌표** (imageRect 기준 cropRect 정규화 값 변환)
    private var cropRectInView: CGRect {
        let ir = imageRect
        return CGRect(
            x: ir.origin.x + cropRect.origin.x * ir.width,
            y: ir.origin.y + cropRect.origin.y * ir.height,
            width: cropRect.width * ir.width,
            height: cropRect.height * ir.height
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let ir = imageRect
        guard ir.width > 0 && ir.height > 0 else { return }

        // 2) 이미지 그리기 — 회전 각도(rotationDegrees) 적용.
        // 이미지 중심을 축으로 회전 → Lightroom/C1 스타일의 "수평 보정 프리뷰".
        if let img = image {
            ctx.saveGState()
            if abs(rotationDegrees) > 0.01 {
                let cx = ir.midX, cy = ir.midY
                ctx.translateBy(x: cx, y: cy)
                ctx.rotate(by: CGFloat(rotationDegrees * .pi / 180))
                ctx.translateBy(x: -cx, y: -cy)
            }
            img.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            ctx.restoreGState()
        }

        let cr = cropRectInView

        // 3) 박스 밖 마스크 (이미지 영역 안만) — 약간 어둡게
        ctx.saveGState()
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.55).cgColor)
        // clip 을 이미지 영역 - 크롭 박스로 (even-odd)
        ctx.addRect(ir)
        ctx.addRect(cr)
        ctx.clip(using: .evenOdd)
        ctx.fill(ir)
        ctx.restoreGState()

        // 4) 9분할 rule-of-thirds
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: activeHandle != nil ? 0.7 : 0.45).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1...2 {
            let x = cr.minX + cr.width * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: cr.minY))
            ctx.addLine(to: CGPoint(x: x, y: cr.maxY))
            let y = cr.minY + cr.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: cr.minX, y: y))
            ctx.addLine(to: CGPoint(x: cr.maxX, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // 5) 크롭 박스 외곽선
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(cr)
        ctx.restoreGState()

        // 6) L 자 코너 핸들 (안쪽으로)
        drawLCorners(ctx: ctx, rect: cr)

        // 7) 엣지 중앙 바 핸들
        drawEdgeHandles(ctx: ctx, rect: cr)
    }

    private func drawLCorners(ctx: CGContext, rect r: CGRect) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(3.0)
        let L: CGFloat = 16      // L 길이
        let inset: CGFloat = 1.5  // 박스 선 안쪽으로

        // topLeft
        ctx.move(to: CGPoint(x: r.minX + inset, y: r.minY + inset + L))
        ctx.addLine(to: CGPoint(x: r.minX + inset, y: r.minY + inset))
        ctx.addLine(to: CGPoint(x: r.minX + inset + L, y: r.minY + inset))
        ctx.strokePath()

        // topRight
        ctx.move(to: CGPoint(x: r.maxX - inset - L, y: r.minY + inset))
        ctx.addLine(to: CGPoint(x: r.maxX - inset, y: r.minY + inset))
        ctx.addLine(to: CGPoint(x: r.maxX - inset, y: r.minY + inset + L))
        ctx.strokePath()

        // bottomLeft
        ctx.move(to: CGPoint(x: r.minX + inset, y: r.maxY - inset - L))
        ctx.addLine(to: CGPoint(x: r.minX + inset, y: r.maxY - inset))
        ctx.addLine(to: CGPoint(x: r.minX + inset + L, y: r.maxY - inset))
        ctx.strokePath()

        // bottomRight
        ctx.move(to: CGPoint(x: r.maxX - inset - L, y: r.maxY - inset))
        ctx.addLine(to: CGPoint(x: r.maxX - inset, y: r.maxY - inset))
        ctx.addLine(to: CGPoint(x: r.maxX - inset, y: r.maxY - inset - L))
        ctx.strokePath()

        ctx.restoreGState()
    }

    private func drawEdgeHandles(ctx: CGContext, rect r: CGRect) {
        ctx.saveGState()
        ctx.setFillColor(NSColor.white.cgColor)
        let barLen: CGFloat = 28
        let barThick: CGFloat = 3
        // top
        ctx.fill(CGRect(x: r.midX - barLen / 2, y: r.minY + 1, width: barLen, height: barThick))
        // bottom
        ctx.fill(CGRect(x: r.midX - barLen / 2, y: r.maxY - 1 - barThick, width: barLen, height: barThick))
        // leading
        ctx.fill(CGRect(x: r.minX + 1, y: r.midY - barLen / 2, width: barThick, height: barLen))
        // trailing
        ctx.fill(CGRect(x: r.maxX - 1 - barThick, y: r.midY - barLen / 2, width: barThick, height: barLen))
        ctx.restoreGState()
    }

    // MARK: - Layout invalidation

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override var frame: NSRect {
        didSet { needsDisplay = true }
    }

    // MARK: - Hit testing (handle detection)

    private func handle(at point: CGPoint) -> HandleType? {
        let cr = cropRectInView
        let hitSize: CGFloat = 22
        func near(_ p: CGPoint) -> Bool {
            let dx = point.x - p.x, dy = point.y - p.y
            return dx * dx + dy * dy <= hitSize * hitSize
        }
        if near(CGPoint(x: cr.minX, y: cr.minY)) { return .topLeft }
        if near(CGPoint(x: cr.maxX, y: cr.minY)) { return .topRight }
        if near(CGPoint(x: cr.minX, y: cr.maxY)) { return .bottomLeft }
        if near(CGPoint(x: cr.maxX, y: cr.maxY)) { return .bottomRight }
        // edges (각각의 중앙 ± 20pt)
        let edgeHit: CGFloat = 14
        if abs(point.y - cr.minY) < edgeHit && point.x > cr.minX + 20 && point.x < cr.maxX - 20 { return .top }
        if abs(point.y - cr.maxY) < edgeHit && point.x > cr.minX + 20 && point.x < cr.maxX - 20 { return .bottom }
        if abs(point.x - cr.minX) < edgeHit && point.y > cr.minY + 20 && point.y < cr.maxY - 20 { return .leading }
        if abs(point.x - cr.maxX) < edgeHit && point.y > cr.minY + 20 && point.y < cr.maxY - 20 { return .trailing }
        // inside box → move
        if cr.insetBy(dx: 20, dy: 20).contains(point) { return .move }
        return nil
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        let cr = cropRectInView
        guard !cr.isEmpty else { return }
        let cornerSize: CGFloat = 24
        // 코너: resizeLeftRight 로 폴백 (macOS 에 대각선 커서 공개 API 없음)
        addCursorRect(CGRect(x: cr.minX - cornerSize / 2, y: cr.minY - cornerSize / 2, width: cornerSize, height: cornerSize), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: cr.maxX - cornerSize / 2, y: cr.minY - cornerSize / 2, width: cornerSize, height: cornerSize), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: cr.minX - cornerSize / 2, y: cr.maxY - cornerSize / 2, width: cornerSize, height: cornerSize), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: cr.maxX - cornerSize / 2, y: cr.maxY - cornerSize / 2, width: cornerSize, height: cornerSize), cursor: .resizeLeftRight)
        // 엣지
        addCursorRect(CGRect(x: cr.midX - 20, y: cr.minY - 8, width: 40, height: 16), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: cr.midX - 20, y: cr.maxY - 8, width: 40, height: 16), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: cr.minX - 8, y: cr.midY - 20, width: 16, height: 40), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: cr.maxX - 8, y: cr.midY - 20, width: 16, height: 40), cursor: .resizeLeftRight)
        // move
        addCursorRect(cr.insetBy(dx: 20, dy: 20), cursor: .openHand)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        activeHandle = handle(at: p)
        dragStartRect = cropRect
        dragStartPoint = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let h = activeHandle else { return }
        let p = convert(event.locationInWindow, from: nil)
        let ir = imageRect
        guard ir.width > 0 && ir.height > 0 else { return }
        // 이미지 공간 정규화 delta
        let dxN = (p.x - dragStartPoint.x) / ir.width
        let dyN = (p.y - dragStartPoint.y) / ir.height
        let shift = event.modifierFlags.contains(.shift)
        let lockedPixelAspect = aspectRatio ?? (shift ? effectivePixelAspect() : nil)
        var newRect = dragStartRect
        applyDrag(&newRect, handle: h, dxN: dxN, dyN: dyN, lockedPixelAspect: lockedPixelAspect)
        cropRect = clampNormalized(newRect, preservingPixelAspect: lockedPixelAspect)
    }

    override func mouseUp(with event: NSEvent) {
        activeHandle = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func applyDrag(_ rect: inout CGRect, handle h: HandleType, dxN: CGFloat, dyN: CGFloat, lockedPixelAspect: Double?) {
        switch h {
        case .move:
            rect.origin.x = max(0, min(1 - dragStartRect.width, dragStartRect.origin.x + dxN))
            rect.origin.y = max(0, min(1 - dragStartRect.height, dragStartRect.origin.y + dyN))
            return
        case .topLeft:
            rect.origin.x = dragStartRect.minX + dxN
            rect.origin.y = dragStartRect.minY + dyN
            rect.size.width = dragStartRect.maxX - rect.origin.x
            rect.size.height = dragStartRect.maxY - rect.origin.y
        case .topRight:
            rect.size.width = dragStartRect.width + dxN
            rect.origin.y = dragStartRect.minY + dyN
            rect.size.height = dragStartRect.maxY - rect.origin.y
        case .bottomLeft:
            rect.origin.x = dragStartRect.minX + dxN
            rect.size.width = dragStartRect.maxX - rect.origin.x
            rect.size.height = dragStartRect.height + dyN
        case .bottomRight:
            rect.size.width = dragStartRect.width + dxN
            rect.size.height = dragStartRect.height + dyN
        case .top:
            rect.origin.y = dragStartRect.minY + dyN
            rect.size.height = dragStartRect.maxY - rect.origin.y
        case .bottom:
            rect.size.height = dragStartRect.height + dyN
        case .leading:
            rect.origin.x = dragStartRect.minX + dxN
            rect.size.width = dragStartRect.maxX - rect.origin.x
        case .trailing:
            rect.size.width = dragStartRect.width + dxN
        }
        // 드래그 방향 역전 시 rect 뒤집힘 방지 — minX/maxX/minY/maxY 정규화
        if rect.size.width < 0 {
            rect.origin.x += rect.size.width
            rect.size.width = -rect.size.width
        }
        if rect.size.height < 0 {
            rect.origin.y += rect.size.height
            rect.size.height = -rect.size.height
        }
        rect.size.width = max(0.05, rect.size.width)
        rect.size.height = max(0.05, rect.size.height)

        // 비율 잠금 — 프리셋 비율이 있으면 항상 잠금, Free 상태에서는 Shift 동안 현재 비율 유지.
        if let pixelAR = lockedPixelAspect {
            guard let img = image, img.size.height > 0 else { return }
            let imgAR = img.size.width / img.size.height
            let norm = CGFloat(pixelAR) / imgAR
            switch h {
            case .top, .bottom:
                let newW = rect.height * norm
                let cx = (rect.minX + rect.maxX) / 2
                rect.origin.x = cx - newW / 2
                rect.size.width = newW
            case .leading, .trailing:
                let newH = rect.width / norm
                let cy = (rect.minY + rect.maxY) / 2
                rect.origin.y = cy - newH / 2
                rect.size.height = newH
            default:
                let byH = rect.width / norm
                let byW = rect.height * norm
                if byW > rect.width { rect.size.width = byW } else { rect.size.height = byH }
            }
        }
    }

    private func effectivePixelAspect() -> Double? {
        if let ar = aspectRatio { return ar }
        guard cropRect.height > 0, let img = image, img.size.height > 0 else { return nil }
        let imgAR = img.size.width / img.size.height
        return (cropRect.width / cropRect.height) * imgAR
    }

    private func clampNormalized(_ r: CGRect, preservingPixelAspect pixelAR: Double? = nil) -> CGRect {
        var r = r
        if r.size.width < 0 {
            r.origin.x += r.size.width
            r.size.width = -r.size.width
        }
        if r.size.height < 0 {
            r.origin.y += r.size.height
            r.size.height = -r.size.height
        }

        guard let pixelAR,
              let img = image,
              img.size.width > 0,
              img.size.height > 0 else {
            r.origin.x = max(0, min(1, r.origin.x))
            r.origin.y = max(0, min(1, r.origin.y))
            r.size.width = min(r.size.width, 1 - r.origin.x)
            r.size.height = min(r.size.height, 1 - r.origin.y)
            r.size.width = max(0.05, r.size.width)
            r.size.height = max(0.05, r.size.height)
            return r
        }

        let imgAR = img.size.width / img.size.height
        let normAR = CGFloat(pixelAR) / max(imgAR, 0.0001)
        let minSide: CGFloat = 0.05
        let cx = min(max(r.midX, 0), 1)
        let cy = min(max(r.midY, 0), 1)

        var width = max(r.width, minSide)
        var height = max(r.height, minSide)

        if width / max(height, 0.0001) > normAR {
            height = width / normAR
        } else {
            width = height * normAR
        }

        let maxWAtCenter = max(minSide, min(cx, 1 - cx) * 2)
        let maxHAtCenter = max(minSide, min(cy, 1 - cy) * 2)
        if width > maxWAtCenter {
            width = maxWAtCenter
            height = width / normAR
        }
        if height > maxHAtCenter {
            height = maxHAtCenter
            width = height * normAR
        }

        if width > 1 {
            width = 1
            height = width / normAR
        }
        if height > 1 {
            height = 1
            width = height * normAR
        }

        width = max(minSide, min(width, 1))
        height = max(minSide, min(height, 1))
        r = CGRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
        r.origin.x = max(0, min(1 - r.width, r.origin.x))
        r.origin.y = max(0, min(1 - r.height, r.origin.y))
        return r
    }

    // (applyPreset 은 InlineCropOverlay.selectPreset 이 직접 담당하므로 제거됨 — dead code)
}

// MARK: - SwiftUI Wrapper

struct NSCropView: NSViewRepresentable {
    let image: NSImage
    @Binding var cropRect: CGRect
    @Binding var rotationDegrees: Double
    @Binding var aspectLabel: String
    /// 현재 선택된 종횡비 (픽셀 기준). Free/Original = nil.
    var aspectRatio: Double?

    /// v8.6.1: Coordinator 패턴 — onCropChanged 클로저가 Binding 값 캡처 시 SwiftUI struct
    /// 재생성 때마다 stale 되는 문제 해결. Coordinator 는 class 라 레퍼런스 공유 가능.
    final class Coordinator {
        var parent: NSCropView
        init(_ parent: NSCropView) { self.parent = parent }

        func apply(_ rect: CGRect, _ rot: Double, _ label: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.parent.cropRect != rect { self.parent.cropRect = rect }
                if self.parent.rotationDegrees != rot { self.parent.rotationDegrees = rot }
                if self.parent.aspectLabel != label { self.parent.aspectLabel = label }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CropNSView {
        let v = CropNSView(frame: .zero)
        v.image = image
        v.cropRect = cropRect
        v.rotationDegrees = rotationDegrees
        v.aspectLabel = aspectLabel
        v.aspectRatio = aspectRatio
        // 콜백은 coordinator 를 통해 — parent 를 매번 최신화할 수 있음
        let coord = context.coordinator
        v.onCropChanged = { rect, rot, label in coord.apply(rect, rot, label) }
        return v
    }

    func updateNSView(_ nsView: CropNSView, context: Context) {
        // 매 렌더 시 coordinator 의 parent 갱신 (stale binding 방지)
        context.coordinator.parent = self

        // 외부 binding 변경 반영 — isApplyingExternal 플래그로 didSet 의 onCropChanged
        // 재호출을 막아 피드백 루프 방지.
        nsView.isApplyingExternal = true
        defer { nsView.isApplyingExternal = false }

        if nsView.image != image { nsView.image = image }
        if nsView.cropRect != cropRect { nsView.cropRect = cropRect }
        if nsView.rotationDegrees != rotationDegrees { nsView.rotationDegrees = rotationDegrees }
        if nsView.aspectLabel != aspectLabel { nsView.aspectLabel = aspectLabel }
        if nsView.aspectRatio != aspectRatio { nsView.aspectRatio = aspectRatio }
    }
}
