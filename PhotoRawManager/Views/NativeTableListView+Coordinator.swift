import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Coordinator (DataSource / Delegate / DragSource)

extension NativeTableListView {
    final class Coordinator: NSObject,
                              NSTableViewDataSource,
                              NSTableViewDelegate {
        var store: PhotoStore
        weak var tableView: ListTableView?
        weak var scrollView: NSScrollView?

        /// 현재 표시 중인 데이터 스냅샷 (스크롤 성능 확보 + 정렬 결과 저장).
        var rows: [PhotoItem] = []
        /// 마지막으로 반영한 photosVersion — 재로딩 판단.
        private var lastPhotosVersion: Int = -1
        /// 현재 sortDescriptors 서명 — 변화 감지용.
        private var lastSortSignature: String = ""

        init(store: PhotoStore) {
            self.store = store
        }

        // MARK: - Data refresh

        /// SwiftUI updateNSView 에서 호출 — store 변화 감지해서 필요 시 reload.
        func refreshIfNeeded() {
            guard let tv = tableView else { return }
            let newVersion = store.photosVersion
            let newSig = signature(from: tv.sortDescriptors)
            if newVersion != lastPhotosVersion || newSig != lastSortSignature {
                lastPhotosVersion = newVersion
                lastSortSignature = newSig
                reloadData()
            } else if store.selectedPhotoIDs != selectedIDs() {
                // 데이터는 그대로인데 store 쪽 선택이 바뀌면 반영
                syncSelectionFromStore()
            }
        }

        /// 처음 로드 + 전체 재로딩.
        func reloadData() {
            guard let tv = tableView else { return }
            rows = applySorting(to: store.filteredPhotos, descriptors: tv.sortDescriptors)
            tv.reloadData()
            syncSelectionFromStore()
        }

        private func signature(from descriptors: [NSSortDescriptor]) -> String {
            descriptors.map { "\($0.key ?? ""):\($0.ascending)" }.joined(separator: "|")
        }

        /// sortDescriptors 에 따라 정렬 (폴더 상단 고정).
        private func applySorting(to items: [PhotoItem], descriptors: [NSSortDescriptor]) -> [PhotoItem] {
            let folders = items.filter { $0.isFolder || $0.isParentFolder }
            var photos = items.filter { !$0.isFolder && !$0.isParentFolder }
            guard let d = descriptors.first, let key = d.key else {
                return folders + photos
            }
            photos.sort { a, b in
                let result: Bool
                switch key {
                case "name":   result = a.fileNameWithExtension < b.fileNameWithExtension
                case "date":   result = a.fileModDate < b.fileModDate
                case "size":   result = a.totalFileSize < b.totalFileSize
                case "type":   result = a.kindSortKey < b.kindSortKey
                case "rating": result = a.rating < b.rating
                case "resolution": result = a.resolutionSortKey < b.resolutionSortKey
                case "camera": result = a.cameraSortKey < b.cameraSortKey
                case "lens":   result = a.lensSortKey < b.lensSortKey
                default: return false
                }
                return d.ascending ? result : !result
            }
            return folders + photos
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            return rows.count
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            reloadData()
        }

        // MARK: - NSTableViewDelegate — Cell 제공

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < rows.count, let col = tableColumn else { return nil }
            let photo = rows[row]
            let colID = col.identifier.rawValue
            return Self.cellView(for: photo, columnID: colID, store: store)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            return 40
        }

        // MARK: - NSTableViewDelegate — 선택 변화

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tv = tableView else { return }
            let selectedRows = tv.selectedRowIndexes
            let newSelection = Set(selectedRows.compactMap { idx -> UUID? in
                guard idx < rows.count else { return nil }
                return rows[idx].id
            })
            if store.selectedPhotoIDs != newSelection {
                store.selectedPhotoIDs = newSelection
                if let first = newSelection.first { store.selectedPhotoID = first }
                if newSelection.count == 1, let id = newSelection.first {
                    store.selectedPhotoID = id
                }
            }
        }

        private func selectedIDs() -> Set<UUID> {
            guard let tv = tableView else { return [] }
            return Set(tv.selectedRowIndexes.compactMap { idx -> UUID? in
                guard idx < rows.count else { return nil }
                return rows[idx].id
            })
        }

        /// store.selectedPhotoIDs 기반으로 NSTableView 의 선택을 맞춤 (양방향 동기화).
        private func syncSelectionFromStore() {
            guard let tv = tableView else { return }
            let target = store.selectedPhotoIDs
            var indices = IndexSet()
            for (idx, photo) in rows.enumerated() where target.contains(photo.id) {
                indices.insert(idx)
            }
            if tv.selectedRowIndexes != indices {
                tv.selectRowIndexes(indices, byExtendingSelection: false)
            }
        }

        // MARK: - Context Menu

        func buildContextMenu(forRow row: Int) -> NSMenu? {
            let menu = NSMenu()
            let selectedPhotos = rows.enumerated()
                .filter { idx, _ in tableView?.selectedRowIndexes.contains(idx) == true }
                .map { $0.element }
            guard let first = selectedPhotos.first else {
                let item = NSMenuItem(title: "선택된 파일 없음", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                return menu
            }

            // 휴지통으로 이동 (기본 메뉴 — TODO: 다음 단계에서 PhotoContextMenu 호스팅)
            let deleteItem = NSMenuItem(title: "휴지통으로 이동", action: #selector(ctxDelete), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)

            menu.addItem(.separator())

            // Finder 에서 보기
            let revealItem = NSMenuItem(title: "Finder 에서 보기", action: #selector(ctxReveal), keyEquivalent: "")
            revealItem.target = self
            revealItem.representedObject = first.jpgURL
            menu.addItem(revealItem)

            return menu
        }

        @objc private func ctxDelete() {
            store.requestDeleteOriginal(ids: store.selectedPhotoIDs)
        }

        @objc private func ctxReveal(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        // MARK: - Keyboard

        /// NSTableView.keyDown 에서 호출 — 처리됐으면 true 반환.
        func handleKeyDown(event: NSEvent) -> Bool {
            let chars = event.charactersIgnoringModifiers ?? ""
            let hasCmd = event.modifierFlags.contains(.command)

            // Cmd+C/X/V/A
            if hasCmd {
                switch chars.lowercased() {
                case "c":
                    copySelectionToPasteboard(store: store)
                    return true
                case "x":
                    cutSelectionToPasteboard(store: store)
                    return true
                case "v":
                    pasteFilesFromPasteboard(store: store)
                    return true
                case "a":
                    store.selectAll()
                    syncSelectionFromStore()
                    return true
                default: break
                }
            }

            // 스페이스 — 별 5 토글
            if chars == " " {
                if store.selectedPhotoIDs.count > 1 {
                    let focusRating = store.selectedPhotoID.flatMap { store.idx($0) }.map { store.photos[$0].rating } ?? 0
                    store.setRatingForSelected(focusRating == 5 ? 0 : 5)
                } else if let id = store.selectedPhotoID, let i = store.idx(id) {
                    store.setRating(store.photos[i].rating == 5 ? 0 : 5, for: id)
                }
                return true
            }

            // 0~5 별점
            if let ch = chars.first, let rating = Int(String(ch)), rating >= 0 && rating <= 5 {
                if store.selectedPhotoIDs.count > 1 {
                    store.setRatingForSelected(rating)
                } else if let id = store.selectedPhotoID {
                    store.setRating(rating, for: id)
                }
                return true
            }

            // 6~9 컬러라벨
            if let ch = chars.first, let num = Int(String(ch)), num >= 6 && num <= 9 {
                let labelMap: [Int: ColorLabel] = [6: .red, 7: .yellow, 8: .green, 9: .blue]
                if let label = labelMap[num] {
                    if store.selectedPhotoIDs.count > 1 {
                        store.setColorLabelForSelected(label)
                    } else if let id = store.selectedPhotoID {
                        store.setColorLabel(label, for: id)
                    }
                }
                return true
            }

            return false
        }

        // MARK: - Cell View Factory

        /// 셀 뷰 생성 — NSTableCellView 를 서브클래싱하지 않고 그냥 NSView + 서브뷰 직접 배치.
        /// 셀은 재사용되므로 identifier 로 구분.
        static func cellView(for photo: PhotoItem, columnID: String, store: PhotoStore) -> NSView? {
            switch columnID {
            case "name":
                return NameCellView(photo: photo, store: store)
            case "date":
                return TextCellView(text: photo.isFolder ? "--" : Self.dateFormatter.string(from: photo.fileModDate),
                                    alignment: .center, isMonospaced: false)
            case "size":
                return TextCellView(text: photo.isFolder ? "--" : Self.formatSize(photo.totalFileSize),
                                    alignment: .center, isMonospaced: true)
            case "type":
                return TextCellView(text: Self.prettyKind(for: photo),
                                    alignment: .center, isMonospaced: false)
            case "rating":
                return RatingCellView(photo: photo, store: store)
            case "resolution":
                let exif = store.exifFor(photo.id)
                let text: String = {
                    if let w = exif?.imageWidth, let h = exif?.imageHeight { return "\(w)×\(h)" }
                    return ""
                }()
                return TextCellView(text: text, alignment: .center, isMonospaced: true)
            case "camera":
                return TextCellView(text: store.exifFor(photo.id)?.cameraModel ?? "",
                                    alignment: .center, isMonospaced: false)
            case "lens":
                return TextCellView(text: store.exifFor(photo.id)?.lensModel ?? "",
                                    alignment: .center, isMonospaced: false)
            default:
                return nil
            }
        }

        static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f
        }()

        static func formatSize(_ bytes: Int64) -> String {
            if bytes <= 0 { return "--" }
            if bytes > 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
            if bytes > 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }

        static func prettyKind(for photo: PhotoItem) -> String {
            if photo.isParentFolder { return "상위 폴더" }
            if photo.isFolder { return "폴더" }
            let ext = photo.jpgURL.pathExtension.lowercased()
            switch ext {
            case "jpg", "jpeg": return "JPEG 이미지"
            case "png": return "PNG 이미지"
            case "heic": return "HEIC 이미지"
            case "tif", "tiff": return "TIFF 이미지"
            case "arw": return "Sony RAW"
            case "cr2", "cr3": return "Canon RAW"
            case "nef": return "Nikon RAW"
            case "raf": return "Fuji RAW"
            case "orf": return "Olympus RAW"
            case "rw2": return "Panasonic RAW"
            case "pef": return "Pentax RAW"
            case "dng": return "Adobe DNG"
            case "mp4": return "MP4 비디오"
            case "mov": return "QuickTime 비디오"
            case "m4v": return "M4V 비디오"
            default: return ext.uppercased()
            }
        }

        // MARK: - Drag Source (멀티 파일 Finder 드래그)

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < rows.count else { return nil }
            let photo = rows[row]
            if photo.isParentFolder { return nil }
            let pb = NSPasteboardItem()
            pb.setString(photo.jpgURL.absoluteString, forType: .fileURL)
            return pb
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            // 다중 드래그 중 selection 에서 RAW 파트너 추가 — NSTableView 기본은 1 row = 1 file 이지만
            // JPG+RAW 쌍을 함께 드래그하려면 추가 pasteboard items 가 필요.
            //   → session 의 pasteboard 를 직접 확장.
            let pasteboard = session.draggingPasteboard
            var extraItems: [NSPasteboardItem] = []
            for idx in rowIndexes {
                guard idx < rows.count else { continue }
                let photo = rows[idx]
                if let raw = photo.rawURL, raw != photo.jpgURL {
                    let pb = NSPasteboardItem()
                    pb.setString(raw.absoluteString, forType: .fileURL)
                    extraItems.append(pb)
                }
            }
            if !extraItems.isEmpty {
                // pasteboard 는 이미 기존 items 들 포함. writeObjects 로 append.
                pasteboard.writeObjects(extraItems)
            }
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            // 드래그 종료 시 폴더 파일 상태 재검증 → FolderWatcher 가 변화 놓친 케이스 대비.
            // 외부 앱(Finder)이 파일을 move 했으면 source 에서 사라진 파일이 리스트에 남을 수 있음.
            if let folder = store.folderURL {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else { return }
                    self.store.loadFolder(folder, restoreRatings: true)
                    fputs("[ListDrag] session ended op=\(operation.rawValue) → folder reloaded\n", stderr)
                }
            }
        }

    }
}

// MARK: - Cell Views

/// 이름 컬럼: 컬러라벨 바 + 썸네일 + 파일명 + SP/G 배지
final class NameCellView: NSView {
    private let colorBar = NSView()
    private let thumbImageView = NSImageView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let spBadge = NSImageView()
    private let gBadge = NSTextField(labelWithString: "G")

    init(photo: PhotoItem, store: PhotoStore) {
        super.init(frame: .zero)
        setupSubviews()
        configure(photo: photo, store: store)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupSubviews() {
        wantsLayer = true
        colorBar.wantsLayer = true
        colorBar.layer?.cornerRadius = 1.5
        addSubview(colorBar)

        thumbImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbImageView.wantsLayer = true
        thumbImageView.layer?.cornerRadius = 3
        thumbImageView.layer?.masksToBounds = true
        thumbImageView.layer?.borderWidth = 0.5
        thumbImageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        addSubview(thumbImageView)

        filenameLabel.font = .systemFont(ofSize: 12)
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.maximumNumberOfLines = 1
        addSubview(filenameLabel)

        spBadge.image = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)
        spBadge.contentTintColor = .systemRed
        spBadge.imageScaling = .scaleProportionallyDown
        spBadge.isHidden = true
        addSubview(spBadge)

        gBadge.font = .systemFont(ofSize: 8, weight: .heavy)
        gBadge.textColor = .white
        gBadge.alignment = .center
        gBadge.wantsLayer = true
        gBadge.layer?.backgroundColor = NSColor.systemGreen.cgColor
        gBadge.layer?.cornerRadius = 2
        gBadge.isHidden = true
        addSubview(gBadge)
    }

    private func configure(photo: PhotoItem, store: PhotoStore) {
        let live = store.livePhoto(photo.id) ?? photo

        if let nsColor = live.colorLabel.nsColor {
            colorBar.layer?.backgroundColor = nsColor.cgColor
            colorBar.isHidden = false
        } else {
            colorBar.isHidden = true
        }

        // 썸네일
        if photo.isParentFolder {
            thumbImageView.image = NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: nil)
            thumbImageView.contentTintColor = .secondaryLabelColor
        } else if photo.isFolder {
            thumbImageView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            thumbImageView.contentTintColor = .controlAccentColor
        } else {
            thumbImageView.contentTintColor = nil
            // 메모리 → 디스크 순
            if let cached = ThumbnailCache.shared.get(photo.displayURL) {
                thumbImageView.image = cached
            } else {
                thumbImageView.image = nil
                DispatchQueue.global(qos: .userInitiated).async { [weak thumbImageView] in
                    let img = DiskThumbnailCache.shared.getByPath(url: photo.displayURL)
                    DispatchQueue.main.async {
                        if let img = img {
                            ThumbnailCache.shared.set(photo.displayURL, image: img)
                        }
                        thumbImageView?.image = img
                    }
                }
            }
        }

        filenameLabel.stringValue = photo.fileNameWithExtension
        spBadge.isHidden = !live.isSpacePicked
        gBadge.isHidden = !live.isGSelected
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        let h = bounds.height

        colorBar.frame = NSRect(x: pad, y: (h - 20) / 2, width: 3, height: 20)
        thumbImageView.frame = NSRect(x: pad + 3 + 6, y: (h - 34) / 2, width: 50, height: 34)
        let filenameX: CGFloat = pad + 3 + 6 + 50 + 6
        var filenameW: CGFloat = bounds.width - filenameX - pad
        // SP / G 배지가 보이면 오른쪽 공간 예약
        var rightX: CGFloat = bounds.width - pad
        if !spBadge.isHidden {
            spBadge.frame = NSRect(x: rightX - 12, y: (h - 12) / 2, width: 12, height: 12)
            rightX -= 12 + 4
            filenameW -= 12 + 4
        }
        if !gBadge.isHidden {
            gBadge.frame = NSRect(x: rightX - 14, y: (h - 14) / 2, width: 14, height: 14)
            filenameW -= 14 + 4
        }
        filenameLabel.frame = NSRect(x: filenameX, y: (h - 16) / 2, width: max(30, filenameW), height: 16)
    }
}

/// 텍스트 전용 셀 (수정일, 크기, 종류, 해상도, 카메라, 렌즈)
final class TextCellView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String, alignment: NSTextAlignment, isMonospaced: Bool) {
        super.init(frame: .zero)
        label.stringValue = text
        label.font = isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            : NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = alignment
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 6, dy: 0)
    }
}

/// 별점 셀 — 5별 렌더링 (채워진 건 골드, 빈 것은 회색)
final class RatingCellView: NSView {
    private var starViews: [NSImageView] = []

    init(photo: PhotoItem, store: PhotoStore) {
        super.init(frame: .zero)
        for _ in 0..<5 {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyDown
            starViews.append(iv)
            addSubview(iv)
        }
        configure(photo: photo, store: store)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configure(photo: PhotoItem, store: PhotoStore) {
        let rating = store.livePhoto(photo.id)?.rating ?? photo.rating
        let goldColor = NSColor(AppTheme.starGold)
        let dimColor = NSColor.white.withAlphaComponent(0.18)
        let isFolder = photo.isFolder || photo.isParentFolder
        for (i, iv) in starViews.enumerated() {
            if isFolder {
                iv.image = nil
                iv.isHidden = true
                continue
            }
            iv.isHidden = false
            let filled = (i + 1) <= rating
            iv.image = NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: nil)
            iv.contentTintColor = filled ? goldColor : dimColor
        }
    }

    override func layout() {
        super.layout()
        let starSize: CGFloat = 11
        let spacing: CGFloat = 1
        let totalW = starSize * 5 + spacing * 4
        let startX = (bounds.width - totalW) / 2
        let y = (bounds.height - starSize) / 2
        for (i, iv) in starViews.enumerated() {
            iv.frame = NSRect(x: startX + CGFloat(i) * (starSize + spacing), y: y, width: starSize, height: starSize)
        }
    }
}

// MARK: - ColorLabel → NSColor

private extension ColorLabel {
    var nsColor: NSColor? {
        switch self {
        case .none: return nil
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        }
    }
}
