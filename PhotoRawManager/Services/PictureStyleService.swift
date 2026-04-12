import Foundation
import AppKit
import CoreImage
import ImageIO

// MARK: - 픽쳐 스타일 모델

struct PictureStyle: Identifiable, Hashable {
    let id: String          // "camera_original", "standard", "vivid" 등
    let name: String        // 한국어 표시명
    let category: String    // "카메라", "표준", "인물", "풍경", "특수"
    let icon: String        // SF Symbol 이름
}

// MARK: - 픽쳐 스타일 서비스

struct PictureStyleService {

    // MARK: - 스타일 목록

    static let styles: [PictureStyle] = [
        // 카메라 원본
        PictureStyle(id: "camera_original", name: "카메라 원본", category: "카메라", icon: "camera.fill"),

        // 표준 스타일
        PictureStyle(id: "standard", name: "스탠다드", category: "표준", icon: "circle"),
        PictureStyle(id: "vivid", name: "비비드", category: "표준", icon: "paintpalette"),
        PictureStyle(id: "neutral", name: "뉴트럴", category: "표준", icon: "circle.dashed"),

        // 인물
        PictureStyle(id: "portrait", name: "포트레이트", category: "인물", icon: "person"),
        PictureStyle(id: "portrait_warm", name: "포트레이트 (웜)", category: "인물", icon: "person.fill"),

        // 풍경
        PictureStyle(id: "landscape", name: "풍경", category: "풍경", icon: "mountain.2"),
        PictureStyle(id: "landscape_vivid", name: "풍경 (비비드)", category: "풍경", icon: "mountain.2.fill"),

        // 특수
        PictureStyle(id: "monochrome", name: "흑백", category: "특수", icon: "circle.lefthalf.filled"),
        PictureStyle(id: "sepia", name: "세피아", category: "특수", icon: "circle.righthalf.filled"),
        PictureStyle(id: "flat", name: "플랫 (로그)", category: "특수", icon: "minus"),
        PictureStyle(id: "film", name: "필름", category: "특수", icon: "film"),
    ]

    /// 카테고리별 그룹
    static var groupedStyles: [(String, [PictureStyle])] {
        let order = ["카메라", "표준", "인물", "풍경", "특수"]
        var dict: [String: [PictureStyle]] = [:]
        for s in styles { dict[s.category, default: []].append(s) }
        return order.compactMap { cat in
            guard let items = dict[cat] else { return nil }
            return (cat, items)
        }
    }

    // MARK: - 공유 CIContext (Metal GPU)

    private static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    // MARK: - 카메라 원본 JPEG 추출

    /// RAW 파일에서 임베디드 JPEG 추출 (카메라 픽쳐스타일 100% 동일)
    static func extractEmbeddedJPEG(from rawURL: URL) -> NSImage? {
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(rawURL as CFURL, nil) else { return nil }

            // 임베디드 썸네일(실제로는 풀사이즈 JPEG 프리뷰) 추출
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,  // 없으면 생성하지 않음
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]

            // 먼저 서브이미지 개수 확인 (RAW 파일은 보통 2개: RAW + 임베디드 JPEG)
            let imageCount = CGImageSourceGetCount(source)

            // 임베디드 JPEG 찾기: 가장 큰 것을 선택 (역순 탐색 — 큰 것이 뒤에 있는 경우가 많음)
            if imageCount > 1 {
                var bestImage: CGImage?
                var bestSize = 0
                for idx in stride(from: imageCount - 1, through: 0, by: -1) {
                    if let cgImage = CGImageSourceCreateImageAtIndex(source, idx, options as CFDictionary) {
                        let w = cgImage.width
                        let h = cgImage.height
                        let size = w * h
                        if w > 640 && h > 480 {
                            if size > 1_000_000 { // 1MP 이상이면 즉시 반환 (충분한 크기)
                                return NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
                            }
                            if size > bestSize {
                                bestImage = cgImage
                                bestSize = size
                            }
                        }
                    }
                }
                if let best = bestImage {
                    return NSImage(cgImage: best, size: NSSize(width: best.width, height: best.height))
                }
            }

            // 폴백: 썸네일 추출 시도
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                let w = thumb.width
                let h = thumb.height
                return NSImage(cgImage: thumb, size: NSSize(width: w, height: h))
            }

            return nil
        }
    }

    // MARK: - 커스텀 스타일 적용

    /// CIRAWFilter로 RAW 디코딩 + 스타일 적용
    /// - Parameters:
    ///   - styleId: 스타일 ID ("standard", "vivid" 등)
    ///   - rawURL: RAW 파일 경로
    ///   - maxPixel: 최대 픽셀 (0 = 원본 크기)
    /// - Returns: 스타일 적용된 NSImage
    static func applyStyle(_ styleId: String, to rawURL: URL, maxPixel: CGFloat = 0) -> NSImage? {
        // 카메라 원본은 임베디드 JPEG 추출
        if styleId == "camera_original" {
            return extractEmbeddedJPEG(from: rawURL)
        }

        return autoreleasepool {
            // RAW 디코딩
            var output: CIImage?

            if #available(macOS 12.0, *) {
                if let rawFilter = CIRAWFilter(imageURL: rawURL) {
                    rawFilter.boostAmount = 0
                    rawFilter.isGamutMappingEnabled = true

                    // 크기 조절
                    if maxPixel > 0 {
                        let native = rawFilter.nativeSize
                        let origMax = max(native.width, native.height)
                        if origMax > maxPixel {
                            rawFilter.scaleFactor = Float(maxPixel / origMax)
                        }
                    }

                    // 스타일별 RAW 파라미터 적용
                    applyRAWFilterParams(rawFilter, styleId: styleId)

                    output = rawFilter.outputImage
                } else {
                    output = CIImage(contentsOf: rawURL)
                }
            } else {
                output = CIImage(contentsOf: rawURL)
            }

            guard var image = output else { return nil }

            // 크기 조절 (CIRAWFilter 미지원 경로용)
            if maxPixel > 0 {
                let extent = image.extent
                let origMax = max(extent.width, extent.height)
                if origMax > maxPixel {
                    let scale = maxPixel / origMax
                    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                }
            }

            // 후처리 필터 체인 적용
            image = applyPostFilters(image, styleId: styleId)

            // CGImage 렌더링
            let extent = image.extent
            guard let cgImage = ciContext.createCGImage(image, from: extent,
                                                        format: .RGBA8,
                                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
                return nil
            }

            return NSImage(cgImage: cgImage, size: NSSize(width: extent.width, height: extent.height))
        }
    }

    /// 미리보기용: 800px로 빠르게 스타일 적용
    static func previewStyle(_ styleId: String, rawURL: URL) -> NSImage? {
        return applyStyle(styleId, to: rawURL, maxPixel: 800)
    }

    // MARK: - RAW 필터 파라미터 (CIRAWFilter 전용)

    @available(macOS 12.0, *)
    private static func applyRAWFilterParams(_ rawFilter: CIRAWFilter, styleId: String) {
        switch styleId {
        case "standard":
            // 기본 설정 유지
            break

        case "vivid":
            // 채도 강화 + 대비 증가 + 바이브런스
            rawFilter.boostAmount = 0.3
            rawFilter.boostShadowAmount = 0.15

        case "neutral":
            // 낮은 채도/대비
            rawFilter.boostAmount = -0.1
            rawFilter.boostShadowAmount = 0

        case "portrait":
            // 약간의 따뜻함 + 부드러운 그림자
            rawFilter.boostShadowAmount = 0.2

        case "portrait_warm":
            // 강한 따뜻함 + 채도 약간 증가
            rawFilter.boostShadowAmount = 0.25
            rawFilter.boostAmount = 0.1

        case "landscape":
            // 채도 증가 + 대비 증가 + 선명도
            rawFilter.boostAmount = 0.2
            rawFilter.boostShadowAmount = 0.1

        case "landscape_vivid":
            // 강한 채도/대비
            rawFilter.boostAmount = 0.4
            rawFilter.boostShadowAmount = 0.2

        case "flat":
            // 낮은 대비 (로그 스타일)
            rawFilter.boostAmount = -0.2
            rawFilter.boostShadowAmount = 0.3

        default:
            break
        }
    }

    // MARK: - 후처리 필터 체인

    private static func applyPostFilters(_ image: CIImage, styleId: String) -> CIImage {
        var result = image

        switch styleId {
        case "vivid":
            result = applySaturation(result, amount: 1.3)
            result = applyContrast(result, amount: 1.15)
            result = applyVibrance(result, amount: 0.2)

        case "neutral":
            result = applySaturation(result, amount: 0.85)
            result = applyContrast(result, amount: 0.95)

        case "portrait":
            result = applyTemperatureShift(result, fromTemp: 6200, toTemp: 6500)
            result = applySaturation(result, amount: 1.05)

        case "portrait_warm":
            result = applyTemperatureShift(result, fromTemp: 6000, toTemp: 6800)
            result = applySaturation(result, amount: 1.1)

        case "landscape":
            result = applySaturation(result, amount: 1.2)
            result = applyContrast(result, amount: 1.1)
            result = applySharpen(result, radius: 2.0, intensity: 0.4)

        case "landscape_vivid":
            result = applySaturation(result, amount: 1.4)
            result = applyContrast(result, amount: 1.2)
            result = applySharpen(result, radius: 3.0, intensity: 0.6)

        case "monochrome":
            if let filter = CIFilter(name: "CIPhotoEffectMono") {
                filter.setValue(result, forKey: kCIInputImageKey)
                if let out = filter.outputImage { result = out }
            }

        case "sepia":
            if let filter = CIFilter(name: "CISepiaTone") {
                filter.setValue(result, forKey: kCIInputImageKey)
                filter.setValue(0.6, forKey: kCIInputIntensityKey)
                if let out = filter.outputImage { result = out }
            }

        case "flat":
            result = applyContrast(result, amount: 0.8)

        case "film":
            result = applyFilmLook(result)

        default:
            break
        }

        return result
    }

    // MARK: - 개별 필터 헬퍼

    /// 채도 조절
    private static func applySaturation(_ image: CIImage, amount: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(amount, forKey: kCIInputSaturationKey)
        filter.setValue(0.0, forKey: kCIInputBrightnessKey)
        filter.setValue(1.0, forKey: kCIInputContrastKey)
        return filter.outputImage ?? image
    }

    /// 대비 조절
    private static func applyContrast(_ image: CIImage, amount: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(1.0, forKey: kCIInputSaturationKey)
        filter.setValue(0.0, forKey: kCIInputBrightnessKey)
        filter.setValue(amount, forKey: kCIInputContrastKey)
        return filter.outputImage ?? image
    }

    /// 바이브런스 조절
    private static func applyVibrance(_ image: CIImage, amount: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIVibrance") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(amount, forKey: "inputAmount")
        return filter.outputImage ?? image
    }

    /// 색온도 시프트
    private static func applyTemperatureShift(_ image: CIImage, fromTemp: CGFloat, toTemp: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: fromTemp, y: 0), forKey: "inputNeutral")
        filter.setValue(CIVector(x: toTemp, y: 0), forKey: "inputTargetNeutral")
        return filter.outputImage ?? image
    }

    /// 선명도 (언샤프 마스크)
    private static func applySharpen(_ image: CIImage, radius: CGFloat, intensity: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIUnsharpMask") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        filter.setValue(intensity, forKey: kCIInputIntensityKey)
        return filter.outputImage ?? image
    }

    /// 필름 룩: S커브 톤 + 뮤트 하이라이트 + 약간의 그레인
    private static func applyFilmLook(_ image: CIImage) -> CIImage {
        var result = image

        // S커브 톤 매핑
        if let toneCurve = CIFilter(name: "CIToneCurve") {
            toneCurve.setValue(result, forKey: kCIInputImageKey)
            toneCurve.setValue(CIVector(x: 0.0, y: 0.05), forKey: "inputPoint0")  // 블랙 리프트
            toneCurve.setValue(CIVector(x: 0.25, y: 0.18), forKey: "inputPoint1") // 섀도 약간 올림
            toneCurve.setValue(CIVector(x: 0.5, y: 0.50), forKey: "inputPoint2")  // 미드톤 유지
            toneCurve.setValue(CIVector(x: 0.75, y: 0.78), forKey: "inputPoint3") // 하이라이트 약간 내림
            toneCurve.setValue(CIVector(x: 1.0, y: 0.93), forKey: "inputPoint4")  // 화이트 클리핑
            if let out = toneCurve.outputImage { result = out }
        }

        // 약간의 채도 감소 (필름 특성)
        result = applySaturation(result, amount: 0.9)

        return result
    }
}
