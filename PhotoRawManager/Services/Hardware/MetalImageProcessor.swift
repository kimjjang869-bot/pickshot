//
//  MetalImageProcessor.swift
//  PhotoRawManager
//
//  Metal + MPS GPU 기반 이미지 처리: Lanczos 리사이즈, 히스토그램, 톤 커브,
//  IOSurface 제로카피 변환, Accelerate vDSP 라플라시안 선명도.
//

import Foundation
import AppKit
import CoreGraphics
import CoreImage
import Metal
import MetalPerformanceShaders
import IOSurface
import Accelerate
import os.log

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

        // Encode — withUnsafePointer 내부에서 encode해야 포인터가 유효함
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        withUnsafePointer(to: &transform) { ptr in
            lanczos.scaleTransform = ptr
            lanczos.encode(commandBuffer: commandBuffer, sourceTexture: srcTexture, destinationTexture: dstTexture)
        }
        let sem = DispatchSemaphore(value: 0)
        commandBuffer.addCompletedHandler { _ in sem.signal() }
        commandBuffer.commit()
        _ = sem.wait(timeout: .now() + 5)  // 5초 타임아웃 (GPU 행 방지)

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
        let sem = DispatchSemaphore(value: 0)
        commandBuffer.addCompletedHandler { _ in sem.signal() }
        commandBuffer.commit()
        let waitResult = sem.wait(timeout: .now() + 5)  // 보안: GPU 무응답 시 데드락 방지
        guard waitResult == .success else {
            plog("[GPU] histogram 타임아웃\n")
            return nil
        }

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
        let ciImage = CIImage(ioSurface: unsafeBitCast(surface, to: IOSurfaceRef.self))

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

    // MARK: - GPU Laplacian Sharpness (Accelerate vDSP)

    /// Calculate Laplacian sharpness using Accelerate framework (SIMD-optimized).
    /// 10-50x faster than manual pixel loop.
    /// Center-weighted: center 50% gets 70% weight.
    static func laplacianSharpness(pixels: [UInt8], width: Int, height: Int) -> Double {
        let count = width * height
        guard count > 4 else { return 0 }

        // Convert UInt8 → Float 직접 변환 (vDSP_vfltu8)
        // 과거: pixels.map { Int16($0) } → [Float] 두 번 할당 (4K 33M픽셀 ≈ 200MB 임시 피크)
        // 현재: UInt8 버퍼를 vDSP가 직접 Float로 변환 (임시 Int16 배열 제거)
        var floatPixels = [Float](repeating: 0, count: count)
        pixels.withUnsafeBufferPointer { buf in
            floatPixels.withUnsafeMutableBufferPointer { dst in
                if let srcBase = buf.baseAddress, let dstBase = dst.baseAddress {
                    vDSP_vfltu8(srcBase, 1, dstBase, 1, vDSP_Length(buf.count))
                }
            }
        }

        // Laplacian kernel: [0,1,0; 1,-4,1; 0,1,0]
        // Process with stride-2 for speed (same as original)
        let step = 2
        var centerSum: Float = 0
        var centerSqSum: Float = 0
        var centerCount: Int = 0
        var edgeSum: Float = 0
        var edgeSqSum: Float = 0
        var edgeCount: Int = 0

        let cx0 = width / 4, cx1 = width * 3 / 4
        let cy0 = height / 4, cy1 = height * 3 / 4

        // Process rows in parallel using Dispatch
        let rowCount = (height - 2) / step
        let results = UnsafeMutablePointer<(cSum: Float, cSqSum: Float, cCount: Int, eSum: Float, eSqSum: Float, eCount: Int)>.allocate(capacity: rowCount)
        defer { results.deallocate() }

        DispatchQueue.concurrentPerform(iterations: rowCount) { ri in
            let y = 1 + ri * step
            var lCS: Float = 0, lCSq: Float = 0, lCC = 0
            var lES: Float = 0, lESq: Float = 0, lEC = 0

            for x in stride(from: 1, to: width - 1, by: step) {
                let idx = y * width + x
                let lap = -4.0 * floatPixels[idx]
                    + floatPixels[idx - 1]
                    + floatPixels[idx + 1]
                    + floatPixels[idx - width]
                    + floatPixels[idx + width]

                if x >= cx0 && x < cx1 && y >= cy0 && y < cy1 {
                    lCS += lap; lCSq += lap * lap; lCC += 1
                } else {
                    lES += lap; lESq += lap * lap; lEC += 1
                }
            }
            results[ri] = (lCS, lCSq, lCC, lES, lESq, lEC)
        }

        // Aggregate
        for i in 0..<rowCount {
            let r = results[i]
            centerSum += r.cSum; centerSqSum += r.cSqSum; centerCount += r.cCount
            edgeSum += r.eSum; edgeSqSum += r.eSqSum; edgeCount += r.eCount
        }

        guard centerCount > 0 else { return 0 }
        let meanC = Double(centerSum) / Double(centerCount)
        let varCenter = (Double(centerSqSum) / Double(centerCount) - meanC * meanC) / 255.0 / 255.0 * 10000

        if edgeCount > 0 {
            let meanE = Double(edgeSum) / Double(edgeCount)
            let varEdge = (Double(edgeSqSum) / Double(edgeCount) - meanE * meanE) / 255.0 / 255.0 * 10000
            return varCenter * 0.7 + varEdge * 0.3
        }
        return varCenter
    }
}
