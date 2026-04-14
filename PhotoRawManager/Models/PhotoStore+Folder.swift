import SwiftUI
import Foundation
import AppKit

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
                            loader.load(url: url) { _ in }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Session Persistence

    func restoreLastSession() {
        guard let path = defaults.string(forKey: lastFolderKey) else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        loadFolder(url, restoreRatings: true)
    }

    func saveLastFolder() {
        guard let url = folderURL else { return }
        defaults.set(url.path, forKey: lastFolderKey)
    }

    // MARK: - Folder Loading

    func loadFolder(_ url: URL, restoreRatings: Bool = false) {
        AppLogger.log(.folder, "loadFolder: \(url.lastPathComponent) path=\(url.path)")
        let loadStart = CFAbsoluteTimeGetCurrent()

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
                guard self?.folderURL == url else { return }

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
                // Preload thumbnails with slight delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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
                // 썸네일 프리로드
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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

            // unzip 명령어로 임시 폴더에 풀기
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", "-q", zipURL.path, "-d", tempDir.path]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                fputs("[ZIP] unzip 실패: \(zipURL.lastPathComponent)\n", stderr)
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
    }

    func loadRecentFolders() -> [URL] {
        let paths = defaults.stringArray(forKey: recentFoldersKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Favorite Folders

    func addFavoriteFolder(_ url: URL) {
        var favs = loadFavoriteFolders()
        guard !favs.contains(where: { $0.path == url.path }) else { return }
        favs.append(url)
        defaults.set(favs.map { $0.path }, forKey: favoriteFoldersKey)
    }

    func removeFavoriteFolder(_ url: URL) {
        var favs = loadFavoriteFolders()
        favs.removeAll { $0.path == url.path }
        defaults.set(favs.map { $0.path }, forKey: favoriteFoldersKey)
    }

    func loadFavoriteFolders() -> [URL] {
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
