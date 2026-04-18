import SwiftUI
import AppKit

/// 프리뷰 하단 비파괴 보정 플로팅 필.
/// v8.6 업데이트:
/// - 온도 켈빈(K) 값 표시
/// - 온도(파랑→노랑) · 틴트(초록→마젠타) 슬라이더 트랙 그라디언트
/// - 자동 버튼 → 실제 계산값을 슬라이더에 반영
/// - ESC → 확장 패널 닫기
/// - 커브 에디터 크기 확대
struct FloatingAdjustmentPill: View {
    let photoURL: URL

    @ObservedObject var store: DevelopStore = .shared
    @State private var expandedTool: AdjustmentTool? = nil
    @State private var fadeState: FadeState = .visible
    @State private var fadeTask: Task<Void, Never>? = nil

    private static let pipeline = DevelopPipeline()

    enum AdjustmentTool: String, Hashable {
        case exposure, wb, curve, crop, preset
    }

    enum FadeState {
        case visible, dim, hidden
        var opacity: Double {
            switch self {
            case .visible: return 1.0
            case .dim: return 0.4
            case .hidden: return 0.0
            }
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            if let tool = expandedTool {
                expandedContent(tool: tool)
            } else {
                collapsedContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(red: 1.0, green: 0.76, blue: 0.03).opacity(0.28), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
        )
        .opacity(fadeState.opacity)
        .animation(.easeOut(duration: 0.22), value: fadeState)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: expandedTool)
        .onHover { inside in if inside { kickFade() } }
        .onAppear { kickFade() }
        .onReceive(NotificationCenter.default.publisher(for: .pickShotAdjustmentActivity)) { _ in kickFade() }
        // ESC → 확장 패널 닫기
        .onReceive(NotificationCenter.default.publisher(for: .pickShotCollapseAdjustments)) { _ in
            if expandedTool != nil {
                withAnimation { expandedTool = nil }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        HStack(spacing: 4) {
            pillIcon(tool: .exposure, symbol: "sun.max.fill", badge: exposureBadge)
            pillIcon(tool: .wb, symbol: "thermometer.sun.fill", badge: wbBadge)
            pillIcon(tool: .curve, symbol: "point.bottomleft.forward.to.point.topright.scurvepath", badge: curveBadge)
            pillIcon(tool: .crop, symbol: "crop", badge: cropBadge)
            Divider().frame(height: 26).padding(.horizontal, 4).opacity(0.3)
            pillIcon(tool: .preset, symbol: "tag.fill", badge: nil)
            copyPasteButtons
            resetButton
        }
    }

    private func pillIcon(tool: AdjustmentTool, symbol: String, badge: String?) -> some View {
        let settings = store.get(for: photoURL)
        let isTouched = tool != .preset && settings.touchedComponents.contains(touchedMask(for: tool))
        return Button(action: {
            withAnimation { expandedTool = tool }
            kickFade()
        }) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 22)
                    .foregroundColor(isTouched ? Color(red: 1.0, green: 0.76, blue: 0.03) : .white.opacity(0.82))
                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.76, blue: 0.03))
                } else {
                    Color.clear.frame(height: 11)
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltipFor(tool))
    }

    private var resetButton: some View {
        Button(action: {
            var s = store.get(for: photoURL)
            guard !s.isDefault else { return }
            s.reset()
            store.set(s, for: photoURL)
            kickFade()
        }) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 32, height: 34)
                .foregroundColor(.white.opacity(store.get(for: photoURL).isDefault ? 0.35 : 0.85))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.get(for: photoURL).isDefault)
        .help("모두 리셋 (R)")
    }

    private var copyPasteButtons: some View {
        HStack(spacing: 2) {
            Button(action: copyCurrentSettings) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 32)
                    .foregroundColor(.white.opacity(store.get(for: photoURL).isDefault ? 0.3 : 0.75))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.get(for: photoURL).isDefault)
            .help("보정값 복사 (Cmd+Shift+C)")

            Button(action: pasteSettings) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 32)
                    .foregroundColor(store.clipboard == nil ? .white.opacity(0.3) : Color(red: 1.0, green: 0.76, blue: 0.03))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.clipboard == nil)
            .help("보정값 붙여넣기 (Cmd+Shift+V)")
        }
    }

    private func copyCurrentSettings() {
        let s = store.get(for: photoURL)
        guard !s.isDefault else { return }
        store.copyToClipboard(s)
        NotificationCenter.default.post(name: .pickShotAdjustmentToast, object: "보정값 복사됨")
    }

    private func pasteSettings() {
        guard store.clipboard != nil else { return }
        _ = store.pasteFromClipboard(to: [photoURL])
        NotificationCenter.default.post(name: .pickShotAdjustmentToast, object: "보정값 적용됨")
    }

    // MARK: - Expanded

    @ViewBuilder
    private func expandedContent(tool: AdjustmentTool) -> some View {
        switch tool {
        case .exposure:
            exposureExpanded
        case .wb:
            wbExpanded
        case .curve:
            curveExpanded
        case .preset:
            presetExpanded
        case .crop:
            placeholderExpanded(title: "크롭 (C 키)", subtitle: "프리뷰에서 C 를 눌러 진입하세요")
        }
    }

    // MARK: - Exposure Expanded

    private var exposureExpanded: some View {
        let binding = Binding<Double>(
            get: { store.get(for: photoURL).exposure },
            set: { newVal in
                var s = store.get(for: photoURL)
                s.exposure = max(-3.0, min(3.0, newVal))
                store.set(s, for: photoURL)
            }
        )
        let settings = store.get(for: photoURL)

        return HStack(spacing: 10) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(red: 1.0, green: 0.76, blue: 0.03))
                .frame(width: 24)

            DoubleClickResetSlider(
                value: binding,
                range: -3.0...3.0,
                defaultValue: 0,
                step: 0.1,
                bigStep: 0.5,
                format: { String(format: "%+.1f EV", $0) }
            )
            .frame(width: 240)

            Text(String(format: "%+.1f EV", settings.exposure))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 58, alignment: .trailing)

            autoComputeButton(label: "자동") {
                applyAutoExposure()
            }

            closeButton
        }
    }

    private func applyAutoExposure() {
        if let ev = Self.pipeline.computeAutoExposure(url: photoURL) {
            var s = store.get(for: photoURL)
            s.exposure = ev
            s.exposureAuto = false
            store.set(s, for: photoURL)
            NotificationCenter.default.post(name: .pickShotAdjustmentToast, object: String(format: "자동 노출: %+.1f EV", ev))
        }
    }

    // MARK: - WB Expanded (켈빈 표시 + 그라디언트)

    private var wbExpanded: some View {
        let tempBinding = Binding<Double>(
            get: { store.get(for: photoURL).temperature },
            set: { newVal in
                var s = store.get(for: photoURL)
                s.temperature = max(-100, min(100, newVal))
                store.set(s, for: photoURL)
            }
        )
        let tintBinding = Binding<Double>(
            get: { store.get(for: photoURL).tint },
            set: { newVal in
                var s = store.get(for: photoURL)
                s.tint = max(-100, min(100, newVal))
                store.set(s, for: photoURL)
            }
        )
        let settings = store.get(for: photoURL)

        return HStack(spacing: 10) {
            Image(systemName: "thermometer.sun.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(red: 1.0, green: 0.76, blue: 0.03))
                .frame(width: 24)

            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text("온도")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 24, alignment: .trailing)
                    DoubleClickResetSlider(
                        value: tempBinding,
                        range: -100...100,
                        defaultValue: 0,
                        step: 1,
                        bigStep: 10,
                        format: { _ in "" },
                        trackGradient: LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.30, blue: 0.95),  // 진한 파랑
                                Color(red: 0.50, green: 0.55, blue: 0.75),
                                Color.white.opacity(0.2),
                                Color(red: 0.85, green: 0.70, blue: 0.40),
                                Color(red: 1.0, green: 0.70, blue: 0.10)   // 진한 노랑
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 200)
                    Text(kelvinLabel(for: settings.temperature))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 52, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    Text("틴트")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 24, alignment: .trailing)
                    DoubleClickResetSlider(
                        value: tintBinding,
                        range: -100...100,
                        defaultValue: 0,
                        step: 1,
                        bigStep: 10,
                        format: { _ in "" },
                        trackGradient: LinearGradient(
                            colors: [
                                Color(red: 0.15, green: 0.85, blue: 0.35),  // 진한 초록
                                Color(red: 0.55, green: 0.70, blue: 0.55),
                                Color.white.opacity(0.2),
                                Color(red: 0.80, green: 0.45, blue: 0.75),
                                Color(red: 0.95, green: 0.15, blue: 0.75)   // 진한 마젠타
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 200)
                    Text(String(format: "%+.0f", settings.tint))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 52, alignment: .trailing)
                }
            }

            autoComputeButton(label: "자동") {
                applyAutoWB()
            }

            closeButton
        }
    }

    /// temperature (-100~+100) 를 켈빈(K) 로 환산: 0 → 5500K, ±100 → ±4500K
    private func kelvinLabel(for t: Double) -> String {
        let k = Int((5500.0 + t * 45.0).rounded())
        return "\(k)K"
    }

    private func applyAutoWB() {
        if let (temp, tint) = Self.pipeline.computeAutoWB(url: photoURL) {
            var s = store.get(for: photoURL)
            s.temperature = temp
            s.tint = tint
            s.wbAuto = false
            store.set(s, for: photoURL)
            NotificationCenter.default.post(name: .pickShotAdjustmentToast, object: "자동 WB 적용")
        }
    }

    // MARK: - Curve Expanded (크기 확대)

    private var curveExpanded: some View {
        HStack(spacing: 8) {
            CurveEditorView(photoURL: photoURL, onAutoApply: {
                applyAutoCurve()
            })
            .frame(width: 340, height: 300)
            closeButton
        }
    }

    private func applyAutoCurve() {
        if let pts = Self.pipeline.computeAutoCurve(url: photoURL) {
            var s = store.get(for: photoURL)
            s.curvePoints = pts
            s.curveAuto = false
            store.set(s, for: photoURL)
            NotificationCenter.default.post(name: .pickShotAdjustmentToast, object: "자동 커브 적용")
        }
    }

    // MARK: - Preset Expanded

    private var presetExpanded: some View {
        HStack(spacing: 8) {
            PresetPanelView(photoURL: photoURL, onDismiss: { expandedTool = nil })
            closeButton
        }
    }

    private func placeholderExpanded(title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                Text(subtitle).font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
            }
            Spacer(minLength: 12)
            closeButton
        }
        .frame(minWidth: 260)
    }

    // MARK: - Shared Buttons

    /// 자동 계산 버튼 (토글 아님 — 누를 때마다 즉시 계산 후 값 반영)
    private func autoComputeButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(
                    Capsule().fill(Color(red: 1.0, green: 0.76, blue: 0.03).opacity(0.85))
                )
                .foregroundColor(.black)
        }
        .buttonStyle(.plain)
        .help("누르면 이미지 분석 후 자동값을 슬라이더에 반영")
    }

    private var closeButton: some View {
        Button(action: {
            withAnimation { expandedTool = nil }
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Badges

    private var exposureBadge: String? {
        let s = store.get(for: photoURL)
        if s.exposure != 0 { return String(format: "%+.1f", s.exposure) }
        return nil
    }
    private var wbBadge: String? {
        let s = store.get(for: photoURL)
        if s.temperature != 0 || s.tint != 0 {
            return kelvinLabel(for: s.temperature)
        }
        return nil
    }
    private var curveBadge: String? {
        let s = store.get(for: photoURL)
        if !s.curvePoints.isEmpty { return "•" }
        return nil
    }
    private var cropBadge: String? {
        let s = store.get(for: photoURL)
        if s.cropRect != nil { return "✓" }
        if s.cropRotation != 0 { return String(format: "%+.0f°", s.cropRotation) }
        return nil
    }

    private func touchedMask(for tool: AdjustmentTool) -> DevelopSettings.ComponentMask {
        switch tool {
        case .exposure: return .exposure
        case .wb: return .whiteBalance
        case .curve: return .curve
        case .crop: return .crop
        case .preset: return .exposure
        }
    }

    private func tooltipFor(_ tool: AdjustmentTool) -> String {
        switch tool {
        case .exposure: return "노출 — [ / ] 로도 조정"
        case .wb: return "화이트 밸런스 — ; / ' 로도 조정"
        case .curve: return "톤 커브"
        case .crop: return "인라인 크롭 (C)"
        case .preset: return "프리셋 저장/불러오기"
        }
    }

    // MARK: - Fade Management

    private func kickFade() {
        fadeTask?.cancel()
        fadeState = .visible
        fadeTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run { if expandedTool == nil { fadeState = .dim } }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run { if expandedTool == nil { fadeState = .hidden } }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let pickShotAdjustmentActivity = Notification.Name("pickShotAdjustmentActivity")
    static let pickShotAdjustmentToast = Notification.Name("pickShotAdjustmentToast")
    /// ESC 로 확장 패널 닫기 요청
    static let pickShotCollapseAdjustments = Notification.Name("pickShotCollapseAdjustments")
}
