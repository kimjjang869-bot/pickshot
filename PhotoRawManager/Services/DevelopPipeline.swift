import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import ImageIO

/// 비파괴 Core Image 렌더링 파이프라인.
/// RAW/JPG 입력 → WB → Exposure → ToneCurve → Straighten → Crop 순으로 적용.
///
/// 사용 예:
/// ```
/// let pipeline = DevelopPipeline()
/// if let rendered = pipeline.render(url: photoURL, settings: settings, targetSize: CGSize(1024, 768)) {
///     imageView.image = rendered
/// }
/// ```
///
/// 성능:
/// - 슬라이더 드래그 중에는 `targetSize = 1024` 로 호출 (60fps 가능)
/// - 드래그 끝나면 `targetSize = .zero` (풀해상도) 로 재호출
/// - CIContext 는 공유 (Metal 가속)
final class DevelopPipeline {

    // MARK: - Shared CIContext (Metal)

    private static let sharedContext: CIContext = {
        let opts: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .cacheIntermediates: true
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: opts)
        }
        return CIContext(options: opts)
    }()

    private let context: CIContext
    init(context: CIContext = DevelopPipeline.sharedContext) {
        self.context = context
    }

    // MARK: - Render

    /// 파일 URL 에서 설정을 적용해 NSImage 반환.
    /// - targetSize: 프록시 크기. .zero 면 풀해상도.
    func render(url: URL, settings: DevelopSettings, targetSize: CGSize = .zero) -> NSImage? {
        guard let ciImage = loadCIImage(url: url, settings: settings, targetSize: targetSize) else {
            return nil
        }
        let processed = applyFilters(to: ciImage, settings: settings)
        return makeNSImage(from: processed)
    }

    /// 이미 로드된 CIImage 에 필터만 적용 (슬라이더 드래그 최적화용).
    func apply(to ciImage: CIImage, settings: DevelopSettings) -> CIImage {
        return applyFilters(to: ciImage, settings: settings)
    }

    // MARK: - Load

    /// 파일 로드 (RAW 면 CIRAWFilter, JPG 면 CIImage). RAW 노출/WB 는 여기서 먼저 반영.
    func loadCIImage(url: URL, settings: DevelopSettings, targetSize: CGSize = .zero) -> CIImage? {
        let isRAW = isRAWFile(url: url)

        if isRAW {
            guard let raw = CIRAWFilter(imageURL: url) else { return nil }
            // RAW 파이프라인에서 직접 처리 가능한 값들은 여기서 먼저 (품질 더 좋음)
            raw.exposure = Float(settings.exposure)
            // RAW 의 수동 WB — temperature/tint 는 절대값(K/G-M) 이 필요
            if !settings.wbAuto && (settings.temperature != 0 || settings.tint != 0) {
                // -100~+100 를 5000K 기준 ±3000K 범위로 매핑
                let kelvin = 5000.0 + settings.temperature * 30.0
                raw.neutralTemperature = Float(kelvin)
                raw.neutralTint = Float(settings.tint * 1.5)
            }
            // AWB 는 Core Image 가 기본 제공하지 않으므로 후단에서 CIColorMatrix 로 처리
            var image = raw.outputImage
            if let size = targetSize as CGSize?, size != .zero, let img = image {
                image = fitScale(img, to: size)
            }
            return image
        } else {
            guard let ciImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                return nil
            }
            if targetSize != .zero {
                return fitScale(ciImage, to: targetSize)
            }
            return ciImage
        }
    }

    private func isRAWFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["nef", "cr2", "cr3", "arw", "raf", "dng", "orf", "rw2", "pef", "srf"].contains(ext)
    }

    private func fitScale(_ image: CIImage, to targetSize: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = min(targetSize.width / extent.width, targetSize.height / extent.height, 1.0)
        if scale >= 1.0 { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Filter Chain

    private func applyFilters(to input: CIImage, settings: DevelopSettings) -> CIImage {
        var image = input

        // 1) JPG 용 WB (RAW 는 load 단계에서 이미 처리됨)
        if !isRAWPlaceholder(image: input) {
            image = applyWhiteBalance(to: image, settings: settings)
        }

        // 2) 노출 (JPG 전용 — RAW 는 load 단계에서 이미)
        if !isRAWPlaceholder(image: input), settings.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(settings.exposure)
            if let out = f.outputImage { image = out }
        }

        // 3) 자동 노출 (히스토그램 중앙값 기반 보정)
        if settings.exposureAuto {
            image = applyAutoExposure(to: image)
        }

        // 4) 톤 커브
        if settings.curveAuto {
            image = applyAutoCurve(to: image)
        }
        if !settings.curvePoints.isEmpty {
            image = applyCurve(to: image, points: settings.normalizedCurvePoints())
        }

        // 5) 회전 (스트레이튼)
        if settings.cropRotation != 0 {
            let f = CIFilter.straighten()
            f.inputImage = image
            f.angle = Float(settings.cropRotation * .pi / 180.0)
            if let out = f.outputImage { image = out }
        }

        // 6) 크롭 (마지막)
        if let rect = settings.cropRect {
            let extent = image.extent
            let cropRect = CGRect(
                x: extent.origin.x + rect.origin.x * extent.width,
                y: extent.origin.y + rect.origin.y * extent.height,
                width: rect.width * extent.width,
                height: rect.height * extent.height
            )
            image = image.cropped(to: cropRect)
        }

        return image
    }

    /// RAW 여부 간접 판단 (파일로부터 왔는지 모르므로 heuristic). 필요시 flag로 대체 가능.
    private func isRAWPlaceholder(image: CIImage) -> Bool { false }

    // MARK: - White Balance

    /// 수동 WB (JPG) + 자동 WB (Shades of Gray) 적용.
    private func applyWhiteBalance(to image: CIImage, settings: DevelopSettings) -> CIImage {
        var result = image

        // 자동 WB: Shades of Gray (p=6)
        if settings.wbAuto {
            result = shadesOfGrayAWB(result)
        }

        // 수동 WB: temperature(-100~+100) → RGB 게인 (간단 모델)
        if settings.temperature != 0 || settings.tint != 0 {
            let t = settings.temperature / 100.0  // -1 ~ +1
            let tn = settings.tint / 100.0
            // 따뜻하게(+t) → R 게인↑, B 게인↓
            let rGain = 1.0 + t * 0.35
            let bGain = 1.0 - t * 0.35
            // 틴트: +tn(마젠타) → G 게인↓
            let gGain = 1.0 - tn * 0.25

            let f = CIFilter.colorMatrix()
            f.inputImage = result
            f.rVector = CIVector(x: CGFloat(rGain), y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: CGFloat(gGain), z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: CGFloat(bGain), w: 0)
            if let out = f.outputImage { result = out }
        }

        return result
    }

    /// Shades of Gray AWB (Finlayson & Trezzi 2004, p=6).
    /// 간단 근사: CIAreaAverage 로 RGB 평균 추출 후 게인 역산 → CIColorMatrix.
    /// 실제 p=6 p-norm 은 별도 Metal 커널에서 구현 예정 (Day 3). 지금은 Gray World 로 시작.
    private func shadesOfGrayAWB(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let avgFilter = CIFilter.areaAverage()
        avgFilter.inputImage = image
        avgFilter.extent = extent

        guard let avgOut = avgFilter.outputImage else { return image }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            avgOut,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let r = max(Double(bitmap[0]) / 255.0, 0.01)
        let g = max(Double(bitmap[1]) / 255.0, 0.01)
        let b = max(Double(bitmap[2]) / 255.0, 0.01)

        // G 를 기준으로 R/B 게인 맞춤
        let rGain = g / r
        let bGain = g / b

        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: CGFloat(rGain), y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: CGFloat(bGain), w: 0)
        return f.outputImage ?? image
    }

    // MARK: - Auto Exposure

    private func applyAutoExposure(to image: CIImage) -> CIImage {
        let avgFilter = CIFilter.areaAverage()
        avgFilter.inputImage = image
        avgFilter.extent = image.extent
        guard let avgOut = avgFilter.outputImage else { return image }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            avgOut,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // RGB 평균의 휘도 (0.299 R + 0.587 G + 0.114 B)
        let luminance = (0.299 * Double(bitmap[0]) + 0.587 * Double(bitmap[1]) + 0.114 * Double(bitmap[2])) / 255.0
        let target = 0.45  // 중앙에서 약간 어두운 쪽 목표
        let ratio = target / max(luminance, 0.01)
        let ev = log2(ratio).clamped(to: -1.0...1.5)  // 극단값 방지

        let f = CIFilter.exposureAdjust()
        f.inputImage = image
        f.ev = Float(ev)
        return f.outputImage ?? image
    }

    // MARK: - Tone Curve

    private func applyCurve(to image: CIImage, points: [CGPoint]) -> CIImage {
        let f = CIFilter.toneCurve()
        f.inputImage = image
        f.point0 = points[0]
        f.point1 = points.count > 1 ? points[1] : CGPoint(x: 0.25, y: 0.25)
        f.point2 = points.count > 2 ? points[2] : CGPoint(x: 0.5, y: 0.5)
        f.point3 = points.count > 3 ? points[3] : CGPoint(x: 0.75, y: 0.75)
        f.point4 = points.count > 4 ? points[4] : CGPoint(x: 1, y: 1)
        return f.outputImage ?? image
    }

    /// 자동 커브: 히스토그램 기반 S 커브 부여.
    /// 첫 구현은 고정 S 커브. Day 3 에 히스토그램 매칭으로 업그레이드 예정.
    private func applyAutoCurve(to image: CIImage) -> CIImage {
        let sPoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.25, y: 0.22),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.75, y: 0.78),
            CGPoint(x: 1, y: 1)
        ]
        return applyCurve(to: image, points: sPoints)
    }

    // MARK: - Output

    private func makeNSImage(from ciImage: CIImage) -> NSImage? {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0,
              let cg = context.createCGImage(ciImage, from: extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: extent.width, height: extent.height))
    }
}

// MARK: - Comparable Clamp

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
