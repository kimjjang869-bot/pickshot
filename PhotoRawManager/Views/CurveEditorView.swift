import SwiftUI
import AppKit

/// 라이트룸 스타일 톤 커브 에디터.
/// 구성:
/// - 상단 채널 선택: 포인트 커브 / 파라메트릭 / R / G / B (현재는 RGB 공통 + 파라메트릭)
/// - 히스토그램 배경 + 대각선 베이스라인
/// - 아래 영역: 4개 슬라이더 (밝은 영역 · 밝음 · 어두움 · 어두운 영역)
/// - 슬라이더 값은 DevelopSettings.toneHighlights/Lights/Darks/Shadows 에 저장
struct CurveEditorView: View {
    let photoURL: URL
    var onAutoApply: (() -> Void)? = nil

    @ObservedObject var store: DevelopStore = .shared
    @State private var histogramData: HistogramData? = nil

    // 드래그 중인 포인트 인덱스
    @State private var dragPointIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 상단 헤더
            HStack(spacing: 6) {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 1.0, green: 0.76, blue: 0.03))
                Text("톤 커브").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)

                Spacer()

                Button(action: { onAutoApply?() }) {
                    Text("자동")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(Color(red: 1.0, green: 0.76, blue: 0.03).opacity(0.85)))
                        .foregroundColor(.black)
                }
                .buttonStyle(.plain)
                .help("이미지 분석 후 자동 커브 적용")

                Button(action: resetAll) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .help("커브 · 영역 슬라이더 전체 리셋")
            }

            // 히스토그램 + 커브 캔버스
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.75))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )

                gridLines

                // 히스토그램
                if let data = histogramData {
                    ZStack {
                        HistogramPath(values: data.luminance).fill(Color.white.opacity(0.22))
                        HistogramPath(values: data.red).fill(Color.red.opacity(0.22))
                        HistogramPath(values: data.green).fill(Color.green.opacity(0.22))
                        HistogramPath(values: data.blue).fill(Color.blue.opacity(0.22))
                    }
                    .padding(4)
                    .allowsHitTesting(false)
                }

                // 커브 + 포인트
                curveCanvas
            }
            .frame(height: 180)

            // 영역 슬라이더 4개
            regionSliders
        }
        .padding(10)
        .onAppear { loadHistogram() }
        .onChange(of: photoURL) { _ in loadHistogram() }
    }

    // MARK: - Grid

    private var gridLines: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                for i in 1...3 {
                    let x = w * CGFloat(i) / 4
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)

            // 대각선 베이스라인
            Path { p in
                p.move(to: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: w, y: 0))
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
        .padding(4)
    }

    // MARK: - Curve Canvas

    private var curveCanvas: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let points = currentPoints(in: CGSize(width: w, height: h))
            ZStack {
                // 커브 라인 (cubic bezier 근사 부드러운 곡선)
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for i in 1..<points.count {
                        let prev = points[i - 1]
                        let curr = points[i]
                        let cdx = (curr.x - prev.x) * 0.5
                        path.addCurve(
                            to: curr,
                            control1: CGPoint(x: prev.x + cdx, y: prev.y),
                            control2: CGPoint(x: curr.x - cdx, y: curr.y)
                        )
                    }
                }
                .stroke(Color.white, lineWidth: 1.5)

                // 포인트 핸들
                ForEach(0..<points.count, id: \.self) { i in
                    Circle()
                        .fill(i == dragPointIndex ? Color(red: 1.0, green: 0.76, blue: 0.03) : Color.white)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                        .position(points[i])
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in handleDrag(at: v.location, in: CGSize(width: w, height: h)) }
                    .onEnded { _ in dragPointIndex = nil }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { handleDoubleTap(in: CGSize(width: w, height: h)) }
            )
        }
        .padding(4)
    }

    // MARK: - Region Sliders

    private var regionSliders: some View {
        VStack(spacing: 5) {
            regionRow(label: "밝은 영역", binding: bindHighlights)
            regionRow(label: "밝음",     binding: bindLights)
            regionRow(label: "어두움",   binding: bindDarks)
            regionRow(label: "어두운 영역", binding: bindShadows)
        }
        .padding(.top, 2)
    }

    private func regionRow(label: String, binding: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 62, alignment: .trailing)
            DoubleClickResetSlider(
                value: binding,
                range: -100...100,
                defaultValue: 0,
                step: 1,
                bigStep: 10,
                format: { _ in "" }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 16)
            Text(String(format: "%+.0f", binding.wrappedValue))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private var bindHighlights: Binding<Double> {
        Binding(
            get: { store.get(for: photoURL).toneHighlights },
            set: { v in var s = store.get(for: photoURL); s.toneHighlights = v; store.set(s, for: photoURL) }
        )
    }
    private var bindLights: Binding<Double> {
        Binding(
            get: { store.get(for: photoURL).toneLights },
            set: { v in var s = store.get(for: photoURL); s.toneLights = v; store.set(s, for: photoURL) }
        )
    }
    private var bindDarks: Binding<Double> {
        Binding(
            get: { store.get(for: photoURL).toneDarks },
            set: { v in var s = store.get(for: photoURL); s.toneDarks = v; store.set(s, for: photoURL) }
        )
    }
    private var bindShadows: Binding<Double> {
        Binding(
            get: { store.get(for: photoURL).toneShadows },
            set: { v in var s = store.get(for: photoURL); s.toneShadows = v; store.set(s, for: photoURL) }
        )
    }

    // MARK: - Points

    private func currentPoints(in size: CGSize) -> [CGPoint] {
        let settings = store.get(for: photoURL)
        var raw = settings.curvePoints.sorted { $0.x < $1.x }
        if raw.isEmpty {
            raw = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        }
        return raw.map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) }
    }

    private func handleDrag(at location: CGPoint, in size: CGSize) {
        var settings = store.get(for: photoURL)
        if settings.curvePoints.isEmpty {
            settings.curvePoints = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        }

        if let idx = dragPointIndex {
            settings.curvePoints = updatePoint(settings.curvePoints, index: idx, toCanvas: location, size: size)
            store.set(settings, for: photoURL)
            return
        }

        let canvasPoints = settings.curvePoints.sorted { $0.x < $1.x }.map {
            CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height)
        }
        let hitIdx = canvasPoints.enumerated().min { a, b in
            distance(a.element, location) < distance(b.element, location)
        }?.offset
        if let idx = hitIdx, distance(canvasPoints[idx], location) < 14 {
            dragPointIndex = idx
            settings.curvePoints = updatePoint(settings.curvePoints, index: idx, toCanvas: location, size: size)
            store.set(settings, for: photoURL)
        } else if settings.curvePoints.count < 5 {
            let p = CGPoint(
                x: (location.x / size.width).clamped(to: 0...1),
                y: (1 - location.y / size.height).clamped(to: 0...1)
            )
            settings.curvePoints.append(p)
            settings.curvePoints.sort { $0.x < $1.x }
            dragPointIndex = settings.curvePoints.firstIndex { abs($0.x - p.x) < 0.0001 }
            store.set(settings, for: photoURL)
        }
    }

    private func handleDoubleTap(in size: CGSize) {
        var settings = store.get(for: photoURL)
        let sorted = settings.curvePoints.sorted { $0.x < $1.x }
        guard sorted.count > 2 else { return }
        settings.curvePoints.remove(at: sorted.count / 2)
        store.set(settings, for: photoURL)
    }

    private func updatePoint(_ points: [CGPoint], index: Int, toCanvas location: CGPoint, size: CGSize) -> [CGPoint] {
        let sorted = points.sorted { $0.x < $1.x }
        guard index >= 0, index < sorted.count else { return points }
        var result = sorted
        let nx = (location.x / size.width).clamped(to: 0...1)
        let ny = (1 - location.y / size.height).clamped(to: 0...1)
        let minX: CGFloat = index == 0 ? 0 : sorted[index - 1].x + 0.02
        let maxX: CGFloat = index == sorted.count - 1 ? 1 : sorted[index + 1].x - 0.02
        let cx = nx.clamped(to: minX...maxX)
        result[index] = CGPoint(x: cx, y: ny)
        return result
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x; let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    private func resetAll() {
        var s = store.get(for: photoURL)
        s.curvePoints = []
        s.toneHighlights = 0
        s.toneLights = 0
        s.toneDarks = 0
        s.toneShadows = 0
        store.set(s, for: photoURL)
    }

    // MARK: - Histogram

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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
