import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// 과노출(빨강) / 저노출(파랑) 얼룩말 경고 오버레이
struct ZebraWarningOverlay: View {
    let image: NSImage
    @State private var overlayImage: NSImage?

    var body: some View {
        Group {
            if let overlay = overlayImage {
                Image(nsImage: overlay)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.5)
            }
        }
        .onAppear { generateOverlay() }
        .onChange(of: image) { _ in generateOverlay() }
    }

    private func generateOverlay() {
        DispatchQueue.global(qos: .userInteractive).async {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

            let width = cgImage.width
            let height = cgImage.height

            // 성능: 최대 1200px로 축소
            let scale = min(1.0, 1200.0 / Double(max(width, height)))
            let w = Int(Double(width) * scale)
            let h = Int(Double(height) * scale)

            guard let context = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }

            // 원본 그리기 (리사이즈)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

            guard let data = context.data else { return }
            let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

            // 과노출/저노출 마스크 생성
            let overlayCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!

            guard let overlayData = overlayCtx.data else { return }
            let overlayPtr = overlayData.bindMemory(to: UInt8.self, capacity: w * h * 4)

            // 투명으로 초기화
            memset(overlayPtr, 0, w * h * 4)

            let highThreshold: UInt8 = 250  // 과노출 임계값
            let lowThreshold: UInt8 = 5     // 저노출 임계값

            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let r = ptr[i]
                    let g = ptr[i + 1]
                    let b = ptr[i + 2]

                    // 얼룩말 패턴 (대각선 줄무늬)
                    let stripe = ((x + y) / 4) % 2 == 0

                    if r > highThreshold && g > highThreshold && b > highThreshold {
                        // 과노출: 빨간 줄무늬
                        if stripe {
                            overlayPtr[i] = 255     // R
                            overlayPtr[i + 1] = 0   // G
                            overlayPtr[i + 2] = 0   // B
                            overlayPtr[i + 3] = 180  // A
                        }
                    } else if r < lowThreshold && g < lowThreshold && b < lowThreshold {
                        // 저노출: 파란 줄무늬
                        if stripe {
                            overlayPtr[i] = 0       // R
                            overlayPtr[i + 1] = 100  // G
                            overlayPtr[i + 2] = 255  // B
                            overlayPtr[i + 3] = 150  // A
                        }
                    }
                }
            }

            guard let overlayCG = overlayCtx.makeImage() else { return }
            let result = NSImage(cgImage: overlayCG, size: NSSize(width: w, height: h))

            DispatchQueue.main.async {
                overlayImage = result
            }
        }
    }
}
