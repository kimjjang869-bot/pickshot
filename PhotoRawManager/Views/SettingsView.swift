import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("일반", systemImage: "gear")
                }

            PreviewSettingsTab()
                .tabItem {
                    Label("미리보기", systemImage: "photo")
                }

            ExportSettingsTab()
                .tabItem {
                    Label("내보내기", systemImage: "square.and.arrow.up")
                }

            CacheSettingsTab()
                .tabItem {
                    Label("캐시", systemImage: "internaldrive")
                }

            PerformanceOptimizeTab()
                .tabItem {
                    Label("성능 최적화", systemImage: "bolt.circle")
                }

            ShortcutsSettingsTab()
                .tabItem {
                    Label("단축키", systemImage: "keyboard")
                }
        }
        .frame(width: 550, height: 520)
    }
}

// MARK: - Tab 1: 일반 (General)

struct GeneralSettingsTab: View {
    @AppStorage("autoOpenLastFolder") private var autoOpenLastFolder = true
    @AppStorage("showFileTypeBadge") private var showFileTypeBadge = true
    @AppStorage("showFileExtension") private var showFileExtension = true
    @AppStorage("deleteOriginalFile") private var deleteOriginalFile = false
    @AppStorage("windowStartSize") private var windowStartSize = "default"
    @AppStorage("appLanguage") private var appLanguage = "ko"
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("showNotifications") private var showNotifications = true
    @AppStorage("autoSaveOnExit") private var autoSaveOnExit = true
    @AppStorage("autoBackupEnabled") private var autoBackupEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("일반 설정")
                    .font(.title3.bold())
                Text("앱의 기본 동작과 외관을 설정합니다.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("시작 시 마지막 폴더 자동 열기", isOn: $autoOpenLastFolder)
                        Toggle("파일 확장자 배지 표시 (JPG, R+J, RAW 등)", isOn: $showFileTypeBadge)
                        Toggle("파일명에 확장자 표시 (IMG_9741.JPG)", isOn: $showFileExtension)

                        Divider()

                        Toggle("Backspace 키로 원본 파일 삭제 (휴지통)", isOn: $deleteOriginalFile)
                            .foregroundColor(deleteOriginalFile ? .red : .primary)
                        if deleteOriginalFile {
                            Text("⚠️ 주의: Backspace 키를 누르면 원본 파일이 휴지통으로 이동됩니다. 실수로 삭제할 수 있으니 주의하세요.")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }

                        Divider()

                        Picker("프로그램 시작 시 윈도우 크기", selection: $windowStartSize) {
                            Text("기본").tag("default")
                            Text("최대화").tag("maximized")
                            Text("마지막 크기").tag("lastSize")
                        }

                        Divider()

                        Picker("언어 설정", selection: $appLanguage) {
                            Text("한국어").tag("ko")
                            Text("English").tag("en")
                        }

                        Divider()

                        Picker("다크 모드", selection: $appearance) {
                            Text("시스템").tag("system")
                            Text("항상 다크").tag("dark")
                            Text("항상 라이트").tag("light")
                        }

                        Divider()

                        Toggle("알림 표시 (내보내기 완료, 분석 완료 등)", isOn: $showNotifications)

                        Divider()

                        Toggle("종료 시 별점/셀렉 자동 저장", isOn: $autoSaveOnExit)

                        Divider()

                        Toggle("메모리카드 자동 백업", isOn: $autoBackupEnabled)
                            .onChange(of: autoBackupEnabled) { enabled in
                                if enabled { MemoryCardBackupService.shared.startMonitoring() }
                                else { MemoryCardBackupService.shared.stopMonitoring() }
                            }
                        Text("메모리카드(SD/CF) 연결 시 자동으로 백업 폴더를 묻고 복사합니다")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(4)
                }

                // Apply / Reset buttons
                HStack {
                    Button("초기화") {
                        autoOpenLastFolder = true
                        showFileTypeBadge = true
                        showFileExtension = true
                        windowStartSize = "default"
                        appLanguage = "ko"
                        appearance = "system"
                        showNotifications = true
                        autoSaveOnExit = true
                        NotificationCenter.default.post(name: .init("SettingsChanged"), object: nil)
                    }
                    .help("모든 일반 설정을 기본값으로 초기화")

                    Spacer()

                    Button("적용") {
                        NotificationCenter.default.post(name: .init("SettingsChanged"), object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("변경된 설정을 즉시 적용합니다")
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
    }
}

// MARK: - Tab 2: 미리보기 (Preview)

struct PreviewSettingsTab: View {
    @AppStorage("previewMaxResolution") private var previewMaxResolution = "original"
    @AppStorage("rawPreviewMode") private var rawPreviewMode = "fast"
    @AppStorage("colorProfile") private var colorProfile = "display"
    @AppStorage("previewCacheSize") private var previewCacheSize = 20.0
    @AppStorage("defaultThumbnailSize") private var defaultThumbnailSize = 150.0
    @AppStorage("defaultViewMode") private var defaultViewMode = "gridPreview"
    @AppStorage("defaultSortMode") private var defaultSortMode = "captureTime"
    @AppStorage("showHistogramByDefault") private var showHistogramByDefault = false
    @AppStorage("showExifByDefault") private var showExifByDefault = false
    @AppStorage("enableTransition") private var enableTransition = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("미리보기 설정")
                    .font(.title3.bold())
                Text("이미지 미리보기와 표시 방식을 설정합니다.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                GroupBox("해상도 및 캐시") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("미리보기 해상도", selection: $previewMaxResolution) {
                            Text("원본").tag("original")
                            Text("4000px").tag("4000")
                            Text("3000px").tag("3000")
                            Text("2000px").tag("2000")
                            Text("1000px (저사양)").tag("1000")
                            Text("500px (초저사양)").tag("500")
                        }

                        Picker("RAW 미리보기 모드", selection: $rawPreviewMode) {
                            Text("빠른 미리보기 (내장 프리뷰)").tag("fast")
                            Text("픽쳐스타일 미리보기 (CIRAWFilter)").tag("ciraw")
                        }
                        .help("빠른 미리보기: 카메라 내장 JPEG 사용 (빠름, 픽쳐스타일 적용됨)\n픽쳐스타일 미리보기: CIRAWFilter 사용 (느림, 정밀한 색상)")

                        Picker("RAW 색공간", selection: $colorProfile) {
                            Text("모니터 맞춤 (자동)").tag("display")
                            Text("sRGB").tag("srgb")
                            Text("Display P3").tag("p3")
                            Text("Adobe RGB").tag("adobeRGB")
                        }
                        .help("CIRAWFilter 모드에서 사용할 출력 색공간")

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("미리보기 캐시 크기: \(Int(previewCacheSize))장")
                            Slider(value: $previewCacheSize, in: 5...300, step: 5)
                            if previewCacheSize > 50 {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(.orange)
                                    Text("50장 이상은 메모리 사용량이 크게 증가할 수 있습니다 (RAM 16GB 이상 권장)")
                                        .font(.system(size: 10)).foregroundColor(.orange)
                                }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("썸네일 기본 크기: \(Int(defaultThumbnailSize))px")
                            Slider(value: $defaultThumbnailSize, in: 50...300, step: 10)
                        }
                    }
                    .padding(4)
                }

                GroupBox("보기 옵션") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("기본 보기 모드", selection: $defaultViewMode) {
                            Text("그리드+미리보기").tag("gridPreview")
                            Text("필름스트립").tag("filmstrip")
                        }

                        Divider()

                        Picker("기본 정렬", selection: $defaultSortMode) {
                            Text("촬영시간").tag("captureTime")
                            Text("파일명").tag("fileName")
                            Text("별점").tag("rating")
                        }

                        Divider()

                        Toggle("히스토그램 기본 표시", isOn: $showHistogramByDefault)

                        Divider()

                        Toggle("EXIF 정보 기본 표시", isOn: $showExifByDefault)

                        Divider()

                        Toggle("이미지 전환 애니메이션", isOn: $enableTransition)
                    }
                    .padding(4)
                }

                Divider()
                HStack {
                    Button("되돌리기") {
                        previewMaxResolution = "original"
                        rawPreviewMode = "fast"
                        colorProfile = "display"
                        previewCacheSize = 20.0
                        defaultThumbnailSize = 150.0
                        defaultViewMode = "gridPreview"
                        defaultSortMode = "captureTime"
                        showHistogramByDefault = false
                        showExifByDefault = false
                        enableTransition = true
                        NotificationCenter.default.post(name: Notification.Name("SettingsChanged"), object: nil)
                    }
                    .help("모든 미리보기 설정을 기본값으로 초기화")

                    Spacer()

                    Button("확인") {
                        NotificationCenter.default.post(name: Notification.Name("SettingsChanged"), object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
    }
}

// MARK: - Tab 3: 내보내기 (Export)

struct ExportSettingsTab: View {
    @AppStorage("defaultExportPath") private var defaultExportPath = ""
    @AppStorage("autoLaunchLightroom") private var autoLaunchLightroom = false
    @AppStorage("createXMPSidecar") private var createXMPSidecar = true
    @AppStorage("openFinderAfterExport") private var openFinderAfterExport = true
    @AppStorage("exportFolderStructure") private var exportFolderStructure = "rawOnly"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("내보내기 설정")
                    .font(.title3.bold())
                Text("사진 내보내기의 기본 동작을 설정합니다.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("기본 내보내기 폴더")
                            Spacer()
                            Text(defaultExportPath.isEmpty ? "선택 안 됨" : abbreviatePath(defaultExportPath))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("폴더 선택") {
                                selectExportFolder()
                            }
                        }

                        Divider()

                        Toggle("Lightroom 자동 실행", isOn: $autoLaunchLightroom)

                        Divider()

                        Toggle("XMP 사이드카 생성", isOn: $createXMPSidecar)

                        Divider()

                        Toggle("내보내기 후 Finder 열기", isOn: $openFinderAfterExport)

                        Divider()

                        Picker("내보내기 시 하위 폴더 구조", selection: $exportFolderStructure) {
                            Text("RAW만").tag("rawOnly")
                            Text("RAW+JPG 분리").tag("separated")
                            Text("통합").tag("combined")
                        }
                    }
                    .padding(4)
                }

                Divider()
                HStack {
                    Button("되돌리기") {
                        defaultExportPath = ""
                        autoLaunchLightroom = false
                        createXMPSidecar = true
                        openFinderAfterExport = true
                        exportFolderStructure = "rawOnly"
                        NotificationCenter.default.post(name: Notification.Name("SettingsChanged"), object: nil)
                    }
                    .help("모든 내보내기 설정을 기본값으로 초기화")

                    Spacer()

                    Button("확인") {
                        NotificationCenter.default.post(name: Notification.Name("SettingsChanged"), object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
    }

    private func selectExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.message = "기본 내보내기 폴더를 선택하세요"
        if panel.runModal() == .OK, let url = panel.url {
            defaultExportPath = url.path
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Tab 4: AI 엔진 (AI Engine)

struct AIEngineSettingsTab: View {
    @AppStorage("aiClassifyEngine") private var aiClassifyEngine = "geminiFlash"
    @AppStorage("aiCorrectionEngine") private var aiCorrectionEngine = "claudeSonnet"
    @AppStorage("GeminiAPIKey") private var geminiAPIKey = ""
    @AppStorage("OpenAIAPIKey") private var openAIAPIKey = ""
    @AppStorage("aiBudgetUSD") private var aiBudgetUSD = "5.0"
    @AppStorage("aiConcurrency") private var aiConcurrency = 3

    @State private var claudeAPIKey: String = ""
    @State private var testingEngine: String?
    @State private var testResult: (engine: String, success: Bool, message: String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("AI 엔진 설정")
                    .font(.title3.bold())
                Text("AI 분류 및 보정에 사용할 엔진과 API 키를 관리합니다.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                GroupBox("엔진 선택") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("AI 분류 엔진", selection: $aiClassifyEngine) {
                            Text("Gemini Flash").tag("geminiFlash")
                            Text("GPT-4o Mini").tag("gpt4oMini")
                            Text("Claude Haiku").tag("claudeHaiku")
                            Text("Claude Sonnet").tag("claudeSonnet")
                        }

                        Divider()

                        Picker("AI 보정 엔진", selection: $aiCorrectionEngine) {
                            Text("Claude Sonnet").tag("claudeSonnet")
                            Text("Claude Haiku").tag("claudeHaiku")
                            Text("GPT-4o").tag("gpt4o")
                        }
                    }
                    .padding(4)
                }

                GroupBox("API 키") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Gemini API 키")
                                .frame(width: 120, alignment: .leading)
                            SecureField("API 키 입력", text: $geminiAPIKey)
                                .textFieldStyle(.roundedBorder)
                            apiTestButton(engine: "gemini")
                        }

                        Divider()

                        HStack {
                            Text("OpenAI API 키")
                                .frame(width: 120, alignment: .leading)
                            SecureField("API 키 입력", text: $openAIAPIKey)
                                .textFieldStyle(.roundedBorder)
                            apiTestButton(engine: "openai")
                        }

                        Divider()

                        HStack {
                            Text("Claude API 키")
                                .frame(width: 120, alignment: .leading)
                            SecureField("API 키 입력", text: $claudeAPIKey)
                                .textFieldStyle(.roundedBorder)
                                .onAppear {
                                    claudeAPIKey = ClaudeVisionService.getAPIKey() ?? ""
                                }
                                .onChange(of: claudeAPIKey) { newValue in
                                    ClaudeVisionService.setAPIKey(newValue)
                                }
                            apiTestButton(engine: "claude")
                        }

                        if let result = testResult {
                            HStack {
                                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(result.success ? .green : .red)
                                Text(result.message)
                                    .font(.callout)
                                    .foregroundColor(result.success ? .green : .red)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(4)
                }

                GroupBox("사용량 관리") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("월 예산 설정 ($)")
                                .frame(width: 120, alignment: .leading)
                            TextField("예산 (USD)", text: $aiBudgetUSD)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }

                        Divider()

                        Stepper("동시 처리 수: \(aiConcurrency)", value: $aiConcurrency, in: 1...6)
                    }
                    .padding(4)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func apiTestButton(engine: String) -> some View {
        Button {
            testingEngine = engine
            // Simulate test - in production this would make a real API call
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let hasKey: Bool
                switch engine {
                case "gemini": hasKey = !geminiAPIKey.isEmpty
                case "openai": hasKey = !openAIAPIKey.isEmpty
                case "claude": hasKey = !claudeAPIKey.isEmpty
                default: hasKey = false
                }
                testResult = (
                    engine: engine,
                    success: hasKey,
                    message: hasKey ? "\(engine.capitalized) 연결 성공" : "API 키를 입력하세요"
                )
                testingEngine = nil
            }
        } label: {
            if testingEngine == engine {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("테스트")
            }
        }
        .buttonStyle(.bordered)
        .disabled(testingEngine != nil)
    }
}

// MARK: - Tab 5: 퍼포먼스 (Performance)

struct PerformanceSettingsTab: View {
    @AppStorage("thumbnailCacheSize") private var thumbnailCacheSize = 3000.0
    @AppStorage("memoryLimit") private var memoryLimit = "auto"
    @AppStorage("prefetchRange") private var prefetchRange = 5
    @AppStorage("useGPUAcceleration") private var useGPUAcceleration = true
    @AppStorage("analysisCPULimit") private var analysisCPULimit = 75.0
    @AppStorage("rawDecodeQuality") private var rawDecodeQuality = "balanced"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("퍼포먼스 설정")
                    .font(.title3.bold())
                Text("캐시, 메모리, GPU 등 성능 관련 옵션을 조정합니다.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                GroupBox("캐시 및 메모리") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("썸네일 캐시 크기: \(Int(thumbnailCacheSize))장")
                            Slider(value: $thumbnailCacheSize, in: 1000...10000, step: 500)
                        }

                        Divider()

                        Picker("메모리 제한", selection: $memoryLimit) {
                            Text("자동").tag("auto")
                            Text("2GB").tag("2gb")
                            Text("4GB").tag("4gb")
                            Text("8GB").tag("8gb")
                        }

                        Divider()

                        Stepper("프리패치 범위: \(prefetchRange)장", value: $prefetchRange, in: 3...20)
                    }
                    .padding(4)
                }

                GroupBox("처리 성능") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("GPU 가속 사용", isOn: $useGPUAcceleration)

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("백그라운드 분석 CPU 제한: \(Int(analysisCPULimit))%")
                            Slider(value: $analysisCPULimit, in: 25...100, step: 5)
                        }

                        Divider()

                        Picker("RAW 디코딩 품질", selection: $rawDecodeQuality) {
                            Text("빠름").tag("fast")
                            Text("균형").tag("balanced")
                            Text("최고품질").tag("best")
                        }
                    }
                    .padding(4)
                }

                GroupBox("성능 모니터 & 로그") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("성능 로그가 자동으로 기록됩니다")
                                    .font(.system(size: 11))
                                Text("메모리, CPU, 응답시간 이상 시 경고 기록")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text("경로: ~/Library/Logs/PickShot/")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(spacing: 6) {
                                Button("로그 폴더 열기") {
                                    PerformanceMonitor.shared.openLogFolder()
                                }
                                .font(.system(size: 11))

                                Button("성능 리포트 복사") {
                                    let report = PerformanceMonitor.shared.generateReport()
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(report, forType: .string)
                                }
                                .font(.system(size: 11))
                            }
                        }
                    }
                    .padding(4)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Tab 6: 단축키 (Shortcuts)

struct ShortcutsSettingsTab: View {
    private let shortcutSections: [(String, [(String, String)])] = [
        ("탐색", [
            ("← →", "이전 / 다음 사진"),
            ("↑ ↓", "위 / 아래 행 이동"),
            ("Shift + 방향키", "범위 선택 확장"),
        ]),
        ("선택", [
            ("클릭", "단일 선택"),
            ("Cmd + 클릭", "개별 추가/해제"),
            ("Shift + 클릭", "범위 선택"),
            ("Cmd + A", "전체 선택"),
            ("Cmd + D", "전체 해제"),
        ]),
        ("별점 / 라벨", [
            ("1 ~ 5", "별점 매기기"),
            ("0", "별점 초기화"),
            ("6", "색상 라벨 해제"),
            ("7 / 8 / 9", "빨강 / 주황 / 노랑 라벨"),
        ]),
        ("셀렉 / 미리보기", [
            ("Space", "스페이스 셀렉 (SP) 토글"),
            ("P", "Quick Look 미리보기"),
            ("I", "메타데이터 오버레이 토글"),
            ("H", "히스토그램 오버레이 토글"),
        ]),
        ("보기", [
            ("Cmd + 0", "화면 맞춤"),
            ("Cmd + =", "확대"),
            ("Cmd + -", "축소"),
        ]),
        ("파일", [
            ("Cmd + O", "폴더 열기"),
            ("Cmd + E", "내보내기"),
            ("Cmd + ,", "설정"),
            ("Cmd + /", "단축키 안내"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("단축키 안내")
                    .font(.title3.bold())
                Text("현재 사용 가능한 단축키 목록입니다. (읽기 전용)")
                    .font(.callout)
                    .foregroundColor(.secondary)

                ForEach(shortcutSections, id: \.0) { section in
                    GroupBox(section.0) {
                        VStack(spacing: 0) {
                            ForEach(Array(section.1.enumerated()), id: \.offset) { index, shortcut in
                                HStack {
                                    Text(shortcut.0)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .frame(width: 160, alignment: .leading)
                                    Text(shortcut.1)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 3)

                                if index < section.1.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Cache Settings Tab (캐시)

struct CacheSettingsTab: View {
    @AppStorage("thumbnailCacheMaxGB") private var thumbnailCacheMaxGB: Double = 2.0
    @AppStorage("customCachePath") private var customCachePath: String = ""
    @State private var thumbCacheSize: String = "계산 중..."
    @State private var previewCacheSize: String = "계산 중..."
    @State private var logCacheSize: String = "계산 중..."
    @State private var totalCacheSize: String = "계산 중..."
    @State private var isClearing = false

    private var effectiveCachePath: String {
        customCachePath.isEmpty ? defaultCachePath : customCachePath
    }

    private var defaultCachePath: String {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDir.appendingPathComponent("PickShot").path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("캐시 현황") {
                    VStack(spacing: 8) {
                        cacheRow(icon: "photo.stack", label: "썸네일 캐시", size: thumbCacheSize, color: .blue)
                        cacheRow(icon: "eye", label: "미리보기 캐시", size: previewCacheSize, color: .green)
                        cacheRow(icon: "doc.text", label: "로그", size: logCacheSize, color: .gray)
                        Divider()
                        HStack {
                            Image(systemName: "internaldrive").font(.system(size: 14)).foregroundColor(.accentColor)
                            Text("총 캐시 용량").font(.system(size: 13, weight: .bold))
                            Spacer()
                            Text(totalCacheSize).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(.accentColor)
                        }
                    }.padding(4)
                }

                GroupBox("캐시 크기 제한") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("썸네일 캐시 최대").frame(width: 130, alignment: .leading)
                            Slider(value: $thumbnailCacheMaxGB, in: 0.5...10, step: 0.5)
                            Text("\(thumbnailCacheMaxGB, specifier: "%.1f") GB").font(.system(size: 12, design: .monospaced)).frame(width: 55, alignment: .trailing)
                        }
                        Text("초과 시 오래된 항목부터 자동 삭제").font(.system(size: 11)).foregroundColor(.secondary)
                    }.padding(4)
                }

                GroupBox("캐시 저장 위치") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "folder").foregroundColor(.secondary)
                            Text(effectiveCachePath).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).foregroundColor(.secondary)
                            Spacer()
                        }.padding(6).background(Color.gray.opacity(0.1)).cornerRadius(4)

                        HStack(spacing: 8) {
                            Button("위치 변경...") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.message = "캐시 파일을 저장할 폴더를 선택하세요"
                                if panel.runModal() == .OK, let url = panel.url {
                                    customCachePath = url.appendingPathComponent("PickShot").path
                                }
                            }
                            if !customCachePath.isEmpty {
                                Button("기본 위치로") { customCachePath = "" }
                            }
                            Button("Finder에서 열기") {
                                let path = effectiveCachePath
                                let url = URL(fileURLWithPath: path)
                                if FileManager.default.fileExists(atPath: path) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        Text("변경 시 기존 캐시는 이동되지 않습니다").font(.system(size: 11)).foregroundColor(.secondary)
                    }.padding(4)
                }

                GroupBox("캐시 삭제") {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Button(action: { clearCache(type: .thumb) }) { Label("썸네일", systemImage: "trash") }.disabled(isClearing)
                            Button(action: { clearCache(type: .preview) }) { Label("미리보기", systemImage: "trash") }.disabled(isClearing)
                            Button(action: { clearCache(type: .all) }) { Label("전체 삭제", systemImage: "trash.fill") }.foregroundColor(.red).disabled(isClearing)
                        }
                        if isClearing { ProgressView("삭제 중...").controlSize(.small) }
                        Text("삭제 후 다음 로딩 시 캐시가 다시 생성됩니다").font(.system(size: 11)).foregroundColor(.secondary)
                    }.padding(4)
                }

                Divider()
                HStack {
                    Button("되돌리기") {
                        thumbnailCacheMaxGB = 2.0
                        customCachePath = ""
                        NotificationCenter.default.post(name: Notification.Name("SettingsChanged"), object: nil)
                    }
                    .help("모든 캐시 설정을 기본값으로 초기화")

                    Spacer()

                    Button("확인") {
                        NotificationCenter.default.post(name: Notification.Name("SettingsChanged"), object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                }
                .padding(.top, 8)
            }.padding(20)
        }
        .onAppear { refreshCacheSizes() }
    }

    private func cacheRow(icon: String, label: String, size: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(color).frame(width: 20)
            Text(label).font(.system(size: 12))
            Spacer()
            Text(size).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
        }
    }

    private enum ClearType { case thumb, preview, all }

    private func clearCache(type: ClearType) {
        isClearing = true
        DispatchQueue.global(qos: .utility).async {
            switch type {
            case .thumb:
                DiskThumbnailCache.shared.clearAll()
                ThumbnailCache.shared.removeAll()
            case .preview:
                PreviewImageCache.shared.clearCache()
                try? FileManager.default.removeItem(atPath: "/tmp/pickshot_cache")
            case .all:
                DiskThumbnailCache.shared.clearAll()
                ThumbnailCache.shared.removeAll()
                PreviewImageCache.shared.clearCache()
                try? FileManager.default.removeItem(atPath: "/tmp/pickshot_cache")
                ExifService.clearCache()
            }
            DispatchQueue.main.async { isClearing = false; refreshCacheSizes() }
        }
    }

    private func refreshCacheSizes() {
        DispatchQueue.global(qos: .utility).async {
            let thumb = folderSize(path: defaultCachePath + "/thumbnails")
            let preview = folderSize(path: "/tmp/pickshot_cache")
            let log = folderSize(path: defaultCachePath + "/logs")
            let total = thumb + preview + log
            DispatchQueue.main.async {
                thumbCacheSize = formatBytes(thumb)
                previewCacheSize = formatBytes(preview)
                logCacheSize = formatBytes(log)
                totalCacheSize = formatBytes(total)
            }
        }
    }

    private func folderSize(path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath), let size = attrs[.size] as? Int64 { total += size }
        }
        return total
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 MB" }
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - Performance Optimize Tab (성능 최적화)

struct PerformanceOptimizeTab: View {
    @State private var isBenchmarking = false
    @State private var benchmarkDone = false
    @State private var cpuScore: String = "—"
    @State private var gpuScore: String = "—"
    @State private var ramInfo: String = "—"
    @State private var diskSpeed: String = "—"
    @State private var recommendedProfile: String = "—"
    @State private var applied = false
    @State private var selectedProfile: String = ""

    @AppStorage("previewMaxResolution") private var previewMaxResolution = "original"
    @AppStorage("previewCacheSize") private var previewCacheSize = 20.0
    @AppStorage("defaultThumbnailSize") private var defaultThumbnailSize = 150.0
    @AppStorage("thumbnailCacheMaxGB") private var thumbnailCacheMaxGB: Double = 2.0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 헤더
                VStack(spacing: 4) {
                    Image(systemName: "bolt.circle.fill").font(.system(size: 32)).foregroundColor(.accentColor)
                    Text("성능 최적화").font(.system(size: 16, weight: .bold))
                    Text("시스템을 분석하고 최적의 설정을 자동으로 적용합니다").font(.system(size: 12)).foregroundColor(.secondary)
                }

                Divider()

                // 시스템 정보
                GroupBox("시스템 정보") {
                    VStack(alignment: .leading, spacing: 8) {
                        infoRow("CPU", ProcessInfo.processInfo.processorCount > 8 ? "고성능 (\(ProcessInfo.processInfo.activeProcessorCount)코어)" : "표준 (\(ProcessInfo.processInfo.activeProcessorCount)코어)")
                        infoRow("RAM", "\(Int(ProcessInfo.processInfo.physicalMemory / (1024*1024*1024)))GB")
                        infoRow("GPU", "Metal \(MTLCreateSystemDefaultDevice()?.name ?? "Unknown")")
                        infoRow("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
                    }.padding(4)
                }

                // 벤치마크 결과
                GroupBox("성능 측정") {
                    VStack(spacing: 12) {
                        if isBenchmarking {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("측정 중... (약 5초)").font(.system(size: 13)).foregroundColor(.secondary)
                            }
                        } else if benchmarkDone {
                            HStack(spacing: 20) {
                                benchBox(title: "CPU", value: cpuScore, color: .blue)
                                benchBox(title: "GPU", value: gpuScore, color: .green)
                                benchBox(title: "디스크", value: diskSpeed, color: .orange)
                                benchBox(title: "RAM", value: ramInfo, color: .purple)
                            }

                            Divider()

                            HStack {
                                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                                Text("추천 프로필: ").font(.system(size: 13, weight: .medium))
                                Text(recommendedProfile).font(.system(size: 13, weight: .bold)).foregroundColor(.accentColor)
                            }
                        }

                        Button(action: { runBenchmark() }) {
                            Label(benchmarkDone ? "다시 측정" : "성능 측정 시작", systemImage: "speedometer")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBenchmarking)
                    }.padding(4)
                }

                // 원클릭 최적화
                if benchmarkDone {
                    GroupBox("원클릭 최적화") {
                        VStack(spacing: 10) {
                            Text("측정 결과를 기반으로 미리보기, 캐시, 썸네일 설정을 자동으로 최적화합니다")
                                .font(.system(size: 12)).foregroundColor(.secondary)

                            HStack(spacing: 12) {
                                profileButton("speed", icon: "hare", title: "속도 우선", desc: "낮은 해상도\n빠른 탐색")
                                profileButton("balanced", icon: "scale.3d", title: "균형 (추천)", desc: "적정 해상도\n적정 캐시")
                                profileButton("quality", icon: "eye", title: "화질 우선", desc: "최대 해상도\n큰 캐시")
                            }

                            if applied {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    Text("설정 적용 완료!").font(.system(size: 12, weight: .medium)).foregroundColor(.green)
                                }
                            }
                        }.padding(4)
                    }
                }

                // 현재 설정 요약
                GroupBox("현재 설정") {
                    VStack(alignment: .leading, spacing: 6) {
                        settingRow("미리보기 해상도", previewMaxResolution == "original" ? "원본" : "\(previewMaxResolution)px")
                        settingRow("미리보기 캐시", "\(Int(previewCacheSize))장")
                        settingRow("썸네일 크기", "\(Int(defaultThumbnailSize))px")
                        settingRow("디스크 캐시 제한", "\(String(format: "%.1f", thumbnailCacheMaxGB))GB")
                    }.padding(4)
                }

                Divider()
                HStack {
                    Button("되돌리기") {
                        previewMaxResolution = "original"
                        previewCacheSize = 20.0
                        defaultThumbnailSize = 150.0
                        thumbnailCacheMaxGB = 2.0
                        selectedProfile = ""
                        applied = false
                        NotificationCenter.default.post(name: Notification.Name("SettingsChanged"), object: nil)
                    }
                    .help("모든 성능 최적화 설정을 기본값으로 초기화")

                    Spacer()

                    Button("확인") {
                        NotificationCenter.default.post(name: Notification.Name("SettingsChanged"), object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                }
                .padding(.top, 8)
            }.padding(20)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium)).frame(width: 60, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).frame(width: 140, alignment: .leading)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(.accentColor)
        }
    }

    private func benchBox(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
        }.frame(width: 80)
    }

    private func profileButton(_ profile: String, icon: String, title: String, desc: String) -> some View {
        let isSelected = selectedProfile == profile
        return Button(action: { applyProfile(profile) }) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.system(size: 11, weight: .bold))
                Text(desc).font(.system(size: 9)).foregroundColor(isSelected ? .white.opacity(0.8) : .secondary).multilineTextAlignment(.center)
            }
            .frame(width: 110, height: 85)
            .foregroundColor(isSelected ? .white : .primary)
            .background(isSelected ? Color.accentColor : Color.gray.opacity(0.15))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Benchmark

    private func runBenchmark() {
        isBenchmarking = true
        benchmarkDone = false
        applied = false

        DispatchQueue.global(qos: .userInitiated).async {
            let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024*1024*1024))
            let cores = ProcessInfo.processInfo.activeProcessorCount

            // CPU 벤치마크: 1000x1000 이미지 리사이즈 속도
            let cpuStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<10 {
                autoreleasepool {
                    let w = 1000, h = 1000
                    if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
                        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                        let _ = ctx.makeImage()
                    }
                }
            }
            let cpuTime = (CFAbsoluteTimeGetCurrent() - cpuStart) * 1000
            let cpuScoreVal = cpuTime < 50 ? "매우 빠름" : cpuTime < 100 ? "빠름" : cpuTime < 200 ? "보통" : "느림"

            // GPU 체크
            let hasGPU = MTLCreateSystemDefaultDevice() != nil
            let gpuName = MTLCreateSystemDefaultDevice()?.name ?? "없음"
            let gpuScoreVal = gpuName.contains("M4") || gpuName.contains("M3") ? "최고" :
                              gpuName.contains("M2") || gpuName.contains("M1") ? "우수" : "보통"

            // 디스크 속도 (임시 파일 쓰기/읽기)
            let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("pickshot_bench.tmp")
            let testData = Data(repeating: 0xAA, count: 10_000_000) // 10MB
            let diskStart = CFAbsoluteTimeGetCurrent()
            try? testData.write(to: tmpFile)
            let _ = try? Data(contentsOf: tmpFile)
            try? FileManager.default.removeItem(at: tmpFile)
            let diskTime = (CFAbsoluteTimeGetCurrent() - diskStart) * 1000
            let diskSpeedVal = diskTime < 50 ? "SSD 고속" : diskTime < 100 ? "SSD" : diskTime < 500 ? "HDD" : "느림"

            // 추천 프로필 결정
            let profile: String
            if ramGB >= 32 && cores >= 8 && gpuScoreVal == "최고" {
                profile = "🚀 고성능 — 최대 설정 가능"
            } else if ramGB >= 16 && cores >= 4 {
                profile = "⚡ 균형 — 표준 설정 추천"
            } else {
                profile = "🐢 절약 — 속도 우선 설정 추천"
            }

            DispatchQueue.main.async {
                self.cpuScore = cpuScoreVal
                self.gpuScore = gpuScoreVal
                self.ramInfo = "\(ramGB)GB"
                self.diskSpeed = diskSpeedVal
                self.recommendedProfile = profile
                self.isBenchmarking = false
                self.benchmarkDone = true
            }
        }
    }

    // MARK: - Apply Profile

    private func applyProfile(_ profile: String) {
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024*1024*1024))

        switch profile {
        case "speed":
            previewMaxResolution = "1000"
            previewCacheSize = Double(min(10, ramGB / 2))
            defaultThumbnailSize = 100
            thumbnailCacheMaxGB = 1.0
        case "balanced":
            previewMaxResolution = "2000"
            previewCacheSize = Double(min(30, ramGB))
            defaultThumbnailSize = 150
            thumbnailCacheMaxGB = min(Double(ramGB / 8), 4.0)
        case "quality":
            previewMaxResolution = "4000"
            previewCacheSize = Double(min(100, ramGB * 2))
            defaultThumbnailSize = 200
            thumbnailCacheMaxGB = min(Double(ramGB / 4), 8.0)
        default: break
        }

        selectedProfile = profile
        applied = true
        NotificationCenter.default.post(name: Notification.Name("SettingsChanged"), object: nil)
    }
}

import Metal
