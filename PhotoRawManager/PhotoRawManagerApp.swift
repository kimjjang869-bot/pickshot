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

        SubscriptionManager.shared.checkTrialStatus()
    }

    var body: some Scene {
        WindowGroup({
            let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "8.0"
            return "PickShot v\(ver)-beta"
        }()) {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1024, minHeight: 700)
                .task {
                    updateService.checkForUpdate(userInitiated: false)
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
                Button("스마트 셀렉...") {
                    store.previewSmartSelect()
                    store.showSmartSelect = true
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store.photos.isEmpty)

                Divider()

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
                        store.photosVersion += 1
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
