import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// 포커스 피킹 — CIFilter GPU 가속 (실시간)
struct FocusPeakingOverlay: View {
    let image: NSImage
    @State private var overlayImage: NSImage?
    @State private var lastImageID: Int = 0

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        Group {
            if let overlay = overlayImage {
                Image(nsImage: overlay)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.6)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { generate() }
        .onChange(of: image) { _, _ in generate() }
    }

    private func generate() {
        let id = image.hashValue
        guard id != lastImageID else { return }
        lastImageID = id

        DispatchQueue.global(qos: .userInteractive).async {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let ciImage = CIImage(cgImage: cgImage)

            // 1. 축소 (성능)
            let scale = min(1.0, 600.0 / Double(max(cgImage.width, cgImage.height)))
            let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            // 2. Sobel 엣지 감지 (CIEdges — GPU)
            guard let edgeFilter = CIFilter(name: "CIEdges") else { return }
            edgeFilter.setValue(scaled, forKey: kCIInputImageKey)
            edgeFilter.setValue(5.0, forKey: kCIInputIntensityKey)
            guard let edges = edgeFilter.outputImage else { return }

            // 3. 빨간색으로 착색 (CIColorMatrix)
            guard let colorFilter = CIFilter(name: "CIColorMatrix") else { return }
            colorFilter.setValue(edges, forKey: kCIInputImageKey)
            colorFilter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
            colorFilter.setValue(CIVector(x: 0, y: 0.1, z: 0, w: 0), forKey: "inputGVector")
            colorFilter.setValue(CIVector(x: 0, y: 0, z: 0.1, w: 0), forKey: "inputBVector")
            colorFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            guard let colored = colorFilter.outputImage else { return }

            // 4. 렌더링
            let extent = colored.extent
            guard let cgResult = Self.ciContext.createCGImage(colored, from: extent) else { return }
            let result = NSImage(cgImage: cgResult, size: NSSize(width: extent.width, height: extent.height))

            DispatchQueue.main.async {
                overlayImage = result
            }
        }
    }
}
