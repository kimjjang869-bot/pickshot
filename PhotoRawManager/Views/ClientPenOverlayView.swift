import SwiftUI

/// 클라이언트가 뷰어에서 그린 펜 그림을 본체 앱 미리보기 위에 오버레이로 렌더.
/// 웹 뷰어의 JSON 포맷과 호환: `penDrawings: [{color, paths: [{x, y}...]}]`
/// 정규화 좌표 (0.0 ~ 1.0) 기준이므로 이미지가 어떤 크기든 정확히 그 자리에 표시.
struct ClientPenOverlayView: View {
    let penDrawingsJSON: String
    let imageSize: CGSize
    let displaySize: CGSize

    @State private var parsedDrawings: [PenStroke] = []

    struct PenStroke {
        let color: Color
        let width: CGFloat
        let points: [CGPoint]  // 정규화 좌표 (0~1)
    }

    var body: some View {
        Canvas { context, size in
            plog("[PEN] 🖼️ Canvas draw — size=\(size), strokes=\(parsedDrawings.count)\n")
            for stroke in parsedDrawings {
                guard stroke.points.count >= 2 else { continue }
                var path = Path()
                let first = stroke.points[0]
                plog("[PEN] stroke — pts=\(stroke.points.count), first=(\(first.x),\(first.y)), width=\(stroke.width)\n")
                path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                for pt in stroke.points.dropFirst() {
                    path.addLine(to: CGPoint(x: pt.x * size.width, y: pt.y * size.height))
                }
                context.stroke(
                    path,
                    with: .color(stroke.color),
                    style: StrokeStyle(lineWidth: max(stroke.width, 2), lineCap: .round, lineJoin: .round)
                )
            }
        }
        .allowsHitTesting(false)
        .onAppear { parse() }
        .onChange(of: penDrawingsJSON) { _, _ in parse() }
    }

    private func parse() {
        guard let data = penDrawingsJSON.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            plog("[PEN] ❌ JSON 파싱 실패, 원본 \(penDrawingsJSON.count)자 앞부분: \(penDrawingsJSON.prefix(200))\n")
            parsedDrawings = []
            return
        }
        plog("[PEN] JSON 파싱 OK — \(array.count)개 entry\n")
        if let firstEntry = array.first {
            plog("[PEN] 첫 entry keys: \(firstEntry.keys.joined(separator: ","))\n")
            if let paths = firstEntry["paths"] as? [Any] { plog("[PEN] paths count: \(paths.count), first: \(paths.first ?? "nil")\n") }
        }
        parsedDrawings = array.compactMap { entry in
            let colorHex = entry["color"] as? String ?? "#FF3B30"
            let width = (entry["width"] as? CGFloat) ?? (entry["strokeWidth"] as? CGFloat) ?? 3.0

            // "paths" (array of {x, y}) 또는 "points" (array of [x, y]) 둘 다 지원.
            // ⚠️ JSONSerialization 은 NSDictionary/NSNumber 로 브리지하므로 관대하게 처리.
            var points: [CGPoint] = []
            if let pathsAny = entry["paths"] as? [Any] {
                var failedDictCast = 0
                var failedNumCast = 0
                for item in pathsAny {
                    if let p = item as? [String: Any] {
                        let xNum = p["x"] as? NSNumber
                        let yNum = p["y"] as? NSNumber
                        if let x = xNum?.doubleValue, let y = yNum?.doubleValue {
                            points.append(CGPoint(x: x, y: y))
                        } else {
                            failedNumCast += 1
                        }
                    } else if let arr = item as? [Any], arr.count >= 2,
                              let x = (arr[0] as? NSNumber)?.doubleValue,
                              let y = (arr[1] as? NSNumber)?.doubleValue {
                        points.append(CGPoint(x: x, y: y))
                    } else {
                        failedDictCast += 1
                    }
                }
                if points.isEmpty {
                    plog("[PEN] ⚠️ paths \(pathsAny.count)개 중 0개 변환 — dictFail=\(failedDictCast), numFail=\(failedNumCast), firstType=\(type(of: pathsAny.first ?? "nil"))\n")
                }
            } else if let pointsArr = entry["points"] as? [[Double]] {
                points = pointsArr.compactMap { p in
                    guard p.count >= 2 else { return nil }
                    return CGPoint(x: p[0], y: p[1])
                }
            }

            guard !points.isEmpty else { return nil }
            return PenStroke(
                color: Color(hex: colorHex) ?? .red,
                width: width,
                points: points
            )
        }
    }
}

// MARK: - Color Hex 파서

private extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var val: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&val) else { return nil }
        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((val & 0xFF0000) >> 16) / 255.0
            g = Double((val & 0x00FF00) >> 8) / 255.0
            b = Double(val & 0x0000FF) / 255.0
            a = 1.0
        } else {
            r = Double((val & 0xFF000000) >> 24) / 255.0
            g = Double((val & 0x00FF0000) >> 16) / 255.0
            b = Double((val & 0x0000FF00) >> 8) / 255.0
            a = Double(val & 0x000000FF) / 255.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
