import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreImage

struct BatchProcessService {

    struct Options {
        var targetWidth: Int = 0      // 0 = keep original
        var targetHeight: Int = 0
        var maintainAspect: Bool = true
        var quality: Double = 0.92    // JPEG quality
        var format: OutputFormat = .jpeg
        var watermarkText: String = ""
        var watermarkImageURL: URL? = nil   // 이미지 워터마크 (로고)
        var watermarkPosition: WatermarkPosition = .bottomRight
        var watermarkOpacity: Double = 0.5
        var watermarkFontSize: CGFloat = 24
        var watermarkImageScale: Double = 0.15  // 이미지 워터마크 크기 (원본 대비 비율)
    }

    enum OutputFormat: String, CaseIterable {
        case jpeg = "JPEG"
        case png = "PNG"
        case tiff = "TIFF"
        case tiff16 = "16bit TIFF"

        var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            case .tiff, .tiff16: return .tiff
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .tiff, .tiff16: return "tiff"
            }
        }
    }

    enum WatermarkPosition: String, CaseIterable {
        case topLeft = "좌상"
        case topRight = "우상"
        case bottomLeft = "좌하"
        case bottomRight = "우하"
        case center = "중앙"
    }

    // MARK: - Process

    static func process(
        photos: [PhotoItem],
        options: Options,
        destination: URL,
        progress: @escaping (Int, Int) -> Void,
        cancelled: @escaping () -> Bool
    ) -> (success: Int, failed: Int) {
        let total = photos.count
        var successCount = 0
        var failedCount = 0
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: total) { index in
            guard !cancelled() else { return }

            autoreleasepool {
                let photo = photos[index]
                let ok = processOne(photo: photo, options: options, destination: destination)

                lock.lock()
                if ok { successCount += 1 } else { failedCount += 1 }
                let done = successCount + failedCount
                lock.unlock()

                DispatchQueue.main.async {
                    progress(done, total)
                }
            }
        }

        return (success: successCount, failed: failedCount)
    }

    // MARK: - Single Image Processing

    private static func processOne(photo: PhotoItem, options: Options, destination: URL) -> Bool {
        // For 16-bit TIFF, use RAW source if available with CIRAWFilter
        if options.format == .tiff16 {
            return processOne16bit(photo: photo, options: options, destination: destination)
        }

        let sourceURL = photo.jpgURL

        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return false
        }

        // Get original dimensions from image properties (no full decode)
        guard let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let origW = props[kCGImagePropertyPixelWidth] as? Int,
              let origH = props[kCGImagePropertyPixelHeight] as? Int else {
            return false
        }

        // Calculate target size
        let (targetW, targetH) = calculateTargetSize(
            origW: origW, origH: origH,
            requestW: options.targetWidth, requestH: options.targetHeight,
            maintainAspect: options.maintainAspect
        )

        // Use CGImageSource subsample resize — no full decode needed
        let maxDim = max(targetW, targetH)
        let thumbOptions: [NSString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let resizedImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions as CFDictionary) else {
            return false
        }

        // Draw watermark if needed (requires CGContext)
        let resultImage: CGImage
        let needsWatermark = !options.watermarkText.isEmpty || options.watermarkImageURL != nil
        if needsWatermark {
            let colorSpace = resizedImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let context = CGContext(
                data: nil,
                width: resizedImage.width,
                height: resizedImage.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return false }

            context.interpolationQuality = .high
            context.draw(resizedImage, in: CGRect(x: 0, y: 0, width: resizedImage.width, height: resizedImage.height))

            if !options.watermarkText.isEmpty {
                drawWatermark(
                    context: context,
                    width: resizedImage.width,
                    height: resizedImage.height,
                    text: options.watermarkText,
                    position: options.watermarkPosition,
                    opacity: options.watermarkOpacity,
                    fontSize: options.watermarkFontSize
                )
            }

            if let logoURL = options.watermarkImageURL {
                drawImageWatermark(
                    context: context,
                    width: resizedImage.width,
                    height: resizedImage.height,
                    imageURL: logoURL,
                    position: options.watermarkPosition,
                    opacity: options.watermarkOpacity,
                    scale: options.watermarkImageScale
                )
            }

            guard let watermarked = context.makeImage() else { return false }
            resultImage = watermarked
        } else {
            resultImage = resizedImage
        }

        // Save
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = destination
            .appendingPathComponent(baseName)
            .appendingPathExtension(options.format.fileExtension)

        return saveImage(resultImage, to: outputURL, format: options.format, quality: options.quality)
    }

    // MARK: - 16-bit TIFF Processing

    private static func processOne16bit(photo: PhotoItem, options: Options, destination: URL) -> Bool {
        // Prefer RAW source for maximum bit depth; fall back to JPG
        let sourceURL = photo.rawURL ?? photo.jpgURL

        let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])

        // Try loading as RAW via CIRAWFilter for full 16-bit depth
        var ciImage: CIImage?
        if #available(macOS 13.0, *), let rawFilter = CIRAWFilter(imageURL: sourceURL) {
            rawFilter.extendedDynamicRangeAmount = 0  // standard range
            ciImage = rawFilter.outputImage
        }

        // Fallback: load via CIImage
        if ciImage == nil {
            ciImage = CIImage(contentsOf: sourceURL)
        }

        guard var outputCI = ciImage else { return false }

        let origExtent = outputCI.extent
        let origW = Int(origExtent.width)
        let origH = Int(origExtent.height)

        // Calculate target size
        let (targetW, targetH) = calculateTargetSize(
            origW: origW, origH: origH,
            requestW: options.targetWidth, requestH: options.targetHeight,
            maintainAspect: options.maintainAspect
        )

        // Apply resize if needed
        if targetW != origW || targetH != origH {
            let scaleX = CGFloat(targetW) / CGFloat(origW)
            let scaleY = CGFloat(targetH) / CGFloat(origH)
            outputCI = outputCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        // Render to 16-bit CGImage
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgImage = ciContext.createCGImage(
            outputCI,
            from: outputCI.extent,
            format: .RGBA16,
            colorSpace: colorSpace
        ) else { return false }

        // If watermark needed, draw it on a 16-bit context
        let finalImage: CGImage
        let needsWM2 = !options.watermarkText.isEmpty || options.watermarkImageURL != nil
        if needsWM2 {
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue)
            guard let context = CGContext(
                data: nil,
                width: targetW,
                height: targetH,
                bitsPerComponent: 16,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return false }

            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

            if !options.watermarkText.isEmpty {
                drawWatermark(
                    context: context,
                    width: targetW,
                    height: targetH,
                    text: options.watermarkText,
                    position: options.watermarkPosition,
                    opacity: options.watermarkOpacity,
                    fontSize: options.watermarkFontSize
                )
            }
            if let logoURL = options.watermarkImageURL {
                drawImageWatermark(
                    context: context,
                    width: targetW,
                    height: targetH,
                    imageURL: logoURL,
                    position: options.watermarkPosition,
                    opacity: options.watermarkOpacity,
                    scale: options.watermarkImageScale
                )
            }

            guard let result = context.makeImage() else { return false }
            finalImage = result
        } else {
            finalImage = cgImage
        }

        // Save as 16-bit TIFF
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = destination
            .appendingPathComponent(baseName)
            .appendingPathExtension("tiff")

        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else { return false }

        let properties: [CFString: Any] = [
            kCGImagePropertyDepth: 16,
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB
        ]

        CGImageDestinationAddImage(dest, finalImage, properties as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - Helpers

    private static func calculateTargetSize(
        origW: Int, origH: Int,
        requestW: Int, requestH: Int,
        maintainAspect: Bool
    ) -> (Int, Int) {
        // No resize requested
        if requestW <= 0 && requestH <= 0 {
            return (origW, origH)
        }

        if maintainAspect {
            let aspect = Double(origW) / Double(origH)
            if requestW > 0 && requestH > 0 {
                // Fit within both dimensions
                let scaleW = Double(requestW) / Double(origW)
                let scaleH = Double(requestH) / Double(origH)
                let scale = min(scaleW, scaleH)
                return (max(1, Int(Double(origW) * scale)), max(1, Int(Double(origH) * scale)))
            } else if requestW > 0 {
                // Long edge = requestW
                if origW >= origH {
                    return (requestW, max(1, Int(Double(requestW) / aspect)))
                } else {
                    return (max(1, Int(Double(requestW) * aspect)), requestW)
                }
            } else {
                // Long edge = requestH
                if origH >= origW {
                    return (max(1, Int(Double(requestH) * aspect)), requestH)
                } else {
                    return (requestH, max(1, Int(Double(requestH) / aspect)))
                }
            }
        } else {
            return (
                requestW > 0 ? requestW : origW,
                requestH > 0 ? requestH : origH
            )
        }
    }

    private static func drawWatermark(
        context: CGContext,
        width: Int, height: Int,
        text: String,
        position: WatermarkPosition,
        opacity: Double,
        fontSize: CGFloat
    ) {
        // Scale font size relative to image size (base: 2000px long edge)
        let longEdge = CGFloat(max(width, height))
        let scaledFontSize = fontSize * (longEdge / 2000.0)
        let clampedFontSize = max(12, min(scaledFontSize, 200))

        let font = NSFont.systemFont(ofSize: clampedFontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(opacity)
        ]
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(opacity * 0.8)
        shadow.shadowOffset = NSSize(width: 1, height: -1)
        shadow.shadowBlurRadius = 3

        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedString.size()
        let margin: CGFloat = clampedFontSize * 0.8

        // CGContext has origin at bottom-left
        let x: CGFloat
        let y: CGFloat

        switch position {
        case .topLeft:
            x = margin
            y = CGFloat(height) - margin - textSize.height
        case .topRight:
            x = CGFloat(width) - textSize.width - margin
            y = CGFloat(height) - margin - textSize.height
        case .bottomLeft:
            x = margin
            y = margin
        case .bottomRight:
            x = CGFloat(width) - textSize.width - margin
            y = margin
        case .center:
            x = (CGFloat(width) - textSize.width) / 2
            y = (CGFloat(height) - textSize.height) / 2
        }

        // Use NSGraphicsContext to draw attributed string on CGContext
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        // Draw shadow background
        let shadowAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black.withAlphaComponent(opacity * 0.5)
        ]
        let shadowString = NSAttributedString(string: text, attributes: shadowAttrs)
        shadowString.draw(at: NSPoint(x: x + 1, y: y - 1))

        // Draw main text
        attributedString.draw(at: NSPoint(x: x, y: y))

        NSGraphicsContext.restoreGraphicsState()
    }

    /// 이미지 워터마크 (로고)
    private static func drawImageWatermark(
        context: CGContext,
        width: Int, height: Int,
        imageURL: URL,
        position: WatermarkPosition,
        opacity: Double,
        scale: Double
    ) {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let logoImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }

        // 로고 크기 계산 (원본 장변 대비 비율)
        let longEdge = CGFloat(max(width, height))
        let logoMaxSize = longEdge * CGFloat(scale)
        let logoW = CGFloat(logoImage.width)
        let logoH = CGFloat(logoImage.height)
        let ratio = min(logoMaxSize / logoW, logoMaxSize / logoH)
        let drawW = logoW * ratio
        let drawH = logoH * ratio
        let margin: CGFloat = longEdge * 0.02

        let x: CGFloat
        let y: CGFloat

        switch position {
        case .topLeft:
            x = margin; y = CGFloat(height) - margin - drawH
        case .topRight:
            x = CGFloat(width) - drawW - margin; y = CGFloat(height) - margin - drawH
        case .bottomLeft:
            x = margin; y = margin
        case .bottomRight:
            x = CGFloat(width) - drawW - margin; y = margin
        case .center:
            x = (CGFloat(width) - drawW) / 2; y = (CGFloat(height) - drawH) / 2
        }

        context.saveGState()
        context.setAlpha(CGFloat(opacity))
        context.draw(logoImage, in: CGRect(x: x, y: y, width: drawW, height: drawH))
        context.restoreGState()
    }

    private static func saveImage(_ image: CGImage, to url: URL, format: OutputFormat, quality: Double) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else { return false }

        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }

        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
