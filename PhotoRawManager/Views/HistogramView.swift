import SwiftUI
import AppKit

// MARK: - Compact Histogram Overlay (top-right of preview)

/// v8.7: 슬라이더 조절 중 실시간 히스토그램 반영.
/// - url: 원본 파일 URL (첫 로드 + developedImage 없을 때 사용)
/// - liveImage: 현재 프리뷰에 표시된 이미지 (보정 적용 후). 변할 때마다 Metal 히스토그램 재계산.
struct HistogramOverlay: View {
    let photo: PhotoItem
    var liveImage: NSImage? = nil
    @State private var histogramData: HistogramData?
    @State private var isVisible = true
    /// 드래그 중 연속 호출 디바운스 (last compute time)
    @State private var lastComputeTime: Date = .distantPast

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
            .onAppear { refresh() }
            .onChange(of: photo.id) { _, _ in refresh() }
            .onChange(of: liveImage) { _, _ in refresh(throttled: true) }
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
                .onAppear { refresh() }
                .onChange(of: photo.id) { _, _ in refresh() }
                .onChange(of: liveImage) { _, _ in refresh(throttled: true) }
        }
    }

    /// liveImage 있으면 그것에서, 없으면 원본 파일에서 히스토그램 계산.
    /// throttled=true 면 슬라이더 드래그 중 50ms 최소 간격 (20fps 상한).
    private func refresh(throttled: Bool = false) {
        if throttled {
            let now = Date()
            if now.timeIntervalSince(lastComputeTime) < 0.05 { return }
            lastComputeTime = now
        }
        let url = photo.jpgURL
        let photoID = photo.id
        let imageToUse = liveImage
        DispatchQueue.global(qos: .userInitiated).async {
            let data: HistogramData?
            if let img = imageToUse,
               let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                data = Self.computeHistogramFromCGImage(cgImage)
            } else {
                data = Self.computeHistogram(url: url)
            }
            DispatchQueue.main.async {
                if self.photo.id == photoID {
                    self.histogramData = data
                }
            }
        }
    }

    /// CGImage 기반 히스토그램 — Metal GPU 우선, CPU fallback.
    static func computeHistogramFromCGImage(_ image: CGImage) -> HistogramData? {
        // Metal 경로
        if MetalImageProcessor.isAvailable,
           let gpuHist = MetalImageProcessor.histogram(image: image) {
            return HistogramData(
                red: normalizeHistogram(gpuHist.r),
                green: normalizeHistogram(gpuHist.g),
                blue: normalizeHistogram(gpuHist.b),
                luminance: normalizeHistogram(gpuHist.l)
            )
        }
        // CPU fallback — 300px 로 리사이즈해 속도 확보
        let scale = min(300.0 / CGFloat(image.width), 300.0 / CGFloat(image.height), 1.0)
        let w = max(1, Int(CGFloat(image.width) * scale))
        let h = max(1, Int(CGFloat(image.height) * scale))
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = [Int](repeating: 0, count: 256)
        var g = [Int](repeating: 0, count: 256)
        var b = [Int](repeating: 0, count: 256)
        var l = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let rv = Int(pixels[i]); let gv = Int(pixels[i+1]); let bv = Int(pixels[i+2])
            r[rv] += 1; g[gv] += 1; b[bv] += 1
            l[(rv * 299 + gv * 587 + bv * 114) / 1000] += 1
        }
        return HistogramData(
            red: normalizeHistogram(r),
            green: normalizeHistogram(g),
            blue: normalizeHistogram(b),
            luminance: normalizeHistogram(l)
        )
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
            return HistogramData(
                red: normalizeHistogram(gpuHist.r),
                green: normalizeHistogram(gpuHist.g),
                blue: normalizeHistogram(gpuHist.b),
                luminance: normalizeHistogram(gpuHist.l)
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

        return HistogramData(
            red: normalizeHistogram(r),
            green: normalizeHistogram(g),
            blue: normalizeHistogram(b),
            luminance: normalizeHistogram(l)
        )
    }

    /// 히스토그램 표시용 정규화.
    /// 단일 피크가 전체 그래프를 눌러버리지 않도록 99 percentile + log 압축을 쓴다.
    private static func normalizeHistogram(_ values: [Int]) -> [CGFloat] {
        guard !values.isEmpty else { return [] }
        let sorted = values.sorted()
        let p99Index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * 0.99)))
        let reference = max(sorted[p99Index], 1)
        let denom = log1p(Double(reference))
        return values.map { value in
            let v = min(Double(value), Double(reference))
            return CGFloat(log1p(v) / denom)
        }
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
