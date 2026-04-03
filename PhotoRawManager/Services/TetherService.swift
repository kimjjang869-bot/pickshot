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
        }
    }

    /// Called on the main queue when a new photo has been downloaded.
    /// Passes the URL of the saved file.
    var onNewPhoto: ((URL) -> Void)?

    // MARK: - Private
    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var pendingDownloads: Set<String> = []

    override init() {
        // Restore saved output folder or default to Desktop/PickShot_Tethered
        if let saved = UserDefaults.standard.string(forKey: "tetherOutputFolder") {
            outputFolder = URL(fileURLWithPath: saved)
        } else {
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            outputFolder = desktop.appendingPathComponent("PickShot_Tethered")
        }
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
}

// MARK: - ICDeviceBrowserDelegate

extension TetherService: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        AppLogger.log(.general, "[Tether] Camera found: \(cam.name ?? "Unknown")")

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

            // Read battery level if available
            if let cam = device as? ICCameraDevice {
                self.batteryLevel = cam.batteryLevel
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

    func cameraDevice(_ camera: ICCameraDevice, didAdd item: ICCameraItem) {
        // A new photo appeared on the camera - download it
        guard let file = item as? ICCameraFile else { return }
        let fileName = file.name ?? "unknown"
        AppLogger.log(.general, "[Tether] New file detected: \(fileName)")

        // Track pending downloads to avoid duplicates
        guard !pendingDownloads.contains(fileName) else { return }
        pendingDownloads.insert(fileName)

        ensureOutputFolder()

        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: outputFolder,
            .overwrite: true,
            .sidecarFiles: true,
        ]

        camera.requestDownloadFile(file, options: options, downloadDelegate: self, didDownloadSelector: #selector(ICCameraDeviceDownloadDelegate.didDownloadFile(_:error:options:contextInfo:)), contextInfo: nil)
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove item: ICCameraItem) {
        // Not needed for tethering
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusMessage = "\(self.cameraName) 준비 완료 - 촬영하세요"
            if let cam = device as? ICCameraDevice {
                self.batteryLevel = cam.batteryLevel
            }
        }
    }

    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus : Any]) {
        // Update battery if available
    }

}

// MARK: - ICCameraDeviceDownloadDelegate

extension TetherService: ICCameraDeviceDownloadDelegate {
    func didDownloadFile(_ file: ICCameraFile, error: (any Error)?, options: [ICDownloadOption : Any], contextInfo: UnsafeMutableRawPointer?) {
        let fileName = file.name ?? "unknown"
        pendingDownloads.remove(fileName)

        if let error = error {
            AppLogger.log(.general, "[Tether] Download failed for \(fileName): \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "다운로드 실패: \(fileName)"
            }
            return
        }

        let savedURL = outputFolder.appendingPathComponent(fileName)
        AppLogger.log(.general, "[Tether] Downloaded: \(savedURL.path)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.captureCount += 1
            self.latestPhotoURL = savedURL
            self.statusMessage = "촬영 #\(self.captureCount): \(fileName)"
            self.onNewPhoto?(savedURL)
        }
    }
}
