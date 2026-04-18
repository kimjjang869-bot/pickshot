import SwiftUI
import AppKit

/// 비파괴 톤 커브 에디터 — 히스토그램 위에 포인트 드래그로 CIToneCurve 편집.
///
/// 지원:
/// - 포인트 드래그 (x, y 모두 0~1 정규화)
/// - 빈 곳 클릭 → 새 포인트 추가 (최대 5개, CIToneCurve 한계)
/// - 포인트 더블클릭 → 삭제 (단 첫/마지막은 삭제 불가)
/// - 히스토그램 배경 (RGB 합성)
/// - 자동 커브 토글
/// - 프리셋 버튼: 선형 / S / Fade
struct CurveEditorView: View {
    let photoURL: URL
    @ObservedObject var store: DevelopStore = .shared
    @State private var histogramData: HistogramData? = nil

    // 드래그 중인 포인트 인덱스 (nil 이면 드래그 안 함)
    @State private var dragPointIndex: Int? = nil

    private let gridSize: CGSize = CGSize(width: 200, height: 160)
    private let pointRadius: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.76, blue: 0.03))
                Text("톤 커브").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)

                Spacer()

                Toggle(isOn: Binding(
                    get: { store.get(for: photoURL).curveAuto },
                    set: { newVal in
                        var s = store.get(for: photoURL)
                        s.curveAuto = newVal
                        store.set(s, for: photoURL)
                    }
                )) {
                    Text("자동")
                        .font(.system(size: 10, weight: .bold))
                }
                .toggleStyle(AutoPillToggleStyle())
                .help("자동 히스토그램 매칭 커브 (Option+K)")
            }

            ZStack {
                // 배경
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )

                // 격자 가이드 (3x3)
                gridLines

                // 히스토그램 (배경)
                if let data = histogramData {
                    ZStack {
                        HistogramPath(values: data.luminance).fill(Color.gray.opacity(0.25))
                        HistogramPath(values: data.red).fill(Color.red.opacity(0.25))
                        HistogramPath(values: data.green).fill(Color.green.opacity(0.25))
                        HistogramPath(values: data.blue).fill(Color.blue.opacity(0.25))
                    }
                    .allowsHitTesting(false)
                    .padding(4)
                }

                // 커브 + 포인트
                curveCanvas
            }
            .frame(width: gridSize.width, height: gridSize.height)

            // 프리셋 버튼
            HStack(spacing: 4) {
                curvePresetButton(label: "선형", points: linearPoints)
                curvePresetButton(label: "S 커브", points: sCurvePoints)
                curvePresetButton(label: "Fade", points: fadePoints)
                Spacer()
                Button(action: resetCurve) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .help("커브 리셋")
            }
            .padding(.top, 2)
        }
        .padding(8)
        .onAppear { loadHistogram() }
        .onChange(of: photoURL) { _ in loadHistogram() }
    }

    // MARK: - Curve Canvas

    private var curveCanvas: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let points = currentPoints(in: CGSize(width: w, height: h))

            ZStack {
                // 커브 선
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    // Catmull-Rom 비슷한 부드러운 곡선 (간단히 cubic bezier 사용)
                    for i in 1..<points.count {
                        let prev = points[i - 1]
                        let curr = points[i]
                        let controlDx = (curr.x - prev.x) * 0.5
                        path.addCurve(
                            to: curr,
                            control1: CGPoint(x: prev.x + controlDx, y: prev.y),
                            control2: CGPoint(x: curr.x - controlDx, y: curr.y)
                        )
                    }
                }
                .stroke(Color(red: 1.0, green: 0.76, blue: 0.03), lineWidth: 2)

                // 포인트들
                ForEach(0..<points.count, id: \.self) { i in
                    Circle()
                        .fill(i == dragPointIndex ? Color.yellow : Color.white)
                        .frame(width: pointRadius * 2, height: pointRadius * 2)
                        .overlay(
                            Circle().stroke(Color(red: 1.0, green: 0.76, blue: 0.03), lineWidth: 1.5)
                        )
                        .position(points[i])
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(at: value.location, in: CGSize(width: w, height: h))
                    }
                    .onEnded { _ in dragPointIndex = nil }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    handleDoubleTap(in: CGSize(width: w, height: h))
                }
            )
        }
        .padding(4)
    }

    private var gridLines: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                // 3x3 격자
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
                // 대각선
                path.move(to: CGPoint(x: 0, y: h))
                path.addLine(to: CGPoint(x: w, y: 0))
            }
            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        }
        .padding(4)
    }

    // MARK: - Point Math

    /// 현재 저장된 포인트들을 캔버스 좌표로 변환 (x 정렬, 최소 2개 보장)
    private func currentPoints(in size: CGSize) -> [CGPoint] {
        let settings = store.get(for: photoURL)
        var raw = settings.curvePoints.sorted { $0.x < $1.x }
        if raw.isEmpty {
            // 기본 선형 — 양 끝 2점
            raw = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        }
        // 자동이면 내부 자동 포인트 프리뷰
        if settings.curveAuto && settings.curvePoints.isEmpty {
            raw = sCurvePoints  // 자동 커브의 시각 표현
        }
        return raw.map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) }
    }

    private func handleDrag(at location: CGPoint, in size: CGSize) {
        var settings = store.get(for: photoURL)
        if settings.curvePoints.isEmpty {
            // 기본 선형 2점 추가 후 시작
            settings.curvePoints = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        }
        // 드래그 중 포인트가 정해져 있으면 그거 이동
        if let idx = dragPointIndex {
            settings.curvePoints = updatePoint(settings.curvePoints, index: idx, toCanvas: location, size: size)
            store.set(settings, for: photoURL)
            return
        }

        // 가장 가까운 포인트 찾기 (반경 12pt 이내면 드래그)
        let canvasPoints = settings.curvePoints.sorted { $0.x < $1.x }.map {
            CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height)
        }
        let hitIdx = canvasPoints.enumerated().min { a, b in
            distance(a.element, location) < distance(b.element, location)
        }?.offset
        if let idx = hitIdx, distance(canvasPoints[idx], location) < 12 {
            dragPointIndex = idx
            settings.curvePoints = updatePoint(settings.curvePoints, index: idx, toCanvas: location, size: size)
            store.set(settings, for: photoURL)
        } else {
            // 빈 곳 탭 — 5개 미만이면 새 포인트 추가
            if settings.curvePoints.count < 5 {
                let newPoint = CGPoint(
                    x: (location.x / size.width).clamped(to: 0...1),
                    y: (1 - location.y / size.height).clamped(to: 0...1)
                )
                settings.curvePoints.append(newPoint)
                settings.curvePoints.sort { $0.x < $1.x }
                dragPointIndex = settings.curvePoints.firstIndex { abs($0.x - newPoint.x) < 0.0001 }
                store.set(settings, for: photoURL)
            }
        }
    }

    private func handleDoubleTap(in size: CGSize) {
        // 더블탭: 가장 가까운 포인트 제거 (첫/마지막 제외)
        var settings = store.get(for: photoURL)
        let sorted = settings.curvePoints.sorted { $0.x < $1.x }
        guard sorted.count > 2 else { return }
        // 가운데 포인트 중 하나 제거: 현재 구현은 중앙값 제거
        let middleIdx = sorted.count / 2
        settings.curvePoints.remove(at: middleIdx)
        store.set(settings, for: photoURL)
    }

    private func updatePoint(_ points: [CGPoint], index: Int, toCanvas location: CGPoint, size: CGSize) -> [CGPoint] {
        let sorted = points.sorted { $0.x < $1.x }
        guard index >= 0, index < sorted.count else { return points }
        var result = sorted
        let normalizedX = (location.x / size.width).clamped(to: 0...1)
        let normalizedY = (1 - location.y / size.height).clamped(to: 0...1)
        // x 제약: 이웃 포인트 사이
        let minX: CGFloat = index == 0 ? 0 : sorted[index - 1].x + 0.02
        let maxX: CGFloat = index == sorted.count - 1 ? 1 : sorted[index + 1].x - 0.02
        let clampedX = normalizedX.clamped(to: minX...maxX)
        result[index] = CGPoint(x: clampedX, y: normalizedY)
        return result
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Presets

    private var linearPoints: [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
    }
    private var sCurvePoints: [CGPoint] {
        [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.25, y: 0.18),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.75, y: 0.82),
            CGPoint(x: 1, y: 1)
        ]
    }
    private var fadePoints: [CGPoint] {
        [
            CGPoint(x: 0, y: 0.12),
            CGPoint(x: 0.5, y: 0.52),
            CGPoint(x: 1, y: 0.93)
        ]
    }

    private func curvePresetButton(label: String, points: [CGPoint]) -> some View {
        Button(action: {
            var s = store.get(for: photoURL)
            s.curvePoints = points
            s.curveAuto = false
            store.set(s, for: photoURL)
        }) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                .foregroundColor(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    private func resetCurve() {
        var s = store.get(for: photoURL)
        s.curvePoints = []
        s.curveAuto = false
        store.set(s, for: photoURL)
    }

    // MARK: - Histogram Loading

    private func loadHistogram() {
        let url = photoURL
        histogramData = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let data = HistogramOverlay.computeHistogram(url: url)
            DispatchQueue.main.async {
                self.histogramData = data
            }
        }
    }
}

// MARK: - Auto Toggle Style

private struct AutoPillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            configuration.label
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    Capsule().fill(configuration.isOn ? Color(red: 1.0, green: 0.76, blue: 0.03) : Color.white.opacity(0.1))
                )
                .foregroundColor(configuration.isOn ? .black : .white.opacity(0.75))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Comparable clamp

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
