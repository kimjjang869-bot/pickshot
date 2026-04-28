import SwiftUI
import UniformTypeIdentifiers

// MARK: - Cell Frame PreferenceKey (for drag monitor)
private struct FilmstripCellFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct FilmstripResizeHandleFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

struct FilmstripView: View {
    @EnvironmentObject var store: PhotoStore
    @AppStorage("filmstripHeight") private var filmstripHeight: Double = 120
    @State private var scrollMonitor: Any?
    /// v8.6.2: Filmstrip scrollTo 쓰로틀용 (빠른 이동 시 썸네일 스크롤이 못따라오는 문제 해결)
    @State private var scrollThrottleLastFire: Date = .distantPast
    @State private var scrollTrailingWork: DispatchWorkItem?
    @State private var isResizingFilmstrip = false
    @State private var suppressFilmstripSelectionUntil: Date = .distantPast

    // v8.7: Finder 로 멀티 파일 드래그 — NSView 오버레이 대신 글로벌 이벤트 모니터 방식.
    //   SwiftUI 의 탭/선택을 방해하지 않으면서 드래그 임계값 초과 시 NSDraggingSession 개시.
    @StateObject private var dragMonitor = FilmstripDragMonitor()

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
            // v8.9.7+: 단일 resize handle — 8pt 높이 (이전 4pt 너무 얇아 잡기 힘들었음).
            //   별도 24pt overlay 중복 핸들 제거 (cells 와 레이어 충돌 → 폭조절 시 썸네일 선택 버그).
            ZStack {
                Color.gray.opacity(0.3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.6))
                    .frame(width: 40, height: 3)
            }
            .frame(height: 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    beginFilmstripResize()
                    filmstripHeight = max(80, min(300, filmstripHeight - value.translation.height))
                }
                .onEnded { _ in
                    endFilmstripResize()
                }
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: FilmstripResizeHandleFrameKey.self,
                        value: geo.frame(in: .global)
                    )
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
                                .background(
                                    // v8.9.7+: burst 중엔 cellFrames 수집 SKIP — GeometryReader 의 매-selection-변경
                                    //   layout 재계산 + onPreferenceChange 폭주 차단 → 20→30fps+.
                                    //   burst 끝나면 다음 frame 에 자동 재수집.
                                    Group {
                                        if !store.isFastNavigation {
                                            GeometryReader { geo in
                                                Color.clear.preference(
                                                    key: FilmstripCellFrameKey.self,
                                                    value: [photo.id: geo.frame(in: .global)]
                                                )
                                            }
                                        } else {
                                            Color.clear
                                        }
                                    }
                                )
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
                .allowsHitTesting(!isResizingFilmstrip)
                // v8.9.7+: 중복 24pt overlay 드래그 핸들 제거 — cells 위에 레이어돼 폭조절 중 썸네일 선택 충돌 유발.
                //   resize 는 위쪽 8pt 핸들만 사용.
                .scrollIndicators(.visible)
                .focusable()
                .onKeyPress { press in
                    handleKeyPress(press)
                }
                .onAppear {
                    setupVerticalToHorizontalScroll()
                    dragMonitor.install(store: store)
                }
                .onDisappear {
                    if let monitor = scrollMonitor {
                        NSEvent.removeMonitor(monitor)
                        scrollMonitor = nil
                    }
                    dragMonitor.uninstall()
                }
                .onPreferenceChange(FilmstripCellFrameKey.self) { frames in
                    dragMonitor.cellFrames = frames
                }
                // v8.6.2: 빠른 이동 시 썸네일 스크롤 못따라옴 해결 — throttle 패턴 + 애니메이션 제거.
                //   이전: withAnimation(0.2) 가 매 키마다 200ms 블록 → 다음 스크롤 지연 누적
                //   지금: 200ms 애니메이션 삭제, throttle 80ms 간격 + trailing 보장
                // v8.6.2: scrollTrigger 기반 — moveSelection (방향키) 에만 증가, 클릭에선 증가 X.
                //   쓰로틀 제거 → 매 키 입력마다 scrollTo 즉시 발동 → 선택이 속도 따라옴.
                //   필름스트립은 LazyHStack 이라 scrollTo 비용 작음 (LazyVGrid 10k 와 달리 빠름).
                .onChange(of: store.scrollTrigger) { _, _ in
                    guard let id = store.selectedPhotoID else { return }
                    // v8.9.7+: scrollTo 30fps cap — 매 nav 발사 시 LazyHStack 5000장 layout 재계산 누적 → 20fps 정체.
                    //   33ms throttle 로 30fps 보장. trailing fire 로 마지막 위치 보장.
                    let now = Date()
                    if now.timeIntervalSince(scrollThrottleLastFire) >= 0.033 {
                        scrollThrottleLastFire = now
                        proxy.scrollTo(id, anchor: .center)
                        scrollTrailingWork?.cancel()
                    } else {
                        scrollTrailingWork?.cancel()
                        let work = DispatchWorkItem {
                            if let lastID = store.selectedPhotoID {
                                proxy.scrollTo(lastID, anchor: .center)
                                scrollThrottleLastFire = Date()
                            }
                        }
                        scrollTrailingWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                    }
                }
            }
        }
        .onPreferenceChange(FilmstripResizeHandleFrameKey.self) { frame in
            dragMonitor.resizeHandleFrame = frame
        }
    }

    private func beginFilmstripResize() {
        isResizingFilmstrip = true
        dragMonitor.isResizeActive = true
        suppressFilmstripSelectionUntil = .distantFuture
    }

    private func endFilmstripResize() {
        isResizingFilmstrip = false
        dragMonitor.isResizeActive = false
        dragMonitor.resizeEndedAt = Date()
        suppressFilmstripSelectionUntil = Date().addingTimeInterval(0.35)
    }

    // MARK: - Cell row (썸네일뷰 PhotoCellWrapper 와 동일한 드래그/드롭/컨텍스트 메뉴)

    @ViewBuilder
    private func cellRow(for photo: PhotoItem) -> some View {
        // 공통 탭 핸들러 — overlay 뒤에 적용해야 NSView MultiFileDragView 와 충돌하지 않음
        let tap = {
            guard !isResizingFilmstrip,
                  Date() >= suppressFilmstripSelectionUntil else { return }
            let clickCount = NSApp.currentEvent?.clickCount ?? 1
            if clickCount >= 2, photo.isFolder || photo.isParentFolder {
                store.loadFolder(photo.jpgURL, restoreRatings: true)
                return
            }
            // v8.9.7+: 폴더도 단일 클릭 시 cmd/shift modifier 지원 (parentFolder 만 단일 선택).
            let flags = NSEvent.modifierFlags
            if photo.isParentFolder {
                store.selectedPhotoID = photo.id
                store.selectedPhotoIDs = [photo.id]
            } else {
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
                .background(RightClickSelector {
                    // v8.9.7+: 우클릭 시 해당 사진을 선택 — 썸네일뷰/리스트뷰와 동일 UX
                    if !store.selectedPhotoIDs.contains(photo.id) {
                        store.selectPhoto(photo.id, cmdKey: false, shiftKey: false)
                    }
                })
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
            // v8.7: 일반 사진 셀 — SwiftUI .onDrag 제거. 드래그는 FilmstripDragMonitor (글로벌 NSEvent)
            //   에서 처리하여 멀티 파일 동시 Finder 복사 지원. .onDrag 가 있으면 SwiftUI 가 먼저
            //   단일 파일 드래그 세션을 시작해서 multi-item drag 이 불가능.
            //   내부 셀 재정렬(PhotoReorderDropDelegate) 은 유지.
            base
                .overlay(DropIndicatorOverlay(photoID: photo.id))
                .onTapGesture(perform: tap)
                .onDrop(of: [.utf8PlainText], delegate: PhotoReorderDropDelegate(
                    photo: photo, store: store, cellWidth: (filmstripHeight - 20) * 1.3
                ))
                .background(RightClickSelector {
                    // v8.9.7+: 우클릭 시 해당 사진을 선택 — 썸네일뷰/리스트뷰와 동일 UX
                    if !store.selectedPhotoIDs.contains(photo.id) {
                        store.selectPhoto(photo.id, cmdKey: false, shiftKey: false)
                    }
                })
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

// MARK: - Filmstrip Drag Monitor (v8.7)

/// 글로벌 NSEvent monitor 로 필름스트립 드래그를 감지.
/// SwiftUI 의 tap/select 이벤트를 방해하지 않으면서 (이벤트 consume 안 함),
/// 드래그 임계값을 넘으면 NSDraggingSession 을 시작해 멀티 파일 Finder 복사 지원.
final class FilmstripDragMonitor: ObservableObject {
    private var monitor: Any?
    private var downLocation: NSPoint?
    private var downPhotoID: UUID?
    private var didStartDrag = false
    private var suppressUntilMouseUp = false
    private let threshold: CGFloat = 6  // macOS 드래그 임계값 표준 (너무 크면 둔함)
    private weak var store: PhotoStore?

    /// 현재 필름스트립에 표시된 각 셀의 global(screen) frame — PreferenceKey 로 업데이트.
    /// @MainActor 에서 SwiftUI onPreferenceChange 가 세팅.
    var cellFrames: [UUID: CGRect] = [:]
    var resizeHandleFrame: CGRect = .zero
    var isResizeActive = false
    /// v8.9.7+: resize 종료 후 cooldown — 마지막 resize 종료 시점부터 250ms 동안 drag 차단.
    var resizeEndedAt: Date = .distantPast


    func install(store: PhotoStore) {
        self.store = store
        uninstall()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
            return event  // 항상 pass-through — SwiftUI 가 탭/선택을 계속 처리
        }
        fputs("[FilmDrag] monitor installed (store=\(store.photos.count) photos)\n", stderr)
    }

    func uninstall() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit { uninstall() }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // v8.9.7+: resize 활성 또는 종료 후 250ms 안엔 모든 drag 차단.
            let inResizeCooldown = Date().timeIntervalSince(resizeEndedAt) < 0.25
            if isResizeHandleEvent(event) || isResizeActive || inResizeCooldown {
                suppressUntilMouseUp = true
                downLocation = nil
                downPhotoID = nil
                didStartDrag = false
                return
            }
            downLocation = event.locationInWindow
            downPhotoID = photoAt(event: event)
            didStartDrag = false
            fputs("[FilmDrag] mouseDown frames=\(cellFrames.count) hit=\(downPhotoID != nil ? "YES" : "no")\n", stderr)

        case .leftMouseDragged:
            guard !suppressUntilMouseUp, !isResizeActive else { return }
            guard !didStartDrag,
                  let start = downLocation,
                  let id = downPhotoID,
                  let store = store else { return }
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            let dist = hypot(dx, dy)
            guard dist > threshold else { return }
            didStartDrag = true
            fputs("[FilmDrag] 🚀 initiate drag — sel=\(store.selectedPhotoIDs.count) anchor=\(id.uuidString.prefix(8))\n", stderr)
            initiateDrag(event: event, anchorPhotoID: id, store: store)

        case .leftMouseUp:
            suppressUntilMouseUp = false
            downLocation = nil
            downPhotoID = nil
            didStartDrag = false

        default:
            break
        }
    }

    /// mouseDown 위치가 어느 셀 안인지 찾음.
    /// SwiftUI GeometryReader(.global) → top-origin (Y 아래로 증가)
    /// NSEvent window.convertPoint(toScreen:) → AppKit bottom-origin
    /// → Y 축을 뒤집어서 SwiftUI 좌표계에 맞춘 후 hit test.
    private func photoAt(event: NSEvent) -> UUID? {
        guard !isResizeHandleEvent(event) else { return nil }
        guard let hitPoint = swiftUIGlobalPoint(for: event) else { return nil }
        for (id, rect) in cellFrames where rect.contains(hitPoint) {
            return id
        }
        return nil
    }

    private func isResizeHandleEvent(_ event: NSEvent) -> Bool {
        guard !resizeHandleFrame.isEmpty,
              let hitPoint = swiftUIGlobalPoint(for: event) else { return false }
        // 실제 사용자는 4px 핸들보다 조금 위/아래 경계선을 잡고 높이를 조절한다.
        // 이 얇은 경계 영역에서 시작한 드래그가 썸네일 셀 프레임과 겹치면 파일 드래그로 오인되므로
        // 세로 여유를 넓게 둔다. x는 핸들이 전체 폭이라 사실상 전체 필름스트립 폭을 커버한다.
        return resizeHandleFrame.insetBy(dx: -48, dy: -48).contains(hitPoint)
    }

    private func swiftUIGlobalPoint(for event: NSEvent) -> NSPoint? {
        guard let window = event.window else { return nil }
        let appkitScreenPt = window.convertPoint(toScreen: event.locationInWindow)
        // 이벤트가 발생한 스크린 찾기 (멀티 디스플레이 대응)
        let screen = NSScreen.screens.first { $0.frame.contains(appkitScreenPt) } ?? NSScreen.main
        guard let screenFrame = screen?.frame else { return nil }
        // AppKit (bottom-origin) → SwiftUI (top-origin) 변환
        let swiftUIY = screenFrame.origin.y + screenFrame.height - appkitScreenPt.y
        return NSPoint(x: appkitScreenPt.x, y: swiftUIY)
    }

    /// NSDraggingSession 시작 — 선택된 모든 파일 + JPG/RAW 쌍 포함.
    private func initiateDrag(event: NSEvent, anchorPhotoID: UUID, store: PhotoStore) {
        // anchor 가 현재 선택에 없으면 단독 드래그
        let ids: Set<UUID> = store.selectedPhotoIDs.contains(anchorPhotoID)
            ? store.selectedPhotoIDs
            : [anchorPhotoID]

        var urls: [URL] = []
        for id in ids {
            guard let idx = store._photoIndex[id], idx < store.photos.count else { continue }
            let p = store.photos[idx]
            if p.isParentFolder { continue }
            if p.isFolder {
                urls.append(p.jpgURL)
            } else {
                urls.append(p.jpgURL)
                if let raw = p.rawURL, raw != p.jpgURL { urls.append(raw) }
            }
        }
        guard !urls.isEmpty else { return }

        // 드래그 프리뷰 기본 frame — 마우스 커서 기준으로 오프셋 적용.
        //   프레임 origin(0,0) 이면 커서가 프리뷰의 좌상단 기준이 되어 시각적으로 어색함.
        //   커서가 이미지의 중앙 오른쪽 하단 약간 아래에 오도록 -side/2 , -side/2 오프셋.
        let side: CGFloat = 80
        let defaultFrame = NSRect(x: -side / 2, y: -side / 2, width: side, height: side)

        // anchor 셀의 썸네일로 첫 번째 아이템 프리뷰 구성
        var previewImage: NSImage? = nil
        if let anchorIdx = store._photoIndex[anchorPhotoID],
           anchorIdx < store.photos.count {
            let anchor = store.photos[anchorIdx]
            let thumb =
                DiskThumbnailCache.shared.getByPath(url: anchor.jpgURL)
                ?? ThumbnailCache.shared.get(anchor.jpgURL)
            if let image = thumb {
                let resized = NSImage(size: NSSize(width: side, height: side))
                resized.lockFocus()
                NSGraphicsContext.current?.imageInterpolation = .high
                let r = min(side / image.size.width, side / image.size.height)
                let w = image.size.width * r
                let h = image.size.height * r
                image.draw(in: NSRect(x: (side - w)/2, y: (side - h)/2, width: w, height: h))
                if ids.count > 1 {
                    let badge = "\(ids.count)" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                        .foregroundColor: NSColor.white
                    ]
                    let bsize = badge.size(withAttributes: attrs)
                    let bW = max(20, bsize.width + 8)
                    let bRect = NSRect(x: side - bW - 2, y: side - 18, width: bW, height: 16)
                    NSColor.systemBlue.setFill()
                    NSBezierPath(roundedRect: bRect, xRadius: 8, yRadius: 8).fill()
                    badge.draw(at: NSPoint(x: bRect.midX - bsize.width/2, y: bRect.midY - bsize.height/2),
                               withAttributes: attrs)
                }
                resized.unlockFocus()
                previewImage = resized
            }
        }

        var items: [NSDraggingItem] = []
        for (i, url) in urls.enumerated() {
            let pb = NSPasteboardItem()
            pb.setString(url.absoluteString, forType: .fileURL)
            let di = NSDraggingItem(pasteboardWriter: pb)
            // 첫 번째 아이템만 썸네일 표시, 나머지는 투명 (Finder 기본 스택 효과와 유사)
            if i == 0 {
                di.setDraggingFrame(defaultFrame, contents: previewImage)
            } else {
                di.setDraggingFrame(defaultFrame, contents: nil)
            }
            items.append(di)
        }

        guard let contentView = event.window?.contentView else { return }
        _ = contentView.beginDraggingSession(with: items, event: event, source: FilmstripDragSource.shared)
    }
}

/// NSDraggingSource singleton — 외부앱(Finder)에선 copy, 내부 드롭은 move 허용.
final class FilmstripDragSource: NSObject, NSDraggingSource {
    static let shared = FilmstripDragSource()
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : .move
    }
}
