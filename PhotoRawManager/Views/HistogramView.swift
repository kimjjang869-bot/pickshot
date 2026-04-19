import SwiftUI
import AppKit

// MARK: - Compact Histogram Overlay (top-right of preview)

struct HistogramOverlay: View {
    let photo: PhotoItem
    @State private var histogramData: HistogramData?
    @State private var isVisible = true

    var body: some View {
        if isVisible, let data = histogramData {
            VStack(spacing: 0) {
                ZStack {
                    HistogramPath(values: data.luminance)
                        .fill(Color.gray.opacity(0.3))
                    HistogramPath(values: data.red)
                        .fill(Color.red.opacity(0.4))
                    HistogramPath(values: data.green)
                        .fill(Color.green.opacity(0.4))
                    HistogramPath(values: data.blue)
                        .fill(Color.blue.opacity(0.4))
                }
                .frame(width: 150, height: 100)
            }
            .background(Color.black.opacity(0.7))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .onTapGesture { isVisible = false }
            .onAppear { loadHistogram() }
            .onChange(of: photo.id) { _, _ in
                loadHistogram()
            }
        } else if !isVisible {
            Button(action: { isVisible = true }) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(4)
                    .background(Color.black.opacity(0.4))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        } else {
            EmptyView()
                .onAppear { loadHistogram() }
                .onChange(of: photo.id) { _, _ in
                    loadHistogram()
                }
        }
    }

    private func loadHistogram() {
        let url = photo.jpgURL
        let photoID = photo.id
        histogramData = nil  // Clear old data immediately
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Self.computeHistogram(url: url)
            DispatchQueue.main.async {
                if self.photo.id == photoID {
                    self.histogramData = data
                }
            }
        }
    }

    static func computeHistogram(url: URL) -> HistogramData? {
        // Load thumbnail (HW JPEG decode if available)
        let cgImage: CGImage?
        if HWJPEGDecoder.isAvailable {
            cgImage = HWJPEGDecoder.decode(url: url, maxPixel: 300)
        } else {
            let options: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 300,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image = cgImage else { return nil }

        // Try Metal GPU histogram first (much faster)
        if MetalImageProcessor.isAvailable,
           let gpuHist = MetalImageProcessor.histogram(image: image) {
            let maxVal = max(
                gpuHist.r.max() ?? 1, gpuHist.g.max() ?? 1,
                gpuHist.b.max() ?? 1, gpuHist.l.max() ?? 1, 1
            )
            return HistogramData(
                red: gpuHist.r.map { CGFloat($0) / CGFloat(maxVal) },
                green: gpuHist.g.map { CGFloat($0) / CGFloat(maxVal) },
                blue: gpuHist.b.map { CGFloat($0) / CGFloat(maxVal) },
                luminance: gpuHist.l.map { CGFloat($0) / CGFloat(maxVal) }
            )
        }

        // Fallback: CPU histogram
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var r = [Int](repeating: 0, count: 256)
        var g = [Int](repeating: 0, count: 256)
        var b = [Int](repeating: 0, count: 256)
        var l = [Int](repeating: 0, count: 256)

        let total = width * height
        for i in stride(from: 0, to: total * 4, by: 4) {
            let rv = Int(pixels[i])
            let gv = Int(pixels[i + 1])
            let bv = Int(pixels[i + 2])
            r[rv] += 1
            g[gv] += 1
            b[bv] += 1
            l[(rv * 299 + gv * 587 + bv * 114) / 1000] += 1
        }

        let maxVal = max(r.max() ?? 1, g.max() ?? 1, b.max() ?? 1, l.max() ?? 1, 1)

        return HistogramData(
            red: r.map { CGFloat($0) / CGFloat(maxVal) },
            green: g.map { CGFloat($0) / CGFloat(maxVal) },
            blue: b.map { CGFloat($0) / CGFloat(maxVal) },
            luminance: l.map { CGFloat($0) / CGFloat(maxVal) }
        )
    }
}

struct HistogramData {
    let red: [CGFloat]
    let green: [CGFloat]
    let blue: [CGFloat]
    let luminance: [CGFloat]
}

struct HistogramPath: Shape {
    let values: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count == 256 else { return path }

        let stepX = rect.width / 255
        path.move(to: CGPoint(x: 0, y: rect.height))

        for i in 0..<256 {
            let x = CGFloat(i) * stepX
            let y = rect.height - values[i] * rect.height
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}
