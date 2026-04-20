//
//  ClippingOverlayRenderer.swift
//  PhotoRawManager
//
//  Metal 커널 기반 과노출/저노출 오버레이 생성기.
//  Shift+H 토글 시 현재 프리뷰 이미지에서 마스크 CGImage 생성 → UI overlay.
//  CI 필터 3회 체인 (30-50ms) 대신 single dispatch (2-3ms).
//

import Foundation
import AppKit
import CoreGraphics
import Metal
import os.log

/// 클리핑 오버레이 생성기 (싱글톤 — Metal 파이프라인 공유).
enum ClippingOverlayRenderer {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pickshot",
                                       category: "ClipOverlay")

    private static let device: MTLDevice? = MetalImageProcessor.device

    private static let commandQueue: MTLCommandQueue? = device?.makeCommandQueue()

    /// 컴파일된 Metal 컴퓨트 파이프라인 (lazy 한 번만).
    private static let pipeline: MTLComputePipelineState? = {
        guard let device = device else { return nil }
        do {
            let library: MTLLibrary
            if let defaultLib = device.makeDefaultLibrary() {
                library = defaultLib
            } else {
                library = try device.makeDefaultLibrary(bundle: .main)
            }
            guard let function = library.makeFunction(name: "clipping_overlay") else {
                logger.warning("clipping_overlay kernel 없음")
                return nil
            }
            return try device.makeComputePipelineState(function: function)
        } catch {
            logger.warning("ClippingOverlay pipeline 생성 실패: \(error.localizedDescription)")
            return nil
        }
    }()

    struct Params {
        var overExposureThreshold: Float = 0.98
        var underExposureThreshold: Float = 0.02
        var overlayAlpha: Float = 0.70
    }

    /// 입력 CGImage 에서 클리핑 마스크 CGImage 생성 (배경 투명, 클리핑 픽셀만 빨강/파랑).
    /// 다운샘플 → 원본보다 작음 (1024px 기준). UI 오버레이 용도.
    static func makeOverlay(from image: CGImage, params: Params = Params()) -> CGImage? {
        guard let device = device,
              let queue = commandQueue,
              let pipeline = pipeline else {
            logger.warning("Metal 미지원 → 클리핑 오버레이 생성 불가")
            return nil
        }

        // 다운샘플 (1024 long side) — UI 오버레이라 고해상도 불필요
        let maxSide: CGFloat = 1024
        let scale = min(maxSide / CGFloat(image.width), maxSide / CGFloat(image.height), 1.0)
        let w = max(1, Int(CGFloat(image.width) * scale))
        let h = max(1, Int(CGFloat(image.height) * scale))

        // 1) 입력 텍스처 (다운샘플)
        guard let inputTex = makeDownsampledTexture(from: image, width: w, height: h, device: device) else {
            return nil
        }

        // 2) 출력 텍스처 (shared storage — CPU 읽기)
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false
        )
        outDesc.usage = [.shaderWrite, .shaderRead]
        outDesc.storageMode = .shared
        guard let outputTex = device.makeTexture(descriptor: outDesc) else { return nil }

        // 3) 파라미터 버퍼
        var paramsLocal = params
        guard let paramBuf = device.makeBuffer(
            bytes: &paramsLocal,
            length: MemoryLayout<Params>.size,
            options: .storageModeShared
        ) else { return nil }

        // 4) Encode + commit
        guard let cb = queue.makeCommandBuffer(),
              let encoder = cb.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTex, index: 0)
        encoder.setTexture(outputTex, index: 1)
        encoder.setBuffer(paramBuf, offset: 0, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        let sem = DispatchSemaphore(value: 0)
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
        _ = sem.wait(timeout: .now() + 2)

        // 5) 출력 텍스처 → CGImage
        return cgImage(from: outputTex)
    }

    /// CGImage 를 지정 크기로 다운샘플 + MTLTexture 생성 (RGBA8Unorm, shared).
    private static func makeDownsampledTexture(
        from image: CGImage,
        width: Int,
        height: Int,
        device: MTLDevice
    ) -> MTLTexture? {
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: pixels,
                    bytesPerRow: bytesPerRow)
        return tex
    }

    /// MTLTexture (rgba8Unorm shared) → CGImage.
    private static func cgImage(from texture: MTLTexture) -> CGImage? {
        let w = texture.width
        let h = texture.height
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0
        )
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
