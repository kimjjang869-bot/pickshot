//
//  HardwareAcceleration.swift
//  PhotoRawManager
//
//  VideoToolbox hardware JPEG decoding and Metal GPU image processing.
//

import Foundation
import AppKit
import CoreGraphics
import CoreImage
import VideoToolbox
import CoreMedia
import Metal
import MetalPerformanceShaders
import IOSurface
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
        // Software fallback via CGImageSource
        return _decodeSoftware(jpegData: jpegData, maxPixel: maxPixel)
    }

    /// Decode JPEG from file URL using hardware acceleration (falls back to software).
    static func decode(url: URL, maxPixel: CGFloat? = nil) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else {
            logger.error("Failed to read JPEG data from \(url.path)")
            return nil
        }
        return decode(jpegData: data, maxPixel: maxPixel)
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

// MARK: - Metal GPU Image Processor

/// GPU-accelerated image processing using Metal and Metal Performance Shaders.
struct MetalImageProcessor {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pickshot", category: "MetalGPU")

    // MARK: Lazy Metal Resources (thread-safe)

    /// Shared Metal device.
    static var device: MTLDevice? { _device }

    /// Whether Metal is available.
    static var isAvailable: Bool { _device != nil }

    private static let _device: MTLDevice? = MTLCreateSystemDefaultDevice()

    private static let _commandQueue: MTLCommandQueue? = {
        _device?.makeCommandQueue()
    }()

    private static let _ciContext: CIContext? = {
        guard let device = _device else { return nil }
        return CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .priorityRequestLow: false
        ])
    }()

    // MARK: Resize

    /// Resize image on GPU using MPS Lanczos scale (high quality).
    /// - Parameters:
    ///   - image: Source CGImage
    ///   - size: Target size in pixels
    /// - Returns: Resized CGImage or nil on failure.
    static func resize(image: CGImage, to size: CGSize) -> CGImage? {
        guard let device = _device, let commandQueue = _commandQueue else {
            logger.warning("Metal not available, cannot resize on GPU")
            return nil
        }

        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }

        // Create textures
        let outDesc = _makeTextureDescriptor(width: width, height: height)

        guard let srcTexture = _texture(from: image, device: device),
              let dstTexture = device.makeTexture(descriptor: outDesc) else {
            logger.warning("Failed to create Metal textures")
            return nil
        }

        // Create Lanczos scaler
        let lanczos = MPSImageLanczosScale(device: device)

        // Configure transform
        let scaleX = Double(width) / Double(image.width)
        let scaleY = Double(height) / Double(image.height)
        let translateX: Double = 0
        let translateY: Double = 0
        var transform = MPSScaleTransform(scaleX: scaleX, scaleY: scaleY, translateX: translateX, translateY: translateY)

        withUnsafePointer(to: &transform) { ptr in
            lanczos.scaleTransform = ptr
        }

        // Encode
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        lanczos.encode(commandBuffer: commandBuffer, sourceTexture: srcTexture, destinationTexture: dstTexture)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read back
        return _cgImage(from: dstTexture)
    }

    // MARK: Histogram

    /// Generate RGBA histogram on GPU using Metal Performance Shaders.
    /// Returns arrays of 256 bins each for red, green, blue, and luminance channels.
    static func histogram(image: CGImage) -> (r: [Int], g: [Int], b: [Int], l: [Int])? {
        guard let device = _device, let commandQueue = _commandQueue else {
            logger.warning("Metal not available for histogram")
            return nil
        }

        guard let srcTexture = _texture(from: image, device: device) else {
            logger.warning("Failed to create texture for histogram")
            return nil
        }

        // Configure histogram
        var histogramInfo = MPSImageHistogramInfo(
            numberOfHistogramEntries: 256,
            histogramForAlpha: false,
            minPixelValue: vector_float4(0, 0, 0, 0),
            maxPixelValue: vector_float4(1, 1, 1, 1)
        )

        let histogram = MPSImageHistogram(device: device, histogramInfo: &histogramInfo)
        let bufferLength = histogram.histogramSize(forSourceFormat: srcTexture.pixelFormat)

        guard let histogramBuffer = device.makeBuffer(length: bufferLength, options: .storageModeShared) else {
            return nil
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        histogram.encode(
            to: commandBuffer,
            sourceTexture: srcTexture,
            histogram: histogramBuffer,
            histogramOffset: 0
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Parse results - MPS outputs interleaved RGBA histogram as uint32
        let ptr = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: 256 * 4)

        var r = [Int](repeating: 0, count: 256)
        var g = [Int](repeating: 0, count: 256)
        var b = [Int](repeating: 0, count: 256)
        var l = [Int](repeating: 0, count: 256)

        for i in 0..<256 {
            let rVal = Int(ptr[i * 4 + 0])
            let gVal = Int(ptr[i * 4 + 1])
            let bVal = Int(ptr[i * 4 + 2])
            r[i] = rVal
            g[i] = gVal
            b[i] = bVal
            // Approximate luminance from RGB histogram bins
            l[i] = Int(Double(rVal) * 0.299 + Double(gVal) * 0.587 + Double(bVal) * 0.114)
        }

        return (r: r, g: g, b: b, l: l)
    }

    // MARK: Tone Curve

    /// Apply brightness, contrast, and gamma adjustments on GPU via Core Image + Metal.
    /// - Parameters:
    ///   - image: Source CGImage
    ///   - brightness: -1.0 to 1.0 (0 = no change)
    ///   - contrast: 0.0 to 4.0 (1.0 = no change)
    ///   - gamma: 0.1 to 5.0 (1.0 = no change)
    /// - Returns: Adjusted CGImage or nil on failure.
    static func applyToneCurve(image: CGImage, brightness: Float, contrast: Float, gamma: Float) -> CGImage? {
        guard let ciContext = _ciContext else {
            logger.warning("Metal CIContext not available for tone curve")
            return nil
        }

        var ciImage = CIImage(cgImage: image)

        // Apply color controls (brightness + contrast)
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(ciImage, forKey: kCIInputImageKey)
            colorControls.setValue(brightness, forKey: kCIInputBrightnessKey)
            colorControls.setValue(contrast, forKey: kCIInputContrastKey)
            if let output = colorControls.outputImage {
                ciImage = output
            }
        }

        // Apply gamma via CIGammaAdjust
        if gamma != 1.0 {
            if let gammaFilter = CIFilter(name: "CIGammaAdjust") {
                gammaFilter.setValue(ciImage, forKey: kCIInputImageKey)
                gammaFilter.setValue(gamma, forKey: "inputPower")
                if let output = gammaFilter.outputImage {
                    ciImage = output
                }
            }
        }

        let extent = ciImage.extent
        guard let result = ciContext.createCGImage(ciImage, from: extent) else {
            logger.warning("CIContext.createCGImage failed")
            return nil
        }

        return result
    }

    // MARK: IOSurface Zero-Copy

    /// Create an IOSurface-backed texture for zero-copy GPU display.
    static func createIOSurface(from image: CGImage) -> IOSurface? {
        let width = image.width
        let height = image.height
        let bytesPerElement = 4
        let bytesPerRow = width * bytesPerElement

        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: bytesPerElement,
            .bytesPerRow: bytesPerRow,
            .allocSize: bytesPerRow * height,
            .pixelFormat: kCVPixelFormatType_32BGRA
        ]

        guard let surface = IOSurface(properties: properties) else {
            logger.warning("Failed to create IOSurface")
            return nil
        }

        // Lock and draw into the surface
        surface.lock(options: [], seed: nil)

        let baseAddress = surface.baseAddress
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            surface.unlock(options: [], seed: nil)
            logger.warning("Failed to create CGContext for IOSurface")
            return nil
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        surface.unlock(options: [], seed: nil)

        return surface
    }

    /// Convert IOSurface to NSImage for display.
    static func nsImage(from surface: IOSurface) -> NSImage? {
        let width = surface.width
        let height = surface.height

        // Create a CIImage from the IOSurface
        let ciImage = CIImage(ioSurface: surface)

        guard let ciContext = _ciContext else {
            // Fallback without Metal CIContext
            let fallbackContext = CIContext()
            guard let cgImage = fallbackContext.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
                return nil
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        }

        guard let cgImage = ciContext.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            logger.warning("Failed to create CGImage from IOSurface")
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // MARK: Private Texture Helpers

    private static func _makeTextureDescriptor(width: Int, height: Int) -> MTLTextureDescriptor {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .managed
        return desc
    }

    private static func _texture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width
        let height = image.height
        let bytesPerRow = 4 * width

        let desc = _makeTextureDescriptor(width: width, height: height)
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        // Render CGImage into a buffer then upload
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let data = ctx.data else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        return texture
    }

    private static func _cgImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = 4 * width
        let totalBytes = bytesPerRow * height

        var pixelData = [UInt8](repeating: 0, count: totalBytes)
        texture.getBytes(
            &pixelData,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixelData) as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
