import SwiftUI
import AppKit

/// 픽쳐 스타일 미리보기 및 선택 시트
struct PictureStylePreviewView: View {
    let filename: String
    let rawURL: URL
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedStyleId: String = "camera_original"
    @State private var previews: [String: NSImage] = [:]
    @State private var largePreview: NSImage?
    @State private var isLoading = true
    @State private var loadedCount = 0

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            headerView

            Divider()

            HSplitView {
                // 왼쪽: 스타일 그리드
                styleGridView
                    .frame(minWidth: 340, idealWidth: 400)

                // 오른쪽: 큰 미리보기
                largePreviewView
                    .frame(minWidth: 400, idealWidth: 500)
            }

            Divider()

            // 하단 버튼
            bottomButtons
        }
        .frame(minWidth: 800, minHeight: 600)
        .frame(idealWidth: 900, idealHeight: 700)
        .onAppear { loadPreviews() }
    }

    // MARK: - 헤더

    private var headerView: some View {
        HStack {
            Image(systemName: "camera.filters")
                .font(.title2)
            Text("픽쳐 스타일")
                .font(.headline)
            Spacer()
            Text(filename)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 스타일 그리드

    private var styleGridView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("스타일 미리보기 생성 중... (\(loadedCount)/\(PictureStyleService.styles.count))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }

                ForEach(PictureStyleService.groupedStyles, id: \.0) { category, styles in
                    Section {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(styles) { style in
                                styleCell(style)
                            }
                        }
                    } header: {
                        Text(category)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                    }
                }
            }
            .padding(12)
        }
    }

    private func styleCell(_ style: PictureStyle) -> some View {
        let isSelected = style.id == selectedStyleId

        return VStack(spacing: 4) {
            ZStack {
                if let img = previews[style.id] {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 80)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 80)
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            HStack(spacing: 3) {
                Image(systemName: style.icon)
                    .font(.system(size: 9))
                Text(style.name)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedStyleId = style.id
            loadLargePreview(styleId: style.id)
        }
    }

    // MARK: - 큰 미리보기

    private var largePreviewView: some View {
        VStack(spacing: 8) {
            if let img = largePreview {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(12)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("미리보기 로딩...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(12)
            }

            // 선택된 스타일 이름
            if let style = PictureStyleService.styles.first(where: { $0.id == selectedStyleId }) {
                HStack(spacing: 4) {
                    Image(systemName: style.icon)
                    Text(style.name)
                        .fontWeight(.medium)
                }
                .font(.subheadline)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - 하단 버튼

    private var bottomButtons: some View {
        HStack {
            Button("닫기") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Button("적용") {
                onSelect(selectedStyleId)
                dismiss()
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 미리보기 로딩

    private func loadPreviews() {
        let styles = PictureStyleService.styles
        let url = rawURL

        // 백그라운드에서 모든 스타일 미리보기 생성
        DispatchQueue.global(qos: .userInitiated).async {
            for style in styles {
                autoreleasepool {
                    // 카메라 원본은 임베디드 JPEG 추출, 그 외는 CIRAWFilter 스타일 적용
                    let generated: NSImage?
                    if style.id == "camera_original" {
                        let extracted = PictureStyleService.extractEmbeddedJPEG(from: url)
                        if let original = extracted {
                            let resized = resizeForPreview(original, maxPixel: 300)
                            DispatchQueue.main.async {
                                previews[style.id] = resized
                                loadedCount += 1
                            }
                            return
                        }
                        generated = nil
                    } else {
                        generated = PictureStyleService.previewStyle(style.id, rawURL: url)
                    }

                    // 셀용 작은 이미지로 리사이즈
                    let thumb: NSImage?
                    if let img = generated {
                        thumb = resizeForPreview(img, maxPixel: 300)
                    } else {
                        thumb = nil
                    }

                    DispatchQueue.main.async {
                        previews[style.id] = thumb
                        loadedCount += 1
                        if loadedCount >= styles.count {
                            isLoading = false
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                isLoading = false
            }
        }

        // 기본 선택(카메라 원본) 큰 미리보기 로드
        loadLargePreview(styleId: "camera_original")
    }

    private func loadLargePreview(styleId: String) {
        let url = rawURL
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                let img: NSImage?
                if styleId == "camera_original" {
                    img = PictureStyleService.extractEmbeddedJPEG(from: url)
                } else {
                    img = PictureStyleService.applyStyle(styleId, to: url, maxPixel: 1600)
                }
                DispatchQueue.main.async {
                    largePreview = img
                }
            }
        }
    }

    /// 미리보기용 리사이즈
    private func resizeForPreview(_ image: NSImage, maxPixel: CGFloat) -> NSImage {
        let size = image.size
        let origMax = max(size.width, size.height)
        guard origMax > maxPixel else { return image }
        let scale = maxPixel / origMax
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        return resized
    }
}
