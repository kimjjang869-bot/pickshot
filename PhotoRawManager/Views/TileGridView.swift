import SwiftUI
import AppKit

// MARK: - CALayer 타일 그리드 엔진 v2
// 14000장 60fps 목표 — NSCollectionView 완전 대체

struct TileGridView: NSViewRepresentable {
    @EnvironmentObject var store: PhotoStore

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tileView = TileDocumentView()
        tileView.store = store
        tileView.photos = store.filteredPhotos
        tileView.photosVersion = store.photosVersion

        scrollView.documentView = tileView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            tileView, selector: #selector(TileDocumentView.scrollChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        context.coordinator.tileView = tileView
        context.coordinator.scrollView = scrollView

        // 초기 레이아웃
        DispatchQueue.main.async {
            tileView.viewWidth = scrollView.frame.width
            tileView.recalcLayout()
            tileView.updateVisibleTiles()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tileView = context.coordinator.tileView else { return }
        let viewWidth = scrollView.frame.width

        // 데이터 변경 — photosVersion으로만 판단 (filteredPhotos 중복 호출 방지)
        let dataChanged = tileView.photosVersion != store.photosVersion
        let sizeChanged = tileView.thumbSize != store.thumbnailSize
        let widthChanged = abs(tileView.viewWidth - viewWidth) > 1

        if dataChanged {
            tileView.photos = store.filteredPhotos
            tileView.photosVersion = store.photosVersion
        }

        if dataChanged || sizeChanged || widthChanged {
            tileView.store = store
            tileView.thumbSize = store.thumbnailSize
            tileView.viewWidth = viewWidth
            tileView.recalcLayout()
            tileView.updateVisibleTiles()

            // 열 수 업데이트
            if store.actualColumnsPerRow != tileView.cols {
                store.actualColumnsPerRow = tileView.cols
            }
        }

        // 선택 변경 — 가벼운 업데이트만
        let selChanged = tileView.selectedID != store.selectedPhotoID ||
                         tileView.selectedIDs != store.selectedPhotoIDs
        if selChanged {
            tileView.selectedID = store.selectedPhotoID
            tileView.selectedIDs = store.selectedPhotoIDs
            tileView.updateSelectionOnly()
        }

        // 스크롤 트리거
        if tileView.lastScrollTrigger != store.scrollTrigger {
            tileView.lastScrollTrigger = store.scrollTrigger
            tileView.scrollToSelected()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator {
        var tileView: TileDocumentView?
        var scrollView: NSScrollView?
    }
}

// MARK: - 타일 문서 뷰

class TileDocumentView: NSView {
    var store: PhotoStore?
    var photos: [PhotoItem] = []
    var photosVersion: Int = -1
    var thumbSize: CGFloat = 100
    var selectedID: UUID?
    var selectedIDs: Set<UUID> = []
    var lastScrollTrigger: Int = 0
    var viewWidth: CGFloat = 800

    // 레이아웃
    var cols: Int = 4
    private var cellW: CGFloat = 112
    private var cellH: CGFloat = 130
    private var totalHeight: CGFloat = 0
    private let spacing: CGFloat = 12
    private let lineSpacing: CGFloat = 10
    private let inset: CGFloat = 8

    // 타일 관리
    private var visibleTiles: [Int: TileLayer] = [:]
    private var recyclePool: [TileLayer] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 레이아웃

    func recalcLayout() {
        let w = viewWidth > 100 ? viewWidth : 800
        cellW = thumbSize + 10
        cellH = thumbSize * 0.75 + 50
        cols = max(1, Int((w - inset * 2 + spacing) / (cellW + spacing)))
        let rows = (photos.count + cols - 1) / cols
        totalHeight = inset + CGFloat(rows) * (cellH + lineSpacing) + 50
        let scrollH = enclosingScrollView?.frame.height ?? 600
        frame = NSRect(x: 0, y: 0, width: w, height: max(totalHeight, scrollH))
    }

    // MARK: - 보이는 타일만 렌더링

    func updateVisibleTiles() {
        guard let scrollView = enclosingScrollView else { return }
        let visibleRect = scrollView.documentVisibleRect

        let startRow = max(0, Int((visibleRect.minY - inset) / (cellH + lineSpacing)) - 1)
        let endRow = min((photos.count + cols - 1) / cols, Int((visibleRect.maxY - inset) / (cellH + lineSpacing)) + 2)

        var neededIndices = Set<Int>()
        for row in startRow..<endRow {
            for col in 0..<cols {
                let idx = row * cols + col
                if idx >= 0 && idx < photos.count { neededIndices.insert(idx) }
            }
        }

        // 화면 밖 타일 회수
        for (idx, tile) in visibleTiles where !neededIndices.contains(idx) {
            tile.removeFromSuperlayer()
            tile.reset()
            recyclePool.append(tile)
            visibleTiles.removeValue(forKey: idx)
        }

        // 타일 생성/업데이트
        for idx in neededIndices {
            let photo = photos[idx]
            let row = idx / cols
            let col = idx % cols
            let x = inset + CGFloat(col) * (cellW + spacing)
            let y = inset + CGFloat(row) * (cellH + lineSpacing)
            let tileFrame = CGRect(x: x, y: y, width: cellW, height: cellH)

            if let tile = visibleTiles[idx] {
                // 위치만 업데이트
                if tile.frame != tileFrame {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    tile.frame = tileFrame
                    CATransaction.commit()
                }
                tile.updateSelection(
                    isSelected: selectedIDs.contains(photo.id),
                    isFocused: selectedID == photo.id
                )
            } else {
                // 새 타일
                let tile = recyclePool.popLast() ?? TileLayer()
                tile.frame = tileFrame
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

    /// 선택만 업데이트 (타일 재생성 없음)
    func updateSelectionOnly() {
        for (idx, tile) in visibleTiles {
            guard idx < photos.count else { continue }
            let photo = photos[idx]
            tile.updateSelection(
                isSelected: selectedIDs.contains(photo.id),
                isFocused: selectedID == photo.id
            )
        }
    }

    // MARK: - 스크롤

    @objc func scrollChanged() {
        updateVisibleTiles()
    }

    func scrollToSelected() {
        guard let selID = selectedID,
              let idx = photos.firstIndex(where: { $0.id == selID }),
              let scrollView = enclosingScrollView else { return }

        let row = idx / cols
        let y = inset + CGFloat(row) * (cellH + lineSpacing)
        let visibleH = scrollView.documentVisibleRect.height
        let currentY = scrollView.documentVisibleRect.minY

        // 선택이 보이는 범위 밖이면 스크롤
        if y < currentY + 20 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y - 20)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if y + cellH > currentY + visibleH - 20 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y + cellH - visibleH + 20)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - 마우스

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let idx = indexAtPoint(point), idx < photos.count else {
            store?.deselectAll()
            return
        }
        let photo = photos[idx]

        if photo.isParentFolder || photo.isFolder {
            if event.clickCount == 2 {
                store?.loadFolder(photo.jpgURL, restoreRatings: true)
            }
            return
        }

        store?.selectPhoto(
            photo.id,
            cmdKey: event.modifierFlags.contains(.command),
            shiftKey: event.modifierFlags.contains(.shift)
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let idx = indexAtPoint(point), idx < photos.count else { return }
        let photo = photos[idx]
        guard !photo.isFolder, !photo.isParentFolder else { return }

        // 우클릭한 사진이 선택 안 됐으면 먼저 선택
        if !(store?.selectedPhotoIDs.contains(photo.id) ?? false) {
            store?.selectPhoto(photo.id, cmdKey: false)
        }

        // 컨텍스트 메뉴 — NSMenu
        let menu = NSMenu()
        // 별점
        for r in 0...5 {
            let item = NSMenuItem(title: r == 0 ? "별점 초기화" : "★ \(r)", action: #selector(setRating(_:)), keyEquivalent: "")
            item.tag = r
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // SP
        let sp = NSMenuItem(title: "SP 토글", action: #selector(toggleSP), keyEquivalent: "")
        sp.target = self
        menu.addItem(sp)
        menu.addItem(.separator())
        // Finder에서 열기
        let finder = NSMenuItem(title: "Finder에서 열기", action: #selector(openInFinder), keyEquivalent: "")
        finder.target = self
        menu.addItem(finder)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func setRating(_ sender: NSMenuItem) {
        guard let store = store else { return }
        for id in store.selectedPhotoIDs {
            store.setRating(sender.tag, for: id)
        }
    }

    @objc private func toggleSP() {
        guard let store = store, let id = store.selectedPhotoID else { return }
        store.toggleSpacePick(for: id)
    }

    @objc private func openInFinder() {
        guard let store = store, let photo = store.selectedPhoto else { return }
        NSWorkspace.shared.activateFileViewerSelecting([photo.jpgURL])
    }

    // MARK: - 인덱스 계산

    private func indexAtPoint(_ point: CGPoint) -> Int? {
        let col = Int((point.x - inset) / (cellW + spacing))
        let row = Int((point.y - inset) / (cellH + lineSpacing))
        guard col >= 0, col < cols, row >= 0 else { return nil }
        let idx = row * cols + col
        return idx >= 0 && idx < photos.count ? idx : nil
    }

    // MARK: - 초기화

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 타일 레이어

class TileLayer: CALayer {
    private let imageLayer = CALayer()
    private let textLayer = CATextLayer()
    private let borderLayer = CALayer()
    private let badgeLayer = CATextLayer()
    private var currentURL: URL?

    override init() {
        super.init()
        backgroundColor = NSColor.clear.cgColor
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        imageLayer.cornerRadius = 4
        imageLayer.masksToBounds = true
        imageLayer.contentsScale = scale
        addSublayer(imageLayer)

        borderLayer.borderWidth = 0
        borderLayer.cornerRadius = 6
        addSublayer(borderLayer)

        textLayer.fontSize = 10
        textLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = scale
        textLayer.truncationMode = .end
        addSublayer(textLayer)

        badgeLayer.fontSize = 8
        badgeLayer.foregroundColor = NSColor.white.cgColor
        badgeLayer.alignmentMode = .center
        badgeLayer.contentsScale = scale
        badgeLayer.cornerRadius = 3
        badgeLayer.masksToBounds = true
        badgeLayer.isHidden = true
        addSublayer(badgeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }
    override init(layer: Any) { super.init(layer: layer) }

    func configure(photo: PhotoItem, size: CGFloat, isSelected: Bool, isFocused: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let imgH = size * 0.75
        imageLayer.frame = CGRect(x: 5, y: 2, width: size, height: imgH)
        borderLayer.frame = imageLayer.frame.insetBy(dx: -2, dy: -2)
        textLayer.frame = CGRect(x: 0, y: imgH + 4, width: bounds.width, height: 14)
        textLayer.string = photo.fileName

        // 뱃지 (R+J, JPG, CR3 등)
        if !photo.isFolder && !photo.isParentFolder {
            let (badgeText, badgeColor) = photo.fileTypeBadge
            badgeLayer.string = badgeText
            badgeLayer.backgroundColor = badgeColor == "green" ? NSColor.systemGreen.cgColor :
                                         badgeColor == "blue" ? NSColor.systemBlue.cgColor :
                                         badgeColor == "orange" ? NSColor.systemOrange.cgColor :
                                         NSColor.systemGray.cgColor
            badgeLayer.frame = CGRect(x: size - 30, y: 4, width: 32, height: 16)
            badgeLayer.isHidden = false
        } else {
            badgeLayer.isHidden = true
        }

        updateSelection(isSelected: isSelected, isFocused: isFocused)

        // 썸네일 로딩
        let url = photo.jpgURL
        currentURL = url

        if photo.isFolder || photo.isParentFolder {
            imageLayer.contents = NSImage(systemSymbolName: photo.isParentFolder ? "arrow.up.circle.fill" : "folder.fill", accessibilityDescription: nil)
            imageLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.08).cgColor
        } else if let cached = ThumbnailCache.shared.get(url) {
            imageLayer.contents = cached
            imageLayer.backgroundColor = nil
        } else {
            imageLayer.contents = nil
            imageLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
            // 독립 스레드 + RunLoop.common
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                if let disk = DiskThumbnailCache.shared.getByPath(url: url) {
                    ThumbnailCache.shared.set(url, image: disk)
                    RunLoop.main.perform(inModes: [.common]) {
                        guard self?.currentURL == url else { return }
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self?.imageLayer.contents = disk
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

        CATransaction.commit()
    }

    func updateSelection(isSelected: Bool, isFocused: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isFocused {
            borderLayer.borderColor = NSColor(red: 50/255, green: 140/255, blue: 1, alpha: 1).cgColor
            borderLayer.borderWidth = 3
        } else if isSelected {
            borderLayer.borderColor = NSColor(red: 80/255, green: 180/255, blue: 1, alpha: 1).cgColor
            borderLayer.borderWidth = 2
        } else {
            borderLayer.borderWidth = 0
        }
        CATransaction.commit()
    }

    func reset() {
        currentURL = nil
        imageLayer.contents = nil
        imageLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        borderLayer.borderWidth = 0
        textLayer.string = ""
        badgeLayer.isHidden = true
    }
}
