import SwiftUI
import AppKit
import Quartz

// MARK: - API Usage Gauge

struct APIUsageGauge: View {
    @ObservedObject private var tracker = APIUsageTracker.shared
    @State private var showDetail = false

    var body: some View {
        if ClaudeVisionService.hasAPIKey {
            Button(action: { showDetail.toggle() }) {
                HStack(spacing: 5) {
                    // Mini gauge bar
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 40, height: 6)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(gaugeColor)
                            .frame(width: 40 * tracker.usagePercent, height: 6)
                    }

                    Text("$\(String(format: "%.2f", tracker.estimatedCostUSD))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("AI 사용량: $\(String(format: "%.2f", tracker.estimatedCostUSD)) / $\(String(format: "%.2f", tracker.budgetUSD))")
            .popover(isPresented: $showDetail) {
                APIUsageDetailView()
            }
        }
    }

    private var gaugeColor: Color {
        if tracker.usagePercent > 0.9 { return .red }
        if tracker.usagePercent > 0.7 { return .orange }
        return .green
    }
}

struct APIUsageDetailView: View {
    @ObservedObject private var tracker = APIUsageTracker.shared
    @State private var budgetInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 사용량")
                .font(.system(size: 14, weight: .bold))

            // Gauge
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 10)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [.green, tracker.usagePercent > 0.7 ? .orange : .green, tracker.usagePercent > 0.9 ? .red : .green],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * tracker.usagePercent, height: 10)
                    }
                }
                .frame(height: 10)

                HStack {
                    Text("$\(String(format: "%.3f", tracker.estimatedCostUSD)) 사용")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("$\(String(format: "%.2f", tracker.remainingUSD)) 남음")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(tracker.remainingUSD < 1 ? .red : .green)
                }
            }

            Divider()

            // Stats
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("요청 횟수")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(tracker.requestCount)회")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("입력 토큰")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(tracker.totalInputTokens)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("출력 토큰")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(tracker.totalOutputTokens)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
            }

            Divider()

            // Budget setting
            HStack {
                Text("예산 설정")
                    .font(.system(size: AppTheme.iconSmall))
                HStack(spacing: 4) {
                    Text("$")
                        .font(.system(size: AppTheme.iconSmall))
                    TextField("5.00", text: $budgetInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .font(.system(size: AppTheme.iconSmall))
                        .onAppear { budgetInput = String(format: "%.2f", tracker.budgetUSD) }
                    Button("적용") {
                        if let val = Double(budgetInput) {
                            tracker.setBudget(val)
                        }
                    }
                    .font(.system(size: 10))
                    .controlSize(.small)
                    .help("예산 적용")
                }

                Spacer()

                Button("초기화") {
                    tracker.resetUsage()
                }
                .font(.system(size: 10))
                .foregroundColor(.red)
                .help("사용량 초기화")
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Subscription Badge

struct SubscriptionBadge: View {
    @ObservedObject private var sub = SubscriptionManager.shared
    @State private var showPaywall = false

    var body: some View {
        Button(action: { showPaywall = true }) {
            HStack(spacing: 4) {
                Image(systemName: sub.currentTier.icon)
                    .font(.system(size: 10))
                Text(sub.currentTier.displayName)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(badgeColor)
            .background(badgeColor.opacity(0.12))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help("구독 플랜 보기")
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    private var badgeColor: Color {
        switch sub.currentTier {
        case .free: return .gray
        case .pro: return .blue
        }
    }
}

// MARK: - Analysis Options Popover

struct AnalysisOptionsView: View {
    @ObservedObject var store: PhotoStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("품질 분석 항목")
                .font(.system(size: 14, weight: .bold))

            Text("\(store.photos.count)장의 사진을 분석합니다")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            // Analysis options with toggles
            VStack(alignment: .leading, spacing: 8) {
                AnalysisToggle(
                    isOn: $store.analysisOptions.checkBlur,
                    icon: "camera.metering.spot",
                    title: "블러 / 초점 분석",
                    description: "흔들림, 초점 나감, 인물 초점 미스 감지"
                )

                AnalysisToggle(
                    isOn: $store.analysisOptions.checkClosedEyes,
                    icon: "eye.slash",
                    title: "눈 감김 감지",
                    description: "인물 사진에서 눈 감은 얼굴 감지 (Vision 프레임워크)"
                )

                AnalysisToggle(
                    isOn: $store.analysisOptions.checkFaceFocus,
                    icon: "person.crop.circle",
                    title: "인물 초점 분석",
                    description: "얼굴 영역의 선명도 검사 (흔들림/초점 미스)"
                )
            }

            Divider()

            HStack {
                Button("전체 선택") {
                    store.analysisOptions = AnalysisOptions(
                        checkBlur: true, checkClosedEyes: true,
                        checkFaceFocus: true
                    )
                }
                .font(.caption)
                .help("모든 분석 항목 선택")

                Button("전체 해제") {
                    store.analysisOptions = AnalysisOptions(
                        checkBlur: false, checkClosedEyes: false,
                        checkFaceFocus: false
                    )
                }
                .font(.caption)
                .help("모든 분석 항목 해제")

                Spacer()

                Button(action: {
                    store.showAnalysisOptions = false
                    store.runQualityAnalysis()
                }) {
                    Label("분석 시작", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .help("선택한 항목으로 분석 시작")
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

struct AnalysisToggle: View {
    @Binding var isOn: Bool
    let icon: String
    let title: String
    let description: String

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 20)
                    .foregroundColor(isOn ? .accentColor : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Selection Info Badge

struct SelectionInfoBadge: View {
    @ObservedObject var store: PhotoStore

    var body: some View {
        let selected = store.multiSelectedPhotos
        let total = selected.count
        let ratingCounts = (1...5).map { r in selected.filter { $0.rating == r }.count }
        let unrated = selected.filter { $0.rating == 0 }.count

        HStack(spacing: 6) {
            Text("\(total)장 선택")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)

            if total > 0 {
                Divider().frame(height: 12).background(Color.white.opacity(0.3))

                // Rating breakdown
                ForEach(1...5, id: \.self) { star in
                    if ratingCounts[star - 1] > 0 {
                        HStack(spacing: 1) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.yellow)
                            Text("\(star):")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.7))
                            Text("\(ratingCounts[star - 1])")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }

                if unrated > 0 {
                    HStack(spacing: 1) {
                        Text("미분류:")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.7))
                        Text("\(unrated)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppTheme.accent)
        .cornerRadius(5)
    }
}

// MARK: - Drag Handle

enum DragAxis {
    case horizontal, vertical
}

struct DragHandle: View {
    let axis: DragAxis
    @State private var isHovered = false

    var body: some View {
        Group {
            if axis == .horizontal {
                // Vertical divider (thin line + wide hit area)
                ZStack {
                    // Thin visible line
                    Rectangle()
                        .fill(isHovered ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.15))
                        .frame(width: 1)

                    // Grab handle (center)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isHovered ? Color.accentColor : Color.gray.opacity(0.4))
                        .frame(width: 4, height: 40)
                }
                .frame(width: 14)  // Wide hit area for easy grabbing
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .cursor(.resizeLeftRight)
            } else {
                // Horizontal divider (thin line + tall hit area)
                ZStack {
                    // Thin visible line
                    Rectangle()
                        .fill(isHovered ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.15))
                        .frame(height: 1)

                    // Grab handle (center)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isHovered ? Color.accentColor : Color.gray.opacity(0.4))
                        .frame(width: 40, height: 4)
                }
                .frame(height: 14)  // Tall hit area for easy grabbing
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .cursor(.resizeUpDown)
            }
        }
    }
}

// MARK: - Analysis Progress Bar

struct AnalysisProgressBar: View {
    let progress: Double
    let total: Int
    let onStop: () -> Void

    var analyzed: Int {
        Int(progress * Double(total))
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12))
                    .foregroundColor(.purple)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [.purple, .blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * progress, height: 8)
                            .animation(.easeInOut(duration: 0.3), value: progress)
                    }
                }
                .frame(height: 8)

                Text("\(analyzed)/\(total)장")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)

                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.purple)
                    .frame(width: 40, alignment: .trailing)

                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.red)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("분석 중지")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

// MARK: - NSView-based keyboard event handler

struct KeyEventHandlingView: NSViewRepresentable {
    let store: PhotoStore
    var onFullscreen: (() -> Void)?
    var onHideFullscreen: (() -> Void)?

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.store = store
        view.showFullscreen = onFullscreen
        view.hideFullscreen = onHideFullscreen
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.store = store
        nsView.refreshTouchBar()
    }
}

/// Copy selected photo files to macOS pasteboard (Finder-compatible Cmd+C)
private func copySelectedFilesToPasteboard(store: PhotoStore) {
    let selectedPhotos = store.photos.filter { store.selectedPhotoIDs.contains($0.id) && !$0.isFolder && !$0.isParentFolder }
    guard !selectedPhotos.isEmpty else { return }

    var urls: [URL] = []
    for photo in selectedPhotos {
        urls.append(photo.jpgURL)
        if let rawURL = photo.rawURL {
            urls.append(rawURL)
        }
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])

    // Visual feedback
    let count = selectedPhotos.count
    let fileCount = urls.count
    print("📋 [COPY] \(count)장 (\(fileCount)파일) 클립보드에 복사됨")
}

class KeyCaptureView: NSView {
    var showFullscreen: (() -> Void)?
    var hideFullscreen: (() -> Void)?
    var store: PhotoStore? {
        didSet { touchBarProvider.store = store }
    }
    private var quickLookDataSource: QuickLookDataSource?
    private let touchBarProvider = TouchBarProvider()

    override var acceptsFirstResponder: Bool { true }

    // MARK: - NSTouchBar

    override func makeTouchBar() -> NSTouchBar? {
        touchBarProvider.store = store
        return touchBarProvider.makeTouchBar()
    }

    /// Call to refresh TouchBar when selection changes
    func refreshTouchBar() {
        self.touchBar = nil  // forces re-creation
    }

    // MARK: - Quick Look via QLPreviewPanel

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookDataSource
        panel.delegate = quickLookDataSource
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Panel control ended
    }

    private func toggleQuickLook() {
        guard let store = store, let photo = store.selectedPhoto else { return }

        if quickLookDataSource == nil {
            quickLookDataSource = QuickLookDataSource()
        }
        quickLookDataSource?.currentURL = photo.jpgURL

        if let panel = QLPreviewPanel.shared() {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                panel.makeKeyAndOrderFront(nil)
                panel.reloadData()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let store = store else {
            super.keyDown(with: event)
            return
        }

        let chars = event.charactersIgnoringModifiers ?? ""
        let keyCode = event.keyCode
        let hasCmd = event.modifierFlags.contains(.command)
        let hasShift = event.modifierFlags.contains(.shift)

        // Helper: match by chars OR keyCode for Korean IME compatibility
        func charOrCode(_ c: String, _ code: UInt16) -> Bool {
            return chars == c || keyCode == code
        }

        // Esc → 전체화면 닫기
        if keyCode == 53 {
            hideFullscreen?()
            return
        }

        // Cmd shortcuts
        if hasCmd {
            if chars == "=" || chars == "+" || keyCode == 24 {
                NotificationCenter.default.post(name: .zoomIn, object: nil)
                return
            } else if chars == "-" || keyCode == 27 {
                NotificationCenter.default.post(name: .zoomOut, object: nil)
                return
            } else if charOrCode("a", 0) {
                store.selectAll()
                return
            } else if charOrCode("d", 2) {
                store.deselectAll()
                return
            } else if chars == "/" || chars == "?" || keyCode == 44 {
                store.showShortcutHelp = true
                return
            } else if charOrCode("z", 6) {
                store.undo()
                return
            } else if charOrCode("f", 3) {
                // Cmd+F: 전체화면 토글 (진입/복귀)
                showFullscreen?()
                return
            } else if keyCode == 36 { // Cmd+Enter → 전체화면 닫기
                hideFullscreen?()
                return
            } else if charOrCode("c", 8) {
                // Cmd+C: Copy selected files to clipboard (Finder-compatible)
                copySelectedFilesToPasteboard(store: store)
                return
            }
        }

        // Color labels: 6=빨강, 7=노랑, 8=초록, 9=파랑
        if charOrCode("6", 22) {
            if store.selectionCount > 1 { store.setColorLabelForSelected(.red) }
            else if let id = store.selectedPhotoID { store.setColorLabel(.red, for: id) }
            return
        } else if charOrCode("7", 26) {
            if store.selectionCount > 1 { store.setColorLabelForSelected(.yellow) }
            else if let id = store.selectedPhotoID { store.setColorLabel(.yellow, for: id) }
            return
        } else if charOrCode("8", 28) {
            if store.selectionCount > 1 { store.setColorLabelForSelected(.green) }
            else if let id = store.selectedPhotoID { store.setColorLabel(.green, for: id) }
            return
        } else if charOrCode("9", 25) {
            if store.selectionCount > 1 { store.setColorLabelForSelected(.blue) }
            else if let id = store.selectedPhotoID { store.setColorLabel(.blue, for: id) }
            return
        }

        // Rating - skip if folder/parent selected
        let selectedIsFolder = store.selectedPhoto?.isFolder == true || store.selectedPhoto?.isParentFolder == true

        if charOrCode("1", 18) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(1) }
            else if let id = store.selectedPhotoID { store.setRating(1, for: id) }
            return
        } else if charOrCode("2", 19) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(2) }
            else if let id = store.selectedPhotoID { store.setRating(2, for: id) }
            return
        } else if charOrCode("3", 20) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(3) }
            else if let id = store.selectedPhotoID { store.setRating(3, for: id) }
            return
        } else if charOrCode("4", 21) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(4) }
            else if let id = store.selectedPhotoID { store.setRating(4, for: id) }
            return
        } else if charOrCode("5", 23) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(5) }
            else if let id = store.selectedPhotoID { store.setRating(5, for: id) }
            return
        } else if charOrCode("0", 29) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(0) }
            else if let id = store.selectedPhotoID { store.setRating(0, for: id) }
            return
        }

        // === 비디오 재생 단축키 ===
        // 프리뷰가 보이는 레이아웃(gridPreview, filmstrip)에서만 비디오 단축키 활성화
        let videoPreviewVisible = store.layoutMode == .gridPreview || store.layoutMode == .filmstrip
        let isVideo = videoPreviewVisible && store.selectedPhoto?.isVideoFile == true
        let videoMgr = VideoPlayerManager.shared

        // Spacebar: 비디오면 재생/일시정지, 아니면 별점 5점 토글
        if chars == " " || keyCode == 49 {
            if isVideo && videoMgr.isReady {
                videoMgr.togglePlayPause()
                return
            }
            guard !selectedIsFolder else { return }
            let ids = store.selectionCount > 1 ? store.selectedPhotoIDs : (store.selectedPhotoID.map { [$0] } ?? [])
            for id in ids {
                if let i = store.photos.firstIndex(where: { $0.id == id }) {
                    let newRating = store.photos[i].rating == 5 ? 0 : 5
                    store.setRating(newRating, for: id)
                }
            }
            return
        }

        // J/K/L: 비디오 스크러빙 (NLE 편집기 표준)
        if isVideo && videoMgr.isReady {
            if charOrCode("j", 38) && !hasCmd { videoMgr.jklScrub(key: "j"); return }
            if charOrCode("k", 40) && !hasCmd { videoMgr.jklScrub(key: "k"); return }
            if charOrCode("l", 37) && !hasCmd { videoMgr.jklScrub(key: "l"); return }
            // S: 현재 프레임 스냅샷 저장
            if charOrCode("s", 1) && !hasCmd { videoMgr.exportCurrentFrame(); return }
        }

        // G Select: instantly copy to Google Drive
        if charOrCode("g", 5) && !hasCmd {
            let gService = GSelectService.shared
            if gService.isActive {
                if store.selectionCount > 1 {
                    let selected = store.multiSelectedPhotos
                    gService.gSelectMultiple(photos: selected)
                    let indices = selected.compactMap { store.idx($0.id) }
                    for i in indices { store.photos[i].isGSelected = true }
                } else if let id = store.selectedPhotoID, let photo = store.selectedPhoto {
                    let wasGSelected = photo.isGSelected
                    gService.toggleGSelect(photo: photo)
                    if let i = store.idx(id) { store.photos[i].isGSelected = !wasGSelected }
                }
                store.invalidateCache()
            } else {
                // Not active - show setup
                gService.requestStartSession()
            }
            return
        }

        // H: Toggle histogram overlay
        if charOrCode("h", 4) && !hasCmd {
            NotificationCenter.default.post(name: .toggleHistogram, object: nil)
            return
        }

        // I: Toggle metadata overlay (nomacs-style)
        if charOrCode("i", 34) && !hasCmd {
            store.toggleMetadataOverlay()
            return
        }

        // D: Dual viewer toggle
        if charOrCode("d", 2) && !hasCmd {
            store.showDualViewer.toggle()
            return
        }

        // C: Compare mode (2~4 photos selected)
        if charOrCode("c", 8) && !hasCmd {
            if store.selectionCount >= 2 && store.selectionCount <= 4 {
                store.showCompare = true
            }
            return
        }

        // P: Quick Look preview
        if charOrCode("p", 35) && !hasCmd {
            toggleQuickLook()
            return
        }

        // ?, /: Shortcut help (non-Cmd)
        if (chars == "?" || chars == "/" || keyCode == 44) && !hasCmd {
            store.showShortcutHelp = true
            return
        }

        // Arrow keys, Enter, Delete (keyCode-only)
        store.isKeyRepeat = event.isARepeat

        // 비디오 재생 중: ←/→ = 프레임 스텝 또는 5초 이동
        if isVideo && videoMgr.isReady && (keyCode == 123 || keyCode == 124) {
            if videoMgr.isPlaying {
                // 재생 중이면 5초 점프
                if keyCode == 123 { videoMgr.seekRelative(seconds: -5) }
                else { videoMgr.seekRelative(seconds: 5) }
            } else {
                // 일시정지 중이면 프레임 스텝
                if keyCode == 123 { videoMgr.stepBackward() }
                else { videoMgr.stepForward() }
            }
            return
        }

        switch keyCode {
        case 123: store.selectLeft(shift: hasShift, cmd: hasCmd)    // <-
        case 124: store.selectRight(shift: hasShift, cmd: hasCmd)   // ->
        case 125: store.selectDown(shift: hasShift, cmd: hasCmd)    // down
        case 126: store.selectUp(shift: hasShift, cmd: hasCmd)      // up
        case 36:  // Enter
            if hasCmd {
                // Cmd+Enter: toggle fullscreen filmstrip
                let newMode: LayoutMode = store.layoutMode == .gridPreview ? .filmstrip : .gridPreview
                store.setLayoutMode(newMode)
                if newMode == .filmstrip {
                    // Hide folder tree in filmstrip fullscreen
                    store.showFolderBrowser = false
                } else {
                    store.showFolderBrowser = true
                }
                NSApp.keyWindow?.toggleFullScreen(nil)
            } else {
                // Enter: open folder/parent folder
                if let photo = store.selectedPhoto {
                    if photo.isParentFolder, let parent = store.folderURL?.deletingLastPathComponent() {
                        store.loadFolder(parent, restoreRatings: true)
                    } else if photo.isFolder {
                        store.loadFolder(photo.jpgURL, restoreRatings: true)
                    }
                }
            }
        case 51, 117:  // Backspace / Delete
            guard !store.selectedPhotoIDs.isEmpty else { break }
            let selectedPhotos = store.photos.filter { store.selectedPhotoIDs.contains($0.id) && !$0.isFolder && !$0.isParentFolder }
            guard !selectedPhotos.isEmpty else { break }

            let deleteOriginal = UserDefaults.standard.bool(forKey: "deleteOriginalFile")
            if deleteOriginal {
                // Show serious warning
                store.pendingDeleteIDs = store.selectedPhotoIDs
                store.showDeleteOriginalConfirm = true
            } else {
                // Just remove from thumbnail list (no file deletion)
                store.removePhotosFromList(ids: store.selectedPhotoIDs)
            }
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Quick Look Data Source

class QuickLookDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var currentURL: URL?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return currentURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        return currentURL.map { $0 as NSURL }
    }
}

// MARK: - Disabled Button Guide

/// Shows an alert explaining why a button is disabled and offers to fix it
struct DisabledGuide {
    /// Show alert for disabled AI features
    static func showAIDisabled() {
        let alert = NSAlert()
        alert.messageText = "AI 기능을 사용하려면"
        alert.informativeText = "AI 기능은 Pro 구독이 필요합니다.\nAPI 키가 설정되어 있지 않으면 설정에서 입력해주세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "닫기")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // macOS 14+: showSettingsWindow, macOS 13: showPreferencesWindow
            if #available(macOS 14, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else if #available(macOS 13, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            // Cmd+, 단축키로 직접 열기 (폴백)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if NSApp.windows.first(where: { $0.title.contains("설정") || $0.title.contains("Settings") }) == nil {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            }
        }
    }

    /// Show alert for compare mode
    static func showCompareDisabled(currentCount: Int) {
        let alert = NSAlert()
        alert.messageText = "비교 보기"
        alert.informativeText = "2~4장의 사진을 선택해야 비교할 수 있습니다.\n현재 \(currentCount)장 선택됨.\n\nCmd+클릭으로 여러 장을 선택하세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    /// Show alert for G Select not logged in
    static func showGSelectLoginNeeded() {
        let alert = NSAlert()
        alert.messageText = "Google Drive 로그인 필요"
        alert.informativeText = "G셀렉을 사용하려면 Google 계정으로 로그인해야 합니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "로그인")
        alert.addButton(withTitle: "닫기")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            GSelectService.shared.loginToGoogle()
        }
    }

    /// Show alert for analysis in progress
    static func showAnalysisInProgress() {
        let alert = NSAlert()
        alert.messageText = "분석 진행 중"
        alert.informativeText = "현재 분석이 진행 중입니다. 완료 후 다시 시도해주세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    /// Show alert for correction in progress
    static func showCorrectionInProgress() {
        let alert = NSAlert()
        alert.messageText = "보정 진행 중"
        alert.informativeText = "현재 보정 작업이 진행 중입니다. 완료될 때까지 기다려주세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    /// Show alert for no photos loaded
    static func showNoPhotos() {
        let alert = NSAlert()
        alert.messageText = "사진이 없습니다"
        alert.informativeText = "먼저 사진 폴더를 열어주세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "폴더 열기")
        alert.addButton(withTitle: "닫기")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Trigger folder open
            NotificationCenter.default.post(name: .init("openFolder"), object: nil)
        }
    }
}

// MARK: - Startup View

struct StartupView: View {
    @EnvironmentObject var store: PhotoStore
    @State private var hoveredCard: String?
    @State private var showRawMatchResult: Bool = false
    @State private var rawMatchResult: RawMatchResult = RawMatchResult()
    @State private var showFileSyncPopup: Bool = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.linearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text("PickShot")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                    }
                    Text("초고속 사진 선별 도구")
                        .font(.system(size: AppTheme.fontSubhead))
                        .foregroundColor(.secondary)
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.2")")
                        .font(.system(size: AppTheme.fontCaption, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                }

                Spacer().frame(height: 40)

                // === TOP: File Sync Button ===
                Button(action: { showFileSyncPopup = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                            .font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("JPG · RAW 파일 연동하기")
                                .font(.system(size: 15, weight: .bold))
                            Text("픽샷 셀렉 가져오기 · JPG,RAW 매칭 복사")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .foregroundColor(.white)
                    .frame(width: 380, height: 60)
                    .background(
                        LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
                }
                .buttonStyle(.plain)

                Spacer().frame(height: 28)

                // === Mode buttons ===
                HStack(spacing: 16) {
                    // Viewer
                    Button(action: {
                        store.startupMode = .viewer
                        store.shouldOpenFolderBrowser = true
                        let lastPath = UserDefaults.standard.string(forKey: "lastFolderPath") ?? ""
                        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                        if !lastPath.isEmpty && FileManager.default.fileExists(atPath: lastPath) {
                            store.loadFolder(URL(fileURLWithPath: lastPath), restoreRatings: true)
                        } else {
                            store.loadFolder(desktop, restoreRatings: true)
                        }
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("뷰어")
                                    .font(.system(size: 14, weight: .bold))
                                Text("사진 선별 · 분류 · 내보내기")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        .foregroundColor(.white)
                        .frame(width: 182, height: 56)
                        .background(
                            LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .blue.opacity(0.25), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)

                    // Tethering
                    Button(action: { store.startupMode = .tethering }) {
                        HStack(spacing: 10) {
                            Image(systemName: "cable.connector")
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("테더링")
                                    .font(.system(size: 14, weight: .bold))
                                HStack(spacing: 4) {
                                    Text("카메라 연결 · 실시간 촬영")
                                        .font(.system(size: 10))
                                    Text("Soon")
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.white.opacity(0.2))
                                        .cornerRadius(3)
                                }
                                .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 182, height: 56)
                        .background(
                            LinearGradient(colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
                Text("\u{00A9} 2026 PickShot")
                    .font(.system(size: AppTheme.fontMicro))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.bottom, AppTheme.space20)
            }
        }
        .sheet(isPresented: $showRawMatchResult) {
            RawMatchResultView(result: rawMatchResult, isPresented: $showRawMatchResult)
        }
        .sheet(isPresented: $showFileSyncPopup) {
            FileSyncPopupView(store: store, isPresented: $showFileSyncPopup, showRawMatchResult: $showRawMatchResult, rawMatchResult: $rawMatchResult)
        }
    }

    private func performRawMatching() {
        // Step 1: Select JPG folder
        let jpgPanel = NSOpenPanel()
        jpgPanel.title = "JPG 폴더 선택"
        jpgPanel.message = "JPG 파일이 있는 폴더를 선택하세요"
        jpgPanel.canChooseDirectories = true
        jpgPanel.canChooseFiles = false
        guard jpgPanel.runModal() == .OK, let jpgFolder = jpgPanel.url else { return }

        // Step 2: Select RAW folder
        let rawPanel = NSOpenPanel()
        rawPanel.title = "RAW 폴더 선택"
        rawPanel.message = "매칭할 RAW 파일이 있는 폴더를 선택하세요"
        rawPanel.canChooseDirectories = true
        rawPanel.canChooseFiles = false
        guard rawPanel.runModal() == .OK, let rawFolder = rawPanel.url else { return }

        // Step 3: Select destination
        let destPanel = NSOpenPanel()
        destPanel.title = "저장할 폴더 선택"
        destPanel.message = "매칭된 파일을 복사할 폴더를 선택하세요"
        destPanel.canChooseDirectories = true
        destPanel.canChooseFiles = false
        destPanel.canCreateDirectories = true
        guard destPanel.runModal() == .OK, let destFolder = destPanel.url else { return }

        // Step 4: Match and copy
        let fm = FileManager.default
        let rawExts = FileMatchingService.rawExtensions

        // Get JPG file names
        let jpgFiles = (try? fm.contentsOfDirectory(at: jpgFolder, includingPropertiesForKeys: nil)) ?? []
        let jpgItems = jpgFiles.filter { ["jpg","jpeg"].contains($0.pathExtension.lowercased()) }
        let jpgNames = Set(jpgItems.map { $0.deletingPathExtension().lastPathComponent })

        // Get RAW file names
        let rawFiles = (try? fm.contentsOfDirectory(at: rawFolder, includingPropertiesForKeys: nil)) ?? []
        let rawItems = rawFiles.filter { rawExts.contains($0.pathExtension.lowercased()) }
        let rawNames = Set(rawItems.map { $0.deletingPathExtension().lastPathComponent })

        // Find matches and mismatches
        var matchedNames: [String] = []
        var jpgOnly: [String] = []
        var rawOnly: [String] = []
        var copyFailed: [(name: String, reason: String)] = []

        // Create JPG + RAW subdirectories
        let jpgDest = destFolder.appendingPathComponent("JPG")
        let rawDest = destFolder.appendingPathComponent("RAW")
        try? fm.createDirectory(at: jpgDest, withIntermediateDirectories: true)
        try? fm.createDirectory(at: rawDest, withIntermediateDirectories: true)

        // Process matches
        for jpgFile in jpgItems {
            let name = jpgFile.deletingPathExtension().lastPathComponent
            if rawNames.contains(name) {
                matchedNames.append(name)
                // Copy JPG
                let dest = jpgDest.appendingPathComponent(jpgFile.lastPathComponent)
                do {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: jpgFile, to: dest)
                } catch {
                    copyFailed.append((name: jpgFile.lastPathComponent, reason: error.localizedDescription))
                }
                // Copy RAW
                if let rawFile = rawItems.first(where: { $0.deletingPathExtension().lastPathComponent == name }) {
                    let rdest = rawDest.appendingPathComponent(rawFile.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: rdest.path) { try fm.removeItem(at: rdest) }
                        try fm.copyItem(at: rawFile, to: rdest)
                    } catch {
                        copyFailed.append((name: rawFile.lastPathComponent, reason: error.localizedDescription))
                    }
                }
            } else {
                jpgOnly.append(name)
            }
        }

        // RAW only (no matching JPG)
        for rawFile in rawItems {
            let name = rawFile.deletingPathExtension().lastPathComponent
            if !jpgNames.contains(name) {
                rawOnly.append(name)
            }
        }

        rawMatchResult = RawMatchResult(
            jpgCount: jpgItems.count,
            rawCount: rawItems.count,
            matchedCount: matchedNames.count,
            jpgOnlyNames: jpgOnly,
            rawOnlyNames: rawOnly,
            failedNames: copyFailed,
            destFolder: destFolder
        )
        showRawMatchResult = true
    }
}

// MARK: - File Sync Popup

struct FileSyncPopupView: View {
    let store: PhotoStore
    @Binding var isPresented: Bool
    @Binding var showRawMatchResult: Bool
    @Binding var rawMatchResult: RawMatchResult

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                    .font(.system(size: 32))
                    .foregroundStyle(.linearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("파일 연동하기")
                    .font(.system(size: 18, weight: .bold))
                Text("셀렉 파일을 가져오거나 JPG와 RAW를 매칭합니다")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Divider()

            // Two buttons
            HStack(spacing: 16) {
                // PickShot file import
                Button(action: { importPickshotFile() }) {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.arrow.up")
                            .font(.system(size: 28))
                        Text(".pickshot 파일\n가져오기")
                            .font(.system(size: 13, weight: .semibold))
                            .multilineTextAlignment(.center)
                        Text("셀렉 파일을\nRAW 폴더에 적용합니다")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white)
                    .frame(width: 180, height: 160)
                    .background(
                        LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                // JPG + RAW matching
                Button(action: { performRawMatch() }) {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 28))
                        Text("JPG, RAW\n매칭 복사")
                            .font(.system(size: 13, weight: .semibold))
                            .multilineTextAlignment(.center)
                        Text("JPG와 같은 이름의 RAW를\n찾아서 함께 복사합니다")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white)
                    .frame(width: 180, height: 160)
                    .background(
                        LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button("닫기") { isPresented = false }
                .foregroundColor(.secondary)
        }
        .padding(28)
        .frame(width: 440)
    }

    private func importPickshotFile() {
        isPresented = false

        // Step 1: Select .pickshot file
        let panel = NSOpenPanel()
        panel.title = ".pickshot 파일 선택"
        panel.message = ".pickshot 파일을 선택하세요"
        panel.allowedContentTypes = [.init(filenameExtension: "pickshot")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let pickshotURL = panel.url else { return }

        // Step 2: Select RAW folder
        let rawPanel = NSOpenPanel()
        rawPanel.title = "RAW 폴더 선택"
        rawPanel.message = "셀렉을 적용할 RAW/JPG 파일이 있는 폴더를 선택하세요"
        rawPanel.canChooseDirectories = true
        rawPanel.canChooseFiles = false
        guard rawPanel.runModal() == .OK, let rawFolder = rawPanel.url else { return }

        // Load folder and apply pickshot
        store.startupMode = .viewer
        store.shouldOpenFolderBrowser = true
        store.loadFolder(rawFolder, restoreRatings: true)

        // Wait for folder to load, then apply
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let result = PickshotFileService.applyPickshotFile(url: pickshotURL, to: &store.photos, photoIndex: store._photoIndex)
            if let result = result {
                store.photosVersion += 1
                store.lastImportResult = result
                store.showImportResult = true
            }
        }
    }

    private func performRawMatch() {
        isPresented = false

        // Step 1: JPG folder
        let jpgPanel = NSOpenPanel()
        jpgPanel.title = "JPG 폴더 선택"
        jpgPanel.message = "JPG 파일이 있는 폴더를 선택하세요"
        jpgPanel.canChooseDirectories = true
        jpgPanel.canChooseFiles = false
        guard jpgPanel.runModal() == .OK, let jpgFolder = jpgPanel.url else { return }

        // Step 2: RAW folder
        let rawPanel = NSOpenPanel()
        rawPanel.title = "RAW 폴더 선택"
        rawPanel.message = "매칭할 RAW 파일이 있는 폴더를 선택하세요"
        rawPanel.canChooseDirectories = true
        rawPanel.canChooseFiles = false
        guard rawPanel.runModal() == .OK, let rawFolder = rawPanel.url else { return }

        // Step 3: Destination
        let destPanel = NSOpenPanel()
        destPanel.title = "저장할 폴더 선택"
        destPanel.message = "매칭된 파일을 복사할 폴더를 선택하세요"
        destPanel.canChooseDirectories = true
        destPanel.canChooseFiles = false
        destPanel.canCreateDirectories = true
        guard destPanel.runModal() == .OK, let destFolder = destPanel.url else { return }

        // Match and copy (reuse StartupView logic)
        let fm = FileManager.default
        let rawExts = FileMatchingService.rawExtensions

        let jpgFiles = (try? fm.contentsOfDirectory(at: jpgFolder, includingPropertiesForKeys: nil)) ?? []
        let jpgItems = jpgFiles.filter { ["jpg","jpeg"].contains($0.pathExtension.lowercased()) }
        let jpgNames = Set(jpgItems.map { $0.deletingPathExtension().lastPathComponent })

        let rawFiles = (try? fm.contentsOfDirectory(at: rawFolder, includingPropertiesForKeys: nil)) ?? []
        let rawItems = rawFiles.filter { rawExts.contains($0.pathExtension.lowercased()) }
        let rawNames = Set(rawItems.map { $0.deletingPathExtension().lastPathComponent })

        var matchedNames: [String] = []
        var jpgOnly: [String] = []
        var rawOnly: [String] = []
        var copyFailed: [(name: String, reason: String)] = []

        let jpgDest = destFolder.appendingPathComponent("JPG")
        let rawDest = destFolder.appendingPathComponent("RAW")
        try? fm.createDirectory(at: jpgDest, withIntermediateDirectories: true)
        try? fm.createDirectory(at: rawDest, withIntermediateDirectories: true)

        for jpgFile in jpgItems {
            let name = jpgFile.deletingPathExtension().lastPathComponent
            if rawNames.contains(name) {
                matchedNames.append(name)
                let dest = jpgDest.appendingPathComponent(jpgFile.lastPathComponent)
                do {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: jpgFile, to: dest)
                } catch { copyFailed.append((name: jpgFile.lastPathComponent, reason: error.localizedDescription)) }

                if let rawFile = rawItems.first(where: { $0.deletingPathExtension().lastPathComponent == name }) {
                    let rdest = rawDest.appendingPathComponent(rawFile.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: rdest.path) { try fm.removeItem(at: rdest) }
                        try fm.copyItem(at: rawFile, to: rdest)
                    } catch { copyFailed.append((name: rawFile.lastPathComponent, reason: error.localizedDescription)) }
                }
            } else { jpgOnly.append(name) }
        }

        for rawFile in rawItems {
            let name = rawFile.deletingPathExtension().lastPathComponent
            if !jpgNames.contains(name) { rawOnly.append(name) }
        }

        rawMatchResult = RawMatchResult(
            jpgCount: jpgItems.count, rawCount: rawItems.count, matchedCount: matchedNames.count,
            jpgOnlyNames: jpgOnly, rawOnlyNames: rawOnly, failedNames: copyFailed, destFolder: destFolder
        )
        showRawMatchResult = true
    }
}

// MARK: - RAW Match Result

struct RawMatchResult {
    var jpgCount: Int = 0
    var rawCount: Int = 0
    var matchedCount: Int = 0
    var jpgOnlyNames: [String] = []
    var rawOnlyNames: [String] = []
    var failedNames: [(name: String, reason: String)] = []
    var destFolder: URL? = nil
}

struct RawMatchResultView: View {
    let result: RawMatchResult
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)
                Text("JPG, RAW 매칭 완료")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }

            Divider()

            // Summary
            HStack(spacing: 24) {
                VStack {
                    Text("\(result.jpgCount)")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.blue)
                    Text("JPG")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                VStack {
                    Text("\(result.rawCount)")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                    Text("RAW")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                VStack {
                    Text("\(result.matchedCount)")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                    Text("매칭 성공")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            // JPG only (no RAW)
            if !result.jpgOnlyNames.isEmpty {
                DisclosureGroup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(result.jpgOnlyNames, id: \.self) { name in
                                Text(name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 80)
                } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                            .font(.system(size: 11))
                        Text("JPG만 있음 (RAW 없음): \(result.jpgOnlyNames.count)장")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.yellow)
                    }
                }
            }

            // RAW only (no JPG)
            if !result.rawOnlyNames.isEmpty {
                DisclosureGroup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(result.rawOnlyNames, id: \.self) { name in
                                Text(name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 80)
                } label: {
                    HStack {
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        Text("RAW만 있음 (JPG 없음): \(result.rawOnlyNames.count)장")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Copy failures
            if !result.failedNames.isEmpty {
                DisclosureGroup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(result.failedNames.indices, id: \.self) { i in
                                HStack {
                                    Text(result.failedNames[i].name)
                                        .font(.system(size: 11, design: .monospaced))
                                    Text(result.failedNames[i].reason)
                                        .font(.system(size: 10))
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 60)
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 11))
                        Text("복사 실패: \(result.failedNames.count)장")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                    }
                }
            }

            Divider()

            // Actions
            HStack {
                if let dest = result.destFolder {
                    Button("폴더 열기") {
                        NSWorkspace.shared.open(dest)
                    }
                    .help("복사된 파일 폴더 열기")
                }
                Spacer()
                Button("확인") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

struct StartupCard: View {
    let icon: String; let title: String; let subtitle: String; let color: Color; let isHovered: Bool; var comingSoon: Bool = false
    var body: some View {
        VStack(spacing: AppTheme.space12) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundColor(comingSoon ? .secondary : color)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(comingSoon ? .secondary : .primary)
            Text(subtitle)
                .font(.system(size: AppTheme.fontBody))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if comingSoon {
                Text("Coming Soon")
                    .font(.system(size: AppTheme.fontMicro, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .frame(width: 120, height: 120)
        .padding(AppTheme.space16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered && !comingSoon ? color.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovered && !comingSoon ? color.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .scaleEffect(isHovered && !comingSoon ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Breadcrumb Path View

struct BreadcrumbPathView: View {
    let url: URL
    let store: PhotoStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(pathComponents.indices, id: \.self) { i in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                Button(action: {
                    let targetURL = buildURL(upTo: i)
                    let systemPaths = ["/Volumes", "/System", "/Library", "/usr", "/private"]
                    let isSystem = systemPaths.contains(targetURL.path) || targetURL.path == "/"
                    if !isSystem && FileManager.default.fileExists(atPath: targetURL.path) {
                        store.startupMode = .viewer
                        store.loadFolder(targetURL, restoreRatings: true)
                    }
                }) {
                    Text(pathComponents[i])
                        .font(.system(size: AppTheme.fontSubhead, weight: i == pathComponents.count - 1 ? .bold : .medium))
                        .foregroundColor(i == pathComponents.count - 1 ? Color(red: 0.4, green: 0.85, blue: 1.0) : .secondary.opacity(0.7))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
        .help(url.path)
    }

    private var pathComponents: [String] {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) {
            let relative = String(path.dropFirst(home.count))
            let parts = relative.split(separator: "/").map(String.init)
            return ["~"] + parts
        }
        return url.pathComponents.filter { $0 != "/" }
    }

    private func buildURL(upTo index: Int) -> URL {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) {
            if index == 0 { return URL(fileURLWithPath: home) }
            let relative = String(path.dropFirst(home.count))
            let parts = relative.split(separator: "/").map(String.init)
            let subParts = Array(parts.prefix(index))
            return URL(fileURLWithPath: home + "/" + subParts.joined(separator: "/"))
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        let subParts = Array(parts.prefix(index + 1))
        return URL(fileURLWithPath: "/" + subParts.joined(separator: "/"))
    }
}

// MARK: - Fullscreen Photo View (Cmd+F)

struct FullscreenView: View {
    @EnvironmentObject var store: PhotoStore
    @Binding var isPresented: Bool
    @State private var showInfo: Bool = true
    @State private var infoTimer: DispatchWorkItem?

    private var currentPhoto: PhotoItem? {
        guard let id = store.selectedPhotoID,
              let idx = store._photoIndex[id],
              idx < store.photos.count else { return nil }
        return store.photos[idx]
    }

    private var photoCounter: (index: Int, total: Int)? {
        guard let photo = currentPhoto else { return nil }
        let filtered = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        guard let idx = filtered.firstIndex(where: { $0.id == photo.id }) else { return nil }
        return (idx + 1, filtered.count)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 뷰어 엔진 그대로 사용 — 클릭하면 확대/선명하게
            if let photo = currentPhoto {
                PhotoPreviewView(photo: photo)
                    .overlay(
                        Group {
                            if photo.isSpacePicked {
                                RoundedRectangle(cornerRadius: 0).strokeBorder(Color.red, lineWidth: 12).allowsHitTesting(false)
                            } else if photo.rating > 0 {
                                RoundedRectangle(cornerRadius: 0).strokeBorder(Color.yellow.opacity(0.7), lineWidth: 8).allowsHitTesting(false)
                            }
                        }
                    )
            }

            // Top: 카운터 + 파일명 + 닫기
            VStack {
                HStack {
                    if let counter = photoCounter {
                        Text("\(counter.index) / \(counter.total)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(8).background(Color.black.opacity(0.5)).cornerRadius(6).padding(12)
                    }
                    Spacer()
                    if showInfo, let photo = currentPhoto {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(photo.jpgURL.lastPathComponent).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                            if let q = photo.quality, q.isAnalyzed {
                                HStack(spacing: 4) {
                                    Circle().fill(q.overallGrade == .good ? Color.green : q.overallGrade == .average ? Color.orange : Color.red).frame(width: 8, height: 8)
                                    Text("\(q.score)점").font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                                }
                            }
                        }
                        .padding(8).background(Color.black.opacity(0.5)).cornerRadius(6)
                    }
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 24)).foregroundColor(.white.opacity(0.6))
                    }.buttonStyle(.plain).padding(12).help("Esc 또는 Cmd+Enter")
                }
                Spacer()
            }

            // Bottom: 필름스트립 + 바
            VStack(spacing: 0) {
                Spacer()
                fullscreenFilmstrip
                fullscreenBottomBar
            }
        }
        .onChange(of: store.selectedPhotoID) { _ in flashInfo() }
    }

    // MARK: - Bottom Bar

    private var fullscreenBottomBar: some View {
        HStack(spacing: 0) {
            // Photo counter (left)
            if let counter = photoCounter {
                Text("\(counter.index) / \(counter.total)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 90, alignment: .leading)
            } else {
                Spacer().frame(width: 90)
            }

            Spacer()

            // Star rating buttons + SP button (center)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { rating in
                    Button(action: { setRating(rating) }) {
                        HStack(spacing: 3) {
                            Image(systemName: isRatingActive(rating) ? "star.fill" : "star")
                                .font(.system(size: 14))
                            Text("\(rating)")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(isRatingActive(rating) ? .black : .white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isRatingActive(rating) ? Color.yellow : Color.white.opacity(0.15))
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 24)
                    .padding(.horizontal, 4)

                // SP button
                Button(action: { toggleSP() }) {
                    Text("SP")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(isSPActive ? .white : .white.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSPActive ? Color.red : Color.white.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Hint (right)
            Text("⌘↩ 닫기")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
            .offset(y: -20)
        )
    }

    // MARK: - Filmstrip

    private var fullscreenFilmstrip: some View {
        let photos = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        let currentIdx = photos.firstIndex(where: { $0.id == store.selectedPhotoID }) ?? 0
        let start = max(0, currentIdx - 3)
        let end = min(photos.count - 1, currentIdx + 3)

        return HStack {
            Spacer()
            HStack(spacing: 3) {
                if start <= end {
                    ForEach(start...end, id: \.self) { i in
                        let photo = photos[i]
                        let isCurrent = i == currentIdx
                        ZStack {
                            if let thumb = ThumbnailCache.shared.get(photo.jpgURL) {
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: isCurrent ? 60 : 50, height: isCurrent ? 45 : 38).clipped()
                            } else {
                                Rectangle().fill(Color.gray.opacity(0.3)).frame(width: isCurrent ? 60 : 50, height: isCurrent ? 45 : 38)
                            }
                            if photo.isSpacePicked {
                                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.red, lineWidth: 2)
                                    .frame(width: isCurrent ? 60 : 50, height: isCurrent ? 45 : 38)
                            }
                        }
                        .cornerRadius(3)
                        .opacity(isCurrent ? 1.0 : 0.5)
                        .overlay(isCurrent ? RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 2) : nil)
                        .onTapGesture { store.selectPhoto(photo.id, cmdKey: false) }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.5)).cornerRadius(8)
            .padding(.trailing, 16).padding(.bottom, 4)
        }
    }

    private func isRatingActive(_ rating: Int) -> Bool {
        currentPhoto?.rating == rating
    }

    private var isSPActive: Bool {
        currentPhoto?.isSpacePicked == true
    }

    private func setRating(_ rating: Int) {
        guard let id = store.selectedPhotoID,
              let idx = store._photoIndex[id],
              idx < store.photos.count,
              !store.photos[idx].isFolder else { return }
        // Toggle off if same rating tapped again
        store.photos[idx].rating = store.photos[idx].rating == rating ? 0 : rating
    }

    private func toggleSP() {
        guard let id = store.selectedPhotoID,
              let idx = store._photoIndex[id],
              idx < store.photos.count,
              !store.photos[idx].isFolder else { return }
        store.photos[idx].isSpacePicked.toggle()
    }

    private func flashInfo() {
        showInfo = true
        infoTimer?.cancel()
        let item = DispatchWorkItem { showInfo = false }
        infoTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }
}

// FullscreenKeyHandler 제거 — 같은 윈도우에서 기존 KeyCaptureView가 처리

// MARK: - Pickshot Import Result Sheet (셀렉 가져오기 결과)

struct PickshotImportResultSheet: View {
    @ObservedObject var store: PhotoStore

    private var result: PickshotImportResult? { store.lastImportResult }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 헤더
            HStack {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                Text("셀렉 가져오기 결과")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if let r = result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 세션 정보
                        if !r.sourceFolderName.isEmpty {
                            infoRow(label: "원본 폴더", value: r.sourceFolderName, icon: "folder.fill", color: .blue)
                        }

                        // 통계 그리드
                        HStack(spacing: 12) {
                            statCard(title: "전체", value: "\(r.totalInFile)", color: .secondary)
                            statCard(title: "매칭", value: "\(r.matched.count)", color: .green)
                            statCard(title: "미매칭", value: "\(r.unmatched.count)", color: r.unmatched.isEmpty ? .secondary : .red)
                            statCard(title: "SP 셀렉", value: "\(r.matched.filter { $0.spacePick }.count)", color: .orange)
                            statCard(title: "코멘트", value: "\(r.commentsCount)", color: .purple)
                        }

                        // 코멘트 목록
                        if !r.commentDetails.isEmpty {
                            Divider()
                            Text("클라이언트 코멘트")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.orange)

                            ForEach(r.commentDetails.indices, id: \.self) { i in
                                let detail = r.commentDetails[i]
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "bubble.left.fill")
                                        .foregroundColor(.orange)
                                        .font(.system(size: 11))
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(detail.filename)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        ForEach(detail.comments.indices, id: \.self) { j in
                                            Text(detail.comments[j])
                                                .font(.system(size: 12))
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        // 미매칭 파일 목록
                        if !r.unmatched.isEmpty {
                            Divider()
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(r.unmatched, id: \.self) { name in
                                        Text(name)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.red)
                                    }
                                }
                            } label: {
                                Text("미매칭 파일 (\(r.unmatched.count))")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 400)
            } else {
                Text("가져오기 결과가 없습니다")
                    .foregroundColor(.secondary)
                    .padding()
            }

            Divider()

            // 하단 버튼
            HStack {
                Spacer()
                Button("닫기") {
                    store.showPickshotImportSheet = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 500)
        .frame(minHeight: 300)
    }

    private func infoRow(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 12))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .bold))
        }
    }

    private func statCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }
}
