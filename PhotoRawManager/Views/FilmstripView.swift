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

/// v9.1.2: 스크롤 위치 추적 — 사용자 드래그/마우스휠 스크롤 시 윈도우 슬라이드용.
private struct FilmstripScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct FilmstripView: View {
    @EnvironmentObject var store: PhotoStore
    @AppStorage("filmstripHeight") private var filmstripHeight: Double = 120
    @State private var scrollMonitor: Any?
    @State private var boundsObserver: NSObjectProtocol?
    /// v8.6.2: Filmstrip scrollTo 쓰로틀용 (빠른 이동 시 썸네일 스크롤이 못따라오는 문제 해결)
    @State private var scrollThrottleLastFire: Date = .distantPast
    @State private var scrollTrailingWork: DispatchWorkItem?
    @State private var isResizingFilmstrip = false
    @State private var suppressFilmstripSelectionUntil: Date = .distantPast
    /// v9.1.2: 스크롤 드래그 위치 (0 = 맨 왼쪽). 윈도우 중심 계산 입력.
    @State private var filmstripScrollOffset: CGFloat = 0
    @State private var filmstripVisibleWidth: CGFloat = 800
    /// v9.1.2: selection 변경 시점 추적 — 변경 직후 600ms 동안은 selectedIdx 우선 (useSelected 강제).
    @State private var lastSelectionChangeAt: Date = .distantPast
    /// v9.1.3: 시각 스크롤 위치 — selectedPhotoID 와 분리. nil 이면 selection 따라감.
    ///   다중 선택 시 스크롤은 이 값만 바꾸고 selection 은 건드리지 않음.
    @State private var viewportCenterIdx: Int? = nil

    // v8.7: Finder 로 멀티 파일 드래그 — NSView 오버레이 대신 글로벌 이벤트 모니터 방식.
    //   SwiftUI 의 탭/선택을 방해하지 않으면서 드래그 임계값 초과 시 NSDraggingSession 개시.
    @StateObject private var dragMonitor = FilmstripDragMonitor()

    /// v9.1.3: 슬롯 패턴 필름스트립용 스크롤 휠 → selection 이동.
    ///   기존 NSScrollView 기반 스크롤 로직은 슬롯 패턴엔 맞지 않음 (실제 ScrollView 없음).
    ///   커서가 필름스트립 영역에 있을 때 휠 deltaY → selectedPhotoID 좌우 이동.
    private func setupVerticalToHorizontalScroll() {
        if let existing = scrollMonitor { NSEvent.removeMonitor(existing); scrollMonitor = nil }
        if let observer = boundsObserver {
            NotificationCenter.default.removeObserver(observer)
            boundsObserver = nil
        }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window else { return event }

            // 커서가 필름스트립 영역 안인지 확인.
            // macOS 윈도우 좌표: 좌하단 원점, Y가 위로 증가. 필름스트립은 시각적 하단 = 낮은 Y값.
            // 필름스트립 영역: 0 ≤ pt.y ≤ filmstripHeight + 16 (resize handle 8pt + scrollbar 8pt 여유).
            let pt = event.locationInWindow
            guard pt.y >= 0,
                  pt.y <= CGFloat(self.filmstripHeight) + 24
            else { return event }

            let deltaY = event.scrollingDeltaY
            let deltaX = event.scrollingDeltaX
            // 가로/세로 둘 다 누적 (가로 휠도 지원).
            let primary = abs(deltaX) > abs(deltaY) ? deltaX : -deltaY
            guard abs(primary) > 0.01 else { return nil }

            // 정밀 트랙패드: 누적 픽셀 → 셀 단위(약 80px) 변환. 일반 휠: 한 노치당 1셀.
            let stepPx: CGFloat = event.hasPreciseScrollingDeltas ? 80 : 1
            Self.scrollAccum += event.hasPreciseScrollingDeltas ? primary : (primary > 0 ? stepPx : -stepPx)
            let stepCount = Int(Self.scrollAccum / stepPx)
            guard stepCount != 0 else { return nil }
            Self.scrollAccum -= CGFloat(stepCount) * stepPx

            let allPhotos = self.store.filteredPhotos
            guard !allPhotos.isEmpty else { return nil }
            let selIDs = self.store.selectedPhotoIDs

            // v9.1.3: 다중 선택 활성 → 시각 스크롤만 (viewportCenterIdx) 변경, selection 보존.
            //   단일 선택 → 기존 동작 (스크롤이 selection 이동).
            if selIDs.count > 1 {
                let curViewport = self.viewportCenterIdx ?? self.store.selectedPhotoID.flatMap { id in
                    allPhotos.firstIndex(where: { $0.id == id })
                } ?? 0
                let newViewport = max(0, min(allPhotos.count - 1, curViewport + stepCount))
                if newViewport != curViewport {
                    DispatchQueue.main.async {
                        self.viewportCenterIdx = newViewport
                    }
                }
            } else {
                let curIdx = self.store.selectedPhotoID.flatMap { id in
                    allPhotos.firstIndex(where: { $0.id == id })
                } ?? 0
                let newIdx = max(0, min(allPhotos.count - 1, curIdx + stepCount))
                if newIdx != curIdx {
                    let newID = allPhotos[newIdx].id
                    DispatchQueue.main.async {
                        self.store.selectedPhotoID = newID
                        self.store.selectedPhotoIDs = [newID]
                        self.viewportCenterIdx = nil  // selection 따라감
                    }
                }
            }
            return nil
        }
    }

    /// 휠 누적 (정밀 트랙패드용 — 작은 delta 가 누적되어 셀 1개 이동 트리거).
    private static var scrollAccum: CGFloat = 0

    /// NSClipView 의 postsBoundsChangedNotifications 활성화 (재귀).
    private static func enableBoundsObserving(in view: NSView?) {
        guard let view = view else { return }
        if let clip = view as? NSClipView, let sv = clip.enclosingScrollView,
           let doc = sv.documentView,
           doc.frame.width > clip.bounds.width + 1 && doc.frame.height <= clip.bounds.height + 4 {
            clip.postsBoundsChangedNotifications = true
        }
        for sub in view.subviews { enableBoundsObserving(in: sub) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // v9.1.3: 핸들 시각 두께 6pt (얇게) + hit-buffer 포함 18pt 영역.
            //   셀과의 분리감을 위해 hit area 안에서 핸들은 위쪽에, 아래는 빈공간 (셀과의 간격 역할).
            ZStack {
                Color.clear
                // 시각 핸들 — 사각형, 위쪽에 배치.
                VStack(spacing: 0) {
                    ZStack {
                        Color.gray.opacity(0.4)
                        Rectangle()
                            .fill(Color.gray.opacity(0.75))
                            .frame(width: 50, height: 2)
                    }
                    .frame(height: 6)
                    Spacer(minLength: 0)  // 핸들과 셀 사이 빈공간 (분리감)
                }
            }
            .frame(height: 18)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    beginFilmstripResize()
                    // v9.1.3: 상한 300 → 800 으로 확대 (큰 디스플레이에서 충분한 폭조절).
                    filmstripHeight = max(80, min(800, filmstripHeight - value.translation.height))
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

            // v9.1.2: 풀스크린 패턴 채택 — LazyHStack(17000) ForEach + scrollTo 제거.
            //   슬라이딩 윈도우 (selectedIdx ± 30, 총 ~61장) 만 렌더링.
            //   결과: SwiftUI diff 17000 → 61, scrollTo 부담 0, burst 끊김 없음.
            //   미리보기는 selectedPhotoID 변화에 따라 PhotoPreviewView 가 자동 추적.
            //   캐시 미스는 placeholder (회색) — 디코드 트리거 없음 (필름스트립은 표시만).
            windowedFilmstrip
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
                    if let observer = boundsObserver {
                        NotificationCenter.default.removeObserver(observer)
                        boundsObserver = nil
                    }
                    dragMonitor.uninstall()
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

    /// v9.1.2: 라이트룸 스타일 — 슬롯 고정, 사진 swap. 선택 보더는 항상 중앙 슬롯에서 움직이지 않음.
    ///   슬롯 위치는 화면에 고정 / 각 슬롯의 사진만 currentIdx 기준으로 swap.
    ///   하단에 시각 스크롤바 — 드래그로 선택 변경.
    private var windowedFilmstrip: some View {
        let allPhotos = store.filteredPhotos
        let selIdx = store.selectedPhotoID.flatMap { id in
            allPhotos.firstIndex(where: { $0.id == id })
        } ?? 0
        // v9.1.3: viewportCenterIdx 가 있으면 시각 위치는 그것을 사용 (selection 과 분리).
        //   nil 이면 selection 따라감 — 키 이동/클릭은 자동으로 viewport 동기화.
        let currentIdx = viewportCenterIdx ?? selIdx
        // v9.1.3: 스크롤바 9pt + 위쪽 간격 + 하단 패딩 14pt(스크롤바를 위로 올림).
        //   라벨 영역 32pt (bold 12pt + 별점). 폭은 (cellHeight - 32) * 1.3.
        let scrollbarH: CGFloat = 9
        let scrollbarBottomPad: CGFloat = 14
        let cellH = filmstripHeight - 20
        let cellW = (cellH - 44) * 1.3 + 4

        return GeometryReader { geo in
            let visibleW = geo.size.width
            // 화면 폭 안에 들어가는 슬롯 수 (홀수로 → 중앙 슬롯 명확).
            let rawSlots = max(3, Int(visibleW / cellW))
            let slotCount = rawSlots % 2 == 0 ? rawSlots - 1 : rawSlots
            let centerSlot = slotCount / 2
            // v9.1.3: 라이트룸식 — 시작/끝 근처에선 startIdx clamp 해서 leading/trailing 빈 슬롯 제거.
            //   가운데 영역에선 selected 가 중앙 슬롯에 오도록 유지.
            //   결과: 좌측 큰 빈 공간 사라짐, 셀이 자연스럽게 가장자리부터 채워짐.
            let rawStart = currentIdx - centerSlot
            let maxStart = max(0, allPhotos.count - slotCount)
            let startIdx = max(0, min(rawStart, maxStart))

            VStack(spacing: 6) {
                // v9.1.3: 셀 위쪽 보더 잘림 방지 — 상단 4pt 여유.
                Color.clear.frame(height: 4)

                // 슬롯 — currentIdx 기준 사진 swap. 시작/끝 근처에선 selected 가 중앙 아닌 가장자리쪽으로 이동.
                HStack(spacing: 4) {
                    ForEach(0..<slotCount, id: \.self) { slot in
                        let actualIdx = startIdx + slot
                        if actualIdx >= 0 && actualIdx < allPhotos.count {
                            cellRow(for: allPhotos[actualIdx])
                                .id(allPhotos[actualIdx].id)
                        } else {
                            Color.clear.frame(width: cellW, height: cellH)
                        }
                    }
                }
                .frame(maxWidth: visibleW, alignment: .leading)
                // v9.1.3: 내부 .clipped() 제거 — 셀 보더가 위/아래 잘리던 문제 해결.
                //   가로 오버플로는 외곽 .clipped() 가 처리.

                Spacer(minLength: 0)  // 셀 위쪽으로 몰고 스크롤바 하단으로

                // v9.1.3: 시각 스크롤바 — 18pt 두께 (이전 8pt → 너무 얇아 잡기 힘듦), 하단에 배치.
                //   드래그로 선택 변경. 트랙 클릭으로도 점프 가능.
                if allPhotos.count > 1 {
                    GeometryReader { sbGeo in
                        let trackW = sbGeo.size.width
                        let thumbW = max(60, trackW * CGFloat(slotCount) / CGFloat(allPhotos.count))
                        let progress = CGFloat(currentIdx) / CGFloat(allPhotos.count - 1)
                        let thumbX = (trackW - thumbW) * progress
                        ZStack(alignment: .leading) {
                            // v9.1.3: 사각형으로 통일.
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            let p = max(0, min(1, value.location.x / trackW))
                                            let newIdx = min(allPhotos.count - 1, max(0, Int(p * CGFloat(allPhotos.count - 1))))

                                            if store.selectedPhotoIDs.count > 1 {
                                                viewportCenterIdx = newIdx
                                            } else {
                                                let newID = allPhotos[newIdx].id
                                                if store.selectedPhotoID != newID {
                                                    store.selectedPhotoID = newID
                                                    store.selectedPhotoIDs = [newID]
                                                    viewportCenterIdx = nil
                                                }
                                            }
                                        }
                                )
                            Rectangle()
                                .fill(Color.white.opacity(0.55))
                                .overlay(
                                    Rectangle()
                                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                                )
                                .frame(width: thumbW)
                                .offset(x: thumbX)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: scrollbarH)
                    .padding(.horizontal, 6)
                    .padding(.bottom, scrollbarBottomPad)  // v9.1.3: 스크롤바 하단에서 14pt 위로 올려 잡기 쉬움
                }
            }
            .frame(width: visibleW, height: geo.size.height, alignment: .center)
            .clipped()
            .onAppear { filmstripVisibleWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, newW in filmstripVisibleWidth = newW }
        }
        .clipped()
    }

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
                // v9.1.3: 다중 선택된 셀을 modifier 없이 클릭하면 선택 보존 (드래그 직전 클릭으로 인한 선택 손실 방지).
                //   라이트룸/Finder 표준 동작 — 선택된 항목 클릭은 포커스만 옮김.
                let noMod = !flags.contains(.command) && !flags.contains(.shift)
                if noMod && store.selectedPhotoIDs.count > 1 && store.selectedPhotoIDs.contains(photo.id) {
                    store.selectedPhotoID = photo.id  // 포커스만 이동, 다중 선택 유지
                } else {
                    store.selectPhoto(photo.id, cmdKey: flags.contains(.command), shiftKey: flags.contains(.shift))
                }
            }
            // v9.1.3: 클릭 시 viewport 재동기화 (스크롤로 viewport 가 selection 과 어긋난 경우 복구).
            viewportCenterIdx = nil
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
            let photoCell = base
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

            // 빠른 키 이동 중에는 셀마다 PhotoContextMenu 를 재구성하는 비용이 누적된다.
            // 메뉴는 키를 놓은 뒤 다시 붙여서 우클릭 동작은 유지한다.
            if store.isFastNavigation {
                photoCell
            } else {
                photoCell
                    .contextMenu {
                        PhotoContextMenu(photo: photo, store: store)
                    }
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

    // v9.1.3: 라벨(12pt bold) + 별점 + padding(6*2) + spacing = 44pt 예약. 나머지는 이미지.
    private var labelAreaH: CGFloat { 44 }
    private var imgHeight: CGFloat { max(40, cellHeight - labelAreaH) }
    private var cellWidth: CGFloat { imgHeight * 1.3 }

    private var hasStateBorder: Bool {
        colorLabel != .none || rating > 0
    }
    private var borderColor: Color {
        if colorLabel != .none, let c = colorLabel.color { return c }
        if rating > 0 { return AppTheme.starGold }
        if isFocused { return AppTheme.accent }
        if isSelected { return AppTheme.accent.opacity(0.85) }
        return .clear
    }
    // v9.1.3: 보더 두께 강화 — 선택/포커스가 명확히 보이도록.
    private var borderWidth: CGFloat {
        if colorLabel != .none || rating > 0 { return 4 }
        if isFocused { return 5 }
        if isSelected { return 4 }
        return 0
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                // v9.1.3: 사각형으로 통일 — RoundedRectangle/cornerRadius 제거.
                if photo.isFolder || photo.isParentFolder {
                    ZStack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                        Image(systemName: photo.isParentFolder ? "arrow.up.circle.fill" : "folder.fill")
                            .font(.system(size: imgHeight * 0.45, weight: .regular))
                            .foregroundColor(.blue.opacity(0.85))
                    }
                    .frame(width: cellWidth, height: imgHeight)
                } else {
                    AsyncThumbnailView(url: photo.displayURL)
                        .frame(width: cellWidth, height: imgHeight)
                        .clipped()
                }

                // v9.1.3: SP 뱃지 제거

                // RAW/format badge (top-left) — 사각 배경.
                if photo.hasRAW, let rawURL = photo.rawURL {
                    Text(rawURL.pathExtension.uppercased())
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(AppTheme.rawBadge.opacity(0.85))
                        .padding(3)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                // G select badge — 사각 배경.
                if isGSelected {
                    Text("G")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.9))
                        .padding(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }

            // v9.1.3: 파일명 — 크기 9→12 + bold + 썸네일 폭 안에서 가운데 정렬.
            Text(photo.fileNameWithExtension)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(isSelected ? .white : .white.opacity(0.9))
                .frame(width: cellWidth, alignment: .center)
                .multilineTextAlignment(.center)

            // Star rating — 빈 별 포함해서 항상 5개 표시 (높이 일관성)
            StarDisplayView(rating: rating, size: 7, compact: false)
        }
        // v9.1.3: 보더가 위쪽이 잘려 보이는 문제 해결 — padding 4→6 으로 안쪽 여유 확보 + Rectangle 로 사각형 보더.
        .padding(6)
        .background(
            Rectangle()
                .fill(
                    isFocused ? AppTheme.accent.opacity(0.40) :
                    isSelected ? AppTheme.accent.opacity(0.22) :
                    isHovered ? Color.white.opacity(0.05) :
                    Color.clear
                )
        )
        .overlay(
            // v9.1.3: 사각형 보더 (RoundedRectangle 제거). strokeBorder 로 안쪽 그려서 잘림 방지.
            Rectangle()
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .overlay(
            // 별점/라벨 상태 보더가 있을 때 포커스/선택은 내부 링으로 별도 표시 (사각형).
            Group {
                if hasStateBorder && (isFocused || isSelected) {
                    Rectangle()
                        .strokeBorder(
                            isFocused ? AppTheme.accent : AppTheme.accent.opacity(0.85),
                            lineWidth: isFocused ? 3 : 2.5
                        )
                        .padding(4)
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
