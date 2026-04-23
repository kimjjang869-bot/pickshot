import SwiftUI
import Foundation
import AppKit
import AppleArchive
import System

extension PhotoStore {
    // MARK: - Folder Size Cache

    /// 폴더 사이즈 캐시 갱신 (photos 변경 시 1회만 계산)
    func updateFolderSizeCache() {
        guard !photos.isEmpty else { cachedFolderSizeText = ""; return }
        let totalBytes = photos.reduce(Int64(0)) { sum, photo in
            guard !photo.isFolder && !photo.isParentFolder else { return sum }
            return sum + photo.jpgFileSize + photo.rawFileSize
        }
        if totalBytes <= 0 {
            cachedFolderSizeText = "\(photos.filter { !$0.isFolder }.count)장"
        } else if totalBytes > 1_073_741_824 {
            cachedFolderSizeText = String(format: "%.1f GB", Double(totalBytes) / 1_073_741_824)
        } else if totalBytes > 1_048_576 {
            cachedFolderSizeText = String(format: "%.0f MB", Double(totalBytes) / 1_048_576)
        } else {
            cachedFolderSizeText = String(format: "%.0f KB", Double(totalBytes) / 1024)
        }
    }

    // MARK: - Folder Watching

    func setupFolderWatcher() {
        folderWatcher.onNewFilesDetected = { [weak self] newURLs in
            guard let self = self, self.isFolderWatchingEnabled else { return }
            self.handleNewFiles(newURLs)
        }
        folderWatcher.onFolderStructureChanged = { [weak self] in
            guard let self = self, self.isFolderWatchingEnabled else { return }
            // 디바운스: 2초 내 중복 리로드 방지
            self.folderReloadWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, let url = self.folderURL else { return }
                fputs("[WATCH] 폴더 구조 변경 감지 → 리로드\n", stderr)
                self.loadFolder(url, restoreRatings: true)
            }
            self.folderReloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
    }

    func handleNewFiles(_ newURLs: Set<URL>) {
        guard let folderURL = folderURL else { return }
        let capturedURL = folderURL

        // Re-scan the folder to pick up new files with proper matching
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let allItems = FileMatchingService.scanAndMatch(folderURL: capturedURL)

            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.folderURL == capturedURL else { return } // folder changed, discard
                let existingNames = Set(self.photos.map { $0.fileName })
                var addedItems: [PhotoItem] = []

                for item in allItems {
                    if !existingNames.contains(item.fileName) {
                        var photo = item
                        photo.exifData = ExifService.extractExif(from: item.jpgURL)
                        photo.jpgFileSize = (try? FileManager.default.attributesOfItem(atPath: item.jpgURL.path)[.size] as? Int64) ?? 0
                        if let rawURL = item.rawURL {
                            photo.rawFileSize = (try? FileManager.default.attributesOfItem(atPath: rawURL.path)[.size] as? Int64) ?? 0
                            photo.rawExifData = ExifService.extractExif(from: rawURL)
                        }
                        addedItems.append(photo)
                    }
                }

                if !addedItems.isEmpty {
                    self.photos.append(contentsOf: addedItems)
                    // Preload thumbnails for new items
                    let newURLs = addedItems.map { $0.jpgURL }
                    DispatchQueue.global(qos: .utility).async {
                        let loader = ThumbnailLoader.shared
                        for url in newURLs {
                            loader.prefetch(url: url)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Session Persistence

    func restoreLastSession() {
        // Try security-scoped bookmark first (App Sandbox)
        if let url = SandboxBookmarkService.resolveBookmark(key: "lastFolder") {
            loadFolder(url, restoreRatings: true)
            return
        }
        // Fallback to path string (backward compat)
        guard let path = defaults.string(forKey: lastFolderKey) else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        loadFolder(url, restoreRatings: true)
    }

    func saveLastFolder() {
        guard let url = folderURL else { return }
        defaults.set(url.path, forKey: lastFolderKey)
        SandboxBookmarkService.saveBookmark(for: url, key: "lastFolder")
    }

    /// URL 이 속한 볼륨 루트를 찾음 (예: /Volumes/4tb/photos/2025 → /Volumes/4tb)
    private static func findVolumeRoot(for url: URL) -> URL {
        let path = url.path
        // /Volumes/XXX/... → /Volumes/XXX
        if path.hasPrefix("/Volumes/") {
            let components = path.split(separator: "/", maxSplits: 3)
            if components.count >= 2 {
                return URL(fileURLWithPath: "/\(components[0])/\(components[1])")
            }
        }
        // 그 외 (홈 폴더 등) → 원래 URL 반환
        return url
    }

    // MARK: - Folder Loading

    func loadFolder(_ url: URL, restoreRatings: Bool = false) {
        guard beginFolderLoad(url) else { return }

        // Sandbox: 1) 직접 접근 가능? 2) bookmark 으로 접근? 3) NSOpenPanel
        let canAccess = FileManager.default.isReadableFile(atPath: url.path)
            || SandboxBookmarkService.startFolderAccess(for: url)
        if !canAccess {
            // Sandbox: 볼륨 루트를 NSOpenPanel 으로 한번만 허용하면 전체 하위 접근 가능
            let volumeRoot = Self.findVolumeRoot(for: url)
            let displayName = volumeRoot.lastPathComponent
            AppLogger.log(.folder, "Sandbox 접근 불가 → 볼륨 접근 요청: \(displayName)")
            DispatchQueue.main.async { [weak self] in
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.directoryURL = volumeRoot  // 볼륨 루트 바로 열기
                panel.message = "'\(displayName)' 볼륨에 접근합니다. 열기를 눌러주세요."
                panel.prompt = "열기"
                if panel.runModal() == .OK, let granted = panel.url {
                    SandboxBookmarkService.saveBookmark(for: granted, key: "volume_\(granted.path)")
                    SandboxBookmarkService.saveBookmark(for: granted, key: "lastFolder")
                    let targetURL = FileManager.default.isReadableFile(atPath: url.path) ? url : granted
                    self?.endFolderLoad(url)
                    self?.loadFolder(targetURL, restoreRatings: restoreRatings)
                }
            }
            endFolderLoad(url)
            return
        }

        AppLogger.log(.folder, "loadFolder: \(url.lastPathComponent) path=\(url.path)")
        let loadStart = CFAbsoluteTimeGetCurrent()

        // 이전 폴더의 pending save를 먼저 플러시 (폴더 바뀌기 전 현재 폴더 경로로 저장)
        saveRatingsNow()

        // 이전 폴더 로딩/프리페치 취소 + 미리보기 캐시 비움
        ThumbnailLoader.shared.cancelAll()
        PreviewImageCache.shared.clearCache()
        idlePrefetchGeneration += 1  // 이전 프리페치 취소
        thumbsGeneration += 1
        thumbsLoaded = 0
        thumbsTotal = 0

        folderURL = url
        isRecursiveMode = false  // 일반 폴더 열기 시 재귀 모드 해제

        // Save folder info in background (non-blocking)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.saveLastFolder()
            self?.addRecentFolder(url)
        }
        addToFolderHistory(url)

        if isFolderWatchingEnabled {
            // Start watching on background thread to avoid blocking main thread on slow disks
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.folderWatcher.startWatching(folder: url)
            }
        }

        // Auto-optimize for NAS/network volumes
        ThumbnailLoader.shared.optimizeForPath(url.path)

        // 느린 디스크 여부 캐시 — PhotoPreviewView가 stage2 스킵 결정에 활용
        // (검사 자체가 sysctl/fs metadata 호출이므로 background에서)
        let folderPath = url.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let isSlow = SystemSpec.isSlowDisk(path: folderPath)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.folderURL?.path == folderPath else { return }
                self.currentFolderIsSlowDisk = isSlow
                if isSlow {
                    fputs("[STORAGE] 느린 디스크 감지 — stage2 미리보기 스킵 (\(folderPath))\n", stderr)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var items = FileMatchingService.scanAndMatch(folderURL: url)

            // Add parent folder navigation
            let parent = url.deletingLastPathComponent()
            let home = FileManager.default.homeDirectoryForCurrentUser
            let desktop = home.appendingPathComponent("Desktop")
            let isAtTopLevel = url.path == desktop.path || url.path == home.path || url.path == "/" || parent.path == "/"
            if !isAtTopLevel && parent.path != url.path {
                var parentItem = PhotoItem(jpgURL: parent)
                parentItem.isFolder = true
                parentItem.isParentFolder = true
                items.insert(parentItem, at: 0)
            }

            // Phase 1: Show photos immediately
            let phase1Elapsed = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            AppLogger.log(.folder, "Phase 1 scan complete: \(items.filter { !$0.isFolder }.count) photos, \(items.filter { $0.isFolder && !$0.isParentFolder }.count) subfolders in \(String(format: "%.1f", phase1Elapsed))ms")
            // Pre-sort on background thread (avoid main thread sort)
            let sorted: [PhotoItem]
            switch self?.sortMode ?? .dateDesc {
            case .dateAsc: sorted = items.sorted { $0.fileModDate < $1.fileModDate }
            case .dateDesc: sorted = items.sorted { $0.fileModDate > $1.fileModDate }
            case .nameAsc: sorted = items.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            case .nameDesc: sorted = items.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedDescending }
            default: sorted = items
            }

            DispatchQueue.main.async {
                guard self?.folderURL == url else {
                    self?.endFolderLoad(url)
                    return
                }

                // photos 교체 전에 기존 선택 파일명 캡처 (리로드 시 선택 유지용)
                var prevFileName: String? = nil
                if let prevID = self?.selectedPhotoID,
                   let prevIdx = self?._photoIndex[prevID],
                   let count = self?.photos.count, prevIdx < count {
                    prevFileName = self?.photos[prevIdx].fileName
                }

                // Set photos first (triggers didSet but sort is already done)
                self?.photos = sorted
                if restoreRatings { self?.applySavedRatings() }

                // Select first non-folder photo on NEXT run loop
                DispatchQueue.main.async {
                    guard self?.folderURL == url else { return }

                    // 기존 파일명을 새 목록에서 찾아 선택 유지
                    // (PhotoItem.id는 UUID()로 매번 새로 생성되므로 파일명으로 매칭)
                    var preserved = false
                    if let name = prevFileName,
                       let match = sorted.first(where: { $0.fileName == name && !$0.isFolder && !$0.isParentFolder }) {
                        self?.selectedPhotoID = match.id
                        self?.selectedPhotoIDs = [match.id]
                        self?.scrollTrigger += 1
                        preserved = true
                    }

                    if !preserved {
                        // 선택 없거나 사라졌을 때만 첫 사진 선택
                        let firstPhoto = sorted.first(where: { !$0.isParentFolder && !$0.isFolder })
                            ?? sorted.first
                        if let fp = firstPhoto {
                            self?.selectedPhotoID = fp.id
                            self?.selectedPhotoIDs = [fp.id]
                            self?.scrollTrigger += 1
                        }
                    }
                    // 열 수는 ContentView.updateGridColumns(leftW)에서 계산
                }
                // Prewarming 시점/범위는 디스크 속도에 따라 다르게:
                // - SSD: visible 표시 후 1.5초 (visible 로딩과 충돌 방지, ±40장으로 충분)
                // - HDD/SD: 폴더 클릭 후 visible이 표시되자마자 0.5초에 시작 (HDD는 어차피 천천히 채워짐)
                //   → 사용자가 다음 스크롤 전까지 미리 채워둘 시간 확보
                // HDD: visible 로딩이 거의 끝난 후(2초)에 시작 — 디스크 경합 회피가 visible 표시 속도에 가장 큰 영향
                // SSD: 1.5초 (visible 로딩이 빨라서 충돌 적음)
                let prewarmDelay: TimeInterval = (self?.currentFolderIsSlowDisk ?? false) ? 2.0 : 1.5
                DispatchQueue.main.asyncAfter(deadline: .now() + prewarmDelay) {
                    self?.preloadAllThumbnails()
                }
                // EXIF 배치 로딩 (목록뷰: 200장, 그리드: 50장)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let count = self?.viewMode == .list ? 200 : 50
                    self?.batchLoadExif(count: count)
                }
                // 아이들 시 고화질 미리보기 프리캐싱 (3초 후 시작)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self?.startIdlePreviewPrefetch()
                }
                self?.endFolderLoad(url)
            }

            // Phase 2: Read EXIF on-demand only (not upfront)
            // EXIF is loaded per-photo when selected via loadExifOnDemand()
            // This eliminates the heavy batch EXIF read that caused lag on folder switch
            let phase2Elapsed = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            AppLogger.log(.folder, "Folder ready (no Phase 2): \(items.count) items in \(String(format: "%.1f", phase2Elapsed))ms")
        }
    }

    /// 하위 폴더 포함 열기 — 모든 하위 디렉토리의 이미지를 재귀적으로 로딩
    func loadPhotosRecursive(from url: URL) {
        AppLogger.log(.folder, "loadPhotosRecursive: \(url.lastPathComponent) path=\(url.path)")
        let loadStart = CFAbsoluteTimeGetCurrent()

        // 이전 썸네일 로딩 취소
        ThumbnailLoader.shared.cancelAll()
        thumbsGeneration += 1
        thumbsLoaded = 0
        thumbsTotal = 0

        folderURL = url
        isRecursiveMode = true

        // 폴더 정보 저장 (논블로킹)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.saveLastFolder()
            self?.addRecentFolder(url)
        }
        addToFolderHistory(url)

        // NAS/네트워크 볼륨 최적화
        ThumbnailLoader.shared.optimizeForPath(url.path)

        DispatchQueue.main.async { [weak self] in
            self?.isLoading = true
            self?.loadingStatus = "하위 폴더 스캔 중..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // recursive: true 로 모든 하위 폴더 스캔
            var items = FileMatchingService.scanAndMatch(folderURL: url, recursive: true)

            // 재귀 모드에서는 폴더 아이템 제거 (하위 폴더 내용이 이미 포함됨)
            items.removeAll { $0.isFolder }

            // 상위 폴더 네비게이션 추가
            let parent = url.deletingLastPathComponent()
            let home = FileManager.default.homeDirectoryForCurrentUser
            let desktop = home.appendingPathComponent("Desktop")
            let isAtTopLevel = url.path == desktop.path || url.path == home.path || url.path == "/" || parent.path == "/"
            if !isAtTopLevel && parent.path != url.path {
                var parentItem = PhotoItem(jpgURL: parent)
                parentItem.isFolder = true
                parentItem.isParentFolder = true
                items.insert(parentItem, at: 0)
            }

            let photoCount = items.filter { !$0.isFolder && !$0.isParentFolder }.count
            let phase1Elapsed = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            AppLogger.log(.folder, "Recursive scan: \(photoCount) photos from all subfolders in \(String(format: "%.1f", phase1Elapsed))ms")

            // 정렬은 filteredPhotos에서 sortMode에 따라 자동 적용
            let sorted = items

            DispatchQueue.main.async {
                guard self?.folderURL == url else { return }
                self?.photos = sorted
                self?.isLoading = false
                self?.loadingStatus = ""
                self?.showToastMessage("하위 폴더 포함 \(photoCount)장 로드됨")

                // 첫 번째 사진 선택
                DispatchQueue.main.async {
                    guard self?.folderURL == url else { return }
                    let firstPhoto = sorted.first(where: { !$0.isParentFolder && !$0.isFolder })
                        ?? sorted.first
                    if let fp = firstPhoto {
                        self?.selectedPhotoID = fp.id
                        self?.selectedPhotoIDs = [fp.id]
                        self?.scrollTrigger += 1
                    }
                }
                // 썸네일 prewarming: SSD 1.5초 / HDD-SD 0.5초 (HDD는 천천히 채워지므로 빨리 시작)
                // HDD: visible 로딩이 거의 끝난 후(2초)에 시작 — 디스크 경합 회피가 visible 표시 속도에 가장 큰 영향
                // SSD: 1.5초 (visible 로딩이 빨라서 충돌 적음)
                let prewarmDelay: TimeInterval = (self?.currentFolderIsSlowDisk ?? false) ? 2.0 : 1.5
                DispatchQueue.main.asyncAfter(deadline: .now() + prewarmDelay) {
                    self?.preloadAllThumbnails()
                }
            }
        }
    }

    /// 재귀 모드 해제 — 현재 폴더만 다시 로드
    func exitRecursiveMode() {
        guard isRecursiveMode, let url = folderURL else { return }
        isRecursiveMode = false
        loadFolder(url, restoreRatings: true)
    }

    // MARK: - ZIP 파일 열기

    func openZipFile(_ zipURL: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pickshot_zip_\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // App Sandbox 호환: AppleArchive 프레임워크로 ZIP 압축 해제 (macOS 13+)
            if #available(macOS 13.0, *) {
                guard let fileStream = ArchiveByteStream.fileStream(
                    path: FilePath(zipURL.path),
                    mode: .readOnly,
                    options: [],
                    permissions: FilePermissions(rawValue: 0o644)
                ) else {
                    fputs("[ZIP] 파일 스트림 열기 실패: \(zipURL.lastPathComponent)\n", stderr)
                    try? FileManager.default.removeItem(at: tempDir)
                    return
                }
                defer { try? fileStream.close() }

                guard let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: fileStream) else {
                    fputs("[ZIP] 압축 해제 스트림 실패: \(zipURL.lastPathComponent)\n", stderr)
                    try? FileManager.default.removeItem(at: tempDir)
                    return
                }
                defer { try? decompressStream.close() }

                guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream) else {
                    fputs("[ZIP] 디코드 스트림 실패: \(zipURL.lastPathComponent)\n", stderr)
                    try? FileManager.default.removeItem(at: tempDir)
                    return
                }
                defer { try? decodeStream.close() }

                guard let extractStream = ArchiveStream.extractStream(
                    extractingTo: FilePath(tempDir.path),
                    flags: [.ignoreOperationNotPermitted]
                ) else {
                    fputs("[ZIP] 추출 스트림 실패: \(zipURL.lastPathComponent)\n", stderr)
                    try? FileManager.default.removeItem(at: tempDir)
                    return
                }
                defer { try? extractStream.close() }

                try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
            } else {
                fputs("[ZIP] ZIP 열기는 macOS 13 이상에서 지원됩니다\n", stderr)
                try? FileManager.default.removeItem(at: tempDir)
                return
            }

            // 이전 임시 폴더 정리
            cleanupZipTemp()

            zipTempDir = tempDir
            fputs("[ZIP] 열기: \(zipURL.lastPathComponent) → \(tempDir.path)\n", stderr)

            // 임시 폴더를 폴더로 로딩
            loadFolder(tempDir, restoreRatings: false)
        } catch {
            fputs("[ZIP] 오류: \(error.localizedDescription)\n", stderr)
        }
    }

    func cleanupZipTemp() {
        if let dir = zipTempDir {
            try? FileManager.default.removeItem(at: dir)
            zipTempDir = nil
        }
    }

    // MARK: - Folder Open / Navigation

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "사진이 있는 폴더를 선택하세요 (jpg/raw 하위 폴더도 자동 스캔)"

        if panel.runModal() == .OK, let url = panel.url {
            // NSOpenPanel scope 만료 전에 bookmark 동기 저장
            SandboxBookmarkService.saveBookmark(for: url, key: "lastFolder")
            SandboxBookmarkService.saveBookmark(for: url, key: "volume_\(url.path)")
            loadFolder(url)
        }
    }

    func navigateBack() {
        guard folderHistoryIndex > 0 else { return }
        folderHistoryIndex -= 1
        let url = folderHistory[folderHistoryIndex]
        loadFolder(url)
    }

    func navigateForward() {
        guard folderHistoryIndex < folderHistory.count - 1 else { return }
        folderHistoryIndex += 1
        let url = folderHistory[folderHistoryIndex]
        loadFolder(url)
    }

    func addToFolderHistory(_ url: URL) {
        // Trim forward history
        if folderHistoryIndex < folderHistory.count - 1 {
            folderHistory = Array(folderHistory.prefix(folderHistoryIndex + 1))
        }
        folderHistory.append(url)
        folderHistoryIndex = folderHistory.count - 1
    }

    // MARK: - Recent Folders

    func addRecentFolder(_ url: URL) {
        var recents = loadRecentFolders()
        recents.removeAll { $0.path == url.path }
        recents.insert(url, at: 0)
        if recents.count > 5 { recents = Array(recents.prefix(5)) }
        defaults.set(recents.map { $0.path }, forKey: recentFoldersKey)
        SandboxBookmarkService.saveBookmarks(for: recents, keyPrefix: "recentFolders")
    }

    func loadRecentFolders() -> [URL] {
        // Try security-scoped bookmarks first (App Sandbox)
        let bookmarked = SandboxBookmarkService.resolveBookmarkURLs(keyPrefix: "recentFolders")
        if !bookmarked.isEmpty { return bookmarked }
        // Fallback to path strings (backward compat)
        let paths = defaults.stringArray(forKey: recentFoldersKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Favorite Folders

    func addFavoriteFolder(_ url: URL) {
        var favs = loadFavoriteFolders()
        guard !favs.contains(where: { $0.path == url.path }) else { return }
        favs.append(url)
        defaults.set(favs.map { $0.path }, forKey: favoriteFoldersKey)
        SandboxBookmarkService.saveBookmarks(for: favs, keyPrefix: "favoriteFolders")
    }

    func removeFavoriteFolder(_ url: URL) {
        var favs = loadFavoriteFolders()
        favs.removeAll { $0.path == url.path }
        defaults.set(favs.map { $0.path }, forKey: favoriteFoldersKey)
        SandboxBookmarkService.saveBookmarks(for: favs, keyPrefix: "favoriteFolders")
    }

    func loadFavoriteFolders() -> [URL] {
        // Try security-scoped bookmarks first (App Sandbox)
        let bookmarked = SandboxBookmarkService.resolveBookmarkURLs(keyPrefix: "favoriteFolders")
        if !bookmarked.isEmpty { return bookmarked }
        // Fallback to path strings (backward compat)
        let paths = defaults.stringArray(forKey: favoriteFoldersKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    func setFavoriteNickname(_ url: URL, name: String) {
        var dict = defaults.dictionary(forKey: favoriteNicknamesKey) as? [String: String] ?? [:]
        if name.isEmpty || name == url.lastPathComponent {
            dict.removeValue(forKey: url.path)
        } else {
            dict[url.path] = name
        }
        defaults.set(dict, forKey: favoriteNicknamesKey)
    }

    func favoriteNickname(for url: URL) -> String {
        let dict = defaults.dictionary(forKey: favoriteNicknamesKey) as? [String: String] ?? [:]
        return dict[url.path] ?? url.lastPathComponent
    }
}
