import Foundation
import AppKit
import Darwin

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
    @Published var totalBytes: Int64 = 0  // 총 용량

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
    private var unmountObserver: NSObjectProtocol?

    deinit {
        stopMonitoring()
    }

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
        // 언마운트 감시 — 카드 제거 시 상태 정리
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let path = notification.userInfo?["NSDevicePath"] as? String else { return }
            let url = URL(fileURLWithPath: path)
            fputs("[CARD] 언마운트: \(url.lastPathComponent)\n", stderr)
            // 현재 감지된 볼륨이 제거되면 정리
            if self.detectedVolumeURL == url {
                self.detectedVolumeURL = nil
                self.detectedVolumeName = ""
            }
            if self.lastStartedVolume == url {
                self.lastStartedVolume = nil
            }
        }
    }

    func stopMonitoring() {
        if let observer = volumeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            volumeObserver = nil
        }
        if let observer = unmountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            unmountObserver = nil
        }
        waitingForNextCard = false
    }

    // MARK: - Memory Card Detection

    private var lastStartedVolume: URL?  // 중복 시작 방지

    func checkAndPromptIfMemoryCard(_ url: URL) {
        let hasDCIM = isMemoryCard(url)
        // 이미 이 볼륨 백업 중이거나 방금 시작했으면 스킵
        let alreadyBacking = sessions.contains { $0.volumeURL == url && !$0.isComplete }
        let justStarted = (lastStartedVolume == url)
        fputs("[CARD] check \(url.lastPathComponent) DCIM=\(hasDCIM) waiting=\(waitingForNextCard) already=\(alreadyBacking) justStarted=\(justStarted)\n", stderr)
        guard hasDCIM, !alreadyBacking, !justStarted else { return }

        detectedVolumeURL = url
        detectedVolumeName = url.lastPathComponent
        fputs("[CARD] ✅ Memory card detected: \(url.lastPathComponent)\n", stderr)

        DispatchQueue.main.async {
            if self.waitingForNextCard, let dest = self.destinationURL {
                // 다음 카드 자동 복사 시작 — 이전 상태 완전 정리
                self.showBackupResult = false
                self.showBackupPrompt = false
                self.waitingForNextCard = false
                self.sessions.removeAll { $0.isComplete }  // 완료된 이전 세션 제거
                self.lastStartedVolume = url
                fputs("[CARD] 자동 복사 시작 → \(dest.lastPathComponent)\n", stderr)
                self.startBackup(from: url, to: dest)
            } else if !self.showBackupPrompt && !self.isBackingUp && self.lastStartedVolume != url {
                // 첫 카드 → 폴더 선택 팝업 (백업 중 아닐 때만)
                self.lastStartedVolume = url
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
        session.totalBytes = photos.reduce(Int64(0)) { sum, url in
            sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        }
        session.startTime = CFAbsoluteTimeGetCurrent()

        DispatchQueue.main.async {
            self.sessions.append(session)
            self.objectWillChange.send()
        }

        fputs("[BACKUP] 시작: \(sourceVolume.lastPathComponent) → \(destination.lastPathComponent) (\(photos.count)장)\n", stderr)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            var failedFiles: [FailedFile] = []
            var skippedCount = 0
            let dcimPath = sourceVolume.appendingPathComponent("DCIM").path

            for (index, sourceURL) in photos.enumerated() {
                if session.isCancelled { break }

                let relativePath = sourceURL.path.replacingOccurrences(of: dcimPath + "/", with: "")
                let destURL = destination.appendingPathComponent(relativePath)
                let destDir = destURL.deletingLastPathComponent()
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

                // 이미 존재하면 크기까지 비교 — 일치하면 스킵, 다르면 재복사
                let srcSize = Self.fileSize(sourceURL)
                if fm.fileExists(atPath: destURL.path) {
                    let dstSize = Self.fileSize(destURL)
                    if srcSize > 0 && srcSize == dstSize {
                        skippedCount += 1
                        session.bytesCopied += srcSize
                        DispatchQueue.main.async {
                            session.done = index + 1
                            session.updateSpeedAndETA()
                            self.objectWillChange.send()
                        }
                        continue
                    }
                    try? fm.removeItem(at: destURL)
                }

                let tmpURL = destURL.appendingPathExtension("tmp_복사중")
                var success = false

                for retry in 0..<3 {
                    try? fm.removeItem(at: tmpURL)
                    // copyfile() C API — F_NOCACHE로 큰 파일 빠르게 복사
                    if Self.fastCopy(from: sourceURL, to: tmpURL) {
                        let dstSize = Self.fileSize(tmpURL)
                        if srcSize > 0 && srcSize == dstSize {
                            do {
                                try fm.moveItem(at: tmpURL, to: destURL)
                                session.bytesCopied += srcSize
                                success = true
                                break
                            } catch {
                                try? fm.removeItem(at: tmpURL)
                            }
                        } else {
                            try? fm.removeItem(at: tmpURL)
                        }
                    } else {
                        try? fm.removeItem(at: tmpURL)
                        if retry == 2 {
                            fputs("[BACKUP] 실패: \(sourceURL.lastPathComponent)\n", stderr)
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
                    // 완료된 세션 제거
                    self.sessions.removeAll { $0.id == session.id }
                    // eject 완료 후 waitingForNextCard 설정 (타이밍 이슈 방지)
                    self.ejectVolume(sourceVolume) {
                        DispatchQueue.main.async {
                            self.waitingForNextCard = true
                            fputs("[CARD] 추출 완료 → 다음 카드 대기 중\n", stderr)
                        }
                    }
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

    // MARK: - Fast Copy (copyfile C API + F_NOCACHE)

    /// copyfile() C API로 파일 복사 — FileManager.copyItem보다 빠름
    /// COPYFILE_CLONE: APFS→APFS면 즉시, 아니면 자동 fallback
    /// F_NOCACHE: 큰 파일을 unified buffer cache에 안 올림 (메모리 절약 + 속도 향상)
    private static func fastCopy(from src: URL, to dst: URL) -> Bool {
        let srcPath = src.path
        let dstPath = dst.path

        // copyfile() with CLONE 시도 (APFS→APFS면 즉시복사)
        let flags: copyfile_flags_t = UInt32(COPYFILE_ALL | COPYFILE_CLONE)
        let result = copyfile(srcPath, dstPath, nil, flags)

        if result == 0 {
            // 소스/대상에 F_NOCACHE 설정 — 대용량 파일 캐시 오염 방지
            if let fd = fopen(dstPath, "r") {
                fcntl(fileno(fd), F_NOCACHE, 1)
                fclose(fd)
            }
            return true
        }

        // copyfile 실패 시 수동 버퍼 복사 (4MB 버퍼)
        return manualBufferCopy(from: srcPath, to: dstPath)
    }

    /// 4MB 버퍼로 직접 read/write — SD카드 USB3.0에서 큰 버퍼가 빠름
    private static func manualBufferCopy(from srcPath: String, to dstPath: String) -> Bool {
        guard let srcFd = fopen(srcPath, "rb") else { return false }
        defer { fclose(srcFd) }
        guard let dstFd = fopen(dstPath, "wb") else { return false }
        defer { fclose(dstFd) }

        // F_NOCACHE — 큰 파일이 시스템 캐시를 오염시키지 않게
        fcntl(fileno(srcFd), F_NOCACHE, 1)
        fcntl(fileno(dstFd), F_NOCACHE, 1)

        let bufferSize = 4 * 1024 * 1024  // 4MB — SD카드 USB3.0 최적
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = fread(buffer, 1, bufferSize, srcFd)
            if bytesRead == 0 { break }
            let bytesWritten = fwrite(buffer, 1, bytesRead, dstFd)
            if bytesWritten != bytesRead { return false }
        }
        return ferror(srcFd) == 0
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: - Eject Volume

    private func ejectVolume(_ url: URL, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            proc.arguments = ["eject", url.path]
            try? proc.run()
            proc.waitUntilExit()
            let success = proc.terminationStatus == 0
            fputs("[BACKUP] eject \(url.lastPathComponent): \(success ? "성공" : "실패")\n", stderr)
            completion?()
        }
    }

    // MARK: - Next Card

    func waitForNextCard() {
        showBackupResult = false
        // 현재 카드 자동 언마운트 → 완료 후 대기 상태 전환
        if let vol = detectedVolumeURL {
            ejectVolume(vol) { [weak self] in
                DispatchQueue.main.async {
                    self?.detectedVolumeURL = nil
                    self?.detectedVolumeName = ""
                    self?.waitingForNextCard = true
                    fputs("[CARD] 추출 완료 → 다음 카드 대기 중\n", stderr)
                }
            }
        } else {
            waitingForNextCard = true
        }
    }

    func finishBackup() {
        waitingForNextCard = false
        showBackupResult = false
        showBackupPrompt = false
        backupResult = nil
        detectedVolumeURL = nil
        detectedVolumeName = ""
        lastStartedVolume = nil
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
