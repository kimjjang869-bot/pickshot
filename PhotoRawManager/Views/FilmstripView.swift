import SwiftUI
import UniformTypeIdentifiers

struct FilmstripView: View {
    @EnvironmentObject var store: PhotoStore
    @AppStorage("filmstripHeight") private var filmstripHeight: Double = 120
    @State private var scrollMonitor: Any?
    /// v8.6.2: Filmstrip scrollTo 쓰로틀용 (빠른 이동 시 썸네일 스크롤이 못따라오는 문제 해결)
    @State private var scrollThrottleLastFire: Date = .distantPast
    @State private var scrollTrailingWork: DispatchWorkItem?

    /// Convert vertical mouse wheel to horizontal scroll in filmstrip
    private func setupVerticalToHorizontalScroll() {
        if let existing = scrollMonitor { NSEvent.removeMonitor(existing); scrollMonitor = nil }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window,
                  let contentView = window.contentView else { return event }
            let pt = event.locationInWindow

            // 커서 아래의 뷰에서 상위로 올라가며 가로 스크롤뷰 탐색
            guard let hit = contentView.hitTest(pt) else { return event }
            var v: NSView? = hit
            var scrollView: NSScrollView? = nil
            while let cur = v {
                if let sv = cur as? NSScrollView {
                    // 가로 문서인지 확인 (documentView가 contentView보다 넓음)
                    let docWidth = sv.documentView?.frame.width ?? 0
                    let docHeight = sv.documentView?.frame.height ?? 0
                    let clipWidth = sv.contentView.bounds.width
                    let clipHeight = sv.contentView.bounds.height
                    if docWidth > clipWidth + 1 && docHeight <= clipHeight + 4 {
                        scrollView = sv
                        break
                    }
                }
                v = cur.superview
            }
            guard let scrollView = scrollView else { return event }

            let deltaY = event.scrollingDeltaY
            let deltaX = event.scrollingDeltaX
            // 트랙패드 가로 스와이프는 그대로 통과
            if abs(deltaX) > abs(deltaY) { return event }
            guard abs(deltaY) > 0.01 else { return event }

            // 휠 위로(deltaY > 0) → 왼쪽 (origin.x 감소)
            // 휠 아래로(deltaY < 0) → 오른쪽 (origin.x 증가)
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 30.0
            let dx = -deltaY * multiplier
            var origin = scrollView.contentView.bounds.origin
            origin.x += dx
            let docWidth = scrollView.documentView?.frame.width ?? scrollView.contentView.bounds.width
            let maxX = max(0, docWidth - scrollView.contentView.bounds.width)
            origin.x = min(max(0, origin.x), maxX)
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return nil  // Consume
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Resize handle
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 4)
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.6))
                        .frame(width: 40, height: 3)
                )
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { value in
                        filmstripHeight = max(80, min(300, filmstripHeight - value.translation.height))
                    }
                )
                .onHover { hovering in
                    if hovering { NSCursor.resizeUpDown.push() }
                    else { NSCursor.pop() }
                }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 4) {
                        ForEach(store.filteredPhotos) { photo in
                            cellRow(for: photo)
                                .id(photo.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(height: filmstripHeight)
                .background(
                    Color(nsColor: .windowBackgroundColor).opacity(0.95)
                        .contentShape(Rectangle())
                        .onTapGesture { store.deselectAll() }
                        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                            handleExternalDrop(providers: providers)
                            return true
                        }
                )
                .scrollIndicators(.visible)
                .focusable()
                .onKeyPress { press in
                    handleKeyPress(press)
                }
                .onAppear { setupVerticalToHorizontalScroll() }
                .onDisappear {
                    if let monitor = scrollMonitor {
                        NSEvent.removeMonitor(monitor)
                        scrollMonitor = nil
                    }
                }
                // v8.6.2: 빠른 이동 시 썸네일 스크롤 못따라옴 해결 — throttle 패턴 + 애니메이션 제거.
                //   이전: withAnimation(0.2) 가 매 키마다 200ms 블록 → 다음 스크롤 지연 누적
                //   지금: 200ms 애니메이션 삭제, throttle 80ms 간격 + trailing 보장
                // v8.6.2: scrollTrigger 기반 — moveSelection (방향키) 에만 증가, 클릭에선 증가 X.
                //   쓰로틀 제거 → 매 키 입력마다 scrollTo 즉시 발동 → 선택이 속도 따라옴.
                //   필름스트립은 LazyHStack 이라 scrollTo 비용 작음 (LazyVGrid 10k 와 달리 빠름).
                .onChange(of: store.scrollTrigger) { _ in
                    guard let id = store.selectedPhotoID else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Cell row (썸네일뷰 PhotoCellWrapper 와 동일한 드래그/드롭/컨텍스트 메뉴)

    @ViewBuilder
    private func cellRow(for photo: PhotoItem) -> some View {
        // 공통 탭 핸들러 — overlay 뒤에 적용해야 NSView MultiFileDragView 와 충돌하지 않음
        let tap = {
            let clickCount = NSApp.currentEvent?.clickCount ?? 1
            if clickCount >= 2, photo.isFolder || photo.isParentFolder {
                store.loadFolder(photo.jpgURL, restoreRatings: true)
                return
            }
            if photo.isFolder || photo.isParentFolder {
                store.selectedPhotoID = photo.id
                store.selectedPhotoIDs = [photo.id]
            } else {
                let flags = NSEvent.modifierFlags
                store.selectPhoto(photo.id, cmdKey: flags.contains(.command), shiftKey: flags.contains(.shift))
            }
        }

        let base = FilmstripCell(
            photo: photo,
            rating: photo.rating,
            colorLabel: photo.colorLabel,
            isSpacePicked: photo.isSpacePicked,
            isGSelected: photo.isGSelected,
            isSelected: store.isSelected(photo.id),
            isFocused: store.selectedPhotoID == photo.id,
            cellHeight: filmstripHeight - 20
        )
        .contentShape(Rectangle())

        if photo.isParentFolder {
            base
                .onTapGesture(perform: tap)
                .contextMenu {
                    Button("Finder에서 열기") {
                        NSWorkspace.shared.open(photo.jpgURL)
                    }
                }
        } else if photo.isFolder {
            // 폴더 셀: onDrag(단일 URL) + onDrop(이 폴더 안으로 이동)
            base
                .onDrag {
                    let provider = NSItemProvider(object: photo.jpgURL as NSURL)
                    provider.suggestedName = photo.jpgURL.lastPathComponent
                    return provider
                }
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    handleDropOnFolder(providers: providers, folderURL: photo.jpgURL)
                    return true
                }
                .onTapGesture(perform: tap)
                .contextMenu {
                    Button("Finder에서 열기") {
                        NSWorkspace.shared.open(photo.jpgURL)
                    }
                    Divider()
                    copyCutPasteMenu(for: photo, store: store)
                    Divider()
                    Button(role: .destructive) {
                        store.requestDeleteOriginal(ids: [photo.id])
                    } label: {
                        Label("휴지통으로 이동", systemImage: "trash")
                    }
                }
        } else {
            // v8.6.2: 일반 사진 셀 — MultiFileDragView NSView 가 클릭을 먹는 문제로 SwiftUI .onDrag 로 교체.
            //   장점: onTapGesture 확실히 동작, 간단
            //   단점: 멀티 파일 드래그 미리보기 이미지는 시스템 기본 (썸네일뷰의 커스텀 미리보기보다 단순)
            //   JPG+RAW 파트너는 NSItemProvider 에 둘 다 포함해서 Finder 로 드래그 시 함께 이동
            base
                .overlay(DropIndicatorOverlay(photoID: photo.id))
                .onTapGesture(perform: tap)
                .onDrag {
                    // 다중 선택 or 단일
                    let ids = store.selectedPhotoIDs.contains(photo.id) ? store.selectedPhotoIDs : [photo.id]
                    var urls: [URL] = []
                    for id in ids {
                        guard let idx = store._photoIndex[id], idx < store.photos.count else { continue }
                        let p = store.photos[idx]
                        guard !p.isFolder && !p.isParentFolder else { continue }
                        urls.append(p.jpgURL)
                        if let raw = p.rawURL, raw != p.jpgURL { urls.append(raw) }
                    }
                    // 우선 첫 URL 을 provider 로 (SwiftUI .onDrag 는 단일 itemProvider 반환)
                    if let first = urls.first {
                        return NSItemProvider(object: first as NSURL)
                    }
                    return NSItemProvider()
                }
                .onDrop(of: [.utf8PlainText], delegate: PhotoReorderDropDelegate(
                    photo: photo, store: store, cellWidth: (filmstripHeight - 20) * 1.3
                ))
                .contextMenu {
                    PhotoContextMenu(photo: photo, store: store)
                }
        }
    }

    /// 폴더 셀에 드롭 받기 — 썸네일뷰와 동일: 드롭된 파일/폴더를 이 폴더 안으로 이동.
    private func handleDropOnFolder(providers: [NSItemProvider], folderURL: URL) {
        let group = DispatchGroup()
        var collected: [URL] = []
        let lock = NSLock()
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock(); collected.append(url); lock.unlock()
                } else if let url = item as? URL {
                    lock.lock(); collected.append(url); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            guard !collected.isEmpty else { return }
            // 자기 자신/자식 폴더로 이동 방지
            let filtered = collected.filter { src in
                guard src != folderURL else { return false }
                return !folderURL.path.hasPrefix(src.path + "/")
            }
            guard !filtered.isEmpty else { return }
            store.movePhotosToFolder(fileURLs: filtered, destination: folderURL)
        }
    }

    // MARK: - Keyboard (썸네일뷰와 동일한 단축키)

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let chars = press.characters
        let mods = press.modifiers

        // ⌘C / ⌘X / ⌘V — 복사 / 잘라내기 / 붙여넣기
        if mods.contains(.command) {
            switch chars.lowercased() {
            case "c": copySelectionToPasteboard(store: store); return .handled
            case "x": cutSelectionToPasteboard(store: store); return .handled
            case "v": pasteFilesFromPasteboard(store: store); return .handled
            default: break
            }
        }

        // 스페이스바: 별 5개 토글 (포커스 사진 기준, 다중 선택 시 일괄)
        if chars == " " {
            if store.selectedPhotoIDs.count > 1 {
                let focusRating = store.selectedPhotoID.flatMap { store.idx($0) }.map { store.photos[$0].rating } ?? 0
                store.setRatingForSelected(focusRating == 5 ? 0 : 5)
            } else if let id = store.selectedPhotoID, let i = store.idx(id) {
                store.setRating(store.photos[i].rating == 5 ? 0 : 5, for: id)
            }
            return .handled
        }

        // 0~5: 별점
        if let ch = chars.first, let rating = Int(String(ch)), rating >= 0 && rating <= 5 {
            if store.selectedPhotoIDs.count > 1 {
                store.setRatingForSelected(rating)
            } else if let id = store.selectedPhotoID {
                store.setRating(rating, for: id)
            }
            return .handled
        }

        // 6~9: 컬러 라벨 (6=빨강, 7=노랑, 8=초록, 9=파랑)
        if let ch = chars.first, let num = Int(String(ch)), num >= 6 && num <= 9 {
            let labelMap: [Int: ColorLabel] = [6: .red, 7: .yellow, 8: .green, 9: .blue]
            if let label = labelMap[num] {
                if store.selectedPhotoIDs.count > 1 {
                    store.setColorLabelForSelected(label)
                } else if let id = store.selectedPhotoID {
                    store.setColorLabel(label, for: id)
                }
            }
            return .handled
        }

        // P: SP 픽 토글
        if chars.lowercased() == "p" {
            if store.selectedPhotoIDs.count > 1 {
                store.toggleSpacePickForSelected()
            } else if let id = store.selectedPhotoID {
                store.toggleSpacePick(for: id)
            }
            return .handled
        }

        // G/X: G셀렉 토글
        if chars.lowercased() == "g" || chars.lowercased() == "x" {
            let ids = store.selectedPhotoIDs.isEmpty
                ? (store.selectedPhotoID.map { [$0] } ?? [])
                : Array(store.selectedPhotoIDs)
            for id in ids {
                if let idx = store._photoIndex[id] {
                    store.photos[idx].isGSelected.toggle()
                }
            }
            return .handled
        }

        // 백스페이스/Delete: 삭제 확인
        if press.key == .delete || press.key == .deleteForward {
            if !store.selectedPhotoIDs.isEmpty {
                store.requestDeleteOriginal(ids: store.selectedPhotoIDs)
            }
            return .handled
        }

        return .ignored
    }

    // MARK: - 외부 드롭 (Finder → 현재 폴더로 복사/이동)

    private func handleExternalDrop(providers: [NSItemProvider]) {
        let moveInstead = NSEvent.modifierFlags.contains(.option)
        let group = DispatchGroup()
        var collected: [URL] = []
        let lock = NSLock()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        lock.lock(); collected.append(url); lock.unlock()
                    } else if let url = item as? URL {
                        lock.lock(); collected.append(url); lock.unlock()
                    }
                }
            }
        }
        group.notify(queue: .main) {
            guard !collected.isEmpty, let dest = store.folderURL else { return }
            for src in collected {
                let target = dest.appendingPathComponent(src.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) { continue }
                if moveInstead {
                    try? FileManager.default.moveItem(at: src, to: target)
                } else {
                    try? FileManager.default.copyItem(at: src, to: target)
                }
            }
            store.loadFolder(dest, restoreRatings: true)
        }
    }

}

struct FilmstripCell: View {
    let photo: PhotoItem
    // 가변 스칼라 필드는 별도 파라미터로 분리 (PhotoItem Equatable이 id만 비교하므로 diff 안 됨)
    let rating: Int
    let colorLabel: ColorLabel
    let isSpacePicked: Bool
    let isGSelected: Bool
    let isSelected: Bool
    var isFocused: Bool = false
    var cellHeight: CGFloat = 100
    @State private var isHovered = false

    private var cellWidth: CGFloat { cellHeight * 1.3 }
    private var imgHeight: CGFloat { cellHeight * 0.7 }

    private var hasStateBorder: Bool {
        isSpacePicked || colorLabel != .none || rating > 0
    }
    private var borderColor: Color {
        if isSpacePicked { return .red }
        if colorLabel != .none, let c = colorLabel.color { return c }
        if rating > 0 { return AppTheme.starGold }
        if isFocused { return AppTheme.accent }
        if isSelected { return AppTheme.accent.opacity(0.7) }
        return .clear
    }
    private var borderWidth: CGFloat {
        if isSpacePicked { return 3 }
        if colorLabel != .none || rating > 0 { return 2.5 }
        if isFocused { return 2.5 }
        if isSelected { return 1.5 }
        return 0
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                // v8.6.2: 폴더/상위폴더 는 시스템 기본 썸네일 대신 SwiftUI 폴더 아이콘 사용 (깨짐 방지)
                if photo.isFolder || photo.isParentFolder {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.1))
                        Image(systemName: photo.isParentFolder ? "arrow.up.circle.fill" : "folder.fill")
                            .font(.system(size: imgHeight * 0.45, weight: .regular))
                            .foregroundColor(.blue.opacity(0.85))
                    }
                    .frame(width: cellWidth, height: imgHeight)
                    .cornerRadius(4)
                } else {
                    AsyncThumbnailView(url: photo.displayURL)
                        .frame(width: cellWidth, height: imgHeight)
                        .clipped()
                        .cornerRadius(4)
                }

                // SP badge (red, prominent)
                if isSpacePicked {
                    Text("SP")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.9))
                        .cornerRadius(3)
                        .padding(3)
                }

                // RAW/format badge (top-left)
                if photo.hasRAW, let rawURL = photo.rawURL {
                    Text(rawURL.pathExtension.uppercased())
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(AppTheme.rawBadge.opacity(0.85))
                        .cornerRadius(2)
                        .padding(3)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                // G select badge
                if isGSelected {
                    Text("G")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.9))
                        .cornerRadius(3)
                        .padding(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }

            // v8.6.2: 확장자 표시 — RAW/JPG 구분
            Text(photo.fileNameWithExtension)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(isSelected ? .white : AppTheme.textSecondary)
                .frame(width: cellWidth)

            // Star rating — 빈 별 포함해서 항상 5개 표시 (높이 일관성)
            StarDisplayView(rating: rating, size: 7, compact: false)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    isFocused ? AppTheme.accent.opacity(0.40) :
                    isSelected ? AppTheme.accent.opacity(0.22) :
                    isHovered ? Color.white.opacity(0.05) :
                    Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .overlay(
            // 별점/라벨/SP 상태 보더가 있을 때 포커스/선택은 내부 링으로 별도 표시
            Group {
                if hasStateBorder && (isFocused || isSelected) {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            isFocused ? AppTheme.accent : AppTheme.accent.opacity(0.85),
                            lineWidth: isFocused ? 2 : 1.5
                        )
                        .padding(3)
                }
            }
        )
        .onHover { isHovered = $0 }
    }
}
