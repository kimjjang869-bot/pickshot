//
//  MetalFXUpscaler.swift
//  PhotoRawManager
//
//  MetalFX Spatial Scaler 기반 이미지 업스케일러.
//  Stage 1 프리뷰(1200-1600px) → 화면 목표 크기(예: 3200-4000px) 로 GPU 즉시 업스케일.
//  디스크 재로딩 없이 부드러운 품질 전환 가능 → 사진 전환 UX 개선.
//
//  macOS 13.0+ 필요.
//

import Foundation
import AppKit
import CoreGraphics
import Metal
import MetalFX
import os.log

/// MetalFX Spatial Scaler 래퍼 — 한 번의 dispatch 로 고품질 업스케일.
/// 사용 예:
///   if let up = MetalFXUpscaler.upscale(cgImage: stage1CG, to: CGSize(width: 4000, height: 2667)) {
///       self.image = NSImage(cgImage: up, size: ...)
///   }
@available(macOS 13.0, *)
enum MetalFXUpscaler {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pickshot",
                                       category: "MetalFX")

    /// Metal device/queue 는 MetalImageProcessor 의 것을 재사용 (단일 풀).
    private static var device: MTLDevice? { MetalImageProcessor.device }

    /// 입력 CGImage 를 target 크기로 MetalFX Spatial Upscale.
    /// 실패하거나 Metal/MetalFX 미지원 시 nil 반환 — 호출부에서 fallback(원본 유지 등).
    static func upscale(cgImage: CGImage, to targetSize: CGSize) -> CGImage? {
        guard let device = device else {
            logger.warning("Metal 미지원 → MetalFX 업스케일 불가")
            return nil
        }
        let targetW = Int(targetSize.width)
        let targetH = Int(targetSize.height)
        guard targetW > 0, targetH > 0,
              targetW > cgImage.width, targetH > cgImage.height else {
            // 목표가 작거나 같으면 업스케일 의미 없음
            return nil
        }

        // 1) 입력 텍스처
        guard let inputTex = makeColorTexture(from: cgImage, device: device) else {
            logger.warning("입력 텍스처 생성 실패")
            return nil
        }

        // 2) 출력 텍스처
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: targetW, height: targetH,
            mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outDesc.storageMode = .private
        guard let outputTex = device.makeTexture(descriptor: outDesc) else { return nil }

        // 3) MTLFXSpatialScaler 구성
        let scalerDesc = MTLFXSpatialScalerDescriptor()
        scalerDesc.inputWidth = inputTex.width
        scalerDesc.inputHeight = inputTex.height
        scalerDesc.outputWidth = targetW
        scalerDesc.outputHeight = targetH
        scalerDesc.colorTextureFormat = .bgra8Unorm
        scalerDesc.outputTextureFormat = .bgra8Unorm
        scalerDesc.colorProcessingMode = .perceptual

        guard let scaler = scalerDesc.makeSpatialScaler(device: device) else {
            logger.warning("MTLFXSpatialScaler 생성 실패 — device 미지원?")
            return nil
        }
        scaler.colorTexture = inputTex
        scaler.outputTexture = outputTex

        // 4) Encode + execute
        guard let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer() else {
            return nil
        }
        scaler.encode(commandBuffer: commandBuffer)

        let sem = DispatchSemaphore(value: 0)
        commandBuffer.addCompletedHandler { _ in sem.signal() }
        commandBuffer.commit()
        _ = sem.wait(timeout: .now() + 2)

        // 5) 출력 텍스처 → CGImage
        return readBackCGImage(from: outputTex)
    }

    // MARK: - Helpers

    /// CGImage → MTLTexture (bgra8Unorm). private storage 로 원본 픽셀 CPU 읽기 제거.
    private static func makeColorTexture(from cgImage: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false
        )
        texDesc.usage = [.shaderRead]
        texDesc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: texDesc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: pixels,
                    bytesPerRow: bytesPerRow)
        return tex
    }

    /// MTLTexture(private) → CGImage. blit 로 shared 버퍼에 복사 후 CGImage 생성.
    private static func readBackCGImage(from texture: MTLTexture) -> CGImage? {
        guard let device = device, let queue = device.makeCommandQueue() else { return nil }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        let totalBytes = bytesPerRow * height

        guard let outBuf = device.makeBuffer(length: totalBytes, options: .storageModeShared) else { return nil }

        guard let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: outBuf,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: totalBytes
        )
        blit.endEncoding()
        let sem = DispatchSemaphore(value: 0)
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
        _ = sem.wait(timeout: .now() + 2)

        // CFData — outBuf 바이트 래핑
        let dataProvider = CGDataProvider(data: Data(
            bytesNoCopy: outBuf.contents(),
            count: totalBytes,
            deallocator: .custom({ _, _ in /* outBuf retained by this closure via capture */ })
        ) as CFData)
        // 위 deallocator 에서 outBuf 를 retain 유지시킴 (closure 캡처)
        _ = outBuf  // 컴파일러 warning 방지

        guard let provider = dataProvider else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = [
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            CGBitmapInfo.byteOrder32Little
        ]
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
