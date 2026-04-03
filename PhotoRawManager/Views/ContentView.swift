import SwiftUI
import Quartz

struct ContentView: View {
    @EnvironmentObject var store: PhotoStore
    @ObservedObject private var updateService = UpdateService.shared
    @State private var folderBrowserExpanded: Bool = false
    @State private var folderBrowserWidth: CGFloat = 250
    @State private var showFullscreen: Bool = false

    // G Select state (used by toolbar extension)
    @ObservedObject var gSelect = GSelectService.shared
    @State var linkCopied = false
    @State var showGSelectQR = false

    private func openFullscreenWindow() {
        let fullscreenView = FullscreenView(isPresented: $showFullscreen)
            .environmentObject(store)
        let hostingController = NSHostingController(rootView: fullscreenView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.setFrame(NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900), display: true)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    private var folderSizeText: String {
        guard !store.photos.isEmpty else { return "" }
        let totalBytes = store.photos.reduce(Int64(0)) { sum, photo in
            guard !photo.isFolder && !photo.isParentFolder else { return sum }
            return sum + photo.jpgFileSize + photo.rawFileSize
        }
        if totalBytes <= 0 {
            // Estimate from photo count
            return "\(store.photos.filter { !$0.isFolder }.count)장"
        }
        if totalBytes > 1_073_741_824 {
            return String(format: "%.1f GB", Double(totalBytes) / 1_073_741_824)
        } else if totalBytes > 1_048_576 {
            return String(format: "%.0f MB", Double(totalBytes) / 1_048_576)
        } else {
            return String(format: "%.0f KB", Double(totalBytes) / 1024)
        }
    }

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
            } else {
                // Viewer mode - show toolbar + folder browser always, content or empty state
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
                            .frame(width: folderBrowserExpanded ? folderBrowserWidth : 36)
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
                                            folderBrowserWidth = max(180, min(500, newWidth))
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
                                                Slider(value: $store.thumbnailSize, in: 60...250, step: 10)
                                                    .frame(maxWidth: 120)
                                                    .help("썸네일 크기 조절")
                                                Image(systemName: "photo")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(AppTheme.textSecondary)
                                            }
                                        }

                                        Spacer()

                                        // Center: Selection / Total count
                                        HStack(spacing: 6) {
                                            if store.selectionCount > 0 {
                                                Text("선택: \(store.selectionCount)장")
                                                    .foregroundColor(AppTheme.accent)
                                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                Text("/")
                                                    .foregroundColor(AppTheme.textDim)
                                            }
                                            Text("전체: \(store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }.count)장")
                                                .foregroundColor(.yellow)
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        }

                                        Spacer()

                                        // Right: Folder size
                                        HStack(spacing: 4) {
                                            Image(systemName: "internaldrive")
                                                .font(.system(size: 10))
                                            Text(folderSizeText)
                                        }
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(nsColor: .windowBackgroundColor))
                                }
                                .frame(width: store.hSplitPosition)

                                // Horizontal divider handle
                                DragHandle(axis: .horizontal)
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                let newW = store.hSplitPosition + value.translation.width
                                                store.hSplitPosition = max(200, min(newW, geo.size.width - 300))
                                            }
                                    )

                                // Right panel
                                VStack(spacing: 0) {
                                    if let photo = store.selectedPhoto {
                                        // Preview
                                        PhotoPreviewView(photo: photo)
                                            .overlay(
                                                photo.isSpacePicked ?
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(Color.red, lineWidth: 4)
                                                    .allowsHitTesting(false)
                                                : nil
                                            )
                                            .frame(height: store.vSplitPosition)

                                        // Vertical divider handle
                                        DragHandle(axis: .vertical)
                                            .gesture(
                                                DragGesture()
                                                    .onChanged { value in
                                                        let maxH = geo.size.height - 120
                                                        let newH = store.vSplitPosition + value.translation.height
                                                        store.vSplitPosition = max(150, min(newH, maxH))
                                                    }
                                            )

                                        // Metadata + AI
                                        ScrollView {
                                            VStack(spacing: 12) {
                                                ExifInfoView(photo: photo)
                                                AIAnalysisView(photo: photo)
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
        .sheet(isPresented: $store.showExportSheet) { ExportView() }
        .sheet(isPresented: $store.showGoogleDrive) { GoogleDriveUploadView() }
        .sheet(isPresented: $store.showShortcutHelp) { ShortcutHelpView() }
        .sheet(isPresented: $store.showAbout) { AboutView() }
        .alert("셀렉 가져오기 완료", isPresented: $store.showImportResult) {
            Button("확인") {}
        } message: {
            Text(importResultMessage)
        }
        .sheet(isPresented: $gSelect.showSetupSheet) { GSelectSetupView() }
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
        .alert("⚠️ 원본 파일 삭제", isPresented: $store.showDeleteOriginalConfirm) {
            Button("삭제 (휴지통으로 이동)", role: .destructive) {
                store.deleteOriginalFiles(ids: store.pendingDeleteIDs)
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
        .background(KeyEventHandlingView(store: store, onFullscreen: { showFullscreen = true }))
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
        .onChange(of: showFullscreen) { show in
            if show {
                openFullscreenWindow()
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
