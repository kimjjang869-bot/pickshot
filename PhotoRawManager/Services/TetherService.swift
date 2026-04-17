import Foundation
import ImageCaptureCore
import AppKit

/// Manages camera tethering via ImageCaptureCore framework.
/// Detects USB-connected cameras, auto-downloads captured photos,
/// and notifies the UI of new files.
class TetherService: NSObject, ObservableObject {
    // MARK: - Published State
    @Published var isActive: Bool = false
    @Published var cameraName: String = ""
    @Published var batteryLevel: Int? = nil  // 0-100, nil if not available
    @Published var captureCount: Int = 0
    @Published var latestPhotoURL: URL? = nil
    @Published var statusMessage: String = "카메라를 USB로 연결하세요"
    @Published var isConnected: Bool = false

    /// Output folder where tethered photos are saved.
    @Published var outputFolder: URL {
        didSet {
            UserDefaults.standard.set(outputFolder.path, forKey: "tetherOutputFolder")
            SandboxBookmarkService.saveBookmark(for: outputFolder, key: "tetherOutputFolder")
        }
    }

    /// 파일명 prefix (예: "WED_", "SESSION_"). 비어있으면 원본 이름 유지.
    @Published var filenamePrefix: String {
        didSet {
            UserDefaults.standard.set(filenamePrefix, forKey: "tetherFilenamePrefix")
        }
    }

    /// 자동 증가 시퀀스 번호 (prefix 사용 시)
    @Published var sequenceNumber: Int {
        didSet {
            UserDefaults.standard.set(sequenceNumber, forKey: "tetherSequenceNumber")
        }
    }

    /// 원격 셔터 지원 여부 (카메라별로 다름)
    @Published var canTriggerShutter: Bool = false

    /// Called on the main queue when a new photo has been downloaded.
    /// Passes the URL of the saved file.
    var onNewPhoto: ((URL) -> Void)?

    // MARK: - Private
    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var statusTimer: DispatchSourceTimer?
    // 폴링 모드 (Sony PC Remote 대응 — capability 없어도 mediaFiles 폴링으로 새 파일 감지)
    private var pollingTimer: DispatchSourceTimer?
    private var knownFileNames: Set<String> = []
    private var pollCount: Int = 0
    // Sony 처럼 본체에서 mediaFiles 못 읽는 경우 — SD 카드 장치도 별도 추적
    private var sdCardDevice: ICCameraDevice?
    private var pendingDownloads: Set<String> = []

    override init() {
        // Restore saved output folder or default to Desktop/PickShot_Tethered
        // Try security-scoped bookmark first (App Sandbox)
        if let bookmarked = SandboxBookmarkService.resolveBookmark(key: "tetherOutputFolder") {
            outputFolder = bookmarked
        } else if let saved = UserDefaults.standard.string(forKey: "tetherOutputFolder") {
            outputFolder = URL(fileURLWithPath: saved)
        } else {
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            outputFolder = desktop.appendingPathComponent("PickShot_Tethered")
        }

        // 파일명 템플릿 복원
        filenamePrefix = UserDefaults.standard.string(forKey: "tetherFilenamePrefix") ?? ""
        let savedSeq = UserDefaults.standard.integer(forKey: "tetherSequenceNumber")
        sequenceNumber = savedSeq == 0 ? 1 : savedSeq  // 기본값 1부터 시작

        super.init()
        browser.delegate = self
    }

    // MARK: - Public API

    /// Start browsing for connected cameras.
    func startBrowsing() {
        guard !isActive else { return }
        isActive = true
        statusMessage = "카메라 검색 중..."
        browser.start()
        AppLogger.log(.general, "[Tether] Started browsing for cameras")
    }

    /// Stop browsing and disconnect any camera.
    func stopBrowsing() {
        browser.stop()
        disconnectCamera()
        isActive = false
        statusMessage = "테더링 중지됨"
        stopStatusPolling()
        stopPollingMode()
        AppLogger.log(.general, "[Tether] Stopped browsing")
    }

    /// Disconnect the current camera.
    private func disconnectCamera() {
        if let cam = camera {
            cam.delegate = nil
            cam.requestCloseSession()
            camera = nil
        }
        isConnected = false
        cameraName = ""
        batteryLevel = nil
    }

    /// Ensure the output folder exists.
    private func ensureOutputFolder() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputFolder.path) {
            try? fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        }
    }

    /// 원격 셔터 트리거 — 카메라에게 촬영 명령 전송
    /// - Important: PTP 프로토콜 지원 카메라에서만 작동 (Canon/Nikon/Sony 대부분 지원)
    /// - 실패 시 statusMessage 에 에러 표시
    func triggerShutter() {
        guard let cam = camera, isConnected else {
            statusMessage = "카메라가 연결되어 있지 않습니다"
            return
        }
        guard cam.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue) else {
            statusMessage = "이 카메라는 원격 촬영을 지원하지 않습니다"
            return
        }

        cam.requestTakePicture()
        AppLogger.log(.general, "[Tether] 원격 셔터 트리거")
    }

    /// 파일명에 prefix + sequence 를 적용한 새 이름 반환
    /// 예) "IMG_1234.CR3" + prefix "WED_" + seq 42 → "WED_0042.CR3"
    /// prefix 가 비어있으면 원본 이름 유지
    fileprivate func buildFilename(originalName: String) -> String {
        guard !filenamePrefix.isEmpty else { return originalName }
        let ext = (originalName as NSString).pathExtension
        let seqStr = String(format: "%04d", sequenceNumber)
        let base = "\(filenamePrefix)\(seqStr)"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// 사이드카 파일(.xmp, .thm 등)에도 동일한 새 이름 적용
    fileprivate func buildSidecarFilename(originalSidecar: String, newBase: String) -> String {
        let ext = (originalSidecar as NSString).pathExtension
        return ext.isEmpty ? newBase : "\(newBase).\(ext)"
    }
}

// MARK: - ICDeviceBrowserDelegate

extension TetherService: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        let name = cam.name ?? "Unknown"
        let caps = cam.capabilities
        AppLogger.log(.general, "[Tether] Camera found: \(name) caps=\(caps)")
        fputs("[Tether] 🔎 Camera found: '\(name)' caps=\(caps)\n", stderr)

        let nameLower = name.lowercased()
        let sdCardKeywords = ["sd_card", "sd card", "memory card", "mmc", "cf_card",
                               "xqd", "cfexpress", "compactflash", "sdhc", "sdxc"]
        let isSDCard = sdCardKeywords.contains(where: { nameLower.contains($0) })

        if isSDCard {
            // SD 카드 — 별도 보관해서 폴링 용도로 사용 (본체 카메라에서 mediaFiles 못 읽는 경우 대응)
            fputs("[Tether] 💾 SD 카드로 판단 — 폴링 용도로 보관\n", stderr)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // 이미 다른 SD 있으면 교체
                if let old = self.sdCardDevice, old !== cam {
                    old.requestCloseSession()
                }
                self.sdCardDevice = cam
                cam.delegate = self
                cam.requestOpenSession()
            }
            return
        }

        // 본체 카메라 — 이미 연결돼 있으면 무시
        if let existing = camera, existing !== cam {
            fputs("[Tether] ⏭️  이미 '\(existing.name ?? "?")' 연결됨 — '\(name)' 무시\n", stderr)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.camera = cam
            self.cameraName = cam.name ?? "카메라"
            self.statusMessage = "\(self.cameraName) 연결 중..."
            cam.delegate = self
            cam.requestOpenSession()
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let cam = device as? ICCameraDevice, cam === camera else { return }
        AppLogger.log(.general, "[Tether] Camera disconnected: \(cam.name ?? "Unknown")")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.disconnectCamera()
            self.statusMessage = "카메라 연결이 해제되었습니다"
        }
    }
}

// MARK: - ICCameraDeviceDelegate

extension TetherService: ICCameraDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let error = error {
                self.statusMessage = "세션 열기 실패: \(error.localizedDescription)"
                AppLogger.log(.general, "[Tether] Session open error: \(error)")
                return
            }
            self.isConnected = true
            self.statusMessage = "\(self.cameraName) 연결됨 - 촬영 대기 중"
            AppLogger.log(.general, "[Tether] Session opened for \(self.cameraName)")

            if let cam = device as? ICCameraDevice {
                self.batteryLevel = cam.batteryLevel
                let caps = cam.capabilities
                fputs("[Tether] 📋 Capabilities: \(caps)\n", stderr)
                AppLogger.log(.general, "[Tether] Capabilities: \(caps)")

                let canShoot = caps.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue)
                let canReceive = caps.contains(ICDeviceCapability.cameraDeviceCanReceiveFile.rawValue)
                let supportsTether = caps.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
                fputs("[Tether] 🎯 canTakePicture=\(canShoot) canReceiveFile=\(canReceive) canAcceptPTP=\(supportsTether)\n", stderr)

                // mediaFiles 로 이미 카메라 내 파일 상태 조회
                let existingFiles = cam.mediaFiles ?? []
                fputs("[Tether] 📁 초기 mediaFiles: \(existingFiles.count) 개\n", stderr)
                self.knownFileNames = Set(existingFiles.compactMap { $0.name })

                self.canTriggerShutter = canShoot

                if !canShoot && !canReceive && supportsTether {
                    // Sony PC Remote 일 수도 있음 — PTP 지원되면 polling 으로 회복
                    self.statusMessage = "Sony PC Remote 감지 — 폴링 모드로 촬영 감지 중 (2초 간격)"
                    fputs("[Tether] 🔄 폴링 모드 활성화 (PTP 만 지원)\n", stderr)
                    self.startPollingMode()
                } else if !canShoot && !canReceive {
                    self.statusMessage = "카메라가 촬영 이벤트를 지원하지 않는 모드입니다 — USB 모드 확인"
                }

                // 실제 촬영 데이터 수신을 위해 requestEnableTethering (Canon/Nikon)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self, let c = self.camera else { return }
                    fputs("[Tether] → requestEnableTethering()\n", stderr)
                    c.requestEnableTethering()
                }

                self.startStatusPolling()
            }
        }
    }

    /// 5초마다 배터리 + 연결 상태 재조회
    private func startStatusPolling() {
        statusTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, let cam = self.camera, self.isConnected else { return }
            let newBat = cam.batteryLevel
            if newBat != self.batteryLevel {
                self.batteryLevel = newBat
            }
        }
        timer.resume()
        statusTimer = timer
    }

    private func stopStatusPolling() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    /// 폴링 모드 — didAdd 이벤트가 안 올 때 (Sony PC Remote 등), 2초마다 mediaFiles 비교해서
    /// 새 파일 있으면 직접 다운로드.
    private func startPollingMode() {
        pollingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.pollForNewFiles()
        }
        timer.resume()
        pollingTimer = timer
    }

    private func stopPollingMode() {
        pollingTimer?.cancel()
        pollingTimer = nil
    }

    private func pollForNewFiles() {
        guard isConnected else { return }

        // 본체 카메라 mediaFiles (PC Remote 면 0개) + SD 카드 mediaFiles 양쪽 체크
        let camFiles = (camera?.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        let sdFiles = (sdCardDevice?.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }

        // 두 소스 병합 (이름 중복 제거)
        var merged: [ICCameraFile] = []
        var mergedNames = Set<String>()
        for f in camFiles + sdFiles {
            guard let n = f.name, !mergedNames.contains(n) else { continue }
            mergedNames.insert(n)
            merged.append(f)
        }

        let currentNames = Set(merged.compactMap { $0.name })
        let newNames = currentNames.subtracting(knownFileNames)

        pollCount += 1
        if pollCount % 5 == 0 {
            fputs("[Tether] 💓 polling tick #\(pollCount) cam=\(camFiles.count) sd=\(sdFiles.count) known=\(knownFileNames.count)\n", stderr)
        }

        if !newNames.isEmpty {
            fputs("[Tether] 🔍 폴링: 새 파일 \(newNames.count)개 감지 \(Array(newNames).prefix(3))\n", stderr)
            let newItems = merged.filter { file in
                guard let name = file.name else { return false }
                return newNames.contains(name)
            }
            // 어느 디바이스 소속이든 상관없이 다운로드 처리
            if let anyCam = newItems.first?.device as? ICCameraDevice {
                cameraDevice(anyCam, didAdd: newItems)
            } else if let sd = sdCardDevice {
                cameraDevice(sd, didAdd: newItems)
            } else if let cam = camera {
                cameraDevice(cam, didAdd: newItems)
            }
            knownFileNames = currentNames
        } else {
            if knownFileNames != currentNames {
                knownFileNames = currentNames
            }
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = false
            self.statusMessage = "세션 종료됨"
            AppLogger.log(.general, "[Tether] Session closed")
        }
    }

    // 새 API: 여러 아이템 배열을 받음 (macOS 10.15+)
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        fputs("[Tether] 📸 didAdd items count=\(items.count)\n", stderr)
        AppLogger.log(.general, "[Tether] 📸 didAdd \(items.count) items")

        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "새 촬영 감지 — 다운로드 중..."
        }

        for item in items {
            let itemName = item.name ?? "?"
            let itemType = type(of: item)
            fputs("[Tether]   - \(itemName) (type: \(itemType))\n", stderr)

            guard let file = item as? ICCameraFile else {
                fputs("[Tether]   ⚠️  item is not ICCameraFile (folder/other) — skipping\n", stderr)
                continue
            }
            let fileName = file.name ?? "unknown"
            AppLogger.log(.general, "[Tether] New file detected: \(fileName) size=\(file.fileSize)")

            guard !pendingDownloads.contains(fileName) else {
                fputs("[Tether]   • already pending, skipping\n", stderr)
                continue
            }
            pendingDownloads.insert(fileName)

            ensureOutputFolder()

            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: outputFolder,
                .overwrite: true,
                .sidecarFiles: true,
            ]

            fputs("[Tether]   → requestDownloadFile \(fileName)\n", stderr)
            camera.requestDownloadFile(file, options: options, downloadDelegate: self, didDownloadSelector: #selector(ICCameraDeviceDownloadDelegate.didDownloadFile(_:error:options:contextInfo:)), contextInfo: nil)
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        // 촬영 후 카메라에서 파일 삭제된 경우 — 무시
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        // 카메라 내부 파일 이름 변경 — 무시
    }

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        DispatchQueue.main.async { [weak self] in
            self?.canTriggerShutter = camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue)
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        // PTP 이벤트 로그 (디버깅 — 셔터 눌렀을 때 이벤트 오는지 확인용)
        let hex = eventData.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        fputs("[Tether] 🔔 PTP event (\(eventData.count) bytes): \(hex)\n", stderr)
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusMessage = "\(self.cameraName) 준비 완료 - 촬영하세요"
            self.batteryLevel = device.batteryLevel
        }
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        // 접근 제한 해제 — 로그만
        AppLogger.log(.general, "[Tether] Access restriction removed")
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        // 접근 제한 활성화 — 로그만
        AppLogger.log(.general, "[Tether] Access restriction enabled")
    }

    func didRemove(_ device: ICDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = false
            self.camera = nil
            self.cameraName = ""
            self.statusMessage = "카메라 연결 해제됨"
            AppLogger.log(.general, "[Tether] Device removed")
        }
    }

    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus : Any]) {
        // Update battery if available
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {
        // 카메라가 썸네일을 전송했을 때 — 테더링 플로우에선 사용 안 함
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable : Any]?, for item: ICCameraItem, error: (any Error)?) {
        // 카메라가 메타데이터를 전송했을 때 — 테더링 플로우에선 사용 안 함
    }
}

// MARK: - ICCameraDeviceDownloadDelegate

extension TetherService: ICCameraDeviceDownloadDelegate {
    func didDownloadFile(_ file: ICCameraFile, error: (any Error)?, options: [ICDownloadOption : Any], contextInfo: UnsafeMutableRawPointer?) {
        let originalFileName = file.name ?? "unknown"
        pendingDownloads.remove(originalFileName)

        if let error = error {
            AppLogger.log(.general, "[Tether] Download failed for \(originalFileName): \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "다운로드 실패: \(originalFileName)"
            }
            return
        }

        let downloadedURL = outputFolder.appendingPathComponent(originalFileName)

        // 파일명 템플릿 적용 (prefix + sequence)
        let finalURL: URL
        if !filenamePrefix.isEmpty {
            let newName = buildFilename(originalName: originalFileName)
            let newURL = outputFolder.appendingPathComponent(newName)
            do {
                if FileManager.default.fileExists(atPath: newURL.path) {
                    try FileManager.default.removeItem(at: newURL)
                }
                try FileManager.default.moveItem(at: downloadedURL, to: newURL)
                // 사이드카(.xmp, .thm 등) 도 같은 이름으로 리네임
                let baseOrig = (originalFileName as NSString).deletingPathExtension
                let newBase = (newName as NSString).deletingPathExtension
                if let files = try? FileManager.default.contentsOfDirectory(atPath: outputFolder.path) {
                    for f in files where f != newName {
                        let fNSString = f as NSString
                        if fNSString.deletingPathExtension == baseOrig, f != originalFileName {
                            let src = outputFolder.appendingPathComponent(f)
                            let dstName = buildSidecarFilename(originalSidecar: f, newBase: newBase)
                            let dst = outputFolder.appendingPathComponent(dstName)
                            if FileManager.default.fileExists(atPath: dst.path) {
                                try? FileManager.default.removeItem(at: dst)
                            }
                            try? FileManager.default.moveItem(at: src, to: dst)
                        }
                    }
                }
                finalURL = newURL
                DispatchQueue.main.async { [weak self] in
                    self?.sequenceNumber += 1
                }
            } catch {
                AppLogger.log(.general, "[Tether] Rename failed (\(error)), using original name")
                finalURL = downloadedURL
            }
        } else {
            finalURL = downloadedURL
        }

        AppLogger.log(.general, "[Tether] Downloaded: \(finalURL.path)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.captureCount += 1
            self.latestPhotoURL = finalURL
            self.statusMessage = "촬영 #\(self.captureCount): \(finalURL.lastPathComponent)"
            self.onNewPhoto?(finalURL)
        }
    }
}
