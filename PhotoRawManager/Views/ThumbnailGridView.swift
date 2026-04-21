import SwiftUI
import UniformTypeIdentifiers
import CoreImage
import Combine

// MARK: - 드래그 드롭 상태 (PhotoStore와 분리 — 성능 최적화)
class DragDropState: ObservableObject {
    static let shared = DragDropState()
    @Published var dropTargetID: UUID? = nil
    @Published var dropLeading: Bool = true
}

private struct GridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ThumbnailGridView: View {
    @EnvironmentObject var store: PhotoStore
    /// v8.6.2: 키 꾹 누르기 중 proxy.scrollTo 쓰로틀 (debounce 아님)
    ///   최소 100ms 간격으로 '반드시' 발동 — debounce 는 연속 입력 중 끝까지 실행 안 되는 문제로
    ///   스크롤이 따라가지 못함.
    @State private var scrollThrottleLastFire: Date = .distantPast
    @State private var scrollTrailingWork: DispatchWorkItem?

    var body: some View {
        GeometryReader { geo in
            Group {
            let _ = updateColumns(width: geo.size.width)
            if store.filteredPhotos.isEmpty {
                emptyStateView
                    .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                        handleExternalDrop(providers: providers)
                        return true
                    }
            } else {
                // SwiftUI LazyVGrid / List (안정적 + 메모리 캐시 8GB)
                //   v8.7: useNativeGrid UserDefaults true → AppKit NSCollectionView 사용 (10배 빠름)
                VStack(spacing: 0) {
                    if store.viewMode == .list {
                        // v8.7: NSTableView 기반 — Finder/Bridge 수준 멀티 드래그 + 성능
                        NativeTableListView()
                            .environmentObject(store)
                    } else if UserDefaults.standard.bool(forKey: "useLazyVGrid") == false {
                        // v8.7: 네이티브 NSCollectionView — 2000+장 폴더에서 60fps 스크롤/네비
                        NSThumbnailCollectionView()
                            .environmentObject(store)
                            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                                handleExternalDrop(providers: providers)
                                return true
                            }
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                gridView
                            }
                            .scrollIndicators(.visible)
                            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                                // Finder 등 외부에서 파일을 드롭하면 현재 폴더로 복사
                                // (Option 누르고 드롭하면 이동)
                                handleExternalDrop(providers: providers)
                                return true
                            }
                            .contextMenu {
                                // 빈 영역 우클릭 — 붙여넣기 + 정렬 + 새 폴더
                                Button(action: {
                                    pasteFilesFromPasteboard(store: store)
                                }) {
                                    Label("붙여넣기  ⌘V", systemImage: "doc.on.clipboard")
                                }
                                .disabled(NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil)?.isEmpty ?? true)

                                Divider()

                                Menu("정렬") {
                                    Button("이름순") { store.sortMode = .nameAsc }
                                    Button("이름순 (역순)") { store.sortMode = .nameDesc }
                                    Divider()
                                    Button("날짜순 (최신)") { store.sortMode = .dateDesc }
                                    Button("날짜순 (오래된)") { store.sortMode = .dateAsc }
                                    Divider()
                                    Button("크기순") { store.sortMode = .sizeDesc }
                                    Button("별점순") { store.sortMode = .ratingDesc }
                                }
                                Divider()
                                Button(action: {
                                    guard let parentURL = store.folderURL else { return }
                                    let alert = NSAlert()
                                    alert.messageText = "새 폴더 만들기"
                                    let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                                    tf.stringValue = "새 폴더"
                                    alert.accessoryView = tf
                                    alert.addButton(withTitle: "만들기")
                                    alert.addButton(withTitle: "취소")
                                    if alert.runModal() == .alertFirstButtonReturn {
                                        let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
                                        guard !name.isEmpty else { return }
                                        try? FileManager.default.createDirectory(at: parentURL.appendingPathComponent(name), withIntermediateDirectories: true)
                                        // 썸네일 그리드 리로드 + 폴더 트리 새로고침
                                        store.loadFolder(parentURL, restoreRatings: true)
                                        FolderPreviewCache.shared.invalidate(parentURL)
                                        NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
                                    }
                                }) {
                                    Label("새 폴더 만들기", systemImage: "folder.badge.plus")
                                }
                            }
                            .onChange(of: store.scrollTrigger) { _, _ in
                                guard let id = store.selectedPhotoID else { return }
                                // v8.6.2: 10k+ 폴더에서 LazyVGrid scrollTo 가 느림 → 쓰로틀.
                                //   - 단일 이동 또는 100ms 경과: 즉시 실행
                                //   - 연속 입력 중: trailing 예약 (마지막 위치로 확실히 스크롤 보장)
                                let now = Date()
                                if !store.isKeyRepeat || now.timeIntervalSince(scrollThrottleLastFire) >= 0.1 {
                                    proxy.scrollTo(id, anchor: nil)
                                    scrollThrottleLastFire = now
                                    scrollTrailingWork?.cancel()
                                } else {
                                    // 너무 빠른 연속 호출 → trailing 한 번만 예약 (끝까지 반영 보장)
                                    scrollTrailingWork?.cancel()
                                    let work = DispatchWorkItem {
                                        guard let newID = store.selectedPhotoID else { return }
                                        proxy.scrollTo(newID, anchor: nil)
                                        scrollThrottleLastFire = Date()
                                    }
                                    scrollTrailingWork = work
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
                                }
                            }
                        }
                    }
                }
            }
            } // Group
        }
    }

    /// Finder 등 외부에서 파일을 드롭했을 때 현재 폴더로 복사(기본) 또는 이동(Option).
    private func handleExternalDrop(providers: [NSItemProvider]) {
        let moveInstead = NSEvent.modifierFlags.contains(.option)
        let group = DispatchGroup()
        var collected: [URL] = []
        let lock = NSLock()

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let u = item as? URL { url = u }
                else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                if let u = url {
                    lock.lock()
                    collected.append(u)
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            guard !collected.isEmpty else { return }
            store.importFilesFromExternal(urls: collected, moveInstead: moveInstead)
        }
    }

    private func updateColumns(width: CGFloat) {
        let size = store.thumbnailSize
        let spacing: CGFloat = 12
        let cellWidth = size + spacing
        let cols = max(1, Int((width + spacing) / cellWidth))
        if store.actualColumnsPerRow != cols {
            // 동기 업데이트: async 지연 시 열 수 불일치 → 대각선 이동 버그
            store.actualColumnsPerRow = cols
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: store.folderURL != nil ? "photo.on.rectangle.angled" : "folder")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.3))
            Text(store.folderURL != nil ? "표시할 이미지가 없습니다" : "폴더를 선택하세요")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private func updateActualColumns(width: CGFloat?) {
        guard let w = width, w > 0 else { return }
        let size = store.thumbnailSize
        let spacing: CGFloat = 12
        let cellWidth = size + spacing
        let cols = max(1, Int((w + spacing) / cellWidth))
        if store.actualColumnsPerRow != cols {
            store.actualColumnsPerRow = cols
        }
    }

    private func listSortButton(_ title: String, mode: SortMode, altMode: SortMode, width: CGFloat?) -> some View {
        Button(action: {
            if store.sortMode == mode {
                store.sortMode = altMode
            } else if store.sortMode == altMode {
                store.sortMode = mode
            } else {
                store.sortMode = mode
            }
        }) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: store.sortMode == mode || store.sortMode == altMode ? .bold : .regular))
                if store.sortMode == mode {
                    Image(systemName: "chevron.up").font(.system(size: 7))
                } else if store.sortMode == altMode {
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
            }
            .foregroundColor(store.sortMode == mode || store.sortMode == altMode ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Grid View

    private var gridView: some View {
        let size = store.thumbnailSize
        // Fixed 열 수 사용: adaptive 대신 actualColumnsPerRow 기반 → 키보드 행이동과 정확히 일치
        let columns = Array(repeating: GridItem(.flexible(minimum: size, maximum: size + 60), spacing: 12),
                            count: max(1, store.actualColumnsPerRow))

        let photos = store.filteredPhotos  // Compute once, not per-cell
        let selectedID = store.selectedPhotoID
        let selectedIDs = store.selectedPhotoIDs
        return LazyVGrid(columns: columns, spacing: 10, pinnedViews: []) {
            ForEach(photos) { photo in
                LazyThumbnailWrapper(
                    photo: photo,
                    size: size,
                    isSelected: selectedIDs.contains(photo.id),
                    isFocused: selectedID == photo.id,
                    onTap: {
                        let flags = NSEvent.modifierFlags
                        store.selectPhoto(photo.id, cmdKey: flags.contains(.command), shiftKey: flags.contains(.shift))
                    }
                )
                // v8.6.2: Equatable conformance 로 선택 상태 변경 시 해당 cell 2개만 re-render
                //   (이전에 selected 였다가 해제된 cell + 새로 selected 된 cell). 나머지 10k-2 개는 스킵.
                .equatable()
                .id(photo.id)
                // v8.6.3: 러버밴드 선택용 셀 프레임 수집
                .background(GeometryReader { geo in
                    Color.clear.preference(
                        key: GridCellFrameKey.self,
                        value: [photo.id: geo.frame(in: .named("pickshotGrid"))]
                    )
                })
            }
        }
        .padding(8)
        .background(
            // v8.6.3: 러버밴드 (marquee) 선택 — 빈 영역에서 드래그 시작하면 사각형 그리고 교차 셀 선택
            MarqueeSelectionBackground(
                coordinateSpaceName: "pickshotGrid",
                allPhotoIDs: photos.filter { !$0.isFolder && !$0.isParentFolder }.map(\.id),
                store: store
            )
        )
        .coordinateSpace(name: "pickshotGrid")
        .onPreferenceChange(GridCellFrameKey.self) { frames in
            MarqueeFrameRegistry.shared.frames = frames
        }
    }

    // MARK: - List View

    // 목록뷰 표시 컬럼 설정
    @AppStorage("listColumns") private var listColumnsRaw: String = "date,size,type,rating"

    private var visibleColumns: Set<String> {
        get { Set(listColumnsRaw.split(separator: ",").map(String.init)) }
    }

    private func toggleColumn(_ col: String) {
        var cols = visibleColumns
        if cols.contains(col) { cols.remove(col) } else { cols.insert(col) }
        listColumnsRaw = cols.sorted().joined(separator: ",")
    }

    // 컬럼 폭 (드래그 조절 가능, UserDefaults 저장)
    @AppStorage("colW_name") private var colW_name: Double = 200
    @AppStorage("colW_date") private var colW_date: Double = 150
    @AppStorage("colW_size") private var colW_size: Double = 75
    @AppStorage("colW_type") private var colW_type: Double = 55
    @AppStorage("colW_rating") private var colW_rating: Double = 70
    @AppStorage("colW_resolution") private var colW_resolution: Double = 90
    @AppStorage("colW_camera") private var colW_camera: Double = 100
    @AppStorage("colW_iso") private var colW_iso: Double = 55
    @AppStorage("colW_shutter") private var colW_shutter: Double = 65
    @AppStorage("colW_aperture") private var colW_aperture: Double = 55
    @AppStorage("colW_lens") private var colW_lens: Double = 110

    /// 목록 헤더 (고정)
    private var listHeader: some View {
        let cols = visibleColumns
        return HStack(spacing: 0) {
            // 이름 (가변폭 — 남은 공간 채움)
            HStack(spacing: 4) {
                colHeader("이름", width: nil, sort: .nameAsc, altSort: .nameDesc)
                Spacer(minLength: 4)
            }
            .frame(minWidth: 120)
            .contentShape(Rectangle())
            .onTapGesture { store.sortMode = store.sortMode == .nameAsc ? .nameDesc : .nameAsc }
            if cols.contains("date")       { colHeader("수정일", width: colW_date, sort: .dateDesc, altSort: .dateAsc); colResizer(binding: $colW_date, min: 80) }
            if cols.contains("size")       { colHeader("크기", width: colW_size, sort: .sizeDesc, altSort: .sizeAsc); colResizer(binding: $colW_size, min: 50) }
            if cols.contains("type")       { colHeader("종류", width: colW_type, sort: .extensionSort, altSort: .extensionSort); colResizer(binding: $colW_type, min: 40) }
            if cols.contains("rating")     { colHeader("별점", width: colW_rating, sort: .ratingDesc, altSort: .ratingAsc); colResizer(binding: $colW_rating, min: 50) }
            if cols.contains("resolution") { colHeaderStatic("해상도", width: colW_resolution); colResizer(binding: $colW_resolution, min: 60) }
            if cols.contains("camera")     { colHeader("카메라", width: colW_camera, sort: .cameraSort, altSort: .cameraSort); colResizer(binding: $colW_camera, min: 60) }
            if cols.contains("iso")        { colHeaderStatic("ISO", width: colW_iso); colResizer(binding: $colW_iso, min: 35) }
            if cols.contains("shutter")    { colHeaderStatic("셔터", width: colW_shutter); colResizer(binding: $colW_shutter, min: 40) }
            if cols.contains("aperture")   { colHeaderStatic("조리개", width: colW_aperture); colResizer(binding: $colW_aperture, min: 40) }
            if cols.contains("lens")       { colHeaderStatic("렌즈", width: colW_lens); colResizer(binding: $colW_lens, min: 60) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .contextMenu {
            Toggle("수정일", isOn: Binding(get: { cols.contains("date") }, set: { _ in toggleColumn("date") }))
            Toggle("크기", isOn: Binding(get: { cols.contains("size") }, set: { _ in toggleColumn("size") }))
            Toggle("종류", isOn: Binding(get: { cols.contains("type") }, set: { _ in toggleColumn("type") }))
            Divider()
            Toggle("별점", isOn: Binding(get: { cols.contains("rating") }, set: { _ in toggleColumn("rating") }))
            Toggle("해상도", isOn: Binding(get: { cols.contains("resolution") }, set: { _ in toggleColumn("resolution") }))
            Divider()
            Toggle("카메라", isOn: Binding(get: { cols.contains("camera") }, set: { _ in toggleColumn("camera") }))
            Toggle("렌즈", isOn: Binding(get: { cols.contains("lens") }, set: { _ in toggleColumn("lens") }))
            Toggle("ISO", isOn: Binding(get: { cols.contains("iso") }, set: { _ in toggleColumn("iso") }))
            Toggle("셔터속도", isOn: Binding(get: { cols.contains("shutter") }, set: { _ in toggleColumn("shutter") }))
            Toggle("조리개", isOn: Binding(get: { cols.contains("aperture") }, set: { _ in toggleColumn("aperture") }))
        }
    }

    private func colHeader(_ title: String, width: Double?, sort: SortMode, altSort: SortMode) -> some View {
        let isActive = store.sortMode == sort || store.sortMode == altSort
        return HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isActive ? .accentColor : .primary)
            if isActive {
                Image(systemName: store.sortMode == sort ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .bold)).foregroundColor(.accentColor)
            }
        }
        .frame(width: width.map { CGFloat($0) }, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { store.sortMode = store.sortMode == sort ? altSort : sort }
    }

    private func colHeaderStatic(_ title: String, width: Double) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.primary)
            .frame(width: CGFloat(width), alignment: .center)
    }

    /// 드래그 가능한 컬럼 구분선
    private func colResizer(binding: Binding<Double>, min: CGFloat = 40) -> some View {
        ColResizerView(width: binding, minWidth: Double(min))
    }
    private var colDivider: some View {
        Divider().frame(height: 12).padding(.horizontal, 2)
    }
}

// MARK: - 네이티브 Table 목록뷰 (Finder 스타일 컬럼 리사이즈)

/// 리스트뷰 전용 Table 바운딩 frame 수집 — NSEvent 모니터의 hit test 용.
private struct ListViewBoundsKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct NativeListView: View {
    @EnvironmentObject var store: PhotoStore
    @State private var selection: Set<UUID> = []
    @State private var sortOrder: [KeyPathComparator<PhotoItem>] = [
        .init(\.fileModDate, order: .reverse)
    ]
    @State private var columnCustomization = TableColumnCustomization<PhotoItem>()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// sortOrder 변화에 따라 store.filteredPhotos 를 지역적으로 재정렬해 Table 에 제공.
    /// SwiftUI Table(data, sortOrder:) 는 data 를 스스로 재정렬하지 않으므로 수동 적용.
    private var sortedRows: [PhotoItem] {
        let base = store.filteredPhotos
        if sortOrder.isEmpty { return base }
        // 폴더/parent 는 항상 상단에 고정. 사진만 sortOrder 적용.
        let folders = base.filter { $0.isFolder || $0.isParentFolder }
        let photos = base.filter { !$0.isFolder && !$0.isParentFolder }
        let sortedPhotos = photos.sorted(using: sortOrder)
        return folders + sortedPhotos
    }

    var body: some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            TableColumn("이름", value: \.fileNameWithExtension) { photo in
                listNameCell(photo: photo)
            }
            .width(min: 200, ideal: 320, max: 600)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("수정일", value: \.fileModDate) { photo in
                Text(photo.isFolder ? "--" : Self.dateFormatter.string(from: photo.fileModDate))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .width(min: 100, ideal: 120, max: 180)
            .customizationID("date")

            TableColumn("크기", value: \.totalFileSize) { photo in
                Text(photo.isFolder ? "--" : formatSize(photo.totalFileSize))
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .width(min: 55, ideal: 70, max: 100)
            .customizationID("size")

            TableColumn("종류", value: \.kindSortKey) { photo in
                Text(prettyKind(for: photo))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 75, ideal: 100, max: 150)
            .customizationID("type")

            TableColumn("별점", value: \.rating) { photo in
                let rating = store.livePhoto(photo.id)?.rating ?? photo.rating
                // Lightroom/Capture One 스타일 — 5개 별 전부 표시, 채워진 만큼 골드 색
                HStack(spacing: 1) {
                    if photo.isFolder || photo.isParentFolder {
                        Text("").frame(maxWidth: .infinity)
                    } else {
                        ForEach(1...5, id: \.self) { idx in
                            Image(systemName: idx <= rating ? "star.fill" : "star")
                                .font(.system(size: 9))
                                .foregroundColor(idx <= rating ? AppTheme.starGold : Color.white.opacity(0.18))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .width(min: 70, ideal: 80, max: 110)
            .customizationID("rating")

            TableColumn("해상도", value: \.resolutionSortKey) { photo in
                let exif = store.exifFor(photo.id)
                Group {
                    if let w = exif?.imageWidth, let h = exif?.imageHeight {
                        Text("\(w)×\(h)")
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    } else { Text("") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .width(min: 80, ideal: 100, max: 150)
            .customizationID("resolution")
            .defaultVisibility(.hidden)

            TableColumn("카메라", value: \.cameraSortKey) { photo in
                Text(store.exifFor(photo.id)?.cameraModel ?? "")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .width(min: 80, ideal: 120, max: 200)
            .customizationID("camera")
            .defaultVisibility(.hidden)

            TableColumn("렌즈", value: \.lensSortKey) { photo in
                Text(store.exifFor(photo.id)?.lensModel ?? "")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .width(min: 80, ideal: 120, max: 200)
            .customizationID("lens")
            .defaultVisibility(.hidden)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: UUID.self) { ids in
            listContextMenu(for: ids)
        } primaryAction: { ids in
            // 더블클릭 — 폴더면 진입
            if let id = ids.first, let idx = store._photoIndex[id], idx < store.photos.count {
                let photo = store.photos[idx]
                if photo.isFolder || photo.isParentFolder {
                    store.loadFolder(photo.jpgURL, restoreRatings: true)
                }
            }
        }
        .onChange(of: selection) { _, newSelection in
            store.selectedPhotoIDs = newSelection
            if newSelection.count == 1, let first = newSelection.first {
                store.selectedPhotoID = first
            } else if newSelection.count > 1 {
                // 다중 선택 — selectedPhotoID는 마지막 추가된 것
                if let current = store.selectedPhotoID, newSelection.contains(current) {
                    // 유지
                } else {
                    store.selectedPhotoID = newSelection.first
                }
            }
        }
        .onChange(of: store.selectedPhotoIDs) { _, newIDs in
            if newIDs != selection {
                selection = newIDs
            }
        }
        .onAppear {
            selection = store.selectedPhotoIDs
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                store.triggerListExifLoad()
            }
        }
        .onChange(of: store.photosVersion) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                store.triggerListExifLoad()
            }
        }
        .focusable()
        .onKeyPress { press in
            handleKeyPress(press)
        }
    }

    /// 이름 컬럼 셀 뷰 — 썸네일 + 파일명 + SP/G 배지 + 컬러라벨 인디케이터.
    /// `.draggable` 로 단일 파일 드래그 지원 (SwiftUI Table 의 내부 tracking loop 때문에
    /// NSEvent 글로벌 모니터로 멀티 드래그 불가 — 현재 아키텍처 한계).
    @ViewBuilder
    private func listNameCell(photo: PhotoItem) -> some View {
        let livePhoto = store.livePhoto(photo.id) ?? photo
        HStack(spacing: 8) {
            if let labelColor = livePhoto.colorLabel.color {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(labelColor)
                    .frame(width: 3, height: 20)
            } else {
                Color.clear.frame(width: 3)
            }

            if photo.isParentFolder {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(.secondary)
                    .frame(width: 50, height: 34)
            } else if photo.isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor.opacity(0.85))
                    .frame(width: 50, height: 34)
            } else {
                AsyncThumbnailView(url: photo.displayURL)
                    .frame(width: 50, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            }

            Text(photo.fileNameWithExtension)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            if livePhoto.isSpacePicked {
                Image(systemName: "flag.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.red)
            }
            if livePhoto.isGSelected {
                Text("G")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color.green))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    // Table 의 내부 mouse tracking 과 간섭 없이 드래그 감지.
                    //   onChanged 가 여러 번 호출되므로 한 번만 drag session 개시.
                    guard !Self.listDragInProgress else { return }
                    Self.listDragInProgress = true
                    fputs("[ListDrag] gesture → initiate (photo=\(photo.id.uuidString.prefix(8)))\n", stderr)
                    initiateListDrag(anchor: photo)
                }
                .onEnded { _ in
                    Self.listDragInProgress = false
                }
        )
        .onAppear {
            if !photo.isFolder && !photo.isParentFolder && photo.exifData == nil {
                store.loadExifIfNeeded(for: photo.id)
            }
        }
    }

    /// 리스트뷰 드래그 진행 상태 — simultaneousGesture 가 여러 번 fire 하므로 중복 방지.
    /// ListViewDragSource.draggingSession(endedAt:) 에서 리셋하므로 internal.
    nonisolated(unsafe) static var listDragInProgress: Bool = false

    /// 드래그 시작 — 선택된 모든 파일로 NSDraggingSession 개시
    private func initiateListDrag(anchor: PhotoItem) {
        guard let event = NSApp.currentEvent else {
            fputs("[ListDrag] ❌ no current event\n", stderr)
            return
        }
        // 선택에 anchor 포함 안 되면 단독 드래그
        let ids: Set<UUID> = store.selectedPhotoIDs.contains(anchor.id)
            ? store.selectedPhotoIDs : [anchor.id]
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

        let side: CGFloat = 80
        let defaultFrame = NSRect(x: -side / 2, y: -side / 2, width: side, height: side)

        // 프리뷰 생성
        var previewImage: NSImage? = nil
        let thumb = DiskThumbnailCache.shared.getByPath(url: anchor.jpgURL)
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

        var items: [NSDraggingItem] = []
        for (i, url) in urls.enumerated() {
            let pb = NSPasteboardItem()
            pb.setString(url.absoluteString, forType: .fileURL)
            let di = NSDraggingItem(pasteboardWriter: pb)
            di.setDraggingFrame(defaultFrame, contents: i == 0 ? previewImage : nil)
            items.append(di)
        }

        guard let contentView = event.window?.contentView else {
            fputs("[ListDrag] ❌ no contentView\n", stderr)
            return
        }
        _ = contentView.beginDraggingSession(with: items, event: event, source: ListViewDragSource.shared)
        fputs("[ListDrag] ✅ session started with \(urls.count) items\n", stderr)
    }

    /// 리스트뷰 우클릭 컨텍스트 메뉴 — 썸네일뷰 PhotoContextMenu 재사용.
    @ViewBuilder
    private func listContextMenu(for ids: Set<UUID>) -> some View {
        // 우클릭 시 해당 행을 선택으로 전환 (썸네일뷰와 동일 UX)
        let _ = {
            if !ids.isEmpty && ids != selection {
                DispatchQueue.main.async {
                    selection = ids
                    store.selectedPhotoIDs = ids
                    if let first = ids.first { store.selectedPhotoID = first }
                }
            }
        }()
        let effectiveIDs: Set<UUID> = ids.isEmpty ? selection : ids
        let firstID = effectiveIDs.first
        let idx: Int? = firstID.flatMap { store._photoIndex[$0] }
        if let i = idx, i < store.photos.count {
            PhotoContextMenu(photo: store.photos[i], store: store)
        } else {
            Text("선택된 파일 없음").disabled(true)
        }
    }

    private func handleKeyPressExt(_ press: KeyPress) -> KeyPress.Result {
        // Cmd+C/X/V — 복사/잘라내기/붙여넣기
        if press.modifiers.contains(.command) {
            switch press.characters.lowercased() {
            case "c":
                copySelectionToPasteboard(store: store)
                return .handled
            case "x":
                cutSelectionToPasteboard(store: store)
                return .handled
            case "v":
                pasteFilesFromPasteboard(store: store)
                return .handled
            case "a":
                store.selectAll()
                selection = store.selectedPhotoIDs
                return .handled
            default: break
            }
        }
        return .ignored
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Cmd 단축키 먼저 처리
        if handleKeyPressExt(press) == .handled { return .handled }

        let chars = press.characters

        // 스페이스바: 별 5개 토글 (포커스 사진 기준, 다중 선택 시 일괄)
        if chars == " " {
            if store.selectedPhotoIDs.count > 1 {
                // 포커스 사진의 현재 값 기준으로 토글 결정 → 전체 일괄
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

    /// Finder 스타일 파일 종류 라벨 — "JPEG 이미지", "Sony RAW", "MP4 비디오" 등
    private func prettyKind(for photo: PhotoItem) -> String {
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

    private func formatSize(_ bytes: Int64) -> String {
        if bytes <= 0 { return "--" }
        if bytes > 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        if bytes > 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private func badgeColor(_ color: String) -> Color {
        switch color {
        case "green": return .green; case "orange": return .orange
        case "blue": return .blue; case "purple": return .purple
        case "teal": return .teal; default: return .gray
        }
    }
}

// MARK: - 컬럼 리사이저 (각 인스턴스 독립 @State)
struct ColResizerView: View {
    @Binding var width: Double
    let minWidth: Double
    @State private var startWidth: Double = 0

    var body: some View {
        // 히트 영역 12px, 표시 구분선 1px
        Color.clear
            .frame(width: 12, height: 24)
            .overlay(
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 1, height: 14)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if startWidth == 0 { startWidth = width }
                        let newW = startWidth + Double(value.translation.width)
                        width = Swift.max(minWidth, Swift.min(500, newW))
                    }
                    .onEnded { _ in
                        startWidth = 0
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
    }
}

// MARK: - SP 행 하이라이트 modifier
struct SPRowHighlight: ViewModifier {
    let isSP: Bool
    func body(content: Content) -> some View {
        content
            .background(isSP ? Color.red.opacity(0.08) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSP ? Color.red.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
    }
}

extension View {
    func spRowHighlight(store: PhotoStore, id: UUID) -> some View {
        let sp = store.livePhoto(id)?.isSpacePicked ?? false
        return self.modifier(SPRowHighlight(isSP: sp))
    }
}

extension ThumbnailGridView {

    /// 목록 본문 (스크롤)
    private var listBody: some View {
        let photos = store.filteredPhotos
        return LazyVStack(spacing: 0, pinnedViews: []) {
            ForEach(photos) { photo in
                LazyListRowWrapper(
                    photo: photo,
                    isSelected: store.isSelected(photo.id),
                    isFocused: store.selectedPhotoID == photo.id,
                    onTap: {
                        let flags = NSEvent.modifierFlags
                        store.selectPhoto(photo.id, cmdKey: flags.contains(.command), shiftKey: flags.contains(.shift))
                    }
                )
                .id(photo.id)
                .onTapGesture {
                    let flags = NSEvent.modifierFlags
                    store.selectPhoto(photo.id, cmdKey: flags.contains(.command), shiftKey: flags.contains(.shift))
                }
                Divider().opacity(0.15).padding(.leading, 34)
            }
        }
        .frame(minHeight: 100)
    }
}

// MARK: - Lazy Wrappers (prevent full grid re-render on selection change)

struct LazyThumbnailWrapper: View, Equatable {
    let photo: PhotoItem
    let size: CGFloat
    let isSelected: Bool
    let isFocused: Bool
    let onTap: () -> Void
    @EnvironmentObject var store: PhotoStore

    // v8.6.2: 선택 상태/사진ID/크기만 비교. store 변경 (예: thumbCacheCount) 에는 re-render 안 함.
    static func == (l: LazyThumbnailWrapper, r: LazyThumbnailWrapper) -> Bool {
        l.photo.id == r.photo.id
            && l.size == r.size
            && l.isSelected == r.isSelected
            && l.isFocused == r.isFocused
            && l.photo.rating == r.photo.rating
            && l.photo.colorLabel == r.photo.colorLabel
            && l.photo.isSpacePicked == r.photo.isSpacePicked
            && l.photo.isGSelected == r.photo.isGSelected
    }

    var body: some View {
        if photo.isParentFolder {
            let isSelected = store.selectedPhotoID == photo.id || store.selectedPhotoIDs.contains(photo.id)
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? AppTheme.accent.opacity(0.2) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .frame(width: size, height: size * 0.75)
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(isSelected ? 0.3 : 0.12))
                                .frame(width: size * 0.35, height: size * 0.35)
                            Image(systemName: "chevron.up")
                                .font(.system(size: size * 0.14, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                        Text(photo.jpgURL.lastPathComponent)
                            .font(.system(size: max(9, size * 0.055), weight: .medium))
                            .foregroundColor(isSelected ? .white : .secondary)
                            .lineLimit(1)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? AppTheme.selectionBorder : Color.clear, lineWidth: AppTheme.cellBorderWidth)
                )
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? AppTheme.selectionBorder.opacity(0.15) : Color.clear)
                )
            }
            .frame(width: size)
            .padding(4)
            .contentShape(Rectangle())
            .onTapGesture {
                if NSApp.currentEvent?.clickCount == 2 {
                    store.loadFolder(photo.jpgURL)
                } else {
                    let flags = NSEvent.modifierFlags
                    store.selectPhoto(photo.id, cmdKey: flags.contains(.command), shiftKey: flags.contains(.shift))
                }
            }
            .help("클릭: 선택 / 더블클릭: 이동 / Enter: 이동")
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                // 상위 폴더로 드래그 이동
                handleDropOnFolder(providers: providers, folderURL: photo.jpgURL)
                return true
            }
        } else if photo.isFolder {
            // Subfolder item — 미리보기 사진 4장 or 폴더 아이콘
            VStack(spacing: 4) {
                if store.showFolderPreview {
                    FolderPreviewGrid(folderURL: photo.jpgURL, size: size)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.gray.opacity(0.08))
                            .frame(width: size, height: size * 0.75)
                        Image(systemName: "folder.fill")
                            .font(.system(size: size * 0.25))
                            .foregroundColor(.blue.opacity(0.6))
                    }
                }
                Text(photo.jpgURL.lastPathComponent)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size)
            }
            .frame(width: size)
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? AppTheme.selectionBorder : Color.clear, lineWidth: AppTheme.cellBorderWidth)
            )
            .contentShape(Rectangle())
            // 폴더 자체 드래그 — SwiftUI 네이티브 .onDrag (커스텀 NSView 보다 이벤트 관리 안정적)
            .onDrag {
                let provider = NSItemProvider(object: photo.jpgURL as NSURL)
                provider.suggestedName = photo.jpgURL.lastPathComponent
                return provider
            }
            // 다른 폴더/파일을 이 폴더 안으로 드롭 받기
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                handleDropOnFolder(providers: providers, folderURL: photo.jpgURL)
                return true
            }
            .onTapGesture {
                if NSApp.currentEvent?.clickCount == 2 {
                    store.loadFolder(photo.jpgURL)
                } else {
                    let flags = NSEvent.modifierFlags
                    store.selectPhoto(photo.id, cmdKey: flags.contains(.command), shiftKey: flags.contains(.shift))
                }
            }
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
            ThumbnailCell(
                photo: photo,
                isSelected: isSelected,
                isFocused: isFocused,
                size: size
            )
            .equatable()
            .contentShape(Rectangle())
            .overlay(
                MultiFileDragView(photo: photo, store: store)
            )
            .overlay(
                DropIndicatorOverlay(photoID: photo.id)
            )
            .onDrop(of: [.utf8PlainText], delegate: PhotoReorderDropDelegate(
                photo: photo, store: store, cellWidth: size
            ))
            .onTapGesture { onTap() }
            .contextMenu {
                if photo.isFolder || photo.isParentFolder {
                    Button("Finder에서 열기") {
                        NSWorkspace.shared.open(photo.jpgURL)
                    }
                    if photo.isFolder {
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
                    PhotoContextMenu(photo: photo, store: store)
                }
            }
        }
    }

    /// 폴더 썸네일에 드래그 드롭 시:
    /// - 사진 드래그 → 해당 폴더로 이동
    /// - 폴더 드래그 → 대상 폴더 안으로 이동 (자기 자신/자식으로 이동 방지)
    /// 동시 드롭 방지 (같은 드롭이 두 번 fire 되지 않도록)
    private func handleDropOnFolder(providers: [NSItemProvider], folderURL: URL) {
        // 빠른 연속 드롭 방지 — 현재 진행 중이면 무시
        let now = CFAbsoluteTimeGetCurrent()
        if let last = Self.lastDropFolderTime, now - last < 0.3,
           Self.lastDropFolderURL == folderURL {
            return
        }
        Self.lastDropFolderTime = now
        Self.lastDropFolderURL = folderURL
        // 이후 오리지널 로직 이어짐 — inner impl 호출
        handleDropOnFolderImpl(providers: providers, folderURL: folderURL)
    }
    private static var lastDropFolderTime: CFAbsoluteTime?
    private static var lastDropFolderURL: URL?

    private func handleDropOnFolderImpl(providers: [NSItemProvider], folderURL: URL) {
        // providers 에서 파일 URL 추출 (drag overlay 가 pasteboard 로 전달한 경우 대비)
        var droppedURLs: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier("public.file-url") else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) {
                    droppedURLs.append(u)
                } else if let u = item as? URL {
                    droppedURLs.append(u)
                }
            }
        }
        group.notify(queue: .main) {
            // 외부 소스(providers) 에서 못 받은 경우 → 현재 선택 기준으로 폴백
            var fileURLs: [URL] = droppedURLs.isEmpty ? [] : droppedURLs
            var folderURLs: [URL] = []

            if fileURLs.isEmpty {
                // 그리드 내부 선택 기반 (기존 로직)
                for id in store.selectedPhotoIDs {
                    guard let idx = store._photoIndex[id], idx < store.photos.count else { continue }
                    let p = store.photos[idx]
                    if p.isParentFolder { continue }
                    if p.isFolder {
                        folderURLs.append(p.jpgURL)
                    } else {
                        fileURLs.append(p.jpgURL)
                        if let raw = p.rawURL, raw != p.jpgURL { fileURLs.append(raw) }
                    }
                }
            } else {
                // Provider 기반: URL 타입별 분류
                var files: [URL] = []
                for u in fileURLs {
                    // 자기 자신이나 부모로 드롭 방지
                    if u == folderURL || folderURL.path.hasPrefix(u.path + "/") { continue }
                    if u.hasDirectoryPath {
                        folderURLs.append(u)
                    } else {
                        files.append(u)
                    }
                }
                fileURLs = files
            }

            // 파일 이동
            if !fileURLs.isEmpty {
                store.movePhotosToFolder(fileURLs: fileURLs, destination: folderURL)
            }
            // 폴더 이동
            for src in folderURLs {
                let dest = folderURL.appendingPathComponent(src.lastPathComponent)
                do {
                    try FileManager.default.moveItem(at: src, to: dest)
                    store.showToastMessage("📁 '\(src.lastPathComponent)' → '\(folderURL.lastPathComponent)' 이동")
                } catch {
                    store.showToastMessage("⚠️ 폴더 이동 실패: \(error.localizedDescription)")
                }
            }
            if !folderURLs.isEmpty {
                NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
                if let current = store.folderURL {
                    store.loadFolder(current, restoreRatings: true)
                }
            }
        }
    }
}

struct LazyListRowWrapper: View {
    let photo: PhotoItem
    let isSelected: Bool
    let isFocused: Bool
    let onTap: () -> Void
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        ListRow(photo: photo, isSelected: isSelected, isFocused: isFocused, thumbSize: store.thumbnailSize)
            .contentShape(Rectangle())
            .onDrag {
                let ids = store.selectedPhotoIDs.contains(photo.id) ? store.selectedPhotoIDs : [photo.id]
                var urls: [URL] = []
                for id in ids {
                    guard let idx = store._photoIndex[id], idx < store.photos.count else { continue }
                    let p = store.photos[idx]
                    guard !p.isFolder && !p.isParentFolder else { continue }
                    urls.append(p.jpgURL)
                    if let rawURL = p.rawURL, rawURL != p.jpgURL { urls.append(rawURL) }
                }
                let provider = NSItemProvider()
                for url in urls {
                    provider.registerFileRepresentation(forTypeIdentifier: "public.file-url", visibility: .all) { completion in
                        completion(url, false, nil)
                        return nil
                    }
                }
                return provider
            }
            .onAppear {
                store.loadExifIfNeeded(for: photo.id)
            }
            .onChange(of: store.photosVersion) { _, _ in
                // 정렬/필터 변경 후에도 EXIF 재로딩
                store.loadExifIfNeeded(for: photo.id)
            }
            .onTapGesture {
                if photo.isParentFolder || photo.isFolder {
                    store.loadFolder(photo.jpgURL, restoreRatings: true)
                } else {
                    onTap()
                }
            }
            .contextMenu {
                if photo.isFolder || photo.isParentFolder {
                    Button("Finder에서 열기") {
                        NSWorkspace.shared.open(photo.jpgURL)
                    }
                } else {
                    PhotoContextMenu(photo: photo, store: store)
                }
            }
    }
}

// MARK: - Photo Context Menu (Right-click)

/// 폴더/사진 공통: 복사/잘라내기/붙여넣기 컨텍스트 메뉴 3줄.
@ViewBuilder
func copyCutPasteMenu(for photo: PhotoItem, store: PhotoStore) -> some View {
    Button(action: {
        // 선택 안돼있으면 현재 사진만 선택하고 복사
        if !store.selectedPhotoIDs.contains(photo.id) {
            store.selectedPhotoIDs = [photo.id]
            store.selectedPhotoID = photo.id
        }
        copySelectionToPasteboard(store: store)
    }) {
        Label("복사  ⌘C", systemImage: "doc.on.doc")
    }
    Button(action: {
        if !store.selectedPhotoIDs.contains(photo.id) {
            store.selectedPhotoIDs = [photo.id]
            store.selectedPhotoID = photo.id
        }
        cutSelectionToPasteboard(store: store)
    }) {
        Label("잘라내기  ⌘X", systemImage: "scissors")
    }
    Button(action: {
        pasteFilesFromPasteboard(store: store)
    }) {
        Label("붙여넣기  ⌘V", systemImage: "doc.on.clipboard")
    }
    .disabled(NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil)?.isEmpty ?? true)
}

struct PhotoContextMenu: View {
    let photo: PhotoItem
    let store: PhotoStore

    private var targetIDs: Set<UUID> {
        store.selectedPhotoIDs.contains(photo.id) ? store.selectedPhotoIDs : [photo.id]
    }

    private var targetCount: Int {
        targetIDs.count
    }

    private static let recentFoldersKey = "recentCopyFolders"

    private var recentCopyFolders: [URL] {
        // Try security-scoped bookmarks first (App Sandbox)
        let bookmarked = SandboxBookmarkService.resolveBookmarks(keyPrefix: "recentCopyFolders")
        if !bookmarked.isEmpty { return bookmarked }
        // Fallback to path strings (backward compat)
        return (UserDefaults.standard.stringArray(forKey: Self.recentFoldersKey) ?? [])
            .compactMap { URL(fileURLWithPath: $0) }
    }

    private func addRecentFolder(_ url: URL) {
        var folders = UserDefaults.standard.stringArray(forKey: Self.recentFoldersKey) ?? []
        folders.removeAll { $0 == url.path }
        folders.insert(url.path, at: 0)
        if folders.count > 5 { folders = Array(folders.prefix(5)) }
        UserDefaults.standard.set(folders, forKey: Self.recentFoldersKey)
        let urls = folders.compactMap { URL(fileURLWithPath: $0) }
        SandboxBookmarkService.saveBookmarks(for: urls, keyPrefix: "recentCopyFolders")
    }

    private func collectFileURLs() -> [URL] {
        var urls: [URL] = []
        for id in targetIDs {
            guard let idx = store._photoIndex[id], idx < store.photos.count else { continue }
            let p = store.photos[idx]
            guard !p.isFolder && !p.isParentFolder else { continue }
            urls.append(p.jpgURL)
            if let rawURL = p.rawURL, rawURL != p.jpgURL { urls.append(rawURL) }
        }
        return urls
    }

    private func copyFilesToFolder(_ destFolder: URL) {
        let fm = FileManager.default
        let files = collectFileURLs()
        var copied = 0
        for file in files {
            let dest = destFolder.appendingPathComponent(file.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: file, to: dest)
                copied += 1
            } catch {}
        }
        addRecentFolder(destFolder)
        store.showToastMessage("📂 \(copied)개 파일 복사 완료 → \(destFolder.lastPathComponent)")
    }

    private func copyFilesToNewFolder() {
        let panel = NSOpenPanel()
        panel.title = "복사할 폴더 선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        copyFilesToFolder(url)
    }

    var body: some View {
        // 복사 / 잘라내기 / 붙여넣기
        Button(action: { copySelectionToPasteboard(store: store) }) {
            Label("복사  ⌘C", systemImage: "doc.on.doc")
        }
        Button(action: { cutSelectionToPasteboard(store: store) }) {
            Label("잘라내기  ⌘X", systemImage: "scissors")
        }
        Button(action: { pasteFilesFromPasteboard(store: store) }) {
            Label("붙여넣기  ⌘V", systemImage: "doc.on.clipboard")
        }
        .disabled(NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil)?.isEmpty ?? true)

        Divider()

        // 새 폴더로 이동 (최상단)
        Button(action: {
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
                let urls = collectFileURLs()
                store.movePhotosToFolder(fileURLs: urls, destination: newDir)
            }
        }) {
            Label("새 폴더로 이동", systemImage: "folder.fill.badge.plus")
        }

        Divider()

        // Rating submenu
        Menu {
            ForEach(0...5, id: \.self) { rating in
                Button(action: {
                    for id in targetIDs {
                        if let idx = store._photoIndex[id] { store.photos[idx].rating = rating }
                    }
                }) {
                    if rating == 0 {
                        Label("별점 없음", systemImage: "star.slash")
                    } else {
                        Label(String(repeating: "★", count: rating), systemImage: "star.fill")
                    }
                }
            }
        } label: {
            Label("별점", systemImage: "star.fill")
        }

        // 컬러 라벨
        Menu {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                Button(action: {
                    for id in targetIDs { store.setColorLabel(label == .none ? photo.colorLabel : label, for: id) }
                }) {
                    HStack {
                        if label == .none {
                            Label("라벨 해제", systemImage: "xmark.circle")
                        } else {
                            Label(label.rawValue + (label.key.isEmpty ? "" : " (\(label.key))"), systemImage: "circle.fill")
                        }
                        if photo.colorLabel == label && label != .none { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Label("컬러 라벨", systemImage: "tag.fill")
        }

        // G Select
        Button(action: {
            for id in targetIDs {
                if let idx = store._photoIndex[id] { store.photos[idx].isGSelected.toggle() }
            }
        }) {
            Label(photo.isGSelected ? "G셀렉 해제" : "G셀렉", systemImage: "cloud")
        }

        // Color label submenu
        Menu {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                Button(action: {
                    for id in targetIDs {
                        if let idx = store._photoIndex[id] { store.photos[idx].colorLabel = label }
                    }
                }) {
                    HStack {
                        Circle().fill(label.color ?? .gray).frame(width: 10, height: 10)
                        Text(label == .none ? "라벨 없음" : label.rawValue)
                    }
                }
            }
        } label: {
            Label("컬러 라벨", systemImage: "tag.fill")
        }

        Divider()

        // Export selected
        Button(action: {
            store.showExportSheet = true
        }) {
            Label("내보내기 (\(targetCount)장)", systemImage: "square.and.arrow.up")
        }

        // RAW → JPG conversion (opens export sheet in RAW→JPG tab)
        Button(action: {
            store.exportOpenAsRawConvert = true
            store.showExportSheet = true
        }) {
            Label("RAW → JPG 변환 (\(targetCount)장)", systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        // Metadata Edit
        Button(action: {
            store.metadataEditorMode = targetCount > 1 ? .batch : .single
            store.showMetadataEditor = true
        }) {
            Label("메타데이터 편집 (\(targetCount)장)", systemImage: "doc.badge.gearshape")
        }

        // Rename
        Button(action: {
            store.showBatchRename = true
        }) {
            Label("이름 변경 (\(targetCount)장)", systemImage: "pencil")
        }

        // v8.6.2: 일괄 회전 (JPG: EXIF 재기록, RAW: XMP 사이드카)
        Menu {
            Button("90° 시계방향") { store.batchRotate(ids: targetIDs, degreesCW: 90) }
            Button("180°")         { store.batchRotate(ids: targetIDs, degreesCW: 180) }
            Button("270° (반시계 90°)") { store.batchRotate(ids: targetIDs, degreesCW: 270) }
        } label: {
            Label("회전 (\(targetCount)장)", systemImage: "rotate.right")
        }

        // v8.6.3: Adobe Camera Raw (Photoshop) 로 열기
        Button(action: {
            openInCameraRaw(ids: targetIDs, store: store)
        }) {
            Label("Camera Raw 에서 열기 (\(targetCount)장)", systemImage: "camera.metering.matrix")
        }
        .disabled(!hasAnyRAW(ids: targetIDs, store: store))

        // v8.7: 참조 기반 시각 검색 — "이 얼굴/사물이 있는 사진 찾기" (Debug 전용)
        #if DEBUG
        Menu {
            Button(action: {
                store.visualSearchCropURL = photo.jpgURL
                store.visualSearchCropMode = .face
                store.visualSearchPresetLabel = nil
                NotificationCenter.default.post(name: .pickShotOpenVisualSearchCrop, object: nil)
            }) {
                Label("이 얼굴 찾기 (영역 드래그)", systemImage: "person.circle")
            }
            Button(action: {
                store.visualSearchCropURL = photo.jpgURL
                store.visualSearchCropMode = .object
                store.visualSearchPresetLabel = nil
                NotificationCenter.default.post(name: .pickShotOpenVisualSearchCrop, object: nil)
            }) {
                Label("이 사물/배경 찾기 (영역 드래그)", systemImage: "sparkle.magnifyingglass")
            }
            // 기존 얼굴 레퍼런스 label 들 — "같은 사람 추가 샷" 바로가기
            let existingLabels = Set(VisualSearchService.shared.references
                .filter { $0.mode == .face }
                .compactMap { $0.label })
            if !existingLabels.isEmpty {
                Divider()
                ForEach(Array(existingLabels).sorted(), id: \.self) { lbl in
                    Button(action: {
                        store.visualSearchCropURL = photo.jpgURL
                        store.visualSearchCropMode = .face
                        store.visualSearchPresetLabel = lbl
                        NotificationCenter.default.post(name: .pickShotOpenVisualSearchCrop, object: nil)
                    }) {
                        Label("'\(lbl)' 에 샷 추가 (옆/뒷면)", systemImage: "plus.circle")
                    }
                }
            }
            // v8.7: 학습 — 현재 검색이 active 일 때만 표시
            if store.visualSearchActive && !VisualSearchService.shared.references.isEmpty {
                Divider()
                // 활성 검색의 label 들 표시 (사용자가 "이 사람 아님" 선언 가능)
                let activeLabels = Set(VisualSearchService.shared.references
                    .filter { $0.mode == .face }
                    .compactMap { $0.label }
                )
                ForEach(Array(activeLabels).sorted(), id: \.self) { lbl in
                    Button(action: {
                        VisualSearchService.shared.markAsNotMatching(url: photo.jpgURL, forLabel: lbl)
                        store.showToastMessage("학습됨: '\(lbl)' 아님으로 표시")
                    }) {
                        Label("'\(lbl)' 아님 (학습)", systemImage: "hand.thumbsdown")
                    }
                }
            }
            if !VisualSearchService.shared.references.isEmpty {
                Divider()
                Button(action: {
                    VisualSearchService.shared.clearAll()
                    store.visualSearchActive = false
                }) {
                    Label("검색 기준 모두 해제", systemImage: "xmark.circle")
                }
            }
        } label: {
            Label("비슷한 사진 찾기", systemImage: "magnifyingglass")
        }
        #endif

        Divider()

        // Copy filename
        Button(action: {
            let names = targetIDs.compactMap { id -> String? in
                guard let idx = store._photoIndex[id] else { return nil }
                return store.photos[idx].jpgURL.lastPathComponent
            }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names, forType: .string)
            store.showToastMessage("📋 \(targetCount)개 파일명 복사됨")
        }) {
            Label("파일명 복사", systemImage: "doc.on.clipboard")
        }

        // Show in Finder
        Button(action: {
            NSWorkspace.shared.activateFileViewerSelecting([photo.jpgURL])
        }) {
            Label("Finder에서 보기", systemImage: "folder")
        }

        // 연결 프로그램으로 열기
        Menu {
            // 기본 앱으로 열기
            Button(action: {
                NSWorkspace.shared.open(photo.jpgURL)
            }) {
                Label("기본 앱으로 열기", systemImage: "app")
            }

            Divider()

            // 주요 사진 앱 목록
            let photoApps: [(String, String, String)] = [
                ("Adobe Photoshop", "PaintbrushStroke", "com.adobe.Photoshop"),
                ("Adobe Lightroom", "camera.filters", "com.adobe.LightroomClassicCC7"),
                ("Adobe Bridge", "rectangle.stack", "com.adobe.bridge14"),
                ("Capture One", "camera.aperture", "com.phaseone.captureone"),
                ("미리보기", "eye", "com.apple.Preview"),
            ]
            ForEach(photoApps, id: \.0) { (name, icon, bundleId) in
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    Button(action: {
                        NSWorkspace.shared.open([photo.jpgURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                    }) {
                        Label(name, systemImage: icon)
                    }
                }
            }

            Divider()

            // 기타 앱 선택
            Button(action: {
                let panel = NSOpenPanel()
                panel.title = "프로그램 선택"
                panel.allowedContentTypes = [.application]
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                if panel.runModal() == .OK, let appURL = panel.url {
                    NSWorkspace.shared.open([photo.jpgURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                }
            }) {
                Label("기타 프로그램 선택...", systemImage: "ellipsis.circle")
            }
        } label: {
            Label("연결 프로그램으로 열기", systemImage: "arrow.up.forward.app")
        }

        // 이 사람만 보기 (얼굴 그룹 필터) — AI 기능 숨김 시 제외
        if !AppConfig.hideAIFeatures {
            if let fgID = photo.faceGroupID {
                Button(action: {
                    store.faceGroupFilter = fgID
                    store.showToastMessage("👤 \(store.faceGroupName(for: fgID)) 필터 적용")
                }) {
                    Label("이 사람만 보기", systemImage: "person.crop.circle")
                }
            } else if !store.faceGroups.isEmpty {
                // 얼굴 그룹핑은 됐지만 이 사진에 얼굴이 없는 경우 — 메뉴에서 제외
                // (disabled 버튼은 UX 혼란을 주므로 그냥 숨김)
            }
        }

        Divider()

        // Remove from list
        Button(action: {
            store.photosToRemove = targetIDs
            store.showDeleteConfirm = true
        }) {
            Label("목록에서 제거", systemImage: "eye.slash")
        }

        // Delete original (if setting enabled)
        Button(role: .destructive, action: {
            store.requestDeleteOriginal(ids: targetIDs)
        }) {
            Label("휴지통으로 이동", systemImage: "trash")
        }

    }

    /// 현재 열려 있는 폴더 안에 새 폴더 생성
    private func createNewFolderInCurrentFolder() {
        guard let parentURL = store.folderURL else { return }
        let alert = NSAlert()
        alert.messageText = "새 폴더 만들기"
        alert.informativeText = "폴더 이름을 입력하세요"
        alert.addButton(withTitle: "만들기")
        alert.addButton(withTitle: "취소")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "새 폴더"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let newFolder = parentURL.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
                store.showToastMessage("📁 '\(name)' 폴더 생성 완료")
                NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
                // 현재 폴더 새로고침
                store.loadFolder(parentURL, restoreRatings: true)
            } catch {
                store.showToastMessage("⚠️ 폴더 생성 실패: \(error.localizedDescription)")
            }
        }
    }

}

// MARK: - RAW 헬퍼 (top-level — PhotoContextMenu + NativeTableListView Coordinator 공유)

func hasAnyRAW(ids: Set<UUID>, store: PhotoStore) -> Bool {
    for id in ids {
        guard let idx = store._photoIndex[id] else { continue }
        let p = store.photos[idx]
        if p.rawURL != nil || FileMatchingService.rawExtensions.contains(p.jpgURL.pathExtension.lowercased()) {
            return true
        }
    }
    return false
}

/// Adobe Camera Raw (Photoshop) 로 RAW 파일 열기.
/// /Applications 아래 Photoshop 버전을 찾아 사용. 없으면 기본 앱으로 열림.
func openInCameraRaw(ids: Set<UUID>, store: PhotoStore) {
        let urls: [URL] = ids.compactMap { id in
            guard let idx = store._photoIndex[id], idx < store.photos.count else { return nil }
            let p = store.photos[idx]
            if let raw = p.rawURL { return raw }
            if FileMatchingService.rawExtensions.contains(p.jpgURL.pathExtension.lowercased()) { return p.jpgURL }
            return nil
        }
        guard !urls.isEmpty else {
            store.showToastMessage("⚠️ 선택에 RAW 파일이 없습니다")
            return
        }
        // Photoshop 찾기 — Adobe 는 /Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app 구조
        let ws = NSWorkspace.shared
        var photoshop: URL? = nil
        // 1) Bundle ID 로 직접 조회 (가장 확실)
        if let bundleURL = ws.urlForApplication(withBundleIdentifier: "com.adobe.Photoshop") {
            photoshop = bundleURL
        }
        // 2) Fallback: /Applications 깊이 2까지 스캔해서 Adobe Photoshop*.app 찾기 (최신 버전 우선)
        if photoshop == nil {
            let fm = FileManager.default
            let topLevel = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            var candidates: [URL] = []
            for item in topLevel {
                let name = item.lastPathComponent.lowercased()
                if name.hasSuffix(".app") && name.contains("photoshop") {
                    candidates.append(item)
                } else if name.contains("photoshop") {
                    // 서브폴더 한 단계 더 — Adobe 표준 구조
                    let sub = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                    for s in sub where s.pathExtension == "app" && s.lastPathComponent.lowercased().contains("photoshop") {
                        candidates.append(s)
                    }
                }
            }
            // 최신 버전 우선 — "Adobe Photoshop 2026.app" > "2025" > "2024" > "(Beta)"
            photoshop = candidates.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
        }
        if let ps = photoshop {
            fputs("[RAW] Camera Raw 대상 앱: \(ps.path)\n", stderr)
        } else {
            fputs("[RAW] Photoshop 을 찾지 못함 → 기본 앱으로 fallback\n", stderr)
        }

        if let ps = photoshop {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            ws.open(urls, withApplicationAt: ps, configuration: cfg) { _, error in
                DispatchQueue.main.async {
                    if let error = error {
                        store.showToastMessage("⚠️ Camera Raw 열기 실패: \(error.localizedDescription)")
                    } else {
                        store.showToastMessage("📷 \(urls.count)장 → \(ps.lastPathComponent)")
                    }
                }
            }
        } else {
            // Photoshop 없음 — 기본 앱으로 열기 (macOS 가 연결된 앱 사용)
            for u in urls {
                ws.open(u)
            }
            store.showToastMessage("📷 \(urls.count)장 기본 앱으로 열기 (Photoshop 미설치)")
        }
    }

// MARK: - Thumbnail Cell (Grid)

struct ThumbnailCell: View, Equatable {
    @EnvironmentObject var store: PhotoStore
    @ObservedObject private var developStore = DevelopStore.shared
    let photo: PhotoItem
    let isSelected: Bool
    let isFocused: Bool
    let size: CGFloat

    @State private var isHovered = false

    static func == (lhs: ThumbnailCell, rhs: ThumbnailCell) -> Bool {
        lhs.photo.id == rhs.photo.id &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isFocused == rhs.isFocused &&
        lhs.size == rhs.size &&
        lhs.photo.rating == rhs.photo.rating &&
        lhs.photo.colorLabel == rhs.photo.colorLabel &&
        lhs.photo.isSpacePicked == rhs.photo.isSpacePicked &&
        lhs.photo.isGSelected == rhs.photo.isGSelected &&
        lhs.photo.clientSelected == rhs.photo.clientSelected &&
        lhs.photo.clientComments.count == rhs.photo.clientComments.count &&
        (lhs.photo.clientPenDrawingsJSON != nil) == (rhs.photo.clientPenDrawingsJSON != nil)
        // ⚠️ pendingCut 은 Equatable 에 포함 X — @EnvironmentObject 자체 변화로 body 재호출됨
    }

    private var badgeFont: Font { .system(size: max(8, size * 0.065), weight: .bold) }
    private var imgH: CGFloat { size * 0.75 }

    var body: some View {
        VStack(spacing: 3) {
            AsyncThumbnailView(url: photo.displayURL)
                .frame(width: size, height: imgH)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cellCornerRadius, style: .continuous))
                .overlay(badgeOverlay, alignment: .topTrailing)
                .overlay(pickOverlay, alignment: .topLeading)
                .overlay(gradeOverlay, alignment: .bottomLeading)
                .overlay(sceneOverlay, alignment: .bottomTrailing)
                .overlay(developBadge, alignment: .bottom)
                .overlay(videoOverlay, alignment: .center)

            // File name
            // v8.6.2: 확장자 항상 표시 — RAW/JPG 구분이 중요 (CR3 vs JPG 등)
Text(photo.fileNameWithExtension)
                .font(.system(size: AppTheme.fontCaption))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundColor(.primary)
                .frame(width: size)

            // Star rating
            starsView
        }
        .padding(5)
        .background(cellBackground)
        .overlay(cellBorder)
        .overlay(selectionRing)
        // 잘라내기 상태면 opacity 낮춤 (시각 피드백)
        .opacity(store.pendingCutPhotoIDs.contains(photo.id) ? 0.45 : 1.0)
        .onHover { isHovered = $0 }
    }

    // MARK: - Badge overlays

    @ViewBuilder
    private var badgeOverlay: some View {
        if store.showFileTypeBadge {
            let badge = photo.fileTypeBadge
            let badgeColor: Color = badge.color == "orange" ? .orange :
                                    badge.color == "green" ? .green :
                                    badge.color == "purple" ? .purple :
                                    badge.color == "teal" ? .teal :
                                    badge.color == "gray" ? .gray : .blue
            VStack(alignment: .trailing, spacing: 2) {
                badgeText(badge.text, color: badgeColor)
                if photo.isCorrected {
                    badgeText("보정", color: AppTheme.correctedBadge)
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var pickOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            if photo.isGSelected {
                let isUploading = GSelectService.shared.currentlyUploading == photo.id
                HStack(spacing: 2) {
                    Text("G")
                        .font(.system(size: max(8, size * 0.07), weight: .black))
                    Image(systemName: isUploading ? "arrow.up.circle" : "checkmark.icloud.fill")
                        .font(.system(size: max(7, size * 0.06)))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.85))
                .cornerRadius(3)
                .padding(3)
            }
            if let labelColor = photo.colorLabel.color {
                Circle()
                    .fill(labelColor)
                    .frame(width: max(10, size * 0.07), height: max(10, size * 0.07))
                    .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
            }
            if !photo.comments.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: max(8, size * 0.07)))
                    Text("\(photo.comments.count)")
                        .font(.system(size: AppTheme.fontMicro, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.orange)
                .clipShape(Capsule())
            }
            if photo.isAIPick {
                badgeText("PICK", color: AppTheme.pickBadge)
            }
            // 🆕 고객 피드백 배지 — 셀렉/코멘트/펜 중 하나라도 있으면 표시
            if photo.clientSelected || !photo.clientComments.isEmpty || photo.clientPenDrawingsJSON != nil {
                HStack(spacing: 2) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: max(7, size * 0.06)))
                    Text(photo.clientName?.isEmpty == false ? (photo.clientName ?? "고객") : "고객")
                        .font(.system(size: max(7, size * 0.06), weight: .bold))
                    if photo.clientPenDrawingsJSON != nil {
                        Image(systemName: "pencil.tip")
                            .font(.system(size: max(7, size * 0.055)))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    LinearGradient(
                        colors: [.pink, .purple, .blue],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
            }
            if let fgID = photo.faceGroupID {
                HStack(spacing: 2) {
                    Image(systemName: "person.fill")
                        .font(.system(size: max(7, size * 0.06)))
                    Text("\(fgID + 1)")
                        .font(.system(size: max(7, size * 0.06), weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.85))
                .cornerRadius(3)
            }
        }
        .padding(4)
    }

    @ViewBuilder
    private var videoOverlay: some View {
        if photo.isVideoFile {
            ZStack {
                // Play icon center
                Image(systemName: "play.circle.fill")
                    .font(.system(size: max(20, size * 0.2)))
                    .foregroundColor(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.5), radius: 3)

                // Duration badge bottom-left
                if let dur = photo.videoDuration, dur > 0 {
                    VStack {
                        Spacer()
                        HStack {
                            Text(formatDuration(dur))
                                .font(.system(size: max(8, size * 0.065), weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.65))
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                .padding(4)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder
    private var gradeOverlay: some View {
        if let quality = photo.quality, quality.isAnalyzed {
            badgeText(quality.overallGrade.rawValue, color: AppTheme.gradeColor(quality.overallGrade))
                .padding(4)
        }
    }

    /// v8.6 — 비파괴 보정 적용된 사진 하단 중앙에 표시되는 배지
    @ViewBuilder
    private var developBadge: some View {
        let settings = developStore.get(for: photo.jpgURL)
        if !settings.isDefault {
            HStack(spacing: 3) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: max(8, size * 0.07), weight: .bold))
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .foregroundColor(.black)
            .background(
                Capsule().fill(Color(red: 1.0, green: 0.76, blue: 0.03))
            )
            .shadow(color: .black.opacity(0.4), radius: 2)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var sceneOverlay: some View {
        let tag = photo.aiCategory ?? photo.sceneTag
        if let tag = tag {
            HStack(spacing: 2) {
                Text(tag)
                    .font(.system(size: max(7, size * 0.06), weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                // AI score badge
                if let score = photo.aiScore {
                    Text("\(score)")
                        .font(.system(size: max(6, size * 0.05), weight: .bold, design: .monospaced))
                        .foregroundColor(score >= 80 ? .green : score >= 50 ? .yellow : .red)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(photo.aiCategory != nil ? Color.purple.opacity(0.6) : Color.black.opacity(0.5))
            .cornerRadius(2)
            .padding(4)
        }
    }

    private func badgeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var starsView: some View {
        let starSize = max(7, size * 0.06)
        return StarDisplayView(rating: photo.rating, size: max(8, starSize), compact: false)
            .frame(height: starSize + 4)
            .frame(minHeight: 20)
    }

    private var cellBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.cellCornerRadius + 2, style: .continuous)
            .fill(
                isFocused ? AppTheme.accent.opacity(0.35) :
                isSelected ? AppTheme.accent.opacity(0.22) :
                isHovered ? AppTheme.hoverBg :
                Color.clear
            )
    }

    private var hasStateBorder: Bool {
        photo.colorLabel != .none || photo.rating == 5
    }

    private var cellBorder: some View {
        // 고객 셀렉된 사진은 무지개 보더 (최우선). 기존 내 보더는 inner ring 으로 유지.
        if photo.clientSelected {
            return AnyView(
                RoundedRectangle(cornerRadius: AppTheme.cellCornerRadius + 2, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.pink, .purple, .blue, .cyan, .green, .yellow, .orange, .red],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 2.2
                    )
            )
        }

        let borderColor: Color = {
            if let labelColor = photo.colorLabel.color { return labelColor }
            // v8.7: ★5 테두리는 노란 레이블과 구분되는 오렌지 (ratingFiveBorder)
            if photo.rating == 5 { return AppTheme.ratingFiveBorder }
            if isFocused { return AppTheme.focusBorder }
            if isSelected { return AppTheme.selectionBorder.opacity(0.7) }
            return Color.clear
        }()
        let borderWidth: CGFloat = hasStateBorder || isFocused
            ? AppTheme.focusBorderWidth : AppTheme.cellBorderWidth
        return AnyView(
            RoundedRectangle(cornerRadius: AppTheme.cellCornerRadius + 2, style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        )
    }

    /// 별점/컬러라벨 보더가 이미 있는 경우, 그 안쪽에 선택/포커스 하이라이트 링을 추가 표시.
    @ViewBuilder
    private var selectionRing: some View {
        if hasStateBorder && (isFocused || isSelected) {
            RoundedRectangle(cornerRadius: AppTheme.cellCornerRadius, style: .continuous)
                .stroke(
                    isFocused ? AppTheme.focusBorder : AppTheme.selectionBorder.opacity(0.9),
                    lineWidth: isFocused ? 2.5 : 2
                )
                .padding(3.5)
        }
    }

}

// MARK: - List Row

struct ListRow: View {
    let photo: PhotoItem
    let isSelected: Bool
    let isFocused: Bool
    let thumbSize: CGFloat  // 썸네일 크기 (슬라이더 연동)
    @EnvironmentObject var store: PhotoStore
    @AppStorage("listColumns") private var listColumnsRaw: String = "date,size,type,rating"

    private var cols: Set<String> { Set(listColumnsRaw.split(separator: ",").map(String.init)) }

    // 헤더와 동일한 컬럼 폭 (드래그 조절 연동)
    @AppStorage("colW_name") private var cW_name: Double = 200
    @AppStorage("colW_date") private var cW_date: Double = 150
    @AppStorage("colW_size") private var cW_size: Double = 75
    @AppStorage("colW_type") private var cW_type: Double = 55
    @AppStorage("colW_rating") private var cW_rating: Double = 70
    @AppStorage("colW_resolution") private var cW_resolution: Double = 90
    @AppStorage("colW_camera") private var cW_camera: Double = 100
    @AppStorage("colW_iso") private var cW_iso: Double = 55
    @AppStorage("colW_shutter") private var cW_shutter: Double = 65
    @AppStorage("colW_aperture") private var cW_aperture: Double = 55
    @AppStorage("colW_lens") private var cW_lens: Double = 110

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy년 M월 d일 HH:mm"
        return f
    }()

    var body: some View {
        let c = cols
        let isFile = !photo.isFolder && !photo.isParentFolder
        let exif = photo.exifData
        let imgSize = max(20, min(thumbSize * 0.4, 60))  // 목록 썸네일 크기

        HStack(spacing: 0) {
            // 이름 (최소 150px 보장)
            HStack(spacing: 6) {
                Group {
                    if photo.isParentFolder {
                        Image(systemName: "chevron.up.circle.fill").font(.system(size: imgSize * 0.7)).foregroundColor(.blue)
                    } else if photo.isFolder {
                        Image(systemName: "folder.fill").font(.system(size: imgSize * 0.7)).foregroundColor(.blue)
                    } else {
                        AsyncThumbnailView(url: photo.displayURL)
                            .frame(width: imgSize, height: imgSize * 0.67)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
                .frame(width: imgSize, height: imgSize * 0.67)

                HStack(spacing: 3) {
                    // v8.6.2: 확장자 항상 표시 — RAW/JPG 구분이 중요 (CR3 vs JPG 등)
Text(photo.fileNameWithExtension)
                        .font(.system(size: 12)).lineLimit(1)
                    if isFile {
                        let badge = photo.fileTypeBadge
                        Text(badge.text).font(.system(size: 7, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(badgeColor(badge.color).opacity(0.8)).cornerRadius(2)
                    }
                    if photo.isSpacePicked {
                        Text("SP").font(.system(size: 7, weight: .black)).foregroundColor(.white)
                            .padding(.horizontal, 2).padding(.vertical, 1)
                            .background(AppTheme.error).cornerRadius(2)
                    }
                }
                Spacer(minLength: 4)
            }
            .frame(minWidth: 120)

            // 동적 컬럼 (세로 구분선 포함)
            if c.contains("date") {
                colDiv
                Text(isFile ? Self.dateFormatter.string(from: photo.fileModDate) : "--")
                    .font(.system(size: 11)).foregroundColor(.secondary).frame(width: cW_date, alignment: .leading)
            }
            if c.contains("size") {
                colDiv
                Text(isFile ? formatSize(photo.jpgFileSize + photo.rawFileSize) : "--")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).frame(width: cW_size, alignment: .trailing)
            }
            if c.contains("type") {
                colDiv
                Text(photo.isFolder ? "폴더" : photo.isParentFolder ? "" : photo.jpgURL.pathExtension.uppercased())
                    .font(.system(size: 11)).foregroundColor(.secondary).frame(width: cW_type, alignment: .center)
            }
            if c.contains("rating") {
                colDiv
                if photo.rating > 0 {
                    HStack(spacing: 0) {
                        ForEach(1...photo.rating, id: \.self) { _ in
                            Image(systemName: "star.fill").font(.system(size: 7)).foregroundColor(AppTheme.starGold)
                        }
                    }.frame(width: cW_rating)
                } else { Text("").frame(width: cW_rating) }
            }
            if c.contains("resolution") {
                colDiv
                Text(isFile && exif?.imageWidth != nil ? "\(exif!.imageWidth!)×\(exif!.imageHeight ?? 0)" : "")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: cW_resolution, alignment: .center)
            }
            if c.contains("camera") {
                colDiv
                Text(exif?.cameraModel ?? "").font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).frame(width: cW_camera, alignment: .leading)
            }
            if c.contains("iso") {
                colDiv
                Text(exif?.iso != nil ? "\(exif!.iso!)" : "").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: cW_iso, alignment: .trailing)
            }
            if c.contains("shutter") {
                colDiv
                Text(exif?.shutterSpeed ?? "").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: cW_shutter, alignment: .center)
            }
            if c.contains("aperture") {
                colDiv
                Text(exif?.aperture != nil ? String(format: "f/%.1f", exif!.aperture!) : "").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: cW_aperture, alignment: .center)
            }
            if c.contains("lens") {
                colDiv
                Text(exif?.lensModel ?? "").font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).frame(width: cW_lens, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, max(2, imgSize * 0.1))
        .background(
            isFocused ? AppTheme.accent.opacity(0.25) :
            isSelected ? AppTheme.accent.opacity(0.12) :
            Color.clear
        )
        .onAppear {
            // 목록뷰에서 보이는 행의 EXIF on-demand 로딩
            if isFile && photo.exifData == nil {
                store.loadExifIfNeeded(for: photo.id)
            }
        }
    }

    private var colDiv: some View {
        Divider().frame(height: 16).padding(.horizontal, 2).opacity(0.15)
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes <= 0 { return "--" }
        if bytes > 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        if bytes > 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private func badgeColor(_ color: String) -> Color {
        switch color {
        case "green": return .green; case "orange": return .orange
        case "blue": return .blue; case "purple": return .purple
        case "teal": return .teal; default: return .gray
        }
    }
}

// MARK: - Thumbnail Cache

class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var baseCountLimit: Int = 10000
    private var recoveryWork: DispatchWorkItem?  // 복원 작업 중첩 방지

    init() {
        applyCacheLimits()

        // 설정 변경 시 캐시 크기 재조정
        NotificationCenter.default.addObserver(forName: .init("SettingsChanged"), object: nil, queue: .main) { [weak self] _ in
            self?.applyCacheLimits()
        }

        // macOS 메모리 압박 감지 → 캐시 자동 축소 (전체 삭제 아닌 NSCache 자연 evict 유도)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            // 기존 복원 작업 취소 (중첩 방지)
            self.recoveryWork?.cancel()

            if event.contains(.critical) {
                let currentLimit = self.cache.countLimit
                self.cache.countLimit = max(200, currentLimit / 4)
                fputs("⚠️ [CACHE] CRITICAL memory pressure — countLimit \(currentLimit)→\(max(200, currentLimit/4)) (부분 해제)\n", stderr)
                // 5초 후 복원 (기존 1초 → OS가 안정될 시간 확보)
                let work = DispatchWorkItem { [weak self] in
                    self?.cache.countLimit = self?.baseCountLimit ?? currentLimit
                }
                self.recoveryWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            } else {
                let currentLimit = self.cache.countLimit
                self.cache.countLimit = max(500, currentLimit / 2)
                fputs("⚠️ [CACHE] WARNING memory pressure — countLimit \(currentLimit)→\(max(500, currentLimit/2))\n", stderr)
                // 8초 후 복원
                let work = DispatchWorkItem { [weak self] in
                    self?.cache.countLimit = self?.baseCountLimit ?? currentLimit
                }
                self.recoveryWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// UserDefaults 또는 SystemSpec tier 기반으로 캐시 크기 설정
    private func applyCacheLimits() {
        // UserDefaults의 thumbnailCacheMaxGB를 썸네일 countLimit 힌트로 사용
        let savedCacheGB = UserDefaults.standard.double(forKey: "thumbnailCacheMaxGB")

        // v8.6.1: cost 단위가 bytes 로 통일됨 → totalCostLimit 도 bytes.
        // 기존엔 `gbValue * 1024 * 1024` 가 KB 단위라고 주석에 쓰여있었지만 실제 저장은
        // bytes 상수 × 1,048,576 = MB 단위였음 → NSCache 가 사실상 무제한으로 쌓아 누수.
        if savedCacheGB > 0 {
            let gbValue = savedCacheGB
            cache.totalCostLimit = Int(gbValue * 1024 * 1024 * 1024)  // GB → bytes
            let count: Int
            if gbValue >= 2.0 { count = 20000 }
            else if gbValue >= 1.0 { count = 10000 }
            else if gbValue >= 0.5 { count = 5000 }
            else { count = 2000 }
            cache.countLimit = count
            baseCountLimit = count
        } else {
            let mb = SystemSpec.shared.thumbnailCacheMB()
            cache.totalCostLimit = mb * 1024 * 1024  // MB → bytes
            let count: Int
            switch SystemSpec.shared.effectiveTier {
            case .extreme: count = 20000
            case .high:    count = 10000
            case .standard: count = 5000
            case .low:     count = 2000
            }
            cache.countLimit = count
            baseCountLimit = count
        }
    }

    func get(_ url: URL) -> NSImage? {
        return cache.object(forKey: url as NSURL)
    }

    func set(_ url: URL, image: NSImage) {
        // v8.6.1 메모리 누수 수정: cost 단위를 **bytes** 로 통일 (이전엔 KB 단위로 저장되어
        // totalCostLimit 이 실제 값의 1/1024 로 오해되어 NSCache 자동 evict 가 사실상 작동 안 함).
        // applyCacheLimits() 에서 totalCostLimit 도 bytes 단위로 맞춰야 함.
        let cost: Int
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cost = max(1, cg.bytesPerRow * cg.height)
        } else {
            let pixelW = image.representations.first?.pixelsWide ?? Int(image.size.width)
            let pixelH = image.representations.first?.pixelsHigh ?? Int(image.size.height)
            cost = max(1, pixelW * pixelH * 4)
        }
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        // v8.6.2: CacheProgressGauge 용 — URL 유입 알림 (PhotoStore 에서 중복 카운트 방지)
        NotificationCenter.default.post(name: .thumbnailCacheInserted, object: url)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// v8.6.1: 사진 삭제 시 해당 URL 캐시 제거 (메모리 누수 방지)
    func remove(url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    /// v8.6.1: 메모리 압박 시 cost/count 상한 절반으로 축소 (즉시 evict 유도).
    func reduceCacheLimit() {
        cache.totalCostLimit = max(cache.totalCostLimit / 2, 256 * 1024 * 1024)  // 최소 256MB
        cache.countLimit = max(cache.countLimit / 2, 500)
    }

    /// 디버그용 — countLimit 과 totalCostLimit 만 확인 (NSCache.count 는 private)
    func debugCountAndLimit() -> (count: Int, limitMB: Int) {
        return (0, cache.totalCostLimit / 1024 / 1024)  // bytes → MB
    }
}

// MARK: - Concurrent Thumbnail Loader

class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    let queue = OperationQueue()
    private var pendingCallbacks: [URL: [(NSImage) -> Void]] = [:]
    private let lock = NSLock()
    var normalConcurrency: Int = 4

    init() {
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
    }

    /// 스크롤 시 대기 중인 작업 전부 취소 (보이는 셀만 새로 요청)
    func cancelPending() {
        queue.cancelAllOperations()
        lock.lock()
        pendingCallbacks.removeAll()
        lock.unlock()
    }

    /// 빠른 탐색 중 프리로딩 양보 (concurrency 낮추되 완전 중단은 안 함)
    func throttle() {
        queue.maxConcurrentOperationCount = 2
    }

    /// 탐색 멈추면 프리로딩 복구
    func unthrottle() {
        queue.maxConcurrentOperationCount = normalConcurrency
    }

    /// Auto-detect storage type for I/O optimization
    enum StorageType { case localSSD, externalSSD, externalHDD, sdCard, network }

    func optimizeForPath(_ path: String) {
        let type = detectStorageType(path)
        switch type {
        case .localSSD:
            isNetworkMode = false
            isExternalHDD = false
            // SystemSpec tier 기반 (M1 Pro 16GB = standard → 3)
            let c = SystemSpec.shared.ssdThumbnailConcurrency()
            queue.maxConcurrentOperationCount = c
            normalConcurrency = c
            AppLogger.log(.performance, "Local SSD: concurrency=\(c)")
        case .externalSSD:
            isNetworkMode = false
            isExternalHDD = false
            // 외장 SSD도 동일 tier 기반 캡 적용
            let c = SystemSpec.shared.ssdThumbnailConcurrency()
            queue.maxConcurrentOperationCount = c
            normalConcurrency = c
            AppLogger.log(.performance, "External SSD: concurrency=\(c)")
        case .externalHDD:
            isNetworkMode = false
            isExternalHDD = true
            // HDD NCQ 큐 깊이 활용 — 6-way까지 sustained throughput 증가 (8-way는 USB 외장에서 역효과)
            queue.maxConcurrentOperationCount = 6
            normalConcurrency = 6
            AppLogger.log(.performance, "External HDD: concurrency=6, thumbSize=160 for \(path)")
        case .sdCard:
            // SD카드: 랜덤 읽기 극도로 느림 → 직렬 처리 + 최소 썸네일
            isNetworkMode = false
            isExternalHDD = true  // slow disk 취급
            queue.maxConcurrentOperationCount = 1  // 직렬: 동시 읽기 시 속도 급락
            normalConcurrency = 1
            AppLogger.log(.performance, "SD Card: concurrency=1, thumbSize=120 for \(path)")
        case .network:
            isNetworkMode = true
            isExternalHDD = false
            // NAS 30-50MB/s 기준: 병목은 네트워크 대역폭
            // 4-way 가 최적 (8+ 은 NIC 포화, TCP retransmit → 오히려 느려짐)
            // 전제: 스테이지1 썸네일은 RAW 임베디드 JPEG (3-5MB) + 부분 읽기
            queue.maxConcurrentOperationCount = 4
            normalConcurrency = 4
            AppLogger.log(.performance, "NAS/Network: concurrency=4 (대역폭 보호), thumbSize=100 for \(path)")
        }
    }

    var isNetworkMode: Bool = false
    var isExternalHDD: Bool = false

    /// Check if path is on slow storage (HDD or NAS)
    var isSlowDisk: Bool {
        isNetworkMode || isExternalHDD
    }

    private func detectStorageType(_ path: String) -> StorageType {
        let url = URL(fileURLWithPath: path)

        // Check if network volume (authoritative — uses OS volume metadata)
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           let isLocal = values.volumeIsLocal, !isLocal {
            return .network
        }

        // Internal disk = SSD on modern Macs
        if !path.hasPrefix("/Volumes/") {
            return .localSSD
        }

        // External volume: SD카드 / HDD / SSD 판별
        let volumeName = url.pathComponents.count >= 3 ? url.pathComponents[2].lowercased() : ""

        // 1. SD카드 감지: URLResourceValues로 볼륨 속성 확인
        if let sdType = checkIfSDCard(volumeName: volumeName) {
            return sdType
        }

        // 2. SSD 힌트 (브랜드명)
        let ssdHints = ["ssd", "extreme", "samsung t", "sandisk extreme", "nvme", "thunderbolt", "portable ssd"]
        if ssdHints.contains(where: { volumeName.contains($0) }) {
            return .externalSSD
        }

        // 3. 용량 기반 추정: 64GB 이하만 SD카드/USB stick 확정
        let mountPoint = "/Volumes/" + (url.pathComponents.count >= 3 ? url.pathComponents[2] : "")
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: mountPoint),
           let totalSize = attrs[.systemSize] as? Int64 {
            let sizeGB = totalSize / (1024 * 1024 * 1024)
            if sizeGB <= 64 {
                return .sdCard
            }
        }

        // 4. 대용량 외장 — 2024+ 기준 대부분 SSD. HDD 로 과도 추정하면 썸네일/미리보기 느려짐 → SSD 로 가정
        fputs("[STORAGE] 불명 대용량 외장 → externalSSD 로 가정: \(volumeName)\n", stderr)
        return .externalSSD
    }

    /// SD카드 / USB 메모리 감지 — URLResourceValues로 볼륨 속성 확인
    private func checkIfSDCard(volumeName: String) -> StorageType? {
        // 이름 기반 빠른 판별
        let sdHints = ["sd card", "micro sd", "sdxc", "sdhc", "sduc", "memory card",
                        "untitled", "no name", "eos_digital", "nikon", "canon",
                        "dcim", "sony"]  // 카메라 메모리카드 기본 이름들
        if sdHints.contains(where: { volumeName.contains($0) }) {
            return .sdCard
        }

        // URLResourceValues 로 볼륨 용량 확인 (App Sandbox 호환)
        let mountPoint = URL(fileURLWithPath: "/Volumes/" + volumeName)
        do {
            let resourceValues = try mountPoint.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey
            ])

            // 볼륨 이름으로 추가 SD카드 힌트 확인
            let volName = (resourceValues.volumeName ?? volumeName).lowercased()
            if sdHints.contains(where: { volName.contains($0) }) {
                fputs("[STORAGE] SD Card detected via volumeName: \(volumeName)\n", stderr)
                return .sdCard
            }

            // 용량 기반: 64GB 이하만 SD카드/USB stick 확정
            // (≤256GB 는 SSD 가능성 충분 → nil 반환해서 caller 가 SSD 힌트/벤치마크로 판정)
            if let totalBytes = resourceValues.volumeTotalCapacity {
                let gb = Double(totalBytes) / 1_000_000_000
                if gb <= 64 {
                    fputs("[STORAGE] Small volume (\(String(format: "%.0f", gb))GB) treated as SD: \(volumeName)\n", stderr)
                    return .sdCard
                }
                // 65GB~ → nil (외장 SSD 가능성 → caller 가 SSD 힌트 검사)
            }
        } catch {
            // URLResourceValues 실패 → nil 반환, 다른 방법으로 판별
        }

        return nil
    }

    /// Cancel all pending operations (call when scrolling fast to prioritize new visible cells)
    func cancelAll() {
        queue.cancelAllOperations()
        lock.lock()
        pendingCallbacks.removeAll()
        lock.unlock()
    }

    /// Get file modification date for disk cache key
    private static func fileModDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date.distantPast
    }

    /// v8.6.2: CacheSweeper 용 동기 생성. 디스크 캐시까지 채움.
    /// 이미 캐시에 있으면 즉시 리턴 (추가 I/O 없음).
    @discardableResult
    func generateThumbnailSync(url: URL) -> NSImage? {
        if ThumbnailCache.shared.get(url) != nil { return nil }
        if DiskThumbnailCache.shared.getByPath(url: url) != nil {
            // 디스크에 있지만 메모리 캐시엔 없음 → 메모리에만 채우고 종료 (sweep 주 목적)
            return nil
        }
        // 실제 추출 (feed-forward 경로와 동일 extractThumbnail)
        let img = Self.extractThumbnailFast(url: url) ?? Self.extractThumbnail(url: url)
        guard let raw = img else { return nil }
        // v8.6.2: 사용자 회전 override 적용
        let deg = PhotoStore.rotationOverrideCW(for: url)
        let image = deg == 0 ? raw : RotationService.rotateImage(raw, degreesCW: deg)
        ThumbnailCache.shared.set(url, image: image)
        let modDate = Self.fileModDate(url)
        DiskThumbnailCache.shared.set(url: url, modDate: modDate, image: image)
        return image
    }

    func load(url: URL, completion: @escaping (NSImage) -> Void) {
        // 1. Memory cache hit → return directly
        if let cached = ThumbnailCache.shared.get(url) {
            AppLogger.log(.cache, "thumbnail cache HIT: \(url.lastPathComponent)")
            completion(cached)
            return
        }
        // 2. Disk cache hit → path-only lookup (no stat() — 메인스레드 블로킹 방지)
        if let diskCached = DiskThumbnailCache.shared.getByPath(url: url) {
            ThumbnailCache.shared.set(url, image: diskCached)
            completion(diskCached)
            return
        }

        // 3. Need to extract from file — queue it
        lock.lock()
        // Double-check: 다른 스레드가 lock 대기 중 캐시에 저장했을 수 있음
        if let cached = ThumbnailCache.shared.get(url) {
            lock.unlock()
            completion(cached)
            return
        }
        if pendingCallbacks[url] != nil {
            pendingCallbacks[url]?.append(completion)
            lock.unlock()
            return
        }
        pendingCallbacks[url] = [completion]

        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            // background queue worker thread 는 main autorelease pool 과 별개 → 명시적 pool 필수
            // 없으면 ThumbnailCache 가 evict 해도 CGImageSource/NSImage 가 thread-local pool 에 누적되어
            // key repeat 꾹 누르기 중 RAM 이 GB 단위로 증가함
            autoreleasepool {
            guard let op = op, !op.isCancelled else { return }
            let isNAS = ThumbnailLoader.shared.isNetworkMode
            let isHDD = ThumbnailLoader.shared.isExternalHDD

            // For NAS/HDD: skip expensive stat() — use path-only lookup
            let modDate: Date
            if isNAS || isHDD {
                modDate = Date.distantPast
            } else {
                modDate = Self.fileModDate(url)
            }

            // 2. Disk cache hit → load from disk, populate memory cache
            let diskCached = (isNAS || isHDD)
                ? DiskThumbnailCache.shared.getByPath(url: url)
                : DiskThumbnailCache.shared.get(url: url, modDate: modDate)
            if let diskCached = diskCached {
                AppLogger.log(.cache, "disk cache HIT: \(url.lastPathComponent)")
                ThumbnailCache.shared.set(url, image: diskCached)

                self?.lock.lock()
                let callbacks = self?.pendingCallbacks.removeValue(forKey: url) ?? []
                self?.lock.unlock()

                DispatchQueue.main.async {
                    for cb in callbacks { cb(diskCached) }
                }
                return
            }

            // 3. Extract from file — check cancel before expensive I/O
            guard !op.isCancelled else { return }

            let thumbStart = CFAbsoluteTimeGetCurrent()
            var image: NSImage?

            if isHDD || isNAS {
                // HDD/NAS 최적화: EXIF 임베디드 썸네일만 (전체 RAW 디코딩 금지)
                image = Self.extractThumbnailFast(url: url)
                // Fast 실패 시에만 일반 추출 (JPG는 빠르므로 OK, RAW는 스킵)
                if image == nil && !FileMatchingService.rawExtensions.contains(url.pathExtension.lowercased()) {
                    image = Self.extractThumbnail(url: url)
                }
            } else {
                image = Self.extractThumbnail(url: url)
            }

            let extractElapsed = (CFAbsoluteTimeGetCurrent() - thumbStart) * 1000
            if extractElapsed > 5 {
                fputs("[THUMB] \(url.lastPathComponent) \(Int(extractElapsed))ms\n", stderr)
            }

            // v8.6.2: 사용자 회전 override 적용
            if let raw = image {
                let deg = PhotoStore.rotationOverrideCW(for: url)
                image = deg == 0 ? raw : RotationService.rotateImage(raw, degreesCW: deg)
            }

            if let image = image {
                // Memory cache: immediate (needed for UI)
                ThumbnailCache.shared.set(url, image: image)
                // Disk cache: HDD/NAS에서는 읽기 완료 후 배치로 저장 (I/O 경합 방지)
                if isHDD || isNAS {
                    // v8.6.1: append 도 lock 안에서 (worker thread 다수가 동시에 append 하면
                    // Array realloc 중 race → 크래시)
                    Self.diskCacheWriteLock.lock()
                    Self.pendingDiskCacheWrites.append((url, image))
                    Self.diskCacheWriteLock.unlock()
                    Self.flushDiskCacheIfNeeded()
                } else {
                    DispatchQueue.global(qos: .utility).async {
                        DiskThumbnailCache.shared.set(url: url, modDate: modDate, image: image)
                    }
                }
            }

            // 콜백 정리 + 실행
            self?.lock.lock()
            let callbacks = self?.pendingCallbacks.removeValue(forKey: url) ?? []
            self?.lock.unlock()

            // 취소된 경우 콜백 호출 안함 (placeholder 생성도 방지)
            guard !op.isCancelled, let image = image else { return }
            DispatchQueue.main.async {
                for cb in callbacks { cb(image) }
            }
            } // autoreleasepool 닫기
        }
        queue.addOperation(op)
        lock.unlock()
    }

    // MARK: - HDD 배치 디스크 캐시 저장 (I/O 경합 방지)
    private static var pendingDiskCacheWrites: [(URL, NSImage)] = []
    private static let diskCacheWriteLock = NSLock()
    private static var diskCacheFlushScheduled = false

    private static func flushDiskCacheIfNeeded() {
        diskCacheWriteLock.lock()
        let count = pendingDiskCacheWrites.count
        if count >= 10 {
            let batch = Array(pendingDiskCacheWrites)  // 강한 참조 복사
            pendingDiskCacheWrites.removeAll(keepingCapacity: true)
            diskCacheWriteLock.unlock()
            DispatchQueue.global(qos: .background).async {
                autoreleasepool {
                    for (url, img) in batch {
                        let mod = fileModDate(url)
                        DiskThumbnailCache.shared.set(url: url, modDate: mod, image: img)
                    }
                }
            }
        } else if !diskCacheFlushScheduled {
            diskCacheFlushScheduled = true
            diskCacheWriteLock.unlock()
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) {
                diskCacheWriteLock.lock()
                let batch = Array(pendingDiskCacheWrites)
                pendingDiskCacheWrites.removeAll(keepingCapacity: true)
                diskCacheFlushScheduled = false
                diskCacheWriteLock.unlock()
                autoreleasepool {
                    for (url, img) in batch {
                        let mod = fileModDate(url)
                        DiskThumbnailCache.shared.set(url: url, modDate: mod, image: img)
                    }
                }
            }
        } else {
            diskCacheWriteLock.unlock()
        }
    }

    // MARK: - HDD 고속 EXIF 썸네일 추출

    /// EXIF 임베디드 썸네일 우선 추출 — 파일 헤더만 읽어서 빠름 (HDD에서 10~50ms vs 전체 디코딩 200~500ms)
    private static func extractThumbnailFast(url: URL) -> NSImage? {
        let ext = url.pathExtension.lowercased()

        // 이미지 파일만 처리
        guard allKnownExtensions.contains(ext),
              !FileMatchingService.videoExtensions.contains(ext) else { return nil }

        let isRAW = FileMatchingService.rawExtensions.contains(ext)

        // CGImageSource로 EXIF 임베디드 썸네일만 추출 (CreateThumbnailFromImageAlways = false)
        let srcOpts: [NSString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else { return nil }

        // 메인 이미지 EXIF orientation 읽기 (RAW 썸네일에 orientation이 없을 수 있음)
        let mainOrientation: Int
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let orient = props[kCGImagePropertyOrientation as String] as? Int {
            mainOrientation = orient
        } else {
            mainOrientation = 1  // normal
        }

        // 임베디드 썸네일만 시도 (파일 전체 디코딩 안 함)
        let embedOpts: [NSString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: thumbSize,
            kCGImageSourceCreateThumbnailFromImageAlways: false,    // 임베디드만
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,  // 없으면 생성 안 함
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]

        // 모든 서브이미지 확인 (RAW는 최대 5개까지 — 임베디드 JPEG이 뒤에 있을 수 있음)
        let count = CGImageSourceGetCount(source)
        let maxIdx = isRAW ? min(count, 5) : min(count, 3)
        for idx in 0..<maxIdx {
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, idx, embedOpts as CFDictionary) {
                if cg.width >= 80 && cg.height >= 80 {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    // v8.8.0 fix: NEF 등 일부 RAW 는 임베디드 preview 에 orientation 정보가 없어
                    //   kCGImageSourceCreateThumbnailWithTransform 이 회전을 적용 못 함.
                    //   메인 파일의 orientation (5-8 = 90°/270° rotated) 이고 thumb 이 landscape 면
                    //   실제 display 는 portrait 이어야 하므로 수동 회전.
                    if isRAW && (mainOrientation >= 5 && mainOrientation <= 8) {
                        let thumbLandscape = cg.width > cg.height
                        if thumbLandscape, let rotated = applyOrientation(img, orientation: mainOrientation) {
                            return rotated
                        }
                    }
                    return img
                }
            }
        }

        // RAW: 파일 헤더에서 임베디드 JPEG 직접 추출 (전체 디코딩 회피)
        if isRAW {
            if let img = extractEmbeddedJPEG(url: url, maxSize: thumbSize) {
                // 임베디드 JPEG에 orientation이 없을 수 있으므로 메인 EXIF orientation 적용
                if mainOrientation > 1, let oriented = applyOrientation(img, orientation: mainOrientation) {
                    return oriented
                }
                return img
            }
        }

        return nil  // 임베디드 없음 → 풀 디코딩으로 폴백
    }

    /// EXIF orientation 값을 NSImage에 적용 (CIImage 기반 — 모든 orientation 정확 처리)
    private static func applyOrientation(_ image: NSImage, orientation: Int) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // CGImagePropertyOrientation → CIImage orientation 매핑
        let ciOrientation: CGImagePropertyOrientation
        switch orientation {
        case 2: ciOrientation = .upMirrored
        case 3: ciOrientation = .down
        case 4: ciOrientation = .downMirrored
        case 5: ciOrientation = .leftMirrored
        case 6: ciOrientation = .right
        case 7: ciOrientation = .rightMirrored
        case 8: ciOrientation = .left
        default: return nil
        }
        let ci = CIImage(cgImage: cgImage).oriented(ciOrientation)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let outCG = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: outCG, size: NSSize(width: outCG.width, height: outCG.height))
    }

    private static var thumbSize: Int {
        // Smaller thumbnails = faster I/O + less memory
        let loader = ThumbnailLoader.shared
        if loader.queue.maxConcurrentOperationCount == 1 { return 90 }   // SD카드
        if loader.isSlowDisk { return 100 }  // HDD/NAS
        return 140                            // SSD
    }

    private static let allKnownExtensions: Set<String> = {
        FileMatchingService.jpgExtensions
            .union(FileMatchingService.rawExtensions)
            .union(FileMatchingService.imageExtensions)
            .union(FileMatchingService.videoExtensions)
    }()

    private static func extractThumbnail(url: URL) -> NSImage? {
        let ext = url.pathExtension.lowercased()

        // Generic files: use system icon
        if !allKnownExtensions.contains(ext) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: thumbSize, height: thumbSize)
            return icon
        }

        // Video files: use AVAssetImageGenerator
        if FileMatchingService.videoExtensions.contains(ext) {
            return FileMatchingService.generateVideoThumbnail(url: url)
        }

        let isRAW = FileMatchingService.rawExtensions.contains(ext)

        // NAS fast path: RAW 파일의 앞쪽 4MB 만 읽어서 임베디드 JPEG 추출
        // (전체 파일 다운로드 회피 → 30-50MB/s 링크에서 10배 이상 빠름)
        if isRAW && ThumbnailLoader.shared.isNetworkMode {
            if let cgImage = NASOptimizedReader.extractRAWThumbnail(url: url, maxPixel: CGFloat(thumbSize)) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            // 실패 시 일반 경로로 폴백 (아래)
        }

        // CGImageSource path FIRST — handles EXIF orientation automatically via Transform flag
        let srcOpts: [NSString: Any] = [kCGImageSourceShouldCache: false]
        if let source = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) {
            let imageCount = CGImageSourceGetCount(source)

            if isRAW {
                // RAW Step 1: Try existing embedded thumbnail via CGImageSource (orientation auto-applied)
                let embedOpts: [NSString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: thumbSize,
                    kCGImageSourceCreateThumbnailFromImageAlways: false,
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceShouldCache: false
                ]
                for idx in 0..<imageCount {
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, idx, embedOpts as CFDictionary) {
                        if cgImage.width >= 50 && cgImage.height >= 50 {
                            let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                            return PhotoPreviewView.correctThumbnailOrientationIfNeeded(img, source: source)
                        }
                    }
                }

                // RAW Step 2: Generate thumbnail with subsample (orientation auto-applied)
                let genOpts: [NSString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: thumbSize,
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceSubsampleFactor: 8,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceShouldCache: false
                ]
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, genOpts as CFDictionary) {
                    let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    return PhotoPreviewView.correctThumbnailOrientationIfNeeded(img, source: source)
                }
            }
        }

        // RAW Step 3: Embedded JPEG extraction (last resort — for unsupported RAW formats)
        if isRAW {
            if let img = extractEmbeddedJPEG(url: url, maxSize: thumbSize) {
                return img
            }
            return nil
        }

        // JPG/PNG path
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else {
            return nil
        }

        if !isRAW {
            // JPG/PNG: use SubsampleFactor for 2-4x faster JPEG decode
            // SubsampleFactor: 2 = 1/2 size decode, 4 = 1/4 size decode
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            let origW = props?[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let origH = props?[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            let origMax = max(origW, origH)

            // Calculate optimal subsample factor
            var subsample = 1
            if origMax > thumbSize * 8 { subsample = 8 }
            else if origMax > thumbSize * 4 { subsample = 4 }
            else if origMax > thumbSize * 2 { subsample = 2 }

            var options: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: thumbSize,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false
            ]
            if subsample > 1 {
                options[kCGImageSourceSubsampleFactor as NSString] = subsample
            }

            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                return PhotoPreviewView.correctThumbnailOrientationIfNeeded(img, source: source)
            }
        }

        return nil
    }

    /// Extract embedded JPEG from RAW files that macOS can't decode (e.g., Nikon Z8/Z9 High Efficiency)
    /// Scans for FFD8 JPEG markers and returns the best-sized embedded preview.
    /// Uses tiered read: 512KB first (covers most thumbnails), then 3MB if needed.
    private static func extractEmbeddedJPEG(url: URL, maxSize: Int) -> NSImage? {
        let isNAS = ThumbnailLoader.shared.isNetworkMode

        // Tiered read: small read first, expand only if no JPEG found
        // Most RAW embedded thumbnails live within the first 200-500KB
        let firstReadSize = isNAS ? 512_000 : 1_000_000
        let maxReadSize = isNAS ? 1_500_000 : 3_000_000

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { return nil }

        var data = handle.readData(ofLength: firstReadSize)
        guard data.count > 100 else { handle.closeFile(); return nil }

        // Scan for FFD8 markers
        if let img = findBestEmbeddedJPEG(in: data, maxSize: maxSize) {
            handle.closeFile()
            return img
        }

        // First read had no usable JPEG — read more (only if not NAS-constrained or needed)
        if data.count >= firstReadSize && maxReadSize > firstReadSize {
            let moreData = handle.readData(ofLength: maxReadSize - firstReadSize)
            if !moreData.isEmpty {
                data.append(moreData)
                handle.closeFile()
                return findBestEmbeddedJPEG(in: data, maxSize: maxSize)
            }
        }

        handle.closeFile()
        return nil
    }

    /// Find best embedded JPEG in data by scanning for FFD8 markers (parallel)
    private static func findBestEmbeddedJPEG(in data: Data, maxSize: Int) -> NSImage? {
        // Use parallel scanner for finding FFD8 markers
        let offsets = ParallelFFD8Scanner.findMarkers(in: data, maxMarkers: 8)
        guard !offsets.isEmpty else { return nil }

        var bestImage: NSImage?
        var bestSize = 0

        for offset in offsets {
            let end = min(offset + 1_500_000, data.count)
            let subData = data.subdata(in: offset..<end)
            guard let imgSource = CGImageSourceCreateWithData(subData as CFData, nil),
                  CGImageSourceGetCount(imgSource) > 0 else { continue }

            let thumbOpts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(imgSource, 0, thumbOpts as CFDictionary) {
                let size = cgImage.width * cgImage.height
                if size > bestSize {
                    bestSize = size
                    bestImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    if cgImage.width >= maxSize { return bestImage }
                }
            }
        }

        return bestImage
    }
}

// MARK: - Async Thumbnail View

struct AsyncThumbnailView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var loadedURL: URL?
    @State private var retryCount: Int = 0
    /// v8.6.2: 회전 이벤트 리스닝용 — 회전 시 캐시 무효화 + 재로드 트리거
    static let rotationInvalidateNotification = Notification.Name("com.pickshot.rotation.invalidate")
    /// 고속 concurrent 큐 — 디스크 캐시 + 임베디드 추출 병렬
    static let thumbConcurrentQueue = DispatchQueue(label: "com.pickshot.thumb.fast", qos: .userInteractive, attributes: .concurrent)
    /// v8.6.2: I/O 스파이크 방지 — 동시 디스크 읽기 최대 4개로 제한.
    ///   빠른 필름스트립 스크롤 시 20+ 셀 동시 로드 → 디스크 스파이크 현상 억제.
    static let thumbIOSemaphore = DispatchSemaphore(value: 4)

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
            }
        }
        .onAppear {
            if image == nil {
                loadThumbnail()
            } else if loadedURL != url {
                loadThumbnail()
            }
        }
        .onChange(of: url) { _, newURL in
            if loadedURL != newURL {
                loadThumbnail()
            }
        }
        .onChange(of: retryCount) { _, _ in
            // 재시도 트리거
            if image == nil {
                loadThumbnail()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.rotationInvalidateNotification)) { note in
            // v8.6.2: 회전된 파일이 이 셀의 URL 이면 강제 재로드
            if let rotatedURL = note.object as? URL, rotatedURL == self.url {
                self.image = nil
                self.loadedURL = nil
                loadThumbnail()
            }
        }
    }

    private func loadThumbnail() {
        loadedURL = url
        retryCount = 0
        let currentURL = url

        // 1. 메모리 캐시 히트 → 즉시
        if let cached = ThumbnailCache.shared.get(currentURL) {
            self.image = cached
            return
        }

        // 2. 디스크 캐시 히트 → 동기 (O(1) Dictionary 룩업, < 0.01ms)
        if let disk = DiskThumbnailCache.shared.getByPath(url: currentURL) {
            ThumbnailCache.shared.set(currentURL, image: disk)
            self.image = disk
            return
        }

        // 3~4. 임베디드 + 생성 — 백그라운드 (semaphore 로 동시성 4개 제한 → I/O 스파이크 방지)
        Self.thumbConcurrentQueue.async {
            Self.thumbIOSemaphore.wait()
            defer { Self.thumbIOSemaphore.signal() }

            // 빠른 스크롤로 이미 다른 URL 로 바뀌었으면 작업 skip
            guard self.loadedURL == currentURL else { return }

            // 3. 임베디드 썸네일 (파일 헤더, < 1ms)
            let srcOpts: [NSString: Any] = [kCGImageSourceShouldCache: false]
            if let source = CGImageSourceCreateWithURL(currentURL as CFURL, srcOpts as CFDictionary),
               let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true
               ] as CFDictionary),
               cgThumb.width >= 30 {
                let raw = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
                // v8.6.2: 사용자 회전 override 적용
                let deg = PhotoStore.rotationOverrideCW(for: currentURL)
                let ns = deg == 0 ? raw : RotationService.rotateImage(raw, degreesCW: deg)
                ThumbnailCache.shared.set(currentURL, image: ns)
                RunLoop.main.perform(inModes: [.common]) {
                    guard self.loadedURL == currentURL else { return }
                    self.image = ns
                }
                // 고화질 교체 (백그라운드)
                ThumbnailLoader.shared.load(url: currentURL) { img in
                    RunLoop.main.perform(inModes: [.common]) {
                        if self.loadedURL == currentURL, img.size.width > 2 {
                            self.image = img
                        }
                    }
                }
                return
            }
            // 임베디드 없음 → 생성
            ThumbnailLoader.shared.load(url: currentURL) { img in
                RunLoop.main.perform(inModes: [.common]) {
                    if self.loadedURL == currentURL {
                        if img.size.width > 2 {
                            self.image = img
                        } else if self.retryCount < 3 {
                            // 실패 시 재시도 (최대 3회, 점진적 딜레이)
                            let delay = 0.1 * Double(self.retryCount + 1)
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                self.retryCount += 1
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Multi-File Drag (NSView-based, bypasses SwiftUI single-item limitation)

struct MultiFileDragView: NSViewRepresentable {
    let photo: PhotoItem
    let store: PhotoStore

    func makeNSView(context: Context) -> DragOverlayNSView {
        let view = DragOverlayNSView()
        view.photo = photo
        view.store = store
        return view
    }

    func updateNSView(_ nsView: DragOverlayNSView, context: Context) {
        nsView.photo = photo
        nsView.store = store
    }

    class DragOverlayNSView: NSView {
        var photo: PhotoItem?
        var store: PhotoStore?
        private var mouseDownPoint: NSPoint?
        private var didStartDrag = false

        override var acceptsFirstResponder: Bool { false }

        /// v8.6.2: hitTest 를 실제 클릭 이벤트 처리 중이 아닐 때는 nil 로 돌려서
        /// SwiftUI `.help()` tooltip / onHover 가 뒷 뷰에 정상 dispatch 되도록.
        /// mouse down 이후 드래그 추적 중에만 self 를 반환해서 이벤트 라우팅을 유지.
        override func hitTest(_ point: NSPoint) -> NSView? {
            // 현재 클릭/드래그 추적 중이거나, 현재 이벤트가 mouseDown 이면 이 뷰가 받음.
            if mouseDownPoint != nil { return self }
            if NSApp.currentEvent?.type == .leftMouseDown {
                return self
            }
            // hover / mouseMoved / tooltip / rightMouseDown(→ contextMenu) 은 모두 SwiftUI 로 투과.
            return nil
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = event.locationInWindow
            didStartDrag = false
            nextResponder?.mouseDown(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownPoint = nil
            didStartDrag = false
            nextResponder?.mouseUp(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !didStartDrag, let startPoint = mouseDownPoint else {
                nextResponder?.mouseDragged(with: event)
                return
            }

            let current = event.locationInWindow
            let distance = hypot(current.x - startPoint.x, current.y - startPoint.y)

            guard distance > 8 else {
                nextResponder?.mouseDragged(with: event)
                return
            }

            didStartDrag = true
            mouseDownPoint = nil

            guard let store = store, let photo = photo else { return }
            // parentFolder(상위 폴더 네비게이션) 만 제외. 일반 폴더는 드래그 허용.
            guard !photo.isParentFolder else { return }

            // v8.6.2: 드래그 시작 즉시 선택 반영 — 미선택 사진을 잡고 드래그 시작해도
            // 바로 선택 하이라이트가 켜지고 드래그 미리보기에도 반영됨.
            if !store.selectedPhotoIDs.contains(photo.id) {
                store.selectPhoto(photo.id, cmdKey: false, shiftKey: false)
            }

            // Collect all selected file/folder URLs
            // ⚠️ 영상 .xmp 사이드카는 드래그에 포함 안 함 — 편집툴이 별도 파일로 오해해서 import 실패
            let ids = store.selectedPhotoIDs.contains(photo.id) ? store.selectedPhotoIDs : [photo.id]
            var fileURLs: [URL] = []
            for id in ids {
                guard let idx = store._photoIndex[id], idx < store.photos.count else { continue }
                let p = store.photos[idx]
                if p.isParentFolder { continue }
                if p.isFolder {
                    // 폴더 자체 드래그 (이동)
                    fileURLs.append(p.jpgURL)
                } else {
                    fileURLs.append(p.jpgURL)
                    if let rawURL = p.rawURL, rawURL != p.jpgURL { fileURLs.append(rawURL) }
                }
            }
            guard !fileURLs.isEmpty else { return }

            // 드래그 아이템 — 파일마다 독립 pasteboard item 으로 추가
            // (한 item 에 하나의 fileURL 만 가능 → 여러 파일은 items 배열로)
            var items: [NSDraggingItem] = []
            for (index, url) in fileURLs.enumerated() {
                let pb = NSPasteboardItem()
                pb.setString(url.absoluteString, forType: .fileURL)
                // photo ID 는 첫 번째 item 에만 (내부 리오더용)
                if index == 0 {
                    pb.setString(photo.id.uuidString, forType: .string)
                }
                let di = NSDraggingItem(pasteboardWriter: pb)
                items.append(di)
            }
            // 드래그 프리뷰는 첫 번째 아이템에 붙이기 위해 인용
            let dragItem = items[0]

            // 드래그 미리보기: 썸네일 이미지 (80x80) + 선택 개수 배지
            let previewSize: CGFloat = 80
            let dragImage: NSImage
            // ⚠️ 영상 파일엔 NSImage(contentsOf:) 쓰지 말 것 — main 에서 전체 디코딩 시도 → 무한 멈춤
            // 영상은 DiskThumbnailCache 또는 메모리 ThumbnailCache 만 사용
            // v8.6.2: NSImage(contentsOf:) 메인 스레드 블로킹 제거
            //   → 캐시 miss 면 그냥 시스템 파일 아이콘 사용 (드래그 시작을 절대 막지 않음)
            let loadedThumb: NSImage? =
                DiskThumbnailCache.shared.getByPath(url: photo.jpgURL)
                ?? ThumbnailCache.shared.get(photo.jpgURL)
            if let thumbImage = loadedThumb {
                // 리사이즈
                let resized = NSImage(size: NSSize(width: previewSize, height: previewSize))
                resized.lockFocus()
                NSGraphicsContext.current?.imageInterpolation = .high
                let ratio = min(previewSize / thumbImage.size.width, previewSize / thumbImage.size.height)
                let drawW = thumbImage.size.width * ratio
                let drawH = thumbImage.size.height * ratio
                thumbImage.draw(in: NSRect(x: (previewSize - drawW) / 2, y: (previewSize - drawH) / 2,
                                           width: drawW, height: drawH))

                // 다중 선택 배지
                if ids.count > 1 {
                    let badge = "\(ids.count)"
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                        .foregroundColor: NSColor.white
                    ]
                    let badgeSize = (badge as NSString).size(withAttributes: attrs)
                    let badgeW = max(20, badgeSize.width + 8)
                    let badgeRect = NSRect(x: previewSize - badgeW - 2, y: previewSize - 18, width: badgeW, height: 16)
                    NSColor.systemBlue.setFill()
                    NSBezierPath(roundedRect: badgeRect, xRadius: 8, yRadius: 8).fill()
                    (badge as NSString).draw(at: NSPoint(x: badgeRect.midX - badgeSize.width / 2,
                                                         y: badgeRect.midY - badgeSize.height / 2),
                                             withAttributes: attrs)
                }
                resized.unlockFocus()
                dragImage = resized
            } else {
                dragImage = NSWorkspace.shared.icon(forFile: fileURLs.first?.path ?? "")
            }

            // ⚠️ 모든 NSDraggingItem 에 draggingFrame 필수 — 없으면 크래시
            // 첫 번째 아이템만 실제 썸네일 이미지, 나머지(.xmp, RAW 등)는 1x1 투명 프레임
            dragItem.setDraggingFrame(
                NSRect(x: 0, y: 0, width: previewSize, height: previewSize),
                contents: dragImage
            )
            // 나머지 아이템: 같은 이미지로 설정하되 offset 을 다르게 (시각적 중복 최소화)
            // contents 는 NSImage 공유해도 ARC 로 관리됨.
            for i in 1..<items.count {
                items[i].setDraggingFrame(
                    NSRect(x: 0, y: 0, width: previewSize, height: previewSize),
                    contents: nil  // 추가 파일은 프리뷰 없이 빈 프레임
                )
            }

            beginDraggingSession(with: items, event: event, source: self)
        }
    }
}

extension MultiFileDragView.DragOverlayNSView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async {
            DragDropState.shared.dropTargetID = nil
        }
    }
}

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
                         tileView.selectedIDs != store.selectedPhotoIDs ||
                         tileView.pendingCutPhotoIDs != store.pendingCutPhotoIDs
        if selChanged {
            tileView.selectedID = store.selectedPhotoID
            tileView.selectedIDs = store.selectedPhotoIDs
            tileView.pendingCutPhotoIDs = store.pendingCutPhotoIDs
            tileView.updateSelectionOnly()
            // cut 상태 변화 반영 — visibleTiles opacity 일괄 갱신
            tileView.updateVisibleTiles()
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
    /// 잘라내기 대기 중인 사진 ID — 타일 opacity 낮춰 표시
    var pendingCutPhotoIDs: Set<UUID> = []
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

            let cutFlag = pendingCutPhotoIDs.contains(photo.id)
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
                // cut 상태 변화 반영
                let targetOpacity: Float = cutFlag ? 0.45 : 1.0
                if abs(tile.opacity - targetOpacity) > 0.01 {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    tile.opacity = targetOpacity
                    CATransaction.commit()
                }
            } else {
                let tile = recyclePool.popLast() ?? TileLayer()
                tile.frame = tileFrame
                tile.configure(
                    photo: photo,
                    size: thumbSize,
                    isSelected: selectedIDs.contains(photo.id),
                    isFocused: selectedID == photo.id,
                    isPendingCut: cutFlag
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

    private var scrollPrefetchWork: DispatchWorkItem?

    @objc func scrollChanged() {
        updateVisibleTiles()

        // 스크롤 멈춤 감지 debounce → visible ±5행 prefetch
        // 키보드 이동(PhotoStore.prefetchNearbyThumbnails ±30장)과 동등한 UX 제공
        scrollPrefetchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.prefetchAroundVisible()
        }
        scrollPrefetchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// 현재 visible 범위 앞뒤로 ±5행 썸네일 prefetch.
    /// ThumbnailLoader.load를 fire-and-forget으로 호출 → cache 채우기만.
    /// Slow disk(HDD/SD)에서는 범위를 ±2행으로 축소 (queue 폭주 방지).
    private func prefetchAroundVisible() {
        guard let scrollView = enclosingScrollView, !photos.isEmpty else { return }
        let visibleRect = scrollView.documentVisibleRect

        // HDD에서도 적극적 prefetch (concurrency 4와 함께 동작) — 사용자가 스크롤 직후 회색 placeholder 보지 않도록
        let margin = ThumbnailLoader.shared.isSlowDisk ? 4 : 5
        let startRow = max(0, Int((visibleRect.minY - inset) / (cellH + lineSpacing)) - margin)
        let totalRows = (photos.count + cols - 1) / cols
        let endRow = min(totalRows, Int((visibleRect.maxY - inset) / (cellH + lineSpacing)) + margin)

        let startIdx = max(0, startRow * cols)
        let endIdx = min(photos.count, endRow * cols)

        guard startIdx < endIdx else { return }
        for idx in startIdx..<endIdx {
            let photo = photos[idx]
            if photo.isFolder || photo.isParentFolder { continue }
            let url = photo.jpgURL
            if ThumbnailCache.shared.get(url) != nil { continue }  // 이미 메모리 캐시
            ThumbnailLoader.shared.load(url: url) { _ in }  // fire-and-forget
        }
    }

    /// id → index 캐시 (O(N) firstIndex 매 이동마다 실행 방지)
    private var _idIndexCache: [UUID: Int] = [:]
    private var _idIndexCacheVersion: Int = -1

    func scrollToSelected() {
        guard let selID = selectedID,
              let scrollView = enclosingScrollView else { return }
        // 캐시된 index 우선 사용 (photos 가 바뀌었으면 재빌드)
        if _idIndexCacheVersion != photosVersion {
            _idIndexCache.removeAll(keepingCapacity: true)
            for (i, p) in photos.enumerated() { _idIndexCache[p.id] = i }
            _idIndexCacheVersion = photosVersion
        }
        guard let idx = _idIndexCache[selID] else { return }

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
        // 컬러 라벨
        let labelMenu = NSMenu()
        let labels: [(String, ColorLabel)] = [("빨강 (6)", .red), ("노랑 (7)", .yellow), ("초록 (8)", .green), ("파랑 (9)", .blue), ("보라", .purple)]
        for (title, label) in labels {
            let item = NSMenuItem(title: title, action: #selector(setColorLabel(_:)), keyEquivalent: "")
            item.tag = ColorLabel.allCases.firstIndex(of: label) ?? 0
            item.target = self
            labelMenu.addItem(item)
        }
        labelMenu.addItem(.separator())
        let clearLabel = NSMenuItem(title: "라벨 해제", action: #selector(clearColorLabel), keyEquivalent: "")
        clearLabel.target = self
        labelMenu.addItem(clearLabel)
        let labelMenuItem = NSMenuItem(title: "컬러 라벨", action: nil, keyEquivalent: "")
        labelMenuItem.submenu = labelMenu
        menu.addItem(labelMenuItem)
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

    @objc private func setColorLabel(_ sender: NSMenuItem) {
        guard let store = store else { return }
        let allLabels = ColorLabel.allCases
        guard sender.tag >= 0, sender.tag < allLabels.count else { return }
        let label = allLabels[sender.tag]
        for id in store.selectedPhotoIDs {
            store.setColorLabel(label, for: id)
        }
    }

    @objc private func clearColorLabel() {
        guard let store = store else { return }
        for id in store.selectedPhotoIDs {
            if let i = store._photoIndex[id], i < store.photos.count {
                store.photos[i].colorLabel = .none
            }
        }
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
    // IN/OUT 마커 바 (영상 썸네일 하단)
    private let markerTrack = CALayer()
    private let markerFill = CALayer()
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

        // IN/OUT 마커 트랙 (얇은 선)
        markerTrack.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        markerTrack.cornerRadius = 1
        markerTrack.isHidden = true
        addSublayer(markerTrack)

        // 선택 구간 채우기 (초록→파랑 그라데이션 대신 단색 민트)
        markerFill.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.9).cgColor
        markerFill.cornerRadius = 1
        markerFill.isHidden = true
        markerTrack.addSublayer(markerFill)
    }

    required init?(coder: NSCoder) { fatalError() }
    override init(layer: Any) { super.init(layer: layer) }

    func configure(photo: PhotoItem, size: CGFloat, isSelected: Bool, isFocused: Bool, isPendingCut: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 잘라내기 대기 상태 시각 피드백 — opacity 낮춤
        self.opacity = isPendingCut ? 0.45 : 1.0

        let imgH = size * 0.75
        imageLayer.frame = CGRect(x: 5, y: 2, width: size, height: imgH)
        borderLayer.frame = imageLayer.frame.insetBy(dx: -2, dy: -2)
        textLayer.frame = CGRect(x: 0, y: imgH + 4, width: bounds.width, height: 14)
        textLayer.string = photo.fileNameWithExtension  // v8.6.2: 확장자 표시

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

        // 영상 파일이면 IN/OUT 마커 바 표시
        if photo.isVideoFile {
            let markers = VideoMarkerService.shared.markers(for: photo.jpgURL)
            if !markers.isEmpty {
                // 트랙: 이미지 영역 하단에 2px 두께 바
                let barY = imgH - 4
                markerTrack.frame = CGRect(x: 8, y: barY, width: size - 6, height: 2)
                markerTrack.isHidden = false

                // 채우기: IN/OUT 둘 다 있을 때만, 영상 길이 대비 비율로
                if let i = markers.inSeconds, let o = markers.outSeconds,
                   let dur = photo.videoDuration, dur > 0, o > i {
                    let startFrac = max(0, min(1, i / dur))
                    let endFrac = max(0, min(1, o / dur))
                    let trackW = size - 6
                    markerFill.frame = CGRect(x: trackW * startFrac, y: 0,
                                              width: trackW * (endFrac - startFrac), height: 2)
                    markerFill.isHidden = false
                } else {
                    // 한쪽만 있을 때 — 작은 점 표시
                    markerFill.isHidden = true
                }
            } else {
                markerTrack.isHidden = true
                markerFill.isHidden = true
            }
        } else {
            markerTrack.isHidden = true
            markerFill.isHidden = true
        }

        // 썸네일 로딩
        let url = photo.jpgURL
        currentURL = url

        if photo.isFolder || photo.isParentFolder {
            imageLayer.contents = NSImage(systemSymbolName: photo.isParentFolder ? "arrow.up.circle.fill" : "folder.fill", accessibilityDescription: nil)
            imageLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.08).cgColor
        } else if let cached = ThumbnailCache.shared.get(url) {
            imageLayer.contents = cached
            imageLayer.backgroundColor = nil
        } else if let disk = DiskThumbnailCache.shared.getByPath(url: url) {
            // 디스크 캐시 동기 히트 — GCD 왕복 없이 즉시 (< 1ms)
            ThumbnailCache.shared.set(url, image: disk)
            imageLayer.contents = disk
            imageLayer.backgroundColor = nil
        } else {
            imageLayer.contents = nil
            imageLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
            // 캐시 완전 미스 → 생성 필요
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

// MARK: - 사진 순서 변경 드롭 (Bridge 스타일)
struct PhotoReorderDropDelegate: DropDelegate {
    let photo: PhotoItem
    let store: PhotoStore
    let cellWidth: CGFloat

    private var ds: DragDropState { DragDropState.shared }

    func performDrop(info: DropInfo) -> Bool {
        ds.dropTargetID = nil
        let insertBefore = ds.dropLeading

        guard let item = info.itemProviders(for: [.utf8PlainText]).first else { return false }
        item.loadItem(forTypeIdentifier: "public.utf8-plain-text", options: nil) { data, _ in
            guard let data = data as? Data,
                  let idString = String(data: data, encoding: .utf8),
                  let sourceID = UUID(uuidString: idString) else { return }
            DispatchQueue.main.async {
                // 드래그한 셀이 다중 선택에 포함돼 있으면 선택된 모든 사진을 함께 이동
                let sel = store.selectedPhotoIDs
                if sel.contains(sourceID) && sel.count > 1 {
                    store.movePhotos(sel, to: photo.id, insertBefore: insertBefore)
                } else {
                    store.movePhoto(from: sourceID, to: photo.id)
                }
            }
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        guard !photo.isFolder && !photo.isParentFolder else { return }
        ds.dropTargetID = photo.id
    }

    func dropExited(info: DropInfo) {
        if ds.dropTargetID == photo.id {
            ds.dropTargetID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let localX = info.location.x
        let newLeading = localX < cellWidth / 2
        // 변경 시만 업데이트 (불필요한 @Published 발행 방지)
        if ds.dropLeading != newLeading {
            ds.dropLeading = newLeading
        }
        return DropProposal(operation: .move)
    }
}

// MARK: - 폴더 미리보기 그리드 (4장 썸네일)

// 폴더 미리보기 캐시 엔트리 (NSCache는 class만 저장 가능하므로 tuple을 래핑)
private final class FolderPreviewEntry {
    let images: [NSImage]
    let count: Int
    let subfolders: Int
    init(images: [NSImage], count: Int, subfolders: Int) {
        self.images = images
        self.count = count
        self.subfolders = subfolders
    }
}

// 폴더 미리보기 캐시 (폴더 재진입 시 리프레시 방지)
// NSCache 기반 - countLimit=500, 메모리 압박 시 자동 해제로 GB 단위 누적 방지
class FolderPreviewCache {
    static let shared = FolderPreviewCache()

    private let cache: NSCache<NSURL, FolderPreviewEntry> = {
        let c = NSCache<NSURL, FolderPreviewEntry>()
        c.countLimit = 500
        return c
    }()

    // 메모리 압박 감지 소스 (lazy 초기화)
    private lazy var pressureSource: DispatchSourceMemoryPressure = {
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            self?.cache.removeAllObjects()
            AppLogger.log(.general, "🆘 FolderPreviewCache 메모리 압박 해제")
        }
        src.resume()
        return src
    }()

    private init() {
        // 메모리 압박 소스 가동
        _ = pressureSource
        AppLogger.log(.general, "📁 FolderPreviewCache 초기화 (NSCache countLimit=500)")
    }

    func get(_ url: URL) -> (images: [NSImage], count: Int, subfolders: Int)? {
        guard let e = cache.object(forKey: url as NSURL) else { return nil }
        return (e.images, e.count, e.subfolders)
    }

    func set(_ url: URL, images: [NSImage], count: Int, subfolders: Int) {
        let entry = FolderPreviewEntry(images: images, count: count, subfolders: subfolders)
        cache.setObject(entry, forKey: url as NSURL)
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func invalidateAll() {
        cache.removeAllObjects()
    }
}

struct FolderPreviewGrid: View {
    let folderURL: URL
    let size: CGFloat
    @State private var previewImages: [NSImage] = []
    @State private var photoCount: Int = 0
    @State private var subfolderCount: Int = 0
    @State private var loaded = false

    private var cellH: CGFloat { size * 0.75 }
    private var halfW: CGFloat { (size - 6) / 2 }
    private var halfH: CGFloat { (cellH - 20) / 2 }  // 상단 폴더탭 영역 확보

    // 폴더 아이콘 내부 썸네일 영역 비율 (macOS 폴더 아이콘 기준)
    private var iconSize: CGFloat { size * 0.85 }
    // 폴더 앞면 영역 (아이콘 하단 60% 영역)
    private var gridW: CGFloat { iconSize * 0.68 }
    private var gridH: CGFloat { iconSize * 0.42 }
    private var gridOffsetY: CGFloat { iconSize * 0.12 }

    var body: some View {
        ZStack {
            // macOS 폴더 아이콘
            Image(nsImage: NSWorkspace.shared.icon(forFile: folderURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)

            // 빈 폴더 표시 (사진 없고 하위 폴더도 없을 때만)
            if loaded && previewImages.isEmpty {
                let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "ko"
                if subfolderCount > 0 {
                    // 하위 폴더만 있는 경우
                    VStack(spacing: 2) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: size * 0.1))
                            .foregroundColor(.white.opacity(0.6))
                        Text(lang == "ko" ? "\(subfolderCount)개 폴더" : "\(subfolderCount) folders")
                            .font(.system(size: max(8, size * 0.055), weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .offset(y: gridOffsetY)
                } else if photoCount == 0 {
                    Text(lang == "ko" ? "파일 없음" : "No files")
                        .font(.system(size: max(8, size * 0.06), weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .offset(y: gridOffsetY)
                }
            }

            // 2x2 썸네일 그리드 (폴더 앞면 안에)
            if !previewImages.isEmpty {
                VStack(spacing: 1) {
                    HStack(spacing: 1) {
                        previewThumb(0)
                        previewThumb(1)
                    }
                    HStack(spacing: 1) {
                        previewThumb(2)
                        previewThumb(3)
                    }
                }
                .frame(width: gridW, height: gridH)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .offset(y: gridOffsetY)
            }

            // 사진 수 배지 (우하단)
            if photoCount > 0 {
                Text("\(photoCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.8))
                    .cornerRadius(4)
                    .frame(maxWidth: iconSize, maxHeight: iconSize, alignment: .bottomTrailing)
                    .offset(x: -2, y: -4)
            }
        }
        .frame(width: size, height: size * 0.75)
        .onAppear {
            if !loaded { loadFolderPreviews() }
        }
    }

    @ViewBuilder
    private func previewThumb(_ index: Int) -> some View {
        if index < previewImages.count {
            Image(nsImage: previewImages[index])
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: (gridW - 1) / 2, height: (gridH - 1) / 2)
                .clipped()
        } else {
            Color.clear
                .frame(width: (gridW - 1) / 2, height: (gridH - 1) / 2)
        }
    }

    private func loadFolderPreviews() {
        // 캐시 히트
        if let cached = FolderPreviewCache.shared.get(folderURL) {
            previewImages = cached.images
            photoCount = cached.count
            subfolderCount = cached.subfolders
            loaded = true
            return
        }

        let url = folderURL
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let items: [URL]
            do {
                items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            } catch {
                fputs("[FolderPreview] contentsOfDirectory 실패: \(url.path) — \(error.localizedDescription)\n", stderr)
                DispatchQueue.main.async { loaded = true }
                return
            }

            let mediaExts = FileMatchingService.allMediaExtensions
            let imageFiles = items.filter { mediaExts.contains($0.pathExtension.lowercased()) }
            let count = imageFiles.count
            if count == 0 {
                fputs("[FolderPreview] 미디어 파일 0개: \(url.path) (전체 \(items.count)개 항목)\n", stderr)
                for item in items.prefix(5) {
                    fputs("[FolderPreview]   - \(item.lastPathComponent) (ext: \(item.pathExtension))\n", stderr)
                }
            }

            // 하위 폴더 수 카운트
            let folders = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            let folderCnt = folders.count

            // 이미지가 없으면 하위 폴더에서 찾기 (1단계만)
            var allImageFiles = imageFiles
            if allImageFiles.isEmpty && !folders.isEmpty {
                for subFolder in folders.prefix(4) {
                    if let subItems = try? fm.contentsOfDirectory(at: subFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        let subImages = subItems.filter { mediaExts.contains($0.pathExtension.lowercased()) }
                        if let first = subImages.first {
                            allImageFiles.append(first)
                        }
                    }
                    if allImageFiles.count >= 4 { break }
                }
            }

            var sampled: [URL] = []
            if allImageFiles.count <= 4 {
                sampled = allImageFiles
            } else {
                let step = allImageFiles.count / 4
                for i in 0..<4 { sampled.append(allImageFiles[i * step]) }
            }

            var thumbs: [NSImage] = []
            for fileURL in sampled {
                if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                   let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceThumbnailMaxPixelSize: 120,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: false
                   ] as CFDictionary) {
                    thumbs.append(NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height)))
                }
            }

            // 캐시 저장
            FolderPreviewCache.shared.set(url, images: thumbs, count: count, subfolders: folderCnt)

            DispatchQueue.main.async {
                previewImages = thumbs
                photoCount = count
                subfolderCount = folderCnt
                loaded = true
            }
        }
    }
}

// MARK: - 드롭 위치 | 바 오버레이
/// 셀별 드롭 상태 옵저버 — `DragDropState` 변화 중 본 셀과 무관한 변화는 무시.
/// (전체 셀이 모든 드래그 이벤트마다 re-render되던 문제 해소)
final class CellDropObserver: ObservableObject {
    @Published private(set) var isTarget: Bool = false
    @Published private(set) var leading: Bool = true
    private var bag: Set<AnyCancellable> = []

    func bind(to photoID: UUID) {
        bag.removeAll()
        let ds = DragDropState.shared
        ds.$dropTargetID
            .map { $0 == photoID }
            .removeDuplicates()
            .sink { [weak self] in self?.isTarget = $0 }
            .store(in: &bag)
        ds.$dropLeading
            .removeDuplicates()
            .sink { [weak self] in
                guard let s = self else { return }
                if s.isTarget { s.leading = $0 }
            }
            .store(in: &bag)
    }
}

struct DropIndicatorOverlay: View {
    let photoID: UUID
    @StateObject private var observer = CellDropObserver()

    var body: some View {
        GeometryReader { geo in
            if observer.isTarget {
                let xPos: CGFloat = observer.leading ? -3 : geo.size.width + 3
                dropBar(height: geo.size.height)
                    .position(x: xPos, y: geo.size.height / 2)
            }
        }
        .allowsHitTesting(false)
        .onAppear { observer.bind(to: photoID) }
        .onChange(of: photoID) { _, _ in observer.bind(to: photoID) }
    }

    private func dropBar(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color.blue)
                .frame(width: 10, height: 10)
            Rectangle()
                .fill(Color.blue)
                .frame(width: 3, height: height - 24)
            Circle()
                .fill(Color.blue)
                .frame(width: 10, height: 10)
        }
        .shadow(color: Color.blue.opacity(0.6), radius: 4)
    }
}


// MARK: - v8.6.3 Marquee (Rubber-band) Selection

/// 셀 프레임을 부모로 전파하는 PreferenceKey
struct GridCellFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 마지막으로 수집된 셀 프레임을 전역 저장 — MarqueeSelectionBackground 가 참조 (SwiftUI state 반복 업데이트 회피)
final class MarqueeFrameRegistry {
    static let shared = MarqueeFrameRegistry()
    var frames: [UUID: CGRect] = [:]
    private init() {}
}

/// 러버밴드 선택 배경. 빈 영역에서 드래그 시작 시 사각형 그림. 드래그 종료 시 교차 셀 선택.
struct MarqueeSelectionBackground: View {
    let coordinateSpaceName: String
    let allPhotoIDs: [UUID]
    let store: PhotoStore

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var baseSelection: Set<UUID> = []

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpaceName))
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = value.startLocation
                            let flags = NSEvent.modifierFlags
                            // Cmd/Shift 누르고 드래그면 기존 선택 유지
                            if flags.contains(.command) || flags.contains(.shift) {
                                baseSelection = store.selectedPhotoIDs
                            } else {
                                baseSelection = []
                            }
                        }
                        dragCurrent = value.location
                        updateLiveSelection()
                    }
                    .onEnded { value in
                        dragCurrent = value.location
                        updateLiveSelection()
                        dragStart = nil
                        dragCurrent = nil
                    }
            )
            .simultaneousGesture(
                // 빈 영역 탭 → 선택 해제 (드래그 아닌 단순 탭만)
                TapGesture().onEnded {
                    if dragStart == nil {
                        store.deselectAll()
                    }
                }
            )
            .overlay(
                Group {
                    if let s = dragStart, let c = dragCurrent {
                        let rect = CGRect(
                            x: min(s.x, c.x),
                            y: min(s.y, c.y),
                            width: abs(c.x - s.x),
                            height: abs(c.y - s.y)
                        )
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.15))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 1))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                    }
                }
            )
    }

    private func updateLiveSelection() {
        guard let s = dragStart, let c = dragCurrent else { return }
        let rect = CGRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(c.x - s.x),
            height: abs(c.y - s.y)
        )
        let frames = MarqueeFrameRegistry.shared.frames
        var hits: Set<UUID> = baseSelection
        for id in allPhotoIDs {
            if let f = frames[id], f.intersects(rect) {
                hits.insert(id)
            }
        }
        // 큰 폴더에서 매 프레임마다 set 비교는 비용 있음 → 다르면만 업데이트
        if hits != store.selectedPhotoIDs {
            store.selectedPhotoIDs = hits
            if let first = hits.first {
                store.selectedPhotoID = first
            }
        }
    }
}

// MARK: - ListView Drag Monitor (v8.7)

/// 리스트뷰 드래그 → Finder 멀티 파일 복사를 위한 글로벌 NSEvent 모니터.
/// 필름스트립과 동일한 방식: 이벤트를 consume 안 함. Table selection 은 SwiftUI 가 처리.
/// 드래그 임계값 초과 시 store.selectedPhotoIDs 전체를 NSDraggingSession 으로 개시.
final class ListViewDragMonitor: ObservableObject {
    private var monitor: Any?
    private var downLocation: NSPoint?
    private var didStartDrag = false
    private let threshold: CGFloat = 6
    private weak var store: PhotoStore?

    /// NativeListView 의 global frame — PreferenceKey 로 업데이트. SwiftUI 좌표계 (top-origin).
    var tableBounds: CGRect = .zero

    func install(store: PhotoStore) {
        self.store = store
        uninstall()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
        fputs("[ListDrag] monitor installed\n", stderr)
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
            let inBounds = isInTableBounds(event: event)
            downLocation = inBounds ? event.locationInWindow : nil
            didStartDrag = false
            fputs("[ListDrag] mouseDown inBounds=\(inBounds) bounds=\(tableBounds) sel=\(store?.selectedPhotoIDs.count ?? 0)\n", stderr)

        case .leftMouseDragged:
            let hasStart = downLocation != nil
            let hasStore = store != nil
            let selCount = store?.selectedPhotoIDs.count ?? 0
            if !didStartDrag && hasStart && hasStore && selCount > 0 {
                let dist = hypot(event.locationInWindow.x - downLocation!.x,
                                 event.locationInWindow.y - downLocation!.y)
                if dist > threshold {
                    didStartDrag = true
                    fputs("[ListDrag] 🚀 initiate dist=\(Int(dist)) sel=\(selCount)\n", stderr)
                    initiateDrag(event: event, store: store!)
                }
            } else if !didStartDrag {
                // 드래그 실패 이유 로깅 (한 번만)
                fputs("[ListDrag] dragged but skipped: hasStart=\(hasStart) hasStore=\(hasStore) sel=\(selCount)\n", stderr)
            }

        case .leftMouseUp:
            downLocation = nil
            didStartDrag = false

        default:
            break
        }
    }

    /// NSEvent 좌표가 Table bounds 내에 있는지 체크. Y 축 플립 처리.
    private func isInTableBounds(event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        let appkit = window.convertPoint(toScreen: event.locationInWindow)
        let screen = NSScreen.screens.first { $0.frame.contains(appkit) } ?? NSScreen.main
        guard let frame = screen?.frame else { return false }
        let swiftUIY = frame.origin.y + frame.height - appkit.y
        return tableBounds.contains(NSPoint(x: appkit.x, y: swiftUIY))
    }

    /// 선택된 사진 전체 + JPG/RAW 쌍을 NSDraggingSession 으로 개시.
    private func initiateDrag(event: NSEvent, store: PhotoStore) {
        var urls: [URL] = []
        for id in store.selectedPhotoIDs {
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

        // 드래그 프리뷰: 포커스 사진의 썸네일 + 개수 배지
        let side: CGFloat = 80
        let defaultFrame = NSRect(x: -side / 2, y: -side / 2, width: side, height: side)
        var previewImage: NSImage? = nil
        let anchorURL: URL? = {
            if let focusID = store.selectedPhotoID,
               let idx = store._photoIndex[focusID],
               idx < store.photos.count {
                return store.photos[idx].jpgURL
            }
            return urls.first
        }()
        if let url = anchorURL {
            let thumb =
                DiskThumbnailCache.shared.getByPath(url: url)
                ?? ThumbnailCache.shared.get(url)
            if let image = thumb {
                let resized = NSImage(size: NSSize(width: side, height: side))
                resized.lockFocus()
                NSGraphicsContext.current?.imageInterpolation = .high
                let r = min(side / image.size.width, side / image.size.height)
                let w = image.size.width * r
                let h = image.size.height * r
                image.draw(in: NSRect(x: (side - w)/2, y: (side - h)/2, width: w, height: h))
                if store.selectedPhotoIDs.count > 1 {
                    let badge = "\(store.selectedPhotoIDs.count)" as NSString
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
            di.setDraggingFrame(defaultFrame, contents: i == 0 ? previewImage : nil)
            items.append(di)
        }

        guard let contentView = event.window?.contentView else { return }
        _ = contentView.beginDraggingSession(with: items, event: event, source: ListViewDragSource.shared)
    }
}

final class ListViewDragSource: NSObject, NSDraggingSource {
    static let shared = ListViewDragSource()
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : .move
    }
    /// 드래그 종료 시 listDragInProgress 플래그 해제 (NSDraggingSession 이 뒷단 mouse loop 를
    /// 가져가기 때문에 SwiftUI DragGesture.onEnded 가 호출되지 않음).
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        NativeListView.listDragInProgress = false
        fputs("[ListDrag] session ended — flag reset\n", stderr)
    }
}
