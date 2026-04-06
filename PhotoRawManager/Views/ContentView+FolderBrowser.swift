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
        // isDirectoryKey was prefetched above — resourceValues uses cached value, no extra stat()
        var dirs: [URL] = []
        dirs.reserveCapacity(contents.count / 4)
        for item in contents {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                dirs.append(item)
            }
        }
        dirs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return dirs.map { FolderItem(url: $0, name: $0.lastPathComponent) }
    }

    static func hasImages(in url: URL) -> Bool {
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "cr2", "cr3", "nef", "arw", "orf", "raf", "dng", "rw2"]
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        return contents.contains { imageExts.contains($0.pathExtension.lowercased()) }
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
    @State private var currentIconFolder: URL?
    @State private var iconFolderContents: [FolderItem] = []

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
            // 앱 시작 시 이미 마운트된 메모리카드 체크
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let fm = FileManager.default
                if let volumes = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil) {
                    fputs("[MOUNT] Startup check: \(volumes.map { $0.lastPathComponent })\n", stderr)
                    for vol in volumes {
                        MemoryCardBackupService.shared.checkAndPromptIfMemoryCard(vol)
                    }
                }
            }

            // Watch for volume mount/unmount
            let ws = NSWorkspace.shared.notificationCenter
            ws.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { notification in
                if let volumePath = notification.userInfo?["NSDevicePath"] as? String {
                    fputs("[MOUNT] Volume mounted: \(volumePath)\n", stderr)
                    let volumeURL = URL(fileURLWithPath: volumePath)
                    MemoryCardBackupService.shared.checkAndPromptIfMemoryCard(volumeURL)
                } else {
                    fputs("[MOUNT] Volume mounted but no path\n", stderr)
                }
                refreshRootItems()
            }
            ws.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { notification in
                if let volumePath = notification.userInfo?["NSDevicePath"] as? String {
                    AppLogger.log(.folder, "Volume unmounted: \(volumePath)")
                }
                refreshRootItems()
            }
        }
        .onChange(of: store.folderURL) { newURL in
            guard let url = newURL else { return }
            expandTreeToPath(url)
        }
        // 폴더 생성/삭제/이동 시 트리 자동 새로고침
        .onReceive(NotificationCenter.default.publisher(for: .init("FolderTreeNeedsRefresh"))) { _ in
            refreshRootItems()
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
            favorites = store.loadFavoriteFolders()  // UI 갱신
            store.showToastMessage("'\(newName)'으로 표시 이름 변경")
        } else if response == .alertThirdButtonReturn {
            store.setFavoriteNickname(url, name: "")
            favorites = store.loadFavoriteFolders()
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
                // 트리 새로고침
                refreshRootItems()
            } catch {
                store.showToastMessage("⚠️ 폴더 생성 실패: \(error.localizedDescription)")
            }
        }
    }

    private func refreshRootItems() {
        DispatchQueue.global(qos: .userInitiated).async {
            let items = buildRootItems()
            let favs = store.loadFavoriteFolders()
            let recents = store.loadRecentFolders()
            DispatchQueue.main.async {
                rootItems = items
                favorites = favs
                recentFolders = recents
                // rootItems 로드 완료 후 현재 폴더 경로로 트리 확장
                if let url = store.folderURL {
                    expandTreeToPath(url)
                }
            }
        }
    }

    /// Auto-expand tree to show the currently loaded folder (async to avoid blocking main thread)
    private func expandTreeToPath(_ targetURL: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
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
                    VStack(alignment: .leading, spacing: 0) {
                        folderTreeSection
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .onChange(of: store.folderURL) { newURL in
                    guard let url = newURL else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo(url.path, anchor: .center)
                    }
                }
                .onAppear {
                    if let url = store.folderURL {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
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

            // Favorites (always visible at bottom)
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(icon: "star.fill", title: "즐겨찾기", color: .yellow)

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
                                HStack(spacing: 10) {
                                    AsyncFolderThumbnail(url: url)
                                        .frame(width: 45, height: 34)
                                        .cornerRadius(4)

                                    Text(url.lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
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
            .frame(height: favoritesHeight)
        }
    }

    // MARK: - Folder Tree Section

    private var folderTreeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(icon: "folder.fill", title: "로컬 폴더", color: .blue)

            ForEach(rootItems.indices, id: \.self) { i in
                FolderRowView(item: $rootItems[i], store: store, level: 0, onAddFavorite: { url in
                    store.addFavoriteFolder(url)
                    favorites = store.loadFavoriteFolders()
                })
            }
        }
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
                    HStack(spacing: 10) {
                        AsyncFolderThumbnail(url: url)
                            .frame(width: 50, height: 38)
                            .cornerRadius(4)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.favoriteNickname(for: url))
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if store.favoriteNickname(for: url) != url.lastPathComponent {
                                Text(url.lastPathComponent)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        ProjectFolderCount(url: url)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(store.folderURL?.path == url.path ? Color.accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.startupMode = .viewer
                        store.loadFolder(url, restoreRatings: true)
                    }
                    .contextMenu {
                        Button("이름 변경") { renameFolderWithDialog(url: url) }
                        Divider()
                        Button("즐겨찾기에서 제거") {
                            store.removeFavoriteFolder(url)
                            favorites = store.loadFavoriteFolders()
                        }
                        Button("Finder에서 열기") { NSWorkspace.shared.open(url) }
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
                                  url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
                    iconQuickItem(name: "Documents", icon: "doc.fill", color: .blue,
                                  url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
                    iconQuickItem(name: "Downloads", icon: "arrow.down.circle.fill", color: .green,
                                  url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                    iconQuickItem(name: "Pictures", icon: "photo.fill", color: .orange,
                                  url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures"))
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
                                    .foregroundColor(.blue)
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
        let home = FileManager.default.homeDirectoryForCurrentUser
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
    @State private var showEjectConfirm: Bool = false
    @State private var ejectResult: String?
    @State private var imageCount: Int?
    @State private var isDropTarget: Bool = false
    @State private var isRenaming: Bool = false
    @State private var renamingText: String = ""

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

                    // Expand tree immediately
                    if item.hasSubfolders && !item.isExpanded { toggleExpand() }

                    // Load folder (slight delay to let tree animation complete)
                    if !isSystem {
                        store.startupMode = .viewer
                        let targetURL = item.url
                        DispatchQueue.main.async {
                            store.loadFolder(targetURL, restoreRatings: true)
                        }
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
                            // 진단: 어떤 프로세스가 볼륨을 잡고 있는지
                            let volumePath = item.url.path
                            DispatchQueue.global(qos: .userInitiated).async {
                                let proc = Process()
                                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                                proc.arguments = ["+D", volumePath]
                                let pipe = Pipe()
                                proc.standardOutput = pipe
                                proc.standardError = pipe
                                try? proc.run()
                                proc.waitUntilExit()
                                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                                let output = String(data: data, encoding: .utf8) ?? ""
                                fputs("[EJECT] lsof before eject:\n\(output)\n", stderr)

                                // diskutil eject 사용 (NSWorkspace API보다 안정적)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    let proc = Process()
                                    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                                    proc.arguments = ["eject", volumePath]
                                    let pipe = Pipe()
                                    proc.standardOutput = pipe
                                    proc.standardError = pipe
                                    do {
                                        try proc.run()
                                        proc.waitUntilExit()
                                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                                        let output = String(data: data, encoding: .utf8) ?? ""
                                        fputs("[EJECT] diskutil result: \(output)\n", stderr)
                                        if proc.terminationStatus == 0 {
                                            ejectResult = "'\(item.name)' 추출 완료"
                                        } else {
                                            ejectResult = "'\(item.name)' 추출 실패: \(output)"
                                        }
                                    } catch {
                                        fputs("[EJECT] diskutil error: \(error)\n", stderr)
                                        ejectResult = "'\(item.name)' 추출 실패: \(error.localizedDescription)"
                                    }
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
            .background(store.folderURL?.path == item.url.path ? Color.accentColor.opacity(0.15) : Color.clear)
            .alert("디스크 추출 결과", isPresented: Binding(get: { ejectResult != nil }, set: { if !$0 { ejectResult = nil } })) {
                Button("확인") { ejectResult = nil }
            } message: {
                Text(ejectResult ?? "")
            }
            .cornerRadius(4)
            .id(item.url.path)  // ScrollViewReader 스크롤 대상
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

            .onAppear { }

            // Children
            if item.isExpanded, let children = item.children {
                ForEach(children.indices, id: \.self) { i in
                    FolderRowView(
                        item: Binding(
                            get: { guard let children = item.children, i < children.count else { return FolderItem(url: URL(fileURLWithPath: "/"), name: "?") }; return children[i] },
                            set: { newValue in guard var children = item.children, i < children.count else { return }; children[i] = newValue; item.children = children }
                        ),
                        store: store,
                        level: level + 1,
                        onAddFavorite: onAddFavorite
                    )
                }
            }
        }
    }

    private func toggleExpand() {
        if item.isExpanded {
            item.isExpanded = false
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
        if item.url.path.hasPrefix("/Volumes") && level == 0 {
            return .green
        }
        return .blue
    }
}

// MARK: - Folder Browser Helpers

enum FolderBrowserHelpers {
    /// Count image files in a folder (non-recursive)
    static func countImages(in url: URL) -> Int {
        let fm = FileManager.default
        let imageExts = FileMatchingService.jpgExtensions
            .union(FileMatchingService.rawExtensions)
            .union(FileMatchingService.imageExtensions)
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return 0 }
        return contents.filter { imageExts.contains($0.pathExtension.lowercased()) }.count
    }

    /// Get disk capacity string (e.g. "2.53/4.00 TB")
    static func getDiskCapacity(url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) else { return "" }
        let total = values.volumeTotalCapacity ?? 0
        let available = values.volumeAvailableCapacity ?? 0
        let used = total - available
        let totalGB = Double(total) / 1_000_000_000
        let usedGB = Double(used) / 1_000_000_000
        if totalGB >= 1000 {
            return String(format: "%.2f/%.2f TB", usedGB / 1000, totalGB / 1000)
        }
        return String(format: "%.1f/%.1f GB", usedGB, totalGB)
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
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      !url.hasDirectoryPath else { return }
                fileURLs.append(url)
            }
        }

        group.notify(queue: .main) {
            guard !fileURLs.isEmpty else { return }
            store.movePhotosToFolder(fileURLs: fileURLs, destination: destination)
        }
        return true
    }
}
