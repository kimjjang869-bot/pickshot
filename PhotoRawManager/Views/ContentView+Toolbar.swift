import SwiftUI
import Quartz

// MARK: - Toolbar & Filter Menus

extension ContentView {

    // MARK: - Toolbar

    var toolbar: some View {
        VStack(spacing: 0) {
            // === Row 1: Main actions ===
            HStack(spacing: 8) {
                // Home button - back to startup screen
                Button(action: {
                    store.startupMode = nil
                    store.photos = []
                    store.selectedPhotoID = nil
                    store.selectedPhotoIDs = []
                    store.folderURL = nil
                }) {
                    Image(systemName: "house.fill")
                        .font(.system(size: AppTheme.iconMedium))
                }
                .buttonStyle(.plain)
                .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                .background(AppTheme.toolbarButtonBg)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("시작 화면으로 돌아가기")

                // Folder browser toggle
                Button(action: { store.showFolderBrowser.toggle() }) {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: AppTheme.iconMedium))
                }
                .buttonStyle(.plain)
                .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                .background(store.showFolderBrowser ? Color.accentColor.opacity(0.15) : AppTheme.toolbarButtonBg)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("폴더 브라우저 열기/닫기")

                // Folder path (bold, prominent)
                if let url = store.folderURL {
                    BreadcrumbPathView(url: url, store: store)
                }

                if store.isLoading {
                    ProgressView().scaleEffect(0.7)
                }

                // 하위 폴더 포함 모드 표시 및 해제 버튼
                if store.isRecursiveMode {
                    Button {
                        store.exitRecursiveMode()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 11))
                            Text("하위 폴더 포함")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help("클릭하면 현재 폴더만 표시합니다")
                }

                if store.selectionCount > 1 {
                    SelectionInfoBadge(store: store)
                }

                Spacer()

                // Thumbnail progress — wider bar + ETA
                if store.isPreloadingThumbs {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        let progress = store.thumbsTotal > 0 ? CGFloat(store.thumbsLoaded) / CGFloat(store.thumbsTotal) : 0
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.3)).frame(width: 120, height: 6)
                            RoundedRectangle(cornerRadius: 3).fill(Color.green).frame(width: 120 * progress, height: 6)
                        }
                        Text(String(format: "%03d/%03d", store.thumbsLoaded, store.thumbsTotal))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.green)
                        if !store.thumbsETA.isEmpty {
                            Text(store.thumbsETA)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                    }
                }

                // RAW→JPG conversion progress
                if store.isConverting {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        let progress = store.conversionTotal > 0 ? CGFloat(store.conversionDone) / CGFloat(store.conversionTotal) : 0
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.3)).frame(width: 60, height: 5)
                            RoundedRectangle(cornerRadius: 3).fill(Color.orange).frame(width: 60 * progress, height: 5)
                        }
                        Text("\(store.conversionDone)/\(store.conversionTotal)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.orange)
                        if !store.conversionETA.isEmpty {
                            Text(store.conversionETA)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        Button(action: { store.conversionCancelled = true }) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !store.photos.isEmpty {
                    // G Select button (먼저)
                    gSelectButton

                    // Matching button
                    Button(action: { store.showMatchingSheet = true }) {
                        Label("매칭", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: AppTheme.fontBody, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.purple)
                    .help("파일명/JPG/AI 매칭 셀렉")

                    Button(action: { store.showExportSheet = true }) {
                        Label("내보내기", systemImage: "square.and.arrow.up")
                            .font(.system(size: AppTheme.fontBody, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(AppTheme.warning)
                    .help("선택한 사진 내보내기 (Cmd+E)")

                    Button(action: { store.showBatchProcess = true }) {
                        Label("배치 처리", systemImage: "photo.on.rectangle.angled")
                            .font(.system(size: AppTheme.fontBody, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.teal)
                    .help("리사이즈 + 워터마크 일괄 처리")

                    // Analysis stop button (only visible when analyzing)
                    if store.isAnalyzing {
                        Button(action: { store.stopAnalysis() }) {
                            Label("분석 중지", systemImage: "stop.fill")
                                .font(.system(size: AppTheme.fontBody, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(AppTheme.error)
                        .help("품질 분석 중지")
                    }
                }

                // SubscriptionBadge / APIUsageGauge 숨김
            }
            .fixedSize(horizontal: false, vertical: true)
            // end Row 1
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // === Row 2: Filters ===
            if !store.photos.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    // Sort menu
                    Menu {
                        ForEach(SortMode.allCases, id: \.self) { mode in
                            Button(action: { store.sortMode = mode }) {
                                HStack {
                                    Image(systemName: mode.icon)
                                    Text(mode.rawValue)
                                    if store.sortMode == mode { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        toolbarButton(icon: store.sortMode.icon, text: store.sortMode.rawValue, color: AppTheme.accent, active: false)
                    }
                    .help("정렬 순서 변경 (촬영시간/파일명/별점)")

                    Divider().frame(height: 16).opacity(0.2)

                    // Star filter - pill-shaped buttons
                    HStack(spacing: 2) {
                        ForEach([0, 1, 2, 3, 4, 5], id: \.self) { rating in
                            Button(action: { store.minimumRatingFilter = rating }) {
                                Group {
                                    if rating == 0 {
                                        Text("All")
                                            .font(.system(size: AppTheme.fontCaption, weight: .semibold))
                                    } else {
                                        HStack(spacing: 1) {
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 8))
                                            Text("\(rating)")
                                                .font(.system(size: AppTheme.fontCaption, weight: .semibold))
                                        }
                                    }
                                }
                                .frame(width: AppTheme.pillSize, height: AppTheme.pillSize)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(store.minimumRatingFilter == rating ? .white : (rating == 0 ? .primary : AppTheme.starGold))
                            .background(
                                store.minimumRatingFilter == rating
                                    ? AppTheme.starGold.opacity(0.85)
                                    : AppTheme.toolbarButtonBg
                            )
                            .clipShape(Capsule())
                            .help(rating == 0 ? "모든 별점 표시" : "별점 \(rating) 이상 필터")
                        }
                    }

                    // SP (Space Pick) filter button - pill-shaped
                    Button(action: {
                        store.qualityFilter = store.qualityFilter == .spacePick ? .all : .spacePick
                    }) {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                            Text("SP")
                                .font(.system(size: AppTheme.fontMicro, weight: .black))
                        }
                        .frame(height: AppTheme.pillSize)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .foregroundColor(store.qualityFilter == .spacePick ? .white : AppTheme.error)
                    .background(
                        store.qualityFilter == .spacePick
                            ? AppTheme.error
                            : AppTheme.mutedRed
                    )
                    .clipShape(Capsule())
                    .help("스페이스 셀렉 필터 (Space키로 선택, \(store.spacePickedCount)장)")

                    Divider().frame(height: 16).opacity(0.2)

                    // Search bar
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        TextField("검색", text: $store.searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .frame(width: 80)
                        if !store.searchText.isEmpty {
                            Text("\(store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }.count)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.8))
                                .clipShape(Capsule())
                            Button(action: { store.searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppTheme.toolbarButtonBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    // AI 분류 (품질 + 장면 통합)
                    qualityFilterMenu

                    Spacer(minLength: 0)

                    // Layout mode toggle
                    Button(action: {
                        let newMode: LayoutMode = store.layoutMode == .gridPreview ? .filmstrip : .gridPreview
                        store.setLayoutMode(newMode)
                    }) {
                        toolbarButton(
                            icon: store.layoutMode.icon,
                            text: store.layoutMode == .filmstrip ? "필름스트립" : "그리드",
                            color: .indigo,
                            active: store.layoutMode == .filmstrip
                        )
                    }
                    .buttonStyle(.plain)
                    .help("레이아웃 모드 전환 (그리드+미리보기 / 필름스트립)")

                    // Dual Viewer
                    Button(action: { store.showDualViewer.toggle() }) {
                        Image(systemName: "display.2").font(.system(size: AppTheme.iconSmall))
                    }
                    .buttonStyle(.plain)
                    .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                    .foregroundColor(store.showDualViewer ? .accentColor : .secondary)
                    .background(store.showDualViewer ? AppTheme.accent.opacity(0.15) : AppTheme.toolbarButtonBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help("듀얼 스크린 뷰어 (D)")

                    // Compare button
                    Button(action: {
                        if store.selectionCount >= 2 && store.selectionCount <= 4 {
                            store.showCompare = true
                        } else {
                            DisabledGuide.showCompareDisabled(currentCount: store.selectionCount)
                        }
                    }) {
                        Image(systemName: "square.split.2x1")
                            .font(.system(size: AppTheme.iconSmall))
                            .opacity(store.selectionCount >= 2 && store.selectionCount <= 4 ? 1 : 0.4)
                    }
                    .buttonStyle(.plain)
                    .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                    .background(AppTheme.toolbarButtonBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help("비교 보기 - 2~4장 선택 후 나란히 비교")

                    // Face Compare button
                    Button(action: {
                        if store.selectionCount >= 2 && store.selectionCount <= 6 {
                            store.showFaceCompare = true
                        }
                    }) {
                        Image(systemName: "face.smiling")
                            .font(.system(size: AppTheme.iconSmall))
                            .opacity(store.selectionCount >= 2 && store.selectionCount <= 6 ? 1 : 0.4)
                    }
                    .buttonStyle(.plain)
                    .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                    .background(AppTheme.toolbarButtonBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help("표정 비교 - 2~6장 선택 후 얼굴 비교")

                    // Map button
                    Button(action: { store.showMap = true }) {
                        Image(systemName: "map")
                            .font(.system(size: AppTheme.iconSmall))
                    }
                    .buttonStyle(.plain)
                    .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                    .background(AppTheme.toolbarButtonBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help("GPS 지도 보기")

                    // Slideshow button
                    Button(action: { store.showSlideshow = true }) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: AppTheme.iconSmall))
                    }
                    .buttonStyle(.plain)
                    .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                    .background(AppTheme.toolbarButtonBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help("슬라이드쇼 자동 재생 시작")

                    // Theme toggle button
                    Button(action: { store.isDarkMode.toggle() }) {
                        Image(systemName: store.isDarkMode ? "sun.max" : "moon")
                            .font(.system(size: AppTheme.iconSmall))
                    }
                    .buttonStyle(.plain)
                    .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                    .background(AppTheme.toolbarButtonBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help(store.isDarkMode ? "라이트 모드로 전환" : "다크 모드로 전환")

                    // Help button
                    Button(action: { store.showShortcutHelp = true }) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: AppTheme.iconSmall))
                    }
                    .buttonStyle(.plain)
                    .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                    .background(AppTheme.toolbarButtonBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help("단축키 안내 보기 (Cmd+?)")
                }
                .fixedSize(horizontal: false, vertical: true)
                // end Row 2
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
    }

    // MARK: - Quality Filter Menu

    var qualityFilterMenu: some View {
        let aiCount = store.photos.filter { $0.isAIPick }.count

        return Menu {
            Button(action: { store.qualityFilter = .all }) {
                Label("전체", systemImage: store.qualityFilter == .all ? "checkmark" : "")
            }
            Divider()
            Button(action: { store.qualityFilter = .aiPick }) {
                Label("AI 추천 (\(aiCount)장)", systemImage: "sparkles")
            }
            Button(action: { store.qualityFilter = .goodOnly }) {
                Label("양호 이상", systemImage: "checkmark.circle")
            }
            Button(action: { store.qualityFilter = .issuesOnly }) {
                Label("문제 있음", systemImage: "exclamationmark.triangle")
            }
            Divider()
            Divider()
            Button(action: { store.showAnalysisOptions = true }) {
                Label("PickShot AI 분류 실행...", systemImage: "wand.and.stars")
            }
            Divider()
            // 장면 분류 필터
            let tags = store.availableSceneTags
            if !tags.isEmpty {
                ForEach(tags, id: \.self) { tag in
                    Button(action: { store.sceneTagFilter = store.sceneTagFilter == tag ? nil : tag }) {
                        Label(tag, systemImage: store.sceneTagFilter == tag ? "checkmark" : "")
                    }
                }
                Divider()
            }
            Button(action: { store.classifyScenes() }) {
                Label(store.isClassifyingScenes ? "분류 중..." : "API AI 분류 실행", systemImage: "eye.fill")
            }
            .disabled(store.isClassifyingScenes)
        } label: {
            toolbarButton(
                icon: store.qualityFilter == .aiPick ? "sparkles" : "wand.and.stars",
                text: store.sceneTagFilter != nil ? store.sceneTagFilter! :
                      (store.qualityFilter == .all ? "AI" : store.qualityFilter.rawValue),
                color: .purple,
                active: store.qualityFilter != .all || store.sceneTagFilter != nil
            )
        }
        .help("AI 분류 + 품질 필터")
        .popover(isPresented: $store.showAnalysisOptions) {
            AnalysisOptionsView(store: store)
        }

        if store.isClassifyingScenes || store.isAnalyzing {
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        }
    }

    // MARK: - Face Group Filter Menu

    var faceGroupFilterMenu: some View {
        let groups = store.availableFaceGroups
        let hasGroups = !groups.isEmpty

        return HStack(spacing: 4) {
            Menu {
                Button(action: { store.faceGroupFilter = nil }) {
                    Label("전체", systemImage: store.faceGroupFilter == nil ? "checkmark" : "")
                }
                Divider()
                if hasGroups {
                    ForEach(groups, id: \.self) { gid in
                        Button(action: { store.faceGroupFilter = gid }) {
                            let count = store.faceGroups[gid]?.count ?? 0
                            HStack(spacing: 8) {
                                // Face thumbnail
                                if let faceImg = store.faceThumbnails[gid] {
                                    Image(nsImage: faceImg)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 24, height: 24)
                                        .clipShape(Circle())
                                } else {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.orange)
                                }
                                Text("인물 \(gid + 1)")
                                    .font(.system(size: 12, weight: .medium))
                                Text("\(count)장")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                if store.faceGroupFilter == gid {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } else {
                    Button(action: { store.groupByFaces() }) {
                        Label("얼굴 그룹 실행", systemImage: "person.crop.rectangle.stack")
                    }
                }
                Divider()
                Button(action: { store.groupByFaces() }) {
                    Label(store.isGroupingFaces ? "그룹핑 중..." : "얼굴 그룹", systemImage: "person.crop.rectangle.stack")
                }
                .disabled(store.isGroupingFaces)
            } label: {
                toolbarButton(
                    icon: "person.2.fill",
                    text: store.faceGroupFilter != nil ? "인물 \((store.faceGroupFilter ?? 0) + 1)" : "인물",
                    color: .orange,
                    active: store.faceGroupFilter != nil
                )
            }
            .help("인물 그룹 필터")

            if store.isGroupingFaces {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            }
        }
    }

    // MARK: - G Select Button

    var gSelectButton: some View {
        HStack(spacing: 4) {
            if gSelect.isActive {
                // Active - show status
                Button(action: { gSelect.endSession() }) {
                    HStack(spacing: 4) {
                        // Uploading indicator
                        if gSelect.currentlyUploading != nil {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        } else {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        }
                        Text("G")
                            .font(.system(size: 12, weight: .black))
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 9))

                        // Upload count: selected / uploaded
                        Text("\(gSelect.uploadedCount)/\(gSelect.gSelectedIDs.count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))

                        if gSelect.failedCount > 0 {
                            Text("⚠️\(gSelect.failedCount)")
                                .font(.system(size: 9))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundColor(.white)
                    .background(
                        LinearGradient(colors: [.blue, .green.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("G셀렉: \(gSelect.uploadedCount)/\(gSelect.gSelectedIDs.count)장 업로드 완료 | 클릭하여 종료")

                // Link actions (only when active and link exists)
                if let link = gSelect.shareLink {
                    // Copy link
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        // Brief visual feedback
                        linkCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { linkCopied = false }
                    }) {
                        Image(systemName: linkCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(linkCopied ? .green : .white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
                    .help("공유 링크 복사")

                    // QR Code
                    Button(action: { showGSelectQR = true }) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
                    .help("QR 코드 표시 - 클라이언트 폰으로 스캔")
                    .popover(isPresented: $showGSelectQR) {
                        GSelectQRView(link: link, count: gSelect.gSelectedIDs.count, folderName: gSelect.sessionFolderName, viewerLink: gSelect.viewerLink)
                    }

                    // Share sheet
                    Button(action: {
                        let picker = NSSharingServicePicker(items: [link])
                        if let button = NSApp.keyWindow?.contentView {
                            picker.show(relativeTo: .zero, of: button, preferredEdge: .minY)
                        }
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
                    .help("카카오톡/iMessage/메일로 공유")
                }
            } else {
                // Inactive - start button
                Button(action: {
                    gSelect.requestStartSession()
                }) {
                    HStack(spacing: 3) {
                        Text("G")
                            .font(.system(size: 13, weight: .black))
                            .foregroundColor(.blue)
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("G셀렉 시작 - G키로 사진 선택 시 Google Drive에 즉시 업로드")
            }
        }
    }

    // MARK: - AI Smart Classification Menu

    var aiClassifyMenu: some View {
        let categories = store.availableAICategories
        let hasResults = !categories.isEmpty
        let stats = store.aiUsabilityStats

        return HStack(spacing: 4) {
            Menu {
                Button(action: { store.aiCategoryFilter = nil }) {
                    Label("전체", systemImage: store.aiCategoryFilter == nil ? "checkmark" : "")
                }

                if hasResults {
                    Divider()

                    // Category filters
                    Section("📂 카테고리") {
                        ForEach(categories, id: \.self) { cat in
                            let count = store.photos.filter { $0.aiCategory == cat }.count
                            let icon = aiCategoryIcon(cat)
                            Button(action: { store.aiCategoryFilter = cat }) {
                                Label("\(icon) \(cat) (\(count)장)",
                                      systemImage: store.aiCategoryFilter == cat ? "checkmark" : "")
                            }
                        }
                    }

                    if !stats.isEmpty {
                        Divider()
                        Section("📊 활용도") {
                            ForEach(["즉시사용", "편집후사용", "참고용", "삭제후보"], id: \.self) { level in
                                if let count = stats[level] {
                                    let icon = usabilityIcon(level)
                                    Button(action: {
                                        // Filter by usability via aiCategory filter
                                        // Using special prefix
                                        store.aiCategoryFilter = "__usability__\(level)"
                                    }) {
                                        Label("\(icon) \(level) (\(count)장)", systemImage: "")
                                    }
                                }
                            }
                        }
                    }
                }

                Divider()

                // Run AI classification
                Button(action: {
                    if store.isAIClassifying {
                        DisabledGuide.showAnalysisInProgress()
                    } else if !ClaudeVisionService.hasAPIKey {
                        DisabledGuide.showAIDisabled()
                    } else {
                        store.runAIClassification()
                    }
                }) {
                    Label(store.isAIClassifying ? "분류 중..." : "🤖 AI 스마트 분류 실행",
                          systemImage: "sparkles")
                }
            } label: {
                toolbarButton(
                    icon: "sparkles",
                    text: store.aiCategoryFilter != nil ? (store.aiCategoryFilter?.replacingOccurrences(of: "__usability__", with: "") ?? "AI") : "AI 분류",
                    color: .purple,
                    active: store.aiCategoryFilter != nil
                )
            }
            .help("AI 스마트 분류 필터")

            if store.isAIClassifying {
                let (done, total) = store.aiClassifyProgress
                HStack(spacing: 3) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                    Text("\(done)/\(total)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    func aiCategoryIcon(_ category: String) -> String {
        switch category {
        case "클린샷": return "🏞️"
        case "인물": return "👤"
        case "그룹": return "👥"
        case "군중": return "🎭"
        case "무대": return "🎤"
        case "분위기": return "✨"
        case "디테일": return "🔍"
        case "비하인드": return "🎬"
        case "기념": return "📸"
        default: return "📋"
        }
    }

    func usabilityIcon(_ level: String) -> String {
        switch level {
        case "즉시사용": return "🟢"
        case "편집후사용": return "🟡"
        case "참고용": return "🟠"
        case "삭제후보": return "🔴"
        default: return "⚪"
        }
    }

    // MARK: - Toolbar Button Helper

    func toolbarButton(icon: String, text: String, color: Color, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.iconSmall))
            Text(text)
                .font(.system(size: AppTheme.fontBody, weight: .medium))
        }
        .padding(.horizontal, 8)
        .frame(height: AppTheme.buttonHeight)
        .foregroundColor(active ? .white : color)
        .background(active ? color : AppTheme.toolbarButtonBg)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Drag & Drop

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.hasDirectoryPath else { return }
                DispatchQueue.main.async {
                    store.loadFolder(url)
                }
            }
        }
        return true
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("사진 폴더를 열어주세요")
                .font(.title2)
                .foregroundColor(.secondary)

            Text("JPG 파일로 미리보기하고, 매칭되는 RAW 파일을 함께 관리합니다.\njpg/raw 폴더가 분리되어 있어도 자동으로 매칭됩니다.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("폴더 열기") {
                store.openFolder()
            }
            .controlSize(.large)
            .help("사진 폴더 열기 (Cmd+O)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
