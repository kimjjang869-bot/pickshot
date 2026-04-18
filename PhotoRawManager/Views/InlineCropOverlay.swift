import SwiftUI
import AppKit

/// 프리뷰 위에 오버레이되는 인라인 크롭 UI — 이미지 실제 fit 영역에 정확히 정렬.
///
/// 주요 동작:
/// - 일반 드래그: **자유 조정** (종횡비 무시)
/// - Shift+드래그: **현재 박스 종횡비 잠금**
/// - Option+드래그: **중심 기준** 변형
/// - 프리셋 선택: 박스를 그 비율로 한 번 세팅 (이후 드래그는 자유)
/// - 9분할 그리드: **항상 표시** (드래그 중엔 더 진하게)
/// - 핸들 위에 마우스 올리면 macOS 표준 리사이즈 커서
struct InlineCropOverlay: View {
    let photoURL: URL
    let displaySize: CGSize       // 프리뷰 GeometryReader 사이즈 (vSize)
    let imageAspectRatio: CGFloat? // 원본 이미지 W/H. nil 이면 displaySize 전체 사용
    let onDismiss: () -> Void

    @ObservedObject var store: DevelopStore = .shared

    // 드래프트 상태 (확정 전까지의 값). draftRect 는 **이미지 공간**의 정규화 좌표 (0~1)
    @State private var draftRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var draftRotation: Double = 0
    @State private var draftAspectLabel: String? = nil
    @State private var initialSettings: DevelopSettings = DevelopSettings()

    @State private var activeHandle: CropHandle? = nil
    @State private var dragStartRect: CGRect = .zero

    private let handleHitSize: CGFloat = 22

    enum CropHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, leading, trailing
        case move
    }

    struct AspectPreset: Identifiable, Hashable {
        let id: String
        let label: String
        let ratio: Double?     // nil = 자유
        let isOriginal: Bool
    }

    private let presets: [AspectPreset] = [
        AspectPreset(id: "Free",     label: "자유",   ratio: nil, isOriginal: false),
        AspectPreset(id: "1:1",      label: "1:1",    ratio: 1.0, isOriginal: false),
        AspectPreset(id: "3:2",      label: "3:2",    ratio: 3.0 / 2.0, isOriginal: false),
        AspectPreset(id: "2:3",      label: "2:3",    ratio: 2.0 / 3.0, isOriginal: false),
        AspectPreset(id: "4:5",      label: "4:5",    ratio: 4.0 / 5.0, isOriginal: false),
        AspectPreset(id: "16:9",     label: "16:9",   ratio: 16.0 / 9.0, isOriginal: false),
        AspectPreset(id: "Original", label: "원본",   ratio: nil, isOriginal: true)
    ]

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let fit = fitRect(in: geo.size)
            ZStack {
                // 어두운 바깥 마스크 (이미지 fit 영역만 밝게)
                maskLayer(fit: fit)

                // 실제 크롭 박스 (이미지 공간 좌표 → 캔버스 좌표)
                let cropScreenRect = cropRectInScreen(fit: fit)
                cropBox(rect: cropScreenRect)

                // 8개 핸들
                handleCorner(at: CGPoint(x: cropScreenRect.minX, y: cropScreenRect.minY), type: .topLeft, fit: fit)
                handleCorner(at: CGPoint(x: cropScreenRect.maxX, y: cropScreenRect.minY), type: .topRight, fit: fit)
                handleCorner(at: CGPoint(x: cropScreenRect.minX, y: cropScreenRect.maxY), type: .bottomLeft, fit: fit)
                handleCorner(at: CGPoint(x: cropScreenRect.maxX, y: cropScreenRect.maxY), type: .bottomRight, fit: fit)
                handleEdge(at: CGPoint(x: cropScreenRect.midX, y: cropScreenRect.minY), type: .top, fit: fit, horizontal: true)
                handleEdge(at: CGPoint(x: cropScreenRect.midX, y: cropScreenRect.maxY), type: .bottom, fit: fit, horizontal: true)
                handleEdge(at: CGPoint(x: cropScreenRect.minX, y: cropScreenRect.midY), type: .leading, fit: fit, horizontal: false)
                handleEdge(at: CGPoint(x: cropScreenRect.maxX, y: cropScreenRect.midY), type: .trailing, fit: fit, horizontal: false)

                // 박스 내부 드래그 = 이동
                moveArea(rect: cropScreenRect, fit: fit)

                // 하단 툴바
                VStack {
                    Spacer()
                    cropToolbar
                        .padding(.bottom, 20)
                }
            }
        }
        .contentShape(Rectangle())
        .onAppear { initializeDraft() }
    }

    // MARK: - Fit Rect 계산

    /// 이미지가 display 안에 fit 된 실제 사각형.
    /// imageAspectRatio 가 nil 이면 display 전체 반환.
    private func fitRect(in canvasSize: CGSize) -> CGRect {
        guard let aspect = imageAspectRatio, aspect > 0,
              canvasSize.width > 0, canvasSize.height > 0 else {
            return CGRect(origin: .zero, size: canvasSize)
        }
        let canvasAspect = canvasSize.width / canvasSize.height
        var fitSize: CGSize
        if aspect > canvasAspect {
            // 이미지가 가로로 더 넓음 → 가로 맞춤
            fitSize = CGSize(width: canvasSize.width, height: canvasSize.width / aspect)
        } else {
            fitSize = CGSize(width: canvasSize.height * aspect, height: canvasSize.height)
        }
        let origin = CGPoint(
            x: (canvasSize.width - fitSize.width) / 2,
            y: (canvasSize.height - fitSize.height) / 2
        )
        return CGRect(origin: origin, size: fitSize)
    }

    /// draftRect (이미지 공간 0~1) 를 화면 좌표로 변환.
    private func cropRectInScreen(fit: CGRect) -> CGRect {
        return CGRect(
            x: fit.origin.x + draftRect.origin.x * fit.width,
            y: fit.origin.y + draftRect.origin.y * fit.height,
            width: draftRect.width * fit.width,
            height: draftRect.height * fit.height
        )
    }

    // MARK: - Initialize

    private func initializeDraft() {
        initialSettings = store.get(for: photoURL)
        if let existing = initialSettings.cropRect {
            // 기존 크롭 있으면 그대로 불러옴
            draftRect = existing
            draftAspectLabel = initialSettings.cropAspectLabel ?? "Original"
        } else {
            // 라이트룸과 동일 기본값: 전체 이미지 + 원본 종횡비
            draftRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            draftAspectLabel = "Original"
        }
        draftRotation = initialSettings.cropRotation
    }

    // MARK: - Mask Layer

    private func maskLayer(fit: CGRect) -> some View {
        GeometryReader { geo in
            let cropScreenRect = cropRectInScreen(fit: fit)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: geo.size))
                p.addRect(cropScreenRect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
        }
    }

    // MARK: - Crop Box + Grid

    private func cropBox(rect: CGRect) -> some View {
        ZStack {
            // 흰색 테두리
            Rectangle()
                .stroke(Color.white.opacity(0.95), lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            // 9분할 (rule of thirds) — 항상 표시
            Path { path in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(activeHandle != nil ? 0.7 : 0.45), lineWidth: 0.75)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Handles (with NSCursor)

    @ViewBuilder
    private func handleCorner(at pt: CGPoint, type: CropHandle, fit: CGRect) -> some View {
        // 라이트룸 스타일 L 자 코너 핸들
        LCornerShape(corner: type)
            .stroke(Color.white, lineWidth: 3)
            .shadow(color: .black.opacity(0.65), radius: 2)
            .frame(width: 16, height: 16)
            .position(pt)
            .contentShape(Rectangle())
            .frame(width: handleHitSize, height: handleHitSize)
            .position(pt)
            .onHover { inside in updateCursor(for: type, inside: inside) }
            .gesture(handleDrag(type, fit: fit))
    }

    @ViewBuilder
    private func handleEdge(at pt: CGPoint, type: CropHandle, fit: CGRect, horizontal: Bool) -> some View {
        // 라이트룸 스타일: 엣지 중앙에 짧은 바 (가로/세로 방향)
        Rectangle()
            .fill(Color.white)
            .frame(
                width: horizontal ? 28 : 3,
                height: horizontal ? 3 : 28
            )
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .position(pt)
            .contentShape(Rectangle())
            .frame(
                width: horizontal ? 44 : handleHitSize,
                height: horizontal ? handleHitSize : 44
            )
            .position(pt)
            .onHover { inside in updateCursor(for: type, inside: inside) }
            .gesture(handleDrag(type, fit: fit))
    }

    private func moveArea(rect: CGRect, fit: CGRect) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: rect.width - 24, height: rect.height - 24)
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.openHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(handleDrag(.move, fit: fit))
    }

    private func updateCursor(for type: CropHandle, inside: Bool) {
        guard inside else { NSCursor.arrow.set(); return }
        switch type {
        case .topLeft, .bottomRight, .topRight, .bottomLeft:
            // macOS NSCursor 에 대각선 리사이즈가 공개 API 로 없어서 좌우로 폴백
            NSCursor.resizeLeftRight.set()
        case .top, .bottom:
            NSCursor.resizeUpDown.set()
        case .leading, .trailing:
            NSCursor.resizeLeftRight.set()
        case .move:
            NSCursor.openHand.set()
        }
    }

    // MARK: - Drag Gesture

    private func handleDrag(_ handle: CropHandle, fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if activeHandle == nil {
                    activeHandle = handle
                    dragStartRect = draftRect
                }
                guard activeHandle == handle else { return }
                let shift = NSEvent.modifierFlags.contains(.shift)
                let option = NSEvent.modifierFlags.contains(.option)
                // 이미지 공간 기준 normalized delta
                let dxImg = v.translation.width / max(fit.width, 1)
                let dyImg = v.translation.height / max(fit.height, 1)

                var newRect = dragStartRect
                applyHandleDrag(&newRect, handle: handle, dx: dxImg, dy: dyImg, shift: shift, option: option)
                draftRect = clampNormalized(newRect)
                NotificationCenter.default.post(name: .pickShotAdjustmentActivity, object: nil)
            }
            .onEnded { _ in
                activeHandle = nil
                NSCursor.arrow.set()
            }
    }

    private func applyHandleDrag(
        _ rect: inout CGRect,
        handle: CropHandle,
        dx: CGFloat, dy: CGFloat,
        shift: Bool, option: Bool
    ) {
        // 이동은 단순
        if handle == .move {
            rect.origin.x = (dragStartRect.origin.x + dx).clamped(to: 0...(1 - dragStartRect.width))
            rect.origin.y = (dragStartRect.origin.y + dy).clamped(to: 0...(1 - dragStartRect.height))
            return
        }

        let startCx = dragStartRect.midX
        let startCy = dragStartRect.midY

        switch handle {
        case .topLeft:
            rect.origin.x = dragStartRect.minX + dx
            rect.origin.y = dragStartRect.minY + dy
            rect.size.width = dragStartRect.maxX - rect.origin.x
            rect.size.height = dragStartRect.maxY - rect.origin.y
        case .topRight:
            rect.size.width = dragStartRect.width + dx
            rect.origin.y = dragStartRect.minY + dy
            rect.size.height = dragStartRect.maxY - rect.origin.y
        case .bottomLeft:
            rect.origin.x = dragStartRect.minX + dx
            rect.size.width = dragStartRect.maxX - rect.origin.x
            rect.size.height = dragStartRect.height + dy
        case .bottomRight:
            rect.size.width = dragStartRect.width + dx
            rect.size.height = dragStartRect.height + dy
        case .top:
            rect.origin.y = dragStartRect.minY + dy
            rect.size.height = dragStartRect.maxY - rect.origin.y
        case .bottom:
            rect.size.height = dragStartRect.height + dy
        case .leading:
            rect.origin.x = dragStartRect.minX + dx
            rect.size.width = dragStartRect.maxX - rect.origin.x
        case .trailing:
            rect.size.width = dragStartRect.width + dx
        default:
            break
        }

        // 최소 크기
        rect.size.width = max(0.05, rect.size.width)
        rect.size.height = max(0.05, rect.size.height)

        // 🔑 Shift 눌렀을 때만 이미지 공간 비율 유지.
        //    프리셋 선택된 경우에도 드래그 중에는 무시 — 프리셋은 "초기 세팅" 용도.
        if shift {
            let aspectImgSpace = imageSpaceAspect()
            adjustForAspect(&rect, handle: handle, aspect: aspectImgSpace)
        }

        // 중심 기준 (Option)
        if option {
            let newW = rect.width
            let newH = rect.height
            rect.origin.x = startCx - newW / 2
            rect.origin.y = startCy - newH / 2
        }
    }

    /// 현재 크롭 박스의 이미지-공간 종횡비. Shift+드래그로 잠글 때 기준값.
    private func imageSpaceAspect() -> CGFloat {
        guard dragStartRect.height > 0 else { return 1 }
        // draftRect 는 이미지 공간의 비율이므로, 실제 픽셀 비율로 변환하려면
        // imageAspectRatio 를 곱해야 함.
        // (draftRect.width * imageW) / (draftRect.height * imageH)
        //   = (draftRect.width / draftRect.height) * imageAspectRatio
        let imgAR = imageAspectRatio ?? 1
        return (dragStartRect.width / dragStartRect.height) * imgAR
    }

    /// rect 를 지정한 **픽셀 공간 종횡비** 로 맞춤 (draft 는 image 공간 정규화이므로 변환 필요).
    private func adjustForAspect(_ rect: inout CGRect, handle: CropHandle, aspect pixelAspect: CGFloat) {
        let imgAR = imageAspectRatio ?? 1
        // image 공간 aspect = pixelAspect / imgAR
        let normalizedAspect = pixelAspect / imgAR

        switch handle {
        case .top, .bottom:
            let newW = rect.height * normalizedAspect
            let cx = (rect.minX + rect.maxX) / 2
            rect.origin.x = cx - newW / 2
            rect.size.width = newW
        case .leading, .trailing:
            let newH = rect.width / normalizedAspect
            let cy = (rect.minY + rect.maxY) / 2
            rect.origin.y = cy - newH / 2
            rect.size.height = newH
        default:
            // 코너: 더 긴 변 기준
            let byWidth = rect.width / normalizedAspect
            let byHeight = rect.height * normalizedAspect
            if byHeight > rect.width {
                rect.size.width = byHeight
            } else {
                rect.size.height = byWidth
            }
        }
    }

    private func clampNormalized(_ rect: CGRect) -> CGRect {
        var r = rect
        r.origin.x = r.origin.x.clamped(to: 0...1)
        r.origin.y = r.origin.y.clamped(to: 0...1)
        r.size.width = min(r.size.width, 1 - r.origin.x)
        r.size.height = min(r.size.height, 1 - r.origin.y)
        r.size.width = max(0.05, r.size.width)
        r.size.height = max(0.05, r.size.height)
        return r
    }

    // MARK: - Crop Toolbar

    private var cropToolbar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(presets) { preset in
                    Button(preset.label) { selectPreset(preset) }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 11))
                    Text(draftAspectLabel ?? "자유")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .foregroundColor(.white)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 88)

            Divider().frame(height: 18).opacity(0.3)

            Image(systemName: "rotate.left")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
            DoubleClickResetSlider(
                value: $draftRotation,
                range: -45...45,
                defaultValue: 0,
                step: 0.5,
                bigStep: 5,
                format: { String(format: "%+.1f°", $0) }
            )
            .frame(width: 140)
            Text(String(format: "%+.1f°", draftRotation))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 42, alignment: .trailing)

            Divider().frame(height: 18).opacity(0.3)

            Button(action: cancelCrop) {
                Text("취소")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundColor(.white.opacity(0.85))
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button(action: confirmCrop) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("크롭")
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundColor(.black)
                .background(Capsule().fill(Color(red: 1.0, green: 0.76, blue: 0.03)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(red: 1.0, green: 0.76, blue: 0.03).opacity(0.3), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
        )
    }

    // MARK: - Preset / Confirm / Cancel

    private func selectPreset(_ preset: AspectPreset) {
        draftAspectLabel = preset.id
        if let ratio = preset.ratio {
            // 프리셋 비율(픽셀 공간) 을 이미지 공간으로 변환
            let imgAR = imageAspectRatio ?? 1
            let normalizedAspect = CGFloat(ratio) / imgAR

            let cx = draftRect.midX
            let cy = draftRect.midY
            var newRect = draftRect
            let currentNormalizedAR = draftRect.width / draftRect.height
            if currentNormalizedAR > normalizedAspect {
                newRect.size.width = draftRect.height * normalizedAspect
            } else {
                newRect.size.height = draftRect.width / normalizedAspect
            }
            newRect.origin.x = cx - newRect.width / 2
            newRect.origin.y = cy - newRect.height / 2
            draftRect = clampNormalized(newRect)
        } else if preset.isOriginal {
            draftRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        } else {
            // 자유 — 현재 박스 유지
        }
    }

    private func confirmCrop() {
        var s = store.get(for: photoURL)
        if draftRect.width > 0.98 && draftRect.height > 0.98 && draftRect.origin.x < 0.01 && draftRect.origin.y < 0.01 {
            s.cropRect = nil
            s.cropAspectLabel = nil
        } else {
            s.cropRect = draftRect
            s.cropAspectLabel = draftAspectLabel
        }
        s.cropRotation = draftRotation
        store.set(s, for: photoURL)
        onDismiss()
    }

    private func cancelCrop() {
        store.set(initialSettings, for: photoURL)
        onDismiss()
    }
}

// MARK: - L-shaped Corner Handle (Lightroom-style)

/// 크롭 박스 모서리의 L 자 핸들 모양. 각 모서리 방향에 맞게 선분 두 개 그림.
private struct LCornerShape: Shape {
    let corner: InlineCropOverlay.CropHandle

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        switch corner {
        case .topLeft:
            p.move(to: CGPoint(x: 0, y: h))
            p.addLine(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w, y: 0))
        case .topRight:
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w, y: h))
        case .bottomLeft:
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 0, y: h))
            p.addLine(to: CGPoint(x: w, y: h))
        case .bottomRight:
            p.move(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: 0, y: h))
        default:
            break
        }
        return p
    }
}

// MARK: - Comparable clamp

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
