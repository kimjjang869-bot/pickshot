import SwiftUI
import UniformTypeIdentifiers

@main
struct PhotoRawManagerApp: App {
    @StateObject private var store = PhotoStore()
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    init() {
        // 중복 실행 방지
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if runningApps.count > 1 {
            // 이미 실행 중인 인스턴스를 앞으로 가져오고 현재 인스턴스 종료
            if let existing = runningApps.first(where: { $0 != .current }) {
                existing.activate()
            }
            NSApp.terminate(nil)
        }

        // 스크롤바 항상 표시 (시스템 설정 오버라이드)
        UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")

        // 툴팁 표시 속도 단축 (기본 ~2초 → 0.5초)
        UserDefaults.standard.set(500, forKey: "NSInitialToolTipDelay")

        // SystemSpec warm-up (모든 캐시/동시성의 단일 소스)
        _ = SystemSpec.shared
        AppLogger.log(.general, SystemSpec.shared.debugSummary)

        // 썸네일 캐시 버전 invalidate — orientation 보정 로직 추가됨 (이전 버전에서 가로/세로 잘못 저장된 캐시 폐기)
        let thumbCacheVersionKey = "thumbCacheVersion"
        let currentThumbCacheVersion = "v8.9.4-cr3-portrait-fix"
        if UserDefaults.standard.string(forKey: thumbCacheVersionKey) != currentThumbCacheVersion {
            DiskThumbnailCache.shared.clearAll()
            UserDefaults.standard.set(currentThumbCacheVersion, forKey: thumbCacheVersionKey)
            fputs("[CACHE] 썸네일 디스크 캐시 invalidate (orientation 보정 적용)\n", stderr)
        }

        SubscriptionManager.shared.checkTrialStatus()
    }

    var body: some Scene {
        WindowGroup({
            let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "8.0"
            #if DEBUG
            // v8.9.4: 빌드 시각 태그 (DMG 파일명 타임스탬프와 매칭) — 어떤 테스트 빌드인지 한눈에 식별
            let buildTag: String = {
                guard let exe = Bundle.main.executableURL,
                      let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
                      let mtime = attrs[.modificationDate] as? Date else { return "" }
                let f = DateFormatter()
                f.dateFormat = "MMdd-HHmm"
                return " · test-\(f.string(from: mtime))"
            }()
            return "PickShot v\(ver)\(buildTag)"
            #else
            return "PickShot v\(ver)"
            #endif
        }()) {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1024, minHeight: 700)
                .task {
                    updateService.checkForUpdate(userInitiated: false)
                    // 성능 로그는 로컬 Debug와 테스터 Release 모두에서 문제 재현 자료로 사용한다.
                    // Debug 전용 HUD/스트레스 테스트는 ContentView의 #if DEBUG 경계에서만 노출된다.
                    PerformanceMonitor.shared.start()
                    // Google OAuth credentials loaded on-demand when G Select is used
                    // (removed from startup — was blocking main thread via Keychain)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(
            width: (NSScreen.main?.visibleFrame.width ?? 1440) * 0.95,
            height: (NSScreen.main?.visibleFrame.height ?? 900) * 0.95
        )
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("PickShot 정보") {
                    store.showAbout = true
                }
            }
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인...") {
                    updateService.checkForUpdate(userInitiated: true)
                }
                .disabled(updateService.isChecking)
            }
            CommandGroup(replacing: .newItem) {
                Button("폴더 열기...") {
                    store.openFolder()
                }
                .keyboardShortcut("o")

                Button("ZIP 파일 열기...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.zip]
                    panel.message = "사진이 포함된 ZIP 파일을 선택하세요"
                    if panel.runModal() == .OK, let url = panel.url {
                        store.openZipFile(url)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("셀렉") {
                if !AppConfig.hideAIFeatures {
                    Button("스마트 셀렉...") {
                        store.previewSmartSelect()
                        store.showSmartSelect = true
                    }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.photos.isEmpty)

                    Divider()
                }

                Button("셀렉 내보내기...") {
                    let folderName = store.folderURL?.lastPathComponent ?? "PickShot"
                    if let url = PickshotFileService.exportSelection(photos: store.photos, folderName: folderName) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.photos.isEmpty)

                Button("셀렉 가져오기...") {
                    let result = PickshotFileService.importSelection(to: &store.photos, photoIndex: store._photoIndex)
                    if let result = result {
                        store.invalidateFilterCache()
                        store.lastImportResult = result
                        store.showImportResult = true
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
