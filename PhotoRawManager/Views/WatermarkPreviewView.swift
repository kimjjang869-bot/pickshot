import SwiftUI

/// 워터마크 실시간 미리보기
struct WatermarkPreviewView: View {
    let photo: PhotoItem?
    let text: String
    let imageURL: URL?
    let position: BatchProcessService.WatermarkPosition
    let opacity: Double
    let fontSize: CGFloat
    let imageScale: Double

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 배경 사진
                if let photo = photo {
                    AsyncThumbnailView(url: photo.displayURL)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.3))
                }

                // 텍스트 워터마크
                if !text.isEmpty {
                    if position == .diagonalFill {
                        diagonalFillOverlay(size: geo.size)
                    } else {
                        singleTextOverlay(size: geo.size)
                    }
                }

                // 로고 워터마크
                if let logoURL = imageURL, let logo = NSImage(contentsOf: logoURL) {
                    logoOverlay(logo: logo, size: geo.size)
                }
            }
            .clipped()
        }
    }

    // MARK: - 단일 위치 텍스트

    private func singleTextOverlay(size: CGSize) -> some View {
        let previewFontSize = max(8, fontSize * size.width / 800)
        return Text(text)
            .font(.system(size: previewFontSize, weight: .medium))
            .foregroundColor(.white.opacity(opacity))
            .shadow(color: .black.opacity(opacity * 0.5), radius: 1, x: 1, y: 1)
            .padding(size.width * 0.03)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: position))
    }

    // MARK: - 사선 채우기

    private func diagonalFillOverlay(size: CGSize) -> some View {
        let previewFontSize = max(6, fontSize * size.width / 800)
        return Canvas { ctx, canvasSize in
            let text = Text(text)
                .font(.system(size: previewFontSize, weight: .medium))
                .foregroundColor(.white.opacity(opacity * 0.7))

            let resolved = ctx.resolve(text)
            let textSize = resolved.measure(in: canvasSize)
            let spacingX = textSize.width * 1.8
            let spacingY = textSize.height * 3.5
            let angle = Angle.degrees(-30)

            var row: CGFloat = -canvasSize.height
            while row < canvasSize.height * 2 {
                var col: CGFloat = -canvasSize.width
                while col < canvasSize.width * 2 {
                    ctx.drawLayer { layerCtx in
                        layerCtx.translateBy(x: col, y: row)
                        layerCtx.rotate(by: angle)
                        layerCtx.draw(resolved, at: .zero, anchor: .center)
                    }
                    col += spacingX
                }
                row += spacingY
            }
        }
    }

    // MARK: - 로고 오버레이

    private func logoOverlay(logo: NSImage, size: CGSize) -> some View {
        let logoW = size.width * imageScale
        let logoH = logoW * (logo.size.height / max(1, logo.size.width))
        return Image(nsImage: logo)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: logoW, height: logoH)
            .opacity(opacity)
            .padding(size.width * 0.03)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: position))
    }

    // MARK: - 위치 → Alignment

    private func alignment(for pos: BatchProcessService.WatermarkPosition) -> Alignment {
        switch pos {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        case .center: return .center
        case .diagonalFill: return .center
        }
    }
}
