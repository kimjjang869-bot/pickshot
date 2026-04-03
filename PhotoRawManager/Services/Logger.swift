import Foundation
import AppKit

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
                // Write header
                let header = "=== PickShot Log ===\nVersion: \(appVersion)\nDevice: \(deviceName)\nDate: \(dateStr)\nOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n===\n"
                try? header.write(to: logFile, atomically: true, encoding: .utf8)
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

        // Filename: {computerName}_{IP}_{version}_{date}.log
        let fileName = "\(deviceName)_\(localIP)_v\(appVersion)_\(DateFormatter.logDateFormatter.string(from: Date())).log"

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
