import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import ImageIO
import UniformTypeIdentifiers

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

    /// v8.6.1: CIRAWFilter 는 thread-safe 하지 않음 (NSFastEnumerationMutation 크래시 확인됨).
    /// 공유 캐시를 쓰면 슬라이더/프리뷰/export 가 동시에 property set → outputImage 읽기가
    /// 겹치며 크래시. 매 호출마다 fresh 인스턴스 생성 (디스크 헤더 파싱은 OS 캐시 덕분에 저렴).

    /// v8.6.2: RAW demosaic 결과(CGImage) 캐시 — 슬라이더 드래그 시 CIRAWFilter 재초기화 회피.
    /// 키: (url, scaleFactor, exposure, temperature, tint, wbAuto). 최근 1개만 유지.
    /// crop/curve/contrast/saturation 변경 시엔 키가 같아 캐시 히트 → ~수백ms 절약.
    /// exposure/WB 변경 시에만 캐시 miss → CIRAWFilter 재실행 (raw 품질 보존).
    private struct RAWBaseCacheKey: Equatable {
        let url: URL
        let scaleFactor: Float
        let exposure: Double
        let temperature: Double
        let tint: Double
        let wbAuto: Bool
    }
    private static var rawBaseCache: (key: RAWBaseCacheKey, image: CGImage)?
    private static let rawBaseCacheLock = NSLock()

    static func clearRAWCache() {
        rawBaseCacheLock.lock()
        rawBaseCache = nil
        rawBaseCacheLock.unlock()
    }

    private let context: CIContext
    init(context: CIContext = DevelopPipeline.sharedContext) {
        self.context = context
    }

    // MARK: - Render

    /// 파일 URL 에서 설정을 적용해 NSImage 반환.
    /// - targetSize: 프록시 크기. .zero 면 풀해상도.
    func render(url: URL, settings: DevelopSettings, targetSize: CGSize = .zero) -> NSImage? {
        guard let loaded = loadCIImageWithInfo(url: url, settings: settings, targetSize: targetSize) else {
            return nil
        }
        // CIRAWFilter 경로로 처리된 경우에만 JPG 용 exposure/WB 필터를 스킵 (중복 방지).
        // NEF 등에서 CIRAWFilter 가 실패하면 CIImage 로 fallback 되고 JPG 경로 그대로 사용.
        let processed = applyFilters(to: loaded.image, settings: settings, skipExposureAndManualWB: loaded.usedRAWPath)
        return makeNSImage(from: processed)
    }

    struct LoadResult {
        let image: CIImage
        /// CIRAWFilter 로 처리됐으면 true. false 면 JPG 경로 필요.
        let usedRAWPath: Bool
    }

    /// load 결과 + 어느 경로를 탔는지 반환.
    func loadCIImageWithInfo(url: URL, settings: DevelopSettings, targetSize: CGSize) -> LoadResult? {
        let isRAW = isRAWFile(url: url)

        if isRAW {
            // v8.6.2: scaleFactor 계산 — CGImageSource props 로 0ms (extent 호출 금지)
            var scaleFactor: Float = 1.0
            if targetSize != .zero {
                let native = DevelopPipeline.readRAWPixelSize(url: url) ?? CGSize(width: 6000, height: 4000)
                let longSide = max(native.width, native.height)
                let targetLong = max(targetSize.width, targetSize.height)
                if longSide > 0 && targetLong > 0 && targetLong < longSide {
                    scaleFactor = Float(min(1.0, Double(targetLong) / Double(longSide)))
                }
            }

            // v8.6.2: RAW 베이스 캐시 조회 — 크롭/커브/콘트라스트/채도 드래그 시 CIRAWFilter 스킵.
            let key = RAWBaseCacheKey(
                url: url, scaleFactor: scaleFactor,
                exposure: settings.exposure,
                temperature: settings.wbAuto ? 0 : settings.temperature,
                tint: settings.wbAuto ? 0 : settings.tint,
                wbAuto: settings.wbAuto
            )
            DevelopPipeline.rawBaseCacheLock.lock()
            let cached = DevelopPipeline.rawBaseCache
            DevelopPipeline.rawBaseCacheLock.unlock()
            if let cached = cached, cached.key == key {
                // 캐시 히트 — demosaic 결과 재사용. orient 은 캐시된 이미지에 이미 적용됨.
                let ci = CIImage(cgImage: cached.image)
                return LoadResult(image: ci, usedRAWPath: true)
            }

            // v8.6.1: 매 호출마다 fresh CIRAWFilter (thread-safe 확보).
            if let raw = CIRAWFilter(imageURL: url) {
                if scaleFactor < 1.0 { raw.scaleFactor = scaleFactor }
                raw.exposure = Float(settings.exposure)
                if !settings.wbAuto && (settings.temperature != 0 || settings.tint != 0) {
                    let kelvin = 5500.0 + settings.temperature * 45.0
                    raw.neutralTemperature = Float(kelvin)
                    raw.neutralTint = Float(settings.tint * 1.5)
                }
                if var rawOut = raw.outputImage {
                    // orient 적용 (CIRAWFilter sensor raw → display orient)
                    if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
                       let orient = props[kCGImagePropertyOrientation as String] as? Int,
                       orient > 1,
                       let cgOri = CGImagePropertyOrientation(rawValue: UInt32(orient)) {
                        rawOut = rawOut.oriented(cgOri)
                    }
                    // v8.6.2: demosaic 결과를 CGImage 로 baking 해서 캐싱 (non-RAW 필터 드래그 고속화)
                    if let cg = DevelopPipeline.sharedContext.createCGImage(rawOut, from: rawOut.extent) {
                        DevelopPipeline.rawBaseCacheLock.lock()
                        DevelopPipeline.rawBaseCache = (key: key, image: cg)
                        DevelopPipeline.rawBaseCacheLock.unlock()
                        return LoadResult(image: CIImage(cgImage: cg), usedRAWPath: true)
                    }
                    return LoadResult(image: rawOut, usedRAWPath: true)
                } else {
                    fputs("[DEV-PIPELINE] ⚠️ CIRAWFilter.outputImage nil → CIImage fallback (\(url.lastPathComponent))\n", stderr)
                }
            } else {
                fputs("[DEV-PIPELINE] ⚠️ CIRAWFilter(imageURL:) init 실패 → CIImage fallback (\(url.lastPathComponent))\n", stderr)
            }
            // 2nd try: CIImage 로 직접 (macOS 의 RAW 디코딩 fallback)
            if let ciImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
                let sized = targetSize == .zero ? ciImage : fitScale(ciImage, to: targetSize)
                return LoadResult(image: sized, usedRAWPath: false)
            }
            return nil
        } else {
            guard let ciImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                return nil
            }
            let sized = targetSize == .zero ? ciImage : fitScale(ciImage, to: targetSize)
            return LoadResult(image: sized, usedRAWPath: false)
        }
    }

    /// 이미 로드된 CIImage 에 필터만 적용 (슬라이더 드래그 최적화용).
    func apply(to ciImage: CIImage, settings: DevelopSettings) -> CIImage {
        return applyFilters(to: ciImage, settings: settings)
    }

    /// v8.6.2: **빠른 드래그 프리뷰 용도** — 이미 화면에 있는 Stage 1/2 NSImage 를 기반으로
    /// CI 필터만 적용 (RAW demosaic 스킵). ~20-50ms. 드래그 중 즉시 반응.
    /// 단점: exposure/WB 는 JPG-level 적용 (RAW raw-level 대비 ±2EV 이상에서 품질 저하).
    /// → 드래그 종료 후 300ms idle 에 CIRAWFilter 기반 고품질 render 로 교체 권장.
    func renderFast(baseImage: NSImage, settings: DevelopSettings) -> NSImage? {
        guard let cg = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
              ?? { guard let t = baseImage.tiffRepresentation,
                         let b = NSBitmapImageRep(data: t) else { return nil }
                   return b.cgImage }()
        else { return nil }
        let ci = CIImage(cgImage: cg)
        // skipExposureAndManualWB = false → exposure/WB 를 CI 필터로 적용 (RAW 경로 아님)
        let processed = applyFilters(to: ci, settings: settings, skipExposureAndManualWB: false)
        return makeNSImage(from: processed)
    }

    // MARK: - Load

    /// 파일 로드 (RAW 면 CIRAWFilter, JPG 면 CIImage). RAW 노출/WB 는 여기서 먼저 반영.
    func loadCIImage(url: URL, settings: DevelopSettings, targetSize: CGSize = .zero) -> CIImage? {
        let isRAW = isRAWFile(url: url)

        if isRAW {
            guard let raw = CIRAWFilter(imageURL: url) else {
                fputs("[DEV-PIPELINE] ❌ CIRAWFilter(imageURL:) 실패 — \(url.lastPathComponent)\n", stderr)
                // RAW 필터 실패 시 일반 CIImage 시도 (macOS 가 RAW 를 JPG 로 디코딩 가능하면)
                return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            }
            // RAW 파이프라인에서 직접 처리 가능한 값들은 여기서 먼저 (품질 더 좋음)
            raw.exposure = Float(settings.exposure)
            fputs("[DEV-PIPELINE] RAW exposure=\(settings.exposure) → CIRAWFilter\n", stderr)
            // RAW 의 수동 WB — temperature/tint 는 절대값(K/G-M) 이 필요
            if !settings.wbAuto && (settings.temperature != 0 || settings.tint != 0) {
                // -100~+100 를 5000K 기준 ±4500K 범위로 매핑
                let kelvin = 5500.0 + settings.temperature * 45.0
                raw.neutralTemperature = Float(kelvin)
                raw.neutralTint = Float(settings.tint * 1.5)
                fputs("[DEV-PIPELINE] RAW WB temp=\(kelvin)K tint=\(settings.tint)\n", stderr)
            }
            guard var image = raw.outputImage else {
                fputs("[DEV-PIPELINE] ❌ raw.outputImage 가 nil — \(url.lastPathComponent)\n", stderr)
                return nil
            }
            // v8.6.2 fix: CIRAWFilter.outputImage 는 sensor raw (orient 태그 미적용).
            // Sony α9 III 처럼 orient=6/8 인 RAW 는 landscape 센서를 portrait 로 수동 회전 필요.
            // CIImage.oriented(_:) 는 extent 도 함께 변환해서 이후 파이프라인과 일관.
            if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
               let orient = props[kCGImagePropertyOrientation as String] as? Int,
               orient > 1,
               let cgOri = CGImagePropertyOrientation(rawValue: UInt32(orient)) {
                image = image.oriented(cgOri)
                fputs("[DEV-PIPELINE] RAW orient=\(orient) 적용 (CIRAWFilter 후)\n", stderr)
            }
            if targetSize != .zero {
                image = fitScale(image, to: targetSize)
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

    /// v8.6.2: CGImageSource 메타데이터(PixelWidth/PixelHeight) 로 RAW 센서 해상도 얻기.
    /// `raw.outputImage?.extent` 는 풀 demosaic 을 유도해 수백ms 걸리지만 이건 0ms (파일 헤더 읽기).
    /// 결과는 URL 단위로 메모리 캐싱 (동일 URL 반복 조회 시 부하 0).
    private static let pixelSizeCacheLock = NSLock()
    private static var pixelSizeCache: [URL: CGSize] = [:]
    static func readRAWPixelSize(url: URL) -> CGSize? {
        pixelSizeCacheLock.lock()
        if let cached = pixelSizeCache[url] {
            pixelSizeCacheLock.unlock()
            return cached
        }
        pixelSizeCacheLock.unlock()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int,
              w > 0, h > 0 else { return nil }
        let size = CGSize(width: w, height: h)
        pixelSizeCacheLock.lock()
        // 간단한 사이즈 한도 — 2000 URL 넘으면 절반 비우기
        if pixelSizeCache.count > 2000 {
            pixelSizeCache.removeAll(keepingCapacity: true)
        }
        pixelSizeCache[url] = size
        pixelSizeCacheLock.unlock()
        return size
    }

    private func fitScale(_ image: CIImage, to targetSize: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = min(targetSize.width / extent.width, targetSize.height / extent.height, 1.0)
        if scale >= 1.0 { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Filter Chain

    private func applyFilters(to input: CIImage, settings: DevelopSettings, skipExposureAndManualWB: Bool = false) -> CIImage {
        var image = input

        // 1) JPG 용 WB (RAW 는 load 단계에서 이미 처리됨)
        if !skipExposureAndManualWB {
            image = applyWhiteBalance(to: image, settings: settings)
        } else if settings.wbAuto {
            // RAW 라도 자동 WB 는 후단에서 추가 적용
            image = shadesOfGrayAWB(image)
        }

        // 2) 노출 (JPG 전용 — RAW 는 load 단계에서 이미)
        if !skipExposureAndManualWB, settings.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(settings.exposure)
            if let out = f.outputImage { image = out }
        }

        // 3) 자동 노출 (히스토그램 중앙값 기반 보정)
        if settings.exposureAuto {
            image = applyAutoExposure(to: image)
        }

        // 3b) 컨트라스트 (CIColorControls)
        if settings.contrast != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            // -100 → 0.5, +100 → 1.5
            f.contrast = Float(1.0 + settings.contrast / 200.0)
            if let out = f.outputImage { image = out }
        }

        // 3c) 레벨 (검정점/흰점/감마) — CIToneCurve 5 포인트 근사
        if settings.levelsBlack != 0 || settings.levelsWhite != 1 || settings.levelsGamma != 1 {
            image = applyLevels(to: image, settings: settings)
        }

        // 4) 톤 커브
        if settings.curveAuto {
            image = applyAutoCurve(to: image)
        }
        if !settings.curvePoints.isEmpty {
            image = applyCurve(to: image, points: settings.normalizedCurvePoints())
        }
        // 4b) 4영역 톤 슬라이더 (Lightroom-style parametric curve)
        if settings.toneHighlights != 0 || settings.toneLights != 0 ||
           settings.toneDarks != 0 || settings.toneShadows != 0 {
            image = applyRegionTones(to: image, settings: settings)
        }

        // 5) 회전 (스트레이튼)
        if settings.cropRotation != 0 {
            let f = CIFilter.straighten()
            f.inputImage = image
            f.angle = Float(settings.cropRotation * .pi / 180.0)
            if let out = f.outputImage { image = out }
        }

        // 6) 크롭 (마지막)
        //
        // v8.6.1 좌표계 수정: NSCropView 는 `isFlipped = true` (top-left 원점) 로 draftRect 를
        // 기록하지만 CIImage.extent 는 bottom-left 원점. 이전엔 변환 없이 그대로 곱해서
        // Y축 반전된 크롭 (사용자가 상단 자르면 실제로는 하단이 잘림) 발생.
        // 해결: rect.origin.y 를 (1 - rect.origin.y - rect.height) 로 뒤집어 매핑.
        if let rect = settings.cropRect {
            let extent = image.extent
            let yBottomLeft = 1.0 - rect.origin.y - rect.height
            let cropRect = CGRect(
                x: extent.origin.x + rect.origin.x * extent.width,
                y: extent.origin.y + yBottomLeft * extent.height,
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

    /// Shades of Gray AWB (Finlayson & Trezzi 2004, p=6 근사).
    /// p-norm 평균은 CIKernel 가 필요해서 완전 정확하진 않지만,
    /// 이미지를 미리 6제곱 → Gray World → 6제곱근 복원 순으로 근사.
    /// 실측: Gray World 대비 고채도 피사체 편향이 크게 줄어듦.
    private func shadesOfGrayAWB(_ image: CIImage) -> CIImage {
        // Step 1: 픽셀값 p제곱 (p=6, 부분 근사는 sRGB 감마가 이미 ~2.2 → 추가 3승)
        // sRGB → pow 3 ≈ linear pow 6.6 근사
        let pow3 = CIFilter.gammaAdjust()
        pow3.inputImage = image
        pow3.power = 3.0
        guard let powered = pow3.outputImage else { return grayWorld(image) }

        // Step 2: 면적 평균 (R^p, G^p, B^p 의 평균 = p-norm 의 p승값)
        let avgFilter = CIFilter.areaAverage()
        avgFilter.inputImage = powered
        avgFilter.extent = powered.extent
        guard let avgOut = avgFilter.outputImage else { return grayWorld(image) }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            avgOut,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // Step 3: p승근 복원 (cbrt)
        let rp = max(pow(Double(bitmap[0]) / 255.0, 1.0 / 3.0), 0.02)
        let gp = max(pow(Double(bitmap[1]) / 255.0, 1.0 / 3.0), 0.02)
        let bp = max(pow(Double(bitmap[2]) / 255.0, 1.0 / 3.0), 0.02)

        let rGain = gp / rp
        let bGain = gp / bp

        // Step 4: 극단값 clamp (0.5~2.0 범위) — 불안정한 장면 보호
        let rClamped = rGain.clamped(to: 0.5...2.0)
        let bClamped = bGain.clamped(to: 0.5...2.0)

        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: CGFloat(rClamped), y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: CGFloat(bClamped), w: 0)
        return f.outputImage ?? image
    }

    /// 폴백: 단순 Gray World (Shades of Gray 실패 시).
    private func grayWorld(_ image: CIImage) -> CIImage {
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
        let r = max(Double(bitmap[0]) / 255.0, 0.02)
        let g = max(Double(bitmap[1]) / 255.0, 0.02)
        let b = max(Double(bitmap[2]) / 255.0, 0.02)
        let rGain = (g / r).clamped(to: 0.5...2.0)
        let bGain = (g / b).clamped(to: 0.5...2.0)
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

    /// 레벨 조정 — 검정점(black)/흰점(white) clip + 감마(gamma) 중간톤.
    /// CIToneCurve 5점으로 근사. 감마는 중간점 y = pow(0.5, 1/gamma) 로 매핑.
    private func applyLevels(to image: CIImage, settings: DevelopSettings) -> CIImage {
        let b = CGFloat(settings.levelsBlack).clamped(to: 0...0.9)
        let w = CGFloat(settings.levelsWhite).clamped(to: max(b + 0.1, 0.1)...1.0)
        let gamma = CGFloat(max(0.1, settings.levelsGamma))
        // 입력 x 를 [b, w] 를 [0, 1] 로 선형 매핑 → 감마 → 출력 y
        func mapY(_ x: CGFloat) -> CGFloat {
            let range = w - b
            guard range > 0.0001 else { return 0 }
            let t = min(max((x - b) / range, 0), 1)
            return pow(t, 1.0 / gamma)
        }
        let points = [
            CGPoint(x: 0, y: mapY(0)),
            CGPoint(x: 0.25, y: mapY(0.25)),
            CGPoint(x: 0.5, y: mapY(0.5)),
            CGPoint(x: 0.75, y: mapY(0.75)),
            CGPoint(x: 1, y: mapY(1))
        ]
        return applyCurve(to: image, points: points)
    }

    /// 4영역(shadows/darks/lights/highlights) 슬라이더를 5포인트 CIToneCurve 로 변환해 적용.
    /// 각 슬라이더 값 -100~+100 은 해당 영역 y 좌표를 약 ±0.12 만큼 이동.
    private func applyRegionTones(to image: CIImage, settings: DevelopSettings) -> CIImage {
        let scale: CGFloat = 0.0012  // -100~+100 → ±0.12
        let shY = CGFloat(settings.toneShadows) * scale
        let dkY = CGFloat(settings.toneDarks) * scale
        let ltY = CGFloat(settings.toneLights) * scale
        let hlY = CGFloat(settings.toneHighlights) * scale
        let points = [
            CGPoint(x: 0.0,  y: max(0, min(1, 0.0  + shY))),
            CGPoint(x: 0.25, y: max(0, min(1, 0.25 + (shY + dkY) * 0.5))),
            CGPoint(x: 0.5,  y: max(0, min(1, 0.5  + (dkY + ltY) * 0.5))),
            CGPoint(x: 0.75, y: max(0, min(1, 0.75 + (ltY + hlY) * 0.5))),
            CGPoint(x: 1.0,  y: max(0, min(1, 1.0  + hlY)))
        ]
        return applyCurve(to: image, points: points)
    }

    /// 자동 커브: 히스토그램의 검정/흰점을 레벨 스트레칭 + 중간톤 S 커브.
    /// 알고리즘:
    /// 1. 축소 히스토그램 추출 (256 bin → 휘도)
    /// 2. 하위 1% 지점 = 검정점, 상위 1% = 흰점 → 입력 범위 지정
    /// 3. 중간은 3차 스플라인 S 커브 (약한 대비 부여)
    /// 4. 5개 포인트로 CIToneCurve 에 전달
    private func applyAutoCurve(to image: CIImage) -> CIImage {
        // 1) 휘도 히스토그램 256 bin
        let bins = extractLuminanceHistogram(from: image)
        guard let levels = blackWhitePoints(histogram: bins) else {
            // 폴백: 고정 S 커브
            let fallback = [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 0.25, y: 0.22),
                CGPoint(x: 0.5, y: 0.5),
                CGPoint(x: 0.75, y: 0.78),
                CGPoint(x: 1, y: 1)
            ]
            return applyCurve(to: image, points: fallback)
        }

        let (black, white) = levels
        // 2) 레벨 스트레칭 + 약한 S 를 결합한 5점 (입력 X 는 원본 범위, 출력 Y 는 0~1 선형+S)
        // 검정점 살짝 띄워 보정 (0.02~0.05) — 순수 0 으로 밀면 자연스럽지 않음
        let blackOut: CGFloat = 0.02
        let whiteOut: CGFloat = 0.98

        let mid = (black + white) / 2
        let lower25 = black + (mid - black) * 0.5
        let upper75 = mid + (white - mid) * 0.5

        let points = [
            CGPoint(x: CGFloat(max(0, black)), y: blackOut),
            CGPoint(x: CGFloat(lower25), y: 0.22),
            CGPoint(x: CGFloat(mid), y: 0.5),
            CGPoint(x: CGFloat(upper75), y: 0.78),
            CGPoint(x: CGFloat(min(1, white)), y: whiteOut)
        ]
        return applyCurve(to: image, points: points)
    }

    /// 이미지에서 256-bin 휘도 히스토그램 추출.
    private func extractLuminanceHistogram(from image: CIImage) -> [Int] {
        // CIAreaHistogram: 가로 256 x 세로 1 픽셀의 히스토그램 이미지 생성
        let histFilter = CIFilter.areaHistogram()
        histFilter.inputImage = image
        histFilter.extent = image.extent
        histFilter.scale = 1
        histFilter.count = 256

        guard let histImage = histFilter.outputImage else { return [] }

        // 4 채널 RGBA (G 만 루미넌스 근사로 사용)
        var buffer = [UInt8](repeating: 0, count: 256 * 4)
        context.render(
            histImage,
            toBitmap: &buffer,
            rowBytes: 256 * 4,
            bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // 휘도 근사: 0.299R + 0.587G + 0.114B
        var bins: [Int] = Array(repeating: 0, count: 256)
        for i in 0..<256 {
            let r = Int(buffer[i * 4])
            let g = Int(buffer[i * 4 + 1])
            let b = Int(buffer[i * 4 + 2])
            bins[i] = Int(0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b))
        }
        return bins
    }

    /// 히스토그램에서 상/하위 1% 지점 찾기. 값 0~1.
    private func blackWhitePoints(histogram bins: [Int]) -> (Double, Double)? {
        guard bins.count == 256 else { return nil }
        let total = bins.reduce(0, +)
        guard total > 0 else { return nil }
        let threshold = Double(total) * 0.01

        var acc = 0
        var black = 0
        for i in 0..<256 {
            acc += bins[i]
            if Double(acc) >= threshold { black = i; break }
        }
        acc = 0
        var white = 255
        for i in stride(from: 255, through: 0, by: -1) {
            acc += bins[i]
            if Double(acc) >= threshold { white = i; break }
        }
        // 너무 좁은 범위면 무효 처리 (보정 안 함)
        guard white - black >= 20 else { return nil }
        return (Double(black) / 255.0, Double(white) / 255.0)
    }

    // MARK: - Output

    private func makeNSImage(from ciImage: CIImage) -> NSImage? {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0,
              let cg = context.createCGImage(ciImage, from: extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: extent.width, height: extent.height))
    }

    // MARK: - Auto-Value Computation (자동 버튼이 실제 값 반영용)

    /// 이미지 분석 후 자동 WB 가 계산하는 온도/틴트 값(-100~+100).
    /// 가벼운 썸네일로 계산 (수백 ms).
    func computeAutoWB(url: URL) -> (temperature: Double, tint: Double)? {
        // 썸네일 프록시로 로드 (512x512)
        var settings = DevelopSettings()
        settings.wbAuto = false  // 로드 단계에서 AWB 로직 안 타게
        guard let input = loadCIImage(url: url, settings: settings, targetSize: CGSize(width: 512, height: 512)) else {
            return nil
        }

        // Shades of Gray 와 동일 계산: pow 3 → area average → cbrt → 게인
        let pow3 = CIFilter.gammaAdjust()
        pow3.inputImage = input
        pow3.power = 3.0
        guard let powered = pow3.outputImage else { return nil }
        let avg = CIFilter.areaAverage()
        avg.inputImage = powered
        avg.extent = powered.extent
        guard let avgOut = avg.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            avgOut, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = max(pow(Double(bitmap[0]) / 255.0, 1.0 / 3.0), 0.02)
        let g = max(pow(Double(bitmap[1]) / 255.0, 1.0 / 3.0), 0.02)
        let b = max(pow(Double(bitmap[2]) / 255.0, 1.0 / 3.0), 0.02)
        // 역산: rGain = g/r, bGain = g/b → rGain>1 이면 이미지 R 이 부족 → 따뜻하게 (온도 +)
        let rGain = (g / r).clamped(to: 0.5...2.0)
        let bGain = (g / b).clamped(to: 0.5...2.0)
        // temperature: R vs B 차이
        let temperature = ((rGain - bGain) * 100).clamped(to: -100...100)
        // tint: R+B 평균과 G(=1) 차이 — rb 평균이 1보다 작으면 G 과다 → tint 음수(초록)
        //       rb 평균이 1보다 크면 G 부족 → tint 양수(마젠타)
        let rbMean = (rGain + bGain) / 2
        let tint = ((rbMean - 1.0) * 100).clamped(to: -100...100)
        return (temperature, tint)
    }

    /// 자동 노출 계산: 휘도 중앙값 목표 0.45 기준 EV.
    func computeAutoExposure(url: URL) -> Double? {
        var settings = DevelopSettings()
        settings.exposureAuto = false
        guard let input = loadCIImage(url: url, settings: settings, targetSize: CGSize(width: 512, height: 512)) else {
            return nil
        }
        let avg = CIFilter.areaAverage()
        avg.inputImage = input
        avg.extent = input.extent
        guard let avgOut = avg.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            avgOut, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let luminance = (0.299 * Double(bitmap[0]) + 0.587 * Double(bitmap[1]) + 0.114 * Double(bitmap[2])) / 255.0
        let target = 0.45
        let ratio = target / max(luminance, 0.01)
        let ev = log2(ratio).clamped(to: -2.0...2.0)
        return (ev * 10).rounded() / 10
    }

    /// 자동 대비 — 히스토그램 유효 범위가 좁으면 대비 올림, 넓으면 유지/감소.
    func computeAutoContrast(url: URL) -> Double? {
        let settings = DevelopSettings()
        guard let input = loadCIImage(url: url, settings: settings, targetSize: CGSize(width: 512, height: 512)) else {
            return nil
        }
        let bins = extractLuminanceHistogram(from: input)
        guard bins.count == 256 else { return nil }
        let total = bins.reduce(0, +)
        guard total > 0 else { return nil }

        // 5% / 95% percentile 찾기
        let threshold = Double(total) * 0.05
        var acc = 0
        var lowBin = 0
        for i in 0..<256 {
            acc += bins[i]
            if Double(acc) >= threshold { lowBin = i; break }
        }
        acc = 0
        var highBin = 255
        for i in stride(from: 255, through: 0, by: -1) {
            acc += bins[i]
            if Double(acc) >= threshold { highBin = i; break }
        }
        let range = Double(highBin - lowBin) / 255.0  // 0~1
        guard range > 0.05 else { return 0 }

        // 이상적 range 0.85 목표. 현재 range 가 좁으면 대비 올림, 넓으면 살짝 내림.
        let target = 0.85
        let ratio = target / range
        // ratio 1.0 → 0, ratio 1.5 → +50, ratio 2.0 → +100
        // ratio < 1 → 음수 (이미 대비 강함 → 낮추기)
        let contrast = (ratio - 1.0) * 100
        return max(-40, min(100, contrast.rounded()))
    }

    /// 자동 커브 계산 — 히스토그램 기반 5포인트 반환.
    func computeAutoCurve(url: URL) -> [CGPoint]? {
        var settings = DevelopSettings()
        settings.curveAuto = false
        guard let input = loadCIImage(url: url, settings: settings, targetSize: CGSize(width: 512, height: 512)) else {
            return nil
        }
        let bins = extractLuminanceHistogram(from: input)
        guard let (black, white) = blackWhitePoints(histogram: bins) else {
            return nil
        }
        let blackOut: CGFloat = 0.02
        let whiteOut: CGFloat = 0.98
        let mid = (black + white) / 2
        let lower25 = black + (mid - black) * 0.5
        let upper75 = mid + (white - mid) * 0.5
        return [
            CGPoint(x: CGFloat(max(0, black)), y: blackOut),
            CGPoint(x: CGFloat(lower25), y: 0.22),
            CGPoint(x: CGFloat(mid), y: 0.5),
            CGPoint(x: CGFloat(upper75), y: 0.78),
            CGPoint(x: CGFloat(min(1, white)), y: whiteOut)
        ]
    }

    // MARK: - Export (실제 픽셀 저장)

    /// 보정 적용된 풀해상도 JPEG 을 dest 경로에 저장.
    /// - url: 원본 파일 (RAW/JPG)
    /// - settings: DevelopSettings
    /// - dest: 저장할 JPEG 파일 경로 (.jpg 권장)
    /// - quality: 0.0~1.0 (기본 0.92)
    /// - Returns: 성공 여부
    @discardableResult
    func renderToJPEG(
        url: URL,
        settings: DevelopSettings,
        dest: URL,
        quality: CGFloat = 0.92
    ) -> Bool {
        // 풀해상도 로드
        let isRAW = isRAWFile(url: url)
        guard let input = loadCIImage(url: url, settings: settings, targetSize: .zero) else {
            return false
        }
        let processed = applyFilters(to: input, settings: settings, skipExposureAndManualWB: isRAW)
        let extent = processed.extent
        guard extent.width > 0, extent.height > 0 else { return false }

        // sRGB 색공간으로 CGImage 변환
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cgImage = context.createCGImage(processed, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
            return false
        }

        // CGImageDestination 으로 JPEG 저장
        let uti = UTType.jpeg.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(dest as CFURL, uti, 1, nil) else {
            return false
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        let success = CGImageDestinationFinalize(destination)
        return success
    }
}

// MARK: - Comparable Clamp

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
