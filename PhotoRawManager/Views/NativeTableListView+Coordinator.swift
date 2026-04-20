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
        /// 재로드 중 flag — tableView.reloadData() 가 선택을 초기화하며 발생시키는
        /// tableViewSelectionDidChange 가 store 선택을 덮어쓰는 것을 방지.
        private var isReloading: Bool = false

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
            isReloading = true
            rows = applySorting(to: store.filteredPhotos, descriptors: tv.sortDescriptors)
            tv.reloadData()
            syncSelectionFromStore()
            // reload 직후 selectionDidChange 가 dispatch 될 수 있으므로 next run loop 에서 flag off
            DispatchQueue.main.async { [weak self] in
                self?.isReloading = false
            }
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
            // 재로드 중 이벤트 무시 — reloadData 가 선택을 clear 하며 발생시키는 delegate 호출
            // 이 때 store 선택이 비어버리면 auto-선택된 첫 사진이 날아감.
            guard !isReloading else { return }
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

        // MARK: - Context Menu (PhotoContextMenu 이식)

        /// 현재 선택에 anchor 포함 여부로 대상 결정 (PhotoContextMenu 와 동일 로직).
        private func ctxTargetIDs(anchor: PhotoItem) -> Set<UUID> {
            store.selectedPhotoIDs.contains(anchor.id) ? store.selectedPhotoIDs : [anchor.id]
        }

        func buildContextMenu(forRow row: Int) -> NSMenu? {
            let menu = NSMenu()
            menu.autoenablesItems = false

            // anchor 결정 — 우클릭된 행 우선, 없으면 첫 선택
            let anchor: PhotoItem? = {
                if row >= 0 && row < rows.count { return rows[row] }
                return rows.enumerated().first { tableView?.selectedRowIndexes.contains($0.offset) == true }?.element
            }()
            guard let photo = anchor else {
                let item = NSMenuItem(title: "선택된 파일 없음", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                return menu
            }
            let ids = ctxTargetIDs(anchor: photo)
            let count = ids.count

            // 복사 / 잘라내기 / 붙여넣기
            menu.addItem(mkItem("복사", key: "c", action: #selector(ctxCopy), modifier: [.command]))
            menu.addItem(mkItem("잘라내기", key: "x", action: #selector(ctxCut), modifier: [.command]))
            let paste = mkItem("붙여넣기", key: "v", action: #selector(ctxPaste), modifier: [.command])
            paste.isEnabled = !(NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil)?.isEmpty ?? true)
            menu.addItem(paste)

            menu.addItem(.separator())

            // 새 폴더로 이동
            let moveNewFolder = NSMenuItem(title: "새 폴더로 이동", action: #selector(ctxMoveToNewFolder), keyEquivalent: "")
            moveNewFolder.target = self
            moveNewFolder.image = NSImage(systemSymbolName: "folder.fill.badge.plus", accessibilityDescription: nil)
            menu.addItem(moveNewFolder)

            menu.addItem(.separator())

            // 별점 서브메뉴
            let ratingSub = NSMenu(title: "별점")
            for r in 0...5 {
                let title = r == 0 ? "별점 없음" : String(repeating: "★", count: r)
                let it = NSMenuItem(title: title, action: #selector(ctxSetRating(_:)), keyEquivalent: r == 0 ? "" : "\(r)")
                it.target = self
                it.tag = r
                it.keyEquivalentModifierMask = []
                ratingSub.addItem(it)
            }
            let ratingItem = NSMenuItem(title: "별점", action: nil, keyEquivalent: "")
            ratingItem.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
            ratingItem.submenu = ratingSub
            menu.addItem(ratingItem)

            // 컬러라벨 서브메뉴
            let labelSub = NSMenu(title: "컬러 라벨")
            for (i, label) in ColorLabel.allCases.enumerated() {
                let title = label == .none ? "라벨 해제" : label.rawValue
                let key: String = (label == .none) ? "" : {
                    switch label {
                    case .red: return "6"
                    case .yellow: return "7"
                    case .green: return "8"
                    case .blue: return "9"
                    default: return ""
                    }
                }()
                let it = NSMenuItem(title: title, action: #selector(ctxSetColorLabel(_:)), keyEquivalent: key)
                it.target = self
                it.tag = i
                it.keyEquivalentModifierMask = []
                if let nsColor = label.nsColor {
                    let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                        nsColor.setFill()
                        NSBezierPath(ovalIn: rect).fill()
                        return true
                    }
                    it.image = img
                }
                if photo.colorLabel == label && label != .none { it.state = .on }
                labelSub.addItem(it)
            }
            let labelItem = NSMenuItem(title: "컬러 라벨", action: nil, keyEquivalent: "")
            labelItem.image = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil)
            labelItem.submenu = labelSub
            menu.addItem(labelItem)

            // G Select 토글
            let gTitle = photo.isGSelected ? "G셀렉 해제" : "G셀렉"
            let gItem = NSMenuItem(title: gTitle, action: #selector(ctxToggleGSelect), keyEquivalent: "")
            gItem.target = self
            gItem.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
            menu.addItem(gItem)

            menu.addItem(.separator())

            // 내보내기
            let exportItem = NSMenuItem(title: "내보내기 (\(count)장)",
                                        action: #selector(ctxExport), keyEquivalent: "")
            exportItem.target = self
            exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            menu.addItem(exportItem)

            // RAW → JPG 변환
            let rawConvertItem = NSMenuItem(title: "RAW → JPG 변환 (\(count)장)",
                                            action: #selector(ctxRawToJpg), keyEquivalent: "")
            rawConvertItem.target = self
            rawConvertItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            menu.addItem(rawConvertItem)

            menu.addItem(.separator())

            // 메타데이터 편집
            let metaItem = NSMenuItem(title: "메타데이터 편집 (\(count)장)",
                                      action: #selector(ctxEditMetadata), keyEquivalent: "")
            metaItem.target = self
            metaItem.image = NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil)
            menu.addItem(metaItem)

            // 이름 변경
            let renameItem = NSMenuItem(title: "이름 변경 (\(count)장)",
                                        action: #selector(ctxRename), keyEquivalent: "")
            renameItem.target = self
            renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
            menu.addItem(renameItem)

            // 회전 서브메뉴
            let rotateSub = NSMenu(title: "회전")
            let rot90 = NSMenuItem(title: "90° 시계방향", action: #selector(ctxRotate(_:)), keyEquivalent: "")
            rot90.target = self; rot90.tag = 90
            rotateSub.addItem(rot90)
            let rot180 = NSMenuItem(title: "180°", action: #selector(ctxRotate(_:)), keyEquivalent: "")
            rot180.target = self; rot180.tag = 180
            rotateSub.addItem(rot180)
            let rot270 = NSMenuItem(title: "270° (반시계 90°)", action: #selector(ctxRotate(_:)), keyEquivalent: "")
            rot270.target = self; rot270.tag = 270
            rotateSub.addItem(rot270)
            let rotateItem = NSMenuItem(title: "회전 (\(count)장)", action: nil, keyEquivalent: "")
            rotateItem.image = NSImage(systemSymbolName: "rotate.right", accessibilityDescription: nil)
            rotateItem.submenu = rotateSub
            menu.addItem(rotateItem)

            // Camera Raw 에서 열기
            let cameraRawItem = NSMenuItem(title: "Camera Raw 에서 열기 (\(count)장)",
                                           action: #selector(ctxOpenInCameraRaw), keyEquivalent: "")
            cameraRawItem.target = self
            cameraRawItem.image = NSImage(systemSymbolName: "camera.metering.matrix", accessibilityDescription: nil)
            cameraRawItem.isEnabled = hasAnyRAW(ids: ids, store: store)
            menu.addItem(cameraRawItem)

            menu.addItem(.separator())

            // 파일명 복사
            let copyNameItem = NSMenuItem(title: "파일명 복사", action: #selector(ctxCopyFilename), keyEquivalent: "")
            copyNameItem.target = self
            copyNameItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            menu.addItem(copyNameItem)

            // Finder 에서 보기
            let revealItem = NSMenuItem(title: "Finder 에서 보기", action: #selector(ctxReveal), keyEquivalent: "")
            revealItem.target = self
            revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            revealItem.representedObject = photo.jpgURL
            menu.addItem(revealItem)

            // 기본 앱으로 열기
            let openItem = NSMenuItem(title: "기본 앱으로 열기", action: #selector(ctxOpenDefault), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = photo.jpgURL
            openItem.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            menu.addItem(openItem)

            menu.addItem(.separator())

            // 휴지통으로 이동
            let deleteItem = NSMenuItem(title: "휴지통으로 이동", action: #selector(ctxDelete), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(deleteItem)

            return menu
        }

        private func mkItem(_ title: String, key: String, action: Selector, modifier: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.keyEquivalentModifierMask = modifier
            return item
        }

        // MARK: - Menu Actions

        @objc private func ctxCopy() { copySelectionToPasteboard(store: store) }
        @objc private func ctxCut() { cutSelectionToPasteboard(store: store) }
        @objc private func ctxPaste() { pasteFilesFromPasteboard(store: store) }

        @objc private func ctxDelete() {
            store.requestDeleteOriginal(ids: store.selectedPhotoIDs)
        }

        @objc private func ctxReveal(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        @objc private func ctxOpenDefault(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL {
                NSWorkspace.shared.open(url)
            }
        }

        @objc private func ctxSetRating(_ sender: NSMenuItem) {
            let r = sender.tag
            if store.selectedPhotoIDs.count > 1 {
                store.setRatingForSelected(r)
            } else if let id = store.selectedPhotoID {
                store.setRating(r, for: id)
            }
        }

        @objc private func ctxSetColorLabel(_ sender: NSMenuItem) {
            let idx = sender.tag
            let allCases = ColorLabel.allCases
            guard idx >= 0 && idx < allCases.count else { return }
            let label = allCases[idx]
            if store.selectedPhotoIDs.count > 1 {
                store.setColorLabelForSelected(label)
            } else if let id = store.selectedPhotoID {
                store.setColorLabel(label, for: id)
            }
        }

        @objc private func ctxToggleGSelect() {
            for id in store.selectedPhotoIDs {
                if let idx = store._photoIndex[id] {
                    store.photos[idx].isGSelected.toggle()
                }
            }
        }

        @objc private func ctxExport() {
            store.showExportSheet = true
        }

        @objc private func ctxRawToJpg() {
            store.exportOpenAsRawConvert = true
            store.showExportSheet = true
        }

        @objc private func ctxEditMetadata() {
            let count = store.selectedPhotoIDs.count
            store.metadataEditorMode = count > 1 ? .batch : .single
            store.showMetadataEditor = true
        }

        @objc private func ctxRename() {
            store.showBatchRename = true
        }

        @objc private func ctxRotate(_ sender: NSMenuItem) {
            let deg = sender.tag
            store.batchRotate(ids: store.selectedPhotoIDs, degreesCW: deg)
        }

        @objc private func ctxOpenInCameraRaw() {
            openInCameraRaw(ids: store.selectedPhotoIDs, store: store)
        }

        @objc private func ctxCopyFilename() {
            let names = store.selectedPhotoIDs.compactMap { id -> String? in
                guard let idx = store._photoIndex[id] else { return nil }
                return store.photos[idx].jpgURL.lastPathComponent
            }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names, forType: .string)
            store.showToastMessage("📋 \(store.selectedPhotoIDs.count)개 파일명 복사됨")
        }

        @objc private func ctxMoveToNewFolder() {
            let alert = NSAlert()
            alert.messageText = "새 폴더로 이동"
            alert.informativeText = "폴더 이름을 입력하세요"
            let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            tf.placeholderString = "새 폴더"
            alert.accessoryView = tf
            alert.addButton(withTitle: "이동")
            alert.addButton(withTitle: "취소")
            if alert.runModal() == .alertFirstButtonReturn {
                let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, let folderURL = store.folderURL else { return }
                let newDir = folderURL.appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
                var fileURLs: [URL] = []
                for id in store.selectedPhotoIDs {
                    guard let idx = store._photoIndex[id], idx < store.photos.count else { continue }
                    let p = store.photos[idx]
                    guard !p.isFolder && !p.isParentFolder else { continue }
                    fileURLs.append(p.jpgURL)
                    if let raw = p.rawURL, raw != p.jpgURL { fileURLs.append(raw) }
                }
                store.movePhotosToFolder(fileURLs: fileURLs, destination: newDir)
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
