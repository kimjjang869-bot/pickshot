import SwiftUI
import AppKit

// MARK: - CALayer 기반 타일 그리드 엔진
// NSCollectionView 대신 직접 렌더링 — 14000장도 60fps 스크롤

struct TileGridView: NSViewRepresentable {
    @EnvironmentObject var store: PhotoStore

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tileView = TileDocumentView()
        tileView.store = store

        scrollView.documentView = tileView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        // 스크롤 감지
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            tileView, selector: #selector(TileDocumentView.scrollChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        context.coordinator.tileView = tileView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tileView = context.coordinator.tileView else { return }
        let photos = store.filteredPhotos
        let size = store.thumbnailSize

        // 데이터 변경 시만 업데이트
        if tileView.photosVersion != store.photosVersion || tileView.thumbSize != size {
            tileView.store = store
            tileView.photos = photos
            tileView.photosVersion = store.photosVersion
            tileView.thumbSize = size
            tileView.recalcLayout()
            tileView.updateVisibleTiles()
        }

        // 선택 변경
        if tileView.selectedID != store.selectedPhotoID {
            tileView.selectedID = store.selectedPhotoID
            tileView.selectedIDs = store.selectedPhotoIDs
            tileView.updateVisibleTiles()
        }

        // 스크롤 트리거
        if tileView.lastScrollTrigger != store.scrollTrigger {
            tileView.lastScrollTrigger = store.scrollTrigger
            tileView.scrollToSelected()
        }

        // 열 수 업데이트
        let gridW = scrollView.frame.width
        if gridW > 0 {
            let cellW = size + 10 + 12
            let cols = max(1, Int(gridW / cellW))
            if store.actualColumnsPerRow != cols {
                store.actualColumnsPerRow = cols
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var tileView: TileDocumentView?
        var scrollView: NSScrollView?
    }
}

// MARK: - 타일 문서 뷰 (직접 CALayer 렌더링)

class TileDocumentView: NSView {
    var store: PhotoStore?
    var photos: [PhotoItem] = []
    var photosVersion: Int = -1
    var thumbSize: CGFloat = 100
    var selectedID: UUID?
    var selectedIDs: Set<UUID> = []
    var lastScrollTrigger: Int = 0

    // 레이아웃 계산값
    private var cols: Int = 4
    private var cellW: CGFloat = 112
    private var cellH: CGFloat = 130
    private var totalHeight: CGFloat = 0
    private let spacing: CGFloat = 12
    private let lineSpacing: CGFloat = 10
    private let inset: CGFloat = 8

    // 타일 캐시 — 재사용
    private var visibleTiles: [Int: TileLayer] = [:]  // index → layer
    private var recyclePool: [TileLayer] = []

    override var isFlipped: Bool { true }

    // MARK: - 레이아웃 계산

    func recalcLayout() {
        let viewW = enclosingScrollView?.frame.width ?? 800
        cellW = thumbSize + 10
        cellH = thumbSize * 0.75 + 50
        cols = max(1, Int((viewW - inset * 2 + spacing) / (cellW + spacing)))
        let rows = (photos.count + cols - 1) / cols
        totalHeight = inset + CGFloat(rows) * (cellH + lineSpacing)
        frame = NSRect(x: 0, y: 0, width: viewW, height: max(totalHeight, enclosingScrollView?.frame.height ?? 600))
    }

    // MARK: - 보이는 타일만 렌더링

    func updateVisibleTiles() {
        guard let scrollView = enclosingScrollView else { return }
        let visibleRect = scrollView.documentVisibleRect
        let startRow = max(0, Int((visibleRect.minY - inset) / (cellH + lineSpacing)))
        let endRow = min((photos.count + cols - 1) / cols, Int((visibleRect.maxY - inset) / (cellH + lineSpacing)) + 1)

        var neededIndices = Set<Int>()
        for row in startRow..<endRow {
            for col in 0..<cols {
                let idx = row * cols + col
                if idx < photos.count { neededIndices.insert(idx) }
            }
        }

        // 화면 밖 타일 회수
        for (idx, tile) in visibleTiles {
            if !neededIndices.contains(idx) {
                tile.removeFromSuperlayer()
                tile.reset()
                recyclePool.append(tile)
                visibleTiles.removeValue(forKey: idx)
            }
        }

        // 필요한 타일 생성/업데이트
        for idx in neededIndices {
            if let tile = visibleTiles[idx] {
                // 선택 상태만 업데이트
                tile.updateSelection(
                    isSelected: selectedIDs.contains(photos[idx].id),
                    isFocused: selectedID == photos[idx].id
                )
            } else {
                // 새 타일 — 재사용 or 생성
                let tile = recyclePool.popLast() ?? TileLayer()
                let photo = photos[idx]
                let row = idx / cols
                let col = idx % cols
                let x = inset + CGFloat(col) * (cellW + spacing)
                let y = inset + CGFloat(row) * (cellH + lineSpacing)

                tile.frame = CGRect(x: x, y: y, width: cellW, height: cellH)
                tile.configure(
                    photo: photo,
                    size: thumbSize,
                    isSelected: selectedIDs.contains(photo.id),
                    isFocused: selectedID == photo.id
                )
                layer?.addSublayer(tile)
                visibleTiles[idx] = tile
            }
        }
    }

    // MARK: - 스크롤 이벤트

    @objc func scrollChanged() {
        updateVisibleTiles()
    }

    // MARK: - 선택된 사진으로 스크롤

    func scrollToSelected() {
        guard let selID = selectedID,
              let idx = photos.firstIndex(where: { $0.id == selID }) else { return }
        let row = idx / cols
        let y = inset + CGFloat(row) * (cellH + lineSpacing)
        enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: max(0, y - 100)))
    }

    // MARK: - 마우스 클릭

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let col = Int((point.x - inset) / (cellW + spacing))
        let row = Int((point.y - inset) / (cellH + lineSpacing))
        let idx = row * cols + col
        guard idx >= 0, idx < photos.count, col >= 0, col < cols else { return }

        let photo = photos[idx]
        guard !photo.isFolder, !photo.isParentFolder else {
            // 폴더 더블클릭 → 열기
            if event.clickCount == 2 {
                store?.loadFolder(photo.jpgURL, restoreRatings: true)
            }
            return
        }

        store?.selectPhoto(photo.id, cmdKey: event.modifierFlags.contains(.command), shiftKey: event.modifierFlags.contains(.shift))
    }

    // MARK: - 뷰 설정

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 타일 레이어 (개별 썸네일 셀)

class TileLayer: CALayer {
    private let imageLayer = CALayer()
    private let textLayer = CATextLayer()
    private let borderLayer = CALayer()
    private var currentURL: URL?
    private var photoID: UUID?

    override init() {
        super.init()
        backgroundColor = NSColor.clear.cgColor

        // 이미지
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        imageLayer.cornerRadius = 4
        imageLayer.masksToBounds = true
        addSublayer(imageLayer)

        // 테두리 (선택 표시)
        borderLayer.borderWidth = 0
        borderLayer.cornerRadius = 4
        addSublayer(borderLayer)

        // 파일명
        textLayer.fontSize = 10
        textLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        textLayer.truncationMode = .end
        addSublayer(textLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    func configure(photo: PhotoItem, size: CGFloat, isSelected: Bool, isFocused: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let imgH = size * 0.75
        imageLayer.frame = CGRect(x: 5, y: 2, width: size, height: imgH)
        borderLayer.frame = imageLayer.frame.insetBy(dx: -2, dy: -2)
        textLayer.frame = CGRect(x: 0, y: imgH + 6, width: bounds.width, height: 14)
        textLayer.string = photo.fileName

        photoID = photo.id
        updateSelection(isSelected: isSelected, isFocused: isFocused)

        // 썸네일 로딩 (독립 스레드)
        let url = photo.jpgURL
        currentURL = url

        if !photo.isFolder && !photo.isParentFolder {
            if let cached = ThumbnailCache.shared.get(url) {
                imageLayer.contents = cached
                imageLayer.backgroundColor = nil
            } else {
                imageLayer.contents = nil
                imageLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
                // 독립 큐에서 로딩 + RunLoop common mode로 전달
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    if let diskCached = DiskThumbnailCache.shared.getByPath(url: url) {
                        ThumbnailCache.shared.set(url, image: diskCached)
                        RunLoop.main.perform(inModes: [.common]) {
                            guard self?.currentURL == url else { return }
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            self?.imageLayer.contents = diskCached
                            self?.imageLayer.backgroundColor = nil
                            CATransaction.commit()
                        }
                        return
                    }
                    ThumbnailLoader.shared.load(url: url) { [weak self] image in
                        RunLoop.main.perform(inModes: [.common]) {
                            guard self?.currentURL == url else { return }
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            self?.imageLayer.contents = image
                            self?.imageLayer.backgroundColor = nil
                            CATransaction.commit()
                        }
                    }
                }
            }
        }

        CATransaction.commit()
    }

    func updateSelection(isSelected: Bool, isFocused: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isFocused {
            borderLayer.borderColor = NSColor(red: 50/255, green: 140/255, blue: 255/255, alpha: 1).cgColor
            borderLayer.borderWidth = 3
        } else if isSelected {
            borderLayer.borderColor = NSColor(red: 80/255, green: 180/255, blue: 255/255, alpha: 1).cgColor
            borderLayer.borderWidth = 2
        } else {
            borderLayer.borderWidth = 0
        }
        CATransaction.commit()
    }

    func reset() {
        currentURL = nil
        photoID = nil
        imageLayer.contents = nil
        imageLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        borderLayer.borderWidth = 0
        textLayer.string = ""
    }
}
