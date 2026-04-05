import SwiftUI
import CoreImage
import AppKit

/// 가이드 원근 보정 뷰 — 사용자가 2개의 수직 가이드선을 그려서 원근 보정
struct UprightGuideView: View {
    let photo: PhotoItem
    let onApply: (NSImage) -> Void
    @Environment(\.dismiss) private var dismiss

    // 가이드 라인 포인트 (이미지 좌표계 비율 0~1)
    @State private var line1Top = CGPoint(x: 0.3, y: 0.15)
    @State private var line1Bottom = CGPoint(x: 0.3, y: 0.85)
    @State private var line2Top = CGPoint(x: 0.7, y: 0.15)
    @State private var line2Bottom = CGPoint(x: 0.7, y: 0.85)

    @State private var showPreview = false
    @State private var previewImage: NSImage?
    @State private var originalImage: NSImage?
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("가이드 원근 보정")
                    .font(.headline)
                Spacer()
                Toggle("미리보기", isOn: $showPreview)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: showPreview) { newValue in
                        if newValue {
                            generatePreview()
                        }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Photo with guide lines
            GeometryReader { geo in
                let imageSize = originalImage.map { CGSize(width: $0.size.width, height: $0.size.height) } ?? CGSize(width: 400, height: 300)
                let fitted = fitSize(imageSize, in: geo.size)
                let offsetX = (geo.size.width - fitted.width) / 2
                let offsetY = (geo.size.height - fitted.height) / 2

                ZStack {
                    // Background
                    Color.black

                    // Photo
                    if showPreview, let preview = previewImage {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: fitted.width, height: fitted.height)
                    } else if let img = originalImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: fitted.width, height: fitted.height)
                    } else {
                        ProgressView()
                    }

                    // Guide lines (only shown when not previewing)
                    if !showPreview, originalImage != nil {
                        // Line 1
                        guideLine(
                            top: toViewPoint(line1Top, fitted: fitted, offset: CGPoint(x: offsetX, y: offsetY)),
                            bottom: toViewPoint(line1Bottom, fitted: fitted, offset: CGPoint(x: offsetX, y: offsetY)),
                            color: .red
                        )

                        // Line 2
                        guideLine(
                            top: toViewPoint(line2Top, fitted: fitted, offset: CGPoint(x: offsetX, y: offsetY)),
                            bottom: toViewPoint(line2Bottom, fitted: fitted, offset: CGPoint(x: offsetX, y: offsetY)),
                            color: .orange
                        )

                        // Drag handles
                        dragHandle(point: $line1Top, fitted: fitted, offset: CGPoint(x: offsetX, y: offsetY), color: .red)
                        dragHandle(point: $line1Bottom, fitted: fitted, offset: CGPoint(x: offsetX, y: offsetY), color: .red)
                        dragHandle(point: $line2Top, fitted: fitted, offset: CGPoint(x: offsetX, y: offsetY), color: .orange)
                        dragHandle(point: $line2Bottom, fitted: fitted, offset: CGPoint(x: offsetX, y: offsetY), color: .orange)
                    }
                }
            }

            Divider()

            // Footer buttons
            HStack {
                Text("빨간/주황 선을 건물 수직선에 맞추세요")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("취소") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(action: applyCorrection) {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Text("적용")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isProcessing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 700, minHeight: 550)
        .onAppear(perform: loadOriginalImage)
    }

    // MARK: - Guide Line

    private func guideLine(top: CGPoint, bottom: CGPoint, color: Color) -> some View {
        Path { path in
            path.move(to: top)
            path.addLine(to: bottom)
        }
        .stroke(color, lineWidth: 2)
        .allowsHitTesting(false)
    }

    // MARK: - Drag Handle

    private func dragHandle(point: Binding<CGPoint>, fitted: CGSize, offset: CGPoint, color: Color) -> some View {
        let viewPt = toViewPoint(point.wrappedValue, fitted: fitted, offset: offset)
        return Circle()
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(color, lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 2)
            .position(viewPt)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let normalized = toNormalizedPoint(value.location, fitted: fitted, offset: offset)
                        point.wrappedValue = CGPoint(
                            x: max(0, min(1, normalized.x)),
                            y: max(0, min(1, normalized.y))
                        )
                    }
            )
    }

    // MARK: - Coordinate Conversion

    /// 정규화 좌표 (0~1) → 뷰 좌표
    private func toViewPoint(_ normalized: CGPoint, fitted: CGSize, offset: CGPoint) -> CGPoint {
        CGPoint(
            x: offset.x + normalized.x * fitted.width,
            y: offset.y + normalized.y * fitted.height
        )
    }

    /// 뷰 좌표 → 정규화 좌표 (0~1)
    private func toNormalizedPoint(_ viewPt: CGPoint, fitted: CGSize, offset: CGPoint) -> CGPoint {
        CGPoint(
            x: (viewPt.x - offset.x) / fitted.width,
            y: (viewPt.y - offset.y) / fitted.height
        )
    }

    /// 이미지 크기를 뷰에 맞춤 (aspect fit)
    private func fitSize(_ imageSize: CGSize, in viewSize: CGSize) -> CGSize {
        let scaleX = viewSize.width / imageSize.width
        let scaleY = viewSize.height / imageSize.height
        let scale = min(scaleX, scaleY)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    // MARK: - Image Loading

    private func loadOriginalImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = NSImage(contentsOf: photo.jpgURL) else { return }
            DispatchQueue.main.async {
                originalImage = img
            }
        }
    }

    // MARK: - Preview / Apply

    private func generatePreview() {
        guard let nsImage = originalImage,
              let tiffData = nsImage.tiffRepresentation,
              let ciImage = CIImage(data: tiffData) else { return }

        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let imgWidth = ciImage.extent.width
            let imgHeight = ciImage.extent.height

            // 정규화 좌표 → CIImage 좌표 (CIImage는 y가 위로 증가)
            let l1Top = CGPoint(x: line1Top.x * imgWidth, y: (1 - line1Top.y) * imgHeight)
            let l1Bot = CGPoint(x: line1Bottom.x * imgWidth, y: (1 - line1Bottom.y) * imgHeight)
            let l2Top = CGPoint(x: line2Top.x * imgWidth, y: (1 - line2Top.y) * imgHeight)
            let l2Bot = CGPoint(x: line2Bottom.x * imgWidth, y: (1 - line2Bottom.y) * imgHeight)

            let corrected = PerspectiveCorrectionService.guidedUpright(
                image: ciImage,
                line1: (l1Top, l1Bot),
                line2: (l2Top, l2Bot)
            )

            let context = CIContext(options: [.useSoftwareRenderer: false])
            let extent = corrected.extent
            guard !extent.isInfinite, !extent.isEmpty,
                  let cgImage = context.createCGImage(corrected, from: extent) else {
                DispatchQueue.main.async { isProcessing = false }
                return
            }

            let result = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            DispatchQueue.main.async {
                previewImage = result
                isProcessing = false
            }
        }
    }

    private func applyCorrection() {
        guard let nsImage = originalImage,
              let tiffData = nsImage.tiffRepresentation,
              let ciImage = CIImage(data: tiffData) else { return }

        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let imgWidth = ciImage.extent.width
            let imgHeight = ciImage.extent.height

            let l1Top = CGPoint(x: line1Top.x * imgWidth, y: (1 - line1Top.y) * imgHeight)
            let l1Bot = CGPoint(x: line1Bottom.x * imgWidth, y: (1 - line1Bottom.y) * imgHeight)
            let l2Top = CGPoint(x: line2Top.x * imgWidth, y: (1 - line2Top.y) * imgHeight)
            let l2Bot = CGPoint(x: line2Bottom.x * imgWidth, y: (1 - line2Bottom.y) * imgHeight)

            let corrected = PerspectiveCorrectionService.guidedUpright(
                image: ciImage,
                line1: (l1Top, l1Bot),
                line2: (l2Top, l2Bot)
            )

            let context = CIContext(options: [.useSoftwareRenderer: false])
            let extent = corrected.extent
            guard !extent.isInfinite, !extent.isEmpty,
                  let cgImage = context.createCGImage(corrected, from: extent) else {
                DispatchQueue.main.async { isProcessing = false }
                return
            }

            let result = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            DispatchQueue.main.async {
                isProcessing = false
                onApply(result)
                dismiss()
            }
        }
    }
}
