import Foundation
import SwiftUI
import ImageIO
import Vision

// MARK: - Analysis Options

struct AnalysisOptions {
    var checkBlur: Bool = true
    var checkExposure: Bool = false
    var checkContrast: Bool = false
    var checkClosedEyes: Bool = true
    var checkFaceFocus: Bool = true
    var checkExifInfo: Bool = true
}

enum SortMode: String, CaseIterable {
    case dateAsc = "촬영시간 (오래된순)"
    case dateDesc = "촬영시간 (최신순)"
    case nameAsc = "파일명 (ㄱ→ㅎ)"
    case nameDesc = "파일명 (ㅎ→ㄱ)"
    case ratingDesc = "별점 (높은순)"
    case ratingAsc = "별점 (낮은순)"
    case spacePickFirst = "스페이스 셀렉 우선"
    case sizeDesc = "파일 크기 (큰순)"
    case sizeAsc = "파일 크기 (작은순)"
    case extensionSort = "확장자별"
    case cameraSort = "카메라별"

    var icon: String {
        switch self {
        case .dateAsc: return "clock"
        case .dateDesc: return "clock.fill"
        case .nameAsc: return "textformat.abc"
        case .nameDesc: return "textformat.abc"
        case .ratingDesc: return "star.fill"
        case .ratingAsc: return "star"
        case .spacePickFirst: return "checkmark.circle.fill"
        case .sizeDesc: return "arrow.down.doc"
        case .sizeAsc: return "arrow.up.doc"
        case .extensionSort: return "doc.text"
        case .cameraSort: return "camera"
        }
    }
}

enum QualityFilter: String, CaseIterable {
    case all = "전체"
    case spacePick = "스페이스 셀렉"
    case aiPick = "AI 추천"
    case goodOnly = "양호 이상"
    case issuesOnly = "문제 있음"
    case bestOfDuplicates = "중복 베스트"
    case noDuplicates = "중복 제외"
}

enum ViewMode: String, CaseIterable {
    case grid = "썸네일"
    case list = "목록"

    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

enum StartupMode {
    case viewer
    case tethering
}

enum LayoutMode: String, CaseIterable {
    case gridPreview = "그리드+미리보기"
    case filmstrip = "필름스트립"

    var icon: String {
        switch self {
        case .gridPreview: return "sidebar.left"
        case .filmstrip: return "rectangle.split.1x2"
        }
    }
}

class PhotoStore: ObservableObject {
    @Published var startupMode: StartupMode?
    @Published var photosVersion: Int = 0
    var _suppressDidSet = false
    @Published var photos: [PhotoItem] = [] {
        didSet {
            guard !_suppressDidSet else { return }
            photosVersion += 1; _cachedFiltered = nil; _cacheKey = ""; rebuildIndex()
        }
    }
    @Published var selectedPhotoID: UUID?
    @Published var selectedPhotoIDs: Set<UUID> = []
    /// Incremented when keyboard navigation happens, triggers scroll
    @Published var scrollTrigger: Int = 0
    var scrollAnchor: UnitPoint = .bottom
    /// true when key is held down (OS key repeat), false for actual press
    var isKeyRepeat: Bool = false
    @Published var minimumRatingFilter: Int = 0 { didSet { _cachedFiltered = nil; _cacheKey = "" } }
    @Published var sortMode: SortMode = .dateDesc {
        didSet {
            _cachedFiltered = nil; _cacheKey = ""
            _filteredIndex.removeAll(); _filteredIndexVersion = ""
            UserDefaults.standard.set(sortMode.rawValue, forKey: "savedSortMode")
            scrollTrigger += 1
        }
    }
    @Published var viewMode: ViewMode = .grid
    @Published var thumbnailSize: CGFloat = 120
    @Published var previewResolution: Int = 0  // 0 = 원본, 1000/2000/3000/4000
    @Published var qualityFilter: QualityFilter = .all { didSet { _cachedFiltered = nil; _cacheKey = "" } }
    @Published var isAnalyzing = false
    @Published var analyzeProgress: Double = 0
    @Published var showAnalysisOptions = false
    @Published var analysisOptions = AnalysisOptions()
    private var analysisCancel = false
    @Published var folderURL: URL?
    @Published var hSplitPosition: CGFloat = 500
    @Published var vSplitPosition: CGFloat = 950
    @Published var isLoading = false
    @Published var loadingProgress: Double = 0  // 0~1
    @Published var loadingStatus: String = ""
    @Published var thumbsLoaded: Int = 0
    @Published var thumbsTotal: Int = 0
    private var thumbsGeneration: Int = 0
    var thumbsStartTime: CFAbsoluteTime = 0
    var isPreloadingThumbs: Bool { thumbsLoaded < thumbsTotal && thumbsTotal > 0 }
    var thumbsETA: String {
        guard thumbsLoaded > 0, thumbsTotal > thumbsLoaded else { return "" }
        let elapsed = CFAbsoluteTimeGetCurrent() - thumbsStartTime
        guard elapsed > 0.5 else { return "" }  // Wait 0.5s before showing ETA
        let rate = Double(thumbsLoaded) / elapsed
        let remaining = Double(thumbsTotal - thumbsLoaded) / rate
        if remaining < 60 { return "\(Int(remaining))초" }
        return "\(Int(remaining / 60))분 \(Int(remaining.truncatingRemainder(dividingBy: 60)))초"
    }
    @Published var exportProgress: Double = 0
    @Published var isExporting = false
    @Published var conversionProgress: Double = 0
    @Published var conversionTotal: Int = 0
    @Published var conversionDone: Int = 0
    @Published var conversionCancelled: Bool = false
    @Published var conversionResult: RAWConversionService.ConversionResult?
    var conversionStartTime: CFAbsoluteTime = 0

    /// Estimated time remaining for conversion
    var conversionETA: String {
        guard conversionDone > 0, conversionTotal > conversionDone else { return "" }
        let elapsed = CFAbsoluteTimeGetCurrent() - conversionStartTime
        let rate = Double(conversionDone) / elapsed
        let remaining = Double(conversionTotal - conversionDone) / rate
        if remaining < 60 {
            return "\(Int(remaining))초 남음"
        } else {
            return "\(Int(remaining / 60))분 \(Int(remaining.truncatingRemainder(dividingBy: 60)))초 남음"
        }
    }
    var isConverting: Bool { conversionDone < conversionTotal && conversionTotal > 0 && !conversionCancelled }
    @Published var showExportSheet = false
    @Published var exportOpenAsRawConvert = false  // Open export sheet directly in RAW→JPG tab
    @Published var showMatchingSheet = false
    @Published var showShortcutHelp = false
    @Published var showCompare = false
    @Published var showSlideshow = false
    @Published var colorLabelFilter: ColorLabel = .none { didSet { _cachedFiltered = nil; _cacheKey = "" } }
    @Published var slideshowInterval: Double = 3.0
    @Published var isFolderWatchingEnabled: Bool = true
    @Published var showMetadataOverlay: Bool = false
    @Published var sceneTagFilter: String? = nil { didSet { _cachedFiltered = nil; _cacheKey = "" } }
    @Published var isClassifyingScenes: Bool = false
    @Published var classifyProgress: Double = 0
    @Published var layoutMode: LayoutMode = .gridPreview
    var shouldOpenFolderBrowser: Bool = false
    @Published var showBatchRename: Bool = false
    @Published var showImportResult: Bool = false
    var lastImportResult: PickshotImportResult?
    @Published var showMap: Bool = false
    @Published var toastMessage: String = ""
    @Published var showToast: Bool = false

    func showToastMessage(_ msg: String) {
        toastMessage = msg
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.showToast = false
        }
    }
    @Published var showDeleteOriginalConfirm: Bool = false
    var pendingDeleteIDs: Set<UUID> = []
    var faceGroups: [Int: [UUID]] = [:]  // Not @Published
    var faceThumbnails: [Int: NSImage] = [:]  // Not @Published - accessed directly, no re-render trigger
    @Published var faceGroupFilter: Int? = nil { didSet { _cachedFiltered = nil; _cacheKey = "" } }
    @Published var isGroupingFaces: Bool = false
    @Published var faceGroupProgress: Double = 0
    @Published var showGoogleDrive: Bool = false
    @Published var showAbout: Bool = false
    @Published var showDeleteConfirm: Bool = false
    @Published var showFolderBrowser: Bool = true
    @Published var showFileTypeBadge: Bool = UserDefaults.standard.object(forKey: "showFileTypeBadge") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFileTypeBadge, forKey: "showFileTypeBadge") }
    }
    @Published var showFileExtension: Bool = UserDefaults.standard.object(forKey: "showFileExtension") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFileExtension, forKey: "showFileExtension") }
    }
    @Published var folderHistory: [URL] = []
    @Published var folderHistoryIndex: Int = -1
    @Published var photosToRemove: Set<UUID> = []
    @Published var isDarkMode: Bool = UserDefaults.standard.object(forKey: "isDarkMode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isDarkMode, forKey: "isDarkMode") }
    }

    // AI Smart Classification
    @Published var isAIClassifying: Bool = false
    @Published var aiClassifyProgress: (Int, Int) = (0, 0)
    @Published var aiCategoryFilter: String? = nil { didSet { _cachedFiltered = nil; _cacheKey = "" } }   // 카테고리별 필터

    // Search
    @Published var searchText: String = "" { didSet { _cachedFiltered = nil; _cacheKey = "" } }

    // MARK: - Undo Stack
    private var undoStack: [(action: String, photoIDs: Set<UUID>, oldRatings: [UUID: Int], oldSP: [UUID: Bool], oldGSelect: [UUID: Bool])] = []
    private let maxUndoSteps = 20

    private let defaults = UserDefaults.standard
    private let layoutModeKey = "layoutMode"
    private let lastFolderKey = "lastFolderPath"
    private let ratingsKey = "photoRatings"
    private let folderWatcher = FolderWatcherService()

    private func pushUndo(action: String, photoIDs: Set<UUID>) {
        var oldRatings: [UUID: Int] = [:]
        var oldSP: [UUID: Bool] = [:]
        var oldGSelect: [UUID: Bool] = [:]
        for id in photoIDs {
            if let i = _photoIndex[id], i < photos.count {
                oldRatings[id] = photos[i].rating
                oldSP[id] = photos[i].isSpacePicked
                oldGSelect[id] = photos[i].isGSelected
            }
        }
        undoStack.append((action: action, photoIDs: photoIDs, oldRatings: oldRatings, oldSP: oldSP, oldGSelect: oldGSelect))
        if undoStack.count > maxUndoSteps {
            undoStack.removeFirst(undoStack.count - maxUndoSteps)
        }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        var copy = photos
        for id in last.photoIDs {
            guard let i = _photoIndex[id], i < copy.count else { continue }
            if let oldRating = last.oldRatings[id] { copy[i].rating = oldRating }
            if let oldSP = last.oldSP[id] { copy[i].isSpacePicked = oldSP }
            if let oldG = last.oldGSelect[id] { copy[i].isGSelected = oldG }
        }
        applyPhotosUpdate(copy)
        saveRatings()
    }

    init() {
        // Restore layout mode
        if let savedLayout = defaults.string(forKey: layoutModeKey),
           let mode = LayoutMode(rawValue: savedLayout) {
            layoutMode = mode
        }
        // Restore sort mode
        if let savedSort = UserDefaults.standard.string(forKey: "savedSortMode"),
           let mode = SortMode(rawValue: savedSort) {
            sortMode = mode
        }
        setupFolderWatcher()
    }

    func setLayoutMode(_ mode: LayoutMode) {
        layoutMode = mode
        defaults.set(mode.rawValue, forKey: layoutModeKey)
    }

    // MARK: - Folder Watching

    private func setupFolderWatcher() {
        folderWatcher.onNewFilesDetected = { [weak self] newURLs in
            guard let self = self, self.isFolderWatchingEnabled else { return }
            self.handleNewFiles(newURLs)
        }
    }

    private func handleNewFiles(_ newURLs: Set<URL>) {
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

    private func restoreLastSession() {
        guard let path = defaults.string(forKey: lastFolderKey) else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        loadFolder(url, restoreRatings: true)
    }

    private func saveLastFolder() {
        guard let url = folderURL else { return }
        defaults.set(url.path, forKey: lastFolderKey)
    }

    /// Lazy-load RAW EXIF when a photo is selected (not at folder load time)
    /// EXIF loading is now handled by ExifInfoView directly
    func ensureRawExifLoaded(for photoID: UUID) {
        // No-op: ExifInfoView loads its own EXIF via @State
    }

    private func saveRatings() {
        var ratings: [String: Int] = [:]
        for photo in photos where photo.rating > 0 {
            ratings[photo.fileName] = photo.rating
        }
        defaults.set(ratings, forKey: ratingsKey)
    }

    private func applySavedRatings() {
        guard let ratings = defaults.dictionary(forKey: ratingsKey) as? [String: Int] else { return }
        for i in 0..<photos.count {
            if let saved = ratings[photos[i].fileName] {
                photos[i].rating = saved
            }
        }
    }

    // Fast O(1) lookup instead of O(n) linear search
    private(set) var _photoIndex: [UUID: Int] = [:]

    func rebuildIndex() {
        _photoIndex.removeAll()
        for (i, p) in photos.enumerated() {
            _photoIndex[p.id] = i
        }
    }

    var selectedPhoto: PhotoItem? {
        guard let id = selectedPhotoID else { return nil }
        if let idx = _photoIndex[id], idx < photos.count, photos[idx].id == id {
            return photos[idx]
        }
        // Fallback if index is stale
        return photos.first { $0.id == id }
    }

    var multiSelectedPhotos: [PhotoItem] {
        selectedPhotoIDs.compactMap { id in
            if let idx = _photoIndex[id], idx < photos.count, photos[idx].id == id {
                return photos[idx]
            }
            return nil
        }
    }

    var selectionCount: Int {
        selectedPhotoIDs.count
    }

    /// Anchor index for shift-range mouse selection
    private var shiftClickAnchorIndex: Int?

    func selectPhoto(_ id: UUID, cmdKey: Bool, shiftKey: Bool = false) {
        if let idx = _photoIndex[id], idx < photos.count {
            AppLogger.log(.selection, "selectPhoto: \(photos[idx].fileName)\(cmdKey ? " +Cmd" : "")\(shiftKey ? " +Shift" : "")")
        }
        if shiftKey {
            // Shift+Click: range selection from anchor
            let list = filteredPhotos
            ensureFilteredIndex()
            guard let toIndex = _filteredIndex[id] else {
                selectedPhotoIDs = [id]
                selectedPhotoID = id
                return
            }

            // Set anchor on first shift-click
            if shiftClickAnchorIndex == nil {
                if let currentID = selectedPhotoID, let idx = _filteredIndex[currentID] {
                    shiftClickAnchorIndex = idx
                } else {
                    shiftClickAnchorIndex = toIndex
                }
            }

            guard let anchor = shiftClickAnchorIndex else { return }
            let rangeStart = min(anchor, toIndex)
            let rangeEnd = max(anchor, toIndex)

            // Replace selection with exact range (shrinks if clicking back)
            let safeEnd = min(rangeEnd, list.count - 1)
            guard safeEnd >= rangeStart else { return }
            var newSelection = Set<UUID>()
            for i in rangeStart...safeEnd {
                newSelection.insert(list[i].id)
            }
            selectedPhotoIDs = newSelection
            selectedPhotoID = id
        } else if cmdKey {
            shiftClickAnchorIndex = nil
            // Cmd+Click: toggle individual selection
            if selectedPhotoIDs.contains(id) {
                selectedPhotoIDs.remove(id)
                if selectedPhotoID == id {
                    selectedPhotoID = selectedPhotoIDs.first
                }
            } else {
                selectedPhotoIDs.insert(id)
                selectedPhotoID = id
            }
        } else {
            // Normal click: single select, clear multi
            shiftClickAnchorIndex = nil
            selectedPhotoIDs = [id]
            selectedPhotoID = id
        }
    }

    func selectAll() {
        let ids = Set(filteredPhotos.map { $0.id })
        selectedPhotoIDs = ids
    }

    func deselectAll() {
        selectedPhotoIDs.removeAll()
    }

    /// Remove selected photos from the list (NOT from disk)
    func removeSelectedFromList() {
        let idsToRemove = photosToRemove
        guard !idsToRemove.isEmpty else { return }

        let list = filteredPhotos
        ensureFilteredIndex()
        // Find the index of the first selected photo to determine next selection
        var nextID: UUID? = nil
        if let currentID = selectedPhotoID, let currentFilteredIdx = _filteredIndex[currentID] {
            // Try to select the next photo after the last removed one
            for i in (currentFilteredIdx + 1)..<list.count {
                if !idsToRemove.contains(list[i].id) {
                    nextID = list[i].id
                    break
                }
            }
            // If no next, try previous
            if nextID == nil {
                for i in stride(from: currentFilteredIdx - 1, through: 0, by: -1) {
                    if !idsToRemove.contains(list[i].id) {
                        nextID = list[i].id
                        break
                    }
                }
            }
        }

        // Remove from photos array (NOT from disk)
        photos = photos.filter { !idsToRemove.contains($0.id) }

        // Update selection
        selectedPhotoIDs.subtract(idsToRemove)
        if let next = nextID {
            selectedPhotoID = next
            selectedPhotoIDs = [next]
        } else if let first = filteredPhotos.first {
            selectedPhotoID = first.id
            selectedPhotoIDs = [first.id]
        } else {
            selectedPhotoID = nil
            selectedPhotoIDs = []
        }

        photosToRemove = []
        scrollTrigger &+= 1
    }

    /// Remove photos from list without file deletion (backspace default)
    func removePhotosFromList(ids: Set<UUID>) {
        photosToRemove = ids
        removeSelectedFromList()
    }

    /// Delete original files from disk + remove from list (backspace with setting)
    func deleteOriginalFiles(ids: Set<UUID>) {
        let fm = FileManager.default
        var deleted = 0
        var failed = 0

        for id in ids {
            guard let idx = _photoIndex[id], idx < photos.count else { continue }
            let photo = photos[idx]
            guard !photo.isFolder && !photo.isParentFolder else { continue }

            // Delete JPG
            do {
                if fm.fileExists(atPath: photo.jpgURL.path) {
                    try fm.trashItem(at: photo.jpgURL, resultingItemURL: nil)
                }
            } catch { failed += 1 }

            // Delete RAW
            if let rawURL = photo.rawURL {
                do {
                    if fm.fileExists(atPath: rawURL.path) {
                        try fm.trashItem(at: rawURL, resultingItemURL: nil)
                    }
                } catch { failed += 1 }
            }
            deleted += 1
        }

        AppLogger.log(.export, "Deleted \(deleted) files (\(failed) failed) to Trash")

        // Remove from list
        removePhotosFromList(ids: ids)
    }

    func idx(_ id: UUID) -> Int? {
        if let i = _photoIndex[id], i >= 0, i < photos.count, photos[i].id == id { return i }
        return nil
    }

    func setColorLabel(_ label: ColorLabel, for photoID: UUID) {
        guard let i = idx(photoID) else { return }
        photos[i].colorLabel = (photos[i].colorLabel == label) ? .none : label
    }

    func setColorLabelForSelected(_ label: ColorLabel) {
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id] { photos[i].colorLabel = label }
        }
    }

    func toggleSpacePick(for photoID: UUID) {
        guard let i = idx(photoID) else { return }
        pushUndo(action: "SP 토글", photoIDs: [photoID])
        photos[i].isSpacePicked.toggle()
    }

    func toggleSpacePickForSelected() {
        pushUndo(action: "일괄 SP 토글", photoIDs: selectedPhotoIDs)
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id] { photos[i].isSpacePicked.toggle() }
        }
    }

    var spacePickedCount: Int {
        photos.lazy.filter { $0.isSpacePicked }.count
    }

    func setRatingForSelected(_ rating: Int) {
        pushUndo(action: "일괄 별점 변경", photoIDs: selectedPhotoIDs)
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id] { photos[i].rating = rating }
        }
        saveRatings()
    }

    func isSelected(_ id: UUID) -> Bool {
        selectedPhotoIDs.contains(id)
    }

    // Cached filtered results - invalidated when inputs change
    private var _cachedFiltered: [PhotoItem]?
    private var _cacheKey: String = ""

    func invalidateCache() {
        _cachedFiltered = nil
        _cacheKey = ""
        photosVersion += 1
    }

    /// Replace photos array while preserving selection state
    /// Forces SwiftUI to detect the change by assigning a new array
    private func applyPhotosUpdate(_ newPhotos: [PhotoItem]) {
        let savedSel = selectedPhotoID
        let savedMulti = selectedPhotoIDs
        photos = newPhotos   // triggers didSet → rebuildIndex, invalidate cache
        selectedPhotoID = savedSel
        selectedPhotoIDs = savedMulti
    }

    var filteredPhotos: [PhotoItem] {
        let key = "\(photosVersion)"
        if key == _cacheKey, let cached = _cachedFiltered {
            return cached
        }

        // Capture filter values once to avoid repeated property access
        let minRating = minimumRatingFilter
        let colorFilter = colorLabelFilter
        let qFilter = qualityFilter
        let sceneTag = sceneTagFilter
        let fgID = faceGroupFilter
        let aiCat = aiCategoryFilter
        let search = searchText.lowercased()
        let aiUsabilityLevel: String?
        let aiCatValue: String?
        if let cat = aiCat {
            if cat.hasPrefix("__usability__") {
                aiUsabilityLevel = cat.replacingOccurrences(of: "__usability__", with: "")
                aiCatValue = nil
            } else {
                aiUsabilityLevel = nil
                aiCatValue = cat
            }
        } else {
            aiUsabilityLevel = nil
            aiCatValue = nil
        }

        // Single-pass filter + bucket into parentFolders / folders / files
        var parentItems: [PhotoItem] = []
        var folders: [PhotoItem] = []
        var files: [PhotoItem] = []

        for photo in photos {
            // Folders/parent folders skip all content filters
            if photo.isParentFolder {
                parentItems.append(photo)
                continue
            }
            if photo.isFolder {
                folders.append(photo)
                continue
            }

            // Rating filter
            if minRating > 0 && photo.rating < minRating { continue }
            // Color label filter
            if colorFilter != .none && photo.colorLabel != colorFilter { continue }
            // Quality filter
            switch qFilter {
            case .all:
                break
            case .spacePick:
                if !photo.isSpacePicked { continue }
            case .aiPick:
                if !photo.isAIPick { continue }
            case .goodOnly:
                if let q = photo.quality, q.isAnalyzed, q.score < 60 { continue }
            case .issuesOnly:
                if !photo.hasQualityIssues { continue }
            case .bestOfDuplicates:
                if photo.duplicateGroupID != nil && !photo.isBestInGroup { continue }
            case .noDuplicates:
                if photo.duplicateGroupID != nil { continue }
            }
            // Scene tag filter
            if let tag = sceneTag, photo.sceneTag != tag { continue }
            // Face group filter
            if let fg = fgID, photo.faceGroupID != fg { continue }
            // AI category filter
            if let level = aiUsabilityLevel, photo.aiUsability != level { continue }
            if let cat = aiCatValue, photo.aiCategory != cat { continue }
            // Search filter (filename, case-insensitive)
            if !search.isEmpty && !photo.fileName.lowercased().contains(search) { continue }

            files.append(photo)
        }

        // Sort folders and files
        folders.sort { $0.jpgURL.lastPathComponent < $1.jpgURL.lastPathComponent }
        let sortedFiles = sortPhotos(files)
        let final = parentItems + folders + sortedFiles
        _cachedFiltered = final
        _cacheKey = key
        return final
    }

    func invalidateFilterCache() {
        _cachedFiltered = nil
        _cacheKey = ""
        _filteredIndex.removeAll()
        _filteredIndexVersion = ""
    }

    private func sortPhotos(_ list: [PhotoItem]) -> [PhotoItem] {
        switch sortMode {
        case .dateAsc:
            // Always use fileModDate for stable sort (EXIF loads don't change order)
            return list.sorted { $0.fileModDate < $1.fileModDate }
        case .dateDesc:
            return list.sorted { $0.fileModDate > $1.fileModDate }
        case .nameAsc:
            return list.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .nameDesc:
            return list.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedDescending }
        case .ratingDesc:
            return list.sorted { $0.rating > $1.rating }
        case .ratingAsc:
            return list.sorted { $0.rating < $1.rating }
        case .spacePickFirst:
            return list.sorted { ($0.isSpacePicked ? 0 : 1) < ($1.isSpacePicked ? 0 : 1) }
        case .sizeDesc:
            return list.sorted { ($0.jpgFileSize + $0.rawFileSize) > ($1.jpgFileSize + $1.rawFileSize) }
        case .sizeAsc:
            return list.sorted { ($0.jpgFileSize + $0.rawFileSize) < ($1.jpgFileSize + $1.rawFileSize) }
        case .extensionSort:
            return list.sorted { $0.jpgURL.pathExtension.lowercased() < $1.jpgURL.pathExtension.lowercased() }
        case .cameraSort:
            return list.sorted { ($0.exifData?.cameraModel ?? "zzz") < ($1.exifData?.cameraModel ?? "zzz") }
        }
    }

    var selectedPhotos: [PhotoItem] {
        filteredPhotos.filter { $0.rating > 0 }
    }

    func loadFolder(_ url: URL, restoreRatings: Bool = false) {
        AppLogger.log(.folder, "loadFolder: \(url.lastPathComponent) path=\(url.path)")
        let loadStart = CFAbsoluteTimeGetCurrent()

        // Cancel previous thumbnail loading immediately
        ThumbnailLoader.shared.cancelAll()
        thumbsGeneration += 1  // Invalidate stale callbacks from previous folder
        thumbsLoaded = 0
        thumbsTotal = 0

        folderURL = url

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
                // Set photos first (triggers didSet but sort is already done)
                self?.photos = sorted
                if restoreRatings { self?.applySavedRatings() }

                // Select first non-folder photo on NEXT run loop
                // This ensures SwiftUI has processed the photos array update
                // before ExifInfoView tries to load metadata for the selected photo
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
                // Delay thumbnail preload so UI renders first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.preloadAllThumbnails()
                }
            }

            // Phase 2: Read EXIF on-demand only (not upfront)
            // EXIF is loaded per-photo when selected via loadExifOnDemand()
            // This eliminates the heavy batch EXIF read that caused lag on folder switch
            let phase2Elapsed = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            AppLogger.log(.folder, "Folder ready (no Phase 2): \(items.count) items in \(String(format: "%.1f", phase2Elapsed))ms")
        }
    }

    /// EXIF loading is now handled by ExifInfoView directly (self-contained, no photos array mutation)
    func loadExifOnDemand(for photoID: UUID? = nil) {
        // No-op: ExifInfoView loads its own EXIF via @State
    }

    /// Preload all thumbnails in background
    private func preloadAllThumbnails() {
        let urls = photos.map { $0.jpgURL }
        thumbsTotal = urls.count
        thumbsLoaded = 0
        thumbsStartTime = CFAbsoluteTimeGetCurrent()
        let generation = thumbsGeneration

        let totalCount = urls.count
        var completedCount = 0
        let lock = NSLock()
        let startTime = thumbsStartTime

        let rawCount = urls.filter { FileMatchingService.rawExtensions.contains($0.pathExtension.lowercased()) }.count
        let jpgCount = urls.filter { FileMatchingService.jpgExtensions.contains($0.pathExtension.lowercased()) }.count
        print("📊 [THUMB] Start preload: \(totalCount) files (JPG:\(jpgCount) RAW:\(rawCount)), concurrency=\(ThumbnailLoader.shared.queue.maxConcurrentOperationCount)")

        for url in urls {
            ThumbnailLoader.shared.load(url: url) { [weak self] _ in
                // Discard stale callbacks from previous folder
                guard let self = self, self.thumbsGeneration == generation else { return }

                lock.lock()
                completedCount += 1
                let current = completedCount
                lock.unlock()

                // Update UI every 5 items or at completion (smooth progress)
                if current % 5 == 0 || current == totalCount {
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let rate = elapsed > 0 ? Double(current) / elapsed : 0
                    DispatchQueue.main.async { [weak self] in
                        guard self?.thumbsGeneration == generation else { return }
                        self?.thumbsLoaded = current
                    }
                    if current == totalCount {
                        print("📊 [THUMB] DONE: \(totalCount) files in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", rate)) files/s)")
                    } else if current % 50 == 0 {
                        print("📊 [THUMB] Progress: \(current)/\(totalCount) in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", rate)) files/s)")
                    }
                }
            }
        }
    }

    func runQualityAnalysis() {
        guard !photos.isEmpty, !isAnalyzing else { return }
        isAnalyzing = true
        analyzeProgress = 0
        analysisCancel = false

        let photoSnapshots = photos
        let total = photoSnapshots.count
        let options = analysisOptions

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = ImageAnalysisService.analyzeBatch(
                photos: photoSnapshots,
                options: options,
                cancelCheck: {
                    // Cancel if user requested OR system overheating
                    if self?.analysisCancel == true { return true }
                    let thermal = ProcessInfo.processInfo.thermalState
                    if thermal == .critical {
                        DispatchQueue.main.async { self?.analysisCancel = true }
                        return true
                    }
                    return false
                },
                progress: { done in
                    let p = Double(done) / Double(total)
                    DispatchQueue.main.async {
                        self?.analyzeProgress = p
                    }
                }
            )

            DispatchQueue.main.async {
                guard let self = self else { return }
                if !results.isEmpty {
                    let updatedPhotos: [PhotoItem] = self.photos.map { photo in
                        var updated = photo
                        if let quality = results[photo.id] {
                            updated.quality = quality
                        }
                        return updated
                    }
                    let selectedID = self.selectedPhotoID
                    self.photos = updatedPhotos
                    self.selectedPhotoID = selectedID
                }
                self.isAnalyzing = false
                self.analysisCancel = false

                // Run duplicate grouping after analysis
                self.findDuplicates()
            }
        }
    }

    func findDuplicates() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let groups = ImageAnalysisService.findDuplicateGroups(photos: self.photos)
            guard !groups.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                var updated = self.photos
                var dupCount = 0
                for i in 0..<updated.count {
                    if let group = groups[updated[i].id] {
                        updated[i].duplicateGroupID = group.groupID
                        updated[i].isBestInGroup = group.isBest
                        if !group.isBest { dupCount += 1 }
                    }
                }
                let selectedID = self.selectedPhotoID
                self.photos = updated
                self.selectedPhotoID = selectedID
            }
        }
    }

    func stopAnalysis() {
        analysisCancel = true
    }

    func setRating(_ rating: Int, for photoID: UUID) {
        guard let i = idx(photoID) else { return }
        AppLogger.log(.rating, "setRating: \(photos[i].fileName) → \(rating) (was \(photos[i].rating))")
        pushUndo(action: "별점 변경", photoIDs: [photoID])
        photos[i].rating = (photos[i].rating == rating) ? 0 : rating
        saveRatings()
    }

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

    // MARK: - Folder Navigation

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

    private let recentFoldersKey = "recentFolders"
    private let favoriteFoldersKey = "favoriteFolders"

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

    /// Grid panel width, updated by ThumbnailGridView to calculate columns per row
    @Published var gridWidth: CGFloat = 300

    /// Number of columns in the current grid layout
    /// Matches LazyVGrid(.adaptive(minimum: size, maximum: size + 40), spacing: 8)
    /// Actual columns per row - updated from GeometryReader
    @Published var actualColumnsPerRow: Int = 4

    var columnsPerRow: Int {
        if viewMode == .list { return 1 }
        if layoutMode == .filmstrip { return 1 }
        return max(1, actualColumnsPerRow)
    }

    // Cached filtered index for fast lookup
    private var _filteredIndex: [UUID: Int] = [:]

    private var _filteredIndexVersion: String = ""

    private func ensureFilteredIndex() {
        let list = filteredPhotos
        let key = _cacheKey
        if _filteredIndexVersion != key || _filteredIndex.isEmpty {
            _filteredIndex.removeAll(keepingCapacity: true)
            for (i, p) in list.enumerated() {
                _filteredIndex[p.id] = i
            }
            _filteredIndexVersion = key
        }
    }

    /// Anchor for shift-range selection
    private var shiftAnchorIndex: Int?

    private var moveThrottleWorkItem: DispatchWorkItem?
    private var pendingMoveOffset: Int = 0
    private var lastMoveTime: CFAbsoluteTime = 0

    private func moveSelection(by offset: Int, shiftKey: Bool = false, cmdKey: Bool = false) {
        let list = filteredPhotos
        guard !list.isEmpty else { return }

        // Throttle: if keys come faster than 30ms apart, batch them
        let now = CFAbsoluteTimeGetCurrent()
        let interval = now - lastMoveTime
        lastMoveTime = now

        if interval < 0.05 && !shiftKey && !cmdKey {
            // Accumulate offset and debounce
            pendingMoveOffset += offset
            moveThrottleWorkItem?.cancel()
            let totalOffset = pendingMoveOffset
            let work = DispatchWorkItem { [weak self] in
                self?.pendingMoveOffset = 0
                self?.executeMoveSelection(by: totalOffset, shiftKey: false, cmdKey: false)
            }
            moveThrottleWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
            return
        }

        pendingMoveOffset = 0
        executeMoveSelection(by: offset, shiftKey: shiftKey, cmdKey: cmdKey)
    }

    private func executeMoveSelection(by offset: Int, shiftKey: Bool, cmdKey: Bool) {
        let list = filteredPhotos
        guard !list.isEmpty else { return }

        ensureFilteredIndex()

        guard let currentID = selectedPhotoID else { return }
        guard let currentIndex = _filteredIndex[currentID] else {
            let firstID = list[0].id
            selectedPhotoIDs = [firstID]
            selectedPhotoID = firstID
            return
        }

        let newIndex = currentIndex + offset
        guard newIndex >= 0 && newIndex < list.count else { return }

        let newID = list[newIndex].id

        scrollAnchor = offset > 0 ? .bottom : .top

        if shiftKey {
            // Shift: range select from anchor to new position
            if shiftAnchorIndex == nil {
                shiftAnchorIndex = currentIndex
            }
            guard let anchor = shiftAnchorIndex else { return }
            let rangeStart = min(anchor, newIndex)
            let rangeEnd = max(anchor, newIndex)
            var newSelection = Set<UUID>()
            for i in rangeStart...rangeEnd {
                newSelection.insert(list[i].id)
            }
            selectedPhotoIDs = newSelection
        } else if cmdKey {
            // Cmd: toggle individual selection, keep existing
            if selectedPhotoIDs.contains(newID) {
                // Already selected - just move focus
            } else {
                selectedPhotoIDs.insert(newID)
            }
            shiftAnchorIndex = nil
        } else {
            // Normal: single select
            selectedPhotoIDs = [newID]
            shiftAnchorIndex = nil
        }

        selectedPhotoID = newID
        scrollTrigger &+= 1

        // Prefetch nearby
        prefetchNearby(list: list, centerIndex: newIndex, range: 5)
    }

    private func prefetchNearby(list: [PhotoItem], centerIndex: Int, range: Int) {
        var urls: [URL] = []
        let start = max(0, centerIndex - range)
        let end = min(list.count - 1, centerIndex + range)
        guard end >= start else { return }
        for i in start...end {
            if i == centerIndex { continue }
            urls.append(list[i].jpgURL)
        }
        PreviewImageCache.shared.prefetch(urls: urls)
    }

    func selectRight(shift: Bool = false, cmd: Bool = false) { moveSelection(by: 1, shiftKey: shift, cmdKey: cmd) }
    func selectLeft(shift: Bool = false, cmd: Bool = false) { moveSelection(by: -1, shiftKey: shift, cmdKey: cmd) }
    func selectDown(shift: Bool = false, cmd: Bool = false) { moveSelection(by: columnsPerRow, shiftKey: shift, cmdKey: cmd) }
    func selectUp(shift: Bool = false, cmd: Bool = false) { moveSelection(by: -columnsPerRow, shiftKey: shift, cmdKey: cmd) }

    // MARK: - Scene Classification (Vision)

    /// All unique scene tags currently assigned
    var availableSceneTags: [String] {
        let tags = Set(photos.compactMap { $0.sceneTag })
        return tags.sorted()
    }

    /// Vision identifier → Korean tag (exact word boundary matching)
    private static let sceneMapping: [String: String] = [
        // 인물
        "portrait": "인물", "selfie": "인물", "headshot": "인물",
        "person": "인물", "people": "인물", "man": "인물", "woman": "인물",
        "child": "인물", "girl": "인물", "boy": "인물", "baby": "인물",
        // 단체
        "crowd": "단체/군중", "audience": "단체/군중", "group": "단체/군중",
        "team": "단체/군중", "gathering": "단체/군중",
        // 이벤트
        "wedding": "웨딩", "bride": "웨딩", "groom": "웨딩", "ceremony": "웨딩",
        "concert": "공연/콘서트", "stage": "공연/콘서트", "performance": "공연/콘서트",
        "band": "공연/콘서트", "singer": "공연/콘서트", "microphone": "공연/콘서트",
        "party": "파티/축제", "celebration": "파티/축제", "birthday": "파티/축제",
        "festival": "파티/축제", "carnival": "파티/축제",
        "conference": "발표/회의", "presentation": "발표/회의", "meeting": "발표/회의",
        "podium": "발표/회의", "lecture": "발표/회의",
        "exhibition": "전시/팝업", "museum": "전시/팝업", "gallery": "전시/팝업",
        "display": "전시/팝업", "booth": "전시/팝업",
        // 자연/풍경
        "landscape": "풍경", "mountain": "풍경", "valley": "풍경",
        "field": "풍경", "countryside": "풍경", "prairie": "풍경", "hill": "풍경",
        "sunset": "하늘/일몰", "sunrise": "하늘/일몰", "sky": "하늘/일몰",
        "cloud": "하늘/일몰", "dawn": "하늘/일몰", "dusk": "하늘/일몰",
        "ocean": "바다/해변", "sea": "바다/해변", "beach": "바다/해변",
        "coast": "바다/해변", "wave": "바다/해변", "shore": "바다/해변",
        "lake": "바다/해변", "river": "바다/해변", "waterfall": "바다/해변",
        // 도시/건축
        "cityscape": "도시/야경", "urban": "도시/야경", "downtown": "도시/야경",
        "street": "도시/야경", "night": "도시/야경", "neon": "도시/야경",
        "building": "건물/건축", "architecture": "건물/건축", "house": "건물/건축",
        "church": "건물/건축", "tower": "건물/건축", "bridge": "건물/건축",
        "skyscraper": "건물/건축", "temple": "건물/건축", "castle": "건물/건축",
        // 실내
        "indoor": "실내", "room": "실내", "interior": "실내",
        "office": "실내", "studio": "실내", "gym": "실내", "classroom": "실내",
        // 음식/음료 (통합)
        "food": "음식/음료", "meal": "음식/음료", "dish": "음식/음료", "cooking": "음식/음료",
        "kitchen": "음식/음료", "sushi": "음식/음료", "pizza": "음식/음료", "cake": "음식/음료",
        "dessert": "음식/음료", "restaurant": "음식/음료", "bakery": "음식/음료",
        "drink": "음식/음료", "coffee": "음식/음료", "wine": "음식/음료", "beer": "음식/음료",
        "cocktail": "음식/음료", "beverage": "음식/음료", "cup": "음식/음료", "tea": "음식/음료",
        // 동물/식물 (통합)
        "animal": "동물/식물", "dog": "동물/식물", "cat": "동물/식물", "bird": "동물/식물",
        "pet": "동물/식물", "wildlife": "동물/식물", "horse": "동물/식물", "fish": "동물/식물",
        "insect": "동물/식물", "butterfly": "동물/식물",
        "flower": "동물/식물", "plant": "동물/식물", "garden": "동물/식물",
        "tree": "동물/식물", "forest": "동물/식물", "leaf": "동물/식물", "botanical": "동물/식물",
        // 사물
        "car": "차량/교통", "vehicle": "차량/교통", "motorcycle": "차량/교통",
        "bicycle": "차량/교통", "airplane": "차량/교통", "train": "차량/교통", "boat": "차량/교통",
        "product": "제품/상품", "merchandise": "제품/상품", "package": "제품/상품",
        "commercial": "제품/상품",
        "texture": "디테일/클로즈업", "pattern": "디테일/클로즈업",
        "abstract": "디테일/클로즈업", "macro": "디테일/클로즈업",
        "document": "문서/텍스트", "text": "문서/텍스트", "sign": "문서/텍스트",
        "book": "문서/텍스트", "newspaper": "문서/텍스트", "screen": "문서/텍스트",
        // 스포츠
        "sport": "스포츠", "soccer": "스포츠", "basketball": "스포츠",
        "tennis": "스포츠", "swimming": "스포츠", "running": "스포츠",
        "baseball": "스포츠", "golf": "스포츠", "skiing": "스포츠",
    ]

    /// Map a Vision classification identifier to a Korean scene tag
    /// Uses word-boundary splitting for accurate matching (no partial matches)
    private static func mapToSceneTag(identifier: String) -> String? {
        // Split identifier into words: "lakeside_sunset" → ["lakeside", "sunset"]
        let words = identifier.lowercased()
            .split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" })
            .map(String.init)
        // Check each word against the dictionary (O(1) lookup)
        for word in words {
            if let tag = sceneMapping[word] { return tag }
        }
        // Also check the full identifier
        if let tag = sceneMapping[identifier.lowercased()] { return tag }
        return nil
    }

    /// Fast local scene classification: runs VNClassifyImageRequest + VNDetectFaceRectanglesRequest
    /// in a single handler.perform() call for maximum ANE throughput.
    /// Returns a Korean scene tag matching PickShot's tag vocabulary.
    private static func classifySceneTag(cgImage: CGImage) -> String? {
        let sceneReq = VNClassifyImageRequest()
        sceneReq.usesCPUOnly = false  // enable ANE

        let faceReq = VNDetectFaceRectanglesRequest()
        if #available(macOS 13.0, *) {
            faceReq.revision = VNDetectFaceRectanglesRequestRevision3
        }
        faceReq.usesCPUOnly = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            // Single perform() batches both requests — faster than two separate calls
            try handler.perform([sceneReq, faceReq])
        } catch {
            return nil
        }

        // --- Scene labels (top 3 for multi-signal) ---
        let sorted = (sceneReq.results ?? [])
            .filter { $0.confidence > 0.3 }
            .sorted { $0.confidence > $1.confidence }

        // Collect mapped tags with confidence
        var tagScores: [(tag: String, confidence: Float)] = []
        for obs in sorted.prefix(5) {
            if let tag = mapToSceneTag(identifier: obs.identifier) {
                tagScores.append((tag, obs.confidence))
            }
        }

        // --- Face count (confidence > 0.5 only) ---
        let faceCount = (faceReq.results ?? []).filter { $0.confidence > 0.5 }.count

        // --- Face size analysis ---
        let faces = (faceReq.results ?? []).filter { $0.confidence > 0.5 }
        let maxFaceSize = faces.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0

        // --- Combine scene + face heuristics ---
        let bestTag = tagScores.first?.tag

        // Face-based overrides
        if faceCount >= 5 { return "단체/군중" }
        if faceCount >= 3 && bestTag != "공연/콘서트" { return "단체/군중" }

        // Large face (>8% of image) + 1-2 faces = portrait
        if faceCount >= 1 && faceCount <= 2 && maxFaceSize > 0.08 {
            if bestTag == nil || bestTag == "실내" || bestTag == "풍경" ||
               bestTag == "건물/건축" || bestTag == "도시/야경" {
                return maxFaceSize > 0.15 ? "인물 (클로즈업)" : "인물"
            }
        }

        // Vision tag available
        if let tag = bestTag { return tag }

        // Fallback by face
        if faceCount >= 1 { return "인물" }
        return nil
    }

    /// Classify scenes for all photos using local Vision framework (VNClassifyImageRequest).
    /// Batches scene + face detection in one perform() call per photo.
    /// Uses concurrentPerform for maximum CPU/ANE utilization.
    func classifyScenes() {
        guard !photos.isEmpty, !isClassifyingScenes else { return }
        isClassifyingScenes = true
        classifyProgress = 0

        let photoSnapshots = photos.filter { !$0.isFolder && !$0.isParentFolder }
        let total = photoSnapshots.count
        let startTime = CFAbsoluteTimeGetCurrent()
        print("🏷 [SCENE] Start: \(total) photos")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [UUID: String] = [:]
            let resultsLock = NSLock()
            var completed = 0

            DispatchQueue.concurrentPerform(iterations: total) { idx in
                autoreleasepool {
                let photo = photoSnapshots[idx]

                // Use 480px — sufficient for Vision classification, much faster than 800px
                let sourceOptions: [NSString: Any] = [kCGImageSourceShouldCache: false]
                guard let source = CGImageSourceCreateWithURL(photo.jpgURL as CFURL, sourceOptions as CFDictionary) else {
                    resultsLock.lock()
                    completed += 1
                    resultsLock.unlock()
                    return
                }
                let thumbOptions: [NSString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceShouldCache: false
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                    resultsLock.lock()
                    completed += 1
                    resultsLock.unlock()
                    return
                }

                // Single-pass scene + face classification
                if let tag = Self.classifySceneTag(cgImage: cgImage) {
                    resultsLock.lock()
                    results[photo.id] = tag
                    resultsLock.unlock()
                }

                var shouldReport = false
                var c = 0
                resultsLock.lock()
                completed += 1
                c = completed
                shouldReport = (c % 50 == 0 || c == total)
                resultsLock.unlock()

                if shouldReport {
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let rate = elapsed > 0 ? Double(c) / elapsed : 0
                    if c == total {
                        print("🏷 [SCENE] DONE: \(total) photos in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", rate)) photos/s)")
                    } else {
                        print("🏷 [SCENE] Progress: \(c)/\(total) in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", rate)) photos/s)")
                    }
                    DispatchQueue.main.async { [weak self] in self?.classifyProgress = Double(c) / Double(total) }
                }
                } // autoreleasepool
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                if !results.isEmpty {
                    let selectedID = self.selectedPhotoID
                    var updated = self.photos
                    for i in 0..<updated.count {
                        if let tag = results[updated[i].id] {
                            updated[i].sceneTag = tag
                        }
                    }
                    self.photos = updated
                    self.selectedPhotoID = selectedID
                }
                self.isClassifyingScenes = false
                self.classifyProgress = 1.0
            }
        }
    }

    // MARK: - Face Grouping

    /// Available face group IDs
    var availableFaceGroups: [Int] {
        Array(faceGroups.keys).sorted()
    }

    func groupByFaces() {
        guard !photos.isEmpty, !isGroupingFaces else { return }
        isGroupingFaces = true
        faceGroupProgress = 0

        let photoSnapshots = photos
        let total = photoSnapshots.count

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = FaceGroupingService.groupFaces(
                photos: photoSnapshots,
                progress: { [weak self] done in
                    let p = Double(done) / Double(total)
                    DispatchQueue.main.async { [weak self] in self?.faceGroupProgress = p }
                }
            )

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !results.assignments.isEmpty {
                    let selectedID = self.selectedPhotoID
                    var updated = self.photos
                    for i in 0..<updated.count {
                        if let groupID = results.assignments[updated[i].id] {
                            updated[i].faceGroupID = groupID
                        }
                    }
                    self.photos = updated
                    self.selectedPhotoID = selectedID
                    self.faceGroups = results.groups
                    self.faceThumbnails = results.faceThumbnails

                    // Extract face thumbnails for groups that don't have one
                    for (groupID, photoIDs) in results.groups {
                        if self.faceThumbnails[groupID] == nil, let firstID = photoIDs.first,
                           let photo = self.photos.first(where: { $0.id == firstID }) {
                            if let thumb = extractFaceThumbnail(url: photo.jpgURL) {
                                self.faceThumbnails[groupID] = thumb
                            }
                        }
                    }
                }
                self.isGroupingFaces = false
                self.faceGroupProgress = 1.0
            }
        }
    }

    // MARK: - AI Smart Classification

    func runAIClassification() {
        guard !photos.isEmpty, !isAIClassifying, ClaudeVisionService.hasAPIKey else { return }
        isAIClassifying = true
        aiClassifyProgress = (0, photos.count)

        let photoSnapshots = filteredPhotos

        Task { @MainActor in
            do {
                let results = try await ClaudeVisionService.batchClassify(
                    photos: photoSnapshots,
                    progress: { [weak self] done, total in
                        self?.aiClassifyProgress = (done, total)
                    }
                )

                let selectedID = self.selectedPhotoID
                var updated = self.photos
                for i in 0..<updated.count {
                    if let classification = results[updated[i].id] {
                        updated[i].aiCategory = classification.category
                        updated[i].aiSubcategory = classification.subcategory
                        updated[i].aiMood = classification.mood
                        updated[i].aiUsability = classification.usability
                        updated[i].aiBestFor = classification.bestFor
                        updated[i].aiDescription = classification.description
                        updated[i].aiScore = classification.score
                    }
                }
                self.photos = updated
                self.selectedPhotoID = selectedID
            } catch {
                print("AI Classification failed: \(error)")
            }
            self.isAIClassifying = false
        }
    }

    /// Available AI categories
    var availableAICategories: [String] {
        let categories = Set(photos.compactMap { $0.aiCategory })
        return Array(categories).sorted()
    }

    /// AI usability statistics
    var aiUsabilityStats: [String: Int] {
        var stats: [String: Int] = [:]
        for photo in photos {
            if let usability = photo.aiUsability {
                stats[usability, default: 0] += 1
            }
        }
        return stats
    }

    func toggleMetadataOverlay() {
        showMetadataOverlay.toggle()
    }

    // MARK: - Batch Rename

    /// Preview rename result for a single photo
    static func previewRename(photo: PhotoItem, pattern: String, index: Int) -> String {
        return previewRename(photo: photo, pattern: pattern, index: index, dateFormat: "yyyyMMdd", seqDigits: 3, seqStart: 1)
    }

    static func previewRename(photo: PhotoItem, pattern: String, index: Int, dateFormat: String, seqDigits: Int, seqStart: Int) -> String {
        var result = pattern

        // {date}
        if let date = photo.exifData?.dateTaken {
            let df = DateFormatter()
            df.dateFormat = dateFormat
            result = result.replacingOccurrences(of: "{date}", with: df.string(from: date))
        } else {
            result = result.replacingOccurrences(of: "{date}", with: "nodate")
        }

        // {time} → HHmmss
        if let date = photo.exifData?.dateTaken {
            let df = DateFormatter()
            df.dateFormat = "HHmmss"
            result = result.replacingOccurrences(of: "{time}", with: df.string(from: date))
        } else {
            result = result.replacingOccurrences(of: "{time}", with: "notime")
        }

        // {camera} → camera model
        if let model = photo.exifData?.cameraModel {
            let cleaned = model.replacingOccurrences(of: " ", with: "_")
            result = result.replacingOccurrences(of: "{camera}", with: cleaned)
        } else {
            result = result.replacingOccurrences(of: "{camera}", with: "unknown")
        }

        // {seq} → sequence number
        let seqNum = seqStart + index
        let seq = String(format: "%0\(seqDigits)d", seqNum)
        result = result.replacingOccurrences(of: "{seq}", with: seq)

        // {original} → original file name (without extension)
        result = result.replacingOccurrences(of: "{original}", with: photo.fileName)

        return result
    }

    /// Perform batch rename on selected photos
    func batchRename(pattern: String) -> (success: Int, errors: [String]) {
        return batchRename(pattern: pattern, dateFormat: "yyyyMMdd", seqDigits: 3, seqStart: 1)
    }

    func batchRename(pattern: String, dateFormat: String, seqDigits: Int, seqStart: Int) -> (success: Int, errors: [String]) {
        let targets: [PhotoItem]
        if selectedPhotoIDs.count > 1 {
            targets = filteredPhotos.filter { selectedPhotoIDs.contains($0.id) }
        } else {
            targets = filteredPhotos
        }

        var successCount = 0
        var errors: [String] = []
        let fm = FileManager.default

        for (index, photo) in targets.enumerated() {
            let newBaseName = Self.previewRename(photo: photo, pattern: pattern, index: index, dateFormat: dateFormat, seqDigits: seqDigits, seqStart: seqStart)
            let jpgExt = photo.jpgURL.pathExtension
            let parentDir = photo.jpgURL.deletingLastPathComponent()
            let newJPGURL = parentDir.appendingPathComponent("\(newBaseName).\(jpgExt)")

            // Skip if same name
            if newJPGURL == photo.jpgURL { continue }

            // Check for conflicts
            if fm.fileExists(atPath: newJPGURL.path) && newJPGURL != photo.jpgURL {
                errors.append("\(photo.fileName): 이름 충돌 - \(newBaseName).\(jpgExt)")
                continue
            }

            do {
                // Rename JPG
                try fm.moveItem(at: photo.jpgURL, to: newJPGURL)

                // Rename matching RAW if exists
                if let rawURL = photo.rawURL {
                    let rawExt = rawURL.pathExtension
                    let rawParent = rawURL.deletingLastPathComponent()
                    let newRAWURL = rawParent.appendingPathComponent("\(newBaseName).\(rawExt)")
                    if !fm.fileExists(atPath: newRAWURL.path) {
                        try fm.moveItem(at: rawURL, to: newRAWURL)
                    }
                }

                successCount += 1
            } catch {
                errors.append("\(photo.fileName): \(error.localizedDescription)")
            }
        }

        // Reload folder to reflect changes
        if successCount > 0, let url = folderURL {
            loadFolder(url)
        }

        return (successCount, errors)
    }
}
