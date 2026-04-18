import SwiftUI
import AppKit

/// 더블클릭으로 기본값 리셋, 스크롤로 미세 조정 지원하는 커스텀 슬라이더.
///
/// 동작:
/// - **드래그**: 연속 값 변경 (마우스 X 위치 → 값 매핑)
/// - **더블클릭**: `defaultValue` 로 리셋
/// - **스크롤**: fine step (`step`), Shift+스크롤 = big step (`bigStep`)
/// - **좌/우 클릭**: 클릭 지점으로 즉시 이동
///
/// 시각적:
/// - 중앙(기본값) 위치에 흰색 틱
/// - 기본값 ↔ 현재값 사이 트랙이 노란색으로 채워짐
struct DoubleClickResetSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let step: Double          // fine (스크롤)
    let bigStep: Double       // Shift+scroll
    let format: (Double) -> String

    private let trackHeight: CGFloat = 4
    private let thumbDiameter: CGFloat = 14

    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let defaultRatio = ratio(for: defaultValue)
            let currentRatio = ratio(for: value)

            ZStack(alignment: .leading) {
                // 배경 트랙
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: trackHeight)

                // 기본값 → 현재값 구간 (노란 채움)
                let minR = min(defaultRatio, currentRatio)
                let maxR = max(defaultRatio, currentRatio)
                Capsule()
                    .fill(Color(red: 1.0, green: 0.76, blue: 0.03))
                    .frame(width: max(0, (maxR - minR) * width), height: trackHeight)
                    .offset(x: minR * width)

                // 기본값 틱
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 1.5, height: 10)
                    .offset(x: defaultRatio * width - 0.75)

                // 썸
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: currentRatio * width - thumbDiameter / 2)
                    .overlay(
                        Circle()
                            .stroke(Color(red: 1.0, green: 0.76, blue: 0.03), lineWidth: isDragging ? 2 : 0)
                            .frame(width: thumbDiameter + 4, height: thumbDiameter + 4)
                            .offset(x: currentRatio * width - thumbDiameter / 2 - 2)
                    )
            }
            .frame(height: thumbDiameter + 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        isDragging = true
                        updateValue(from: v.location.x, width: width)
                        NotificationCenter.default.post(name: .pickShotAdjustmentActivity, object: nil)
                    }
                    .onEnded { _ in isDragging = false }
            )
            // macOS: 더블클릭 (SwiftUI 의 count:2 탭제스처)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(.easeOut(duration: 0.15)) { value = defaultValue }
                }
            )
            .overlay(
                ScrollCapture(onScroll: { deltaY, shift in
                    // 휠 위로 = 증가, 아래 = 감소. Shift = big step.
                    let s = shift ? bigStep : step
                    let next = (value + deltaY * s).clamped(to: range)
                    value = snap(next)
                    NotificationCenter.default.post(name: .pickShotAdjustmentActivity, object: nil)
                })
                .allowsHitTesting(true)
            )
        }
        .frame(height: thumbDiameter + 4)
    }

    private func ratio(for v: Double) -> CGFloat {
        let lo = range.lowerBound
        let hi = range.upperBound
        guard hi > lo else { return 0 }
        let r = (v - lo) / (hi - lo)
        return CGFloat(max(0, min(1, r)))
    }

    private func updateValue(from x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let ratio = Double((x / width).clamped(to: 0...1))
        let newVal = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
        value = snap(newVal)
    }

    private func snap(_ v: Double) -> Double {
        guard step > 0 else { return v }
        return (v / step).rounded() * step
    }
}

// MARK: - Scroll Capture (NSView)

/// SwiftUI 에 스크롤 휠 이벤트를 가져오기 위한 NSView 래퍼.
private struct ScrollCapture: NSViewRepresentable {
    let onScroll: (Double, Bool) -> Void

    func makeNSView(context: Context) -> ScrollView {
        let v = ScrollView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: ScrollView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollView: NSView {
        var onScroll: ((Double, Bool) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            let shift = event.modifierFlags.contains(.shift)
            // scrollingDeltaY 부호: 위로 스크롤 = 양수
            let dy = Double(event.scrollingDeltaY)
            guard abs(dy) > 0.1 else { return }
            onScroll?(dy > 0 ? 1 : -1, shift)
        }

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil /* 클릭은 통과 */ }
    }
}

// MARK: - Comparable clamp

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
