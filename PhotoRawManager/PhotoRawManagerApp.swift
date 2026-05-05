import SwiftUI
import UniformTypeIdentifiers

// MARK: - v9.1.3 통합 로그 (Release 빌드에서 컴파일 단계 제거 → 성능 영향 0)
@inlinable
public func plog(_ message: @autoclosure () -> String) {
    #if DEBUG
    if Log.enabled { Log.write(message()) }
    #endif
}

public enum Log {
    public static var enabled: Bool = {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "pickshotLogsEnabled") == nil {
            return true  // Debug 기본 ON
        }
        return UserDefaults.standard.bool(forKey: "pickshotLogsEnabled")
        #else
        return false
        #endif
    }()

    public static func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "pickshotLogsEnabled")
    }

    @usableFromInline
    static func write(_ msg: String) {
        let line = msg.hasSuffix("\n") ? msg : msg + "\n"
        line.withCString { _ = fwrite($0, 1, strlen($0), stderr) }
    }
}

@main
struct PhotoRawManagerApp: App {
    #if DEBUG
    static var stallTimer: DispatchSourceTimer?
    static var stallLastFire: CFAbsoluteTime = 0
    static func startMainRunloopStallDetector() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: .milliseconds(16), leeway: .milliseconds(2))
        stallLastFire = CFAbsoluteTimeGetCurrent()
        t.setEventHandler {
            let now = CFAbsoluteTimeGetCurrent()
            let gapMs = (now - stallLastFire) * 1000
            stallLastFire = now
            if gapMs > 30 {
                plog("[STALL] main runloop blocked \(String(format: "%.0f", gapMs))ms\n")
            }
        }
        t.resume()
        stallTimer = t
    }
    #endif
    @StateObject private var store = PhotoStore()
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    init() {
        // 중복 실행 방지 — Release 빌드에서 NSApp.terminate(nil) 후 init 가 계속 실행되며
        // 종료 중 상태의 싱글톤 접근으로 _assertionFailure 발생하던 문제.
        // exit(0) 으로 즉시 프로세스 종료 → 후속 init 코드 실행 안 됨.
        let bid = Bundle.main.bundleIdentifier ?? ""
        if !bid.isEmpty {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            if runningApps.count > 1 {
                if let existing = runningApps.first(where: { $0 != .current }) {
                    existing.activate()
                }
                plog("[APP] 중복 실행 감지 → 즉시 종료\n")
                exit(0)
            }
        }

        // 스크롤바 항상 표시 / 툴팁 속도 (가벼운 UserDefaults — init 유지)
        UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")
        UserDefaults.standard.set(500, forKey: "NSInitialToolTipDelay")

        #if DEBUG
        // v8.9.7: main runloop stall 감지 — 16ms 마다 main 으로 dispatch, 이전 fire 와의 간격이
        //   30ms 이상이면 stall 로 간주하고 로그. burst 동안 main thread 가 무엇으로 차단되는지 추적.
        Self.startMainRunloopStallDetector()
        #endif

        // 무거운 부트스트랩(SystemSpec warm-up, 캐시 invalidate, 트라이얼 체크) 은
        // init 에서 빼고 .task 로 이동 → init 중 _assertionFailure 위험 영역 축소.
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
                    // App.init() 에서 옮겨온 무거운 부트스트랩.
                    // SwiftUI 가 view 활성 후 main 액터에서 호출 → @MainActor 싱글톤 안전.
                    _ = SystemSpec.shared
                    AppLogger.log(.general, SystemSpec.shared.debugSummary)
                    // v9.1.4: 30일 이상된 로그 자동 정리 (보안 감사 M-3) — 디스크 누적 + 잔존 민감정보 차단
                    AppLogger.purgeOldLogs()

                    // 썸네일 디스크 캐시 invalidate token — orientation/디코드 알고리즘이 바뀐 빌드에서만 갱신.
                    //   ⚠️ 매 버전마다 자동 갱신하면 GB 단위 캐시가 매번 날아감 → 의도적으로 "수동" 갱신.
                    //   다음 사유로 토큰 갱신해야 함:
                    //     - 썸네일 디코드 알고리즘 변경 (Lanczos step 등)
                    //     - orientation 처리 변경
                    //     - 임베디드 추출 경로 변경
                    let thumbCacheVersionKey = "thumbCacheVersion"
                    let currentThumbCacheVersion = "v8.9.4-cr3-portrait-fix"  // ← 위 사유 발생 시만 변경
                    if UserDefaults.standard.string(forKey: thumbCacheVersionKey) != currentThumbCacheVersion {
                        DiskThumbnailCache.shared.clearAll()
                        UserDefaults.standard.set(currentThumbCacheVersion, forKey: thumbCacheVersionKey)
                        plog("[CACHE] 썸네일 디스크 캐시 invalidate (orientation 보정 적용)\n")
                    }

                    SubscriptionManager.shared.checkTrialStatus()

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

                    // v9.1.4: AI 자동 거부 표시 (Aftershoot 식 batch reject)
                    //   AI 품질 분석된 사진 중 hasQualityIssues 인 것 → 컬러라벨 빨강 자동 적용.
                    //   다른 색 라벨 있는 사진은 보존 (사용자 의도 존중).
                    Button("AI 거부 표시 (품질 문제 사진 → 빨강)") {
                        let count = store.applyAIRejectMarks()
                        let alert = NSAlert()
                        alert.messageText = "AI 거부 표시 완료"
                        alert.informativeText = "\(count)장에 빨강 컬러라벨 적용 — 흔들림/노출/포커스 문제 발견된 사진."
                        alert.runModal()
                    }
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

                // v9.1.4: Lightroom XMP 호환 일괄 export
                //   JPG 는 EXIF/XMP 임베딩, RAW 는 .xmp 사이드카 생성.
                //   Lightroom Classic "메타데이터 → 파일에서 읽기" 로 자동 인식.
                Button("Lightroom XMP 일괄 내보내기") {
                    let result = XMPService.exportLightroomCompatible(photos: store.photos)
                    let alert = NSAlert()
                    alert.messageText = "Lightroom XMP 내보내기 완료"
                    alert.informativeText = "총 \(result.total)장 처리 — JPG 임베딩 \(result.jpg)장, .xmp 사이드카 \(result.xmp)장.\n\nLightroom Classic 에서: 메타데이터 → 파일에서 읽기"
                    alert.runModal()
                }
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
                .environmentObject(store)
        }
    }
}
