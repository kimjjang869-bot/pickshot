import Foundation
import SwiftUI
import ImageIO
import Vision
import CoreLocation


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
    case customOrder = "사용자 정렬"

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
        case .customOrder: return "hand.draw"
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
            photosVersion += 1; invalidateFilterCache(); rebuildIndex()
            updateFolderSizeCache()
        }
    }

    /// 폴더 사이즈 캐시 (photos 변경 시 1회만 계산)
    @Published private(set) var cachedFolderSizeText: String = ""
    private func updateFolderSizeCache() {
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
    @Published var selectedPhotoID: UUID? {
        didSet {
            if !isKeyRepeat {
                prefetchNearbyThumbnails()
                if let id = selectedPhotoID { reverseGeocodeIfNeeded(for: id) }
            }
        }
    }
    @Published var selectedPhotoIDs: Set<UUID> = []
    /// Incremented when keyboard navigation happens, triggers scroll
    @Published var scrollTrigger: Int = 0
    var scrollAnchor: UnitPoint = .bottom
    /// true when key is held down (OS key repeat), false for actual press
    var isKeyRepeat: Bool = false
    /// 빠른 탐색 시 썸네일 즉시 표시용 콜백 (디스크 I/O 없음)
    var onQuickPreview: ((URL) -> Void)?
    @Published var minimumRatingFilter: Int = 0 { didSet { invalidateFilterCache() } }
    @Published var sortMode: SortMode = .dateDesc {
        didSet {
            filterLock.lock(); _cachedFiltered = nil; _cacheKey = ""
            _filteredIndex.removeAll(); _filteredIndexVersion = ""; filterLock.unlock()
            UserDefaults.standard.set(sortMode.rawValue, forKey: "savedSortMode")
            scrollTrigger += 1
        }
    }
    @Published var viewMode: ViewMode = .grid
    @Published var useAppKitGrid: Bool = UserDefaults.standard.object(forKey: "useAppKitGrid") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useAppKitGrid, forKey: "useAppKitGrid") }
    }
    @Published var thumbnailSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "savedThumbnailSize")
        return saved > 0 ? CGFloat(saved) : 100
    }() {
        didSet { UserDefaults.standard.set(Double(thumbnailSize), forKey: "savedThumbnailSize") }
    }
    @Published var previewResolution: Int = 0  // 0 = 원본, 1000/2000/3000/4000
    @Published var qualityFilter: QualityFilter = .all { didSet { invalidateFilterCache() } }
    @Published var isAnalyzing = false
    @Published var analyzeProgress: Double = 0
    @Published var showAnalysisOptions = false
    @Published var analysisOptions = AnalysisOptions()
    // analysisCancel: 백그라운드 스레드에서 읽고 메인 스레드에서 쓰므로 lock 보호
    private var _analysisCancel = false
    private let analysisCancelLock = NSLock()
    private var analysisCancel: Bool {
        get { analysisCancelLock.lock(); defer { analysisCancelLock.unlock() }; return _analysisCancel }
        set { analysisCancelLock.lock(); _analysisCancel = newValue; analysisCancelLock.unlock() }
    }
    @Published var folderURL: URL?
    // 비율 기반 분할 (0.0~1.0) — 창 크기 변해도 비율 유지
    @Published var hSplitRatio: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "savedHSplitRatio")
        if saved > 0.05 && saved < 0.95 { return CGFloat(saved) }
        // 기존 절대값 마이그레이션
        let oldPx = UserDefaults.standard.double(forKey: "savedHSplitPosition")
        if oldPx > 0 {
            let screenW = NSScreen.main?.frame.width ?? 1440
            let ratio = oldPx / (screenW * 0.95)   // 윈도우는 화면의 95%
            return max(0.15, min(0.50, ratio))
        }
        return 0.35
    }() {
        didSet { UserDefaults.standard.set(Double(hSplitRatio), forKey: "savedHSplitRatio") }
    }
    @Published var vSplitRatio: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "savedVSplitRatio")
        if saved > 0.05 && saved < 0.95 { return CGFloat(saved) }
        // 기존 절대값 마이그레이션
        let oldPx = UserDefaults.standard.double(forKey: "savedVSplitPosition")
        if oldPx > 0 {
            let screenH = NSScreen.main?.frame.height ?? 900
            let ratio = oldPx / (screenH * 0.95)
            return max(0.20, min(0.90, ratio))
        }
        return 0.70
    }() {
        didSet { UserDefaults.standard.set(Double(vSplitRatio), forKey: "savedVSplitRatio") }
    }
    // 하위 호환용 computed property (기존 코드에서 쓰는 곳 대비)
    var hSplitPosition: CGFloat {
        get {
            let screenW = NSScreen.main?.frame.width ?? 1440
            return hSplitRatio * (screenW * 0.95)
        }
        set {
            let screenW = NSScreen.main?.frame.width ?? 1440
            hSplitRatio = max(0.10, min(0.55, newValue / (screenW * 0.95)))
        }
    }
    var vSplitPosition: CGFloat {
        get {
            let screenH = NSScreen.main?.frame.height ?? 900
            return vSplitRatio * (screenH * 0.95)
        }
        set {
            let screenH = NSScreen.main?.frame.height ?? 900
            vSplitRatio = max(0.20, min(0.90, newValue / (screenH * 0.95)))
        }
    }
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
        guard elapsed > 1.0 else { return "" }
        let rate = Double(thumbsLoaded) / elapsed
        guard rate > 0.1 else { return "" }  // rate 너무 낮으면 ETA 숨김
        let remaining = Double(thumbsTotal - thumbsLoaded) / rate
        guard remaining < 36000 else { return "" }  // 10시간 이상이면 비정상
        if remaining < 60 { return "\(Int(remaining))초" }
        return "\(Int(remaining / 60))분 \(Int(remaining.truncatingRemainder(dividingBy: 60)))초"
    }
    @Published var exportProgress: Double = 0
    @Published var isExporting = false
    // 백그라운드 내보내기 상태
    @Published var bgExportActive = false
    @Published var bgExportProgress: Double = 0
    @Published var bgExportDone: Int = 0
    @Published var bgExportTotal: Int = 0
    @Published var bgExportCancelled = false
    @Published var bgExportLabel: String = ""  // "폴더 내보내기" / "Lightroom 내보내기" / "RAW → JPG 변환"
    var bgExportDestination: URL?
    @Published var conversionProgress: Double = 0
    @Published var conversionTotal: Int = 0
    @Published var conversionDone: Int = 0

    // 파일 이동/복사 진행률
    @Published var fileMoveActive = false
    @Published var fileMoveDone: Int = 0
    @Published var fileMoveTotal: Int = 0
    @Published var fileMoveLabel: String = ""  // "파일 이동" / "파일 복사"
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
    @Published var showDualViewer = false
    @Published var showSlideshow = false
    @Published var colorLabelFilter: ColorLabel = .none { didSet { invalidateFilterCache() } }
    @Published var slideshowInterval: Double = 3.0
    @Published var isFolderWatchingEnabled: Bool = true
    @Published var showMetadataOverlay: Bool = false
    @Published var sceneTagFilter: String? = nil { didSet { invalidateFilterCache() } }
    @Published var keywordFilter: String? = nil { didSet { invalidateFilterCache() } }
    @Published var isClassifyingScenes: Bool = false
    @Published var classifyProgress: Double = 0
    @Published var layoutMode: LayoutMode = .gridPreview
    var shouldOpenFolderBrowser: Bool = false
    @Published var showBatchRename: Bool = false
    @Published var showImportResult: Bool = false
    var lastImportResult: PickshotImportResult?
    @Published var showPickshotImportSheet: Bool = false
    @Published var clientComments: [UUID: String] = [:]  // photoID -> 클라이언트 코멘트 (첫 번째)
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
    @Published var faceGroups: [Int: [UUID]] = [:]
    @Published var faceGroupNames: [Int: String] = [:]  // 그룹ID → 인물 이름
    @Published var faceThumbnails: [Int: NSImage] = [:]
    @Published var faceGroupFilter: Int? = nil { didSet { invalidateFilterCache() } }
    @Published var isGroupingFaces: Bool = false
    @Published var faceGroupProgress: Double = 0
    @Published var showAbout: Bool = false
    @Published var showDeleteConfirm: Bool = false
    @Published var showSmartSelect: Bool = false
    @Published var showSmartCull: Bool = false
    // 드래그 드롭 상태 (DragDropState로 분리 — PhotoStore 리드로우 방지)
    // dropTargetID/dropLeading 삭제 → DragDropState 사용
    var lastRenameMap: [(oldURL: URL, newURL: URL)] = []  // Undo용 이름 변경 기록
    @Published var showCustomPrompt: Bool = false
    @Published var showBatchProcess: Bool = false
    @Published var showFaceCompare: Bool = false
    @Published var smartSelectResult: SmartSelectService.Result?
    @Published var smartSelectConfig: SmartSelectService.Config = SmartSelectService.Config()
    // Memory Card Backup
    let backupService = MemoryCardBackupService.shared

    @Published var showFolderBrowser: Bool = true
    /// 하위 폴더 포함 모드 활성화 여부
    @Published var isRecursiveMode: Bool = false
    @Published var showFileTypeBadge: Bool = UserDefaults.standard.object(forKey: "showFileTypeBadge") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFileTypeBadge, forKey: "showFileTypeBadge") }
    }
    @Published var showFolderPreview: Bool = UserDefaults.standard.object(forKey: "showFolderPreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFolderPreview, forKey: "showFolderPreview") }
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

    /// 미리보기 배경색 (디폴트/검정/흰색/다크그레이/미디엄그레이/라이트그레이/커스텀)
    @Published var previewBgMode: String = UserDefaults.standard.string(forKey: "previewBgMode") ?? "default" {
        didSet { UserDefaults.standard.set(previewBgMode, forKey: "previewBgMode") }
    }
    @Published var previewBgCustomHex: String = UserDefaults.standard.string(forKey: "previewBgCustomHex") ?? "#333333" {
        didSet { UserDefaults.standard.set(previewBgCustomHex, forKey: "previewBgCustomHex") }
    }

    var previewBackgroundColor: Color {
        switch previewBgMode {
        case "black": return .black
        case "white": return .white
        case "darkGray": return Color(nsColor: NSColor(white: 0.2, alpha: 1))
        case "mediumGray": return Color(nsColor: NSColor(white: 0.4, alpha: 1))
        case "lightGray": return Color(nsColor: NSColor(white: 0.7, alpha: 1))
        case "custom":
            if let color = NSColor.fromHex(previewBgCustomHex) {
                return Color(nsColor: color)
            }
            return Color(nsColor: .controlBackgroundColor)
        default: return Color(nsColor: .controlBackgroundColor)
        }
    }

    // AI Smart Classification
    @Published var isAIClassifying: Bool = false
    @Published var aiClassifyProgress: (Int, Int) = (0, 0)
    @Published var aiClassifyErrors: [(String, String)] = []  // (파일명, 에러 메시지)
    @Published var showAIClassifyError = false
    @Published var aiClassifyErrorMessage = ""
    @Published var aiCategoryFilter: String? = nil { didSet { invalidateFilterCache() } }   // 카테고리별 필터

    // MARK: - 스마트 컬렉션 (저장된 필터 조합)
    struct SmartCollection: Codable, Identifiable {
        var id = UUID()
        var name: String
        var minRating: Int = 0
        var colorLabel: String = "none"
        var qualityFilter: String = "all"
        var sceneTag: String?
        var keyword: String?
        var searchText: String = ""
    }

    @Published var savedCollections: [SmartCollection] = [] {
        didSet { saveCollections() }
    }

    func saveCurrentFilter(name: String) {
        let col = SmartCollection(
            name: name,
            minRating: minimumRatingFilter,
            colorLabel: colorLabelFilter.rawValue,
            qualityFilter: qualityFilter.rawValue,
            sceneTag: sceneTagFilter,
            keyword: keywordFilter,
            searchText: searchText
        )
        savedCollections.append(col)
    }

    func applyCollection(_ col: SmartCollection) {
        minimumRatingFilter = col.minRating
        colorLabelFilter = ColorLabel(rawValue: col.colorLabel) ?? .none
        qualityFilter = QualityFilter(rawValue: col.qualityFilter) ?? .all
        sceneTagFilter = col.sceneTag
        keywordFilter = col.keyword
        searchText = col.searchText
    }

    func deleteCollection(_ id: UUID) {
        savedCollections.removeAll { $0.id == id }
    }

    private func saveCollections() {
        if let data = try? JSONEncoder().encode(savedCollections) {
            UserDefaults.standard.set(data, forKey: "smartCollections")
        }
    }

    func loadCollections() {
        guard let data = UserDefaults.standard.data(forKey: "smartCollections"),
              let cols = try? JSONDecoder().decode([SmartCollection].self, from: data) else { return }
        savedCollections = cols
    }

    // Search
    @Published var searchText: String = "" { didSet { invalidateFilterCache() } }

    // MARK: - Undo Stack
    struct FileMove { let sourceURL: URL; let destURL: URL }
    private var undoStack: [(action: String, photoIDs: Set<UUID>, oldRatings: [UUID: Int], oldSP: [UUID: Bool], oldGSelect: [UUID: Bool], fileMoves: [FileMove])] = []
    private let maxUndoSteps = 20

    private let defaults = UserDefaults.standard
    private let layoutModeKey = "layoutMode"
    private let lastFolderKey = "lastFolderPath"
    private let ratingsKey = "photoRatings"
    private let folderWatcher = FolderWatcherService()
    private var folderReloadWork: DispatchWorkItem?

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
        undoStack.append((action: action, photoIDs: photoIDs, oldRatings: oldRatings, oldSP: oldSP, oldGSelect: oldGSelect, fileMoves: []))
        if undoStack.count > maxUndoSteps {
            undoStack.removeFirst(undoStack.count - maxUndoSteps)
        }
    }

    func undo() {
        guard let last = undoStack.popLast() else {
            showToastMessage("되돌릴 항목이 없습니다")
            return
        }

        // 파일 이동 되돌리기
        if !last.fileMoves.isEmpty {
            var undone = 0
            for move in last.fileMoves.reversed() {
                do {
                    try FileManager.default.moveItem(at: move.destURL, to: move.sourceURL)
                    undone += 1
                } catch {
                    AppLogger.log(.general, "Undo move failed: \(move.destURL.lastPathComponent) → \(error)")
                }
            }
            // 폴더 다시 로딩
            if let folderURL = folderURL {
                loadFolder(folderURL, restoreRatings: true)
            }
            NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
            showToastMessage("\(undone)장 이동 되돌리기 완료")
            return
        }

        // 별점/SP/GSelect 되돌리기
        var copy = photos
        for id in last.photoIDs {
            guard let i = _photoIndex[id], i < copy.count else { continue }
            if let oldRating = last.oldRatings[id] { copy[i].rating = oldRating }
            if let oldSP = last.oldSP[id] { copy[i].isSpacePicked = oldSP }
            if let oldG = last.oldGSelect[id] { copy[i].isGSelected = oldG }
        }
        applyPhotosUpdate(copy)
        saveRatings()
        showToastMessage("\(last.action) 되돌리기 완료")
    }

    // MARK: - System Auto-Optimization on First Launch

    private func autoOptimizeOnFirstLaunch() {
        let key = "hasOptimized_v6"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        let isAppleSilicon = ProcessInfo.processInfo.processorCount >= 8

        // 썸네일 표시 크기는 100px 고정 (생성 픽셀 200px이면 Retina 충분)
        UserDefaults.standard.set(Double(100), forKey: "savedThumbnailSize")
        UserDefaults.standard.set(100.0, forKey: "defaultThumbnailSize")
        thumbnailSize = 100

        if ramGB >= 64 && isAppleSilicon {
            UserDefaults.standard.set("original", forKey: "previewMaxResolution")
            UserDefaults.standard.set(30.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(4.0, forKey: "thumbnailCacheMaxGB")
            previewResolution = 0
        } else if ramGB >= 32 {
            UserDefaults.standard.set("original", forKey: "previewMaxResolution")
            UserDefaults.standard.set(25.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(3.0, forKey: "thumbnailCacheMaxGB")
            previewResolution = 0
        } else if ramGB >= 16 {
            UserDefaults.standard.set("original", forKey: "previewMaxResolution")
            UserDefaults.standard.set(15.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(1.5, forKey: "thumbnailCacheMaxGB")
            previewResolution = 0
        } else {
            UserDefaults.standard.set("3000", forKey: "previewMaxResolution")
            UserDefaults.standard.set(10.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(0.5, forKey: "thumbnailCacheMaxGB")
            previewResolution = 3000
        }

        UserDefaults.standard.set(true, forKey: key)
        fputs("[OPT] 첫 실행 자동 최적화 완료 — RAM: \(ramGB)GB, AppleSilicon: \(isAppleSilicon)\n", stderr)
    }

    init() {
        // 첫 실행 시 시스템 사양 기반 자동 최적화
        autoOptimizeOnFirstLaunch()

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

        // 메모리카드 자동 백업 모니터링
        if UserDefaults.standard.bool(forKey: "autoBackupEnabled") {
            backupService.startMonitoring()
        }

        // 설정 변경 알림 → 라이브 프로퍼티에 반영
        NotificationCenter.default.addObserver(forName: .init("SettingsChanged"), object: nil, queue: .main) { [weak self] _ in
            self?.applySettingsFromDefaults()
        }

        // 마지막 폴더 자동 복원 (뷰어 모드 즉시 진입)
        if let lastPath = defaults.string(forKey: lastFolderKey),
           !lastPath.isEmpty,
           FileManager.default.fileExists(atPath: lastPath) {
            startupMode = .viewer
            shouldOpenFolderBrowser = true
            DispatchQueue.main.async {
                self.restoreLastSession()
            }
        }
        loadCollections()
        loadFaceGroupNames()
    }

    /// Settings 창에서 변경된 값을 라이브 프로퍼티에 동기화
    func applySettingsFromDefaults() {
        // 썸네일 크기: defaultThumbnailSize → savedThumbnailSize + thumbnailSize
        let newThumbSize = UserDefaults.standard.double(forKey: "defaultThumbnailSize")
        if newThumbSize > 0 {
            thumbnailSize = CGFloat(newThumbSize)
        }
        // 미리보기 해상도: previewMaxResolution → previewResolution
        let resStr = UserDefaults.standard.string(forKey: "previewMaxResolution") ?? "original"
        previewResolution = (resStr == "original") ? 0 : (Int(resStr) ?? 0)
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

    // MARK: - 주변 썸네일 프리로딩 (키보드 이동 시 빈 썸네일 방지)

    private var prefetchWorkItem: DispatchWorkItem?

    private func prefetchNearbyThumbnails() {
        // 디바운스: 빠른 키 연타 시 마지막 한 번만 실행
        prefetchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let id = self.selectedPhotoID else { return }
            let list = self.filteredPhotos
            self.ensureFilteredIndex()
            guard let idx = self._filteredIndex[id] else { return }

            // 앞뒤 20장 중 메모리 캐시 미스만 로딩
            let start = max(0, idx - 20)
            let end = min(list.count - 1, idx + 20)
            guard start <= end else { return }

            var toLoad: [URL] = []
            for i in start...end {
                let photo = list[i]
                guard !photo.isFolder && !photo.isParentFolder else { continue }
                if ThumbnailCache.shared.get(photo.jpgURL) == nil {
                    toLoad.append(photo.jpgURL)
                }
            }

            // 최대 10장만 큐에 추가 (과도한 큐 적재 방지)
            for url in toLoad.prefix(10) {
                ThumbnailLoader.shared.load(url: url) { _ in }
            }
        }
        prefetchWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05, execute: work)
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
        // 폴더별 저장 (경로 해시 키)
        guard let folderPath = folderURL?.path else { return }

        var ratings: [String: Int] = [:]
        var spPicks: [String: Bool] = [:]
        var colorLabels: [String: String] = [:]
        for photo in photos {
            if photo.rating > 0 { ratings[photo.fileName] = photo.rating }
            if photo.isSpacePicked { spPicks[photo.fileName] = true }
            if photo.colorLabel != .none { colorLabels[photo.fileName] = photo.colorLabel.rawValue }
        }

        // 전역 (하위 호환)
        defaults.set(ratings, forKey: ratingsKey)

        // 폴더별 SP + 컬러라벨
        var allSP = defaults.dictionary(forKey: "folderSpacePicks") as? [String: [String: Bool]] ?? [:]
        var allColors = defaults.dictionary(forKey: "folderColorLabels") as? [String: [String: String]] ?? [:]
        allSP[folderPath] = spPicks
        allColors[folderPath] = colorLabels
        defaults.set(allSP, forKey: "folderSpacePicks")
        defaults.set(allColors, forKey: "folderColorLabels")

        // Write XMP sidecar files in background
        let snapshot = photos.map { (url: $0.jpgURL, rating: $0.rating, label: $0.colorLabel, spacePicked: $0.isSpacePicked) }
        DispatchQueue.global(qos: .utility).async {
            for item in snapshot where item.rating > 0 {
                let xmpLabel = XMPService.xmpLabel(from: item.label.rawValue)
                XMPService.writeRating(for: item.url, rating: item.rating, label: xmpLabel, spacePicked: item.spacePicked)
            }
        }
    }

    private func applySavedRatings() {
        let savedRatings = defaults.dictionary(forKey: ratingsKey) as? [String: Int]
        let folderPath = folderURL?.path ?? ""
        let allSP = defaults.dictionary(forKey: "folderSpacePicks") as? [String: [String: Bool]]
        let allColors = defaults.dictionary(forKey: "folderColorLabels") as? [String: [String: String]]
        let savedSP = allSP?[folderPath]
        let savedColors = allColors?[folderPath]

        fputs("[RESTORE] folder=\(folderURL?.lastPathComponent ?? "nil"), ratings=\(savedRatings?.count ?? 0), SP=\(savedSP?.count ?? 0), colors=\(savedColors?.count ?? 0)\n", stderr)

        var restoredSP = 0
        var restoredRating = 0
        for i in 0..<photos.count {
            let fileName = photos[i].fileName

            // 저장된 별점
            if let saved = savedRatings?[fileName] {
                photos[i].rating = saved
                restoredRating += 1
            }
            // 저장된 SP 셀렉
            if savedSP?[fileName] == true {
                photos[i].isSpacePicked = true
                restoredSP += 1
            }
            // 저장된 컬러라벨
            if let colorStr = savedColors?[fileName],
               let color = ColorLabel(rawValue: colorStr) {
                photos[i].colorLabel = color
            }
        }
        fputs("[RESTORE] 적용: rating \(restoredRating)장, SP \(restoredSP)장\n", stderr)

        // 백그라운드: XMP sidecar + EXIF Rating 읽기 (저장된 별점 없는 사진만)
        let photosSnapshot = photos.map { ($0.id, $0.jpgURL, $0.rating) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var exifRatings: [UUID: Int] = [:]
            for (id, url, currentRating) in photosSnapshot {
                guard currentRating == 0 else { continue }
                // XMP sidecar first
                if let xmpResult = XMPService.readRating(for: url), xmpResult.rating > 0 {
                    exifRatings[id] = xmpResult.rating
                    continue
                }
                // EXIF fallback
                if let exif = ExifService.extractExif(from: url), let r = exif.rating, r > 0 {
                    exifRatings[id] = r
                }
            }
            guard !exifRatings.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for (id, rating) in exifRatings {
                    if let idx = self._photoIndex[id], idx < self.photos.count, self.photos[idx].rating == 0 {
                        self.photos[idx].rating = rating
                    }
                }
                if !exifRatings.isEmpty {
                    AppLogger.log(.general, "XMP/EXIF Rating 적용: \(exifRatings.count)장")
                }
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

    /// 검색창 등 TextField 포커스를 KeyCaptureView로 복원 (방향키 동작 보장)
    func restoreKeyFocus() {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }
        // KeyCaptureView를 찾아서 first responder로
        func find(_ view: NSView) -> NSView? {
            let name = String(describing: type(of: view))
            if name == "KeyCaptureView" { return view }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        if let keyView = find(contentView) {
            window.makeFirstResponder(keyView)
        }
    }

    func selectPhoto(_ id: UUID, cmdKey: Bool, shiftKey: Bool = false) {
        restoreKeyFocus()
        // SwiftUI가 다음 RunLoop에서 TextField로 되돌리는 걸 방지
        DispatchQueue.main.async { [weak self] in self?.restoreKeyFocus() }
        // 폴더/상위폴더는 선택 불가
        if let idx = _photoIndex[id], idx < photos.count {
            let photo = photos[idx]
            AppLogger.log(.selection, "selectPhoto: \(photo.fileName)\(cmdKey ? " +Cmd" : "")\(shiftKey ? " +Shift" : "")")
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
                let item = list[i]
                if !item.isFolder && !item.isParentFolder {
                    newSelection.insert(item.id)
                }
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
        // 폴더/상위폴더 제외 — 사진만 선택
        let ids = Set(filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }.map { $0.id })
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

        // 삭제 효과음
        if deleted > 0 {
            NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif", byReference: true)?.play()
        }

        // Remove from list
        removePhotosFromList(ids: ids)
    }

    /// 폴더를 휴지통으로 이동
    func deleteFolders(ids: Set<UUID>) {
        let fm = FileManager.default
        var deleted = 0
        for id in ids {
            guard let idx = _photoIndex[id], idx < photos.count else { continue }
            let photo = photos[idx]
            guard photo.isFolder else { continue }
            do {
                try fm.trashItem(at: photo.jpgURL, resultingItemURL: nil)
                deleted += 1
                fputs("[DELETE] 폴더 휴지통 이동: \(photo.jpgURL.lastPathComponent)\n", stderr)
            } catch {
                fputs("[DELETE] 폴더 삭제 실패: \(error.localizedDescription)\n", stderr)
            }
        }
        if deleted > 0 {
            NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif", byReference: true)?.play()
        }
        if deleted > 0, let url = folderURL {
            loadFolder(url, restoreRatings: true)
        }
    }

    /// 선택된 파일/폴더를 휴지통으로 이동 (통합)
    func deleteSelectedItems() {
        let ids = selectedPhotoIDs
        guard !ids.isEmpty else { return }

        let hasFolder = ids.contains { id in
            guard let idx = _photoIndex[id], idx < photos.count else { return false }
            return photos[idx].isFolder
        }
        let hasFile = ids.contains { id in
            guard let idx = _photoIndex[id], idx < photos.count else { return false }
            return !photos[idx].isFolder && !photos[idx].isParentFolder
        }

        if hasFolder { deleteFolders(ids: ids) }
        if hasFile { deleteOriginalFiles(ids: ids) }
    }

    /// 선택된 사진 파일을 대상 폴더로 이동
    func movePhotosToFolder(fileURLs: [URL], destination: URL) {
        let fm = FileManager.default
        var moved = 0
        var failed = 0
        var movedIDs = Set<UUID>()
        var fileMoveRecords: [FileMove] = []
        let total = fileURLs.count

        DispatchQueue.main.async {
            self.fileMoveActive = true
            self.fileMoveDone = 0
            self.fileMoveTotal = total
            self.fileMoveLabel = "파일 이동"
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            for (index, srcURL) in fileURLs.enumerated() {
                let destURL = destination.appendingPathComponent(srcURL.lastPathComponent)
                do {
                    if fm.fileExists(atPath: destURL.path) {
                        // 같은 이름 파일 존재 → 스킵
                        failed += 1
                        continue
                    }
                    try fm.moveItem(at: srcURL, to: destURL)
                    fileMoveRecords.append(FileMove(sourceURL: srcURL, destURL: destURL))
                    moved += 1

                    // photos 배열에서 해당 파일 찾아서 ID 수집
                    if let photo = self.photos.first(where: {
                        $0.jpgURL.path == srcURL.path || $0.rawURL?.path == srcURL.path
                    }) {
                        // JPG+RAW 쌍의 다른 파일도 이동
                        if photo.jpgURL.path == srcURL.path, let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                            let rawDest = destination.appendingPathComponent(rawURL.lastPathComponent)
                            try? fm.moveItem(at: rawURL, to: rawDest)
                        } else if photo.rawURL?.path == srcURL.path {
                            let jpgDest = destination.appendingPathComponent(photo.jpgURL.lastPathComponent)
                            if !fm.fileExists(atPath: jpgDest.path) {
                                try? fm.moveItem(at: photo.jpgURL, to: jpgDest)
                            }
                        }
                        movedIDs.insert(photo.id)
                    }
                } catch {
                    failed += 1
                    AppLogger.log(.general, "File move failed: \(srcURL.lastPathComponent) → \(error.localizedDescription)")
                }
                // 진행률 업데이트
                DispatchQueue.main.async {
                    self.fileMoveDone = index + 1
                }
            }

            DispatchQueue.main.async {
                self.fileMoveActive = false
                // Undo 기록
                if !fileMoveRecords.isEmpty {
                    self.undoStack.append((action: "파일 이동", photoIDs: movedIDs, oldRatings: [:], oldSP: [:], oldGSelect: [:], fileMoves: fileMoveRecords))
                }
                // 이동된 사진 목록에서 제거
                if !movedIDs.isEmpty {
                    self.removePhotosFromList(ids: movedIDs)
                }
                let msg = "\(moved)장 이동 완료 (Cmd+Z 되돌리기)" + (failed > 0 ? " (\(failed)장 실패)" : "")
                self.showToastMessage(msg)
                AppLogger.log(.export, "Moved \(moved) files to \(destination.lastPathComponent) (\(failed) failed)")
                // 폴더 트리 새로고침 알림
                NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
            }
        }
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
            if let i = _photoIndex[id], i < photos.count { photos[i].colorLabel = label }
        }
    }

    func toggleSpacePick(for photoID: UUID) {
        guard let i = idx(photoID) else { return }
        pushUndo(action: "SP 토글", photoIDs: [photoID])
        photos[i].isSpacePicked.toggle()
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
    }

    func toggleSpacePickForSelected() {
        pushUndo(action: "일괄 SP 토글", photoIDs: selectedPhotoIDs)
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id] { photos[i].isSpacePicked.toggle() }
        }
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
    }

    var spacePickedCount: Int {
        photos.lazy.filter { $0.isSpacePicked }.count
    }

    // MARK: - Pickshot 가져오기 결과 적용

    func importPickshotFile() {
        let result = PickshotFileService.importSelection(to: &photos, photoIndex: _photoIndex)
        if let result = result {
            photosVersion += 1
            // clientComments 딕셔너리 구축 (preview에서 표시용)
            buildClientComments()
            lastImportResult = result
            showPickshotImportSheet = true
        }
    }

    /// photos 배열의 comments를 clientComments 딕셔너리로 복사
    func buildClientComments() {
        var dict: [UUID: String] = [:]
        for photo in photos {
            if !photo.comments.isEmpty {
                dict[photo.id] = photo.comments.joined(separator: " / ")
            }
        }
        clientComments = dict
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
    // filterLock: _cachedFiltered / _filteredIndex 동시 접근 보호
    private let filterLock = NSLock()
    private var _cachedFiltered: [PhotoItem]?
    private var _cacheKey: String = ""

    func invalidateCache() {
        filterLock.lock()
        _cachedFiltered = nil
        _cacheKey = ""
        filterLock.unlock()
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
        filterLock.lock()
        if key == _cacheKey, let cached = _cachedFiltered {
            filterLock.unlock()
            return cached
        }
        filterLock.unlock()

        // Capture filter values once to avoid repeated property access
        let minRating = minimumRatingFilter
        let colorFilter = colorLabelFilter
        let qFilter = qualityFilter
        let sceneTag = sceneTagFilter
        let kwFilter = keywordFilter
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
            // Keyword filter
            if let kw = kwFilter, !photo.keywords.contains(kw) { continue }
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
        filterLock.lock()
        _cachedFiltered = final
        _cacheKey = key
        filterLock.unlock()
        return final
    }

    func invalidateFilterCache() {
        filterLock.lock()
        _cachedFiltered = nil
        _cacheKey = ""
        _filteredIndex.removeAll()
        _filteredIndexVersion = ""
        filterLock.unlock()
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
        case .customOrder:
            // 사용자 정렬 — customOrderMap 기반, 없으면 원래 순서 유지
            return list.sorted { (customOrderMap[$0.id] ?? Int.max) < (customOrderMap[$1.id] ?? Int.max) }
        }
    }

    var selectedPhotos: [PhotoItem] {
        filteredPhotos.filter { $0.rating > 0 }
    }

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
                // Set photos first (triggers didSet but sort is already done)
                self?.photos = sorted
                if restoreRatings { self?.applySavedRatings() }

                // Select first non-folder photo on NEXT run loop
                DispatchQueue.main.async {
                    guard self?.folderURL == url else { return }
                    let firstPhoto = sorted.first(where: { !$0.isParentFolder && !$0.isFolder })
                        ?? sorted.first
                    if let fp = firstPhoto {
                        self?.selectedPhotoID = fp.id
                        self?.selectedPhotoIDs = [fp.id]
                        self?.scrollTrigger += 1
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

    /// EXIF loading is now handled by ExifInfoView directly (self-contained, no photos array mutation)
    /// 목록뷰에서 보이는 행의 EXIF 로딩 (배치 — 뷰 리빌드 최소화)
    private var exifLoadingIDs: Set<UUID> = []
    private var exifBatchWork: DispatchWorkItem?

    /// 폴더 열 때 첫 N장 EXIF 배치 로딩
    func batchLoadExif(count: Int) {
        let list = photos.filter { !$0.isFolder && !$0.isParentFolder && $0.exifData == nil }
        let batch = list.prefix(count)
        guard !batch.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var loaded = 0
            for photo in batch {
                guard let exif = ExifService.extractExif(from: photo.jpgURL) else { continue }
                DispatchQueue.main.async {
                    guard let self = self,
                          let i = self._photoIndex[photo.id], i < self.photos.count else { return }
                    self._suppressDidSet = true
                    self.photos[i].exifData = exif
                    self._suppressDidSet = false
                    self.exifLoadingIDs.insert(photo.id)
                }
                loaded += 1
            }
            // 배치 완료 → UI 업데이트 (Table 갱신을 위해 photosVersion 증가)
            DispatchQueue.main.async { [weak self] in
                self?.invalidateFilterCache()
                self?.photosVersion += 1
                // @Published가 자동 알림 → objectWillChange 중복 제거
            }
        }
    }

    /// Table 셀에서 최신 데이터 조회 (struct 복사 문제 우회)
    // MARK: - 역지오코딩 (GPS → 장소명)

    private var geocodeCache: [String: String] = [:]  // "lat,lon" → placeName (max 500)
    private let geocoder = CLGeocoder()

    func reverseGeocodeIfNeeded(for photoID: UUID) {
        guard let idx = _photoIndex[photoID], idx < photos.count else { return }
        guard let exif = photos[idx].exifData,
              let lat = exif.latitude, let lon = exif.longitude,
              exif.placeName == nil else { return }

        let key = String(format: "%.4f,%.4f", lat, lon)
        if let cached = geocodeCache[key] {
            photos[idx].exifData?.placeName = cached
            return
        }

        let location = CLLocation(latitude: lat, longitude: lon)
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self, let pm = placemarks?.first else { return }
            let name = [pm.locality, pm.subLocality, pm.thoroughfare]
                .compactMap { $0 }
                .joined(separator: " ")
            let result = name.isEmpty ? (pm.country ?? "Unknown") : name
            if self.geocodeCache.count > 500 { self.geocodeCache.removeAll() }
            self.geocodeCache[key] = result
            DispatchQueue.main.async {
                guard let i = self._photoIndex[photoID], i < self.photos.count else { return }
                self.photos[i].exifData?.placeName = result
            }
        }
    }

    // MARK: - 얼굴 이름 태깅

    func setFaceGroupName(_ groupID: Int, name: String) {
        faceGroupNames[groupID] = name.isEmpty ? nil : name
        saveFaceGroupNames()
    }

    func faceGroupName(for groupID: Int) -> String {
        faceGroupNames[groupID] ?? "인물 \(groupID)"
    }

    private func saveFaceGroupNames() {
        guard let folderPath = folderURL?.path else { return }
        var all = UserDefaults.standard.dictionary(forKey: "faceGroupNames") as? [String: [String: String]] ?? [:]
        all[folderPath] = faceGroupNames.reduce(into: [:]) { $0["\($1.key)"] = $1.value }
        UserDefaults.standard.set(all, forKey: "faceGroupNames")
    }

    func loadFaceGroupNames() {
        guard let folderPath = folderURL?.path else { return }
        let all = UserDefaults.standard.dictionary(forKey: "faceGroupNames") as? [String: [String: String]] ?? [:]
        guard let saved = all[folderPath] else { return }
        faceGroupNames = saved.reduce(into: [:]) { dict, pair in
            if let key = Int(pair.key) { dict[key] = pair.value }
        }
    }

    // MARK: - ZIP 파일 열기

    private var zipTempDir: URL?

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

    func exifFor(_ id: UUID) -> ExifData? {
        guard let idx = _photoIndex[id], idx < photos.count else { return nil }
        return photos[idx].exifData
    }

    func livePhoto(_ id: UUID) -> PhotoItem? {
        guard let idx = _photoIndex[id], idx < photos.count else { return nil }
        return photos[idx]
    }

    func loadExifIfNeeded(for photoID: UUID) {
        guard let idx = _photoIndex[photoID], idx < photos.count else { return }
        guard photos[idx].exifData == nil else { return }
        guard !photos[idx].isFolder && !photos[idx].isParentFolder else { return }
        guard !exifLoadingIDs.contains(photoID) else { return }
        fputs("[EXIF] loadIfNeeded: \(photos[idx].fileName)\n", stderr)

        exifLoadingIDs.insert(photoID)
        let url = photos[idx].jpgURL
        let fileName = url.lastPathComponent
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let exif = ExifService.extractExif(from: url) else {
                fputs("[EXIF] FAIL \(fileName)\n", stderr)
                DispatchQueue.main.async { self?.exifLoadingIDs.remove(photoID) }
                return
            }
            fputs("[EXIF] OK \(fileName) lens=\(exif.lensModel ?? "nil") w=\(exif.imageWidth ?? 0)\n", stderr)
            DispatchQueue.main.async {
                guard let self = self,
                      let i = self._photoIndex[photoID], i < self.photos.count else { return }
                self._suppressDidSet = true
                self.photos[i].exifData = exif
                self._suppressDidSet = false

                // 배치: 0.3초 디바운스로 Table 갱신
                self.exifBatchWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.invalidateFilterCache()
                    self?.photosVersion += 1
                }
                self.exifBatchWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
    }

    /// 목록뷰 전환 시 전체 EXIF 배치 로딩
    private var lastExifLoadVersion: Int = -1
    func triggerListExifLoad() {
        let needExif = photos.filter { !$0.isFolder && !$0.isParentFolder && $0.exifData == nil }.count
        fputs("[EXIF] triggerListExifLoad: need=\(needExif), version=\(photosVersion), last=\(lastExifLoadVersion)\n", stderr)
        guard lastExifLoadVersion != photosVersion else { return }
        lastExifLoadVersion = photosVersion
        guard needExif > 0 else { return }
        batchLoadExif(count: photos.count)
    }

    /// 현재 위치 기반 윈도우 프리페치 — 앞뒤 50장만 로딩
    private var thumbPrefetchGeneration = 0

    private func preloadAllThumbnails() {
        thumbsTotal = photos.filter { !$0.isFolder && !$0.isParentFolder }.count
        thumbsLoaded = thumbsTotal
    }

    // MARK: - 아이들 프리뷰 프리캐싱 (현재 폴더만)
    // CPU/메모리 여유 시 백그라운드에서 미리보기 이미지를 디스크 캐시에 저장
    // 사용자가 클릭하면 디스크→메모리 즉시 로딩 (파일 디코딩 스킵)

    private var idlePrefetchGeneration = 0
    private var idlePrefetchWork: DispatchWorkItem?

    func startIdlePreviewPrefetch() {
        idlePrefetchGeneration += 1
        let gen = idlePrefetchGeneration
        let list = photos.filter { !$0.isFolder && !$0.isParentFolder }
        guard !list.isEmpty else { return }

        // 선택 위치에서 가까운 순으로 정렬
        let currentIdx: Int
        if let selID = selectedPhotoID,
           let idx = list.firstIndex(where: { $0.id == selID }) {
            currentIdx = idx
        } else {
            currentIdx = 0
        }

        // 가까운 것부터 정렬
        let sorted = list.indices.sorted { abs($0 - currentIdx) < abs($1 - currentIdx) }

        let batchSize = 3
        func prefetchBatch(from startIdx: Int) {
            guard startIdx < sorted.count, self.idlePrefetchGeneration == gen else { return }

            // CPU/메모리 체크 — 여유 있을 때만
            let memMB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
            let currentMemMB = Self.currentAppMemoryMB()
            let memUsage = currentMemMB / memMB
            guard memUsage < 0.3 else {
                // 메모리 30% 이상 사용 중 → 10초 후 재시도
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard self?.idlePrefetchGeneration == gen else { return }
                    prefetchBatch(from: startIdx)
                }
                return
            }

            let end = min(startIdx + batchSize, sorted.count)
            DispatchQueue.global(qos: .background).async { [weak self] in
                for i in startIdx..<end {
                    guard self?.idlePrefetchGeneration == gen else { return }
                    let photo = list[sorted[i]]
                    let url = photo.jpgURL
                    let cacheKey = url.appendingPathExtension("orig")

                    // 이미 캐시에 있으면 스킵
                    if PreviewImageCache.shared.get(cacheKey) != nil { continue }

                    // 고화질 로딩 → 캐시에 저장
                    if let img = PreviewImageCache.loadOptimized(url: url, maxPixel: PreviewImageCache.optimalPreviewSize()) {
                        PreviewImageCache.shared.set(cacheKey, image: img)
                        // 썸네일 캐시에도
                        ThumbnailCache.shared.set(url, image: img)
                    }
                }

                // 다음 배치: 1초 간격 (CPU 부담 최소)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard self?.idlePrefetchGeneration == gen else { return }
                    prefetchBatch(from: end)
                }
            }
        }

        prefetchBatch(from: 0)
    }

    /// 현재 앱 메모리 사용량 (MB)
    private static func currentAppMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / (1024 * 1024) : 0
    }

    /// 선택 변경 시 호출 — 현재 위치 앞뒤 50장만 프리페치
    func preloadThumbnailsAroundSelection(initialLoad: Bool = false) {
        let list = filteredPhotos
        let total = list.count
        guard total > 0 else { return }

        thumbPrefetchGeneration += 1
        let gen = thumbPrefetchGeneration
        thumbsTotal = total

        // 현재 선택 위치 찾기
        let currentIdx: Int
        if let selID = selectedPhotoID,
           let idx = list.firstIndex(where: { $0.id == selID }) {
            currentIdx = idx
        } else {
            currentIdx = 0
        }

        // 윈도우: 현재 위치에서 앞뒤 100장
        let windowSize = 100
        let start = max(0, currentIdx - windowSize)
        let end = min(total, currentIdx + windowSize)

        for i in start..<end {
            let url = list[i].jpgURL
            guard !list[i].isFolder && !list[i].isParentFolder else { continue }
            // 이미 캐시에 있으면 스킵
            if ThumbnailCache.shared.get(url) != nil { continue }
            ThumbnailLoader.shared.load(url: url) { [weak self] _ in
                guard self?.thumbPrefetchGeneration == gen else { return }
            }
        }

        // 진행률 업데이트
        DispatchQueue.main.async { [weak self] in
            self?.thumbsLoaded = min(end, total)
        }
    }

    // 백그라운드 전체 프리페치 제거 — on-demand + 앞뒤 50장만으로 충분

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

                // NIMA 미적 점수 분석 (모델 있을 때만)
                if NIMAService.isAvailable {
                    self.runNIMAScoring()
                }
            }
        }
    }

    private func runNIMAScoring() {
        let photoSnapshots = photos.filter { !$0.isFolder && !$0.isParentFolder }
        guard !photoSnapshots.isEmpty else { return }

        AppLogger.log(.general, "NIMA: \(photoSnapshots.count)장 미적 점수 분석 시작")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scores = NIMAService.scoreBatch(
                photos: photoSnapshots,
                cancelCheck: { false },
                progress: { _ in }
            )

            guard !scores.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                var updated = false
                for (id, nimaScore) in scores {
                    if let idx = self._photoIndex[id], idx < self.photos.count {
                        self.photos[idx].quality?.nimaScore = nimaScore
                        updated = true
                    }
                }
                if updated {
                    AppLogger.log(.general, "NIMA: \(scores.count)장 점수 적용 완료")
                }
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

    // MARK: - Smart Auto-Select

    func previewSmartSelect() {
        smartSelectResult = SmartSelectService.detectAndSelect(photos: photos, config: smartSelectConfig)
    }

    func applySmartSelect() {
        guard let result = smartSelectResult, !result.selectedIndices.isEmpty else { return }
        let validIndices = result.selectedIndices.filter { $0 < photos.count }
        pushUndo(action: "스마트 셀렉", photoIDs: Set(validIndices.map { photos[$0].id }))
        for idx in result.selectedIndices {
            guard idx < photos.count else { continue }
            photos[idx].isSpacePicked = true
        }
        saveRatings()
        showToastMessage("\(result.selectedCount)장 베스트샷 셀렉 완료")
    }

    var hasAnalyzedForSmartSelect: Bool {
        photos.contains { $0.quality?.isAnalyzed == true }
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

    // 즐겨찾기 별칭 (실제 폴더 이름 안 바꿈)
    private let favoriteNicknamesKey = "favoriteNicknames"

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

    /// Number of columns in the current grid layout
    /// Matches LazyVGrid(.adaptive(minimum: size, maximum: size + 40), spacing: 8)
    /// Actual columns per row - updated from GeometryReader
    // MARK: - 사용자 정렬 (드래그로 순서 변경)
    var customOrderMap: [UUID: Int] = [:]

    /// 사진 위치 이동 (드래그드롭)
    func movePhoto(from sourceID: UUID, to targetID: UUID) {
        let list = filteredPhotos
        guard let fromIdx = list.firstIndex(where: { $0.id == sourceID }),
              let toIdx = list.firstIndex(where: { $0.id == targetID }),
              fromIdx != toIdx else { return }

        // 커스텀 순서 맵 초기화 (처음이면)
        if customOrderMap.isEmpty {
            for (i, photo) in list.enumerated() {
                customOrderMap[photo.id] = i
            }
        }

        // from을 to 위치로 이동
        let fromOrder = customOrderMap[sourceID] ?? fromIdx
        let toOrder = customOrderMap[targetID] ?? toIdx

        if fromOrder < toOrder {
            for (id, order) in customOrderMap where order > fromOrder && order <= toOrder {
                customOrderMap[id] = order - 1
            }
        } else {
            for (id, order) in customOrderMap where order >= toOrder && order < fromOrder {
                customOrderMap[id] = order + 1
            }
        }
        customOrderMap[sourceID] = toOrder

        // 사용자 정렬 모드로 전환 + 뷰 리프레시
        if sortMode != .customOrder {
            sortMode = .customOrder
        }
        invalidateFilterCache()
        photosVersion += 1
        objectWillChange.send()
        fputs("[REORDER] \(sourceID.uuidString.prefix(8)) → \(targetID.uuidString.prefix(8))\n", stderr)
    }

    @Published var actualColumnsPerRow: Int = 4

    var columnsPerRow: Int {
        if viewMode == .list { return 1 }
        if layoutMode == .filmstrip { return 1 }
        return max(1, actualColumnsPerRow)
    }

    /// 그리드 열 수 재계산 — 윈도우 실제 폭 기반
    func recalcColumnsFromRatio() {
        let windowW = NSApp.keyWindow?.frame.width ?? (NSScreen.main?.frame.width ?? 1440)
        let leftW = windowW * hSplitRatio
        let size = thumbnailSize
        let spacing: CGFloat = 12
        let cellWidth = size + spacing
        let cols = max(1, Int((leftW + spacing) / cellWidth))
        if actualColumnsPerRow != cols {
            actualColumnsPerRow = cols
        }
    }

    // Cached filtered index for fast lookup
    private var _filteredIndex: [UUID: Int] = [:]

    private var _filteredIndexVersion: String = ""

    private func ensureFilteredIndex() {
        let list = filteredPhotos
        filterLock.lock()
        let key = _cacheKey
        if _filteredIndexVersion != key || _filteredIndex.isEmpty {
            _filteredIndex.removeAll(keepingCapacity: true)
            for (i, p) in list.enumerated() {
                _filteredIndex[p.id] = i
            }
            _filteredIndexVersion = key
        }
        filterLock.unlock()
    }

    /// Anchor for shift-range selection
    private var shiftAnchorIndex: Int?

    private var moveThrottleWorkItem: DispatchWorkItem?
    private var pendingMoveOffset: Int = 0
    private var lastMoveTime: CFAbsoluteTime = 0

    private func moveSelection(by offset: Int, shiftKey: Bool = false, cmdKey: Bool = false) {
        executeMoveSelection(by: offset, shiftKey: shiftKey, cmdKey: cmdKey)
    }

    private func executeMoveSelection(by offset: Int, shiftKey: Bool, cmdKey: Bool) {
        let list = filteredPhotos  // 1번만 호출
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

        // 빠른 탐색: 썸네일 즉시 표시 (SwiftUI onChange 병합 우회)
        let photo = list[newIndex]
        if !photo.isFolder && !photo.isParentFolder {
            onQuickPreview?(photo.jpgURL)
        }

    }

    private func prefetchNearby(list: [PhotoItem], centerIndex: Int, range: Int) {
        var urls: [URL] = []
        let start = max(0, centerIndex - range)
        let end = min(list.count - 1, centerIndex + range)
        guard end >= start else { return }
        for i in start...end {
            if i == centerIndex { continue }
            let url = list[i].jpgURL
            // RAW 파일은 고해상도 프리페치 스킵 (RawCamera 디모자이킹 CPU 폭발 방지)
            let ext = url.pathExtension.lowercased()
            if FileMatchingService.rawExtensions.contains(ext) { continue }
            urls.append(url)
        }
        guard !urls.isEmpty else { return }
        PreviewImageCache.shared.prefetch(urls: urls)
    }

    /// RAW 임베디드 썸네일 프리페치 (이동 방향으로 미리 채움, 병렬 추출)
    private static let thumbPrefetchQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4  // 4개 병렬 추출
        q.qualityOfService = .userInitiated
        return q
    }()

    private func prefetchThumbnailsBoth(list: [PhotoItem], centerIndex: Int, count: Int) {
        Self.thumbPrefetchQueue.cancelAllOperations()

        // 앞뒤 count장씩 수집 (가까운 것부터)
        var indices: [Int] = []
        for offset in 1...count {
            let fwd = centerIndex + offset
            let bwd = centerIndex - offset
            if fwd < list.count { indices.append(fwd) }
            if bwd >= 0 { indices.append(bwd) }
        }

        for i in indices {
            let url = list[i].jpgURL
            if ThumbnailCache.shared.get(url) != nil { continue }
            let op = BlockOperation {
                let opts: [NSString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 1200,
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
                let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                ThumbnailCache.shared.set(url, image: ns)
            }
            Self.thumbPrefetchQueue.addOperation(op)
        }
    }

    func selectRight(shift: Bool = false, cmd: Bool = false) { moveSelection(by: 1, shiftKey: shift, cmdKey: cmd) }
    func selectLeft(shift: Bool = false, cmd: Bool = false) { moveSelection(by: -1, shiftKey: shift, cmdKey: cmd) }
    func selectDown(shift: Bool = false, cmd: Bool = false) {
        fputs("[NAV] down cols=\(columnsPerRow) actual=\(actualColumnsPerRow)\n", stderr)
        moveSelection(by: columnsPerRow, shiftKey: shift, cmdKey: cmd)
    }
    func selectUp(shift: Bool = false, cmd: Bool = false) {
        fputs("[NAV] up cols=\(columnsPerRow) actual=\(actualColumnsPerRow)\n", stderr)
        moveSelection(by: -columnsPerRow, shiftKey: shift, cmdKey: cmd)
    }

    // MARK: - Scene Classification (Vision)

    /// All unique scene tags currently assigned
    var availableSceneTags: [String] {
        let tags = Set(photos.compactMap { $0.sceneTag })
        return tags.sorted()
    }

    /// All unique keywords currently assigned across all photos
    var availableKeywords: [String] {
        var kws = Set<String>()
        for photo in photos {
            for kw in photo.keywords { kws.insert(kw) }
        }
        return kws.sorted()
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

    /// Scene classification result including tag and keyword generation data
    struct SceneClassResult {
        let tag: String
        let keywords: [String]
    }

    /// Fast local scene classification: runs VNClassifyImageRequest + VNDetectFaceRectanglesRequest
    /// in a single handler.perform() call for maximum ANE throughput.
    /// Returns a Korean scene tag + IPTC keywords matching PickShot's tag vocabulary.
    private static func classifySceneTag(cgImage: CGImage) -> SceneClassResult? {
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

        // Top identifiers for keyword generation
        let topIdentifiers = sorted.prefix(5).map { $0.identifier }

        // --- Face count (confidence > 0.5 only) ---
        let faceCount = (faceReq.results ?? []).filter { $0.confidence > 0.5 }.count

        // --- Face size analysis ---
        let faces = (faceReq.results ?? []).filter { $0.confidence > 0.5 }
        let maxFaceSize = faces.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0

        // --- Combine scene + face heuristics ---
        let bestTag = tagScores.first?.tag

        // Face-based overrides
        let finalTag: String?
        if faceCount >= 5 {
            finalTag = "단체/군중"
        } else if faceCount >= 3 && bestTag != "공연/콘서트" {
            finalTag = "단체/군중"
        } else if faceCount >= 1 && faceCount <= 2 && maxFaceSize > 0.08 {
            if bestTag == nil || bestTag == "실내" || bestTag == "풍경" ||
               bestTag == "건물/건축" || bestTag == "도시/야경" {
                finalTag = maxFaceSize > 0.15 ? "인물 (클로즈업)" : "인물"
            } else {
                finalTag = bestTag
            }
        } else if let tag = bestTag {
            finalTag = tag
        } else if faceCount >= 1 {
            finalTag = "인물"
        } else {
            finalTag = nil
        }

        guard let tag = finalTag else { return nil }

        // Generate IPTC keywords
        let keywords = KeywordTaggingService.generateKeywords(
            sceneTag: tag,
            topIdentifiers: topIdentifiers,
            faceCount: faceCount,
            maxFaceSize: maxFaceSize
        )

        return SceneClassResult(tag: tag, keywords: keywords)
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
            var results: [UUID: SceneClassResult] = [:]
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

                // Single-pass scene + face classification + keyword generation
                if let result = Self.classifySceneTag(cgImage: cgImage) {
                    resultsLock.lock()
                    results[photo.id] = result
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
                        if let result = results[updated[i].id] {
                            updated[i].sceneTag = result.tag
                            updated[i].keywords = result.keywords
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
                    self.objectWillChange.send()
                    for (photoID, groupID) in results.assignments {
                        if let idx = self._photoIndex[photoID], idx < self.photos.count {
                            self.photos[idx].faceGroupID = groupID
                        }
                    }
                    self._cachedFiltered = nil
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

    /// 커스텀 프롬프트 저장 (UI에서 설정)
    @Published var aiClassifyCustomPrompt: String = ""

    func runAIClassification(customPrompt: String? = nil, selectedOnly: Bool = false) {
        // 엔진에 따라 적절한 API 키 확인
        let engine = UserDefaults.standard.string(forKey: "aiClassifyEngine") ?? "claudeHaiku"
        let hasKey = engine.hasPrefix("gemini") ? GeminiService.hasAPIKey : ClaudeVisionService.hasAPIKey
        guard !photos.isEmpty, !isAIClassifying, hasKey else { return }
        isAIClassifying = true
        aiClassifyErrors = []

        // 선택된 사진만 or 전체
        let photoSnapshots: [PhotoItem]
        if selectedOnly {
            photoSnapshots = multiSelectedPhotos.isEmpty ? (selectedPhoto.map { [$0] } ?? []) : multiSelectedPhotos
        } else {
            photoSnapshots = filteredPhotos
        }
        aiClassifyProgress = (0, photoSnapshots.count)
        let prompt = customPrompt?.isEmpty == false ? customPrompt : nil

        let baseURL = folderURL

        // 폴더 제외 + 이미 분류된 사진 스킵
        let unclassified = photoSnapshots.filter { !$0.isFolder && !$0.isParentFolder && $0.aiCategory == nil }
        let skippedCount = photoSnapshots.count - unclassified.count
        if skippedCount > 0 {
            fputs("[CLASSIFY] \(skippedCount)장 이미 분류됨 → 스킵, \(unclassified.count)장 처리\n", stderr)
        }
        guard !unclassified.isEmpty else {
            showToastMessage("모든 사진이 이미 분류되어 있습니다")
            isAIClassifying = false
            return
        }
        aiClassifyProgress = (skippedCount, photoSnapshots.count)

        Task { @MainActor in
            do {
                let results = try await ClaudeVisionService.batchClassify(
                    photos: unclassified,
                    customPrompt: prompt,
                    progress: { [weak self] done, total in
                        self?.aiClassifyProgress = (skippedCount + done, photoSnapshots.count)
                    },
                    onClassified: { photo, classification in
                        // 분류 즉시 폴더 이동 (중간에 멈춰도 처리됨)
                        let category = classification.category
                        fputs("[CLASSIFY] base=\(baseURL?.path ?? "nil") cat='\(category)' file=\(photo.jpgURL.lastPathComponent)\n", stderr)
                        guard let base = baseURL else {
                            fputs("[CLASSIFY] ❌ baseURL nil\n", stderr)
                            return
                        }
                        guard !category.isEmpty else {
                            fputs("[CLASSIFY] ❌ category empty\n", stderr)
                            return
                        }
                        let fm = FileManager.default
                        let categoryFolder = base.appendingPathComponent(category)
                        do {
                            try fm.createDirectory(at: categoryFolder, withIntermediateDirectories: true)
                        } catch {
                            fputs("[CLASSIFY] ❌ mkdir failed: \(error)\n", stderr)
                        }

                        // JPG 이동
                        let jpgDest = categoryFolder.appendingPathComponent(photo.jpgURL.lastPathComponent)
                        if !fm.fileExists(atPath: jpgDest.path) {
                            do {
                                try fm.moveItem(at: photo.jpgURL, to: jpgDest)
                                fputs("[CLASSIFY] ✅ \(photo.jpgURL.lastPathComponent) → \(category)/\n", stderr)
                            } catch {
                                fputs("[CLASSIFY] ❌ move failed: \(error)\n", stderr)
                            }
                        }
                        // RAW 매칭 파일도 이동
                        if let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                            let rawDest = categoryFolder.appendingPathComponent(rawURL.lastPathComponent)
                            if !fm.fileExists(atPath: rawDest.path) {
                                try? fm.moveItem(at: rawURL, to: rawDest)
                            }
                        }
                    },
                    onError: { [weak self] photo, errorMsg in
                        // 에러 수집 (메인 스레드에서 실행)
                        DispatchQueue.main.async {
                            self?.aiClassifyErrors.append((photo.jpgURL.lastPathComponent, errorMsg))
                        }
                    }
                )

                // 분류 결과를 photos 배열에도 반영
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

                // 완료 → 결과 생성 + 폴더 리로딩
                let successCount = results.count
                let errorCount = self.aiClassifyErrors.count
                let totalCount = unclassified.count

                // 카테고리별 통계
                var categoryStats: [String: Int] = [:]
                for (_, c) in results {
                    categoryStats[c.category, default: 0] += 1
                }
                let sortedCats = categoryStats.sorted { $0.value > $1.value }

                // 결과 메시지 생성
                let engine = UserDefaults.standard.string(forKey: "aiClassifyEngine") ?? "claudeHaiku"
                let cost = APIUsageTracker.shared.estimatedCostUSD
                var msg = "━━━━ AI 분류 완료 ━━━━\n\n"
                msg += "📊 전체: \(totalCount)장\n"
                msg += "✅ 성공: \(successCount)장\n"
                if errorCount > 0 {
                    msg += "❌ 실패: \(errorCount)장\n"
                }
                msg += "🤖 엔진: \(engine)\n"
                msg += "💰 비용: $\(String(format: "%.4f", cost))\n\n"

                if !sortedCats.isEmpty {
                    msg += "━━━━ 카테고리별 ━━━━\n"
                    for (cat, count) in sortedCats {
                        let pct = Int(Double(count) / Double(max(successCount, 1)) * 100)
                        msg += "📁 \(cat): \(count)장 (\(pct)%)\n"
                    }
                }

                if errorCount > 0 {
                    msg += "\n━━━━ 실패 항목 ━━━━\n"
                    for (filename, errMsg) in self.aiClassifyErrors.suffix(5) {
                        msg += "⚠️ \(filename): \(errMsg)\n"
                    }
                    if errorCount > 5 {
                        msg += "... 외 \(errorCount - 5)건\n"
                    }
                }

                self.aiClassifyResultMessage = msg
                self.showAIClassifyResult = true

                if successCount > 0, let base = baseURL {
                    NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
                    self.loadFolder(base, restoreRatings: true)
                }
            } catch {
                self.aiClassifyResultMessage = "❌ AI 분류 실패\n\n\(error.localizedDescription)"
                self.showAIClassifyResult = true
            }
            self.isAIClassifying = false
        }
    }

    /// 분류 완료 결과 표시
    @Published var showAIClassifyResult = false
    @Published var aiClassifyResultMessage = ""

    /// 분류 후 폴더 정리 팝업
    @Published var showOrganizePrompt = false

    /// AI 분류 결과로 폴더 정리 — 카테고리별 하위 폴더 생성 + 파일 이동
    func organizeByAICategory() {
        guard let baseURL = folderURL else { return }
        let fm = FileManager.default
        var movedCount = 0
        var failedCount = 0

        // 분류된 사진만 대상
        let categorized = photos.filter { $0.aiCategory != nil && !$0.isFolder && !$0.isParentFolder }
        guard !categorized.isEmpty else { return }

        for photo in categorized {
            guard let category = photo.aiCategory else { continue }

            // 카테고리 폴더 생성
            let categoryFolder = baseURL.appendingPathComponent(category)
            try? fm.createDirectory(at: categoryFolder, withIntermediateDirectories: true)

            // JPG 이동
            let jpgDest = categoryFolder.appendingPathComponent(photo.jpgURL.lastPathComponent)
            if !fm.fileExists(atPath: jpgDest.path) {
                do {
                    try fm.moveItem(at: photo.jpgURL, to: jpgDest)
                    movedCount += 1
                } catch {
                    failedCount += 1
                    fputs("[ORGANIZE] 이동 실패: \(photo.jpgURL.lastPathComponent) → \(error.localizedDescription)\n", stderr)
                }
            }

            // RAW 매칭 파일도 이동
            if let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                let rawDest = categoryFolder.appendingPathComponent(rawURL.lastPathComponent)
                if !fm.fileExists(atPath: rawDest.path) {
                    try? fm.moveItem(at: rawURL, to: rawDest)
                }
            }
        }

        fputs("[ORGANIZE] 완료: \(movedCount)장 이동, \(failedCount)장 실패\n", stderr)
        showToastMessage("📂 \(movedCount)장을 \(Set(categorized.compactMap { $0.aiCategory }).count)개 폴더로 정리 완료")

        // 폴더 트리 새로고침 알림
        NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)

        // 폴더 다시 로딩
        loadFolder(baseURL, restoreRatings: true)
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

        // EXIF 직접 읽기 (미로딩 시)
        var dateTaken = photo.exifData?.dateTaken
        var cameraName = photo.exifData?.cameraModel
        if dateTaken == nil || cameraName == nil {
            if let source = CGImageSourceCreateWithURL(photo.jpgURL as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                if dateTaken == nil, let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
                   let dateStr = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy:MM:dd HH:mm:ss"
                    dateTaken = df.date(from: dateStr)
                }
                if cameraName == nil, let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                    cameraName = tiff[kCGImagePropertyTIFFModel as String] as? String
                }
            }
        }

        // {date}
        if let date = dateTaken {
            let df = DateFormatter()
            df.dateFormat = dateFormat
            result = result.replacingOccurrences(of: "{date}", with: df.string(from: date))
        } else {
            // 날짜 없으면 파일 수정일 사용
            let df = DateFormatter()
            df.dateFormat = dateFormat
            result = result.replacingOccurrences(of: "{date}", with: df.string(from: photo.fileModDate))
        }

        // {time} → HHmmss
        if let date = dateTaken {
            let df = DateFormatter()
            df.dateFormat = "HHmmss"
            result = result.replacingOccurrences(of: "{time}", with: df.string(from: date))
        } else {
            let df = DateFormatter()
            df.dateFormat = "HHmmss"
            result = result.replacingOccurrences(of: "{time}", with: df.string(from: photo.fileModDate))
        }

        // {camera}
        if let model = cameraName {
            let cleaned = model.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
            result = result.replacingOccurrences(of: "{camera}", with: cleaned)
        } else {
            result = result.replacingOccurrences(of: "{camera}", with: "")
        }

        // {seq} → sequence number
        let seqNum = seqStart + index
        let seq = String(format: "%0\(seqDigits)d", seqNum)
        result = result.replacingOccurrences(of: "{seq}", with: seq)

        // {original} → original file name (without extension)
        result = result.replacingOccurrences(of: "{original}", with: photo.fileName)

        // 연속 구분자 정리 (빈 값으로 인한 __, --, .. 등)
        for sep in ["__", "--", "..", "_.","._","-_","_-",".-","-."] {
            while result.contains(sep) {
                if let firstChar = sep.first {
                    result = result.replacingOccurrences(of: sep, with: String(firstChar))
                }
            }
        }
        // 선행/후행 구분자 제거
        let trimChars = CharacterSet(charactersIn: "_-.")
        result = result.trimmingCharacters(in: trimChars)

        return result
    }

    /// Perform batch rename on selected photos
    func batchRename(pattern: String) -> (success: Int, errors: [String]) {
        return batchRename(pattern: pattern, dateFormat: "yyyyMMdd", seqDigits: 3, seqStart: 1)
    }

    func batchRename(pattern: String, dateFormat: String, seqDigits: Int, seqStart: Int, preserveRatings: Bool = true) -> (success: Int, errors: [String]) {
        let targets: [PhotoItem]
        if selectedPhotoIDs.count > 1 {
            targets = filteredPhotos.filter { selectedPhotoIDs.contains($0.id) && !$0.isFolder && !$0.isParentFolder }
        } else {
            targets = filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        }

        var successCount = 0
        var errors: [String] = []
        let fm = FileManager.default
        var renameMap: [(oldURL: URL, newURL: URL)] = []
        var ratingMap: [String: Int] = [:]  // oldFilename → rating

        // 레이팅 보존: 이름 변경 전 레이팅 수집
        if preserveRatings {
            for photo in targets {
                if photo.rating > 0 {
                    ratingMap[photo.fileName] = photo.rating
                }
            }
        }

        for (index, photo) in targets.enumerated() {
            let newBaseName = Self.previewRename(photo: photo, pattern: pattern, index: index, dateFormat: dateFormat, seqDigits: seqDigits, seqStart: seqStart)
            let jpgExt = photo.jpgURL.pathExtension
            let parentDir = photo.jpgURL.deletingLastPathComponent()
            let newJPGURL = parentDir.appendingPathComponent("\(newBaseName).\(jpgExt)")

            if newJPGURL == photo.jpgURL { continue }

            if fm.fileExists(atPath: newJPGURL.path) {
                errors.append("\(photo.fileName): 이름 충돌")
                continue
            }

            do {
                // JPG 이름 변경
                try fm.moveItem(at: photo.jpgURL, to: newJPGURL)
                renameMap.append((photo.jpgURL, newJPGURL))

                // RAW 이름 변경
                if let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                    let rawExt = rawURL.pathExtension
                    let rawParent = rawURL.deletingLastPathComponent()
                    let newRAWURL = rawParent.appendingPathComponent("\(newBaseName).\(rawExt)")
                    if !fm.fileExists(atPath: newRAWURL.path) {
                        try fm.moveItem(at: rawURL, to: newRAWURL)
                        renameMap.append((rawURL, newRAWURL))
                    }
                }

                // XMP 사이드카 이동
                let xmpURL = photo.jpgURL.deletingPathExtension().appendingPathExtension("xmp")
                if fm.fileExists(atPath: xmpURL.path) {
                    let newXMPURL = parentDir.appendingPathComponent("\(newBaseName).xmp")
                    try? fm.moveItem(at: xmpURL, to: newXMPURL)
                    renameMap.append((xmpURL, newXMPURL))
                }

                // 레이팅 보존: UserDefaults 키 갱신
                if preserveRatings, let rating = ratingMap[photo.fileName] {
                    var saved = UserDefaults.standard.dictionary(forKey: "photoRatings") as? [String: Int] ?? [:]
                    saved.removeValue(forKey: photo.fileName)
                    saved[newBaseName] = rating
                    UserDefaults.standard.set(saved, forKey: "photoRatings")
                }

                successCount += 1
            } catch {
                errors.append("\(photo.fileName): \(error.localizedDescription)")
            }
        }

        // Undo 기록 저장
        lastRenameMap = renameMap
        fputs("[RENAME] 완료: \(successCount)개 성공, \(errors.count)개 실패, undo \(renameMap.count)개 기록\n", stderr)

        // 폴더 리로드
        if successCount > 0, let url = folderURL {
            loadFolder(url, restoreRatings: true)
        }

        return (successCount, errors)
    }

    /// 이름 변경 되돌리기
    func undoBatchRename() -> Bool {
        guard !lastRenameMap.isEmpty else { return false }
        let fm = FileManager.default
        var success = true

        // 역순으로 되돌리기
        for entry in lastRenameMap.reversed() {
            do {
                if fm.fileExists(atPath: entry.newURL.path) {
                    try fm.moveItem(at: entry.newURL, to: entry.oldURL)
                }
            } catch {
                fputs("[RENAME] Undo 실패: \(error.localizedDescription)\n", stderr)
                success = false
            }
        }

        lastRenameMap = []

        // 폴더 리로드
        if let url = folderURL {
            loadFolder(url, restoreRatings: true)
        }

        fputs("[RENAME] Undo 완료: \(success)\n", stderr)
        return success
    }
}

// MARK: - NSColor Hex Extension
extension NSColor {
    static func fromHex(_ hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        return NSColor(
            red: CGFloat((val >> 16) & 0xFF) / 255,
            green: CGFloat((val >> 8) & 0xFF) / 255,
            blue: CGFloat(val & 0xFF) / 255,
            alpha: 1
        )
    }
}
