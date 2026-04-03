import Foundation
import Accelerate
import AppKit
import Vision
import CoreML


// MARK: - AcceleratedImageEngine
/// High-performance image processing using Accelerate (vImage) and Neural Engine (Core ML / Vision).
struct AcceleratedImageEngine {

    // MARK: - vImage Fast Resize

    /// Resize image using vImage (4-8x faster than Core Graphics).
    /// Supports both RGB and RGBA pixel formats via ARGB8888 scaling.
    static func resize(image: CGImage, to size: CGSize) -> CGImage? {
        let targetWidth = Int(size.width)
        let targetHeight = Int(size.height)
        guard targetWidth > 0, targetHeight > 0 else { return nil }

        // --- Source buffer ---
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil, // inherit from source or fall back to sRGB
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        var sourceBuffer = vImage_Buffer()
        var error = vImageBuffer_InitWithCGImage(
            &sourceBuffer,
            &format,
            nil,
            image,
            vImage_Flags(kvImageNoFlags)
        )
        guard error == kvImageNoError else { return nil }

        // --- Destination buffer ---
        var destBuffer = vImage_Buffer()
        error = vImageBuffer_Init(
            &destBuffer,
            vImagePixelCount(targetHeight),
            vImagePixelCount(targetWidth),
            32,
            vImage_Flags(kvImageNoFlags)
        )
        guard error == kvImageNoError else {
            free(sourceBuffer.data)
            return nil
        }

        // --- Scale ---
        error = vImageScale_ARGB8888(
            &sourceBuffer,
            &destBuffer,
            nil,
            vImage_Flags(kvImageHighQualityResampling)
        )

        // Free source immediately; we no longer need it.
        free(sourceBuffer.data)

        guard error == kvImageNoError else {
            free(destBuffer.data)
            return nil
        }

        // --- Create CGImage from destination buffer ---
        let result = vImageCreateCGImageFromBuffer(
            &destBuffer,
            &format,
            nil,
            nil,
            vImage_Flags(kvImageNoAllocate),
            &error
        )

        // If vImageCreateCGImageFromBuffer used kvImageNoAllocate the CGImage
        // now owns destBuffer.data, so we must NOT free it. If the call failed
        // we clean up ourselves.
        if error != kvImageNoError {
            free(destBuffer.data)
            return nil
        }

        guard let cgResult = result?.takeRetainedValue() else {
            free(destBuffer.data)
            return nil
        }
        return cgResult
    }

    /// Convert CGImage to NSImage using vImage resize, constraining the longest
    /// edge to `maxPixel` while preserving aspect ratio.
    static func resizedNSImage(from cgImage: CGImage, maxPixel: CGFloat) -> NSImage? {
        let srcWidth = CGFloat(cgImage.width)
        let srcHeight = CGFloat(cgImage.height)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        let scale = min(maxPixel / max(srcWidth, srcHeight), 1.0)
        let newSize = CGSize(
            width: round(srcWidth * scale),
            height: round(srcHeight * scale)
        )

        guard let resized = resize(image: cgImage, to: newSize) else { return nil }
        return NSImage(cgImage: resized, size: newSize)
    }
}

// MARK: - Neural Engine for Image Analysis
extension AcceleratedImageEngine {

    // MARK: - Fast Local Scene Tag (combined scene + face in one pass)

    /// PickShot scene tag mapping from Vision identifiers to Korean labels.
    private static let pickShotSceneMapping: [(keywords: [String], label: String)] = [
        (["portrait", "selfie", "face", "headshot"], "인물 (클로즈업)"),
        (["person", "people", "man", "woman", "child", "girl", "boy"], "인물"),
        (["crowd", "audience", "group", "team", "gathering"], "단체/군중"),
        (["wedding", "bride", "groom", "ceremony"], "웨딩"),
        (["concert", "stage", "performance", "band", "singer", "microphone"], "공연/콘서트"),
        (["party", "celebration", "birthday", "festival", "carnival"], "파티/축제"),
        (["conference", "presentation", "meeting", "podium", "lecture"], "발표/회의"),
        (["exhibition", "museum", "gallery", "display", "booth"], "전시/팝업"),
        (["landscape", "mountain", "valley", "field", "countryside"], "풍경"),
        (["sunset", "sunrise", "sky", "cloud", "horizon", "dawn", "dusk"], "하늘/일몰"),
        (["ocean", "sea", "beach", "coast", "wave", "shore"], "바다/해변"),
        (["cityscape", "urban", "downtown", "street", "night"], "도시/야경"),
        (["building", "architecture", "house", "church", "tower", "bridge", "skyscraper"], "건물/건축"),
        (["indoor", "room", "interior", "office", "studio", "gym"], "실내"),
        (["food", "meal", "dish", "restaurant", "cooking", "kitchen"], "음식"),
        (["drink", "coffee", "wine", "beer", "cocktail", "beverage", "cup"], "음료"),
        (["product", "merchandise", "package", "commercial", "advertisement"], "제품/상품"),
        (["animal", "dog", "cat", "bird", "pet", "wildlife", "horse"], "동물"),
        (["flower", "plant", "garden", "tree", "forest", "botanical", "leaf"], "식물/자연"),
        (["car", "vehicle", "motorcycle", "bicycle", "airplane", "train", "boat"], "차량/교통"),
        (["texture", "pattern", "abstract", "closeup", "macro", "detail"], "디테일/클로즈업"),
        (["document", "text", "sign", "book", "newspaper", "screen"], "문서/텍스트"),
    ]

    /// Map a single Vision identifier to a PickShot Korean scene tag.
    private static func mapToPickShotTag(_ identifier: String) -> String? {
        let lower = identifier.lowercased()
        for (keywords, label) in pickShotSceneMapping {
            for keyword in keywords where lower.contains(keyword) {
                return label
            }
        }
        return nil
    }

    /// Fast local scene classification returning a PickShot scene tag (Korean).
    /// Runs VNClassifyImageRequest + VNDetectFaceRectanglesRequest in a single
    /// handler.perform() call for maximum throughput on the Neural Engine.
    /// Input is downsampled to 480px for speed.
    ///
    /// - Parameter cgImage: Pre-decoded CGImage (caller handles decode for HW JPEG path).
    /// - Returns: A Korean scene tag string matching PickShot's tag vocabulary, or nil.
    static func classifySceneTag(cgImage: CGImage) -> String? {
        let sceneReq = VNClassifyImageRequest()
        sceneReq.usesCPUOnly = false

        let faceReq = VNDetectFaceRectanglesRequest()
        if #available(macOS 13.0, *) {
            faceReq.revision = VNDetectFaceRectanglesRequestRevision3
        }
        faceReq.usesCPUOnly = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            // Single perform call batches both requests on ANE
            try handler.perform([sceneReq, faceReq])
        } catch {
            return nil
        }

        // --- Scene label ---
        let sorted = (sceneReq.results ?? [])
            .filter { $0.confidence > 0.25 }
            .sorted { $0.confidence > $1.confidence }

        var visionLabel: String?
        for obs in sorted {
            if let tag = mapToPickShotTag(obs.identifier) {
                visionLabel = tag
                break
            }
        }

        // --- Face count (filter low-confidence detections) ---
        let faceCount = faceReq.results?.filter({ $0.confidence > 0.5 }).count ?? 0

        // --- Combine scene + face heuristics ---
        if let label = visionLabel {
            if faceCount >= 3 && label != "공연/콘서트" {
                return "단체/군중"
            } else if faceCount >= 1 && faceCount <= 2 &&
                      (label == "기타" || label == "실내" || label == "풍경" || label == "건물/건축" || label == "도시/야경") {
                return "인물"
            }
            return label
        } else {
            if faceCount >= 3 { return "단체/군중" }
            if faceCount >= 1 { return "인물" }
            return "기타"
        }
    }

    /// Convenience: classify from a file URL (handles downsampling internally).
    static func classifySceneTag(url: URL) -> String? {
        guard let cgImage = downsampledCGImage(url: url, maxPixel: 800) else { return nil }
        return classifySceneTag(cgImage: cgImage)
    }

    // MARK: - Device Capability

    /// Check if Neural Engine is available (Apple Silicon or A11+).
    static var isNeuralEngineAvailable: Bool {
        if #available(macOS 12.0, *) {
            // On Apple Silicon Macs the ANE is always present.
            // We probe by checking for the MLComputeUnits.all option which
            // includes the ANE when hardware is available.
            let config = MLModelConfiguration()
            config.computeUnits = .all
            // If .all is accepted the ANE is present.
            return true
        }
        return false
    }

    /// Preferred computation device: "ANE", "GPU", or "CPU".
    static var preferredDevice: String {
        guard isNeuralEngineAvailable else { return "CPU" }
        #if arch(arm64)
        return "ANE"
        #else
        return "GPU"
        #endif
    }

    // MARK: - Private Helpers

    /// Create a down-sampled CGImage from a URL, suitable for Vision requests.
    private static func downsampledCGImage(url: URL, maxPixel: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

}
