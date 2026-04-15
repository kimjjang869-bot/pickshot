//
//  HWJPEGDecoder.swift
//  PhotoRawManager
//
//  VideoToolbox hardware JPEG decoding (Apple Silicon media engine) with
//  CGImageSource software fallback. URL 경로는 mmap 기반으로 40MB급 피크를 회피한다.
//

import Foundation
import CoreGraphics
import CoreImage
import VideoToolbox
import CoreMedia
import os.log

// MARK: - Hardware JPEG Decoder

/// Hardware-accelerated JPEG decoding using VideoToolbox / Apple Silicon media engine.
struct HWJPEGDecoder {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pickshot", category: "HWJPEGDecoder")

    /// Whether hardware JPEG decoding is available on this system.
    static var isAvailable: Bool {
        // VTDecompressionSession with JPEG is available on macOS 13+ / Apple Silicon.
        // We try to detect by checking if we can create a minimal session.
        // For safety, cache the result.
        return _hardwareAvailable
    }

    private static let _hardwareAvailable: Bool = {
        guard let desc = try? _makeJPEGFormatDescription(width: 1, height: 1) else { return false }
        var session: VTDecompressionSession?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
        return status == noErr
    }()

    // MARK: Public API

    /// Decode JPEG data using hardware acceleration (falls back to software).
    /// - Parameters:
    ///   - jpegData: Raw JPEG bytes
    ///   - maxPixel: Optional longest-edge cap for downsampling (software path only)
    /// - Returns: Decoded CGImage or nil on failure.
    static func decode(jpegData: Data, maxPixel: CGFloat? = nil) -> CGImage? {
        // Try hardware path first
        if isAvailable, let image = _decodeHardware(jpegData: jpegData) {
            if let maxPixel = maxPixel {
                return _downsample(image: image, maxPixel: maxPixel)
            }
            return image
        }
        // Software fallback via CGImageSource (Data 기반)
        return _decodeSoftware(jpegData: jpegData, maxPixel: maxPixel)
    }

    /// Decode JPEG from file URL using hardware acceleration (falls back to software).
    /// - Note: SW 경로에서는 URL을 직접 `CGImageSourceCreateWithURL`에 전달하여 커널 mmap으로
    ///         파일 전체를 메모리에 올리지 않도록 한다. HW 경로에서만 실제 Data를 읽는다.
    static func decode(url: URL, maxPixel: CGFloat? = nil) -> CGImage? {
        // HW 가능 시에만 전체 Data 로드 (VideoToolbox가 연속 메모리를 요구)
        if isAvailable {
            guard let data = try? Data(contentsOf: url) else {
                logger.error("Failed to read JPEG data from \(url.path)")
                return nil
            }
            if let image = _decodeHardware(jpegData: data) {
                if let maxPixel = maxPixel {
                    return _downsample(image: image, maxPixel: maxPixel)
                }
                return image
            }
            // HW 실패 시 동일 Data로 SW 폴백 (재읽기 방지)
            return _decodeSoftware(jpegData: data, maxPixel: maxPixel)
        }
        // SW 전용 경로: 커널 mmap (Data 로드 없음 → 40MB 일시 피크 제거)
        return _decodeSoftware(url: url, maxPixel: maxPixel)
    }

    // MARK: Hardware Path

    private static func _decodeHardware(jpegData: Data) -> CGImage? {
        // 1. Parse JPEG header to get dimensions
        guard let (width, height) = _jpegDimensions(jpegData) else {
            logger.warning("Could not parse JPEG dimensions, falling back")
            return nil
        }

        // 2. Create format description
        guard let formatDesc = try? _makeJPEGFormatDescription(width: Int32(width), height: Int32(height)) else {
            logger.warning("Could not create JPEG format description")
            return nil
        }

        // 3. Create decompression session
        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            logger.warning("VTDecompressionSessionCreate failed: \(status)")
            return nil
        }

        defer { VTDecompressionSessionInvalidate(session) }

        // 4. Create CMBlockBuffer from JPEG data
        var blockBuffer: CMBlockBuffer?
        let blockStatus = jpegData.withUnsafeBytes { rawBuf -> OSStatus in
            guard rawBuf.baseAddress != nil else { return -1 }
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: jpegData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: jpegData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer = blockBuffer else {
            logger.warning("CMBlockBufferCreate failed")
            return nil
        }

        // Replace the block buffer's data with our JPEG bytes
        let replaceStatus = jpegData.withUnsafeBytes { rawBuf -> OSStatus in
            guard let baseAddr = rawBuf.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddr,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: jpegData.count
            )
        }

        guard replaceStatus == kCMBlockBufferNoErr else {
            logger.warning("CMBlockBufferReplaceDataBytes failed")
            return nil
        }

        // 5. Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = jpegData.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            logger.warning("CMSampleBufferCreateReady failed: \(sampleStatus)")
            return nil
        }

        // 6. Decode synchronously
        var outputPixelBuffer: CVPixelBuffer?
        var infoFlags: VTDecodeInfoFlags = []
        let semaphore = DispatchSemaphore(value: 0)

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags
        ) { status, _, imageBuffer, _, _ in
            if status == noErr {
                outputPixelBuffer = imageBuffer
            }
            semaphore.signal()
        }

        guard decodeStatus == noErr else {
            logger.warning("VTDecompressionSessionDecodeFrame failed: \(decodeStatus)")
            return nil
        }

        _ = semaphore.wait(timeout: .now() + 5.0)
        VTDecompressionSessionWaitForAsynchronousFrames(session)

        // 7. Convert CVPixelBuffer to CGImage
        guard let pixelBuffer = outputPixelBuffer else {
            logger.warning("Hardware decode produced no output")
            return nil
        }

        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        return cgImage
    }

    // MARK: Software Fallback

    private static func _decodeSoftware(jpegData: Data, maxPixel: CGFloat?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil) else { return nil }
        return _decodeSoftware(source: source, maxPixel: maxPixel)
    }

    /// URL 직접 입력 경로 — 커널 mmap으로 파일 전체 로드 회피 (일시 메모리 피크 감소).
    private static func _decodeSoftware(url: URL, maxPixel: CGFloat?) -> CGImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false  // 파싱 단계 캐시 억제
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            logger.warning("CGImageSourceCreateWithURL 실패: \(url.path)")
            return nil
        }
        return _decodeSoftware(source: source, maxPixel: maxPixel)
    }

    /// 공통 썸네일 디코드 로직 (Data/URL 공유)
    private static func _decodeSoftware(source: CGImageSource, maxPixel: CGFloat?) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        if let maxPixel = maxPixel {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
        }

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Helpers

    /// Parse JPEG SOF marker to extract width/height.
    private static func _jpegDimensions(_ data: Data) -> (Int, Int)? {
        guard data.count > 2, data[0] == 0xFF, data[1] == 0xD8 else { return nil }

        var offset = 2
        while offset + 4 < data.count {
            guard data[offset] == 0xFF else { offset += 1; continue }
            let marker = data[offset + 1]

            // SOF markers: 0xC0-0xCF except 0xC4, 0xC8, 0xCC
            if marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                guard offset + 9 < data.count else { return nil }
                let height = Int(data[offset + 5]) << 8 | Int(data[offset + 6])
                let width  = Int(data[offset + 7]) << 8 | Int(data[offset + 8])
                return (width, height)
            }

            // Skip segment
            if offset + 3 < data.count {
                let segLen = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
                guard segLen >= 2 else { break }  // 보안: segLen 0이면 무한루프 방지
                offset += 2 + segLen
            } else {
                break
            }
        }
        return nil
    }

    /// Create a CMFormatDescription for JPEG with given dimensions.
    private static func _makeJPEGFormatDescription(width: Int32, height: Int32) throws -> CMFormatDescription {
        var formatDesc: CMFormatDescription?
        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_FormatName as String: "JPEG" as CFString
        ]
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_JPEG,
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let desc = formatDesc else {
            throw NSError(domain: "HWJPEGDecoder", code: Int(status), userInfo: nil)
        }
        return desc
    }

    /// Software downsample of an already-decoded CGImage.
    private static func _downsample(image: CGImage, maxPixel: CGFloat) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let maxDim = max(w, h)
        if maxDim <= maxPixel { return image }
        let scale = maxPixel / maxDim
        let newW = Int(w * scale)
        let newH = Int(h * scale)
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }
}
