//
//  MultiPreviewGrid.swift
//  PhotoRawManager
//
//  Extracted from ContentView.swift split.
//

import SwiftUI

struct MultiPreviewGrid: View {
    @ObservedObject var store: PhotoStore
    private let maxDisplay = 9

    var body: some View {
        let totalCount = store.selectionCount
        // 최대 9장만 실제 로딩 (2000장 전체를 배열로 안 만듬)
        let allPhotos = store.multiSelectedPhotosLimited(maxDisplay)
        let overflow = totalCount > maxDisplay
        let displayPhotos = overflow ? Array(allPhotos.prefix(maxDisplay - 1)) : allPhotos
        let remainCount = totalCount - displayPhotos.count
        let displayCount = displayPhotos.count + (overflow ? 1 : 0)

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cols = optimalCols(count: displayCount, width: w, height: h)
            let rows = (displayCount + cols - 1) / cols
            let spacing: CGFloat = 3
            let cellW = (w - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let cellH = (h - spacing * CGFloat(rows - 1)) / CGFloat(rows)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellW), spacing: spacing), count: cols), spacing: spacing) {
                ForEach(displayPhotos) { photo in
                    MultiPreviewCell(photo: photo, store: store, cellW: cellW, cellH: cellH)
                        .frame(width: cellW, height: cellH)
                }
                // 초과 시 마지막 칸에 "+N장" 표시
                if overflow {
                    ZStack {
                        store.previewBackgroundColor
                        // 마지막 사진 블러 배경
                        if let lastPhoto = allPhotos.last,
                           let thumb = ThumbnailCache.shared.get(lastPhoto.jpgURL) {
                            Image(nsImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .blur(radius: 8)
                                .clipped()
                        }
                        Color.black.opacity(0.6)
                        Text("+\(remainCount)장")
                            .font(.system(size: min(cellW, cellH) * 0.2, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: cellW, height: cellH)
                    .clipped()
                }
            }
        }
    }

    private func optimalCols(count: Int, width: CGFloat, height: CGFloat) -> Int {
        let aspect: CGFloat = 3.0 / 2.0
        for cols in 1...3 {
            let rows = (count + cols - 1) / cols
            let cellW = width / CGFloat(cols)
            let cellH = height / CGFloat(rows)
            if cellW / cellH <= aspect * 1.5 { return cols }
        }
        return 3
    }
}

struct MultiPreviewCell: View {
    let photo: PhotoItem
    @ObservedObject var store: PhotoStore
    let cellW: CGFloat
    let cellH: CGFloat
    @State private var hiResImage: NSImage?

    var body: some View {
        ZStack {
            store.previewBackgroundColor

            if let hi = hiResImage {
                Image(nsImage: hi)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let thumb = ThumbnailCache.shared.get(photo.jpgURL) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().scaleEffect(0.5)
            }

            // SP
            if photo.isSpacePicked {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.red, lineWidth: 3)
            }

            // 파일명 + 별점
            VStack {
                if photo.rating > 0 {
                    HStack {
                        Spacer()
                        HStack(spacing: 1) {
                            ForEach(1...photo.rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.system(size: 7))
                                    .foregroundColor(AppTheme.starGold)
                            }
                        }
                        .padding(2)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(2)
                        .padding(3)
                    }
                }
                Spacer()
                // v8.6.2: 파일 확장자 포함 + 폰트 크기 확대 (9 → 13) — 다중선택 프리뷰 가독성 개선
                Text(photo.fileNameWithExtension)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(3)
                    .padding(.bottom, 5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onTapGesture {
            store.selectPhoto(photo.id, cmdKey: false)
        }
        .onAppear {
            // 고화질 로딩 (선명하게)
            loadHiRes()
        }
    }

    private func loadHiRes() {
        let url = photo.jpgURL
        // 셀 실제 표시 크기 × Retina 2배 — 최소 1600px 확보해서 선명도 유지
        // (이전 800px 는 Retina 에서 업스케일되어 뭉개짐)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let targetPx = max(1600, Int(max(cellW, cellH) * scale))

        // 전역 PreviewImageCache 에 동일 해상도 키가 있으면 재사용
        let cacheKey = url.appendingPathExtension("r\(targetPx)")
        if let cached = PreviewImageCache.shared.get(cacheKey) {
            hiResImage = cached
            return
        }
        // orig 키(원본) 있으면 그것도 OK — 이미 고화질
        let origKey = url.appendingPathExtension("orig")
        if let cached = PreviewImageCache.shared.get(origKey) {
            hiResImage = cached
            return
        }

        // 백그라운드 로딩 + 캐시 저장
        DispatchQueue.global(qos: .userInitiated).async {
            let img = PreviewImageCache.loadOptimized(url: url, maxPixel: CGFloat(targetPx))
            if let img = img {
                PreviewImageCache.shared.set(cacheKey, image: img)
            }
            DispatchQueue.main.async {
                hiResImage = img
            }
        }
    }
}
