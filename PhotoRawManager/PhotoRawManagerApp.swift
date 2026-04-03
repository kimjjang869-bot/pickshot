import SwiftUI

@main
struct PhotoRawManagerApp: App {
    @StateObject private var store = PhotoStore()
    @ObservedObject private var updateService = UpdateService.shared

    var body: some Scene {
        WindowGroup("PickShot v3.5") {
            ContentView()
                .environmentObject(store)
                .task {
                    updateService.checkForUpdate(userInitiated: false)
                    PerformanceMonitor.shared.start()
                    // Initialize Google OAuth credentials from Secrets.xcconfig file
                    if GoogleDriveService.oauthClientID.isEmpty {
                        GoogleDriveService.loadSecretsFromConfig()
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1440, height: 900)
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
            CommandMenu("셀렉") {
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
