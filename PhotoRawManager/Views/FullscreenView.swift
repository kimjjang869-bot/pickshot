//
//  FullscreenView.swift
//  PhotoRawManager
//
//  Extracted from ContentView+SupportingViews.swift split.
//

import SwiftUI
import AppKit

// MARK: - Fullscreen Photo View (Cmd+F)

struct FullscreenView: View {
    @EnvironmentObject var store: PhotoStore
    @Binding var isPresented: Bool
    @State private var showInfo: Bool = true
    @State private var infoTimer: DispatchWorkItem?

    private var currentPhoto: PhotoItem? {
        guard let id = store.selectedPhotoID,
              let idx = store._photoIndex[id],
              idx < store.photos.count else { return nil }
        return store.photos[idx]
    }

    private var photoCounter: (index: Int, total: Int)? {
        guard let photo = currentPhoto else { return nil }
        let filtered = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        guard let idx = filtered.firstIndex(where: { $0.id == photo.id }) else { return nil }
        return (idx + 1, filtered.count)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 뷰어 엔진 그대로 사용 — 클릭하면 확대/선명하게
            // 별점/컬러라벨 보더는 PhotoPreviewView 내부에서 그림 (중복 방지)
            if let photo = currentPhoto {
                PhotoPreviewView(photo: photo)
            }

            // Top: 파일명 + 카운터 + 닫기
            VStack {
                HStack {
                    Spacer()
                    // v9.1.3: 파일이름 항상 표시 (showInfo 가드 제거) + 카운터 파일명 밑으로.
                    if let photo = currentPhoto {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(photo.jpgURL.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            if let counter = photoCounter {
                                Text("\(counter.index) / \(counter.total)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            if let q = photo.quality, q.isAnalyzed {
                                HStack(spacing: 4) {
                                    Circle().fill(q.overallGrade == .good ? Color.green : q.overallGrade == .average ? Color.orange : Color.red).frame(width: 8, height: 8)
                                    Text("\(q.score)점").font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                                }
                            }
                        }
                        .padding(8).background(Color.black.opacity(0.5)).cornerRadius(6)
                    }
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 24)).foregroundColor(.white.opacity(0.6))
                    }.buttonStyle(.plain).padding(12).help("Esc 또는 Cmd+Enter")
                }
                Spacer()
            }

            // Bottom: 필름스트립만 — fullscreenBottomBar(rating row) 제거.
            // v9.1.3: 필름스트립을 화면 최하단으로 이동 (chrome bar 와 같은 수평선) — 우측 빈공간 활용.
            VStack(spacing: 0) {
                Spacer()
                fullscreenFilmstrip
                    .padding(.bottom, 34)
            }
        }
        .onChange(of: store.selectedPhotoID) { _, _ in flashInfo() }
    }

    // MARK: - Bottom Bar

    private var fullscreenBottomBar: some View {
        HStack(spacing: 0) {
            // v9.1.3: 좌측 카운터 제거 (상단 우측 파일이름 밑으로 이동) — 좌측 빈 공간만 남김.
            Spacer().frame(width: 90)

            Spacer()

            // Star rating buttons + SP button (center)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { rating in
                    Button(action: { setRating(rating) }) {
                        HStack(spacing: 3) {
                            Image(systemName: isRatingActive(rating) ? "star.fill" : "star")
                                .font(.system(size: 14))
                            Text("\(rating)")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(isRatingActive(rating) ? .black : .white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isRatingActive(rating) ? Color.yellow : Color.white.opacity(0.15))
                        )
                    }
                    .buttonStyle(.plain)
                }

                // v9.1.3: SP 버튼 제거
            }

            Spacer()

            // v9.1.3: 우측 hint "⌘↩ 닫기" 제거 — 풀스크린 깔끔하게.
            Spacer().frame(width: 90)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
            .offset(y: -20)
        )
    }

    // MARK: - Filmstrip

    private var fullscreenFilmstrip: some View {
        let photos = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        let currentIdx = photos.firstIndex(where: { $0.id == store.selectedPhotoID }) ?? 0
        let start = max(0, currentIdx - 3)
        let end = min(photos.count - 1, currentIdx + 3)

        return HStack {
            Spacer()
            HStack(spacing: 3) {
                if start <= end {
                    ForEach(start...end, id: \.self) { i in
                        let photo = photos[i]
                        let isCurrent = i == currentIdx
                        // v9.1.3: 별점/컬러라벨 있는 셀에 상태 보더 표시.
                        let stateBorderColor: Color? = {
                            if let c = photo.colorLabel.color { return c }
                            if photo.rating > 0 { return AppTheme.starGold }
                            return nil
                        }()
                        ZStack {
                            if let thumb = ThumbnailCache.shared.get(photo.jpgURL) {
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: isCurrent ? 60 : 50, height: isCurrent ? 45 : 38).clipped()
                            } else {
                                Rectangle().fill(Color.gray.opacity(0.3)).frame(width: isCurrent ? 60 : 50, height: isCurrent ? 45 : 38)
                            }
                        }
                        .cornerRadius(3)
                        .opacity(isCurrent ? 1.0 : 0.5)
                        // 상태 보더 (별점/컬러라벨) — 비선택 셀에도 표시.
                        .overlay(
                            stateBorderColor.map {
                                RoundedRectangle(cornerRadius: 3).stroke($0, lineWidth: 3)
                            }
                        )
                        // 현재 포커스 흰 보더 (위에 덮음).
                        .overlay(isCurrent ? RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 4) : nil)
                        .onTapGesture { store.selectPhoto(photo.id, cmdKey: false) }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.5)).cornerRadius(8)
            .padding(.trailing, 16).padding(.bottom, 4)
        }
    }

    private func isRatingActive(_ rating: Int) -> Bool {
        currentPhoto?.rating == rating
    }

    private func setRating(_ rating: Int) {
        guard let id = store.selectedPhotoID,
              let idx = store._photoIndex[id],
              idx < store.photos.count,
              !store.photos[idx].isFolder else { return }
        store.photos[idx].rating = store.photos[idx].rating == rating ? 0 : rating
    }

    private func flashInfo() {
        showInfo = true
        infoTimer?.cancel()
        let item = DispatchWorkItem { showInfo = false }
        infoTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }
}

// FullscreenKeyHandler 제거 — 같은 윈도우에서 기존 KeyCaptureView가 처리
