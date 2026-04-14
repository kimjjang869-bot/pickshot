import Foundation
import SwiftUI
import ImageIO
import Vision
import CoreLocation
import Combine
import AVFoundation


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

    /// 폴더 사이즈 캐시 (photos 변경 시 1회만 계산) — updateFolderSizeCache는 PhotoStore+Folder.swift
    @Published var cachedFolderSizeText: String = ""
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
            invalidateFilterCache()  // 중복 캐시 클리어 제거 — invalidateFilterCache가 이미 처리
            UserDefaults.standard.set(sortMode.rawValue, forKey: "savedSortMode")
            scrollTrigger += 1
        }
    }
    @Published var viewMode: ViewMode = .grid
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
        didSet { splitSaveWork?.cancel(); let v = hSplitRatio; let w = DispatchWorkItem { UserDefaults.standard.set(Double(v), forKey: "savedHSplitRatio") }; splitSaveWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w) }
    }
    private var splitSaveWork: DispatchWorkItem?
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
        didSet { splitSaveWork?.cancel(); let v = vSplitRatio; let w = DispatchWorkItem { UserDefaults.standard.set(Double(v), forKey: "savedVSplitRatio") }; splitSaveWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w) }
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
    var thumbsGeneration: Int = 0
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
    @Published var colorLabelFilters: Set<ColorLabel> = [] { didSet { invalidateFilterCache() } }
    @Published var slideshowInterval: Double = 3.0
    @Published var isFolderWatchingEnabled: Bool = true
    @Published var showMetadataOverlay: Bool = false
    @Published var sceneTagFilter: String? = nil { didSet { invalidateFilterCache() } }
    @Published var keywordFilter: String? = nil { didSet { invalidateFilterCache() } }
    @Published var isClassifyingScenes: Bool = false
    @Published var classifyProgress: Double = 0
    @Published var classifyStatusMessage: String = ""
    @Published var classifyDoneCount: Int = 0
    @Published var classifyTotalCount: Int = 0
    @Published var classifyStartTime: CFAbsoluteTime = 0
    @Published var layoutMode: LayoutMode = .gridPreview
    var shouldOpenFolderBrowser: Bool = false
    @Published var showBatchRename: Bool = false
    @Published var showImportResult: Bool = false
    var lastImportResult: PickshotImportResult?
    @Published var showPickshotImportSheet: Bool = false
    @Published var clientComments: [UUID: String] = [:]  // photoID -> 클라이언트 코멘트 (첫 번째)
    @Published var showMap: Bool = false
    @Published var showFullscreenPreview: Bool = false
    @Published var toastMessage: String = ""
    @Published var showToast: Bool = false

    @Published var showDeleteOriginalConfirm: Bool = false
    var pendingDeleteIDs: Set<UUID> = []
    @Published var faceGroups: [Int: [UUID]] = [:]
    @Published var faceGroupNames: [Int: String] = [:]  // 그룹ID → 인물 이름
    @Published var faceThumbnails: [Int: NSImage] = [:]
    @Published var faceGroupFilter: Int? = nil { didSet { invalidateFilterCache() } }
    @Published var isGroupingFaces: Bool = false
    @Published var faceGroupProgress: Double = 0
    @Published var faceGroupStatusMessage: String = ""
    @Published var faceGroupDoneCount: Int = 0
    @Published var faceGroupTotalCount: Int = 0
    @Published var faceGroupStartTime: CFAbsoluteTime = 0
    @Published var showAbout: Bool = false
    @Published var showDeleteConfirm: Bool = false
    @Published var showSmartSelect: Bool = false
    @Published var showSmartCull: Bool = false
    @Published var showMetadataEditor: Bool = false
    @Published var metadataEditorMode: MetadataEditorMode = .single
    enum MetadataEditorMode { case single, batch }
    @Published var showContactSheet: Bool = false
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

    // Search (debounced 300ms — 글자마다 필터 재계산 방지)
    @Published var searchText: String = ""
    private var searchDebounce: AnyCancellable?

    // MARK: - Undo Stack
    struct FileMove { let sourceURL: URL; let destURL: URL }
    /// 삭제 되돌리기용: 삭제된 PhotoItem + 원래 인덱스
    struct RemovedPhoto { let photo: PhotoItem; let originalIndex: Int }
    var undoStack: [(action: String, photoIDs: Set<UUID>, oldRatings: [UUID: Int], oldSP: [UUID: Bool], oldGSelect: [UUID: Bool], fileMoves: [FileMove], removedPhotos: [RemovedPhoto])] = []
    let maxUndoSteps = 100

    let defaults = UserDefaults.standard
    let layoutModeKey = "layoutMode"
    let lastFolderKey = "lastFolderPath"
    let ratingsKey = "photoRatings"
    let folderWatcher = FolderWatcherService()
    var folderReloadWork: DispatchWorkItem?

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

        // 검색 debounce: 타이핑 멈춘 후 300ms에 필터 캐시 무효화
        searchDebounce = $searchText
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateFilterCache()
            }

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

    // MARK: - Folder Watching / Session Persistence → PhotoStore+Folder.swift

    // MARK: - 주변 썸네일 프리로딩 (키보드 이동 시 빈 썸네일 방지)

    var prefetchWorkItem: DispatchWorkItem?

    // Fast O(1) lookup instead of O(n) linear search
    var _photoIndex: [UUID: Int] = [:]

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
    var shiftClickAnchorIndex: Int?

    /// Remove selected photos from the list (NOT from disk)
    func removeSelectedFromList() {
        let idsToRemove = photosToRemove
        guard !idsToRemove.isEmpty else { return }

        // Step 1: 다음 선택 대상 미리 계산 — 뒤(다음) 사진 우선
        // 표준 뷰어 관행: 삭제 후 다음 사진으로 이동 (이정열 작가 재피드백)
        let list = filteredPhotos
        ensureFilteredIndex()
        var nextID: UUID? = nil
        if let currentID = selectedPhotoID, let currentFilteredIdx = _filteredIndex[currentID] {
            // 뒤(다음) 사진을 먼저 찾기
            for i in (currentFilteredIdx + 1)..<list.count {
                if !idsToRemove.contains(list[i].id) && !list[i].isFolder && !list[i].isParentFolder {
                    nextID = list[i].id
                    break
                }
            }
            // 뒤에 없으면(마지막 사진이었으면) 앞(이전) 사진
            if nextID == nil {
                for i in stride(from: currentFilteredIdx - 1, through: 0, by: -1) {
                    if !idsToRemove.contains(list[i].id) && !list[i].isFolder && !list[i].isParentFolder {
                        nextID = list[i].id
                        break
                    }
                }
            }
        }

        // Step 2: 삭제 전 undo 정보 저장
        var removedItems: [RemovedPhoto] = []
        for (i, photo) in photos.enumerated() {
            if idsToRemove.contains(photo.id) {
                removedItems.append(RemovedPhoto(photo: photo, originalIndex: i))
            }
        }
        undoStack.append((action: "목록 제거", photoIDs: idsToRemove, oldRatings: [:], oldSP: [:], oldGSelect: [:], fileMoves: [], removedPhotos: removedItems))
        if undoStack.count > maxUndoSteps { undoStack.removeFirst(undoStack.count - maxUndoSteps) }

        // Step 3: didSet 억제하고 직접 배열 수정 (중복 재계산 방지)
        _suppressDidSet = true

        // in-place 제거 (배열 복사 없음)
        photos.removeAll { idsToRemove.contains($0.id) }

        // 인덱스 직접 재구축
        rebuildIndex()

        _suppressDidSet = false
        photosVersion += 1

        // 필터 캐시도 직접 업데이트 (전체 재계산 대신 제거만)
        filterLock.lock()
        if let cached = _cachedFiltered {
            _cachedFiltered = cached.filter { !idsToRemove.contains($0.id) }
            _cacheKey = "\(photosVersion)"
        }
        _filteredIndex.removeAll()
        _filteredIndexVersion = ""
        filterLock.unlock()

        // Step 3: 선택 업데이트
        selectedPhotoIDs.subtract(idsToRemove)
        if let next = nextID {
            selectedPhotoID = next
            selectedPhotoIDs = [next]
        } else if let first = _cachedFiltered?.first(where: { !$0.isFolder && !$0.isParentFolder }) ?? photos.first {
            selectedPhotoID = first.id
            selectedPhotoIDs = [first.id]
        } else {
            selectedPhotoID = nil
            selectedPhotoIDs = []
        }

        photosToRemove = []
        scrollTrigger &+= 1

        // 삭제 효과음 (macOS 휴지통 비우기, 0.28초로 자름)
        if !idsToRemove.isEmpty {
            Self.playDeleteSound()
        }

        // 폴더 사이즈는 비동기로 (렉 방지)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let totalBytes = self.photos.reduce(Int64(0)) { sum, photo in
                guard !photo.isFolder && !photo.isParentFolder else { return sum }
                return sum + photo.jpgFileSize + photo.rawFileSize
            }
            let text: String
            if totalBytes <= 0 {
                text = "\(self.photos.filter { !$0.isFolder }.count)장"
            } else if totalBytes > 1_073_741_824 {
                text = String(format: "%.1f GB", Double(totalBytes) / 1_073_741_824)
            } else if totalBytes > 1_048_576 {
                text = String(format: "%.0f MB", Double(totalBytes) / 1_048_576)
            } else {
                text = String(format: "%.0f KB", Double(totalBytes) / 1024)
            }
            DispatchQueue.main.async { self.cachedFolderSizeText = text }
        }
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
        var trashMoves: [FileMove] = []   // 휴지통 복원용

        for id in ids {
            // 안전장치: _photoIndex가 스테일할 수 있으므로 photo.id == id 검증
            // 실패 시 선형 탐색으로 폴백하여 엉뚱한 파일 삭제 방지
            let photo: PhotoItem
            if let idx = _photoIndex[id], idx < photos.count, photos[idx].id == id {
                photo = photos[idx]
            } else if let fallback = photos.first(where: { $0.id == id }) {
                fputs("[DELETE] WARN: _photoIndex 스테일 감지 — id=\(id.uuidString.prefix(8)), 선형 탐색으로 폴백: \(fallback.fileName)\n", stderr)
                photo = fallback
            } else {
                fputs("[DELETE] ERROR: photo를 찾을 수 없음 — id=\(id.uuidString.prefix(8))\n", stderr)
                continue
            }
            guard !photo.isFolder && !photo.isParentFolder else { continue }

            // 무엇을 삭제하는지 명시 로그 (디버깅 용)
            let rawLog = photo.rawURL.map { $0.lastPathComponent } ?? "nil"
            fputs("[DELETE] 삭제 대상: jpgURL=\(photo.jpgURL.lastPathComponent), rawURL=\(rawLog)\n", stderr)

            // Delete JPG → 휴지통 (복원 경로 기록)
            do {
                if fm.fileExists(atPath: photo.jpgURL.path) {
                    var trashURL: NSURL?
                    try fm.trashItem(at: photo.jpgURL, resultingItemURL: &trashURL)
                    if let t = trashURL as URL? {
                        trashMoves.append(FileMove(sourceURL: photo.jpgURL, destURL: t))
                    }
                }
            } catch { failed += 1 }

            // Delete RAW → 휴지통 (jpgURL과 같으면 스킵 — 이미 삭제됨)
            if let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                do {
                    if fm.fileExists(atPath: rawURL.path) {
                        var trashURL: NSURL?
                        try fm.trashItem(at: rawURL, resultingItemURL: &trashURL)
                        if let t = trashURL as URL? {
                            trashMoves.append(FileMove(sourceURL: rawURL, destURL: t))
                        }
                    }
                } catch { failed += 1 }
            }
            deleted += 1
        }

        AppLogger.log(.export, "Deleted \(deleted) files (\(failed) failed) to Trash")

        // 삭제 효과음 (macOS 휴지통 비우기, 0.28초)
        // 주의: removePhotosFromList 안에서도 재생되므로 여기는 생략 — 이중 재생 방지

        // Remove from list (undo 스택에 목록 제거 정보 저장됨)
        removePhotosFromList(ids: ids)

        // undo 스택 마지막 항목에 파일 이동 정보 추가 (휴지통 복원용)
        if !trashMoves.isEmpty, var lastUndo = undoStack.popLast() {
            lastUndo.action = "파일 삭제"
            lastUndo.fileMoves = trashMoves
            undoStack.append(lastUndo)
        }

        // 우리가 직접 삭제한 파일이므로 FolderWatcher가 리로드를 트리거하지 않도록 baseline 동기화
        // → 1~3초 후 발생하는 화면 깜빡임 방지
        folderWatcher.syncBaselineSilently()
        folderReloadWork?.cancel()
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
            Self.playDeleteSound()
        }
        if deleted > 0, let url = folderURL {
            // 폴더 삭제는 구조가 바뀌므로 리로드가 필요. 다만 watcher 중복 리로드는 막음.
            folderReloadWork?.cancel()
            loadFolder(url, restoreRatings: true)
            folderWatcher.syncBaselineSilently()
        }
    }

    /// 삭제 요청 — 설정에 따라 확인 대화상자 표시 or 바로 실행
    /// 기본값: 확인 없이 바로 휴지통으로 이동 (빠른 셀렉 워크플로우)
    func requestDeleteOriginal(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeleteIDs = ids

        // 설정 확인 — skipDeleteConfirm 기본값 true (빠른 워크플로우)
        let skipConfirm = UserDefaults.standard.object(forKey: "skipDeleteConfirm") as? Bool ?? true

        if skipConfirm {
            // 바로 실행 (파일은 휴지통으로, Undo 가능)
            let hasFolder = ids.contains { id in
                guard let idx = _photoIndex[id], idx < photos.count else { return false }
                return photos[idx].isFolder
            }
            if hasFolder { deleteFolders(ids: ids) }
            let fileIDs = ids.filter { id in
                guard let idx = _photoIndex[id], idx < photos.count else { return false }
                return !photos[idx].isFolder && !photos[idx].isParentFolder
            }
            if !fileIDs.isEmpty { deleteOriginalFiles(ids: Set(fileIDs)) }
            pendingDeleteIDs = []
        } else {
            // 확인 대화상자 표시
            showDeleteOriginalConfirm = true
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
    /// Finder 등 외부에서 드래그된 파일을 현재 폴더로 복사(또는 이동).
    /// - moveInstead가 true면 이동, 아니면 복사.
    /// - 폴더가 열려 있어야 하며(folderURL 존재), 이미지/RAW/비디오 파일만 받아들임.
    /// - 중복 이름은 " (1)", " (2)" 로 자동 네이밍.
    func importFilesFromExternal(urls: [URL], moveInstead: Bool = false) {
        guard let destination = folderURL else {
            showToastMessage("먼저 폴더를 열어주세요")
            return
        }

        let fm = FileManager.default
        // 원본 경로의 폴더(현재 열린 폴더)에서 온 파일은 스킵 — 리오더 같은 내부 드롭 충돌 방지
        let destPath = destination.standardizedFileURL.path
        let filtered = urls.filter { url in
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            return parent != destPath
        }
        guard !filtered.isEmpty else { return }

        // 지원 가능한 파일만 (이미지/RAW/비디오)
        let accepted = filtered.filter { url in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return false }
            return FileMatchingService.isImportableFile(url)
        }
        guard !accepted.isEmpty else {
            showToastMessage("지원하는 이미지/RAW/비디오 파일이 없습니다")
            return
        }

        let total = accepted.count
        let label = moveInstead ? "파일 이동" : "파일 복사"

        DispatchQueue.main.async {
            self.fileMoveActive = true
            self.fileMoveDone = 0
            self.fileMoveTotal = total
            self.fileMoveLabel = label
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var done = 0
            var failed = 0
            var copiedRecords: [FileMove] = []

            for (index, srcURL) in accepted.enumerated() {
                // 중복 이름 해결
                let base = srcURL.deletingPathExtension().lastPathComponent
                let ext = srcURL.pathExtension
                var candidate = destination.appendingPathComponent(srcURL.lastPathComponent)
                var n = 1
                while fm.fileExists(atPath: candidate.path) {
                    let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                    candidate = destination.appendingPathComponent(newName)
                    n += 1
                    if n > 999 { break }
                }

                do {
                    if moveInstead {
                        try fm.moveItem(at: srcURL, to: candidate)
                    } else {
                        try fm.copyItem(at: srcURL, to: candidate)
                    }
                    copiedRecords.append(FileMove(sourceURL: srcURL, destURL: candidate))
                    done += 1
                } catch {
                    failed += 1
                    AppLogger.log(.general, "\(label) 실패: \(srcURL.lastPathComponent) → \(error.localizedDescription)")
                }

                DispatchQueue.main.async {
                    self.fileMoveDone = index + 1
                }
            }

            DispatchQueue.main.async {
                self.fileMoveActive = false

                // FolderWatcher가 중복 리로드하지 않도록 baseline 갱신
                self.folderWatcher.syncBaselineSilently()

                // Undo 기록 (이동만, 복사는 수동 삭제가 안전)
                if moveInstead, !copiedRecords.isEmpty {
                    self.undoStack.append((action: "파일 가져오기", photoIDs: Set<UUID>(),
                                           oldRatings: [:], oldSP: [:], oldGSelect: [:],
                                           fileMoves: copiedRecords, removedPhotos: []))
                    if self.undoStack.count > self.maxUndoSteps {
                        self.undoStack.removeFirst(self.undoStack.count - self.maxUndoSteps)
                    }
                }

                let verb = moveInstead ? "이동" : "복사"
                let msg = "\(done)장 \(verb) 완료" + (failed > 0 ? " (\(failed)장 실패)" : "") + (moveInstead ? " (Cmd+Z 되돌리기)" : "")
                self.showToastMessage(msg)

                // 새 파일이 현재 폴더에 들어왔으므로 리로드
                if done > 0 {
                    self.loadFolder(destination, restoreRatings: true)
                    FolderPreviewCache.shared.invalidate(destination)
                    NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
                }
            }
        }
    }

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
                    self.undoStack.append((action: "파일 이동", photoIDs: movedIDs, oldRatings: [:], oldSP: [:], oldGSelect: [:], fileMoves: fileMoveRecords, removedPhotos: []))
                }
                // 이동된 사진 목록에서 제거
                if !movedIDs.isEmpty {
                    self.removePhotosFromList(ids: movedIDs)
                }
                let msg = "\(moved)장 이동 완료 (Cmd+Z 되돌리기)" + (failed > 0 ? " (\(failed)장 실패)" : "")
                self.showToastMessage(msg)
                AppLogger.log(.export, "Moved \(moved) files to \(destination.lastPathComponent) (\(failed) failed)")
                // 폴더 프리뷰 캐시 무효화 (이동 원본 + 대상 폴더)
                FolderPreviewCache.shared.invalidate(destination)
                if let srcParent = fileURLs.first?.deletingLastPathComponent() {
                    FolderPreviewCache.shared.invalidate(srcParent)
                }
                // 폴더 트리 새로고침 알림
                NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
            }
        }
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

    /// 사진 수 (폴더 제외) — O(1) 캐시 기반, 매 렌더마다 filter 방지
    var photoCount: Int {
        filteredPhotos.lazy.filter { !$0.isFolder && !$0.isParentFolder }.count
    }

    /// 스페이스 셀렉 수 — O(1) 캐시 기반
    var spacePickCount: Int {
        photos.lazy.filter { $0.isSpacePicked }.count
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
        let colorFilters = colorLabelFilters
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
            // Color label filter (다중 선택 지원)
            if !colorFilters.isEmpty && !colorFilters.contains(photo.colorLabel) { continue }
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

    // loadFolder / loadPhotosRecursive / exitRecursiveMode → PhotoStore+Folder.swift

    /// EXIF loading is now handled by ExifInfoView directly (self-contained, no photos array mutation)
    /// 목록뷰에서 보이는 행의 EXIF 로딩 (배치 — 뷰 리빌드 최소화)
    var exifLoadingIDs: Set<UUID> = []
    var exifBatchWork: DispatchWorkItem?

    /// Table 셀에서 최신 데이터 조회 (struct 복사 문제 우회)
    // MARK: - 역지오코딩 (GPS → 장소명)

    var geocodeCache: [String: String] = [:]  // "lat,lon" → placeName (max 500)
    let geocoder = CLGeocoder()

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

    // MARK: - ZIP 파일 열기 → openZipFile/cleanupZipTemp는 PhotoStore+Folder.swift

    var zipTempDir: URL?

    /// 목록뷰 전환 시 전체 EXIF 배치 로딩
    var lastExifLoadVersion: Int = -1

    /// 현재 위치 기반 윈도우 프리페치 — 앞뒤 50장만 로딩
    var thumbPrefetchGeneration = 0

    // MARK: - 아이들 프리뷰 프리캐싱 (현재 폴더만)
    // CPU/메모리 여유 시 백그라운드에서 미리보기 이미지를 디스크 캐시에 저장
    // 사용자가 클릭하면 디스크→메모리 즉시 로딩 (파일 디코딩 스킵)

    var idlePrefetchGeneration = 0
    var idlePrefetchWork: DispatchWorkItem?

    /// 현재 앱 메모리 사용량 (MB)
    static func currentAppMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / (1024 * 1024) : 0
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
                    // in-place 업데이트 — 전체 배열 복사 방지 (10K 사진 시 ~8MB 절약)
                    self._suppressDidSet = true
                    for i in self.photos.indices {
                        if let quality = results[self.photos[i].id] {
                            self.photos[i].quality = quality
                        }
                    }
                    self._suppressDidSet = false
                    self.photosVersion += 1
                    self.invalidateFilterCache()
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
        // 메인스레드에서 photos 스냅샷을 먼저 찍어서 백그라운드로 전달
        let snapshot = self.photos
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let groups = ImageAnalysisService.findDuplicateGroups(photos: snapshot)
            guard !groups.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let selectedID = self.selectedPhotoID
                self._suppressDidSet = true
                for i in 0..<self.photos.count {
                    if let group = groups[self.photos[i].id] {
                        self.photos[i].duplicateGroupID = group.groupID
                        self.photos[i].isBestInGroup = group.isBest
                    }
                }
                self._suppressDidSet = false
                self.rebuildIndex(); self.invalidateFilterCache()
                self.objectWillChange.send()
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

    // openFolder / navigation / recent / favorite folders → PhotoStore+Folder.swift

    // MARK: - Recent / Favorite Folder Keys

    let recentFoldersKey = "recentFolders"
    let favoriteFoldersKey = "favoriteFolders"
    // 즐겨찾기 별칭 (실제 폴더 이름 안 바꿈)
    let favoriteNicknamesKey = "favoriteNicknames"

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

    /// 여러 사진을 한 번에 target 위치로 이동 (다중 선택 드래그 리오더).
    /// - sourceIDs가 1개면 movePhoto로 위임.
    /// - target이 source에 포함되면 무시.
    /// - insertBefore=true면 target 앞, false면 뒤에 블록 삽입.
    func movePhotos(_ sourceIDs: Set<UUID>, to targetID: UUID, insertBefore: Bool = true) {
        guard !sourceIDs.isEmpty else { return }
        if sourceIDs.count == 1, let only = sourceIDs.first {
            movePhoto(from: only, to: targetID)
            return
        }
        guard !sourceIDs.contains(targetID) else { return }

        let list = filteredPhotos
        let allOrdered = list.map { $0.id }
        let selectedInOrder = allOrdered.filter { sourceIDs.contains($0) }
        let remaining = allOrdered.filter { !sourceIDs.contains($0) }

        guard let targetIdx = remaining.firstIndex(of: targetID) else { return }
        let insertAt = insertBefore ? targetIdx : targetIdx + 1

        var newOrder = remaining
        newOrder.insert(contentsOf: selectedInOrder, at: insertAt)

        customOrderMap.removeAll()
        for (i, id) in newOrder.enumerated() {
            customOrderMap[id] = i
        }

        if sortMode != .customOrder {
            sortMode = .customOrder
        }
        invalidateFilterCache()
        photosVersion += 1
        // photosVersion @Published 변경으로 충분 — objectWillChange.send() 중복 호출 제거
        fputs("[REORDER MULTI] \(sourceIDs.count)장 → \(targetID.uuidString.prefix(8)) (before=\(insertBefore))\n", stderr)
    }

    @Published var actualColumnsPerRow: Int = 4

    var columnsPerRow: Int {
        if viewMode == .list { return 1 }
        if layoutMode == .filmstrip { return 1 }
        return max(1, actualColumnsPerRow)
    }

    // Cached filtered index for fast lookup
    var _filteredIndex: [UUID: Int] = [:]

    var _filteredIndexVersion: String = ""

    func ensureFilteredIndex() {
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
    var shiftAnchorIndex: Int?

    var moveThrottleWorkItem: DispatchWorkItem?
    var pendingMoveOffset: Int = 0
    var lastMoveTime: CFAbsoluteTime = 0

    /// 삭제 효과음 — macOS 휴지통 비우기 소리(empty trash.aif)를 0.28초로 잘라 재생
    /// AVAudioPlayer 사용 → NSSound 대비 레이턴시 낮음 (pre-loaded buffer)
    /// 연타 대비 플레이어 풀 사용 (stop() 간섭 방지)
    private static let _deleteSoundPool: [AVAudioPlayer] = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif"
        let url = URL(fileURLWithPath: path)
        var pool: [AVAudioPlayer] = []
        for _ in 0..<4 {
            if let p = try? AVAudioPlayer(contentsOf: url) {
                p.prepareToPlay()  // 디코더 워밍업 → 첫 재생 레이턴시 감소
                pool.append(p)
            }
        }
        return pool
    }()
    private static var _deleteSoundIndex: Int = 0
    private static let _deleteSoundDuration: TimeInterval = 0.28  // 짧게 자르기

    static func playDeleteSound() {
        guard !_deleteSoundPool.isEmpty else { return }
        // 라운드 로빈: 다음 가용 플레이어 선택 (연타 시 겹치지 않게)
        _deleteSoundIndex = (_deleteSoundIndex + 1) % _deleteSoundPool.count
        let player = _deleteSoundPool[_deleteSoundIndex]
        player.stop()
        player.currentTime = 0
        player.play()
        // 0.28초 후 자동 정지 (꼬리 자르기)
        // 플레이어는 static 풀이 영구 보유 → retain cycle 없음
        DispatchQueue.main.asyncAfter(deadline: .now() + _deleteSoundDuration) {
            player.stop()
        }
    }

    /// RAW 임베디드 썸네일 프리페치 (이동 방향으로 미리 채움, 병렬 추출)
    static let thumbPrefetchQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4  // 4개 병렬 추출
        q.qualityOfService = .userInitiated
        return q
    }()

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
        classifyStartTime = CFAbsoluteTimeGetCurrent()

        let photoSnapshots = photos.filter { !$0.isFolder && !$0.isParentFolder }
        let total = photoSnapshots.count
        classifyTotalCount = total
        classifyDoneCount = 0
        classifyStatusMessage = "장면 분류 준비 중..."
        let startTime = classifyStartTime
        print("🏷 [SCENE] Start: \(total) photos")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.classifyStatusMessage = "장면 + 얼굴 + 색상 + 구도 분석 중..."
            }
            // 고급 분류 서비스 사용 (장면+얼굴+텍스트+동물+색상+구도 통합)
            let results = AdvancedClassificationService.classifyBatch(
                photos: photoSnapshots,
                cancelCheck: { false },
                progress: { done in
                    let c = done
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let rate = elapsed > 0 ? Double(c) / elapsed : 0
                    if c % 50 == 0 || c == total {
                        if c == total {
                            print("🏷 [SCENE] DONE: \(total) photos in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", rate)) photos/s)")
                        } else {
                            print("🏷 [SCENE] Progress: \(c)/\(total) in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", rate)) photos/s)")
                        }
                    }
                    // 더 빈번한 UI 업데이트 (10장마다 또는 전체 200장 이하면 매장)
                    if c % (total < 200 ? 1 : 10) == 0 || c == total {
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self else { return }
                            self.classifyProgress = Double(c) / Double(total)
                            self.classifyDoneCount = c
                            if c < total {
                                let eta = rate > 0 ? Double(total - c) / rate : 0
                                let etaStr = eta < 60 ? "\(Int(eta))초" : "\(Int(eta/60))분 \(Int(eta) % 60)초"
                                self.classifyStatusMessage = "분석 중 (\(String(format: "%.1f", rate))장/초) · 약 \(etaStr) 남음"
                            } else {
                                self.classifyStatusMessage = "결과 적용 중..."
                            }
                        }
                    }
                }
            )

            DispatchQueue.main.async {
                guard let self = self else { return }
                if !results.isEmpty {
                    let selectedID = self.selectedPhotoID
                    self._suppressDidSet = true
                    for i in 0..<self.photos.count {
                        if let result = results[self.photos[i].id] {
                            self.photos[i].sceneTag = result.sceneTag
                            self.photos[i].keywords = result.keywords
                            self.photos[i].colorMood = result.colorMood.rawValue
                            self.photos[i].compositionType = result.compositionType.rawValue
                            self.photos[i].timeOfDay = result.timeOfDay.rawValue
                            self.photos[i].dominantColors = result.dominantColors
                            self.photos[i].hasText = result.hasText
                            self.photos[i].personCoverage = result.personCoverage
                        }
                    }
                    self._suppressDidSet = false
                    self.rebuildIndex(); self.invalidateFilterCache()
                    self.selectedPhotoID = selectedID
                    self.photosVersion += 1
                }
                self.isClassifyingScenes = false
                self.classifyProgress = 1.0
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                self.classifyStatusMessage = "완료! \(String(format: "%.1f", elapsed))초"

                // === 분류 결과 통계 로그 (stderr) ===
                let classified = self.photos.filter { $0.sceneTag != nil && !$0.isFolder && !$0.isParentFolder }
                let unclassified = self.photos.filter { $0.sceneTag == nil && !$0.isFolder && !$0.isParentFolder }
                var tagCounts: [String: Int] = [:]
                var moodCounts: [String: Int] = [:]
                var compCounts: [String: Int] = [:]
                var todCounts: [String: Int] = [:]
                var totalFaces = 0
                var personPhotos = 0
                var textPhotos = 0
                for p in classified {
                    tagCounts[p.sceneTag ?? "nil", default: 0] += 1
                    if let m = p.colorMood, !m.isEmpty { moodCounts[m, default: 0] += 1 }
                    if let c = p.compositionType, !c.isEmpty { compCounts[c, default: 0] += 1 }
                    if let t = p.timeOfDay, !t.isEmpty { todCounts[t, default: 0] += 1 }
                    if p.personCoverage > 0.03 { personPhotos += 1 }
                    if p.hasText { textPhotos += 1 }
                }
                // stderr + 파일 동시 출력
                var log = "\n[CLASSIFY] ━━━ 장면분류 결과 ━━━\n"
                log += "[CLASSIFY] 총 \(photoSnapshots.count)장 → 분류됨: \(classified.count)장, 미분류: \(unclassified.count)장\n"
                log += "[CLASSIFY] 장면태그:\n"
                for (tag, cnt) in tagCounts.sorted(by: { $0.value > $1.value }) {
                    log += "[CLASSIFY]   \(tag): \(cnt)장\n"
                }
                log += "[CLASSIFY] 색상분위기:\n"
                for (m, cnt) in moodCounts.sorted(by: { $0.value > $1.value }) {
                    log += "[CLASSIFY]   \(m): \(cnt)장\n"
                }
                log += "[CLASSIFY] 구도:\n"
                for (c, cnt) in compCounts.sorted(by: { $0.value > $1.value }) {
                    log += "[CLASSIFY]   \(c): \(cnt)장\n"
                }
                log += "[CLASSIFY] 시간대:\n"
                for (t, cnt) in todCounts.sorted(by: { $0.value > $1.value }) {
                    log += "[CLASSIFY]   \(t): \(cnt)장\n"
                }
                log += "[CLASSIFY] 인물감지: \(personPhotos)장, 텍스트감지: \(textPhotos)장\n"
                log += "[CLASSIFY] ━━━━━━━━━━━━━━━\n\n"
                fputs(log, stderr)
                try? log.write(toFile: "/tmp/pickshot_classify.log", atomically: true, encoding: .utf8)
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
        faceGroupStartTime = CFAbsoluteTimeGetCurrent()

        // 선택 여부 무관하게 폴더 내 전체 사진 대상
        let photoSnapshots = photos
        let total = photoSnapshots.count
        fputs("[FACE] 전체 사진 \(total)장 대상 얼굴 그룹핑 시작\n", stderr)
        faceGroupTotalCount = total
        faceGroupDoneCount = 0
        faceGroupStatusMessage = "얼굴 감지 준비 중..."
        let startTime = faceGroupStartTime

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.faceGroupStatusMessage = "얼굴 감지 + 특징 추출 중..."
            }
            let results = FaceGroupingService.groupFaces(
                photos: photoSnapshots,
                progress: { [weak self] done in
                    let p = Double(done) / Double(total)
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let rate = elapsed > 0 ? Double(done) / elapsed : 0
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.faceGroupProgress = p
                        self.faceGroupDoneCount = done
                        if done < total {
                            let eta = rate > 0 ? Double(total - done) / rate : 0
                            let etaStr = eta < 60 ? "\(Int(eta))초" : "\(Int(eta/60))분 \(Int(eta) % 60)초"
                            self.faceGroupStatusMessage = "얼굴 분석 중 (\(String(format: "%.1f", rate))장/초) · 약 \(etaStr) 남음"
                        } else {
                            self.faceGroupStatusMessage = "얼굴 그룹 매칭 중..."
                        }
                    }
                }
            )

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !results.assignments.isEmpty {
                    let selectedID = self.selectedPhotoID
                    self._suppressDidSet = true
                    for (photoID, groupID) in results.assignments {
                        if let idx = self._photoIndex[photoID], idx < self.photos.count {
                            self.photos[idx].faceGroupID = groupID
                        }
                    }
                    self._suppressDidSet = false
                    self.rebuildIndex(); self.invalidateFilterCache()
                    self.objectWillChange.send()
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
                let groupCount = results.groups.count
                let faceCount = results.assignments.count
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                self.faceGroupStatusMessage = "완료! \(groupCount)명, \(faceCount)장 · \(String(format: "%.1f", elapsed))초"
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
            var newBaseName = Self.previewRename(photo: photo, pattern: pattern, index: index, dateFormat: dateFormat, seqDigits: seqDigits, seqStart: seqStart)
            // 보안: 경로 구분자, null 문자 제거 (경로 이탈 방지)
            newBaseName = newBaseName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\0", with: "")
                .replacingOccurrences(of: ":", with: "_")
                .replacingOccurrences(of: "..", with: "_")
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
