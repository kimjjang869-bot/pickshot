import Foundation
import AppKit

// MARK: - 개별 백업 세션 (카드 1장 = 세션 1개)

class BackupSession: ObservableObject, Identifiable {
    let id = UUID()
    let volumeURL: URL
    let volumeName: String
    let destinationURL: URL

    @Published var done: Int = 0
    @Published var total: Int = 0
    @Published var speed: String = ""
    @Published var eta: String = ""
    @Published var isCancelled = false
    @Published var isComplete = false
    @Published var result: BackupResult?

    var startTime: CFAbsoluteTime = 0
    var bytesCopied: Int64 = 0

    var progress: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    init(volumeURL: URL, destinationURL: URL) {
        self.volumeURL = volumeURL
        self.volumeName = volumeURL.lastPathComponent
        self.destinationURL = destinationURL
    }

    func cancel() { isCancelled = true }

    func updateSpeedAndETA() {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        guard elapsed > 0.5, done > 0 else { return }
        let bytesPerSec = Double(bytesCopied) / elapsed
        speed = String(format: "%.1f MB/s", bytesPerSec / 1_048_576)
        let rate = Double(done) / elapsed
        let remaining = Double(total - done) / rate
        if remaining < 60 {
            eta = "\(Int(remaining))초"
        } else {
            eta = "\(Int(remaining / 60))분 \(Int(remaining.truncatingRemainder(dividingBy: 60)))초"
        }
    }
}

// MARK: - 메모리카드 백업 서비스 (멀티 세션)

class MemoryCardBackupService: ObservableObject {
    static let shared = MemoryCardBackupService()

    @Published var sessions: [BackupSession] = []      // 활성 백업 세션들
    @Published var showBackupPrompt = false
    @Published var showBackupResult = false
    @Published var backupResult: BackupResult?
    @Published var detectedVolumeName: String = ""
    @Published var waitingForNextCard = false

    // 하위호환 — ContentView에서 참조
    var isBackingUp: Bool { !sessions.filter { !$0.isComplete }.isEmpty }
    var backupDone: Int { sessions.last?.done ?? 0 }
    var backupTotal: Int { sessions.last?.total ?? 0 }
    var backupSpeed: String { sessions.last?.speed ?? "" }
    var backupETA: String { sessions.last?.eta ?? "" }

    var detectedVolumeURL: URL?
    var destinationURL: URL?

    private var volumeObserver: NSObjectProtocol?

    private static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "arw", "cr2", "cr3", "nef", "nrw", "raf",
        "dng", "orf", "rw2", "pef", "srw", "3fr", "nefx",
        "heic", "heif", "tiff", "tif"
    ]

    // MARK: - Volume Monitoring

    func startMonitoring() {
        guard volumeObserver == nil else { return }
        volumeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let path = notification.userInfo?["NSDevicePath"] as? String else { return }
            let url = URL(fileURLWithPath: path)
            self.checkAndPromptIfMemoryCard(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.checkAndPromptIfMemoryCard(url)
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

    func checkAndPromptIfMemoryCard(_ url: URL) {
        let hasDCIM = isMemoryCard(url)
        // 이미 이 볼륨 백업 중이면 스킵
        let alreadyBacking = sessions.contains { $0.volumeURL == url && !$0.isComplete }
        fputs("[CARD] check \(url.lastPathComponent) DCIM=\(hasDCIM) waiting=\(waitingForNextCard) already=\(alreadyBacking)\n", stderr)
        guard hasDCIM, !alreadyBacking else { return }

        detectedVolumeURL = url
        detectedVolumeName = url.lastPathComponent
        fputs("[CARD] ✅ Memory card detected: \(url.lastPathComponent)\n", stderr)

        DispatchQueue.main.async {
            if self.waitingForNextCard, let dest = self.destinationURL {
                // 다음 카드 자동 복사 시작
                fputs("[CARD] 자동 복사 시작 → \(dest.lastPathComponent)\n", stderr)
                self.startBackup(from: url, to: dest)
            } else if !self.showBackupPrompt {
                // 첫 카드 → 폴더 선택 팝업
                self.showBackupPrompt = true
                self.objectWillChange.send()
            }
        }
    }

    private func isMemoryCard(_ volumeURL: URL) -> Bool {
        let dcimPath = volumeURL.appendingPathComponent("DCIM")
        return FileManager.default.fileExists(atPath: dcimPath.path)
    }

    // MARK: - Scan Files

    func scanPhotos(from volumeURL: URL) -> [URL] {
        let fm = FileManager.default
        var photos: [URL] = []
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

    // MARK: - Start Backup (멀티 세션)

    func startBackup(from sourceVolume: URL, to destination: URL) {
        let photos = scanPhotos(from: sourceVolume)
        guard !photos.isEmpty else {
            backupResult = BackupResult(total: 0, success: 0, skipped: 0, failed: [], volumeName: sourceVolume.lastPathComponent, cancelled: false)
            showBackupResult = true
            return
        }

        destinationURL = destination
        let session = BackupSession(volumeURL: sourceVolume, destinationURL: destination)
        session.total = photos.count
        session.startTime = CFAbsoluteTimeGetCurrent()

        DispatchQueue.main.async {
            self.sessions.append(session)
            self.objectWillChange.send()
        }

        fputs("[BACKUP] 시작: \(sourceVolume.lastPathComponent) → \(destination.lastPathComponent) (\(photos.count)장)\n", stderr)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            var failedFiles: [FailedFile] = []
            var skippedCount = 0

            for (index, sourceURL) in photos.enumerated() {
                if session.isCancelled { break }

                let dcimPath = sourceVolume.appendingPathComponent("DCIM").path
                let relativePath = sourceURL.path.replacingOccurrences(of: dcimPath + "/", with: "")
                let destURL = destination.appendingPathComponent(relativePath)
                let destDir = destURL.deletingLastPathComponent()
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

                // 이미 존재하면 크기까지 비교 — 일치하면 스킵, 다르면 재복사
                if fm.fileExists(atPath: destURL.path) {
                    let srcSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? 0
                    let dstSize = (try? fm.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
                    if srcSize > 0 && srcSize == dstSize {
                        skippedCount += 1
                        DispatchQueue.main.async {
                            session.done = index + 1
                            session.updateSpeedAndETA()
                            self.objectWillChange.send()
                        }
                        continue
                    }
                    // 크기 다름 → 기존 파일 삭제 후 재복사
                    try? fm.removeItem(at: destURL)
                }

                let tmpURL = destURL.appendingPathExtension("tmp_복사중")
                var success = false

                for retry in 0..<3 {
                    do {
                        try? fm.removeItem(at: tmpURL)
                        try fm.copyItem(at: sourceURL, to: tmpURL)
                        let srcSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? 0
                        let dstSize = (try? fm.attributesOfItem(atPath: tmpURL.path)[.size] as? Int64) ?? 0
                        if srcSize > 0 && srcSize == dstSize {
                            try fm.moveItem(at: tmpURL, to: destURL)
                            session.bytesCopied += srcSize
                            success = true
                            break
                        } else {
                            try? fm.removeItem(at: tmpURL)
                        }
                    } catch {
                        try? fm.removeItem(at: tmpURL)
                        if retry == 2 {
                            fputs("[BACKUP] 실패: \(sourceURL.lastPathComponent) - \(error.localizedDescription)\n", stderr)
                        }
                    }
                }

                if !success {
                    failedFiles.append(FailedFile(name: sourceURL.lastPathComponent, reason: "복사 실패"))
                }

                DispatchQueue.main.async {
                    session.done = index + 1
                    session.updateSpeedAndETA()
                    self.objectWillChange.send()
                }
            }

            let result = BackupResult(
                total: photos.count,
                success: photos.count - failedFiles.count,
                skipped: skippedCount,
                failed: failedFiles,
                volumeName: sourceVolume.lastPathComponent,
                cancelled: session.isCancelled
            )

            DispatchQueue.main.async {
                session.isComplete = true
                session.result = result
                self.backupResult = result
                self.showBackupResult = true
                self.objectWillChange.send()

                let allSuccess = failedFiles.isEmpty && !session.isCancelled
                fputs("[BACKUP] 완료: \(result.success)/\(result.total), 실패: \(failedFiles.count)\n", stderr)

                if allSuccess {
                    self.ejectVolume(sourceVolume)
                    self.waitingForNextCard = true
                    // 완료된 세션 제거
                    self.sessions.removeAll { $0.id == session.id }
                }
            }
        }
    }

    func cancelBackup() {
        sessions.forEach { $0.cancel() }
    }

    func cancelSession(_ session: BackupSession) {
        session.cancel()
    }

    // MARK: - Eject Volume

    private func ejectVolume(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            proc.arguments = ["eject", url.path]
            try? proc.run()
            proc.waitUntilExit()
            let success = proc.terminationStatus == 0
            fputs("[BACKUP] eject \(url.lastPathComponent): \(success ? "성공" : "실패")\n", stderr)
        }
    }

    // MARK: - Next Card

    func waitForNextCard() {
        waitingForNextCard = true
        // 현재 카드 자동 언마운트
        if let vol = detectedVolumeURL {
            ejectVolume(vol)
        }
    }

    func finishBackup() {
        waitingForNextCard = false
        sessions.removeAll()
    }
}

// MARK: - Models

struct BackupResult {
    let total: Int
    let success: Int
    let skipped: Int       // 이미 존재해서 스킵
    let failed: [FailedFile]
    let volumeName: String
    let cancelled: Bool

    var copied: Int { success - skipped }
    var notCopied: Int { total - success }
}

struct FailedFile: Identifiable {
    let id = UUID()
    let name: String
    let reason: String
}
