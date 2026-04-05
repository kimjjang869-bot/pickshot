import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct BatchProcessService {

    struct Options {
        var targetWidth: Int = 0      // 0 = keep original
        var targetHeight: Int = 0
        var maintainAspect: Bool = true
        var quality: Double = 0.92    // JPEG quality
        var format: OutputFormat = .jpeg
        var watermarkText: String = ""
        var watermarkPosition: WatermarkPosition = .bottomRight
        var watermarkOpacity: Double = 0.5
        var watermarkFontSize: CGFloat = 24
    }

    enum OutputFormat: String, CaseIterable {
        case jpeg = "JPEG"
        case png = "PNG"
        case tiff = "TIFF"

        var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            case .tiff: return .tiff
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .tiff: return "tiff"
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
        let sourceURL = photo.jpgURL

        // Load via CGImageSource (fast, no color conversion)
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return false
        }

        let origW = cgImage.width
        let origH = cgImage.height

        // Calculate target size
        let (targetW, targetH) = calculateTargetSize(
            origW: origW, origH: origH,
            requestW: options.targetWidth, requestH: options.targetHeight,
            maintainAspect: options.maintainAspect
        )

        // Create CGContext for resize
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return false }

        context.interpolationQuality = CGInterpolationQuality.high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        // Draw watermark
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

        guard let resultImage = context.makeImage() else { return false }

        // Save
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = destination
            .appendingPathComponent(baseName)
            .appendingPathExtension(options.format.fileExtension)

        return saveImage(resultImage, to: outputURL, format: options.format, quality: options.quality)
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
