import Foundation
import CoreImage
import Vision
import AppKit
import Accelerate
import simd

// MARK: - Line Segment

/// 감지된 직선 세그먼트
private struct LineSegment {
    let p1: SIMD2<Double>  // 시작점
    let p2: SIMD2<Double>  // 끝점
    let angle: Double      // 라디안 (-π/2 ~ π/2)
    let length: Double     // 길이

    var midpoint: SIMD2<Double> { (p1 + p2) * 0.5 }

    /// 수직 직선인지 (80~100도)
    var isVertical: Bool {
        let deg = abs(angle) * 180.0 / .pi
        return deg > 70 && deg < 110
    }

    /// 수평 직선인지 (-10~10도)
    var isHorizontal: Bool {
        let deg = abs(angle) * 180.0 / .pi
        return deg < 20 || deg > 160
    }
}

// MARK: - Upright Mode

enum UprightMode {
    case auto     // 자동 (수평+수직 최적 조합)
    case level    // 수평만 (roll)
    case vertical // 수직만 (roll + pitch)
    case full     // 전체 (roll + pitch + yaw)
}

// MARK: - PerspectiveCorrectionService

/// 원근 보정 서비스 (라이트룸 Upright 수준)
/// LSD 직선감지 → RANSAC 소실점 → 카메라 회전 역산 → 원근 보정
struct PerspectiveCorrectionService {

    // MARK: - Public API

    /// 자동 원근 보정 (기본: auto 모드)
    static func autoUpright(image: CIImage, mode: UprightMode = .auto) -> (corrected: CIImage, angle: Double, applied: Bool) {
        let w = image.extent.width
        let h = image.extent.height
        guard w > 100, h > 100 else { return (image, 0, false) }

        // 0. 얼굴 감지
        let hasFace = detectFaces(image: image)
        if hasFace {
            fputs("[Upright] 인물 감지됨\n", stderr)
        }

        // ── 전략 ──
        // 1차: Apple VNDetectHorizonRequest (수평 회전 — 가장 신뢰성 높음)
        // 2차: Hough Transform (건물/풍경에서 VP 기반 수직 보정)
        // 인물 사진: 수평 보정만 (수직/전체 금지)

        let effectiveMode: UprightMode
        if hasFace {
            // 인물은 무조건 수평만
            effectiveMode = .level
            fputs("[Upright] 인물 → level 고정\n", stderr)
        } else {
            effectiveMode = mode
        }

        switch effectiveMode {
        case .level, .auto:
            return correctWithVision(image: image, w: w, h: h)
        case .vertical:
            return correctVerticalWithHough(image: image, w: w, h: h)
        case .full:
            return correctFullWithHough(image: image, w: w, h: h)
        }
    }

    // MARK: - Vision 기반 수평 보정 (가장 정확)

    /// Apple VNDetectHorizonRequest로 수평 회전 감지 + 보정
    private static func correctWithVision(image: CIImage, w: CGFloat, h: CGFloat) -> (CIImage, Double, Bool) {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let request = VNDetectHorizonRequest()

        do {
            try handler.perform([request])
        } catch {
            fputs("[Upright/Vision] 에러: \(error)\n", stderr)
            return (image, 0, false)
        }

        guard let obs = request.results?.first,
              abs(obs.angle) > 0.003 else {  // 0.17도 미만 스킵
            fputs("[Upright/Vision] 회전 감지 안 됨 — 스킵\n", stderr)
            return (image, 0, false)
        }

        let angleDeg = obs.angle * 180.0 / .pi

        // 15도 이상은 비정상
        guard abs(angleDeg) < 15.0 else {
            fputs("[Upright/Vision] 각도 과대 (\(String(format: "%.1f", angleDeg))°) — 스킵\n", stderr)
            return (image, 0, false)
        }

        fputs("[Upright/Vision] 수평 보정: \(String(format: "%.2f", angleDeg))°\n", stderr)

        let corrected = rotateAndCrop(image: image, angleDegrees: Double(-angleDeg))
        return (corrected, abs(Double(angleDeg)), true)
    }

    // MARK: - Hough 기반 수직 보정 (건물/풍경용)

    /// Hough Transform으로 수직선 감지 → VP 추정 → pitch 보정
    private static func correctVerticalWithHough(image: CIImage, w: CGFloat, h: CGFloat) -> (CIImage, Double, Bool) {
        // 먼저 Vision으로 수평 보정
        var result = image
        var totalAngle: Double = 0

        let (leveled, levelAngle, levelApplied) = correctWithVision(image: image, w: w, h: h)
        if levelApplied {
            result = leveled
            totalAngle = levelAngle
        }

        // Hough로 수직선 감지
        let lines = detectLineSegments(image: result, maxSize: 1024)
        let verticalLines = lines.filter { $0.isVertical && $0.length > 50 }

        fputs("[Upright/Vertical] 수직선: \(verticalLines.count)개\n", stderr)
        guard verticalLines.count >= 3 else {
            return levelApplied ? (result, totalAngle, true) : (image, 0, false)
        }

        // VP 추정
        guard let vp = ransacVanishingPoint(lines: verticalLines) else {
            return levelApplied ? (result, totalAngle, true) : (image, 0, false)
        }

        let cy = h / 2.0
        let f = max(w, h)
        let pitch = atan2(vp.y - cy, f)
        let pitchDeg = pitch * 180.0 / .pi

        fputs("[Upright/Vertical] VP: (\(String(format: "%.0f", vp.x)), \(String(format: "%.0f", vp.y))), pitch: \(String(format: "%.2f", pitchDeg))°\n", stderr)

        if abs(pitchDeg) > 0.5 && abs(pitchDeg) < 15 {
            result = applyPitchCorrection(image: result, pitchRadians: pitch)
            totalAngle = max(totalAngle, abs(pitchDeg))
        }

        return (result, totalAngle, true)
    }

    /// Hough Transform으로 수평+수직 전체 보정 (건물/풍경용)
    private static func correctFullWithHough(image: CIImage, w: CGFloat, h: CGFloat) -> (CIImage, Double, Bool) {
        // 먼저 수직 보정 (Vision 수평 포함)
        let (result, angle, applied) = correctVerticalWithHough(image: image, w: w, h: h)

        guard applied else { return (image, 0, false) }

        // 추가 yaw 보정
        let lines = detectLineSegments(image: result, maxSize: 1024)
        let horizontalLines = lines.filter { $0.isHorizontal && $0.length > 50 }

        guard horizontalLines.count >= 3 else { return (result, angle, true) }

        if let hvp = ransacVanishingPoint(lines: horizontalLines) {
            let cx = w / 2.0
            let f = max(w, h)
            let yaw = atan2(hvp.x - cx, f)
            let yawDeg = yaw * 180.0 / .pi

            if abs(yawDeg) > 0.5 && abs(yawDeg) < 15 {
                let final = applyYawCorrection(image: result, yawRadians: yaw)
                fputs("[Upright/Full] yaw: \(String(format: "%.2f", yawDeg))°\n", stderr)
                return (final, max(angle, abs(yawDeg)), true)
            }
        }

        return (result, angle, true)
    }

    /// 가이드 모드: 사용자가 그은 2개의 수직선 기반 보정
    static func guidedUpright(image: CIImage, line1: (CGPoint, CGPoint), line2: (CGPoint, CGPoint)) -> CIImage {
        let width = image.extent.width
        let height = image.extent.height
        guard width > 10, height > 10 else { return image }

        // 두 선의 기울기 계산
        let angle1 = atan2(line1.1.x - line1.0.x, line1.1.y - line1.0.y)
        let angle2 = atan2(line2.1.x - line2.0.x, line2.1.y - line2.0.y)

        let deg1 = abs(angle1) * 180.0 / .pi
        let deg2 = abs(angle2) * 180.0 / .pi
        if deg1 < 0.3 && deg2 < 0.3 { return image }

        // Vanishing point 계산
        let p1 = line1.0, p2 = line1.1
        let p3 = line2.0, p4 = line2.1

        let d1x = p2.x - p1.x, d1y = p2.y - p1.y
        let d2x = p4.x - p3.x, d2y = p4.y - p3.y
        let cross = d1x * d2y - d1y * d2x

        let topShiftL = (p1.x - p2.x) / height
        let topShiftR = (p3.x - p4.x) / height
        let avgTopShift = (topShiftL + topShiftR) / 2.0
        let shiftAmount = avgTopShift * height * 0.5

        var asymmetry: CGFloat = 0
        if abs(cross) > 0.001 {
            let t = ((p3.x - p1.x) * d2y - (p3.y - p1.y) * d2x) / cross
            let vpX = p1.x + t * d1x
            asymmetry = (vpX - width / 2.0) / width * 0.1
        }

        let tl = CGPoint(x: shiftAmount + asymmetry * width, y: height)
        let tr = CGPoint(x: width - shiftAmount + asymmetry * width, y: height)
        let bl = CGPoint(x: -asymmetry * width, y: 0)
        let br = CGPoint(x: width + asymmetry * width, y: 0)

        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: tl), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: tr), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bl), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: br), forKey: "inputBottomRight")

        guard let output = filter.outputImage else { return image }
        return cropToOriginalAspect(output, originalWidth: width, originalHeight: height)
    }

    // MARK: - Face Detection

    /// 이미지에 얼굴이 있는지 빠르게 감지
    private static func detectFaces(image: CIImage) -> Bool {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        do {
            try handler.perform([request])
            let faces = request.results ?? []
            // 얼굴이 있고 이미지 대비 일정 크기 이상이면 인물 사진
            return faces.contains { $0.boundingBox.width > 0.05 && $0.confidence > 0.5 }
        } catch {
            return false
        }
    }

    // MARK: - LSD (Line Segment Detection)

    /// Canny 에지 + Hough Transform 기반 직선 세그먼트 감지
    private static func detectLineSegments(image: CIImage, maxSize: CGFloat) -> [LineSegment] {
        // 리사이즈
        let scale = min(1.0, maxSize / max(image.extent.width, image.extent.height))
        let resized = scale < 1.0 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(resized, from: resized.extent) else { return [] }

        let w = cgImage.width
        let h = cgImage.height
        guard w > 50, h > 50 else { return [] }

        // 그레이스케일 변환
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: w, space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let grayData = ctx.data else { return [] }
        let pixels = grayData.bindMemory(to: UInt8.self, capacity: w * h)

        // Gaussian blur (3x3) — 노이즈 제거
        var blurred = [Float](repeating: 0, count: w * h)
        let kernel: [Float] = [1, 2, 1, 2, 4, 2, 1, 2, 1]  // /16
        for y in 1..<(h-1) {
            for x in 1..<(w-1) {
                var sum: Float = 0
                for ky in -1...1 {
                    for kx in -1...1 {
                        sum += Float(pixels[(y+ky)*w + (x+kx)]) * kernel[(ky+1)*3 + (kx+1)]
                    }
                }
                blurred[y*w + x] = sum / 16.0
            }
        }

        // Sobel 그래디언트
        var gx = [Float](repeating: 0, count: w * h)
        var gy = [Float](repeating: 0, count: w * h)
        var magnitude = [Float](repeating: 0, count: w * h)

        for y in 1..<(h-1) {
            for x in 1..<(w-1) {
                let idx = y * w + x
                let gxVal = -blurred[idx-w-1] + blurred[idx-w+1]
                           - 2*blurred[idx-1] + 2*blurred[idx+1]
                           - blurred[idx+w-1] + blurred[idx+w+1]
                let gyVal = -blurred[idx-w-1] - 2*blurred[idx-w] - blurred[idx-w+1]
                           + blurred[idx+w-1] + 2*blurred[idx+w] + blurred[idx+w+1]
                gx[idx] = gxVal
                gy[idx] = gyVal
                magnitude[idx] = sqrt(gxVal*gxVal + gyVal*gyVal)
            }
        }

        // Non-maximum suppression (Canny 핵심)
        var nms = [Float](repeating: 0, count: w * h)
        for y in 2..<(h-2) {
            for x in 2..<(w-2) {
                let idx = y * w + x
                let mag = magnitude[idx]
                guard mag > 30 else { continue }

                let angle = atan2(gy[idx], gx[idx])
                let deg = angle * 180.0 / .pi

                // 그래디언트 방향으로 이웃 비교
                var m1: Float = 0, m2: Float = 0
                if (deg >= -22.5 && deg < 22.5) || (deg >= 157.5 || deg < -157.5) {
                    m1 = magnitude[idx+1]; m2 = magnitude[idx-1]
                } else if (deg >= 22.5 && deg < 67.5) || (deg >= -157.5 && deg < -112.5) {
                    m1 = magnitude[idx+w+1]; m2 = magnitude[idx-w-1]
                } else if (deg >= 67.5 && deg < 112.5) || (deg >= -112.5 && deg < -67.5) {
                    m1 = magnitude[idx+w]; m2 = magnitude[idx-w]
                } else {
                    m1 = magnitude[idx+w-1]; m2 = magnitude[idx-w+1]
                }

                if mag >= m1 && mag >= m2 {
                    nms[idx] = mag
                }
            }
        }

        // Hysteresis thresholding
        let highThreshold: Float = 80
        let lowThreshold: Float = 30
        var edgeMap = [UInt8](repeating: 0, count: w * h)  // 0=none, 1=weak, 2=strong
        for y in 2..<(h-2) {
            for x in 2..<(w-2) {
                let idx = y * w + x
                if nms[idx] >= highThreshold {
                    edgeMap[idx] = 2
                } else if nms[idx] >= lowThreshold {
                    edgeMap[idx] = 1
                }
            }
        }
        // weak 에지 중 strong 에지와 연결된 것만 유지
        for y in 2..<(h-2) {
            for x in 2..<(w-2) {
                let idx = y * w + x
                if edgeMap[idx] == 1 {
                    var hasStrongNeighbor = false
                    for dy in -1...1 {
                        for dx in -1...1 {
                            if edgeMap[(y+dy)*w + (x+dx)] == 2 { hasStrongNeighbor = true }
                        }
                    }
                    if !hasStrongNeighbor { edgeMap[idx] = 0 }
                }
            }
        }

        // Hough Transform — 직선 감지
        let rhoMax = Int(sqrt(Double(w*w + h*h))) + 1
        let thetaSteps = 180
        var accumulator = [Int](repeating: 0, count: (2*rhoMax) * thetaSteps)

        // 사전 계산된 sin/cos 테이블
        var cosTable = [Double](repeating: 0, count: thetaSteps)
        var sinTable = [Double](repeating: 0, count: thetaSteps)
        for t in 0..<thetaSteps {
            let theta = Double(t) * .pi / Double(thetaSteps)
            cosTable[t] = cos(theta)
            sinTable[t] = sin(theta)
        }

        // 에지 포인트 수집
        var edgePoints: [(x: Int, y: Int)] = []
        edgePoints.reserveCapacity(w * h / 10)
        for y in stride(from: 2, to: h-2, by: 1) {
            for x in stride(from: 2, to: w-2, by: 1) {
                if edgeMap[y*w + x] >= 1 {
                    edgePoints.append((x, y))
                }
            }
        }

        // 에지가 너무 많으면 서브샘플링
        let maxEdgePoints = 30000
        var sampledPoints = edgePoints
        if edgePoints.count > maxEdgePoints {
            sampledPoints = []
            let step = edgePoints.count / maxEdgePoints
            for i in stride(from: 0, to: edgePoints.count, by: step) {
                sampledPoints.append(edgePoints[i])
            }
        }

        // 수평/수직 근처 각도만 투표 (속도 최적화)
        // 수평: theta 0~20, 160~179  |  수직: theta 70~110
        let hRanges = [(0, 20), (160, 179)]
        let vRange = (70, 110)

        for pt in sampledPoints {
            // 수평 범위
            for range in hRanges {
                for t in range.0...range.1 {
                    let rho = Int(Double(pt.x) * cosTable[t] + Double(pt.y) * sinTable[t]) + rhoMax
                    if rho >= 0 && rho < 2*rhoMax {
                        accumulator[rho * thetaSteps + t] += 1
                    }
                }
            }
            // 수직 범위
            for t in vRange.0...vRange.1 {
                let rho = Int(Double(pt.x) * cosTable[t] + Double(pt.y) * sinTable[t]) + rhoMax
                if rho >= 0 && rho < 2*rhoMax {
                    accumulator[rho * thetaSteps + t] += 1
                }
            }
        }

        // 피크 추출 (local maxima)
        let minVotes = max(20, sampledPoints.count / 80)
        var peaks: [(rho: Int, theta: Int, votes: Int)] = []

        for rho in 3..<(2*rhoMax - 3) {
            for t in 1..<(thetaSteps-1) {
                let votes = accumulator[rho * thetaSteps + t]
                guard votes >= minVotes else { continue }

                // 5x5 local max
                var isMax = true
                for dr in -2...2 {
                    for dt in -1...1 {
                        if dr == 0 && dt == 0 { continue }
                        let nr = rho + dr, nt = t + dt
                        if nr >= 0 && nr < 2*rhoMax && nt >= 0 && nt < thetaSteps {
                            if accumulator[nr * thetaSteps + nt] > votes { isMax = false; break }
                        }
                    }
                    if !isMax { break }
                }
                if isMax { peaks.append((rho, t, votes)) }
            }
        }

        peaks.sort { $0.votes > $1.votes }
        let topPeaks = Array(peaks.prefix(60))

        // 피크에서 직선 세그먼트 추출
        var segments: [LineSegment] = []
        let invScale = 1.0 / scale

        for peak in topPeaks {
            let theta = Double(peak.theta) * .pi / Double(thetaSteps)
            let rho = Double(peak.rho - rhoMax)

            // 이 직선 위의 에지 포인트 수집
            var pointsOnLine: [(x: Double, y: Double)] = []
            let cosT = cos(theta), sinT = sin(theta)

            for pt in edgePoints {
                let dist = abs(Double(pt.x) * cosT + Double(pt.y) * sinT - rho)
                if dist < 2.0 {
                    pointsOnLine.append((Double(pt.x), Double(pt.y)))
                }
            }

            guard pointsOnLine.count >= 8 else { continue }

            // 점들을 직선 방향으로 정렬 → 연속 세그먼트 추출
            let dirX = -sinT, dirY = cosT
            let sorted = pointsOnLine.sorted { ($0.x * dirX + $0.y * dirY) < ($1.x * dirX + $1.y * dirY) }

            // 갭 기반 세그먼트 분할
            var segStart = 0
            for i in 1..<sorted.count {
                let dx = sorted[i].x - sorted[i-1].x
                let dy = sorted[i].y - sorted[i-1].y
                let gap = sqrt(dx*dx + dy*dy)

                if gap > 8 || i == sorted.count - 1 {
                    let end = (gap > 8) ? i - 1 : i
                    if end - segStart >= 5 {
                        let sp = sorted[segStart]
                        let ep = sorted[end]
                        let len = sqrt(pow(ep.x-sp.x, 2) + pow(ep.y-sp.y, 2))
                        if len > 15 {
                            let angle = atan2(ep.y - sp.y, ep.x - sp.x)
                            segments.append(LineSegment(
                                p1: SIMD2(sp.x * invScale, sp.y * invScale),
                                p2: SIMD2(ep.x * invScale, ep.y * invScale),
                                angle: angle,
                                length: len * invScale
                            ))
                        }
                    }
                    segStart = i
                }
            }
        }

        return segments
    }

    // MARK: - RANSAC Vanishing Point

    /// RANSAC으로 직선 그룹의 소실점 추정
    private static func ransacVanishingPoint(lines: [LineSegment]) -> SIMD2<Double>? {
        guard lines.count >= 2 else { return nil }

        let iterations = min(500, lines.count * (lines.count - 1) / 2)
        var bestVP: SIMD2<Double>?
        var bestInliers = 0
        let threshold: Double = 3.0  // 각도 오차 임계값 (도)

        for _ in 0..<iterations {
            // 무작위 2개 직선 선택
            let i = Int.random(in: 0..<lines.count)
            var j = Int.random(in: 0..<lines.count)
            while j == i { j = Int.random(in: 0..<lines.count) }

            // 교차점 = 소실점 후보
            guard let vp = intersect(lines[i], lines[j]) else { continue }

            // 인라이어 카운트
            var inliers = 0
            for line in lines {
                let expectedAngle = atan2(vp.y - line.midpoint.y, vp.x - line.midpoint.x)
                var angleDiff = abs(expectedAngle - line.angle) * 180.0 / .pi
                if angleDiff > 180 { angleDiff = 360 - angleDiff }
                // 반대 방향도 허용
                if angleDiff > 90 { angleDiff = 180 - angleDiff }
                if angleDiff < threshold { inliers += 1 }
            }

            if inliers > bestInliers {
                bestInliers = inliers
                bestVP = vp
            }
        }

        // 최소 30% 인라이어 필요
        guard bestInliers >= max(2, lines.count * 3 / 10) else { return nil }

        // 인라이어로 VP 정제 (최소자승법)
        if let vp = bestVP {
            let refined = refineVP(lines: lines, initialVP: vp, threshold: threshold)
            return refined
        }

        return bestVP
    }

    /// 두 직선의 교차점
    private static func intersect(_ l1: LineSegment, _ l2: LineSegment) -> SIMD2<Double>? {
        let d1 = l1.p2 - l1.p1
        let d2 = l2.p2 - l2.p1
        let cross = d1.x * d2.y - d1.y * d2.x
        guard abs(cross) > 1e-6 else { return nil }

        let d3 = l2.p1 - l1.p1
        let t = (d3.x * d2.y - d3.y * d2.x) / cross
        return l1.p1 + t * d1
    }

    /// VP 정제 — 인라이어의 가중 최소자승
    private static func refineVP(lines: [LineSegment], initialVP: SIMD2<Double>, threshold: Double) -> SIMD2<Double> {
        var sumX: Double = 0, sumY: Double = 0, totalWeight: Double = 0

        for line in lines {
            let expectedAngle = atan2(initialVP.y - line.midpoint.y, initialVP.x - line.midpoint.x)
            var angleDiff = abs(expectedAngle - line.angle) * 180.0 / .pi
            if angleDiff > 180 { angleDiff = 360 - angleDiff }
            if angleDiff > 90 { angleDiff = 180 - angleDiff }

            guard angleDiff < threshold else { continue }

            // 재교차 — 각 인라이어 선과 VP 방향으로 교차점
            let weight = line.length * (1.0 - angleDiff / threshold)
            // VP 후보를 각 직선에 투영
            let vp = intersectWithVPDirection(line: line, vpDir: initialVP - line.midpoint)
            sumX += vp.x * weight
            sumY += vp.y * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else { return initialVP }
        return SIMD2(sumX / totalWeight, sumY / totalWeight)
    }

    private static func intersectWithVPDirection(line: LineSegment, vpDir: SIMD2<Double>) -> SIMD2<Double> {
        // 직선 위의 중점에서 VP 방향으로 연장
        let norm = sqrt(vpDir.x * vpDir.x + vpDir.y * vpDir.y)
        guard norm > 1e-6 else { return line.midpoint }
        return line.midpoint + vpDir
    }

    // MARK: - Transform 적용

    /// 회전 + 자동 크롭 (검은 영역 제거)
    private static func rotateAndCrop(image: CIImage, angleDegrees: Double) -> CIImage {
        let w = image.extent.width
        let h = image.extent.height
        let rads = angleDegrees * .pi / 180.0

        guard let filter = CIFilter(name: "CIStraightenFilter") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(Float(rads), forKey: "inputAngle")
        guard let output = filter.outputImage else { return image }

        // 최적 크롭 — 회전 후 검은 영역 없는 최대 사각형
        let cosA = abs(cos(rads))
        let sinA = abs(sin(rads))
        let newW = w * cosA - h * sinA  // 실제 크롭 가능 너비
        let newH = h * cosA - w * sinA

        // 안전한 크롭 크기
        let cropW: CGFloat, cropH: CGFloat
        if newW > 0 && newH > 0 {
            // 원본 종횡비 유지
            let aspectRatio = w / h
            if newW / newH > aspectRatio {
                cropH = newH
                cropW = cropH * aspectRatio
            } else {
                cropW = newW
                cropH = cropW / aspectRatio
            }
        } else {
            // 각도가 작으면 간단한 크롭
            let margin = abs(tan(rads)) * min(w, h) * 0.5
            cropW = w - margin * 2
            cropH = h - margin * 2
        }

        let outputExtent = output.extent
        let cropX = outputExtent.origin.x + (outputExtent.width - cropW) / 2
        let cropY = outputExtent.origin.y + (outputExtent.height - cropH) / 2

        return output.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
    }

    /// Pitch 보정 (상하 원근 — 수직선을 수직으로)
    private static func applyPitchCorrection(image: CIImage, pitchRadians: Double) -> CIImage {
        let w = image.extent.width
        let h = image.extent.height

        // 보정 강도 제한
        let factor = tan(pitchRadians) * 0.25
        let clampedFactor = max(-0.15, min(0.15, factor))

        let topLeft = CGPoint(x: clampedFactor * w, y: h)
        let topRight = CGPoint(x: w - clampedFactor * w, y: h)
        let bottomLeft = CGPoint(x: -clampedFactor * w * 0.3, y: 0)
        let bottomRight = CGPoint(x: w + clampedFactor * w * 0.3, y: 0)

        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

        guard let output = filter.outputImage else { return image }
        return cropToOriginalAspect(output, originalWidth: w, originalHeight: h)
    }

    /// Yaw 보정 (좌우 원근 — 수평선을 수평으로)
    private static func applyYawCorrection(image: CIImage, yawRadians: Double) -> CIImage {
        let w = image.extent.width
        let h = image.extent.height

        let factor = tan(yawRadians) * 0.25
        let clampedFactor = max(-0.15, min(0.15, factor))

        let topLeft = CGPoint(x: 0, y: h - clampedFactor * h)
        let topRight = CGPoint(x: w, y: h + clampedFactor * h * 0.3)
        let bottomLeft = CGPoint(x: 0, y: clampedFactor * h)
        let bottomRight = CGPoint(x: w, y: -clampedFactor * h * 0.3)

        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

        guard let output = filter.outputImage else { return image }
        return cropToOriginalAspect(output, originalWidth: w, originalHeight: h)
    }

    // MARK: - Crop Helper

    /// 보정 결과를 원본 종횡비로 최대 크롭
    private static func cropToOriginalAspect(_ image: CIImage, originalWidth: CGFloat, originalHeight: CGFloat) -> CIImage {
        let ext = image.extent
        guard !ext.isInfinite, !ext.isEmpty else { return image }

        let aspect = originalWidth / originalHeight
        var cropW = ext.width
        var cropH = ext.height

        if cropW / cropH > aspect {
            cropW = cropH * aspect
        } else {
            cropH = cropW / aspect
        }

        let cropX = ext.origin.x + (ext.width - cropW) / 2
        let cropY = ext.origin.y + (ext.height - cropH) / 2

        return image.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
    }
}
