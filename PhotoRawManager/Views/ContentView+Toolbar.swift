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

                iconButton("cable.connector", active: false) {
                    store.startupMode = .tethering
                }
                .help("테더링 (카메라 연결)")

                iconButton("sidebar.leading", active: store.showFolderBrowser) {
                    store.showFolderBrowser.toggle()
                }
                .help("폴더 브라우저")

                if let url = store.folderURL {
                    BreadcrumbPathView(url: url, store: store)
                    // v8.6.2: 캐시 생성 진행률 원형 게이지 (썸네일+미리보기 통합)
                    CacheProgressGauge(store: store)
                }

                if store.isLoading {
                    ProgressView().scaleEffect(0.6)
                }

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

                    // AI 스마트 셀렉
                    if !AppConfig.hideAIFeatures {
                        Button(action: { store.showSmartCull = true }) {
                            actionLabel("brain", "AI 셀렉", .indigo)
                        }
                        .buttonStyle(.plain)
                        .help("유사 그룹핑 + A컷 자동 추천")
                    }

                    // 인물 그룹 필터
                    if !AppConfig.hideAIFeatures {
                        faceGroupFilterMenu
                    }

                    // v8.7: 파일명 번호 범위 필터
                    rangeFilterMenu

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
                        // Star filter — 별점 필터
                        HStack(spacing: 3) {
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

                        Divider().frame(height: AppTheme.toolbarDividerHeight).opacity(0.15)

                        // Color label filter — 라벨 필터 (다중 선택)
                        HStack(spacing: 5) {
                            ForEach(ColorLabel.allCases.filter { $0 != .none }, id: \.self) { label in
                                let isActive = store.colorLabelFilters.contains(label)
                                Button(action: {
                                    if isActive { store.colorLabelFilters.remove(label) }
                                    else { store.colorLabelFilters.insert(label) }
                                }) {
                                    Circle()
                                        .fill(label.color ?? .clear)
                                        .frame(width: 12, height: 12)
                                        .overlay(
                                            isActive
                                                ? Circle().stroke(Color.white, lineWidth: 2.5)
                                                : Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                                        )
                                        .shadow(color: isActive ? (label.color ?? .clear).opacity(0.7) : .clear, radius: 4)
                                        .opacity(isActive ? 1.0 : 0.5)
                                        .frame(width: AppTheme.minTouchTarget, height: AppTheme.minTouchTarget)
                                }
                                .buttonStyle(.plain)
                                .help("\(label.rawValue) 라벨 필터 (\(label.key.isEmpty ? "" : "키: \(label.key)"))")
                            }
                            if !store.colorLabelFilters.isEmpty {
                                Button(action: { store.colorLabelFilters.removeAll() }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("라벨 필터 해제")
                            }
                        }
                        Spacer(minLength: 4)

                        // Search bar (항상 표시)
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            TextField("검색", text: $store.searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                                .frame(minWidth: 60, maxWidth: 140)
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

                        // 정렬 + AI + 컬렉션 (넓을 때만 표시)
                        if thumbWidth > 550 {
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

                            // AI 분류
                            if !AppConfig.hideAIFeatures {
                                qualityFilterMenu
                            }

                            // 스마트 컬렉션
                            Menu {
                                if store.savedCollections.isEmpty {
                                    Text("저장된 컬렉션 없음")
                                } else {
                                    ForEach(store.savedCollections) { col in
                                        Button(action: { store.applyCollection(col) }) {
                                            Label(col.name, systemImage: "line.3.horizontal.decrease.circle")
                                        }
                                    }
                                    Divider()
                                    Button("전체 삭제", role: .destructive) {
                                        store.savedCollections.removeAll()
                                    }
                                }
                                Divider()
                                Button("현재 필터 저장...") {
                                    let alert = NSAlert()
                                    alert.messageText = "스마트 컬렉션 이름"
                                    alert.informativeText = "현재 필터 설정을 저장합니다."
                                    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                                    textField.stringValue = "내 컬렉션"
                                    alert.accessoryView = textField
                                    alert.addButton(withTitle: "저장")
                                    alert.addButton(withTitle: "취소")
                                    if alert.runModal() == .alertFirstButtonReturn {
                                        let name = textField.stringValue.trimmingCharacters(in: .whitespaces)
                                        if !name.isEmpty {
                                            store.saveCurrentFilter(name: name)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                        .font(.system(size: 11))
                                    if !store.savedCollections.isEmpty {
                                        Text("\(store.savedCollections.count)")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                }
                                .foregroundColor(store.savedCollections.isEmpty ? .secondary : .accentColor)
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 35)
                            .help("스마트 컬렉션")
                        }
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
                toolbarButton(icon: store.sortMode.icon, text: store.sortMode.rawValue, color: AppTheme.accent, active: false)
            }
            .help("정렬 순서 변경 (촬영시간/파일명/별점)")

            // AI 분류 (품질 + 장면 통합)
            if !AppConfig.hideAIFeatures {
                qualityFilterMenu
            }

            // 스마트 컬렉션
            Menu {
                if store.savedCollections.isEmpty {
                    Text("저장된 컬렉션 없음")
                } else {
                    ForEach(store.savedCollections) { col in
                        Button(action: { store.applyCollection(col) }) {
                            Label(col.name, systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                    Divider()
                    Button("전체 삭제", role: .destructive) {
                        store.savedCollections.removeAll()
                    }
                }
                Divider()
                Button("현재 필터 저장...") {
                    let alert = NSAlert()
                    alert.messageText = "스마트 컬렉션 이름"
                    alert.informativeText = "현재 필터 설정을 저장합니다."
                    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                    textField.stringValue = "내 컬렉션"
                    alert.accessoryView = textField
                    alert.addButton(withTitle: "저장")
                    alert.addButton(withTitle: "취소")
                    if alert.runModal() == .alertFirstButtonReturn {
                        let name = textField.stringValue.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty {
                            store.saveCurrentFilter(name: name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11))
                    if !store.savedCollections.isEmpty {
                        Text("\(store.savedCollections.count)")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundColor(store.savedCollections.isEmpty ? .secondary : .accentColor)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 35)
            .help("스마트 컬렉션")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    // MARK: - Quality Filter Menu

    var qualityFilterMenu: some View {
        let aiCount = store.photos.filter { $0.isAIPick }.count

        return HStack(spacing: 4) {
        Menu {
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
                Label(store.isClassifyingScenes ? "분류 중..." : "Vision 로컬 분류", systemImage: "eye.fill")
            }
            .disabled(store.isClassifyingScenes)

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

        if store.isClassifyingScenes || store.isAnalyzing {
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        }
        }  // HStack close
    }

    // MARK: - Face Group Filter Menu

    // MARK: - v8.7 Range (파일 번호) 필터 메뉴

    var rangeFilterMenu: some View {
        let active = store.rangeFilterMin != nil || store.rangeFilterMax != nil
        let labelText: String = {
            if let lo = store.rangeFilterMin, let hi = store.rangeFilterMax { return "\(lo)-\(hi)" }
            if let lo = store.rangeFilterMin { return "\(lo)-" }
            if let hi = store.rangeFilterMax { return "-\(hi)" }
            return "번호"
        }()
        return Button(action: {
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
        }) {
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
                    store.photosVersion += 1
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
