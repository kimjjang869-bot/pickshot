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
            // 키 꾹 누르기 중에는 prefetch 스킵 — 매 이동마다 60장 concurrent async 를 큐에 쌓으면
            // 키 놓았을 때 수천 개 작업이 한꺼번에 실행되며 10초+ 렉 발생
            // 키가 떨어진 순간에 마지막 한 번만 prefetch (디바운스 1초)
            if isKeyRepeat {
                // 연속 이동 중: 이전 예약만 취소하고 새로 예약하지 않음
                prefetchWorkItem?.cancel()
            } else {
                prefetchNearbyThumbnails()
            }
            // 지오코딩은 키 떼는 순간에만
            if !isKeyRepeat, let id = selectedPhotoID { reverseGeocodeIfNeeded(for: id) }
        }
    }
    @Published var selectedPhotoIDs: Set<UUID> = []
    /// Incremented when keyboard navigation happens, triggers scroll
    @Published var scrollTrigger: Int = 0
    var scrollAnchor: UnitPoint = .bottom
    /// true when key is held down (OS key repeat), false for actual press
    var isKeyRepeat: Bool = false
    /// Cmd+X 로 잘라낸 사진 ID — 썸네일 흐리게 표시용 (paste 완료 시 clear)
    @Published var pendingCutPhotoIDs: Set<UUID> = []
    /// 빠른 탐색 시 썸네일 즉시 표시용 콜백 (디스크 I/O 없음)
    var onQuickPreview: ((URL) -> Void)?
    @Published var minimumRatingFilter: Int = 0 { didSet { invalidateFilterCache() } }
    /// v8.7: 별점 필터 — 개별 선택. 비어있으면 전체 표시. ratingFilters 있으면 minimumRatingFilter 무시.
    @Published var ratingFilters: Set<Int> = [] { didSet { invalidateFilterCache() } }
    /// v8.7: 선택한 사진만 보기 — 클라이언트 비교용
    @Published var showOnlySelected: Bool = false { didSet { invalidateFilterCache() } }
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
    var _analysisCancel = false
    let analysisCancelLock = NSLock()
    var analysisCancel: Bool {
        get { analysisCancelLock.lock(); defer { analysisCancelLock.unlock() }; return _analysisCancel }
        set { analysisCancelLock.lock(); _analysisCancel = newValue; analysisCancelLock.unlock() }
    }
    @Published var folderURL: URL?
    /// 현재 폴더가 느린 디스크(HDD/SD/NAS)에 있는지. loadFolder에서 background로 검사 후 set.
    /// PhotoPreviewView가 stage2 스킵 결정 등에 활용.
    @Published var currentFolderIsSlowDisk: Bool = false
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
    // 별점/SP/컬러라벨 저장 debounce — 연속 변경 시 마지막 것만 실제 저장
    var saveRatingsWorkItem: DispatchWorkItem?
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
    // v8.6.2: 캐시 생성 진행률 (CacheProgressGauge 표시용 — EXIF thumbsLoaded 와 별개)
    @Published var previewsLoaded: Int = 0
    @Published var thumbCacheCount: Int = 0
    var previewsStartTime: CFAbsoluteTime = 0
    var cacheProgressStartTime: CFAbsoluteTime = 0
    var previewsElapsed: TimeInterval { previewsStartTime > 0 ? CFAbsoluteTimeGetCurrent() - previewsStartTime : 0 }
    var cacheProgressElapsed: TimeInterval { cacheProgressStartTime > 0 ? CFAbsoluteTimeGetCurrent() - cacheProgressStartTime : 0 }
    private var _previewLoadedURLs: Set<URL> = []
    private var _thumbCacheInsertedURLs: Set<URL> = []
    private let _cacheProgressLock = NSLock()
    /// 미리보기가 처음 생성된 URL 을 기록해서 중복 카운트 방지. main thread 외에서 호출 안전.
    func notePreviewLoaded(url: URL) {
        _cacheProgressLock.lock()
        let isNew = _previewLoadedURLs.insert(url).inserted
        _cacheProgressLock.unlock()
        guard isNew else { return }
        DispatchQueue.main.async { [weak self] in
            self?.previewsLoaded += 1
        }
    }
    /// v8.6.2: ThumbnailCache 인입 알림 처리 — 현재 폴더의 사진만 카운트.
    func noteThumbCacheInserted(url: URL) {
        guard let folder = folderURL else { return }
        // 현재 폴더 직속 파일만 (재귀 폴더 경우에는 folder.path 의 하위면 OK).
        guard url.path.hasPrefix(folder.path) else { return }
        _cacheProgressLock.lock()
        let isNew = _thumbCacheInsertedURLs.insert(url).inserted
        _cacheProgressLock.unlock()
        guard isNew else { return }
        DispatchQueue.main.async { [weak self] in
            self?.thumbCacheCount += 1
        }
    }
    func clearPreviewTracking() {
        _cacheProgressLock.lock()
        _previewLoadedURLs.removeAll()
        _thumbCacheInsertedURLs.removeAll()
        _cacheProgressLock.unlock()
    }
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

    // 전송 세부 정보 (복사/잘라내기 진행 팝업용)
    @Published var bgTransferCurrentFile: String = ""      // 현재 처리 중인 파일명
    @Published var bgTransferSourcePath: String = ""       // 원본 경로
    @Published var bgTransferDestPath: String = ""         // 대상 경로
    @Published var bgTransferBytesDone: Int64 = 0          // 누적 전송 바이트
    @Published var bgTransferBytesTotal: Int64 = 0         // 전체 바이트
    @Published var bgTransferSpeed: Double = 0             // 초당 바이트 (즉시 속도)
    @Published var bgTransferETA: TimeInterval = 0         // 남은 시간 (초)
    @Published var bgTransferSpeedHistory: [Double] = []   // 최근 30개 샘플 (그래프)
    var bgTransferStartedAt: Date?
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
    /// 고객 펜 그림 오버레이 표시 여부 (F 키 토글)
    @Published var showClientPenOverlay: Bool = true
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
    /// v8.6.3 (v8.7 프리뷰): 다중 인물 선택 — OR 조합 ("신랑 or 신부" 같은 필터)
    @Published var faceGroupFilters: Set<Int> = [] { didSet { invalidateFilterCache() } }
    /// v8.7: 파일명 번호 범위 필터 — 파일명에서 마지막 숫자 추출 후 [min, max] 포함 검사
    /// 예: DSC01234.ARW → 1234. (1000, 1500) 설정 시 1000~1500 사이만 통과.
    @Published var rangeFilterMin: Int? = nil { didSet { invalidateFilterCache() } }
    @Published var rangeFilterMax: Int? = nil { didSet { invalidateFilterCache() } }

    /// v8.7: 참조 기반 시각 검색 활성화 여부 — VisualSearchService.matchedURLs 로 필터
    @Published var visualSearchActive: Bool = false { didSet { invalidateFilterCache() } }
    /// v8.7: 시각 검색 크롭 선택 Sheet 표시
    @Published var showVisualSearchCrop: Bool = false
    @Published var visualSearchCropURL: URL? = nil
    @Published var visualSearchCropMode: VisualSearchMode = .face
    /// 같은 사람 추가 샷 — 미리 세팅된 label (VisualSearchCropView 에서 readonly 표시)
    @Published var visualSearchPresetLabel: String? = nil

    /// 파일명에서 마지막 숫자 블록 추출 (예: "DSC01234.ARW" → 1234, "IMG_9876-edit.jpg" → 9876)
    static func extractFileNumber(from url: URL) -> Int? {
        let base = url.deletingPathExtension().lastPathComponent
        // 뒤에서부터 연속된 숫자 블록 찾기
        var digits = ""
        for ch in base.reversed() {
            if ch.isNumber { digits.insert(ch, at: digits.startIndex) }
            else if !digits.isEmpty { break }
        }
        return Int(digits)
    }
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
    var lastRenameNameMap: [(oldName: String, newName: String)] = []  // Undo용 파일명 매핑 (UserDefaults 복원)
    var lastRenameFolderPath: String = ""  // Undo 시 폴더별 컬러/스페이스픽 복원용
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
    /// Undo 가능한 paste 기록 (별도 스택). Rating undo 와 섞이지 않음.
    /// - kind: "copy" or "cut"
    /// - items: (source, dest) 쌍 목록. Cut 시 source→dest 이동, Copy 시 dest 만 기록.
    struct PasteUndoRecord {
        let kind: String  // "copy" or "cut"
        let items: [(source: URL, dest: URL)]
        let destFolder: URL
    }
    var pasteUndoStack: [PasteUndoRecord] = []
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

        // v8.6.2: ThumbnailCache 인입 알림 구독 (CacheProgressGauge)
        NotificationCenter.default.addObserver(
            forName: .thumbnailCacheInserted, object: nil, queue: nil
        ) { [weak self] note in
            guard let url = note.object as? URL else { return }
            self?.noteThumbCacheInserted(url: url)
        }

        // 상시 메모리 감시 — 세션 시작 대비 +2GB 초과 시 자동 캐시 해제
        MemoryGuardService.shared.start()

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
        // v8.6.2 fix: launch 시에도 UserDefaults 값을 라이브 프로퍼티에 sync.
        //   (이전엔 SettingsChanged notification 때만 호출되어 previewResolution 이 0 (기본값) 으로
        //    남아있었고, CacheSweeper 는 1000 으로 caching → cacheKey 불일치로 모든 클릭이 cache MISS)
        applySettingsFromDefaults()

        // 마지막 폴더 자동 복원 (뷰어 모드 즉시 진입)
        // Try security-scoped bookmark first, then fall back to path string
        let hasLastFolder: Bool = {
            if let url = SandboxBookmarkService.resolveBookmark(key: "lastFolder") {
                SandboxBookmarkService.stopAccessing(url)
                return true
            }
            if let lastPath = defaults.string(forKey: lastFolderKey),
               !lastPath.isEmpty,
               FileManager.default.fileExists(atPath: lastPath) {
                return true
            }
            return false
        }()
        if hasLastFolder {
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


    var spacePickedCount: Int {
        photos.lazy.filter { $0.isSpacePicked }.count
    }

    // Cached filtered results - invalidated when inputs change
    // filterLock: _cachedFiltered / _filteredIndex 동시 접근 보호
    let filterLock = NSLock()
    var _cachedFiltered: [PhotoItem]?
    var _cacheKey: String = ""

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
        let rFilters = ratingFilters  // v8.7 개별 별점 필터
        let onlySelected = showOnlySelected
        let selectedIDsSnapshot = selectedPhotoIDs
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
            // v8.7: 선택한 사진만 보기 (클라이언트 비교용) — parentFolder 는 예외적으로 항상 포함
            if onlySelected && !photo.isParentFolder {
                if !selectedIDsSnapshot.contains(photo.id) { continue }
            }
            // v8.7: 개별 별점 필터 (Set) 우선, 없으면 기존 최소값 방식
            if !rFilters.isEmpty {
                if !rFilters.contains(photo.rating) { continue }
            } else if minRating > 0 && photo.rating < minRating { continue }
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
            // 단일 인물 필터 (기존) — 하위호환
            if let fg = fgID, photo.faceGroupID != fg { continue }
            // 다중 인물 필터 (OR) — v8.7: faceGroupFilters 가 있으면 포함된 그룹만 통과
            if !faceGroupFilters.isEmpty {
                if let gid = photo.faceGroupID, faceGroupFilters.contains(gid) {
                    // ok
                } else {
                    continue
                }
            }
            // v8.7: 파일명 번호 범위 필터
            if rangeFilterMin != nil || rangeFilterMax != nil {
                guard let num = PhotoStore.extractFileNumber(from: photo.jpgURL) else { continue }
                if let lo = rangeFilterMin, num < lo { continue }
                if let hi = rangeFilterMax, num > hi { continue }
            }
            // v8.7: 시각 검색 필터 (활성 시 VisualSearchService.matchedURLs 에 포함된 것만)
            if visualSearchActive {
                if !VisualSearchService.shared.matchedURLs.contains(photo.jpgURL) { continue }
            }
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
        // Sandbox에서 /System/Library 직접 접근 불가 → 번들 사운드 또는 NSSound 기반 대체
        // macOS는 NSSound(named:) 으로 시스템 사운드에 안전하게 접근 가능
        // AVAudioPlayer 풀은 번들에 사운드 파일이 있을 때만 생성
        var pool: [AVAudioPlayer] = []
        if let soundURL = Bundle.main.url(forResource: "delete", withExtension: "aif") {
            for _ in 0..<4 {
                if let p = try? AVAudioPlayer(contentsOf: soundURL) {
                    p.prepareToPlay()
                    pool.append(p)
                }
            }
        }
        return pool
    }()
    private static var _deleteSoundIndex: Int = 0
    private static let _deleteSoundDuration: TimeInterval = 0.28  // 짧게 자르기

    static func playDeleteSound() {
        guard !_deleteSoundPool.isEmpty else {
            // 번들 사운드 없을 때 시스템 사운드 폴백
            NSSound(named: "Funk")?.play()
            return
        }
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
        // v8.6.3: usesCPUOnly deprecated in macOS 14 — GPU/ANE 는 기본 동작

        let faceReq = VNDetectFaceRectanglesRequest()
        if #available(macOS 13.0, *) {
            faceReq.revision = VNDetectFaceRectanglesRequestRevision3
        }
        // v8.6.3: usesCPUOnly deprecated — GPU 기본 동작

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
    var availableFaceGroups: [Int] {
        Array(faceGroups.keys).sorted()
    }

    @Published var aiClassifyCustomPrompt: String = ""

    @Published var showAIClassifyResult = false
    @Published var aiClassifyResultMessage = ""

    /// 분류 후 폴더 정리 팝업
    @Published var showOrganizePrompt = false

    /// AI 분류 결과로 폴더 정리 — 카테고리별 하위 폴더 생성 + 파일 이동
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
