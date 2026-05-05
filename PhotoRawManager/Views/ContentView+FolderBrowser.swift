import SwiftUI
import Quartz

// MARK: - Folder Browser Model

struct FolderItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    var children: [FolderItem]?
    var isExpanded: Bool = false
    var hasSubfolders: Bool

    init(url: URL, name: String, hasSubfolders: Bool? = nil) {
        self.url = url
        self.name = name
        // Default to true (assume folders have subfolders) - avoids blocking disk I/O on init
        self.hasSubfolders = hasSubfolders ?? true
    }

    static func loadChildren(of url: URL) -> [FolderItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var dirs: [URL] = []
        dirs.reserveCapacity(contents.count / 4)
        for item in contents {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                dirs.append(item)
            }
        }
        dirs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        // hasSubfolders 는 기본값 true (펼칠 때 실제 확인하고 비어있으면 hide).
        // HDD 에서 N+1 enumerator 호출로 수 초 프리즈 발생 → 제거.
        return dirs.map { FolderItem(url: $0, name: $0.lastPathComponent, hasSubfolders: true) }
    }

    /// 하위 폴더 존재 여부 — enumerator early exit (전체 목록 안 읽음).
    /// 지연 확인용 — hot path 에서는 부르지 말 것.
    static func checkHasSubfolders(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return false }
        while let item = enumerator.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return true  // 하나라도 찾으면 즉시 반환
            }
        }
        return false
    }

    static func hasImages(in url: URL) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        return contents.contains { FileMatchingService.allImageExtensions.contains($0.pathExtension.lowercased()) }
    }
}

// MARK: - Folder Browser Sidebar

enum FolderViewMode: String {
    case tree = "tree"
    case icon = "icon"
}

struct FolderBrowserView: View {
    @EnvironmentObject var store: PhotoStore
    @Binding var isExpanded: Bool
    @State private var rootItems: [FolderItem] = []
    @State private var favorites: [URL] = []
    @State private var recentFolders: [URL] = []
    @State private var folderViewMode: FolderViewMode = .tree
    @State private var favoritesHeight: CGFloat = 550
    // v8.9.4: 우측 사이드바 하단 탭 (즐겨찾기 / 메타데이터 / 메타데이터 편집)
    // v9.0.2: 기본 탭 메타데이터 + 순서 메타데이터 → 즐겨찾기 → 편집.
    @State private var sidebarTab: SidebarTab = .metadata
    enum SidebarTab: String, CaseIterable, Identifiable {
        case metadata = "메타데이터"
        case favorites = "즐겨찾기"
        case editor = "편집"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .metadata: return "info.circle"
            case .favorites: return "star.fill"
            case .editor: return "pencil.circle"
            }
        }
    }
    @State private var currentIconFolder: URL?
    @State private var iconFolderContents: [FolderItem] = []
    @State private var refreshWork: DispatchWorkItem?
    @State private var volumeObservers: [NSObjectProtocol] = []
    /// v9.1.4: NSWorkspace 와 NotificationCenter.default 옵저버를 분리 보관 — 정리 시 정확한 센터에 removeObserver.
    @State private var defaultCenterObservers: [NSObjectProtocol] = []
    // v9.1: 폴더 트리 다중 선택. Cmd+클릭 = 토글. Shift+클릭 = anchor 부터 범위 추가.
    @State var multiFolderSelection: Set<URL> = []
    @State var folderSelectionAnchor: URL?

    /// 트리에서 현재 *보이는* 폴더 URL 들을 표시 순서대로 평탄화.
    func flattenVisibleFolders() -> [URL] {
        var result: [URL] = []
        func walk(_ items: [FolderItem]) {
            for it in items {
                result.append(it.url)
                if it.isExpanded, let kids = it.children {
                    walk(kids)
                }
            }
        }
        walk(rootItems)
        return result
    }

    /// Shift+클릭 처리 — anchor (없으면 현재 store.folderURL 또는 클릭한 URL) 부터 target 까지 범위 추가.
    func handleShiftClick(_ target: URL) {
        let visible = flattenVisibleFolders()
        let anchor = folderSelectionAnchor ?? store.folderURL ?? target
        guard let aIdx = visible.firstIndex(of: anchor),
              let tIdx = visible.firstIndex(of: target) else {
            // 범위 계산 불가 → 단일 토글로 폴백
            multiFolderSelection.insert(target)
            folderSelectionAnchor = target
            return
        }
        let range = aIdx <= tIdx ? aIdx...tIdx : tIdx...aIdx
        for i in range { multiFolderSelection.insert(visible[i]) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            refreshRootItems()
            // 앱 시작 시 이미 마운트된 메모리카드 체크 (자동 백업 설정 시만)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard UserDefaults.standard.bool(forKey: "autoBackupEnabled") else { return }
                let fm = FileManager.default
                if let volumes = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil) {
                    for vol in volumes {
                        MemoryCardBackupService.shared.checkAndPromptIfMemoryCard(vol)
                    }
                }
            }

            // Watch for volume mount/unmount — observer 토큰 저장 (누수 방지)
            guard volumeObservers.isEmpty else { return }  // 중복 등록 방지
            let ws = NSWorkspace.shared.notificationCenter
            let mountObs = ws.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { notification in
                if UserDefaults.standard.bool(forKey: "autoBackupEnabled"),
                   let volumePath = notification.userInfo?["NSDevicePath"] as? String {
                    let volumeURL = URL(fileURLWithPath: volumePath)
                    MemoryCardBackupService.shared.checkAndPromptIfMemoryCard(volumeURL)
                }
                refreshRootItems()
            }
            let unmountObs = ws.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { notification in
                if let volumePath = notification.userInfo?["NSDevicePath"] as? String {
                    AppLogger.log(.folder, "Volume unmounted: \(volumePath)")
                }
                refreshRootItems()
            }
            // v9.1.4: Finder 등 외부 앱에서 폴더 만들기/삭제 후 PickShot 으로 돌아오면 자동 트리 갱신.
            //   NSApplication.didBecomeActive — 앱 다시 활성화될 때 한 번 refresh.
            let appActiveObs = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { _ in refreshRootItems() }
            // (token, center) 튜플로 보관 → 정리 시 정확한 center 에 removeObserver.
            volumeObservers = [mountObs, unmountObs]
            defaultCenterObservers = [appActiveObs]
        }
        .onChange(of: store.folderURL) { _, newURL in
            guard let url = newURL else { return }
            expandTreeToPath(url)
        }
        // 폴더 생성/삭제/이동 시 트리 자동 새로고침
        .onReceive(NotificationCenter.default.publisher(for: .init("FolderTreeNeedsRefresh"))) { _ in
            refreshRootItems()
        }
        .onDisappear {
            let ws = NSWorkspace.shared.notificationCenter
            for obs in volumeObservers { ws.removeObserver(obs) }
            for obs in defaultCenterObservers { NotificationCenter.default.removeObserver(obs) }
            volumeObservers.removeAll()
            defaultCenterObservers.removeAll()
        }
    }

    private func renameFolderWithDialog(url: URL) {
        let alert = NSAlert()
        alert.messageText = "즐겨찾기 표시 이름 변경"
        alert.informativeText = "표시할 이름을 입력하세요 (실제 폴더 이름은 변경되지 않습니다)"
        alert.addButton(withTitle: "변경")
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "원래 이름으로")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = store.favoriteNickname(for: url)
        input.placeholderString = url.lastPathComponent
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty else { return }
            store.setFavoriteNickname(url, name: newName)
            favorites = []  // 강제 리렌더링
            DispatchQueue.main.async { favorites = store.loadFavoriteFolders() }
            store.showToastMessage("'\(newName)'으로 표시 이름 변경")
        } else if response == .alertThirdButtonReturn {
            store.setFavoriteNickname(url, name: "")
            favorites = []
            DispatchQueue.main.async { favorites = store.loadFavoriteFolders() }
            store.showToastMessage("원래 이름으로 복원")
        }
    }

    /// 지정된 폴더 안에 새 하위 폴더 생성
    private func createNewSubfolder(in parentURL: URL) {
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
                // 프리뷰 캐시 무효화 + 트리/그리드 새로고침
                FolderPreviewCache.shared.invalidate(parentURL)
                if store.folderURL == parentURL {
                    store.loadFolder(parentURL, restoreRatings: true)
                }
                refreshRootItems()
            } catch {
                store.showToastMessage("⚠️ 폴더 생성 실패: \(error.localizedDescription)")
            }
        }
    }

    /// Debounced tree refresh — 빠른 연속 호출 (마운트/언마운트 등) 병합.
    /// 확장 상태(isExpanded + children)를 보존하기 위해 oldItems 스냅샷을 캡처하고
    /// 새 rootItems와 경로 기준으로 머지한다. 머지 중 확장된 폴더의 자식은 디스크에서
    /// 새로 읽어 새 폴더 생성/이동 결과가 즉시 반영되도록 한다.
    /// v9.1.4: debounce 300ms → 50ms — 폴더 생성/이동 직후 트리 반영 체감 단축.
    ///   외부 마운트/언마운트 burst 합치기에는 50ms 도 충분.
    private func refreshRootItems() {
        refreshWork?.cancel()
        let oldSnapshot = rootItems  // main thread 호출 가정 — @State 값 타입이라 deep copy
        let currentIconURL = currentIconFolder  // icon 모드 새로고침용
        let work = DispatchWorkItem {
            let newRoots = buildRootItems()
            let merged = Self.mergePreservingExpansion(newItems: newRoots, oldItems: oldSnapshot)
            let favs = store.loadFavoriteFolders()
            let recents = store.loadRecentFolders()
            // icon 모드에서 현재 보고 있는 폴더의 자식 목록도 재스캔
            let refreshedIconContents: [FolderItem]? = currentIconURL.map { FolderItem.loadChildren(of: $0) }
            DispatchQueue.main.async {
                rootItems = merged
                favorites = favs
                recentFolders = recents
                if let items = refreshedIconContents {
                    iconFolderContents = items
                }
                // rootItems 로드 완료 후 현재 폴더 경로로 트리 확장
                if let url = store.folderURL {
                    expandTreeToPath(url)
                }
            }
        }
        refreshWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// 경로 기준으로 newItems에 oldItems의 isExpanded / children을 재귀 이식.
    /// 확장된 폴더는 디스크에서 children을 새로 읽어 신규 서브폴더를 포함시키고,
    /// 그 아래 노드들의 확장 상태 역시 같은 규칙으로 보존한다.
    private static func mergePreservingExpansion(newItems: [FolderItem], oldItems: [FolderItem]) -> [FolderItem] {
        guard !oldItems.isEmpty else { return newItems }
        var oldByPath: [String: FolderItem] = [:]
        oldByPath.reserveCapacity(oldItems.count)
        for item in oldItems { oldByPath[item.url.path] = item }
        return newItems.map { newItem in
            guard let oldItem = oldByPath[newItem.url.path], oldItem.isExpanded else {
                return newItem
            }
            var merged = newItem
            merged.isExpanded = true
            let freshChildren = FolderItem.loadChildren(of: newItem.url)
            let oldChildren = oldItem.children ?? []
            merged.children = mergePreservingExpansion(newItems: freshChildren, oldItems: oldChildren)
            return merged
        }
    }

    /// Auto-expand tree to show the currently loaded folder (async to avoid blocking main thread)
    private func expandTreeToPath(_ targetURL: URL) {
        let home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        let desktopURL = home.appendingPathComponent("Desktop")

        // Build path components from Desktop to target
        var current = targetURL
        var pathsToExpand: [URL] = [current]
        while current.path != desktopURL.path && current.path != "/" && current.path != home.path {
            current = current.deletingLastPathComponent()
            pathsToExpand.insert(current, at: 0)
        }

        // Load all children on background thread, then apply on main
        DispatchQueue.global(qos: .userInitiated).async {
            // Pre-load all needed children off main thread
            var childrenCache: [String: [FolderItem]] = [:]
            for pathURL in pathsToExpand {
                let children = FolderItem.loadChildren(of: pathURL)
                childrenCache[pathURL.path] = children
            }

            DispatchQueue.main.async {
                for pathURL in pathsToExpand {
                    expandFolderInTree(pathURL, prefetchedChildren: childrenCache)
                }
            }
        }
    }

    private func expandFolderInTree(_ targetURL: URL, prefetchedChildren: [String: [FolderItem]]? = nil) {
        func expand(items: inout [FolderItem], depth: Int = 0, maxDepth: Int = 20) -> Bool {
            guard depth < maxDepth else { return false }
            for i in items.indices {
                if items[i].url.path == targetURL.path {
                    if !items[i].isExpanded {
                        items[i].isExpanded = true
                        items[i].children = prefetchedChildren?[items[i].url.path]
                            ?? FolderItem.loadChildren(of: items[i].url)
                    }
                    return true
                }
                if targetURL.path.hasPrefix(items[i].url.path + "/") {
                    if !items[i].isExpanded {
                        items[i].isExpanded = true
                        items[i].children = prefetchedChildren?[items[i].url.path]
                            ?? FolderItem.loadChildren(of: items[i].url)
                    }
                    if var children = items[i].children {
                        if expand(items: &children, depth: depth + 1, maxDepth: maxDepth) {
                            items[i].children = children
                            return true
                        }
                    }
                }
            }
            return false
        }
        _ = expand(items: &rootItems)
    }

    // MARK: - Collapsed (36px icon bar)

    private var collapsedContent: some View {
        VStack(spacing: 2) {
            // Expand button (large and clear)
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded = true } }) {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.blue.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("폴더 브라우저 열기")
            .padding(.top, 6)

            Divider().frame(width: 20).padding(.vertical, 4)

            // Folders icon
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded = true } }) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.blue)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("폴더 탐색")

            // Favorites icon
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded = true } }) {
                Image(systemName: "star.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.yellow)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("즐겨찾기")

            // Recent icon
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded = true } }) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("최근 폴더")

            Spacer()
        }
    }

    // MARK: - Expanded (250px full tree)

    private var expandedContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.blue)
                Text("폴더")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                Spacer()

                // Collapse button (clear and visible)
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded = false } }) {
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("폴더 브라우저 접기")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Folder tree (scrollable, auto-scroll to current folder)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        folderTreeSection
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .onChange(of: store.folderURL) { _, newURL in
                    guard let url = newURL else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(url.path, anchor: .center)
                        }
                    }
                }
            }

            // Drag handle to resize favorites area
            Divider()
            Rectangle()
                .fill(Color.gray.opacity(0.01))
                .frame(height: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 30, height: 3)
                )
                .cursor(.resizeUpDown)
                .gesture(DragGesture().onChanged { value in
                    favoritesHeight = max(80, min(300, favoritesHeight - value.translation.height))
                })

            // v8.9.4: 즐겨찾기 영역을 탭 컨테이너로 변환 (즐겨찾기 / 정보 / 편집)
            VStack(alignment: .leading, spacing: 0) {
                // 탭 picker
                Picker("", selection: $sidebarTab) {
                    ForEach(SidebarTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)

                Group {
                    switch sidebarTab {
                    case .favorites: favoritesContent
                    case .metadata: metadataContent
                    case .editor: metadataEditorContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(height: favoritesHeight)
        }
    }

    // MARK: - Sidebar Tab Contents (v8.9.4)

    private var favoritesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if favorites.isEmpty {
                Text("폴더를 우클릭하여 추가")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(favorites, id: \.path) { url in
                            HStack(spacing: 6) {
                                AsyncFolderThumbnail(url: url)
                                    .frame(width: 40, height: 30)
                                    .cornerRadius(3)

                                Text(store.favoriteNickname(for: url))
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    Spacer(minLength: 4)

                                    // ⋯ 메뉴 버튼
                                    Menu {
                                        Button("이름 변경") { renameFolderWithDialog(url: url) }
                                        Button("즐겨찾기에서 제거") {
                                            store.removeFavoriteFolder(url)
                                            favorites = []
                                            DispatchQueue.main.async { favorites = store.loadFavoriteFolders() }
                                        }
                                        Button("Finder에서 열기") { NSWorkspace.shared.open(url) }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(store.folderURL?.path == url.path ? Color.accentColor.opacity(0.15) : Color.clear)
                                .cornerRadius(4)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.startupMode = .viewer
                                    DispatchQueue.main.async {
                                        store.loadFolder(url, restoreRatings: true)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
        }

    @ViewBuilder
    private var metadataContent: some View {
        if let p = store.selectedPhoto {
            SidebarMetadataView(photo: p)
        } else {
            VStack {
                Spacer()
                Image(systemName: "photo").font(.system(size: 24)).foregroundColor(.secondary)
                Text("사진을 선택하세요").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var metadataEditorContent: some View {
        if let p = store.selectedPhoto {
            SidebarMetadataEditor(photo: p)
        } else {
            VStack {
                Spacer()
                Image(systemName: "pencil.slash").font(.system(size: 24)).foregroundColor(.secondary)
                Text("사진을 선택하세요").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Folder Tree Section

    private var folderTreeSection: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            sectionHeader(icon: "folder.fill", title: "로컬 폴더", color: .blue)

            // v9.1: 다중 선택 액션 바 (2개 이상 선택 시)
            if multiFolderSelection.count >= 2 {
                multiSelectionBar
            }

            ForEach(rootItems.indices, id: \.self) { i in
                FolderRowView(
                    item: $rootItems[i],
                    store: store,
                    level: 0,
                    onAddFavorite: { url in
                        store.addFavoriteFolder(url)
                        favorites = store.loadFavoriteFolders()
                    },
                    multiSelection: $multiFolderSelection,
                    onShiftClick: { handleShiftClick($0) },
                    onSetAnchor: { folderSelectionAnchor = $0 }
                )
            }
        }
    }

    private var multiSelectionBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.orange)
            Text("\(multiFolderSelection.count)개 선택")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)
            Spacer()
            Button {
                let urls = Array(multiFolderSelection)
                multiFolderSelection.removeAll()
                store.loadFoldersAggregated(urls)
            } label: {
                Label("일괄 열기", systemImage: "rectangle.stack.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
            Button {
                multiFolderSelection.removeAll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("다중 선택 해제")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Favorites Section

    // MARK: - Favorites with Thumbnails (Capture One style)

    private var favoritesThumbnailSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(icon: "star.fill", title: "즐겨찾기", color: .yellow)

            if favorites.isEmpty {
                Text("폴더를 우클릭하여 추가")
                    .font(.system(size: AppTheme.iconSmall))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
            } else {
                ForEach(favorites, id: \.path) { url in
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.accentColor)

                        Text(store.favoriteNickname(for: url))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        // ⋯ 메뉴 버튼
                        Menu {
                            Button("이름 변경") { renameFolderWithDialog(url: url) }
                            Button("즐겨찾기에서 제거") {
                                store.removeFavoriteFolder(url)
                                favorites = []
                                DispatchQueue.main.async { favorites = store.loadFavoriteFolders() }
                            }
                            Button("Finder에서 열기") { NSWorkspace.shared.open(url) }
                            Divider()
                            Button("새 폴더 만들기") { createNewSubfolder(in: url) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(store.folderURL?.path == url.path ? Color.accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.startupMode = .viewer
                        store.loadFolder(url, restoreRatings: true)
                    }
                    .help(url.path)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.hasDirectoryPath else { return }
                    DispatchQueue.main.async {
                        store.addFavoriteFolder(url)
                        favorites = store.loadFavoriteFolders()
                    }
                }
            }
            return true
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(icon: "star.fill", title: "즐겨찾기", color: .yellow)

            if favorites.isEmpty {
                Text("폴더를 우클릭하여 추가")
                    .font(.system(size: AppTheme.iconSmall))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
            } else {
                ForEach(favorites, id: \.path) { url in
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.yellow)
                        Text(url.lastPathComponent)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(store.folderURL?.path == url.path ? Color.accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.startupMode = .viewer
                        store.loadFolder(url)
                    }
                    .contextMenu {
                        Button {
                            store.startupMode = .viewer
                            store.loadPhotosRecursive(from: url)
                        } label: {
                            Label("하위 폴더 포함 열기", systemImage: "folder.badge.plus")
                        }
                        Divider()
                        Button("즐겨찾기에서 제거") {
                            store.removeFavoriteFolder(url)
                            favorites = store.loadFavoriteFolders()
                        }
                        Button("Finder에서 열기") {
                            NSWorkspace.shared.open(url)
                        }
                        Divider()
                        folderTreeCopyCutPasteMenu(url, store: store)
                        Divider()
                        Button("새 폴더 만들기") { createNewSubfolder(in: url) }
                    }
                    .help(url.path)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.hasDirectoryPath else { return }
                    DispatchQueue.main.async {
                        store.addFavoriteFolder(url)
                        favorites = store.loadFavoriteFolders()
                    }
                }
            }
            return true
        }
    }

    // MARK: - Recent Section

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(icon: "clock.fill", title: "최근 폴더", color: .orange)

            if recentFolders.isEmpty {
                Text("최근 열었던 폴더 없음")
                    .font(.system(size: AppTheme.iconSmall))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
            } else {
                ForEach(recentFolders, id: \.path) { url in
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        Text(url.lastPathComponent)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(store.folderURL?.path == url.path ? Color.accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.startupMode = .viewer
                        store.loadFolder(url)
                    }
                    .contextMenu {
                        Button("즐겨찾기에 추가") {
                            store.addFavoriteFolder(url)
                            favorites = store.loadFavoriteFolders()
                        }
                        Button("Finder에서 열기") {
                            NSWorkspace.shared.open(url)
                        }
                        Divider()
                        folderTreeCopyCutPasteMenu(url, store: store)
                        Divider()
                        Button("새 폴더 만들기") { createNewSubfolder(in: url) }
                    }
                    .help(url.path)
                }
            }
        }
    }

    // MARK: - Projects Section (Capture One style)

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(icon: "square.grid.2x2", title: "프로젝트", color: .purple)

            if recentFolders.isEmpty {
                Text("최근 열었던 폴더 없음")
                    .font(.system(size: AppTheme.iconSmall))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
            } else {
                ForEach(recentFolders, id: \.path) { url in
                    HStack(spacing: 10) {
                        // Small thumbnail (first image in folder)
                        AsyncFolderThumbnail(url: url)
                            .frame(width: 50, height: 38)
                            .cornerRadius(4)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }

                        Spacer()

                        // Photo count
                        ProjectFolderCount(url: url)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(store.folderURL?.path == url.path ? Color.accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.startupMode = .viewer
                        store.loadFolder(url)
                    }
                    .contextMenu {
                        Button("즐겨찾기에 추가") {
                            store.addFavoriteFolder(url)
                            favorites = store.loadFavoriteFolders()
                        }
                        Button("Finder에서 열기") {
                            NSWorkspace.shared.open(url)
                        }
                        Divider()
                        folderTreeCopyCutPasteMenu(url, store: store)
                        Divider()
                        Button("새 폴더 만들기") { createNewSubfolder(in: url) }
                    }
                    .help(url.path)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            Text(title.uppercased())
                .font(.system(size: AppTheme.fontCaption, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, AppTheme.space4)
    }

    // MARK: - Icon View Section

    private var iconViewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Breadcrumb for icon view
            if let folder = currentIconFolder {
                HStack(spacing: 4) {
                    Button(action: { navigateIconUp() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("상위 폴더로")

                    Text(folder.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else {
                Text("위치 선택")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
            }

            Divider()

            // Quick access
            if currentIconFolder == nil {
                let columns = [GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: columns, spacing: 8) {
                    iconQuickItem(name: "Desktop", icon: "desktopcomputer", color: .blue,
                                  url: URL(fileURLWithPath: "/Users/\(NSUserName())").appendingPathComponent("Desktop"))
                    iconQuickItem(name: "Documents", icon: "doc.fill", color: .blue,
                                  url: URL(fileURLWithPath: "/Users/\(NSUserName())").appendingPathComponent("Documents"))
                    iconQuickItem(name: "Downloads", icon: "arrow.down.circle.fill", color: .green,
                                  url: URL(fileURLWithPath: "/Users/\(NSUserName())").appendingPathComponent("Downloads"))
                    iconQuickItem(name: "Pictures", icon: "photo.fill", color: .orange,
                                  url: URL(fileURLWithPath: "/Users/\(NSUserName())").appendingPathComponent("Pictures"))
                }
                .padding(.horizontal, 6)

                // External volumes
                let volURL = URL(fileURLWithPath: "/Volumes")
                if let vols = try? FileManager.default.contentsOfDirectory(at: volURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    let externals = vols.filter { $0.lastPathComponent != "Macintosh HD" }
                    if !externals.isEmpty {
                        Divider().padding(.vertical, 4)
                        sectionHeader(icon: "externaldrive.fill", title: "외장 디스크", color: .green)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(externals, id: \.path) { vol in
                                iconQuickItem(name: vol.lastPathComponent, icon: "externaldrive.fill", color: .green, url: vol)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }

                // Favorites
                if !favorites.isEmpty {
                    Divider().padding(.vertical, 4)
                    sectionHeader(icon: "star.fill", title: "즐겨찾기", color: .yellow)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(favorites, id: \.path) { url in
                            iconQuickItem(name: url.lastPathComponent, icon: "star.fill", color: .yellow, url: url)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } else {
                // Show subfolders as icons
                let columns = [GridItem(.flexible()), GridItem(.flexible())]
                if iconFolderContents.isEmpty {
                    Text("하위 폴더 없음")
                        .font(.system(size: AppTheme.iconSmall))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 20)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(iconFolderContents) { item in
                            VStack(spacing: 4) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(store.recursiveScannedFolders.contains(item.url.path) ? .yellow : .blue)
                                Text(item.name)
                                    .font(.system(size: 10))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(store.folderURL?.path == item.url.path ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.03))
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                // Double click → enter folder
                                openIconFolder(item.url)
                            }
                            .onTapGesture {
                                // Single click → load photos
                                store.startupMode = .viewer
                                store.loadFolder(item.url, restoreRatings: true)
                            }
                            .contextMenu {
                                Button("폴더 이름 변경") {
                                    renameFolderWithDialog(url: item.url)
                                }
                                Button("즐겨찾기에 추가") {
                                    store.addFavoriteFolder(item.url)
                                    favorites = store.loadFavoriteFolders()
                                }
                                Button("Finder에서 열기") {
                                    NSWorkspace.shared.open(item.url)
                                }
                                Divider()
                                folderTreeCopyCutPasteMenu(item.url, store: store)
                                Divider()
                                Button("새 폴더 만들기") { createNewSubfolder(in: item.url) }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private func iconQuickItem(name: String, icon: String, color: Color, url: URL) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(color)
            Text(name)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            openIconFolder(url)
        }
    }

    private func openIconFolder(_ url: URL) {
        currentIconFolder = url
        DispatchQueue.global(qos: .userInitiated).async {
            let children = FolderItem.loadChildren(of: url)
            DispatchQueue.main.async {
                iconFolderContents = children
            }
        }
    }

    private func navigateIconUp() {
        guard let current = currentIconFolder else { return }
        let parent = current.deletingLastPathComponent()
        if parent.path == "/" || parent.path == current.path {
            currentIconFolder = nil
            iconFolderContents = []
        } else {
            openIconFolder(parent)
        }
    }

    /// Build root folder items (can be called off the main thread)
    private func buildRootItems() -> [FolderItem] {
        // v8.8.0: Sandbox 컨테이너 가 아닌 실제 사용자 home 경로 사용.
        //   FileManager.homeDirectoryForCurrentUser 는 sandbox 에서 컨테이너 를 반환 → 그 안의
        //   Desktop 심볼릭 링크가 실제 경로로 이어지지만 엔타이틀먼트 가 컨테이너 경로 기준으로
        //   적용 안 돼 read-write 가 거부 됨. 실제 /Users/<name> 경로 로 접근 해야 정상 동작.
        let home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        var items: [FolderItem] = []

        let desktopURL = home.appendingPathComponent("Desktop")
        let documentsURL = home.appendingPathComponent("Documents")
        let downloadsURL = home.appendingPathComponent("Downloads")
        let picturesURL = home.appendingPathComponent("Pictures")

        if FileManager.default.fileExists(atPath: desktopURL.path) {
            var desktop = FolderItem(url: desktopURL, name: "Desktop")
            // Auto-expand Desktop on first load
            desktop.children = FolderItem.loadChildren(of: desktopURL)
            desktop.isExpanded = true
            items.append(desktop)
        }
        if FileManager.default.fileExists(atPath: documentsURL.path) {
            items.append(FolderItem(url: documentsURL, name: "Documents"))
        }
        if FileManager.default.fileExists(atPath: downloadsURL.path) {
            items.append(FolderItem(url: downloadsURL, name: "Downloads"))
        }
        if FileManager.default.fileExists(atPath: picturesURL.path) {
            items.append(FolderItem(url: picturesURL, name: "Pictures"))
        }

        // Volumes (external drives)
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        if let vols = try? FileManager.default.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for vol in vols.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                items.append(FolderItem(url: vol, name: vol.lastPathComponent))
            }
        }

        return items
    }
}

// MARK: - Folder Row View (Recursive)

struct FolderRowView: View {
    @Binding var item: FolderItem
    let store: PhotoStore
    let level: Int
    let onAddFavorite: (URL) -> Void
    // v9.1: 다중 선택 binding + 액션 콜백
    @Binding var multiSelection: Set<URL>
    var onShiftClick: ((URL) -> Void)? = nil
    var onSetAnchor: ((URL) -> Void)? = nil
    @State private var showEjectConfirm: Bool = false
    @State private var ejectResult: String?
    @State private var isDropTarget: Bool = false
    @State private var isRenaming: Bool = false
    @State private var renamingText: String = ""

    private var isMultiSelected: Bool { multiSelection.contains(item.url) }

    private var rowBackground: Color {
        if isMultiSelected { return Color.orange.opacity(0.25) }
        if store.folderURL?.path == item.url.path { return Color.accentColor.opacity(0.15) }
        return Color.clear
    }

    @ViewBuilder
    private var rowOverlay: some View {
        if isMultiSelected {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.orange.opacity(0.7), lineWidth: 1.5)
        }
    }

    private var isExternalVolume: Bool {
        item.url.path.hasPrefix("/Volumes") && level == 0
    }

    /// 지정된 폴더 안에 새 하위 폴더 생성
    private func createNewSubfolder(in parentURL: URL) {
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
                // 트리 아이템 자식 새로고침
                item.children = FolderItem.loadChildren(of: item.url)
                if !item.isExpanded { item.isExpanded = true }
                // 생성된 폴더가 현재 열려있는 폴더라면 그리드도 리로드
                if store.folderURL == parentURL {
                    store.loadFolder(parentURL, restoreRatings: true)
                }
                FolderPreviewCache.shared.invalidate(parentURL)
                NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
            } catch {
                store.showToastMessage("⚠️ 폴더 생성 실패: \(error.localizedDescription)")
            }
        }
    }

    private func startRenaming() {
        renamingText = item.url.lastPathComponent
        isRenaming = true
    }

    private func commitRename() {
        isRenaming = false
        let newName = renamingText.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != item.url.lastPathComponent else { return }
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: item.url, to: newURL)
            store.showToastMessage("'\(newName)'으로 이름 변경 완료")
            if store.folderURL == item.url {
                store.loadFolder(newURL, restoreRatings: true)
            }
        } catch {
            store.showToastMessage("이름 변경 실패: \(error.localizedDescription)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                // Disclosure triangle — 히트 영역 확대
                if item.hasSubfolders {
                    Button(action: { toggleExpand() }) {
                        Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 22)
                }

                // Folder icon + name + spacer = entire clickable area (generous padding)
                HStack(spacing: 8) {
                    Image(systemName: folderIcon)
                        .font(.system(size: 15))
                        .foregroundColor(folderColor)

                    if isRenaming {
                        TextField("", text: $renamingText, onCommit: {
                            commitRename()
                        })
                        .font(.system(size: 13))
                        .textFieldStyle(.plain)
                        .onExitCommand { isRenaming = false }
                    } else {
                        Text(item.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer()
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture {
                    let systemPaths = ["/Volumes", "/System", "/Library", "/usr", "/private"]
                    let isSystem = systemPaths.contains(item.url.path) || item.url.path == "/"

                    // v9.1: 모디파이어 분기 — Cmd 토글 / Shift 범위 추가 / 일반 단일 열기
                    let mods = NSEvent.modifierFlags
                    if mods.contains(.shift) && !isSystem {
                        onShiftClick?(item.url)
                        return
                    }
                    if mods.contains(.command) && !isSystem {
                        if multiSelection.contains(item.url) {
                            multiSelection.remove(item.url)
                        } else {
                            multiSelection.insert(item.url)
                            onSetAnchor?(item.url)
                        }
                        return
                    }

                    // 일반 클릭: 다중 선택 해제 + 단일 폴더 열기 + anchor 갱신
                    if !multiSelection.isEmpty { multiSelection.removeAll() }
                    onSetAnchor?(item.url)

                    // 트리 펼치기
                    if item.hasSubfolders && !item.isExpanded { toggleExpand() }

                    // v8.9 perf: 0.1s 딜레이 제거 — toggleExpand 와 loadFolder 는 모두 main async 라 충돌 없음.
                    if !isSystem {
                        store.startupMode = .viewer
                        store.loadFolder(item.url, restoreRatings: true)
                    }
                }

                // Disk capacity for external volumes
                if isExternalVolume {
                    let capacity = FolderBrowserHelpers.getDiskCapacity(url: item.url)
                    if !capacity.isEmpty {
                        Text(capacity)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                // Eject button for external volumes
                if isExternalVolume {
                    Button(action: { showEjectConfirm = true }) {
                        Image(systemName: "eject.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("'\(item.name)' 추출")
                    .alert("디스크 추출", isPresented: $showEjectConfirm) {
                        Button("추출", role: .destructive) {
                            // 추출 전 모든 파일 참조 해제
                            if store.folderURL?.path.hasPrefix(item.url.path) == true {
                                store.photos = []
                                store.selectedPhotoID = nil
                                store.folderURL = nil
                            }
                            PreviewImageCache.shared.clearCache()
                            ThumbnailCache.shared.removeAll()
                            // NSWorkspace로 추출 (App Sandbox 호환)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                do {
                                    try NSWorkspace.shared.unmountAndEjectDevice(at: item.url)
                                    plog("[EJECT] NSWorkspace eject success: \(item.name)\n")
                                    ejectResult = "'\(item.name)' 추출 완료"
                                } catch {
                                    plog("[EJECT] NSWorkspace eject error: \(error)\n")
                                    ejectResult = "'\(item.name)' 추출 실패: \(error.localizedDescription)"
                                }
                            }
                        }
                        Button("취소", role: .cancel) {}
                    } message: {
                        Text("'\(item.name)' 볼륨을 추출하시겠습니까?")
                    }
                }
            }
            .padding(.leading, CGFloat(level) * 16 + 8)
            .padding(.vertical, 4)
            .frame(minHeight: AppTheme.buttonHeight)
            .background(rowBackground)
            .overlay(rowOverlay)
            .alert("디스크 추출 결과", isPresented: Binding(get: { ejectResult != nil }, set: { if !$0 { ejectResult = nil } })) {
                Button("확인") { ejectResult = nil }
            } message: {
                Text(ejectResult ?? "")
            }
            .cornerRadius(4)
            .id(item.url.path)  // ScrollViewReader 스크롤 대상
            .onDrag {
                // 폴더 자체를 드래그 소스로
                NSItemProvider(object: item.url as NSURL)
            }
            .onDrop(of: [.fileURL], delegate: FolderDropDelegate(
                store: store,
                destination: item.url,
                isTargeted: $isDropTarget
            ))
            .overlay(
                isDropTarget ? RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2) : nil
            )
            .contextMenu {
                Button("즐겨찾기에 추가") { onAddFavorite(item.url) }
                Button("Finder에서 열기") { NSWorkspace.shared.open(item.url) }
                Divider()
                // v9.1: 다중 선택 토글 + 일괄 열기
                Button(isMultiSelected ? "다중 선택에서 제거" : "다중 선택에 추가") {
                    if isMultiSelected { multiSelection.remove(item.url) }
                    else { multiSelection.insert(item.url) }
                }
                if multiSelection.count >= 2 {
                    Button {
                        let urls = Array(multiSelection)
                        multiSelection.removeAll()
                        store.loadFoldersAggregated(urls)
                    } label: {
                        Label("선택한 \(multiSelection.count)개 폴더 일괄 열기", systemImage: "rectangle.stack.badge.plus")
                    }
                    Button("다중 선택 해제") { multiSelection.removeAll() }
                }
                Divider()
                folderTreeCopyCutPasteMenu(item.url, store: store)
                Divider()
                Button("폴더 이름 변경") {
                    startRenaming()
                }
                // 하위 폴더가 있는 경우에만 표시
                if item.hasSubfolders {
                    Button {
                        store.startupMode = .viewer
                        store.loadPhotosRecursive(from: item.url)
                    } label: {
                        Label("하위 폴더 포함 열기", systemImage: "folder.badge.plus")
                    }
                }
                Divider()
                Button("새 폴더 만들기") { createNewSubfolder(in: item.url) }
                if isExternalVolume {
                    Divider()
                    Button("디스크 추출") { showEjectConfirm = true }
                }
            }

            // Children — 안전한 인덱스 바인딩
            if item.isExpanded, let children = item.children, !children.isEmpty {
                ForEach(children.indices, id: \.self) { i in
                    if i < (item.children?.count ?? 0) {
                        FolderRowView(
                            item: Binding(
                                get: {
                                    guard let ch = item.children, i < ch.count else {
                                        return FolderItem(url: URL(fileURLWithPath: "/tmp"), name: "")
                                    }
                                    return ch[i]
                                },
                                set: { newValue in
                                    guard var ch = item.children, i < ch.count else { return }
                                    ch[i] = newValue
                                    item.children = ch
                                }
                            ),
                            store: store,
                            level: level + 1,
                            onAddFavorite: onAddFavorite,
                            multiSelection: $multiSelection,
                            onShiftClick: onShiftClick,
                            onSetAnchor: onSetAnchor
                        )
                    }
                }
            }
        }
    }

    private func toggleExpand() {
        if item.isExpanded {
            item.isExpanded = false
            // 접힌 폴더의 children 해제 → 메모리 절약 (재펼침 시 다시 로드)
            item.children = nil
        } else if item.children != nil {
            // children이 이미 로드됨 → 즉시 펼치기
            item.isExpanded = true
        } else {
            // children 로딩 후 펼치기
            let url = item.url
            DispatchQueue.global(qos: .userInitiated).async {
                let children = FolderItem.loadChildren(of: url)
                DispatchQueue.main.async {
                    if children.isEmpty {
                        item.hasSubfolders = false
                    } else {
                        item.children = children
                        item.isExpanded = true
                    }
                }
            }
        }
    }

    private func handleFileDrop(providers: [NSItemProvider], destination: URL) {
        var fileURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                // 폴더가 아닌 파일만
                if !url.hasDirectoryPath {
                    fileURLs.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            guard !fileURLs.isEmpty else { return }
            store.movePhotosToFolder(fileURLs: fileURLs, destination: destination)
        }
    }

    private var folderIcon: String {
        if item.url.path.hasPrefix("/Volumes") && level == 0 {
            return "externaldrive.fill"
        }
        return item.isExpanded ? "folder.fill" : "folder"
    }

    private var folderColor: Color {
        // v8.9.7+: 재귀 모드에 포함된 폴더는 노란 아이콘
        if store.recursiveScannedFolders.contains(item.url.path) {
            return .yellow
        }
        if item.url.path.hasPrefix("/Volumes") && level == 0 {
            return .green
        }
        return .blue
    }
}

// MARK: - Folder Browser Helpers

enum FolderBrowserHelpers {
    /// Count image files in a folder (non-recursive, single-pass)
    static func countImages(in url: URL) -> Int {
        let fm = FileManager.default
        let imageExts = FileMatchingService.jpgExtensions
            .union(FileMatchingService.rawExtensions)
            .union(FileMatchingService.imageExtensions)
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return 0 }
        var count = 0
        for item in contents {
            if imageExts.contains(item.pathExtension.lowercased()) { count += 1 }
        }
        return count
    }

    /// Disk capacity cache (10초 유효)
    private static var capacityCache: [String: (value: String, time: Date)] = [:]
    private static let capacityLock = NSLock()

    /// Get disk capacity string (e.g. "2.53/4.00 TB") — 10초 캐싱
    static func getDiskCapacity(url: URL) -> String {
        let key = url.path
        capacityLock.lock()
        if let cached = capacityCache[key], Date().timeIntervalSince(cached.time) < 10 {
            capacityLock.unlock()
            return cached.value
        }
        capacityLock.unlock()

        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) else { return "" }
        let total = values.volumeTotalCapacity ?? 0
        let available = values.volumeAvailableCapacity ?? 0
        let used = total - available
        let totalGB = Double(total) / 1_000_000_000
        let usedGB = Double(used) / 1_000_000_000
        let result: String
        if totalGB >= 1000 {
            result = String(format: "%.2f/%.2f TB", usedGB / 1000, totalGB / 1000)
        } else {
            result = String(format: "%.1f/%.1f GB", usedGB, totalGB)
        }

        capacityLock.lock()
        capacityCache[key] = (value: result, time: Date())
        capacityLock.unlock()
        return result
    }
}

// MARK: - 즐겨찾기 우클릭 메뉴 (NSMenu 기반 — SwiftUI contextMenu 버그 회피)

struct FavoriteContextMenuHelper: NSViewRepresentable {
    let url: URL
    let store: PhotoStore
    @Binding var favorites: [URL]
    let renameFn: (URL) -> Void
    let createFn: (URL) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RightClickView()
        view.menuProvider = { [url, store] in
            let menu = NSMenu()
            let openItem = NSMenuItem(title: "폴더 열기", action: #selector(RightClickView.menuAction(_:)), keyEquivalent: "")
            openItem.tag = 1
            menu.addItem(openItem)
            menu.addItem(NSMenuItem.separator())
            let renameItem = NSMenuItem(title: "이름 변경", action: #selector(RightClickView.menuAction(_:)), keyEquivalent: "")
            renameItem.tag = 2
            menu.addItem(renameItem)
            let removeItem = NSMenuItem(title: "즐겨찾기에서 제거", action: #selector(RightClickView.menuAction(_:)), keyEquivalent: "")
            removeItem.tag = 3
            menu.addItem(removeItem)
            let finderItem = NSMenuItem(title: "Finder에서 열기", action: #selector(RightClickView.menuAction(_:)), keyEquivalent: "")
            finderItem.tag = 4
            menu.addItem(finderItem)
            menu.addItem(NSMenuItem.separator())
            let newFolderItem = NSMenuItem(title: "새 폴더 만들기", action: #selector(RightClickView.menuAction(_:)), keyEquivalent: "")
            newFolderItem.tag = 5
            menu.addItem(newFolderItem)
            return menu
        }
        view.actionHandler = { [url, store] tag in
            DispatchQueue.main.async {
                switch tag {
                case 1:
                    store.startupMode = .viewer
                    store.loadFolder(url, restoreRatings: true)
                case 2:
                    self.renameFn(url)
                case 3:
                    store.removeFavoriteFolder(url)
                    self.favorites = []
                    DispatchQueue.main.async { self.favorites = store.loadFavoriteFolders() }
                case 4:
                    NSWorkspace.shared.open(url)
                case 5:
                    self.createFn(url)
                default: break
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class RightClickView: NSView {
    var menuProvider: (() -> NSMenu)?
    var actionHandler: ((Int) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        for item in menu.items where item.action != nil {
            item.target = self
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc func menuAction(_ sender: NSMenuItem) {
        actionHandler?(sender.tag)
    }
}

// MARK: - Async Folder Thumbnail

struct AsyncFolderThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.gray.opacity(0.3))
                    )
            }
        }
        .clipped()
        .onAppear { loadFirstImage() }
    }

    private func loadFirstImage() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let exts = FileMatchingService.jpgExtensions
            guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
            let firstImage = contents.prefix(50).first { exts.contains($0.pathExtension.lowercased()) }
            guard let imgURL = firstImage,
                  let source = CGImageSourceCreateWithURL(imgURL as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceThumbnailMaxPixelSize: 100,
                      kCGImageSourceCreateThumbnailFromImageIfAbsent: true
                  ] as CFDictionary) else { return }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async { self.image = img }
        }
    }
}

// MARK: - Project Folder Count (async)

struct ProjectFolderCount: View {
    let url: URL
    @State private var count: Int?

    var body: some View {
        Group {
            if let c = count, c > 0 {
                Text("\(c)")
                    .font(.system(size: AppTheme.iconSmall))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            if count == nil {
                let u = url
                DispatchQueue.global(qos: .utility).async {
                    let c = FolderBrowserHelpers.countImages(in: u)
                    DispatchQueue.main.async { count = c }
                }
            }
        }
    }
}

// MARK: - Folder Drop Delegate (파일 이동)

struct FolderDropDelegate: DropDelegate {
    let store: PhotoStore
    let destination: URL
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        var fileURLs: [URL] = []
        var folderURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                // 자기 자신이나 부모로 이동 방지
                if url == destination || destination.path.hasPrefix(url.path + "/") { return }
                if url.hasDirectoryPath {
                    folderURLs.append(url)
                } else {
                    fileURLs.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            let allSources = fileURLs + folderURLs
            guard !allSources.isEmpty else { return }

            // 공용 엔트리포인트 호출 — 충돌 다이얼로그 + 백그라운드 전송 + 진행률 창 + 언두
            performFileTransferToFolder(
                urls: allSources,
                destFolder: destination,
                isCut: true,               // 드래그 드롭은 항상 이동 동작
                store: store,
                clearClipboardOnSuccess: false
            )
        }
        return true
    }
}
//
//  SidebarMetadataPanels.swift
//  PhotoRawManager
//
//  v8.9.4: 사이드바 메타데이터/편집 탭용 narrow 레이아웃 패널.
//  ExifInfoView 는 가로 한 줄 디자인이라 좁은 폭에서 글자 단위로 깨짐 → 세로 row 형식으로 재구성.
//

import SwiftUI

// MARK: - 메타데이터 정보 패널 (읽기 전용, narrow)

struct SidebarMetadataView: View {
    let photo: PhotoItem
    @State private var exif: ExifData?
    @State private var rawExif: ExifData?
    @State private var iptc: XMPService.IPTCMetadata?

    private var displayExif: ExifData? { rawExif ?? exif }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // 파일명 (truncated middle)
                Text(photo.fileNameWithExtension)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // 카메라 / 렌즈 / 메이커 (v9.0.2)
                if let make = displayExif?.cameraMake, !make.isEmpty {
                    rowKV("제조사", make)
                }
                if let cam = displayExif?.cameraModel {
                    rowKV("카메라", cam)
                }
                if let lens = displayExif?.lensModel {
                    rowKV("렌즈", lens)
                }

                // 촬영 설정
                if let e = displayExif {
                    if e.iso != nil || e.shutterSpeed != nil || e.aperture != nil || e.focalLength != nil
                        || e.exposureBias != nil {
                        Divider()
                    }
                    if let iso = e.iso { rowKV("ISO", "\(iso)") }
                    if let shutter = e.shutterSpeed { rowKV("셔터", shutter) }
                    if let aperture = e.aperture { rowKV("조리개", String(format: "f/%.1f", aperture)) }
                    if let focal = e.focalLength { rowKV("초점거리", String(format: "%.0fmm", focal)) }
                    if let bias = e.exposureBias, abs(bias) > 0.01 {
                        rowKV("노출보정", String(format: "%+.1f EV", bias))
                    }
                }

                // v9.0.2: 픽쳐스타일 / 색공간 / 비트심도 / DPI
                if let p = displayExif {
                    if p.pictureStyle != nil || p.pictureStyleColorSpace != nil
                        || p.bitDepth != nil || p.dpiX != nil {
                        Divider()
                    }
                    if let ps = p.pictureStyle, !ps.isEmpty { rowKV("픽쳐스타일", ps) }
                    if let cs = p.pictureStyleColorSpace, !cs.isEmpty { rowKV("색공간", cs) }
                    if let bd = p.bitDepth { rowKV("비트심도", "\(bd)bit") }
                    if let dx = p.dpiX, let dy = p.dpiY {
                        rowKV("DPI", dx == dy ? "\(dx)" : "\(dx) × \(dy)")
                    }
                }

                // GPS (있을 때만)
                if let e = displayExif, e.hasGPS {
                    Divider()
                    if let place = e.placeName, !place.isEmpty {
                        rowKV("위치", place)
                    }
                    if let lat = e.latitude, let lon = e.longitude {
                        rowKV("좌표", String(format: "%.5f, %.5f", lat, lon))
                    }
                }

                // 일시
                if let date = displayExif?.dateTaken {
                    Divider()
                    rowKV("촬영일시", formatDate(date))
                }

                // 파일 정보
                Divider()
                let ext = photo.jpgURL.pathExtension.uppercased()
                rowKV("파일", ext)
                if photo.jpgFileSize > 0 {
                    rowKV("크기", byteString(photo.jpgFileSize))
                }
                if photo.hasRAW, photo.rawFileSize > 0 {
                    rowKV("RAW", byteString(photo.rawFileSize))
                }
                if let dims = exifDimensions {
                    rowKV("픽셀", dims)
                }

                // 평점/라벨
                if photo.rating > 0 || photo.colorLabel != .none {
                    Divider()
                    if photo.rating > 0 {
                        rowKV("별점", String(repeating: "★", count: photo.rating))
                    }
                    if photo.colorLabel != .none {
                        rowKV("라벨", photo.colorLabel.rawValue)
                    }
                }

                // IPTC (있을 때만)
                if let m = iptc, !m.title.isEmpty || !m.description.isEmpty || !m.keywords.isEmpty {
                    Divider()
                    if !m.title.isEmpty { rowKV("제목", m.title) }
                    if !m.description.isEmpty { rowKV("설명", m.description, multiline: true) }
                    if !m.keywords.isEmpty { rowKV("키워드", m.keywords.joined(separator: ", "), multiline: true) }
                    if !m.creator.isEmpty { rowKV("작가", m.creator) }
                    if !m.copyright.isEmpty { rowKV("저작권", m.copyright) }
                }

                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .onAppear { loadAll() }
        .onChange(of: photo.id) { _, _ in loadAll() }
    }

    private func rowKV(_ key: String, _ value: String, multiline: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(multiline ? nil : 1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var exifDimensions: String? {
        if let w = displayExif?.imageWidth, let h = displayExif?.imageHeight {
            return "\(w) × \(h)"
        }
        return nil
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd HH:mm:ss"
        return f.string(from: d)
    }

    private func byteString(_ size: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: size)
    }

    private func loadAll() {
        let url = photo.jpgURL
        let rawURL = photo.hasRAW ? photo.rawURL : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let e = ExifService.extractExif(from: url)
            var re: ExifData? = nil
            if let r = rawURL {
                re = ExifService.extractExif(from: r)
            }
            let m = XMPService.readIPTCMetadata(from: url)
            DispatchQueue.main.async {
                self.exif = e
                self.rawExif = re
                self.iptc = m
            }
        }
    }
}

// MARK: - 인라인 메타데이터 편집기 (사이드바용)

struct SidebarMetadataEditor: View {
    let photo: PhotoItem
    @State private var title: String = ""
    @State private var description: String = ""
    @State private var keywords: String = ""
    @State private var creator: String = ""
    @State private var copyright: String = ""
    @State private var loaded: Bool = false
    @State private var isSaving: Bool = false
    @State private var savedAt: Date? = nil
    @State private var errorMsg: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(photo.fileNameWithExtension)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)

                fieldGroup("제목") {
                    TextField("사진 제목", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                fieldGroup("설명") {
                    TextEditor(text: $description)
                        .font(.system(size: 11))
                        .frame(minHeight: 50, maxHeight: 80)
                        .padding(2)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(4)
                }

                fieldGroup("키워드 (쉼표 구분)") {
                    TextField("결혼식, 야외, 인물", text: $keywords)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                fieldGroup("작가") {
                    TextField("작가 이름", text: $creator)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                fieldGroup("저작권") {
                    TextField("© 2026 작가 이름", text: $copyright)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                HStack(spacing: 6) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        } else {
                            Label("저장", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)

                    Button(action: { loadFromFile() }) {
                        Label("되돌리기", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)
                    Spacer()
                }

                if let savedAt = savedAt {
                    Text("저장됨 \(formatTime(savedAt))")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
                if let errorMsg = errorMsg {
                    Text(errorMsg)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }

                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .onAppear { loadFromFile() }
        .onChange(of: photo.id) { _, _ in loadFromFile() }
    }

    @ViewBuilder
    private func fieldGroup<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            content()
        }
    }

    private func loadFromFile() {
        let url = photo.jpgURL
        DispatchQueue.global(qos: .userInitiated).async {
            let m = XMPService.readIPTCMetadata(from: url) ?? XMPService.IPTCMetadata()
            DispatchQueue.main.async {
                self.title = m.title
                self.description = m.description
                self.keywords = m.keywords.joined(separator: ", ")
                self.creator = m.creator
                self.copyright = m.copyright
                self.loaded = true
                self.errorMsg = nil
            }
        }
    }

    private func save() {
        let url = photo.jpgURL
        var m = XMPService.IPTCMetadata()
        m.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        m.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        m.keywords = keywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        m.creator = creator.trimmingCharacters(in: .whitespacesAndNewlines)
        m.copyright = copyright.trimmingCharacters(in: .whitespacesAndNewlines)

        isSaving = true
        errorMsg = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = XMPService.writeIPTCMetadata(url: url, metadata: m)
            DispatchQueue.main.async {
                isSaving = false
                if ok {
                    savedAt = Date()
                } else {
                    errorMsg = "저장 실패"
                }
            }
        }
    }

    private func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
