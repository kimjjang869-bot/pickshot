import SwiftUI
import AppKit

/// 프리뷰 위에 오버레이되는 인라인 크롭 UI.
/// Mantis / Photos.app 스타일.
///
/// 특징:
/// - 드래그로 코너/엣지 핸들 이동
/// - Shift+드래그: 종횡비 잠금
/// - Option+드래그: 중심 기준 변형
/// - 3x3 rule-of-thirds 격자 (드래그 중에만 진하게)
/// - 하단 플로팅 툴바: 종횡비 프리셋 · 회전 다이얼 · 확정/취소
struct InlineCropOverlay: View {
    let photoURL: URL
    let displaySize: CGSize     // 프리뷰 화면에서 이미지가 차지하는 실제 크기 (fit)
    /// 크롭 모드 종료 콜백 (저장 완료 or 취소)
    let onDismiss: () -> Void

    @ObservedObject var store: DevelopStore = .shared

    // 드래프트 상태 (확정 전까지 변경 중인 값)
    @State private var draftRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)  // 정규화 0~1
    @State private var draftRotation: Double = 0
    @State private var draftAspectLabel: String? = nil  // "3:2" 등
    @State private var initialSettings: DevelopSettings = DevelopSettings()

    @State private var activeHandle: CropHandle? = nil
    @State private var dragStartRect: CGRect = .zero

    private let handleSize: CGFloat = 20
    private let edgeHandleLength: CGFloat = 36

    enum CropHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, leading, trailing
        case move
    }

    struct AspectPreset: Identifiable, Hashable {
        let id: String  // "Free", "1:1" 등
        let label: String
        let ratio: Double?  // nil = Free / Original
        let isOriginal: Bool
    }

    private let presets: [AspectPreset] = [
        AspectPreset(id: "Free", label: "자유", ratio: nil, isOriginal: false),
        AspectPreset(id: "1:1", label: "1:1", ratio: 1.0, isOriginal: false),
        AspectPreset(id: "3:2", label: "3:2", ratio: 3.0 / 2.0, isOriginal: false),
        AspectPreset(id: "4:5", label: "4:5", ratio: 4.0 / 5.0, isOriginal: false),
        AspectPreset(id: "16:9", label: "16:9", ratio: 16.0 / 9.0, isOriginal: false),
        AspectPreset(id: "Original", label: "원본", ratio: nil, isOriginal: true)
    ]

    var body: some View {
        ZStack {
            // 어두운 배경 (크롭 박스 밖)
            maskLayer

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let rect = CGRect(
                    x: draftRect.origin.x * w,
                    y: draftRect.origin.y * h,
                    width: draftRect.width * w,
                    height: draftRect.height * h
                )

                ZStack {
                    // 크롭 박스 보더 + 격자
                    cropBox(rect: rect)
                    // 코너 핸들
                    handle(at: CGPoint(x: rect.minX, y: rect.minY), handle: .topLeft, w: w, h: h)
                    handle(at: CGPoint(x: rect.maxX, y: rect.minY), handle: .topRight, w: w, h: h)
                    handle(at: CGPoint(x: rect.minX, y: rect.maxY), handle: .bottomLeft, w: w, h: h)
                    handle(at: CGPoint(x: rect.maxX, y: rect.maxY), handle: .bottomRight, w: w, h: h)
                    // 엣지 핸들
                    edgeHandle(at: CGPoint(x: rect.midX, y: rect.minY), handle: .top, w: w, h: h, isHorizontal: true)
                    edgeHandle(at: CGPoint(x: rect.midX, y: rect.maxY), handle: .bottom, w: w, h: h, isHorizontal: true)
                    edgeHandle(at: CGPoint(x: rect.minX, y: rect.midY), handle: .leading, w: w, h: h, isHorizontal: false)
                    edgeHandle(at: CGPoint(x: rect.maxX, y: rect.midY), handle: .trailing, w: w, h: h, isHorizontal: false)
                }
                // 박스 내부 클릭 시 이동
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if activeHandle == nil {
                                // 박스 내부 드래그 시작 → 이동
                                let p = v.startLocation
                                if rect.contains(p) {
                                    activeHandle = .move
                                    dragStartRect = draftRect
                                }
                            }
                            if activeHandle == .move {
                                let dx = v.translation.width / w
                                let dy = v.translation.height / h
                                var newRect = dragStartRect
                                newRect.origin.x = (dragStartRect.origin.x + dx).clamped(to: 0...(1 - dragStartRect.width))
                                newRect.origin.y = (dragStartRect.origin.y + dy).clamped(to: 0...(1 - dragStartRect.height))
                                draftRect = newRect
                                NotificationCenter.default.post(name: .pickShotAdjustmentActivity, object: nil)
                            }
                        }
                        .onEnded { _ in activeHandle = nil }
                )
            }

            // 하단 크롭 툴바
            VStack {
                Spacer()
                cropToolbar
                    .padding(.bottom, 20)
            }
        }
        .contentShape(Rectangle())
        .onAppear { initializeDraft() }
        .background(
            // ESC / Enter 키 처리 (KeyEventHandling 이 PhotoPreview 레벨에서 가로채므로 보완)
            Color.clear
        )
    }

    // MARK: - Initialize

    private func initializeDraft() {
        initialSettings = store.get(for: photoURL)
        if let existing = initialSettings.cropRect {
            draftRect = existing
        } else {
            draftRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        }
        draftRotation = initialSettings.cropRotation
        draftAspectLabel = initialSettings.cropAspectLabel
    }

    // MARK: - Mask Layer

    private var maskLayer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let r = CGRect(
                x: draftRect.origin.x * w,
                y: draftRect.origin.y * h,
                width: draftRect.width * w,
                height: draftRect.height * h
            )
            Path { p in
                p.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
        }
    }

    // MARK: - Crop Box + Grid

    private func cropBox(rect: CGRect) -> some View {
        ZStack {
            // 테두리
            Rectangle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            // 3x3 격자
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
            .stroke(Color.white.opacity(activeHandle != nil ? 0.5 : 0.25), lineWidth: 0.5)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Handles

    private func handle(at pt: CGPoint, handle: CropHandle, w: CGFloat, h: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 10, height: 10)
            .overlay(Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.5), radius: 2)
            .position(pt)
            .contentShape(Rectangle().inset(by: -handleSize / 2))
            .frame(width: handleSize, height: handleSize)
            .position(pt)
            .gesture(cornerDrag(handle: handle, w: w, h: h))
    }

    private func edgeHandle(at pt: CGPoint, handle: CropHandle, w: CGFloat, h: CGFloat, isHorizontal: Bool) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(
                width: isHorizontal ? edgeHandleLength : 4,
                height: isHorizontal ? 4 : edgeHandleLength
            )
            .overlay(
                Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 2)
            .position(pt)
            .contentShape(Rectangle().size(width: edgeHandleLength, height: 14))
            .frame(width: isHorizontal ? edgeHandleLength : 14,
                   height: isHorizontal ? 14 : edgeHandleLength)
            .position(pt)
            .gesture(cornerDrag(handle: handle, w: w, h: h))
    }

    private func cornerDrag(handle: CropHandle, w: CGFloat, h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if activeHandle == nil {
                    activeHandle = handle
                    dragStartRect = draftRect
                }
                guard activeHandle == handle else { return }
                let shift = NSEvent.modifierFlags.contains(.shift)
                let option = NSEvent.modifierFlags.contains(.option)
                let dx = v.translation.width / w
                let dy = v.translation.height / h

                var newRect = dragStartRect
                applyHandleDrag(&newRect, handle: handle, dx: dx, dy: dy, shift: shift, option: option)
                draftRect = clampNormalized(newRect)
                NotificationCenter.default.post(name: .pickShotAdjustmentActivity, object: nil)
            }
            .onEnded { _ in activeHandle = nil }
    }

    private func applyHandleDrag(
        _ rect: inout CGRect,
        handle: CropHandle,
        dx: CGFloat, dy: CGFloat,
        shift: Bool, option: Bool
    ) {
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
        case .move:
            return
        }

        // 최소 크기 0.05 보장
        rect.size.width = max(0.05, rect.size.width)
        rect.size.height = max(0.05, rect.size.height)

        // 종횡비 잠금 (Shift 또는 프리셋 선택 시)
        let aspectRatio = effectiveAspectRatio(shiftHeld: shift)
        if let ar = aspectRatio {
            adjustForAspect(&rect, handle: handle, aspect: ar)
        }

        // 중심 기준 (Option)
        if option {
            let newW = rect.width
            let newH = rect.height
            rect.origin.x = startCx - newW / 2
            rect.origin.y = startCy - newH / 2
        }
    }

    private func effectiveAspectRatio(shiftHeld: Bool) -> CGFloat? {
        // Shift 누르면 현재 크롭 종횡비 유지
        if shiftHeld {
            guard draftRect.height > 0 else { return nil }
            return draftRect.width / draftRect.height
        }
        if let label = draftAspectLabel,
           let preset = presets.first(where: { $0.id == label }),
           let ratio = preset.ratio {
            return CGFloat(ratio)
        }
        return nil
    }

    private func adjustForAspect(_ rect: inout CGRect, handle: CropHandle, aspect: CGFloat) {
        // 핸들에 따라 축 우선순위 선택
        switch handle {
        case .top, .bottom:
            // 높이 우선 → 가로 맞춤
            let newW = rect.height * aspect
            let cx = (rect.minX + rect.maxX) / 2
            rect.origin.x = cx - newW / 2
            rect.size.width = newW
        case .leading, .trailing:
            let newH = rect.width / aspect
            let cy = (rect.minY + rect.maxY) / 2
            rect.origin.y = cy - newH / 2
            rect.size.height = newH
        default:
            // 코너: 더 긴 변에 맞춤
            let byWidth = rect.width / aspect
            let byHeight = rect.height * aspect
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
        return r
    }

    // MARK: - Crop Toolbar

    private var cropToolbar: some View {
        HStack(spacing: 10) {
            // 종횡비 프리셋
            Menu {
                ForEach(presets) { preset in
                    Button(preset.label) {
                        selectPreset(preset)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 11))
                    Text(aspectLabelDisplay)
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .foregroundColor(.white)
            }
            .menuStyle(.borderlessButton)

            Divider().frame(height: 18).opacity(0.3)

            // 회전 슬라이더
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

            // 취소
            Button(action: cancelCrop) {
                Text("취소")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundColor(.white.opacity(0.85))
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            // 확정
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
                .fill(Color.black.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(red: 1.0, green: 0.76, blue: 0.03).opacity(0.3), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
        )
    }

    private var aspectLabelDisplay: String {
        draftAspectLabel ?? "자유"
    }

    private func selectPreset(_ preset: AspectPreset) {
        draftAspectLabel = preset.id
        if let ratio = preset.ratio {
            // 중심 기준으로 종횡비 맞춤
            let cx = draftRect.midX
            let cy = draftRect.midY
            let currentAspect = draftRect.width / draftRect.height
            var newRect = draftRect
            if currentAspect > ratio {
                // 가로가 더 김 → 가로 줄이기
                newRect.size.width = draftRect.height * ratio
            } else {
                newRect.size.height = draftRect.width / ratio
            }
            newRect.origin.x = cx - newRect.width / 2
            newRect.origin.y = cy - newRect.height / 2
            draftRect = clampNormalized(newRect)
        } else if preset.isOriginal {
            // 원본 복원
            draftRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    // MARK: - Confirm / Cancel

    private func confirmCrop() {
        var s = store.get(for: photoURL)
        // 거의 전체 선택 = 크롭 제거
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
        // 원래 설정 복원 (혹시 슬라이더가 중간에 store 건드렸을 때 대비)
        store.set(initialSettings, for: photoURL)
        onDismiss()
    }
}

// MARK: - Comparable clamp

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
