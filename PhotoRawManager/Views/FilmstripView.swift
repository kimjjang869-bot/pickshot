import SwiftUI
import UniformTypeIdentifiers

struct FilmstripView: View {
    @EnvironmentObject var store: PhotoStore
    @AppStorage("filmstripHeight") private var filmstripHeight: Double = 120
    @State private var scrollMonitor: Any?

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
                            FilmstripCell(
                                photo: photo,
                                rating: photo.rating,
                                colorLabel: photo.colorLabel,
                                isSpacePicked: photo.isSpacePicked,
                                isGSelected: photo.isGSelected,
                                isSelected: store.isSelected(photo.id),
                                isFocused: store.selectedPhotoID == photo.id,
                                cellHeight: filmstripHeight - 20
                            )
                            .id(photo.id)
                            .onTapGesture {
                                // 단일 탭 (더블클릭은 NSEvent.clickCount로 즉시 분기 — 250ms 지연 회피)
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
                            .contextMenu {
                                filmstripContextMenu(for: photo)
                            }
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
                .onChange(of: store.scrollTrigger) { _ in
                    guard let id = store.selectedPhotoID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: store.selectedPhotoID) { newID in
                    guard let id = newID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Keyboard (썸네일뷰와 동일한 단축키)

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let chars = press.characters

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

    // MARK: - 컨텍스트 메뉴 (썸네일뷰와 동일한 항목들)

    @ViewBuilder
    private func filmstripContextMenu(for photo: PhotoItem) -> some View {
        if !photo.isFolder && !photo.isParentFolder {
            Button("Finder에서 보기") {
                NSWorkspace.shared.activateFileViewerSelecting([photo.jpgURL])
            }
            Divider()
            Menu("별점") {
                ForEach(0...5, id: \.self) { r in
                    Button("\(r)점") { store.setRating(r, for: photo.id) }
                }
            }
            Button(photo.isSpacePicked ? "SP 해제" : "SP 셀렉") {
                store.toggleSpacePick(for: photo.id)
            }
            Divider()
            Button("삭제…", role: .destructive) {
                store.requestDeleteOriginal(ids: [photo.id])
            }
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
                AsyncThumbnailView(url: photo.jpgURL)
                    .frame(width: cellWidth, height: imgHeight)
                    .clipped()
                    .cornerRadius(4)

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

            Text(photo.fileName)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.tail)
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
