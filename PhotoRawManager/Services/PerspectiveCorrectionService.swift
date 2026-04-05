import Foundation
import CoreImage
import Vision
import AppKit
import Accelerate

/// 원근 보정 서비스 (라이트룸 Upright 대체)
/// Vanishing Point 감지 → 수직/수평 보정
struct PerspectiveCorrectionService {

    // MARK: - Auto Upright (수직선 + 수평선 자동 보정)

    /// 자동 원근 보정 — 수직선을 똑바로 세움
    static func autoUpright(image: CIImage) -> (corrected: CIImage, angle: Double, applied: Bool) {
        let width = image.extent.width
        let height = image.extent.height
        guard width > 100, height > 100 else { return (image, 0, false) }

        // 1. 에지 감지 (Sobel)
        let edges = detectEdges(image: image, maxSize: 800)
        guard !edges.isEmpty else { return (image, 0, false) }

        // 2. 수직 Vanishing Point 감지
        let verticalAngle = estimateVerticalTilt(edges: edges, imageWidth: width, imageHeight: height)

        // 너무 작은 보정은 스킵 (0.5도 미만)
        guard abs(verticalAngle) > 0.5, abs(verticalAngle) < 15.0 else { return (image, 0, false) }

        // 3. 키스톤 보정 적용 (CIPerspectiveCorrection 대신 CIAffineTransform)
        let corrected = applyKeystoneCorrection(image: image, tiltDegrees: verticalAngle)
        return (corrected, verticalAngle, true)
    }

    // MARK: - Edge Detection

    /// Canny 유사 에지 감지 — 강한 수직/수평 에지 추출
    private static func detectEdges(image: CIImage, maxSize: CGFloat) -> [(angle: Double, strength: Double)] {
        // 리사이즈
        let scale = min(1.0, maxSize / max(image.extent.width, image.extent.height))
        let resized = scale < 1.0 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image

        // CIImage → CGImage
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(resized, from: resized.extent) else { return [] }

        let w = cgImage.width
        let h = cgImage.height
        guard w > 50, h > 50 else { return [] }

        // 그레이스케일 변환
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let grayData = ctx.data else { return [] }

        let pixels = grayData.bindMemory(to: UInt8.self, capacity: w * h)

        // Sobel 그래디언트 → 에지 각도 히스토그램
        var angleHistogram = [Double](repeating: 0, count: 360)

        for y in stride(from: 2, to: h - 2, by: 3) {
            for x in stride(from: 2, to: w - 2, by: 3) {
                let idx = y * w + x
                // Sobel X
                let gx = Double(pixels[idx - w - 1]) * -1 + Double(pixels[idx - w + 1]) * 1 +
                          Double(pixels[idx - 1]) * -2 + Double(pixels[idx + 1]) * 2 +
                          Double(pixels[idx + w - 1]) * -1 + Double(pixels[idx + w + 1]) * 1
                // Sobel Y
                let gy = Double(pixels[idx - w - 1]) * -1 + Double(pixels[idx - w]) * -2 + Double(pixels[idx - w + 1]) * -1 +
                          Double(pixels[idx + w - 1]) * 1 + Double(pixels[idx + w]) * 2 + Double(pixels[idx + w + 1]) * 1

                let magnitude = sqrt(gx * gx + gy * gy)
                guard magnitude > 50 else { continue }  // 약한 에지 스킵

                var angle = atan2(gy, gx) * 180.0 / .pi
                if angle < 0 { angle += 360 }
                let bin = Int(angle) % 360
                angleHistogram[bin] += magnitude
            }
        }

        // 수직(90°±15°) 에지 추출
        var edges: [(angle: Double, strength: Double)] = []
        for i in 75...105 {
            if angleHistogram[i] > 0 { edges.append((Double(i), angleHistogram[i])) }
        }
        for i in 255...285 {
            if angleHistogram[i] > 0 { edges.append((Double(i), angleHistogram[i])) }
        }

        return edges.sorted { $0.strength > $1.strength }
    }

    // MARK: - Vertical Tilt Estimation

    /// 수직 에지들의 기울기에서 전체 기울기 추정
    private static func estimateVerticalTilt(edges: [(angle: Double, strength: Double)], imageWidth: CGFloat, imageHeight: CGFloat) -> Double {
        guard !edges.isEmpty else { return 0 }

        // 강한 에지 상위 30%의 가중 평균 각도
        let topCount = max(1, edges.count * 3 / 10)
        let topEdges = Array(edges.prefix(topCount))

        var weightedSum: Double = 0
        var totalWeight: Double = 0
        for edge in topEdges {
            // 90°(완전 수직)에서의 편차
            var deviation = edge.angle - 90.0
            if deviation > 180 { deviation -= 360 }
            if deviation < -180 { deviation += 360 }
            // 270° 근처도 수직 (반대 방향)
            if abs(edge.angle - 270.0) < abs(deviation) {
                deviation = edge.angle - 270.0
            }
            weightedSum += deviation * edge.strength
            totalWeight += edge.strength
        }

        guard totalWeight > 0 else { return 0 }
        return weightedSum / totalWeight
    }

    // MARK: - Keystone Correction

    /// 키스톤 보정 적용 — 수직선을 똑바로 세움
    private static func applyKeystoneCorrection(image: CIImage, tiltDegrees: Double) -> CIImage {
        let width = image.extent.width
        let height = image.extent.height

        // 기울기를 원근 변환으로 변환
        // 위쪽이 넓으면 (양의 기울기) → 아래로 좁히기
        let tiltFactor = tan(tiltDegrees * .pi / 180.0) * 0.3  // 보정 강도 조절

        let topLeft = CGPoint(x: tiltFactor * width, y: height)
        let topRight = CGPoint(x: width - tiltFactor * width, y: height)
        let bottomLeft = CGPoint(x: 0, y: 0)
        let bottomRight = CGPoint(x: width, y: 0)

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

        return filter.outputImage ?? image
    }
}
