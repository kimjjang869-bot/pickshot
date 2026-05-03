import Foundation
import AppKit
import Metal
import Darwin

enum LogCategory: String {
    case preview = "📷"
    case thumbnail = "🖼"
    case folder = "📂"
    case exif = "📋"
    case selection = "👆"
    case rating = "⭐"
    case export = "📦"
    case gselect = "☁️"
    case analysis = "🔬"
    case cache = "💾"
    case performance = "⚡"
    case error = "❌"
    case general = "ℹ️"
}

class AppLogger {
    static var isEnabled: Bool = true

    // MARK: - File Logging

    private static let logQueue = DispatchQueue(label: "com.pickshot.logger", qos: .utility)
    private static var fileHandle: FileHandle?
    private static var currentLogDate: String = ""

    static var logDirectory: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = cachesDir.appendingPathComponent("PickShot/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var currentLogFile: URL {
        let dateStr = DateFormatter.logDateFormatter.string(from: Date())
        return logDirectory.appendingPathComponent("pickshot_\(dateStr).log")
    }

    /// Open general app log folder in Finder.
    static func openLogFolder() {
        NSWorkspace.shared.open(logDirectory)
    }

    /// v9.1.4: 30일 이상된 로그 파일 자동 삭제 (보안 감사 M-3).
    ///   장기 사용자의 로그 누적 (수십 MB) + 민감 정보 잔존 시간 단축.
    ///   앱 시작 시 1회 호출.
    static func purgeOldLogs(maxAgeDays: Int = 30) {
        let dir = logDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let threshold = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)
        var purged = 0
        for url in files where url.pathExtension == "log" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if mtime < threshold {
                if (try? fm.removeItem(at: url)) != nil { purged += 1 }
            }
        }
        if purged > 0 {
            print("[Logger] 30일 이상된 로그 \(purged)개 자동 삭제")
        }
    }

    static func log(_ category: LogCategory, _ message: String) {
        guard isEnabled else { return }
        let timestamp = String(format: "%.3f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000))
        let line = "\(category.rawValue) [\(timestamp)] \(message)"
        print(line)

        // Write to file
        logQueue.async {
            writeToFile(line)
        }
    }

    static func time(_ category: LogCategory, _ label: String, _ block: () -> Void) {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        log(category, "\(label) took \(String(format: "%.1f", elapsed))ms")
    }

    // MARK: - File Writing

    private static func writeToFile(_ line: String) {
        let dateStr = DateFormatter.logDateFormatter.string(from: Date())
        let logFile = logDirectory.appendingPathComponent("pickshot_\(dateStr).log")

        // Rotate file handle if date changed
        if dateStr != currentLogDate {
            fileHandle?.closeFile()
            fileHandle = nil
            currentLogDate = dateStr
        }

        if fileHandle == nil {
            if !FileManager.default.fileExists(atPath: logFile.path) {
                // Write header (상세 하드웨어 정보 포함)
                let header = buildLogHeader(dateStr: dateStr)
                try? header.write(to: logFile, atomically: true, encoding: .utf8)
                // v9.1.4 보안 (L-2): 로그 파일 권한 0600 — 다른 프로세스 read 차단 (민감 정보 보호).
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: logFile.path
                )
            }
            fileHandle = FileHandle(forWritingAtPath: logFile.path)
            fileHandle?.seekToEndOfFile()
        }

        let timeStr = DateFormatter.logTimeFormatter.string(from: Date())
        if let data = "[\(timeStr)] \(line)\n".data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    // MARK: - Log Upload to Google Drive

    /// Upload current log file to Google Drive "PickShot_Logs" folder
    static func sendLogToGoogleDrive(completion: @escaping (Bool, String) -> Void) {
        guard let token = GoogleDriveService.savedAccessToken else {
            completion(false, "Google Drive 로그인이 필요합니다")
            return
        }

        // Flush file handle
        logQueue.sync {
            fileHandle?.synchronizeFile()
        }

        let logFile = currentLogFile
        guard FileManager.default.fileExists(atPath: logFile.path) else {
            completion(false, "로그 파일이 없습니다")
            return
        }

        // v9.1.4: IP / 기기명 평문 노출 제거 (보안 감사 C-4).
        //   App Store / GDPR / 한국 개인정보법 — 사용자 식별자 외부 전송 시 사전 동의 필요.
        //   기기명을 SHA1 prefix 8자로 해시하여 로그 식별성만 유지.
        let deviceHash = Self.deviceIdentifierHash(deviceName: deviceName)
        let fileName = "device-\(deviceHash)_v\(appVersion)_\(DateFormatter.logDateFormatter.string(from: Date())).log"

        // First: find or create "PickShot_Logs" folder
        findOrCreateLogsFolder(token: token) { folderId in
            guard let folderId = folderId else {
                completion(false, "로그 폴더 생성 실패")
                return
            }

            // Rename log file for upload
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.copyItem(at: logFile, to: tempURL)

            GoogleDriveService.uploadFile(fileURL: tempURL, folderId: folderId, accessToken: token) { result, error in
                try? FileManager.default.removeItem(at: tempURL)
                if let _ = result {
                    completion(true, "로그가 전송되었습니다 (\(fileName))")
                } else {
                    completion(false, "업로드 실패: \(error?.localizedDescription ?? "알 수 없는 오류")")
                }
            }
        }
    }

    private static func findOrCreateLogsFolder(token: String, completion: @escaping (String?) -> Void) {
        // Search for existing folder
        let query = "name='PickShot_Logs' and mimeType='application/vnd.google-apps.folder' and trashed=false"
        let urlStr = "https://www.googleapis.com/drive/v3/files?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&fields=files(id)"
        guard let url = URL(string: urlStr) else { completion(nil); return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let files = json["files"] as? [[String: Any]],
               let existingId = files.first?["id"] as? String {
                completion(existingId)
                return
            }

            // Create folder
            GoogleDriveService.createFolder(name: "PickShot_Logs", accessToken: token) { folderId, _ in
                completion(folderId)
            }
        }.resume()
    }

    // MARK: - Device Info

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    static var deviceName: String {
        Host.current().localizedName?.replacingOccurrences(of: " ", with: "_") ?? "unknown"
    }

    /// v9.1.4: 기기명 해시 (외부 전송용 — 식별성만 유지하고 평문 누설 방지).
    ///   동일 기기에서 일관된 8자 prefix 를 반환해서 같은 사용자의 로그 묶음을 구분 가능.
    static func deviceIdentifierHash(deviceName: String) -> String {
        var hash = UInt64(14695981039346656037)  // FNV-1a offset
        for byte in deviceName.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%08x", hash & 0xFFFF_FFFF)
    }

    // MARK: - Hardware Info (상세 PC 스펙)

    /// 앱 시작 시각 (uptime 계산용). PerformanceMonitor.start()에서도 공유.
    static let appStartDate: Date = Date()

    /// 전체 로그 헤더 생성. 파일 작성 또는 PerformanceMonitor에서 공유.
    static func buildLogHeader(dateStr: String) -> String {
        var lines: [String] = []
        lines.append("=== PickShot Log ===")
        lines.append("Version: \(appVersion)\(appBuildSuffix)")
        // v9.1.4 보안 (M-1): 평문 기기 실명 → 해시 ID 만 기록 (식별성 유지 + PII 누설 방지).
        lines.append("Device: \(Self.deviceIdentifierHash(deviceName: deviceName))")
        lines.append("Date: \(dateStr)")
        lines.append("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("--- Hardware ---")
        lines.append(contentsOf: hardwareInfoLines)
        lines.append("===\n")
        return lines.joined(separator: "\n")
    }

    /// 공유 가능한 하드웨어 정보 라인 리스트. Logger/PerformanceMonitor에서 재사용.
    static var hardwareInfoLines: [String] {
        var out: [String] = []

        let hwModelRaw = sysctlString("hw.model") ?? "Unknown"
        let marketing = modelMarketingMap[hwModelRaw]
        if let m = marketing {
            out.append("Mac Model: \(m) [\(hwModelRaw)]")
        } else {
            out.append("Mac Model: \(hwModelRaw)")
        }

        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        out.append("Chip: \(chip)")

        let logical = sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let pCores = sysctlInt("hw.perflevel0.logicalcpu")
        let eCores = sysctlInt("hw.perflevel1.logicalcpu")
        if let p = pCores, let e = eCores {
            out.append("CPU Cores: \(logical) (P: \(p), E: \(e))")
        } else {
            out.append("CPU Cores: \(logical)")
        }

        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        out.append("RAM: \(String(format: "%.0f", ramGB)) GB")

        let gpuName = MTLCreateSystemDefaultDevice()?.name ?? "Unknown"
        out.append("GPU: \(gpuName)")

        // Storage: 시스템 볼륨
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
            let totalBytes = (attrs[.systemSize] as? NSNumber)?.doubleValue ?? 0
            let freeBytes = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
            let totalGB = totalBytes / 1_073_741_824.0
            let freeGB = freeBytes / 1_073_741_824.0
            out.append("Storage: \(String(format: "%.0f", totalGB)) GB (free \(String(format: "%.0f", freeGB)) GB)")
        } else {
            out.append("Storage: Unknown")
        }

        // Display: 메인 스크린
        if let screen = NSScreen.main {
            let size = screen.frame.size
            let scale = screen.backingScaleFactor
            let pxW = Int(size.width * scale)
            let pxH = Int(size.height * scale)
            var hz = 60
            if #available(macOS 12.0, *) {
                hz = screen.maximumFramesPerSecond
            }
            out.append("Display: \(pxW) x \(pxH) @ \(hz)Hz, Scale \(String(format: "%.1f", scale))")
        } else {
            out.append("Display: Unknown")
        }

        let locale = Locale.current.identifier
        out.append("Locale: \(locale)")

        let tz = TimeZone.current.identifier
        let abbr = TimeZone.current.abbreviation() ?? ""
        out.append("Timezone: \(tz)\(abbr.isEmpty ? "" : " (\(abbr))")")

        let uptime = Int(Date().timeIntervalSince(appStartDate))
        out.append("App Uptime: \(uptime)s")

        // 샌드박스 감지 (APP_SANDBOX_CONTAINER_ID 환경변수)
        let sandbox = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        out.append("App Sandbox: \(sandbox ? "Yes" : "No")")

        return out
    }

    /// build number 접미사 ("(build 20)") — 없으면 빈 문자열.
    static var appBuildSuffix: String {
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, !build.isEmpty {
            return " (build \(build))"
        }
        return ""
    }

    /// sysctl 문자열 값 조회. 실패 시 nil.
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 || size == 0 { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        if sysctlbyname(name, &bytes, &size, nil, 0) != 0 { return nil }
        return String(cString: bytes)
    }

    /// sysctl Int 값 조회. 실패 시 nil.
    static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        if sysctlbyname(name, &value, &size, nil, 0) != 0 { return nil }
        return value
    }

    /// 주요 Mac 모델 식별자 → 마케팅 네임. 없으면 hw.model 그대로.
    private static let modelMarketingMap: [String: String] = [
        "MacBookPro18,1": "MacBook Pro 16-inch (M1 Pro/Max, 2021)",
        "MacBookPro18,2": "MacBook Pro 16-inch (M1 Pro/Max, 2021)",
        "MacBookPro18,3": "MacBook Pro 14-inch (M1 Pro/Max, 2021)",
        "MacBookPro18,4": "MacBook Pro 14-inch (M1 Pro/Max, 2021)",
        "Mac14,5": "MacBook Pro 14-inch (M2 Pro/Max, 2023)",
        "Mac14,6": "MacBook Pro 16-inch (M2 Pro/Max, 2023)",
        "Mac14,7": "MacBook Pro 13-inch (M2, 2022)",
        "Mac14,9": "MacBook Pro 14-inch (M2 Pro/Max, 2023)",
        "Mac14,10": "MacBook Pro 16-inch (M2 Pro/Max, 2023)",
        "Mac15,3": "MacBook Pro 14-inch (M3, 2023)",
        "Mac15,6": "MacBook Pro 14-inch (M3 Pro/Max, 2023)",
        "Mac15,7": "MacBook Pro 16-inch (M3 Pro/Max, 2023)",
        "Mac15,8": "MacBook Pro 14-inch (M3 Max, 2023)",
        "Mac15,9": "MacBook Pro 16-inch (M3 Max, 2023)",
        "Mac16,1": "MacBook Pro 14-inch (M4, 2024)",
        "Mac16,6": "MacBook Pro 14-inch (M4 Pro/Max, 2024)",
        "Mac16,8": "MacBook Pro 16-inch (M4 Pro/Max, 2024)",
        "Mac14,2": "MacBook Air 13-inch (M2, 2022)",
        "Mac14,15": "MacBook Air 15-inch (M2, 2023)",
        "Mac15,12": "MacBook Air 13-inch (M3, 2024)",
        "Mac15,13": "MacBook Air 15-inch (M3, 2024)",
        "Mac14,3": "Mac mini (M2, 2023)",
        "Mac14,12": "Mac mini (M2 Pro, 2023)",
        "Mac15,4": "Mac mini (M4, 2024)",
        "Mac15,5": "Mac mini (M4 Pro, 2024)",
        "Mac13,1": "Mac Studio (M1 Max, 2022)",
        "Mac13,2": "Mac Studio (M1 Ultra, 2022)",
        "Mac14,13": "Mac Studio (M2 Max, 2023)",
        "Mac14,14": "Mac Studio (M2 Ultra, 2023)",
        "Mac15,14": "Mac Studio (M4 Max, 2025)",
        "iMac21,1": "iMac 24-inch (M1, 2021)",
        "iMac21,2": "iMac 24-inch (M1, 2021)",
    ]

    /// 현재 시스템 볼륨 여유 공간 (GB). 주기적 샘플링에서 사용.
    static func currentFreeDiskGB() -> Double {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let freeBytes = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue {
            return freeBytes / 1_073_741_824.0
        }
        return 0
    }

    static var localIP: String {
        var address = "unknown"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }
}

// MARK: - DateFormatter helpers

private extension DateFormatter {
    static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
