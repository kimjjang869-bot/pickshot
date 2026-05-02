import SwiftUI
import Quartz

struct ContentView: View {
    @EnvironmentObject var store: PhotoStore
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var memoryCardService = MemoryCardBackupService.shared
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @State private var folderBrowserExpanded: Bool = false
    @State private var folderBrowserWidth: CGFloat = 250
    @State private var folderBrowserResizeStartWidth: CGFloat?
    @State private var folderBrowserResizePreviewWidth: CGFloat?
    @State private var showFullscreen: Bool = false
    @State private var dualWindow: NSWindow?

    // G Select state (used by toolbar extension)
    @ObservedObject var gSelect = GSelectService.shared
    @ObservedObject private var clientSelect = ClientSelectService.shared
    #if DEBUG
    @ObservedObject private var memTracker = MemoryLeakTracker.shared
    @State private var debugStressTimer: DispatchSourceTimer?
    @State private var debugStressStarted = false
    @State private var debugOpenedEnvPath = false
    #endif
    @State var linkCopied = false
    @State var showGSelectQR = false

    // Mouse side-button (back/forward) event monitor
    @State private var mouseSideButtonMonitor: Any?

    // v8.6.3: CacheSweeper.prepareForFolder 쓰로틀 (스트리밍 photos 변동)
    @State private var sweepPrepareWork: DispatchWorkItem?

    // 테스터 키 — 숨겨진 Cmd+Shift+Option+K 로 다이얼로그 표시
    @State private var testerKeyMonitor: Any?
    @State private var showTesterKeySheet = false
    @State private var testerKeyInput: String = ""
    @State private var testerKeyAlertMessage: String?
    @State private var testerKeyAlertSuccess: Bool = false

    private var folderSizeText: String { store.cachedFolderSizeText }
    private let folderBrowserMinWidth: CGFloat = 120
    private let folderBrowserMaxWidth: CGFloat = 560

    private var importResultMessage: String {
        guard let r = store.lastImportResult else { return "가져오기 실패" }
        var msg = "매칭 성공: \(r.matched.count)장"
        // v8.9.4: SP 셀렉 잔재 메시지 제거 (기능 폐지)
        if !r.unmatched.isEmpty {
            msg += "\n\n미매칭: \(r.unmatched.count)장"
            msg += "\n\(r.unmatched.prefix(5).joined(separator: ", "))"
        }
        return msg
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.startupMode == .tethering {
                // Tethering mode
                VStack(spacing: 0) {
                    HStack {
                        Button(action: { store.startupMode = nil }) {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                Text("돌아가기")
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        Spacer()

                        Text("테더링")
                            .font(.system(size: 14, weight: .semibold))

                        Spacer()
                        Color.clear.frame(width: 80)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                    Divider()

                    // AppConfig 플래그로 Debug(개발자 테스트) vs Release(Coming Soon) 분기
                    if AppConfig.enableTethering {
                        TetherView()
                    } else {
                        TetherComingSoonView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.startupMode == nil && store.photos.isEmpty && !store.isLoading {
                // No photos loaded and not in viewer mode - show startup screen
                StartupView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showFullscreen {
                // 전체화면 모드 — 같은 윈도우에서 UI만 교체
                FullscreenView(isPresented: $showFullscreen)
            } else {
                // Viewer mode
                toolbar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .onAppear {
                        if store.shouldOpenFolderBrowser {
                            folderBrowserExpanded = true
                            store.shouldOpenFolderBrowser = false
                        }
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                Divider()

                HStack(spacing: 0) {
                    // Folder Browser Sidebar (only when photos loaded)
                    if store.showFolderBrowser {
                        FolderBrowserView(isExpanded: $folderBrowserExpanded)
                            .frame(width: folderBrowserExpanded ? folderBrowserWidth.clamped(to: folderBrowserMinWidth...folderBrowserMaxWidth) : 36)
                            .animation(.easeInOut(duration: 0.2), value: folderBrowserExpanded)

                        // Drag handle for resizing
                        if folderBrowserExpanded {
                            Rectangle()
                                .fill(Color.gray.opacity(0.01))
                                .frame(width: 6)
                                .cursor(NSCursor.resizeLeftRight)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let startWidth = folderBrowserResizeStartWidth ?? folderBrowserWidth
                                            folderBrowserResizeStartWidth = startWidth
                                            let newWidth = startWidth + value.translation.width
                                            folderBrowserResizePreviewWidth = newWidth.clamped(to: folderBrowserMinWidth...folderBrowserMaxWidth)
                                        }
                                        .onEnded { _ in
                                            if let preview = folderBrowserResizePreviewWidth {
                                                folderBrowserWidth = preview
                                            }
                                            folderBrowserResizeStartWidth = nil
                                            folderBrowserResizePreviewWidth = nil
                                        }
                                )
                                .onHover { inside in
                                    if inside { NSCursor.resizeLeftRight.push() }
                                    else { NSCursor.pop() }
                                }
                        }

                        Divider()
                    }

                    // Main content area (Row 2 toolbar + content)
                    VStack(spacing: 0) {
                    toolbarRow2
                    Divider()

                    // v8.7: 시각 검색 HUD (플로팅, 검색 활성 시만 표시)
                    #if DEBUG
                    VisualSearchHUD {
                        // 해제 시 필터 off + SwiftUI 강제 리렌더
                        store.visualSearchActive = false
                        store.invalidateFilterCache()
                    }
                    #endif

                    // Content area
                    if store.isLoading {
                        // Loading - show progress inside content area (folder browser stays visible)
                        VStack(spacing: 16) {
                            Spacer()
                            ProgressView()
                                .scaleEffect(1.2)
                            Text(store.loadingStatus)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            VStack(spacing: 4) {
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(width: 300, height: 8)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.accentColor)
                                        .frame(width: 300 * store.loadingProgress, height: 8)
                                }
                                Text("\(Int(store.loadingProgress * 100))%")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.accentColor)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if store.layoutMode == .filmstrip {
                        // Filmstrip mode: full-width preview + bottom filmstrip
                        VStack(spacing: 0) {
                            if let photo = store.selectedPhoto {
                                PhotoPreviewView(photo: photo)
                            } else {
                                Text("사진을 선택하세요")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }

                            Divider()
                            FilmstripView()
                        }
                    } else {
                        // Grid+Preview mode (default)
                        GeometryReader { geo in
                            // v8.9.7+: 패널 폭은 유저 드래그(hSplitRatio)로만 결정. 썸네일 크기는 cell
                            //   렌더링만 영향 — Bridge 스타일. 이전엔 maxColsW 로 썸네일 크기에 따라
                            //   패널 폭이 자동 변경되어 사용자 의도와 다른 동작.
                            let leftW = max(300, min(geo.size.width * store.hSplitRatio, geo.size.width * 0.7))
                            let previewH = max(150, min(geo.size.height * store.vSplitRatio, geo.size.height - 120))
                            HStack(spacing: 0) {
                                // Left panel
                                VStack(spacing: 0) {
                                    ThumbnailGridView()
                                        // v8.6.3: 스크롤바 + DragHandle/창 리사이즈 겹침 방지 (8→14)
                                        .padding(.trailing, 14)

                                    Divider()
                                    // Status bar
                                    HStack(spacing: 0) {
                                        // Left: View mode + thumbnail slider
                                        HStack(spacing: 6) {
                                            Picker("보기 모드", selection: $store.viewMode) {
                                                ForEach(ViewMode.allCases, id: \.self) { mode in
                                                    Image(systemName: mode.icon).tag(mode)
                                                }
                                            }
                                            .pickerStyle(.segmented)
                                            .labelsHidden()
                                            .frame(width: 60)
                                            .help("보기 모드 전환 (그리드/목록)")

                                            if store.viewMode == .grid {
                                                Divider().frame(height: 14)
                                                Image(systemName: "photo")
                                                    .font(.system(size: 8))
                                                    .foregroundColor(AppTheme.textSecondary)
                                                Slider(value: $store.thumbnailSize, in: 60...250, step: 20)
                                                    .frame(maxWidth: 120)
                                                    .help("썸네일 크기 조절")
                                                Image(systemName: "photo")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(AppTheme.textSecondary)
                                            }

                                        }

                                        Spacer()

                                        // Selection / Total / Folder size (붙여서 표시)
                                        HStack(spacing: 6) {
                                            if store.selectionCount > 0 {
                                                Text("선택: \(store.selectionCount)장")
                                                    .foregroundColor(AppTheme.accent)
                                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                Text("/")
                                                    .foregroundColor(AppTheme.textDim)
                                            }
                                            Text("전체: \(store.photoCount)장")
                                                .foregroundColor(.yellow)
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))

                                            // v8.9.4: SP 셀렉 잔재 — 상태바 SP 카운트 표시 제거

                                            Text("·").foregroundColor(AppTheme.textDim)

                                            Image(systemName: "internaldrive")
                                                .font(.system(size: 10))
                                                .foregroundColor(.white)
                                            Text(folderSizeText)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.white)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(nsColor: .windowBackgroundColor))
                                }
                                .frame(width: leftW)

                                // Horizontal divider handle
                                DragHandle(axis: .horizontal)
                                    .gesture(
                                        DragGesture(minimumDistance: 5)
                                            .onChanged { value in
                                                // v8.9.2 perf: 임계값 0.003→0.008 강화 (60+ 이벤트 → ~20)
                                                let currentW = geo.size.width * store.hSplitRatio
                                                let newW = currentW + value.translation.width
                                                let newRatio = newW / geo.size.width
                                                let clamped = max(0.10, min(newRatio, 0.55))
                                                if abs(clamped - store.hSplitRatio) >= 0.008 {
                                                    store.hSplitRatio = clamped
                                                }
                                            }
                                    )

                                // Right panel
                                VStack(spacing: 0) {
                                    if store.selectionCount > 1 {
                                        // 다중 선택 — 썸네일 그리드
                                        MultiPreviewGrid(store: store)
                                            .frame(height: previewH)
                                    } else if let photo = store.selectedPhoto {
                                        // v8.9.4: 미리보기 꽉차게 — 하단 메타 영역/DragHandle/frame 제거
                                        PhotoPreviewView(photo: photo)
                                    } else {
                                        Text("사진을 선택하세요")
                                            .font(.title3)
                                            .foregroundColor(.secondary)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                            }
                            .onAppear { updateGridColumns(width: leftW) }
                            .onChange(of: leftW) { _, newW in updateGridColumns(width: newW) }
                            .onChange(of: store.thumbnailSize) { _, _ in updateGridColumns(width: leftW) }
                        }
                    }
                    } // end VStack (toolbarRow2 + content)
                }
                .overlay(alignment: .leading) {
                    if store.showFolderBrowser,
                       folderBrowserExpanded,
                       let preview = folderBrowserResizePreviewWidth {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.accentColor.opacity(0.65))
                            .frame(width: 3)
                            .offset(x: preview)
                            .allowsHitTesting(false)
                    }
                }
            }

            // Bottom: Analysis progress bar
            if store.isAnalyzing {
                AnalysisProgressBar(progress: store.analyzeProgress, total: store.photos.count, onStop: { store.stopAnalysis() })
            }
        }
        .sheet(isPresented: $store.showBatchRename) { BatchRenameView() }
        .sheet(isPresented: $store.showBurstPickerDialog) {
            BurstPickerDialog(isPresented: $store.showBurstPickerDialog)
                .environmentObject(store)
        }
        // v9.0.2: Pro 잠금 모달 — proLockedFeature 가 set 되면 표시.
        .sheet(item: $store.proLockedFeature) { feature in
            ProLockModal(feature: feature)
        }
        .sheet(isPresented: $store.showPreferenceTrainingDialog) {
            PreferenceTrainingDialog(isPresented: $store.showPreferenceTrainingDialog)
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showMetadataEditor) {
            MetadataEditorSheet(store: store)
        }
        .sheet(isPresented: $store.showExportSheet) { ExportView() }
        .sheet(isPresented: $store.showContactSheet) { ContactSheetView().environmentObject(store) }
        .sheet(isPresented: $store.showMatchingSheet) { MatchingView(isPresented: $store.showMatchingSheet) }
        .sheet(isPresented: $store.showShortcutHelp) { ShortcutHelpView() }
        .sheet(isPresented: $store.showAbout) { AboutView() }
        .sheet(isPresented: $store.showSmartSelect) { SmartSelectView() }
        .sheet(isPresented: $store.showSmartCull) { SmartCullView().environmentObject(store) }
        .sheet(isPresented: $store.showBatchProcess) { BatchProcessView() }
        // v8.7: 시각 검색 결과 변경 시 필터 재적용 (active 일 때만)
        .onReceive(VisualSearchService.shared.$matchedURLs) { newMatched in
            guard store.visualSearchActive else { return }
            // 매칭 결과가 비어버렸는데 active 면 사용자가 닫기를 누르는 과도기 → 건너뛰기 (onDeactivate 가 처리)
            if newMatched.isEmpty && VisualSearchService.shared.references.isEmpty { return }
            store.invalidateFilterCache()
        }
        .sheet(isPresented: $memoryCardService.showBackupPrompt) { MemoryCardBackupPromptView() }
        .sheet(isPresented: $memoryCardService.showBackupResult) { MemoryCardBackupResultView() }
        .sheet(isPresented: $store.showCustomPrompt) { CustomPromptView(store: store) }
        .sheet(isPresented: $clientSelect.showSetup) { ClientSelectSetupView() }
        .sheet(isPresented: $clientSelect.showSessionList) { ClientSessionListView() }
        .sheet(isPresented: $clientSelect.showProxySetup) { ClientProxySetupView() }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                // 메모리카드 백업 진행률
                ForEach(memoryCardService.sessions.filter { !$0.isComplete }) { session in
                    BackupProgressBar(session: session, service: memoryCardService)
                }
                // 백그라운드 내보내기/붙여넣기 진행률
                if store.bgExportActive {
                    // 붙여넣기(복사/잘라내기)는 상세 정보 포함 전용 창
                    if store.bgExportLabel == "붙여넣기" || store.bgExportLabel == "잘라내기" {
                        TransferProgressView(store: store)
                    } else {
                        ExportProgressBar(store: store)
                    }
                }
                // AI 분류 진행률
                if store.isAIClassifying {
                    AIClassifyProgressBar(store: store)
                }
                // Vision 로컬 분석 진행 패널
                if store.isClassifyingScenes || store.isGroupingFaces || SmartCullService.shared.isProcessing {
                    VisionAnalysisProgressPanel(store: store)
                }
                // 파일 이동 진행률
                if store.fileMoveActive {
                    FileMoveProgressBar(store: store)
                }
                // 클라이언트 셀렉 업로드 진행률 (업로드 중만 — 완료 시 팝업으로 전환)
                if clientSelect.isUploading {
                    ClientUploadProgressBar(service: clientSelect)
                }
            }
            .padding(.bottom, 40)
            .animation(.easeInOut, value: memoryCardService.sessions.count)
            .animation(.easeInOut, value: store.bgExportActive)
            .animation(.easeInOut, value: store.isAIClassifying)
            .animation(.easeInOut, value: store.isClassifyingScenes)
            .animation(.easeInOut, value: store.isGroupingFaces)
        }
        .overlay(alignment: .topTrailing) {
            // v8.9.7+: 통합 디버그 HUD — preview 정보 + nav perf + memory tracker 한 창에 모음.
            #if DEBUG
            UnifiedDebugHUD()
                .padding(.trailing, 16)
                .padding(.top, 60)
            #endif
        }
        .onAppear {
            #if DEBUG
            // v8.6.1: 메모리 누수 추적 스트레스 테스트 provider 연결
            let tracker = MemoryLeakTracker.shared
            tracker.stressPhotoProvider = {
                store.photos.filter { !$0.isFolder && !$0.isParentFolder }.map { $0.id }
            }
            tracker.stressPhotoSelector = { id in
                store.selectedPhotoID = id
            }
            tracker.stressGridColsProvider = {
                // v8.6.2 fix: 실제 표시 중인 그리드 열 수 반환 (이전엔 6 하드코딩 → 실제 열 수와 달라
                //   대각선으로 이동하는 버그). store.actualColumnsPerRow 가 updateGridColumns 에서 실시간 갱신됨.
                let cols = store.actualColumnsPerRow
                return cols > 0 ? cols : 6
            }
            tracker.stressDeleteAction = { ids in
                store.deleteOriginalFiles(ids: ids)
            }
            tracker.stressCacheInvalidator = { urls in
                PhotoStore.invalidateCachesForDeletedURLs(urls)
            }
            tracker.stressURLProvider = { id in
                store.photos.first(where: { $0.id == id })?.jpgURL
            }
            // v8.9.3: 랜덤 폴더 전환 — 현재 폴더의 부모에서 형제 폴더 enumerate
            tracker.stressFolderProvider = {
                guard let current = store.folderURL else { return [] }
                let parent = current.deletingLastPathComponent()
                let fm = FileManager.default
                guard let contents = try? fm.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { return [] }
                // 디렉토리만 + 시스템 경로 제외
                let systemPaths: Set<String> = ["/Volumes", "/System", "/Library", "/usr", "/private"]
                return contents.filter { url in
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: url.path, isDirectory: &isDir)
                    return isDir.boolValue && !systemPaths.contains(url.path)
                }
            }
            tracker.stressFolderSwitcher = { url, includeSub in
                store.startupMode = .viewer
                if includeSub {
                    store.loadPhotosRecursive(from: url)
                } else {
                    store.loadFolder(url, restoreRatings: true)
                }
            }
            #endif

            // v8.6.2: CacheSweeper 의존성 주입 + 활동 훅
            let sweeper = CacheSweeper.shared
            sweeper.isSlowDiskProvider = { ThumbnailLoader.shared.isSlowDisk }
            sweeper.isBusyProvider = {
                var busy = store.isLoading || store.isConverting || store.isAnalyzing
                    || store.isPreloadingThumbs
                #if DEBUG
                busy = busy || MemoryLeakTracker.shared.isStressTesting
                #endif
                return busy
            }
            // v8.9.4: 스크롤 진행 중 sweep 차단 — NSThumbnailCollectionView Coordinator 가 갱신
            sweeper.isScrollingProvider = { NSThumbnailCollectionView.activeCoordinator?.isScrollingNow ?? false }
            // v8.9.4: recursive scan 진행 중 sweep 차단
            sweeper.isRecursiveScanProvider = { [weak store] in store?.isRecursiveScanInProgress ?? false }
            sweeper.isRecursiveModeProvider = { [weak store] in store?.isRecursiveMode ?? false }
            // v8.8.1: 적극 캐시 모드 바인딩
            sweeper.aggressiveModeProvider = { [weak store] in store?.aggressiveCache ?? false }
            sweeper.selectedIndexProvider = {
                // v8.6.2: O(n) firstIndex → O(1) _photoIndex
                guard let id = store.selectedPhotoID,
                      let idx = store._photoIndex[id] else { return nil }
                return idx
            }
            sweeper.storeNotePreview = { [weak store] url in
                store?.notePreviewLoaded(url: url)
            }
            // 프리뷰와 동일한 소스 정책 사용.
            // RAW+JPG 페어는 카메라 JPG 색감을 유지하고, RAW-only 항목만 RAW/embedded 경로를 탄다.
            sweeper.resolveDecodeURLProvider = { [weak store] jpgURL in
                guard let store = store else { return nil }
                for p in store.photos {
                    if p.jpgURL == jpgURL {
                        return PreviewLoadingPolicy.previewSourceURL(for: p)
                    }
                }
                return nil
            }
        }
        .onChange(of: store.selectedPhotoID) { _, _ in
            CacheSweeper.shared.notifyActivity()
        }
        .onChange(of: store.folderURL) { _, newURL in
            // v8.6.3: 스트리밍 로드 대응 — photosVersion 변화에서 재구성 (아래 onChange 에서 처리)
            // v8.7: 폴더 전환 시 시각 검색 상태 save/restore
            VisualSearchService.shared.switchFolder(
                to: newURL?.path,
                currentActive: store.visualSearchActive
            ) { restoredActive in
                store.visualSearchActive = restoredActive
                store.invalidateFilterCache()
            }
        }
        .onChange(of: store.photosVersion) { _, _ in
            // v8.6.3: photos 가 스트리밍으로 append 될 때마다 sweep 대상 업데이트.
            //   연속 호출 방지 위해 500ms 쓰로틀 (마지막 상태로 확정).
            guard let url = store.folderURL else { return }
            sweepPrepareWork?.cancel()
            let work = DispatchWorkItem {
                guard !store.isRecursiveMode else {
                    // 하위폴더 포함 3~4만 장에서 전체 thumbnail sweep 을 준비하면
                    // 단일 폴더보다 훨씬 무거워진다. 재귀 모드는 보이는 셀/선택 주변 로딩만 사용한다.
                    CacheSweeper.shared.cancel()
                    return
                }
                let urls = store.photos.compactMap { p -> URL? in
                    guard !p.isFolder, !p.isParentFolder else { return nil }
                    return p.jpgURL
                }
                if urls.count > 0 {
                    CacheSweeper.shared.prepareForFolder(url: url, photos: urls)
                    // v8.9: CLIP 임베딩 백그라운드 인덱싱 시작 — 적극 캐시 모드일 때만.
                    //   (기본 모드는 시스템 부하 최소화 원칙)
                    if store.aggressiveCache && ImageEmbeddingService.shared.isAvailable {
                        SemanticSearchService.shared.startIndexing(folderURL: url, urls: urls)
                    }
                }
            }
            sweepPrepareWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            #if DEBUG
            startDebugStressDriverIfRequested()
            #endif
        }
        .alert("셀렉 가져오기 완료", isPresented: $store.showImportResult) {
            Button("확인") {}
        } message: {
            Text(importResultMessage)
        }
        .sheet(isPresented: $store.showPickshotImportSheet) {
            PickshotImportResultSheet(store: store)
        }
        .sheet(isPresented: $store.showAIClassifyResult) {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI 분류 결과")
                    .font(.headline)

                ScrollView {
                    Text(store.aiClassifyResultMessage)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 350)

                HStack {
                    Button("닫기") { store.showAIClassifyResult = false }
                    Spacer()
                    if store.aiClassifyErrors.count > 0 {
                        Button("실패 항목 재시도") {
                            store.showAIClassifyResult = false
                            // 실패한 사진만 다시 분류 (aiCategory 없는 것)
                            store.runAIClassification()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(20)
            .frame(width: 450, height: 450)
        }
        .alert("AI 분류 완료", isPresented: $store.showOrganizePrompt) {
            Button("폴더 정리") { store.organizeByAICategory() }
            Button("나중에", role: .cancel) {}
        } message: {
            let cats = store.availableAICategories
            Text("분류 결과를 기반으로 \(cats.count)개 카테고리 폴더를 만들고 파일을 이동하시겠습니까?\n\n카테고리: \(cats.prefix(5).joined(separator: ", "))\(cats.count > 5 ? " 외 \(cats.count - 5)개" : "")")
        }
        .sheet(isPresented: $gSelect.showSetupSheet) { GSelectSetupView() }
        .sheet(isPresented: $store.showFaceCompare) {
            FaceCompareSheet(store: store)
        }
        .sheet(isPresented: $store.showCompare) {
            if store.selectionCount >= 2, store.multiSelectedPhotos.count >= 2 {
                let selected = Array(store.multiSelectedPhotos.prefix(4))
                CompareView(photos: selected, store: store)
            }
        }
        .sheet(isPresented: $store.showSlideshow) {
            SlideshowView(photos: store.filteredPhotos, interval: store.slideshowInterval)
        }
        .sheet(isPresented: $store.showMap) {
            PhotoMapView(photos: store.filteredPhotos) { photoID in
                store.selectPhoto(photoID, cmdKey: false)
            }
        }
        .sheet(isPresented: $updateService.showUpdateSheet) {
            UpdateView(updateService: updateService)
        }
        // 트라이얼 만료 Paywall — 이전엔 앱을 강제 종료했지만 App Store 정책 위배.
        // 대신 해제 불가능한 sheet 로 Paywall 을 노출해 구매하도록 유도한다.
        .sheet(isPresented: $subscriptionManager.showTrialExpiredPaywall) {
            PaywallView()
                .interactiveDismissDisabled(true)
        }
        // 테스터 키 입력 시트 (숨겨진 Cmd+Shift+Option+K 단축키로 호출)
        .sheet(isPresented: $showTesterKeySheet) {
            TesterKeyInputSheet(
                input: $testerKeyInput,
                message: $testerKeyAlertMessage,
                isSuccess: $testerKeyAlertSuccess,
                onSubmit: {
                    let result = subscriptionManager.activateTesterKey(testerKeyInput)
                    applyTesterKeyResult(result)
                },
                onClose: {
                    showTesterKeySheet = false
                    testerKeyInput = ""
                    testerKeyAlertMessage = nil
                    testerKeyAlertSuccess = false
                }
            )
        }
        .onAppear { installTesterKeyMonitor() }
        .onDisappear { removeTesterKeyMonitor() }
        .alert("업데이트 확인", isPresented: $updateService.showUpToDateAlert) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("최신 버전입니다 (v\(updateService.currentVersion))")
        }
        .alert("목록에서 제거", isPresented: $store.showDeleteConfirm) {
            Button("제거", role: .destructive) {
                store.removeSelectedFromList()
            }
            .keyboardShortcut(.defaultAction)
            Button("취소", role: .cancel) {
                store.photosToRemove = []
            }
        } message: {
            Text("선택한 \(store.photosToRemove.count)장을 목록에서 제거하시겠습니까? (파일은 삭제되지 않습니다)")
        }
        .alert("⚠️ 휴지통으로 이동", isPresented: $store.showDeleteOriginalConfirm) {
            Button("휴지통으로 이동", role: .destructive) {
                let ids = store.pendingDeleteIDs
                let hasFolder = ids.contains { id in
                    guard let idx = store._photoIndex[id], idx < store.photos.count else { return false }
                    return store.photos[idx].isFolder
                }
                if hasFolder { store.deleteFolders(ids: ids) }
                let fileIDs = ids.filter { id in
                    guard let idx = store._photoIndex[id], idx < store.photos.count else { return false }
                    return !store.photos[idx].isFolder && !store.photos[idx].isParentFolder
                }
                if !fileIDs.isEmpty { store.deleteOriginalFiles(ids: Set(fileIDs)) }
                store.pendingDeleteIDs = []
            }
            .keyboardShortcut(.defaultAction)
            Button("취소", role: .cancel) {
                store.pendingDeleteIDs = []
            }
        } message: {
            Text("선택한 \(store.pendingDeleteIDs.count)장의 원본 파일(JPG+RAW)을 휴지통으로 이동합니다.\n\n이 작업은 되돌릴 수 있지만, 휴지통을 비우면 복구할 수 없습니다.\n\n개발자는 파일 손실에 대해 책임지지 않습니다.")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .preferredColorScheme(store.isDarkMode ? .dark : .light)
        .background(KeyEventHandlingView(store: store, onFullscreen: { showFullscreen.toggle() }, onHideFullscreen: { showFullscreen = false }))
        .onChange(of: store.showFullscreenPreview) { _, newVal in
            if newVal {
                showFullscreen = true
                store.showFullscreenPreview = false
            }
        }
        .overlay(alignment: .bottom) {
            if store.showToast {
                Text(store.toastMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(8)
                    .shadow(radius: 4)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: store.showToast)
            }
        }
        .onChange(of: store.showDualViewer) { _, show in
            if show {
                openDualViewer()
            } else {
                dualWindow?.close()
                dualWindow = nil
            }
        }
        .onAppear {
            setupMouseSideButtonMonitor()
            setupCacheSweeperActivityMonitor()
            setupVisualSearchCropObserver()
            #if DEBUG
            scheduleDebugRecursivePathOpenIfRequested()
            startDebugStressDriverIfRequested()
            #endif
        }
        .onDisappear {
            teardownMouseSideButtonMonitor()
            teardownCacheSweeperActivityMonitor()
            teardownVisualSearchCropObserver()
        }
    }

    @State private var visualSearchCropObserver: NSObjectProtocol?

    #if DEBUG
    private func scheduleDebugRecursivePathOpenIfRequested() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            openDebugRecursivePathIfRequested()
        }
    }

    private func openDebugRecursivePathIfRequested() {
        guard !debugOpenedEnvPath else { return }
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PICKSHOT_DEBUG_OPEN_RECURSIVE_PATH"], !path.isEmpty else { return }
        debugOpenedEnvPath = true
        let url = URL(fileURLWithPath: path)
        store.startupMode = .viewer
        store.loadPhotosRecursive(from: url)
        fputs("[DEBUG-OPEN] recursive path=\(path)\n", stderr)
    }

    private func startDebugStressDriverIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["PICKSHOT_STRESS_DRIVER"] == "1" else { return }
        guard !debugStressStarted else { return }

        let selectableCount = store.photoCount
        guard selectableCount > 0 else {
            debugStressStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                debugStressStarted = false
                startDebugStressDriverIfRequested()
            }
            return
        }

        debugStressStarted = true

        let pattern = env["PICKSHOT_STRESS_PATTERN"] ?? "mixed"
        let intervalMs = max(5, min(200, Int(env["PICKSHOT_STRESS_INTERVAL_MS"] ?? "") ?? 10))
        let durationSec = max(5, min(1800, Int(env["PICKSHOT_STRESS_DURATION_SEC"] ?? "") ?? 120))
        let layout = env["PICKSHOT_STRESS_LAYOUT"] ?? "grid"

        if layout == "filmstrip" {
            store.setLayoutMode(.filmstrip)
            store.showFolderBrowser = false
        } else {
            store.setLayoutMode(.gridPreview)
            store.showFolderBrowser = true
        }

        let start = Date()
        var step = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + 0.3, repeating: .milliseconds(intervalMs), leeway: .milliseconds(1))
        timer.setEventHandler {
            DispatchQueue.main.async {
                let elapsed = Date().timeIntervalSince(start)
                if elapsed >= Double(durationSec) {
                    timer.cancel()
                    return
                }
                guard !store.isLoading,
                      !store.isRecursiveScanInProgress,
                      !store.filteredPhotos.isEmpty else { return }

                store.isKeyRepeat = true
                switch pattern {
                case "right":
                    store.selectRight()
                case "row":
                    store.selectDown()
                case "diagonal":
                    (step % 2 == 0) ? store.selectRight() : store.selectDown()
                case "zigzag":
                    let phase = step % 120
                    if phase < 45 { store.selectRight() }
                    else if phase < 60 { store.selectDown() }
                    else if phase < 105 { store.selectLeft() }
                    else { store.selectDown() }
                default:
                    let phase = step % 20
                    if phase < 12 { store.selectRight() }
                    else if phase < 15 { store.selectDown() }
                    else if phase < 18 { store.selectLeft() }
                    else { store.selectUp() }
                }
                step += 1

                let logEvery = max(1, 1000 / intervalMs)
                if step % logEvery == 0 {
                    let rss = Int(PhotoStore.currentAppMemoryMB())
                    let selectedName = store.selectedPhoto?.fileName ?? "-"
                    fputs("[DEBUG-STRESS] layout=\(layout) pattern=\(pattern) step=\(step) elapsed=\(Int(elapsed))s rss=\(rss)MB selected=\(selectedName)\n", stderr)
                }
            }
        }
        timer.setCancelHandler {
            DispatchQueue.main.async {
                store.isKeyRepeat = false
                if let id = store.selectedPhotoID {
                    store.scheduleSelectionIdleWork(for: id, delay: 0.05)
                }
                debugStressTimer = nil
                let rss = Int(PhotoStore.currentAppMemoryMB())
                fputs("[DEBUG-STRESS] done layout=\(layout) pattern=\(pattern) steps=\(step) rss=\(rss)MB\n", stderr)
            }
        }
        debugStressTimer = timer
        timer.resume()
        fputs("[DEBUG-STRESS] start layout=\(layout) pattern=\(pattern) interval=\(intervalMs)ms duration=\(durationSec)s photos=\(selectableCount)\n", stderr)
    }
    #endif

    private func setupVisualSearchCropObserver() {
        if visualSearchCropObserver != nil { return }
        visualSearchCropObserver = NotificationCenter.default.addObserver(
            forName: .pickShotOpenVisualSearchCrop,
            object: nil,
            queue: .main
        ) { _ in openVisualSearchCropWindow() }
    }
    private func teardownVisualSearchCropObserver() {
        if let o = visualSearchCropObserver { NotificationCenter.default.removeObserver(o) }
        visualSearchCropObserver = nil
    }

    // MARK: - v8.7 Visual Search Crop Window 열기 (비모달, 멀티 인스턴스)
    private func openVisualSearchCropWindow() {
        guard let url = store.visualSearchCropURL else { return }
        store.showVisualSearchCrop = false  // flag 재사용 가능하게 초기화

        let folderPhotos = store.photos.compactMap { p -> URL? in
            guard !p.isFolder, !p.isParentFolder else { return nil }
            return p.jpgURL
        }

        VisualSearchCropWindowController.shared.present(
            sourceURL: url,
            mode: store.visualSearchCropMode,
            presetLabel: store.visualSearchPresetLabel,
            folderPhotos: folderPhotos
        ) { mode, shots, label in
            let group = DispatchGroup()
            var successCount = 0
            for shot in shots {
                group.enter()
                VisualSearchService.shared.addReference(
                    mode: mode,
                    sourceURL: shot.url,
                    cropRect: shot.rect,
                    label: label
                ) { ok in
                    if ok { successCount += 1 }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if successCount > 0 {
                    store.visualSearchActive = true
                    store.showToastMessage("🔍 \(successCount)장 등록 완료 — 검색 시작")
                    let urls = store.photos.compactMap { p -> URL? in
                        guard !p.isFolder, !p.isParentFolder else { return nil }
                        return p.jpgURL
                    }
                    VisualSearchService.shared.runSearch(on: urls)
                } else {
                    store.showToastMessage("⚠️ 임베딩 계산 실패 — 얼굴이 감지되지 않았을 수 있습니다")
                    }
                }
            }
        }

    // MARK: - v8.6.2: CacheSweeper 활동 감지 (스크롤 + 키)
    @State private var sweeperActivityMonitor: Any?

    private func setupCacheSweeperActivityMonitor() {
        if sweeperActivityMonitor != nil { return }
        sweeperActivityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .keyDown, .leftMouseDown]
        ) { event in
            CacheSweeper.shared.notifyActivity()
            return event  // 이벤트 소비 금지 (UI 에 그대로 전달)
        }
    }

    private func teardownCacheSweeperActivityMonitor() {
        if let m = sweeperActivityMonitor {
            NSEvent.removeMonitor(m)
            sweeperActivityMonitor = nil
        }
        CacheSweeper.shared.cancel()
    }

    /// 마우스 사이드 버튼 (뒤로=3, 앞으로=4) → 폴더 이력 네비게이션
    private func setupMouseSideButtonMonitor() {
        if mouseSideButtonMonitor != nil { return }
        mouseSideButtonMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            switch event.buttonNumber {
            case 3:
                // 뒤로가기
                DispatchQueue.main.async { store.navigateBack() }
                return nil
            case 4:
                // 앞으로가기
                DispatchQueue.main.async { store.navigateForward() }
                return nil
            default:
                return event
            }
        }
    }

    private func teardownMouseSideButtonMonitor() {
        if let m = mouseSideButtonMonitor {
            NSEvent.removeMonitor(m)
            mouseSideButtonMonitor = nil
        }
    }

    /// 왼쪽 패널 폭에서 그리드 열 수 계산 (방향키 행 이동용)
    private func updateGridColumns(width: CGFloat) {
        let size = store.thumbnailSize
        let spacing: CGFloat = 12
        let cellWidth = size + spacing
        let cols = max(1, Int((width + spacing) / cellWidth))
        if store.actualColumnsPerRow != cols {
            store.actualColumnsPerRow = cols
        }
    }

    // MARK: - 테스터 키 단축키 처리

    /// Cmd+Shift+Option+K 를 로컬 이벤트로 감시해 키 입력 시트를 연다. (메뉴/어디에도 노출 안됨)
    private func installTesterKeyMonitor() {
        guard testerKeyMonitor == nil else { return }
        testerKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let masked = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Cmd+Shift+Option+K (keyCode 40) — 테스터 키 시트
            let fullMod: NSEvent.ModifierFlags = [.command, .shift, .option]
            if masked.contains(fullMod) && event.keyCode == 40 {
                DispatchQueue.main.async {
                    if TesterKeyService.isActive() {
                        let days = TesterKeyService.daysRemaining()
                        testerKeyAlertSuccess = true
                        testerKeyAlertMessage = "이 기기는 이미 테스터 키로 활성화되어 있습니다.\n남은 기간: \(days)일"
                    } else {
                        testerKeyAlertMessage = nil
                        testerKeyAlertSuccess = false
                    }
                    showTesterKeySheet = true
                }
                return nil
            }
            // Cmd+Shift+D (keyCode 2) — Navigation Performance HUD 토글
            #if DEBUG
            let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
            if masked == cmdShift && event.keyCode == 2 {
                DispatchQueue.main.async {
                    NavigationPerformanceMonitor.shared.isEnabled.toggle()
                }
                return nil
            }
            // v8.6.1: Cmd+Shift+Option+M (keyCode 46) — Memory Leak Tracker HUD 토글
            if masked.contains(fullMod) && event.keyCode == 46 {
                DispatchQueue.main.async {
                    let tracker = MemoryLeakTracker.shared
                    if tracker.isTracking { tracker.stop() } else { tracker.start() }
                }
                return nil
            }
            // v8.9.3 alt: Cmd+Ctrl+M (keyCode 46) — 메뉴 충돌 회피용 보조 단축키
            let cmdCtrl: NSEvent.ModifierFlags = [.command, .control]
            if masked == cmdCtrl && event.keyCode == 46 {
                DispatchQueue.main.async {
                    let tracker = MemoryLeakTracker.shared
                    if tracker.isTracking { tracker.stop() } else { tracker.start() }
                }
                return nil
            }
            #endif
            return event
        }
    }

    private func removeTesterKeyMonitor() {
        if let m = testerKeyMonitor {
            NSEvent.removeMonitor(m)
            testerKeyMonitor = nil
        }
    }

    private func applyTesterKeyResult(_ result: TesterKeyService.ActivationResult) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        switch result {
        case .success(let expiry):
            testerKeyAlertSuccess = true
            testerKeyAlertMessage = "✅ 활성화되었습니다.\n\(formatter.string(from: expiry)) 까지 사용 가능"
            testerKeyInput = ""
        case .invalid:
            testerKeyAlertSuccess = false
            testerKeyAlertMessage = "❌ 유효하지 않은 키입니다."
        case .revoked:
            testerKeyAlertSuccess = false
            testerKeyAlertMessage = "❌ 이 키는 무효화되었습니다."
        case .alreadyActivated(let expiry):
            testerKeyAlertSuccess = true
            testerKeyAlertMessage = "이미 이 기기에서 동일한 키로 활성화됨.\n\(formatter.string(from: expiry)) 까지 사용 가능"
        case .deviceAlreadyHasKey:
            testerKeyAlertSuccess = false
            testerKeyAlertMessage = "❌ 이 기기는 이미 다른 테스터 키로 활성화되어 있습니다."
        }
    }

    private func openDualViewer() {
        guard dualWindow == nil else { return }
        let dualView = DualViewerContent()
            .environmentObject(store)
        let hostingController = NSHostingController(rootView: dualView)
        guard let screen = NSScreen.screens.count > 1 ? NSScreen.screens[1] : NSScreen.main else { return }
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = "PickShot 뷰어"
        window.backgroundColor = .black
        window.setFrame(CGRect(x: screen.frame.midX - 600, y: screen.frame.midY - 400, width: 1200, height: 800), display: true)
        window.makeKeyAndOrderFront(nil)
        // 윈도우 닫힘 감지
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [self] _ in
            self.store.showDualViewer = false
            self.dualWindow = nil
        }
        dualWindow = window
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - 테스터 키 입력 시트

struct TesterKeyInputSheet: View {
    @Binding var input: String
    @Binding var message: String?
    @Binding var isSuccess: Bool
    var onSubmit: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.orange)
                Text("테스터 키 활성화")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }

            Text("출시 전 테스터 전용 키입니다. 활성화 시 1년 동안 PickShot Pro 를 무료로 사용할 수 있습니다.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("PS-XXXX-XXXX-XXXX", text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit(onSubmit)
                .disableAutocorrection(true)

            if let msg = message {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(isSuccess ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("닫기") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("활성화") { onSubmit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
