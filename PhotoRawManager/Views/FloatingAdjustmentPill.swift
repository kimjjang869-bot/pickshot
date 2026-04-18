import SwiftUI

/// 프리뷰 하단에 떠 있는 비파괴 보정 컨트롤 필.
///
/// UI 상태:
/// - `.collapsed`: 5개 아이콘 (노출 · WB · 커브 · 크롭 · 리셋). 각 아이콘 아래 현재 값 뱃지.
/// - `.expanded(tool)`: 선택된 도구의 슬라이더가 필 자리를 차지.
///
/// 자동 숨김:
/// - 마우스 움직임 or 키 입력 → 즉시 표시
/// - 2초 무반응 → 불투명도 40%
/// - 5초 무반응 → 완전히 숨김 (다시 마우스 이동 시 재등장)
struct FloatingAdjustmentPill: View {
    let photoURL: URL

    @ObservedObject var store: DevelopStore = .shared
    @State private var expandedTool: AdjustmentTool? = nil
    @State private var fadeState: FadeState = .visible
    @State private var fadeTask: Task<Void, Never>? = nil

    enum AdjustmentTool: String, Hashable {
        case exposure, wb, curve, crop
    }

    enum FadeState {
        case visible          // opacity 1.0
        case dim              // opacity 0.4 (2초 무반응 후)
        case hidden           // opacity 0.0 (5초 무반응 후)

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
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(red: 1.0, green: 0.76, blue: 0.03).opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
        )
        .opacity(fadeState.opacity)
        .animation(.easeOut(duration: 0.22), value: fadeState)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: expandedTool)
        .onHover { inside in
            if inside { kickFade() }
        }
        .onAppear { kickFade() }
        .onReceive(NotificationCenter.default.publisher(for: .pickShotAdjustmentActivity)) { _ in
            kickFade()
        }
        .contentShape(Rectangle())
    }

    // MARK: - Collapsed (아이콘 5개)

    private var collapsedContent: some View {
        HStack(spacing: 4) {
            pillIcon(
                tool: .exposure,
                symbol: "sun.max.fill",
                badge: exposureBadge
            )
            pillIcon(
                tool: .wb,
                symbol: "thermometer.sun.fill",
                badge: wbBadge
            )
            pillIcon(
                tool: .curve,
                symbol: "point.bottomleft.forward.to.point.topright.scurvepath",
                badge: curveBadge
            )
            pillIcon(
                tool: .crop,
                symbol: "crop",
                badge: cropBadge
            )
            Divider()
                .frame(height: 26)
                .padding(.horizontal, 4)
                .opacity(0.3)
            resetButton
        }
    }

    private func pillIcon(tool: AdjustmentTool, symbol: String, badge: String?) -> some View {
        let settings = store.get(for: photoURL)
        let isTouched = settings.touchedComponents.contains(touchedMask(for: tool))

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
        case .crop:
            placeholderExpanded(title: "인라인 크롭 · Day 4 예정", subtitle: "C 키로 진입 예정")
        }
    }

    // 노출 슬라이더
    private var exposureExpanded: some View {
        let binding = Binding<Double>(
            get: { store.get(for: photoURL).exposure },
            set: { newVal in
                var s = store.get(for: photoURL)
                s.exposure = max(-2.0, min(2.0, newVal))
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
                range: -2.0...2.0,
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

            autoButton(
                isOn: settings.exposureAuto,
                label: "자동"
            ) {
                var s = store.get(for: photoURL)
                s.exposureAuto.toggle()
                store.set(s, for: photoURL)
            }

            closeButton
        }
    }

    // 화이트밸런스 (온도 + 틴트)
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
                    Text("온도").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.6)).frame(width: 24, alignment: .trailing)
                    DoubleClickResetSlider(
                        value: tempBinding,
                        range: -100...100,
                        defaultValue: 0,
                        step: 1,
                        bigStep: 10,
                        format: { String(format: "%+.0f", $0) }
                    ).frame(width: 180)
                    Text(String(format: "%+.0f", settings.temperature))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 32, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    Text("틴트").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.6)).frame(width: 24, alignment: .trailing)
                    DoubleClickResetSlider(
                        value: tintBinding,
                        range: -100...100,
                        defaultValue: 0,
                        step: 1,
                        bigStep: 10,
                        format: { String(format: "%+.0f", $0) }
                    ).frame(width: 180)
                    Text(String(format: "%+.0f", settings.tint))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 32, alignment: .trailing)
                }
            }

            autoButton(
                isOn: settings.wbAuto,
                label: "자동"
            ) {
                var s = store.get(for: photoURL)
                s.wbAuto.toggle()
                store.set(s, for: photoURL)
            }

            closeButton
        }
    }

    // 커브 에디터 (히스토그램 위에 포인트 드래그)
    private var curveExpanded: some View {
        HStack(spacing: 8) {
            CurveEditorView(photoURL: photoURL)
                .frame(width: 220, height: 210)
            closeButton
        }
    }

    private func placeholderExpanded(title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.4))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                Text(subtitle).font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
            }
            Spacer(minLength: 12)
            closeButton
        }
        .frame(minWidth: 260)
    }

    // MARK: - Shared UI

    private func autoButton(isOn: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isOn ? Color(red: 1.0, green: 0.76, blue: 0.03) : Color.white.opacity(0.1))
                )
                .foregroundColor(isOn ? .black : .white.opacity(0.75))
        }
        .buttonStyle(.plain)
        .help("자동 적용 (Option+\(label == "자동" ? "E/W" : ""))")
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
        if s.exposureAuto { return "A" }
        if s.exposure != 0 { return String(format: "%+.1f", s.exposure) }
        return nil
    }
    private var wbBadge: String? {
        let s = store.get(for: photoURL)
        if s.wbAuto { return "A" }
        if s.temperature != 0 || s.tint != 0 {
            let t = Int(s.temperature)
            return t >= 0 ? "+\(t)" : "\(t)"
        }
        return nil
    }
    private var curveBadge: String? {
        let s = store.get(for: photoURL)
        if s.curveAuto { return "A" }
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
        }
    }

    private func tooltipFor(_ tool: AdjustmentTool) -> String {
        switch tool {
        case .exposure: return "노출 — [ / ] 로도 조정"
        case .wb: return "화이트 밸런스 — ; / ' 로도 조정"
        case .curve: return "톤 커브 (K) — Day 3 예정"
        case .crop: return "크롭 (C) — Day 4 예정"
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

// MARK: - Notification

extension Notification.Name {
    /// 사용자 활동 (마우스 이동, 키 입력) 감지 → 플로팅 필 재등장.
    static let pickShotAdjustmentActivity = Notification.Name("pickShotAdjustmentActivity")
}
