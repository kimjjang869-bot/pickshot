import SwiftUI
import Quartz

struct ContentView: View {
    @EnvironmentObject var store: PhotoStore
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var memoryCardService = MemoryCardBackupService.shared
    @State private var folderBrowserExpanded: Bool = false
    @State private var folderBrowserWidth: CGFloat = 250
    @State private var showFullscreen: Bool = false
    @State private var dualWindow: NSWindow?

    // G Select state (used by toolbar extension)
    @ObservedObject var gSelect = GSelectService.shared
    @ObservedObject private var clientSelect = ClientSelectService.shared
    @State var linkCopied = false
    @State var showGSelectQR = false

    private var folderSizeText: String { store.cachedFolderSizeText }

    private var importResultMessage: String {
        guard let r = store.lastImportResult else { return "가져오기 실패" }
        var msg = "매칭 성공: \(r.matched.count)장"
        let spCount = r.matched.filter { $0.spacePick }.count
        if spCount > 0 { msg += "\nSP 셀렉: \(spCount)장" }
        if !r.unmatched.isEmpty {
            msg += "\n\n미매칭: \(r.unmatched.count)장"
            msg += "\n\(r.unmatched.prefix(5).joined(separator: ", "))"
        }
        return msg
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.startupMode == .tethering {
                // Tethering mode - Coming Soon placeholder
                VStack(spacing: 16) {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("테더링").font(.title2.bold())
                    Text("카메라 연결 · 실시간 촬영").foregroundColor(.secondary)
                    Text("Coming Soon").font(.caption).foregroundColor(.orange)
                    Button("돌아가기") { store.startupMode = nil }
                        .buttonStyle(.borderedProminent)
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
                            .frame(width: folderBrowserExpanded ? min(folderBrowserWidth, 280) : 36)
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
                                            let newWidth = folderBrowserWidth + value.translation.width
                                            folderBrowserWidth = max(120, min(400, newWidth))
                                        }
                                )
                                .onHover { inside in
                                    if inside { NSCursor.resizeLeftRight.push() }
                                    else { NSCursor.pop() }
                                }
                        }

                        Divider()
                    }

                    // Main content area
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
                                    .overlay(
                                        photo.isSpacePicked ?
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.red, lineWidth: 4)
                                            .allowsHitTesting(false)
                                        : nil
                                    )
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
                            let leftW = max(150, min(geo.size.width * store.hSplitRatio, geo.size.width * 0.55))
                            let previewH = max(150, min(geo.size.height * store.vSplitRatio, geo.size.height - 120))
                            HStack(spacing: 0) {
                                // Left panel
                                VStack(spacing: 0) {
                                    ThumbnailGridView()

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

                                            let spCount = store.spacePickCount
                                            if spCount > 0 {
                                                Text("·").foregroundColor(AppTheme.textDim)
                                                Text("SP: \(spCount)장")
                                                    .foregroundColor(.red)
                                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            }

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
                                                let currentW = geo.size.width * store.hSplitRatio
                                                let newW = currentW + value.translation.width
                                                let newRatio = newW / geo.size.width
                                                let clamped = max(0.10, min(newRatio, 0.55))
                                                if abs(clamped - store.hSplitRatio) >= 0.003 {
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
                                        // 단일 선택 — 기존 미리보기
                                        PhotoPreviewView(photo: photo)
                                            .overlay(
                                                photo.isSpacePicked ?
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(Color.red, lineWidth: 4)
                                                    .allowsHitTesting(false)
                                                : nil
                                            )
                                            .frame(height: previewH)

                                        // Vertical divider handle
                                        DragHandle(axis: .vertical)
                                            .gesture(
                                                DragGesture()
                                                    .onChanged { value in
                                                        let currentH = geo.size.height * store.vSplitRatio
                                                        let newH = currentH + value.translation.height
                                                        let newRatio = newH / geo.size.height
                                                        store.vSplitRatio = max(0.20, min(newRatio, 0.90))
                                                    }
                                            )

                                        // Metadata
                                        ScrollView {
                                            VStack(spacing: 12) {
                                                ExifInfoView(photo: photo)
                                                // AIAnalysisView — 아직 구현 전, 숨김
                                            }
                                            .padding()
                                        }
                                    } else {
                                        Text("사진을 선택하세요")
                                            .font(.title3)
                                            .foregroundColor(.secondary)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                            }
                            .onAppear { updateGridColumns(width: leftW) }
                            .onChange(of: leftW) { newW in updateGridColumns(width: newW) }
                            .onChange(of: store.thumbnailSize) { _ in updateGridColumns(width: leftW) }
                        }
                    }
                }
            }

            // Bottom: Analysis progress bar
            if store.isAnalyzing {
                AnalysisProgressBar(progress: store.analyzeProgress, total: store.photos.count, onStop: { store.stopAnalysis() })
            }
        }
        .sheet(isPresented: $store.showBatchRename) { BatchRenameView() }
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
        .sheet(isPresented: $memoryCardService.showBackupPrompt) { MemoryCardBackupPromptView() }
        .sheet(isPresented: $memoryCardService.showBackupResult) { MemoryCardBackupResultView() }
        .sheet(isPresented: $store.showCustomPrompt) { CustomPromptView(store: store) }
        .sheet(isPresented: $clientSelect.showSetup) { ClientSelectSetupView() }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                // 메모리카드 백업 진행률
                ForEach(memoryCardService.sessions.filter { !$0.isComplete }) { session in
                    BackupProgressBar(session: session, service: memoryCardService)
                }
                // 백그라운드 내보내기 진행률
                if store.bgExportActive {
                    ExportProgressBar(store: store)
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
        .onChange(of: store.showDualViewer) { show in
            if show {
                openDualViewer()
            } else {
                dualWindow?.close()
                dualWindow = nil
            }
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

// MARK: - Multi Preview Grid (Adobe Bridge 스타일)

struct MultiPreviewGrid: View {
    @ObservedObject var store: PhotoStore
    private let maxDisplay = 9

    var body: some View {
        let totalCount = store.selectionCount
        // 최대 9장만 실제 로딩 (2000장 전체를 배열로 안 만듬)
        let allPhotos = store.multiSelectedPhotosLimited(maxDisplay)
        let overflow = totalCount > maxDisplay
        let displayPhotos = overflow ? Array(allPhotos.prefix(maxDisplay - 1)) : allPhotos
        let remainCount = totalCount - displayPhotos.count
        let displayCount = displayPhotos.count + (overflow ? 1 : 0)

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cols = optimalCols(count: displayCount, width: w, height: h)
            let rows = (displayCount + cols - 1) / cols
            let spacing: CGFloat = 3
            let cellW = (w - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let cellH = (h - spacing * CGFloat(rows - 1)) / CGFloat(rows)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellW), spacing: spacing), count: cols), spacing: spacing) {
                ForEach(displayPhotos) { photo in
                    MultiPreviewCell(photo: photo, store: store, cellW: cellW, cellH: cellH)
                        .frame(width: cellW, height: cellH)
                }
                // 초과 시 마지막 칸에 "+N장" 표시
                if overflow {
                    ZStack {
                        store.previewBackgroundColor
                        // 마지막 사진 블러 배경
                        if let lastPhoto = allPhotos.last,
                           let thumb = ThumbnailCache.shared.get(lastPhoto.jpgURL) {
                            Image(nsImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .blur(radius: 8)
                                .clipped()
                        }
                        Color.black.opacity(0.6)
                        Text("+\(remainCount)장")
                            .font(.system(size: min(cellW, cellH) * 0.2, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: cellW, height: cellH)
                    .clipped()
                }
            }
        }
    }

    private func optimalCols(count: Int, width: CGFloat, height: CGFloat) -> Int {
        let aspect: CGFloat = 3.0 / 2.0
        for cols in 1...3 {
            let rows = (count + cols - 1) / cols
            let cellW = width / CGFloat(cols)
            let cellH = height / CGFloat(rows)
            if cellW / cellH <= aspect * 1.5 { return cols }
        }
        return 3
    }
}

struct MultiPreviewCell: View {
    let photo: PhotoItem
    @ObservedObject var store: PhotoStore
    let cellW: CGFloat
    let cellH: CGFloat
    @State private var hiResImage: NSImage?

    var body: some View {
        ZStack {
            store.previewBackgroundColor

            if let hi = hiResImage {
                Image(nsImage: hi)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let thumb = ThumbnailCache.shared.get(photo.jpgURL) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().scaleEffect(0.5)
            }

            // SP
            if photo.isSpacePicked {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.red, lineWidth: 3)
            }

            // 파일명 + 별점
            VStack {
                if photo.rating > 0 {
                    HStack {
                        Spacer()
                        HStack(spacing: 1) {
                            ForEach(1...photo.rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.system(size: 7))
                                    .foregroundColor(AppTheme.starGold)
                            }
                        }
                        .padding(2)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(2)
                        .padding(3)
                    }
                }
                Spacer()
                Text(photo.fileName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(2)
                    .padding(.bottom, 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onTapGesture {
            store.selectPhoto(photo.id, cmdKey: false)
        }
        .onAppear {
            // 고화질 로딩 (선명하게)
            loadHiRes()
        }
    }

    private func loadHiRes() {
        let url = photo.jpgURL
        // PreviewImageCache에 있으면 즉시
        let cacheKey = url.appendingPathExtension("orig")
        if let cached = PreviewImageCache.shared.get(cacheKey) {
            hiResImage = cached
            return
        }
        // 백그라운드 로딩
        DispatchQueue.global(qos: .userInitiated).async {
            let img = PreviewImageCache.loadOptimized(url: url, maxPixel: 800)
            DispatchQueue.main.async {
                hiResImage = img
            }
        }
    }
}

// MARK: - Dual Viewer Content

struct DualViewerContent: View {
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let photo = store.selectedPhoto, !photo.isFolder, !photo.isParentFolder {
                PhotoPreviewView(photo: photo)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "display.2").font(.system(size: 48)).foregroundColor(.gray)
                    Text("메인 뷰어에서 사진을 선택하세요").font(.system(size: 16)).foregroundColor(.gray)
                }
            }
        }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - 백업 진행률 바

struct BackupProgressBar: View {
    @ObservedObject var session: BackupSession
    let service: MemoryCardBackupService

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576)
        }
    }
    @State private var dragOffset: CGSize = .zero
    @State private var position: CGPoint = .zero

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sdcard.fill")
                .font(.system(size: 16))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(session.volumeName) 백업 중...")
                        .font(.system(size: 12, weight: .semibold))
                    Text(formatBytes(session.totalBytes))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(session.done)/\(session.total)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                ProgressView(value: Double(session.done), total: max(Double(session.total), 1))
                    .progressViewStyle(.linear)

                HStack {
                    Text(session.speed)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    if session.eta.isEmpty {
                        Text("준비 중...")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else {
                        Text("남은 시간: \(session.eta)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Button(action: { service.cancelSession(session) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("백업 취소")
        }
        .padding(12)
        .frame(width: 400)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 5)
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    position.x += value.translation.width
                    position.y += value.translation.height
                    dragOffset = .zero
                }
        )
        .offset(x: position.x, y: position.y)
    }
}

// MARK: - 내보내기 진행률 바

struct ExportProgressBar: View {
    @ObservedObject var store: PhotoStore
    @State private var dragOffset: CGSize = .zero
    @State private var position: CGPoint = .zero

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.fill")
                .font(.system(size: 16))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(store.bgExportLabel)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(store.bgExportDone)/\(store.bgExportTotal)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 80, alignment: .trailing)
                }

                ProgressView(value: store.bgExportProgress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }

            Button(action: { store.bgExportCancelled = true }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("내보내기 취소")
        }
        .padding(12)
        .frame(width: 400)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 5)
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    position.x += value.translation.width
                    position.y += value.translation.height
                    dragOffset = .zero
                }
        )
        .offset(x: position.x, y: position.y)
    }
}

// MARK: - AI 분류 진행률 바

// MARK: - 파일 이동 진행률 바

// MARK: - 클라이언트 셀렉 업로드 진행률 바

struct ClientUploadProgressBar: View {
    @ObservedObject var service: ClientSelectService
    @State private var dragOffset: CGSize = .zero
    @State private var position: CGPoint = .zero
    @State private var linkCopied = false

    var body: some View {
        let done = service.uploadDone
        let total = service.uploadTotal
        let progress = total > 0 ? Double(done) / Double(total) : 0
        let isComplete = !service.isUploading && service.viewerLink != nil

        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "icloud.and.arrow.up.fill")
                    .font(.system(size: 16))
                    .foregroundColor(isComplete ? .green : .purple)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(isComplete ? "업로드 완료!" : "클라이언트 셀렉 업로드 중...")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(done)/\(total)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if !isComplete {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.purple)
                    }
                    if !service.uploadSpeed.isEmpty && !isComplete {
                        Text(service.uploadSpeed)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                if !isComplete {
                    Button(action: { service.cancelUpload() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { service.showSetup = true }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("상세 보기")
            }

            // 완료 후 링크/QR 표시
            if isComplete, let link = service.viewerLink {
                HStack(spacing: 8) {
                    Text(link)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        linkCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { linkCopied = false }
                    }) {
                        Text(linkCopied ? "복사됨!" : "링크 복사")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let url = URL(string: link) {
                        Button(action: { NSWorkspace.shared.open(url) }) {
                            Image(systemName: "safari")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help("브라우저에서 열기")
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 450)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 5)
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    position.x += value.translation.width
                    position.y += value.translation.height
                    dragOffset = .zero
                }
        )
        .offset(x: position.x, y: position.y)
    }
}

struct FileMoveProgressBar: View {
    @ObservedObject var store: PhotoStore

    var body: some View {
        let done = store.fileMoveDone
        let total = store.fileMoveTotal
        let progress = total > 0 ? Double(done) / Double(total) : 0

        HStack(spacing: 12) {
            Image(systemName: "folder.badge.arrow.forward")
                .font(.system(size: 16))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(store.fileMoveLabel) 중...")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(done)/\(total)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }
        }
        .padding(12)
        .frame(width: 350)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 5)
    }
}

struct AIClassifyProgressBar: View {
    @ObservedObject var store: PhotoStore
    @State private var dragOffset: CGSize = .zero
    @State private var position: CGPoint = .zero
    @State private var startTime = CFAbsoluteTimeGetCurrent()

    var body: some View {
        let (done, total) = store.aiClassifyProgress
        let progress = total > 0 ? Double(done) / Double(total) : 0
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let eta: String = {
            guard done > 0, elapsed > 1 else { return "계산 중..." }
            let rate = Double(done) / elapsed
            let remaining = Double(total - done) / rate
            if remaining < 60 { return "\(Int(remaining))초 남음" }
            return "\(Int(remaining / 60))분 \(Int(remaining) % 60)초 남음"
        }()
        let cost = Double(done) * (ClaudeVisionService.model.contains("haiku") ? 0.00025 : 0.003)

        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundColor(.purple)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("AI 분류 중...")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    // 에러 카운트 표시
                    if !store.aiClassifyErrors.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.red)
                            Text("\(store.aiClassifyErrors.count) 실패")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.red)
                        }
                        .help(store.aiClassifyErrors.last.map { "\($0.0): \($0.1)" } ?? "")
                    }
                    Text("\(done)/\(total)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 80, alignment: .trailing)
                }

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.purple)

                HStack {
                    Text("$\(String(format: "%.3f", cost))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                    Spacer()
                    Text(eta)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Button(action: {
                store.isAIClassifying = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("분류 취소")
        }
        .padding(12)
        .frame(width: 400)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 5)
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    position.x += value.translation.width
                    position.y += value.translation.height
                    dragOffset = .zero
                }
        )
        .offset(x: position.x, y: position.y)
        .onAppear { startTime = CFAbsoluteTimeGetCurrent() }
    }
}

// MARK: - Vision 로컬 분석 진행 패널

struct VisionAnalysisProgressPanel: View {
    @ObservedObject var store: PhotoStore
    @ObservedObject var cullService = SmartCullService.shared

    /// 활성 작업 수
    private var activeCount: Int {
        (store.isClassifyingScenes ? 1 : 0) +
        (store.isGroupingFaces ? 1 : 0) +
        (cullService.isProcessing ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 14))
                    .foregroundColor(.cyan)
                    .symbolEffect(.pulse, isActive: true)
                Text("Vision 분석")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("\(activeCount)개 작업")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))

            Divider()

            VStack(spacing: 6) {
                // 장면 분류
                if store.isClassifyingScenes {
                    analysisRow(
                        icon: "eye.fill",
                        title: "장면 분류",
                        color: .blue,
                        done: store.classifyDoneCount,
                        total: store.classifyTotalCount,
                        progress: store.classifyProgress,
                        message: store.classifyStatusMessage,
                        startTime: store.classifyStartTime
                    )
                }

                // 얼굴 그룹핑
                if store.isGroupingFaces {
                    analysisRow(
                        icon: "person.crop.rectangle.stack",
                        title: "얼굴 그룹",
                        color: .orange,
                        done: store.faceGroupDoneCount,
                        total: store.faceGroupTotalCount,
                        progress: store.faceGroupProgress,
                        message: store.faceGroupStatusMessage,
                        startTime: store.faceGroupStartTime
                    )
                }

                // SmartCull
                if cullService.isProcessing {
                    analysisRow(
                        icon: "sparkles",
                        title: "스마트 셀렉",
                        color: .purple,
                        done: Int(cullService.progress * 100),
                        total: 100,
                        progress: cullService.progress,
                        message: cullService.statusMessage,
                        startTime: 0 // SmartCull은 자체 ETA 표시
                    )
                }
            }
            .padding(10)
        }
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    private func analysisRow(
        icon: String, title: String, color: Color,
        done: Int, total: Int, progress: Double,
        message: String, startTime: CFAbsoluteTime
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))

                Spacer()

                // 처리량 카운터
                Text("\(done)/\(total)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // 진행바
            ProgressView(value: min(progress, 1.0))
                .progressViewStyle(.linear)
                .tint(color)

            // 상세 메시지
            HStack {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                // 경과 시간
                if startTime > 0 {
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    Text(elapsed < 60 ? "\(Int(elapsed))초" : "\(Int(elapsed/60)):\(String(format: "%02d", Int(elapsed) % 60))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                // 퍼센트
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
        }
        .padding(8)
        .background(color.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - 커스텀 프롬프트 입력

struct CustomPromptView: View {
    @ObservedObject var store: PhotoStore
    @State private var promptText: String = ""
    @State private var selectedPreset: Int = -1
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI 분류 커스텀 프롬프트")
                .font(.headline)

            Text("사진을 어떻게 분류할지 자유롭게 작성하세요")
                .font(.caption)
                .foregroundColor(.secondary)

            // 프리셋 버튼
            HStack(spacing: 6) {
                Text("프리셋:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(Array(ClaudeVisionService.classifyPresets.enumerated()), id: \.offset) { idx, preset in
                    Button(preset.name) {
                        promptText = preset.prompt
                        selectedPreset = idx
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(selectedPreset == idx ? .accentColor : .secondary)
                }
            }

            // 프롬프트 입력
            TextEditor(text: $promptText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 200)
                .border(Color.gray.opacity(0.3))
                .onChange(of: promptText) { _ in selectedPreset = -1 }

            Text("⚠️ JSON 출력 형식을 포함해야 결과가 정상적으로 파싱됩니다")
                .font(.system(size: 10))
                .foregroundColor(.orange)

            HStack {
                Button("취소") { dismiss() }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    let count = store.filteredPhotos.count
                    let engine = UserDefaults.standard.string(forKey: "aiClassifyEngine") ?? "claudeHaiku"
                    let modelName: String = {
                        switch engine {
                        case "claudeHaiku": return "Haiku"
                        case "claudeSonnet": return "Sonnet"
                        case "geminiFlash": return "Gemini Flash"
                        case "geminiPro": return "Gemini Pro"
                        default: return engine
                        }
                    }()
                    Text("\(count)장 · \(modelName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    let costPerPhoto: Double = {
                        switch engine {
                        case "claudeHaiku": return 0.00025
                        case "claudeSonnet": return 0.003
                        case "geminiFlash": return 0.00008
                        case "geminiPro": return 0.00125
                        default: return 0.00025
                        }
                    }()
                    let cost = Double(count) * costPerPhoto
                    let batchSize: Double = {
                        switch engine {
                        case "claudeHaiku": return 5
                        case "claudeSonnet": return 3
                        case "geminiFlash": return 3
                        case "geminiPro": return 1
                        default: return 3
                        }
                    }()
                    let secPerPhoto: Double = engine.contains("Flash") || engine.contains("Haiku") ? 1.0 : 2.0
                    let seconds = Double(count) / batchSize * secPerPhoto
                    let minutes = Int(seconds / 60)
                    let secs = Int(seconds) % 60
                    Text("예상: $\(String(format: "%.2f", cost)) · \(minutes > 0 ? "\(minutes)분 " : "")\(secs)초")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
                Button("분류 실행") {
                    store.runAIClassification(customPrompt: promptText)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 450)
        .onAppear {
            promptText = ClaudeVisionService.defaultClassifyPrompt
            selectedPreset = 0
        }
    }
}

