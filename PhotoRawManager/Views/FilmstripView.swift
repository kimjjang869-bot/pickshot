import SwiftUI
import UniformTypeIdentifiers

struct FilmstripView: View {
    @EnvironmentObject var store: PhotoStore
    @AppStorage("filmstripHeight") private var filmstripHeight: Double = 120
    @State private var scrollMonitor: Any?

    /// Convert vertical mouse wheel to horizontal scroll in filmstrip
    private func setupVerticalToHorizontalScroll() {
        if let existing = scrollMonitor { NSEvent.removeMonitor(existing); scrollMonitor = nil }
        let height = filmstripHeight
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only intercept if mouse is in the filmstrip area (bottom of window)
            guard let window = event.window,
                  let contentView = window.contentView else { return event }
            let mouseY = contentView.convert(event.locationInWindow, from: nil).y
            if mouseY < height + 20 {
                let deltaY = event.scrollingDeltaY
                if abs(deltaY) > abs(event.scrollingDeltaX) && abs(deltaY) > 0.5 {
                    // Create a new horizontal scroll event
                    if let cgEvent = event.cgEvent?.copy() {
                        // Swap deltaY → deltaX
                        cgEvent.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: Double(-deltaY))
                        cgEvent.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: 0)
                        if let newEvent = NSEvent(cgEvent: cgEvent) {
                            window.sendEvent(newEvent)
                            return nil  // Consume original
                        }
                    }
                }
            }
            return event
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
                                isSelected: store.isSelected(photo.id),
                                isFocused: store.selectedPhotoID == photo.id,
                                cellHeight: filmstripHeight - 20
                            )
                            .id(photo.id)
                            .onTapGesture(count: 2) {
                                // Double-click: enter folder
                                if photo.isFolder || photo.isParentFolder {
                                    store.loadFolder(photo.jpgURL, restoreRatings: true)
                                }
                            }
                            .onTapGesture(count: 1) {
                                // Single click: select (folders too)
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

        // 스페이스바: SP(셀렉) 토글 — 빨간 테두리
        if chars == " " {
            if store.selectionCount > 1 {
                store.toggleSpacePickForSelected()
            } else if let id = store.selectedPhotoID {
                store.toggleSpacePick(for: id)
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
                let ids = store.selectedPhotoIDs.count > 1 ? store.selectedPhotoIDs : (store.selectedPhotoID.map { [$0] } ?? [])
                for id in ids {
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
    let isSelected: Bool
    var isFocused: Bool = false
    var cellHeight: CGFloat = 100
    @State private var isHovered = false

    private var cellWidth: CGFloat { cellHeight * 1.3 }
    private var imgHeight: CGFloat { cellHeight * 0.7 }

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                AsyncThumbnailView(url: photo.jpgURL)
                    .frame(width: cellWidth, height: imgHeight)
                    .clipped()
                    .cornerRadius(4)

                // SP badge (red, prominent)
                if photo.isSpacePicked {
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
                if photo.isGSelected {
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

            // Star rating
            if photo.rating > 0 {
                HStack(spacing: 0) {
                    Text(String(repeating: "\u{2605}", count: photo.rating))
                        .font(.system(size: 7))
                        .foregroundColor(AppTheme.starFilled)
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    isFocused ? AppTheme.accent.opacity(0.35) :
                    isSelected ? AppTheme.accent.opacity(0.18) :
                    isHovered ? Color.white.opacity(0.05) :
                    Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    photo.isSpacePicked ? Color.red :
                    isFocused ? AppTheme.accent :
                    isSelected ? AppTheme.accent.opacity(0.7) :
                    Color.clear,
                    lineWidth: photo.isSpacePicked ? 3 : (isFocused ? 2.5 : (isSelected ? 1.5 : 0))
                )
        )
        .onHover { isHovered = $0 }
    }
}
