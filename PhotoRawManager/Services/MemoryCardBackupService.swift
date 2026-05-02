import Foundation
import AppKit
import Darwin

// MARK: - 잠자기 방지 (긴 복사/백업 작업 보호)
// 백업이나 대량 export 도중 잠자기 진입 시 디스크 I/O 가 멎어 복사가 멈추던 문제 방지.
// ProcessInfo.beginActivity 가 Apple-권장 방식 — endActivity 까지 시스템 슬립 차단.
final class SleepPreventer {
    private var token: NSObjectProtocol?
    private let reason: String

    init(reason: String) { self.reason = reason }

    func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: reason
        )
        plog("[SLEEP-GUARD] begin: \(reason)\n")
    }

    func end() {
        if let t = token {
            ProcessInfo.processInfo.endActivity(t)
            token = nil
            plog("[SLEEP-GUARD] end: \(reason)\n")
        }
    }

    deinit { end() }
}

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

    private static let photoExtensions: Set<String> = FileMatchingService.allMediaExtensions

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
            plog("[CARD] 언마운트: \(url.lastPathComponent)\n")
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
        plog("[CARD] check \(url.lastPathComponent) DCIM=\(hasDCIM) waiting=\(waitingForNextCard) already=\(alreadyBacking) justStarted=\(justStarted)\n")
        guard hasDCIM, !alreadyBacking, !justStarted else { return }

        detectedVolumeURL = url
        detectedVolumeName = url.lastPathComponent
        plog("[CARD] ✅ Memory card detected: \(url.lastPathComponent)\n")

        DispatchQueue.main.async {
            if self.waitingForNextCard, let dest = self.destinationURL {
                // 다음 카드 자동 복사 시작 — 이전 상태 완전 정리
                self.showBackupResult = false
                self.showBackupPrompt = false
                self.waitingForNextCard = false
                self.sessions.removeAll { $0.isComplete }  // 완료된 이전 세션 제거
                self.lastStartedVolume = url
                plog("[CARD] 자동 복사 시작 → \(dest.lastPathComponent)\n")
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

        plog("[BACKUP] 시작: \(sourceVolume.lastPathComponent) → \(destination.lastPathComponent) (\(photos.count)장)\n")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // 잠자기 차단 — 백업 도중 시스템 슬립 진입 시 SD 카드 I/O 가 멎어 복사가 멈추던 문제 방지
            let sleepGuard = SleepPreventer(reason: "PickShot 메모리카드 백업: \(sourceVolume.lastPathComponent)")
            sleepGuard.begin()
            defer { sleepGuard.end() }

            let fm = FileManager.default
            let backupStartTime = CFAbsoluteTimeGetCurrent()
            var failedFiles: [FailedFile] = []
            var skippedCount = 0
            let dcimPath = sourceVolume.appendingPathComponent("DCIM").path

            // SD카드 순차 복사 (16MB 버퍼 + F_NOCACHE + F_RDAHEAD)
            for (index, sourceURL) in photos.enumerated() {
                if session.isCancelled { break }

                let relativePath = sourceURL.path.replacingOccurrences(of: dcimPath + "/", with: "")
                let destURL = destination.appendingPathComponent(relativePath)
                let destDir = destURL.deletingLastPathComponent()
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

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

                var success = false

                for retry in 0..<3 {
                    try? fm.removeItem(at: destURL)
                    if Self.fastCopy(from: sourceURL, to: destURL) {
                        let dstSize = Self.fileSize(destURL)
                        if srcSize > 0 && srcSize == dstSize {
                            session.bytesCopied += srcSize
                            success = true
                            break
                        } else {
                            try? fm.removeItem(at: destURL)
                        }
                    } else {
                        try? fm.removeItem(at: destURL)
                        if retry == 2 {
                            plog("[BACKUP] 실패: \(sourceURL.lastPathComponent)\n")
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
                let elapsed = CFAbsoluteTimeGetCurrent() - backupStartTime
                let totalMB = Double(session.bytesCopied) / 1_048_576.0
                let speed = elapsed > 0 ? totalMB / elapsed : 0
                plog("[BACKUP] 완료: \(result.success)/\(result.total), 실패: \(failedFiles.count), \(String(format: "%.1f", totalMB))MB, \(String(format: "%.1f", elapsed))초, \(String(format: "%.1f", speed))MB/s\n")

                if allSuccess {
                    // 완료된 세션 제거
                    self.sessions.removeAll { $0.id == session.id }
                    // 자동 eject 안 함 — 사용자가 "다음 카드"(eject) or "종료"(eject 안 함) 선택
                    plog("[CARD] 백업 완료 → 사용자 선택 대기 (다음 카드/종료)\n")
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

    /// 파일 복사 — copyfile() → 수동 버퍼 → FileManager fallback
    private static func fastCopy(from src: URL, to dst: URL) -> Bool {
        let srcPath = src.path
        let dstPath = dst.path

        // 1차: copyfile() C API (APFS 클론 + 메타데이터 복사)
        let flags: copyfile_flags_t = UInt32(COPYFILE_ALL | COPYFILE_CLONE)
        if copyfile(srcPath, dstPath, nil, flags) == 0 {
            return true
        }

        // 2차: 수동 버퍼 복사 (16MB + F_NOCACHE)
        if manualBufferCopy(from: srcPath, to: dstPath) {
            return true
        }

        // 3차: FileManager fallback (가장 안전)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return true
        } catch {
            plog("[BACKUP] copyItem도 실패: \(src.lastPathComponent) → \(error.localizedDescription)\n")
            return false
        }
    }

    /// 16MB 버퍼 + F_NOCACHE + read/write syscall
    private static func manualBufferCopy(from srcPath: String, to dstPath: String) -> Bool {
        let srcFd = open(srcPath, O_RDONLY)
        guard srcFd >= 0 else { return false }
        defer { close(srcFd) }

        // 0o644 — 안전한 기본 퍼미션 (SD카드 st_mode가 이상할 수 있음)
        let dstFd = open(dstPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard dstFd >= 0 else {
            return false
        }
        defer { close(dstFd) }

        _ = fcntl(srcFd, F_NOCACHE, 1)
        _ = fcntl(dstFd, F_NOCACHE, 1)
        _ = fcntl(srcFd, F_RDAHEAD, 1)

        let bufferSize = 16 * 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = read(srcFd, buffer, bufferSize)
            if bytesRead <= 0 { break }
            var written = 0
            while written < bytesRead {
                let w = write(dstFd, buffer + written, bytesRead - written)
                if w < 0 { return false }
                written += w
            }
        }
        return true
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: - Eject Volume

    private func ejectVolume(_ url: URL, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            var success = false
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                success = true
            } catch {
                plog("[BACKUP] eject error: \(error)\n")
            }
            plog("[BACKUP] eject \(url.lastPathComponent): \(success ? "성공" : "실패")\n")
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
                    self?.lastStartedVolume = nil  // 같은 마운트포인트에 새 카드 감지 허용
                    self?.waitingForNextCard = true
                    plog("[CARD] 추출 완료 → 다음 카드 대기 중\n")
                }
            }
        } else {
            lastStartedVolume = nil
            waitingForNextCard = true
        }
    }

    /// 카드 꺼내기 + 종료
    func ejectAndFinish() {
        if let vol = detectedVolumeURL {
            ejectVolume(vol) { [weak self] in
                DispatchQueue.main.async {
                    plog("[CARD] 꺼내기 완료: \(vol.lastPathComponent)\n")
                    self?.finishBackup()
                }
            }
        } else {
            finishBackup()
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
