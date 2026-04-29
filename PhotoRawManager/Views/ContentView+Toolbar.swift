import SwiftUI
import Quartz

// MARK: - Toolbar & Filter Menus

extension ContentView {

    // MARK: - Toolbar

    var toolbar: some View {
        VStack(spacing: 0) {
            toolbarRow1
        }
    }

    var toolbarRow1: some View {
        VStack(spacing: 0) {
            // === Row 1: 네비게이션 + 액션 ===
            HStack(spacing: 6) {
                // 네비게이션 그룹
                iconButton("house.fill", active: false) {
                    store.startupMode = nil; store.photos = []; store.selectedPhotoID = nil
                    store.selectedPhotoIDs = []; store.folderURL = nil
                }
                .help("시작 화면으로 돌아가기")

                iconButton("sidebar.leading", active: store.showFolderBrowser) {
                    store.showFolderBrowser.toggle()
                }
                .help("폴더 브라우저")

                if let url = store.folderURL {
                    BreadcrumbPathView(url: url, store: store)
                    Spacer().frame(width: 12)  // 경로 ↔ 게이지 간격
                    // v8.8.2: "하위 포함" 배지를 진행률 게이지보다 먼저 표시
                    if store.isRecursiveMode {
                        Button { store.exitRecursiveMode() } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "folder.badge.plus").font(.system(size: 10))
                                Text("하위 포함").font(.system(size: AppTheme.fontMicro, weight: .medium))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.orange.opacity(0.15)).foregroundColor(.orange)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    // v8.9.7+: 캐시 진행률 게이지 제거 — 미리보기 토글로 통합 표시.
                    // v8.8.1: 적극 캐시 모드 토글 (ON 이면 폴더 진입 즉시 공격적 병렬 로딩)
                    AggressiveCacheToggle(store: store)
                    // v8.9.4: 빠른 셀렉 모드 토글 (ON 이면 viewport 우선, AI/Stage2 OFF)
                    FastCullingToggle(store: store)
                    // v9.0: 초기 미리보기 토글 일시 비활성화 (응답없음 발생 — Phase 3 RAW 디코드 큐 backpressure 문제).
                    //   Debug 에서만 노출해 추후 fix 후 v9.1+ 에서 다시 활성화.
                    #if DEBUG
                    InitialPreviewToggle()
                        .fixedSize(horizontal: true, vertical: true)
                    #endif
                    // v8.9.4: 활성 필터 요약 배지 (별점/라벨/선택만 등 무엇이 켜져있는지 한눈에)
                    activeFilterBadge
                }

                if store.isLoading {
                    ProgressView().scaleEffect(0.6)
                }

                if store.selectionCount > 1 {
                    SelectionInfoBadge(store: store)
                }

                Spacer(minLength: 4)

                // 진행률 (썸네일 / 변환)
                if store.isPreloadingThumbs {
                    compactProgress(
                        done: store.thumbsLoaded, total: store.thumbsTotal,
                        color: .green, eta: store.thumbsETA
                    )
                }
                if store.isConverting {
                    compactProgress(
                        done: store.conversionDone, total: store.conversionTotal,
                        color: .orange, eta: store.conversionETA,
                        onStop: { store.conversionCancelled = true }
                    )
                }

                // 분석 중지
                if store.isAnalyzing {
                    Button(action: { store.stopAnalysis() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "stop.fill").font(.system(size: 9))
                            Text("분석 중지").font(.system(size: AppTheme.fontMicro, weight: .medium))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(AppTheme.error).foregroundColor(.white)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if !store.photos.isEmpty {
                    Divider().frame(height: AppTheme.toolbarDividerHeight).opacity(0.15)

                    // v8.9.4: AI 드롭다운 — 클라이언트 왼쪽 (row1) 으로 이동
                    if !AppConfig.hideAIFeatures {
                        qualityFilterMenu
                    }

                    // 클라이언트 셀렉
                    Menu {
                        Button(action: { ClientSelectService.shared.requestStart() }) {
                            Label("사진 업로드 + 링크 생성", systemImage: "icloud.and.arrow.up")
                        }
                        Button(action: { ClientSelectService.shared.showSessionList = true }) {
                            Label("내 세션 목록", systemImage: "list.clipboard")
                        }
                        Button(action: { ClientSelectService.shared.showProxySetup = true }) {
                            Label("Apps Script 프록시 설정", systemImage: "network.badge.shield.half.filled")
                        }
                        Divider()
                        Button(action: { store.importPickshotFile() }) {
                            Label("셀렉 파일 가져오기", systemImage: "doc.badge.arrow.up")
                        }
                        Button(action: { importPickshotFromDrive() }) {
                            Label("Drive에서 가져오기", systemImage: "icloud.and.arrow.down")
                        }
                    } label: {
                        actionLabel("person.crop.rectangle", "클라이언트", .cyan)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("클라이언트 셀렉 보내기/가져오기")

                    // 내보내기
                    Menu {
                        Button(action: { store.showExportSheet = true }) {
                            Label("내보내기 (Cmd+E)", systemImage: "square.and.arrow.up")
                        }
                        Button(action: { store.showBatchProcess = true }) {
                            Label("배치 처리 (리사이즈+워터마크)", systemImage: "photo.on.rectangle.angled")
                        }
                        Divider()
                        Button(action: { store.showContactSheet = true }) {
                            Label("컨택트시트 PDF", systemImage: "tablecells")
                        }
                        Button(action: {
                            store.metadataEditorMode = store.selectedPhotoIDs.count > 1 ? .batch : .single
                            store.showMetadataEditor = true
                        }) {
                            Label("메타데이터 편집", systemImage: "doc.badge.gearshape")
                        }
                    } label: {
                        actionLabel("square.and.arrow.up", "내보내기", .orange)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("내보내기 / 배치 처리")

                    // 매칭
                    Button(action: { store.showMatchingSheet = true }) {
                        actionLabel("arrow.triangle.2.circlepath", "매칭", .purple)
                    }
                    .buttonStyle(.plain)
                    .help("파일명/JPG/AI 매칭 셀렉")

                    // v8.9.4: AI 셀렉/인물그룹/내취향 → 통합 AI 메뉴 안으로 흡수 (헷갈림 해소)

                    // v8.9.4: 번호 필터 → 정렬 메뉴 안으로 이동 (외부 아이콘 제거)

                    // G Select
                    gSelectButton
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        }
    }

    var toolbarRow2: some View {
        VStack(spacing: 0) {
            // === Row 2: Filters ===
            if !store.photos.isEmpty {
                GeometryReader { geo in
                let thumbWidth = geo.size.width * store.hSplitRatio
                HStack(spacing: 0) {
                    // 썸네일 영역에 맞춘 좌측 섹션 (별점 + 라벨 + 검색 + 정렬)
                    HStack(spacing: 8) {
                        // 선택만 토글 — v8.9.4: 맨 왼쪽 (체크박스 아이콘만)
                        selectedOnlyButton

                        Divider().frame(height: AppTheme.toolbarDividerHeight).opacity(0.15)

                        // Star filter — 인라인 5별 스와치 (v8.9.4)
                        starFilterMenu

                        // Color label filter — 인라인 5색 스와치 (v8.9.4)
                        colorLabelFilterMenu
                        // v8.9.4: Spacer 제거 — 모든 버튼 좌측 정렬

                        // Search bar (항상 표시)
                        // v8.9.7+: 정렬 메뉴와 height 통일 (AppTheme.buttonHeight) + 폭 고정 →
                        //   썸네일 폭/슬라이더 조절해도 크기 변하지 않음.
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: AppTheme.iconSmall))
                                .foregroundColor(.secondary)
                            TextField("검색", text: $store.searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: AppTheme.fontBody))
                                .frame(width: 90)
                                .onExitCommand {
                                    store.restoreKeyFocus()
                                }
                                .onSubmit {
                                    store.restoreKeyFocus()
                                    DispatchQueue.main.async {
                                        NSApp.keyWindow?.makeFirstResponder(nil)
                                    }
                                }
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
                                        .font(.system(size: AppTheme.fontBody))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: AppTheme.buttonHeight)
                        .fixedSize(horizontal: true, vertical: true)
                        .background(AppTheme.toolbarButtonBg)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        // v8.9.4: 정렬 메뉴 — thumbWidth 와 무관하게 항상 표시 (이전엔 >550 일 때만)
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
                            Divider()
                            Section("필터") {
                                let rangeActive = store.rangeFilterMin != nil || store.rangeFilterMax != nil
                                let rangeLabel: String = {
                                    if let lo = store.rangeFilterMin, let hi = store.rangeFilterMax { return "파일 번호 \(lo)–\(hi)" }
                                    if let lo = store.rangeFilterMin { return "파일 번호 \(lo)–" }
                                    if let hi = store.rangeFilterMax { return "파일 번호 –\(hi)" }
                                    return "파일 번호 범위..."
                                }()
                                Button(action: { showRangeFilterDialog() }) {
                                    Label(rangeLabel, systemImage: rangeActive ? "checkmark.circle.fill" : "number.circle")
                                }
                                if rangeActive {
                                    Button(action: {
                                        store.rangeFilterMin = nil
                                        store.rangeFilterMax = nil
                                    }) {
                                        Label("파일 번호 필터 해제", systemImage: "xmark.circle")
                                    }
                                }
                            }
                        } label: {
                            toolbarButton(icon: store.sortMode.icon, text: store.sortMode.compactLabel, color: AppTheme.accent, active: false)
                        }
                        .fixedSize(horizontal: true, vertical: true)
                        .tooltip("정렬 / 파일 번호 범위 필터")
                        // v8.9.4: AI 분류 메뉴 → 클라이언트 왼쪽으로 이동 (row1)
                        // v8.9.4: 스마트 컬렉션 → 비활성화
                    }
                    .frame(maxWidth: max(300, thumbWidth), alignment: .leading)
                    .padding(.horizontal, 10)

                    Spacer(minLength: 8)

                    // === 우측: 뷰 전환 그룹 ===
                    iconButton(store.layoutMode.icon, active: store.layoutMode == .filmstrip) {
                        let newMode: LayoutMode = store.layoutMode == .gridPreview ? .filmstrip : .gridPreview
                        store.setLayoutMode(newMode)
                    }
                    .help("레이아웃 전환")

                    // 전체화면 (⌘F)
                    iconButton("arrow.up.left.and.arrow.down.right", active: false) {
                        store.showFullscreenPreview.toggle()
                    }
                    .help("전체화면 (⌘F)")

                    iconButton("display.2", active: store.showDualViewer) {
                        store.showDualViewer.toggle()
                    }
                    .help("듀얼 뷰어 (D)")

                    iconButton("square.split.2x1", active: false) {
                        if store.selectionCount >= 2 && store.selectionCount <= 4 {
                            store.showCompare = true
                        } else {
                            DisabledGuide.showCompareDisabled(currentCount: store.selectionCount)
                        }
                    }
                    .opacity(store.selectionCount >= 2 ? 1 : 0.4)
                    .help("비교 보기 (2~4장)")

                    if !AppConfig.hideAIFeatures {
                        iconButton("face.smiling", active: false) {
                            if store.selectionCount >= 2 && store.selectionCount <= 6 {
                                store.showFaceCompare = true
                            }
                        }
                        .opacity(store.selectionCount >= 2 ? 1 : 0.4)
                        .help("표정 비교 (2~6장)")
                    }

                    // 더보기 메뉴 (사용빈도 낮은 기능)
                    Menu {
                        Button(action: { store.showMap = true }) {
                            Label("GPS 지도", systemImage: "map")
                        }
                        Button(action: { store.showSlideshow = true }) {
                            Label("슬라이드쇼", systemImage: "play.rectangle")
                        }
                        Divider()
                        Button(action: { store.isDarkMode.toggle() }) {
                            Label(store.isDarkMode ? "라이트 모드" : "다크 모드", systemImage: store.isDarkMode ? "sun.max" : "moon")
                        }
                        Button(action: { store.showShortcutHelp = true }) {
                            Label("단축키 안내", systemImage: "questionmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: AppTheme.iconSmall))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
                    .background(AppTheme.toolbarButtonBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help("더보기")
                }
                .padding(.trailing, 10)
                } // end GeometryReader
                .frame(height: 36)
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: - 썸네일 패널 서브 툴바 (검색 + 정렬 + AI + 컬렉션)

    var thumbnailSubToolbar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            // Search bar
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("검색", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(minWidth: 80, maxWidth: 140)
                    .onExitCommand {
                        store.restoreKeyFocus()
                    }
                    .onSubmit {
                        store.restoreKeyFocus()
                        DispatchQueue.main.async {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    }
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
                toolbarButton(icon: store.sortMode.icon, text: store.sortMode.compactLabel, color: AppTheme.accent, active: false)
            }
            .help("정렬 순서 변경 (촬영시간/파일명/별점)")

            // v8.9.4: AI 분류 메뉴 → 클라이언트 왼쪽(row1)으로 이동
            // v8.9.4: 스마트 컬렉션 → 비활성화
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    // MARK: - Quality Filter Menu

    var qualityFilterMenu: some View {
        let aiCount = store.photos.filter { $0.isAIPick }.count

        let groups = store.availableFaceGroups
        let hasGroups = !groups.isEmpty
        return HStack(spacing: 4) {
        Menu {
            // ── 보기 (필터) ──
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

            // 인물 그룹 — v8.9.4: AI 메뉴로 통합 (별도 외부 메뉴 제거)
            if hasGroups {
                Divider()
                Section("👤 인물") {
                    Button(action: {
                        store.faceGroupFilter = nil
                        store.faceGroupFilters = []
                    }) {
                        Label("전체 인물", systemImage: (store.faceGroupFilter == nil && store.faceGroupFilters.isEmpty) ? "checkmark" : "person.2")
                    }
                    ForEach(groups, id: \.self) { gid in
                        let count = store.faceGroups[gid]?.count ?? 0
                        Button(action: {
                            store.faceGroupFilter = (store.faceGroupFilter == gid) ? nil : gid
                            store.faceGroupFilters = []
                        }) {
                            Label("\(store.faceGroupName(for: gid)) (\(count)장)",
                                  systemImage: store.faceGroupFilter == gid ? "checkmark" : "person.crop.circle")
                        }
                    }
                }
            }

            Divider()
            // ── 셀렉 도구 (실행) ──
            Section("🧠 AI 셀렉 도구") {
                Button(action: { store.showSmartCull = true }) {
                    Label("AI 셀렉 (유사 그룹 + A컷)", systemImage: "brain")
                }
                Button(action: { store.showPreferenceTrainingDialog = true }) {
                    let trained = UserPreferenceService.shared.profile.isTrained
                    Label(trained ? "내 취향 (학습됨) — 관리" : "내 취향 학습 시작", systemImage: "brain.head.profile")
                }
                Button(action: { store.showAnalysisOptions = true }) {
                    Label("PickShot AI 분류 실행...", systemImage: "wand.and.stars")
                }
                Button(action: { store.classifyScenes() }) {
                    Label(store.isClassifyingScenes ? "분류 중..." : "Vision 로컬 분류", systemImage: "eye.fill")
                }
                .disabled(store.isClassifyingScenes)
                Button(action: { store.showBurstPickerDialog = true }) {
                    Label("연사 베스트 자동 선별...", systemImage: "wand.and.stars.inverse")
                }
            }

            // ── 장면 태그 (분류 결과 필터) ──
            let tags = store.availableSceneTags
            if !tags.isEmpty {
                Divider()
                Section("📂 장면") {
                    ForEach(tags, id: \.self) { tag in
                        Button(action: { store.sceneTagFilter = store.sceneTagFilter == tag ? nil : tag }) {
                            Label(tag, systemImage: store.sceneTagFilter == tag ? "checkmark" : "")
                        }
                    }
                }
            }

            Divider()

            // AI 프리셋 프롬프트 분류
            Section("🤖 AI 프롬프트 분류") {
                ForEach(ClaudeVisionService.classifyPresets, id: \.name) { preset in
                    Button(action: {
                        if !ClaudeVisionService.hasAPIKey {
                            DisabledGuide.showAIDisabled()
                        } else {
                            store.runAIClassification(customPrompt: preset.prompt)
                        }
                    }) {
                        Label(preset.name, systemImage: "sparkles")
                    }
                    .disabled(store.isAIClassifying)
                }
                Button(action: {
                    if !ClaudeVisionService.hasAPIKey {
                        DisabledGuide.showAIDisabled()
                    } else {
                        store.showCustomPrompt = true
                    }
                }) {
                    Label("커스텀 프롬프트...", systemImage: "text.cursor")
                }
                .disabled(store.isAIClassifying)

                Divider()

                // 선택된 사진만 분류
                let selectedCount = store.selectionCount
                Button(action: {
                    if !ClaudeVisionService.hasAPIKey && !GeminiService.hasAPIKey {
                        DisabledGuide.showAIDisabled()
                    } else {
                        store.runAIClassification(selectedOnly: true)
                    }
                }) {
                    Label("선택된 사진만 분류 (\(selectedCount)장)", systemImage: "checkmark.circle")
                }
                .disabled(store.isAIClassifying || selectedCount == 0)
                // v8.9.4: 연사 베스트는 "AI 셀렉 도구" 섹션으로 이동됨
            }
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

        // v8.9.4: "내 취향" 외부 버튼 → AI 메뉴 안 "AI 셀렉 도구" 섹션으로 흡수
        if store.isClassifyingScenes || store.isAnalyzing {
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        }
        }  // HStack close
    }

    // MARK: - Face Group Filter Menu

    // MARK: - v8.7 Range (파일 번호) 필터 메뉴

    // v8.9.4: rangeFilterMenu 는 deprecated (정렬 메뉴 안으로 이동). 빈 뷰 유지 - 호출처 제거 전 호환용.
    func showRangeFilterDialog() {
        let alert = NSAlert()
        alert.messageText = "파일 번호 범위 필터"
        alert.informativeText = "파일명의 마지막 숫자를 기준으로 필터링합니다.\n예: DSC01234.ARW → 1234.\n비워두면 제한 없음."
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        let loField = NSTextField(frame: NSRect(x: 0, y: 28, width: 100, height: 22))
        loField.placeholderString = "최소 (예: 1000)"
        loField.stringValue = store.rangeFilterMin.map { String($0) } ?? ""
        let sep = NSTextField(labelWithString: "~")
        sep.frame = NSRect(x: 110, y: 30, width: 20, height: 18)
        sep.alignment = .center
        let hiField = NSTextField(frame: NSRect(x: 140, y: 28, width: 100, height: 22))
        hiField.placeholderString = "최대 (예: 1500)"
        hiField.stringValue = store.rangeFilterMax.map { String($0) } ?? ""
        let hint = NSTextField(labelWithString: "현재 폴더: 전체 \(store.photos.count)장")
        hint.frame = NSRect(x: 0, y: 0, width: 240, height: 18)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        container.addSubview(loField); container.addSubview(sep); container.addSubview(hiField); container.addSubview(hint)
        alert.accessoryView = container
        alert.addButton(withTitle: "적용")
        alert.addButton(withTitle: "해제")
        alert.addButton(withTitle: "취소")
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            store.rangeFilterMin = Int(loField.stringValue.trimmingCharacters(in: .whitespaces))
            store.rangeFilterMax = Int(hiField.stringValue.trimmingCharacters(in: .whitespaces))
        } else if resp == .alertSecondButtonReturn {
            store.rangeFilterMin = nil
            store.rangeFilterMax = nil
        }
    }

    var rangeFilterMenu: some View {
        EmptyView()  // deprecated — 정렬 메뉴 안으로 이동
    }
    // unreachable
    var _rangeFilterMenuLegacy: some View {
        let active = store.rangeFilterMin != nil || store.rangeFilterMax != nil
        let labelText: String = {
            if let lo = store.rangeFilterMin, let hi = store.rangeFilterMax { return "\(lo)-\(hi)" }
            if let lo = store.rangeFilterMin { return "\(lo)-" }
            if let hi = store.rangeFilterMax { return "-\(hi)" }
            return "번호"
        }()
        return Button(action: { showRangeFilterDialog() }) {
            toolbarButton(
                icon: "number.circle",
                text: labelText,
                color: .teal,
                active: active
            )
        }
        .buttonStyle(.plain)
        .help("파일 번호 범위 필터 (예: 1000~1500)")
    }

    var faceGroupFilterMenu: some View {
        let groups = store.availableFaceGroups
        let hasGroups = !groups.isEmpty

        return HStack(spacing: 4) {
            Menu {
                Button(action: {
                    store.faceGroupFilter = nil
                    store.faceGroupFilters = []
                }) {
                    Label("전체", systemImage: (store.faceGroupFilter == nil && store.faceGroupFilters.isEmpty) ? "checkmark" : "")
                }
                Divider()
                // v8.7: 다중 인물 선택 (신랑 + 신부 등 OR 조합)
                if hasGroups && !store.faceGroupFilters.isEmpty {
                    Button(action: { store.faceGroupFilters = [] }) {
                        Label("다중 선택 해제 (\(store.faceGroupFilters.count)명)", systemImage: "xmark.circle")
                    }
                    Divider()
                }
                if hasGroups {
                    ForEach(groups, id: \.self) { gid in
                        // 단일 선택 (기존)
                        Button(action: {
                            store.faceGroupFilter = gid
                            store.faceGroupFilters = []
                        }) {
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
                                Text(store.faceGroupName(for: gid))
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
                    Divider()
                    // v8.7: 다중 선택 토글 (한 메뉴에서 여러 명 체크)
                    Text("여러 명 선택 (OR)").font(.system(size: 10)).foregroundColor(.secondary)
                    ForEach(groups, id: \.self) { gid in
                        Button(action: {
                            var set = store.faceGroupFilters
                            if set.contains(gid) { set.remove(gid) } else { set.insert(gid) }
                            store.faceGroupFilters = set
                            if !set.isEmpty { store.faceGroupFilter = nil }  // 단일 필터와 충돌 방지
                        }) {
                            let isSelected = store.faceGroupFilters.contains(gid)
                            Label(
                                "\(isSelected ? "✓ " : "+  ")\(store.faceGroupName(for: gid))",
                                systemImage: isSelected ? "checkmark.square.fill" : "square"
                            )
                        }
                    }
                    Divider()
                    // 이름 변경
                    ForEach(groups, id: \.self) { gid in
                        Button(action: {
                            let alert = NSAlert()
                            alert.messageText = "인물 이름 변경"
                            alert.informativeText = "'\(store.faceGroupName(for: gid))' 의 이름을 입력하세요"
                            let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                            tf.stringValue = store.faceGroupNames[gid] ?? ""
                            tf.placeholderString = "이름 입력"
                            alert.accessoryView = tf
                            alert.addButton(withTitle: "저장")
                            alert.addButton(withTitle: "취소")
                            if alert.runModal() == .alertFirstButtonReturn {
                                store.setFaceGroupName(gid, name: tf.stringValue)
                            }
                        }) {
                            Label("'\(store.faceGroupName(for: gid))' 이름 변경", systemImage: "pencil")
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
                    text: store.faceGroupFilter != nil ? store.faceGroupName(for: store.faceGroupFilter!)
                        : (!store.faceGroupFilters.isEmpty ? "인물 \(store.faceGroupFilters.count)명" : "인물"),
                    color: .orange,
                    active: store.faceGroupFilter != nil || !store.faceGroupFilters.isEmpty
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

                // 프리셋 프롬프트로 분류 실행
                Section("🤖 AI 분류 실행") {
                    ForEach(ClaudeVisionService.classifyPresets, id: \.name) { preset in
                        Button(action: {
                            if store.isAIClassifying {
                                DisabledGuide.showAnalysisInProgress()
                            } else if !ClaudeVisionService.hasAPIKey {
                                DisabledGuide.showAIDisabled()
                            } else {
                                store.runAIClassification(customPrompt: preset.prompt)
                            }
                        }) {
                            Label(preset.name, systemImage: "sparkles")
                        }
                        .disabled(store.isAIClassifying)
                    }

                    // 커스텀 프롬프트 실행
                    Button(action: {
                        if store.isAIClassifying {
                            DisabledGuide.showAnalysisInProgress()
                        } else if !ClaudeVisionService.hasAPIKey {
                            DisabledGuide.showAIDisabled()
                        } else {
                            store.showCustomPrompt = true
                        }
                    }) {
                        Label("커스텀 프롬프트...", systemImage: "text.cursor")
                    }
                    .disabled(store.isAIClassifying)
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

    // MARK: - Active Filter Badge (v8.9.4)

    /// 적극로딩 아이콘 옆에 표시되는 활성 필터 요약 — 무엇이 몇 개 필터됐는지 한눈에
    @ViewBuilder
    var activeFilterBadge: some View {
        let stars = store.ratingFilters.sorted()
        let labels = store.colorLabelFilters
        let selectedOnly = store.showOnlySelected
        let visualSearch = store.visualSearchActive
        let recursive = store.isRecursiveMode
        let hasFilter = !stars.isEmpty || !labels.isEmpty || selectedOnly || visualSearch
        if hasFilter {
            Button(action: {
                // 한 번 누르면 모든 필터 해제 (recursive 제외)
                store.batchUpdateFilters {
                    store.ratingFilters = []
                    store.minimumRatingFilter = 0
                    store.colorLabelFilters = []
                    store.showOnlySelected = false
                    if visualSearch {
                        VisualSearchService.shared.clearAll()
                        store.visualSearchActive = false
                    }
                }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.cyan)
                    // 활성 필터 칩들 (가로 나열)
                    HStack(spacing: 3) {
                        ForEach(stars, id: \.self) { r in
                            HStack(spacing: 1) {
                                Image(systemName: "star.fill").font(.system(size: 8))
                                Text("\(r)").font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(AppTheme.starGold)
                        }
                        ForEach(ColorLabel.allCases.filter { labels.contains($0) }, id: \.self) { l in
                            Circle()
                                .fill(l.color ?? .clear)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 0.5))
                        }
                        if selectedOnly {
                            Image(systemName: "checkmark.square.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.blue)
                        }
                        if visualSearch {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 9))
                                .foregroundColor(.purple)
                        }
                    }
                    Text("·").foregroundColor(.white.opacity(0.4))
                    Text("\(store.filteredPhotos.count)장")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.cyan.opacity(0.15))
                        .overlay(Capsule().stroke(Color.cyan.opacity(0.4), lineWidth: 0.5))
                )
            }
            .buttonStyle(.plain)
            .help("활성 필터 요약 (클릭: 모든 필터 해제) · 하위포함\(recursive ? " ON" : "")")
        }
    }

    // MARK: - Filter Menus (v8.9.4)

    /// 별점 필터 — Lightroom 스타일
    /// • 별 N개 클릭 → 1~N개 모두 칠해짐 (누적 시각), 정확히 N별 사진만 필터
    /// • 동일 별 재클릭 → 해제 (=All)
    /// • Cmd·Shift+클릭 → 다중 선택 (예: 1·3·5 별 동시 표시) 시 칠해지는 건 단순히 활성 별만
    var starFilterMenu: some View {
        let activeRatings = store.ratingFilters
        // 단일 선택 모드인 경우 "최대 활성 별점" 추출 → 그 이하는 모두 채움.
        let isMulti = activeRatings.count > 1
        let cumulativeMax = isMulti ? 0 : (activeRatings.max() ?? 0)
        return HStack(spacing: 3) {
            ForEach([1, 2, 3, 4, 5], id: \.self) { rating in
                let isExactlyActive = activeRatings.contains(rating)
                // 누적 칠하기: 단일 선택 모드일 때 rating <= cumulativeMax 면 fill
                let shouldFill = isMulti ? isExactlyActive : (rating <= cumulativeMax)
                let count = store.photos.filter { $0.rating == rating && !$0.isFolder && !$0.isParentFolder }.count
                Button(action: {
                    let flags = NSEvent.modifierFlags
                    let multi = flags.contains(.command) || flags.contains(.shift)
                    if multi {
                        if isExactlyActive { store.ratingFilters.remove(rating) }
                        else { store.ratingFilters.insert(rating) }
                    } else {
                        // 동일 별 재클릭 → 해제. 그 외 → 정확히 그 별점만 표시
                        if activeRatings.count == 1 && isExactlyActive {
                            store.ratingFilters = []
                        } else {
                            store.ratingFilters = [rating]
                        }
                    }
                    store.minimumRatingFilter = 0
                }) {
                    // v8.9.4: 카운트 숫자 오버레이 제거 (글자 작아서 확인 어려움)
                    Image(systemName: shouldFill ? "star.fill" : "star")
                        .font(.system(size: AppTheme.iconSmall, weight: .semibold))
                        .foregroundColor(shouldFill ? AppTheme.starGold : Color.white.opacity(0.45))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("별 \(rating) 만 표시 (\(count)장) / Cmd·Shift+클릭: 다중 선택")
            }
            if !activeRatings.isEmpty {
                Button(action: {
                    store.batchUpdateFilters {
                        store.ratingFilters = []
                        store.minimumRatingFilter = 0
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("별점 필터 해제")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: AppTheme.buttonHeight)  // v8.9.7+: 검색/정렬과 통일 (32→38)
        .background(AppTheme.toolbarButtonBg)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 컬러라벨 필터 — Lightroom/Photo Mechanic 스타일 인라인 5색 스와치
    /// 활성: 채워진 원 + 흰 링 / 비활성: 어둡게 + 가는 링 / Cmd·Shift+클릭으로 다중
    var colorLabelFilterMenu: some View {
        let activeLabels = store.colorLabelFilters
        return HStack(spacing: 3) {
            ForEach(ColorLabel.allCases.filter { $0 != .none }, id: \.self) { label in
                let isActive = activeLabels.contains(label)
                let count = store.photos.filter {
                    $0.colorLabel == label && !$0.isFolder && !$0.isParentFolder
                }.count
                Button(action: {
                    let flags = NSEvent.modifierFlags
                    let multi = flags.contains(.command) || flags.contains(.shift)
                    if multi {
                        if isActive { store.colorLabelFilters.remove(label) }
                        else { store.colorLabelFilters.insert(label) }
                    } else {
                        if activeLabels.count == 1 && isActive {
                            store.colorLabelFilters = []
                        } else {
                            store.colorLabelFilters = [label]
                        }
                    }
                }) {
                    // v8.9.4: 카운트 숫자 오버레이 제거 (글자 작아서 확인 어려움)
                    Circle()
                        .fill((label.color ?? .gray).opacity(isActive ? 1.0 : 0.45))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle().stroke(
                                isActive ? Color.white : Color.white.opacity(0.15),
                                lineWidth: isActive ? 2 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .help("\(label.rawValue) 라벨 (\(count)장)\(label.key.isEmpty ? "" : " · 키: \(label.key)") / Cmd·Shift+클릭: 다중 선택")
            }
            if !activeLabels.isEmpty {
                Button(action: { store.colorLabelFilters.removeAll() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("라벨 필터 해제")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: AppTheme.buttonHeight)  // v8.9.7+: 검색/정렬과 통일 (32→38)
        .background(AppTheme.toolbarButtonBg)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 선택만 토글 — 체크박스 아이콘만 (텍스트 없음)
    /// v8.9.4: 선택 0일 때도 항상 표시 (배치 흔들림 방지). 카운트 배지는 항상 노출 (0 포함)
    var selectedOnlyButton: some View {
        let count = store.selectedPhotoIDs.count
        let canActivate = count > 0
        return Button(action: {
            if canActivate { store.showOnlySelected.toggle() }
        }) {
            HStack(spacing: 4) {
                Image(systemName: store.showOnlySelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: AppTheme.iconSmall, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 5)
                    .frame(height: 14)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
            }
            .padding(.horizontal, 10)
            .frame(height: AppTheme.buttonHeight)  // v8.9.7+: 검색/정렬과 통일 (32→38)
            .opacity(canActivate ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .foregroundColor(store.showOnlySelected ? .white : .primary)
        .background(store.showOnlySelected ? Color.blue.opacity(0.85) : AppTheme.toolbarButtonBg)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(canActivate ? "선택한 \(count)장만 표시" : "선택된 사진 없음")
    }

    // MARK: - Toolbar Button Helper

    /// v8.8: 숫자 배지 포맷 — 1000 이상은 "1.2k" 형식으로 압축
    func formatCountBadge(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        let k = Double(count) / 1000.0
        if k >= 10 { return "\(Int(k))k" }
        return String(format: "%.1fk", k)
    }

    func toolbarButton(icon: String, text: String, color: Color, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.iconSmall))
                .foregroundColor(active ? .white : color)  // 아이콘은 컬러 유지
            Text(text)
                .font(.system(size: AppTheme.fontBody, weight: .medium))
                .foregroundColor(.white)                   // v8.7: 텍스트는 항상 흰색
        }
        .padding(.horizontal, 8)
        .frame(height: AppTheme.buttonHeight)
        .background(active ? color : AppTheme.toolbarButtonBg)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Drive에서 셀렉 가져오기

    func importPickshotFromDrive() {
        // 토큰 갱신
        GoogleDriveService.refreshAccessToken { _, _ in }

        // 세션 복원 시도
        if ClientSelectService.shared.driveFolderID == nil {
            _ = ClientSelectService.shared.restoreLastSession()
        }

        guard var token = GoogleDriveService.savedAccessToken else {
            store.showToastMessage("Google Drive 로그인이 필요합니다")
            return
        }

        // 토큰 갱신
        let sem = DispatchSemaphore(value: 0)
        GoogleDriveService.refreshAccessToken { newToken, _ in
            if let t = newToken { token = t }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)

        var folderId = ClientSelectService.shared.driveFolderID

        // 폴더 ID 없으면 — Google Drive에서 PickShot 폴더 목록 검색
        if folderId == nil {
            store.showToastMessage("Drive에서 클라이언트 셀렉 폴더 검색 중...")
            // Google Drive에서 최근 폴더 목록 가져오기
            let listSem = DispatchSemaphore(value: 0)
            let query = "mimeType='application/vnd.google-apps.folder' and trashed=false"
            let urlStr = "https://www.googleapis.com/drive/v3/files?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&fields=files(id,name,createdTime)&orderBy=createdTime desc&pageSize=20"
            guard let apiURL = URL(string: urlStr) else { return }
            var request = URLRequest(url: apiURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            var folders: [(id: String, name: String)] = []
            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let files = json["files"] as? [[String: Any]] {
                    folders = files.compactMap { f in
                        guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
                        return (id: id, name: name)
                    }
                }
                listSem.signal()
            }.resume()
            listSem.wait()

            guard !folders.isEmpty else {
                store.showToastMessage("Drive에 폴더가 없습니다")
                return
            }

            // 폴더 선택 팝업
            let alert = NSAlert()
            alert.messageText = "셀렉 결과를 가져올 폴더 선택"
            alert.informativeText = "Google Drive에서 클라이언트 셀렉 폴더를 선택하세요"
            alert.addButton(withTitle: "가져오기")
            alert.addButton(withTitle: "취소")

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 350, height: 28))
            for f in folders {
                popup.addItem(withTitle: f.name)
            }
            alert.accessoryView = popup

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            let selectedIdx = popup.indexOfSelectedItem
            guard selectedIdx >= 0 && selectedIdx < folders.count else { return }
            folderId = folders[selectedIdx].id
        }

        guard let finalFolderId = folderId else { return }

        store.showToastMessage("Drive에서 .pickshot 파일 검색 중...")
        ClientSelectService.shared.checkForPickshotInDrive(folderId: finalFolderId, token: token) { [weak store] tempURL in
            DispatchQueue.main.async {
                guard let store = store else { return }
                guard let url = tempURL else {
                    store.showToastMessage("Drive에 .pickshot 파일이 없습니다")
                    return
                }
                let result = PickshotFileService.applyPickshotFile(url: url, to: &store.photos, photoIndex: store._photoIndex)
                if let result = result {
                    store.invalidateFilterCache()
                    store.buildClientComments()
                    store.lastImportResult = result
                    store.showPickshotImportSheet = true
                }
                // 임시 파일 정리
                try? FileManager.default.removeItem(at: url)
            }
        }
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

    // MARK: - 공통 UI 헬퍼

    /// 통일된 아이콘 버튼 (툴바용)
    func iconButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.iconSmall))
        }
        .buttonStyle(.plain)
        .frame(width: AppTheme.buttonHeight, height: AppTheme.buttonHeight)
        .foregroundColor(active ? .accentColor : .secondary)
        .background(active ? AppTheme.accent.opacity(0.15) : AppTheme.toolbarButtonBg)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 컴팩트 진행률 바
    func compactProgress(done: Int, total: Int, color: Color, eta: String, onStop: (() -> Void)? = nil) -> some View {
        let progress = total > 0 ? CGFloat(done) / CGFloat(total) : 0
        return HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.25)).frame(width: 80, height: 4)
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 80 * progress, height: 4)
            }
            Text("\(done)/\(total)")
                .font(.system(size: AppTheme.fontMicro, weight: .medium, design: .monospaced))
                .foregroundColor(color)
            if !eta.isEmpty {
                Text(eta)
                    .font(.system(size: AppTheme.fontMicro, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            if let stop = onStop {
                Button(action: stop) {
                    Image(systemName: "stop.fill").font(.system(size: 7)).foregroundColor(.red)
                }.buttonStyle(.plain)
            }
        }
    }

    /// 액션 버튼 라벨 (통일된 스타일)
    func actionLabel(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: AppTheme.iconSmall))
            Text(text).font(.system(size: AppTheme.fontCaption, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(color.opacity(0.12))
        .foregroundColor(color)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

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
