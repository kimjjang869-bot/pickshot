import Foundation
import AppKit

/// 메모리카드 자동 백업 서비스
/// 볼륨 마운트 감지 → DCIM 폴더 탐지 → 안전 복사 (tmp → verify → rename)
class MemoryCardBackupService: ObservableObject {
    static let shared = MemoryCardBackupService()

    // MARK: - State

    @Published var isBackingUp = false
    @Published var backupDone: Int = 0
    @Published var backupTotal: Int = 0
    @Published var backupSpeed: String = ""        // "45.2 MB/s"
    @Published var backupETA: String = ""           // "2분 30초"
    @Published var backupCancelled = false
    @Published var showBackupPrompt = false         // 백업 폴더 선택 다이얼로그
    @Published var showNextCardPrompt = false       // 다음 메모리카드 다이얼로그
    @Published var showBackupResult = false
    @Published var backupResult: BackupResult?
    @Published var detectedVolumeName: String = ""
    @Published var waitingForNextCard = false

    var detectedVolumeURL: URL?
    var destinationURL: URL?
    var backupStartTime: CFAbsoluteTime = 0
    var totalBytesCopied: Int64 = 0

    var backupProgress: Double {
        backupTotal > 0 ? Double(backupDone) / Double(backupTotal) : 0
    }

    // MARK: - Photo extensions

    private static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "arw", "cr2", "cr3", "nef", "nrw", "raf",
        "dng", "orf", "rw2", "pef", "srw", "3fr", "nefx",
        "heic", "heif", "tiff", "tif"
    ]

    // MARK: - Volume Monitoring

    private var volumeObserver: NSObjectProtocol?

    func startMonitoring() {
        guard volumeObserver == nil else { return }
        volumeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let path = notification.userInfo?["NSDevicePath"] as? String else { return }
            let url = URL(fileURLWithPath: path)
            AppLogger.log(.general, "Volume mounted: \(path)")

            // 메모리카드 판별 (DCIM 폴더 존재)
            if self.isMemoryCard(url) {
                self.detectedVolumeURL = url
                self.detectedVolumeName = url.lastPathComponent
                self.showBackupPrompt = true
                AppLogger.log(.general, "Memory card detected: \(url.lastPathComponent)")
            }
        }
    }

    func stopMonitoring() {
        if let observer = volumeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            volumeObserver = nil
        }
        waitingForNextCard = false
    }

    // MARK: - Memory Card Detection

    private func isMemoryCard(_ volumeURL: URL) -> Bool {
        let dcimPath = volumeURL.appendingPathComponent("DCIM")
        return FileManager.default.fileExists(atPath: dcimPath.path)
    }

    // MARK: - Scan Files

    func scanPhotos(from volumeURL: URL) -> [URL] {
        let fm = FileManager.default
        var photos: [URL] = []

        // DCIM 폴더 내 재귀 탐색
        let dcimURL = volumeURL.appendingPathComponent("DCIM")
        guard let enumerator = fm.enumerator(
            at: dcimURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            if Self.photoExtensions.contains(ext) {
                photos.append(fileURL)
            }
        }

        return photos.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Safe Copy (tmp → verify → rename)

    func startBackup(from sourceVolume: URL, to destination: URL) {
        guard !isBackingUp else { return }

        let photos = scanPhotos(from: sourceVolume)
        guard !photos.isEmpty else {
            backupResult = BackupResult(total: 0, success: 0, failed: [], volumeName: sourceVolume.lastPathComponent)
            showBackupResult = true
            return
        }

        isBackingUp = true
        backupCancelled = false
        backupDone = 0
        backupTotal = photos.count
        backupStartTime = CFAbsoluteTimeGetCurrent()
        totalBytesCopied = 0
        destinationURL = destination

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let fm = FileManager.default
            var failedFiles: [FailedFile] = []
            let maxRetries = 3

            for (index, sourceURL) in photos.enumerated() {
                if self.backupCancelled { break }

                // 상대 경로 유지 (DCIM/100MSDCF/DSC00001.ARW → 100MSDCF/DSC00001.ARW)
                let dcimPath = sourceVolume.appendingPathComponent("DCIM").path
                let relativePath = sourceURL.path.replacingOccurrences(of: dcimPath + "/", with: "")
                let destURL = destination.appendingPathComponent(relativePath)
                let destDir = destURL.deletingLastPathComponent()

                // 대상 폴더 생성
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

                // 이미 존재하면 스킵
                if fm.fileExists(atPath: destURL.path) {
                    DispatchQueue.main.async {
                        self.backupDone = index + 1
                        self.updateSpeedAndETA()
                    }
                    continue
                }

                // 안전 복사: tmp 파일로 먼저 쓰기
                let tmpURL = destURL.appendingPathExtension("tmp_복사중")
                var success = false

                for retry in 0..<maxRetries {
                    do {
                        // 이전 tmp 파일 제거
                        try? fm.removeItem(at: tmpURL)

                        // 복사
                        try fm.copyItem(at: sourceURL, to: tmpURL)

                        // 검증: 파일 크기 비교
                        let srcSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? 0
                        let dstSize = (try? fm.attributesOfItem(atPath: tmpURL.path)[.size] as? Int64) ?? 0

                        if srcSize > 0 && srcSize == dstSize {
                            // 검증 통과 → 최종 리네임
                            try fm.moveItem(at: tmpURL, to: destURL)
                            self.totalBytesCopied += srcSize
                            success = true
                            break
                        } else {
                            // 크기 불일치 → 재시도
                            try? fm.removeItem(at: tmpURL)
                            AppLogger.log(.general, "Backup verify failed (retry \(retry+1)): \(sourceURL.lastPathComponent) src=\(srcSize) dst=\(dstSize)")
                        }
                    } catch {
                        try? fm.removeItem(at: tmpURL)
                        if retry == maxRetries - 1 {
                            AppLogger.log(.general, "Backup copy failed: \(sourceURL.lastPathComponent) error=\(error.localizedDescription)")
                        }
                    }
                }

                if !success {
                    failedFiles.append(FailedFile(name: sourceURL.lastPathComponent, reason: "복사 실패 (3회 재시도)"))
                }

                DispatchQueue.main.async {
                    self.backupDone = index + 1
                    self.updateSpeedAndETA()
                }
            }

            // 완료
            let result = BackupResult(
                total: photos.count,
                success: photos.count - failedFiles.count,
                failed: failedFiles,
                volumeName: sourceVolume.lastPathComponent
            )

            DispatchQueue.main.async {
                self.isBackingUp = false
                self.backupResult = result
                self.showBackupResult = true

                // 볼륨 자동 해제
                if !self.backupCancelled {
                    self.ejectVolume(sourceVolume)
                }

                AppLogger.log(.general, "Backup complete: \(result.success)/\(result.total) files, \(failedFiles.count) failed")
            }
        }
    }

    func cancelBackup() {
        backupCancelled = true
    }

    // MARK: - Speed & ETA

    private func updateSpeedAndETA() {
        let elapsed = CFAbsoluteTimeGetCurrent() - backupStartTime
        guard elapsed > 0.5, backupDone > 0 else { return }

        // 속도 (MB/s)
        let bytesPerSec = Double(totalBytesCopied) / elapsed
        let mbPerSec = bytesPerSec / 1_048_576
        backupSpeed = String(format: "%.1f MB/s", mbPerSec)

        // ETA
        let rate = Double(backupDone) / elapsed
        let remaining = Double(backupTotal - backupDone) / rate
        if remaining < 60 {
            backupETA = "\(Int(remaining))초"
        } else {
            backupETA = "\(Int(remaining / 60))분 \(Int(remaining.truncatingRemainder(dividingBy: 60)))초"
        }
    }

    // MARK: - Eject Volume

    private func ejectVolume(_ url: URL) {
        let success = NSWorkspace.shared.unmountAndEjectDevice(atPath: url.path)
        AppLogger.log(.general, "Eject \(url.lastPathComponent): \(success ? "성공" : "실패")")
    }

    // MARK: - Next Card

    func waitForNextCard() {
        waitingForNextCard = true
        showNextCardPrompt = false
        // 볼륨 모니터링은 이미 실행 중 → 다음 마운트 시 showBackupPrompt 트리거
    }

    func finishBackup() {
        waitingForNextCard = false
        showNextCardPrompt = false
        stopMonitoring()
    }
}

// MARK: - Models

struct BackupResult {
    let total: Int
    let success: Int
    let failed: [FailedFile]
    let volumeName: String
}

struct FailedFile: Identifiable {
    let id = UUID()
    let name: String
    let reason: String
}
