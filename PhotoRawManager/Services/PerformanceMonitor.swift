import Foundation
import AppKit

// MARK: - Performance Monitor (메모리, CPU, 응답시간 감시 + 로그 파일 생성)

class PerformanceMonitor {
    static let shared = PerformanceMonitor()

    private var timer: DispatchSourceTimer?
    private var logFileURL: URL?
    private var logHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.pickshot.perfmonitor", qos: .utility)

    // Thresholds
    private let memoryWarningMB: Double = 2048      // 2GB
    private let memoryCriticalMB: Double = 4096     // 4GB
    private let cpuWarningPercent: Double = 80       // 80%
    private let cpuCriticalPercent: Double = 150     // 150% (multi-core)

    // Tracking
    private var lastLogTime: Date = .distantPast
    private var peakMemoryMB: Double = 0
    private var peakCPU: Double = 0
    private var warningCount: Int = 0
    private var startTime: Date = Date()

    private init() {}

    // MARK: - Start/Stop

    func start() {
        startTime = Date()
        setupLogFile()
        writeLog("=== PickShot Performance Monitor Started ===")
        writeLog("App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        writeLog("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        writeLog("RAM: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)GB")
        writeLog("CPU Cores: \(ProcessInfo.processInfo.activeProcessorCount)")
        writeLog("============================================\n")

        // Monitor every 3 seconds
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now() + 3, repeating: 3)
        timer?.setEventHandler { [weak self] in
            self?.checkPerformance()
        }
        timer?.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        writeLog("\n=== Monitor Stopped (uptime: \(uptimeString)) ===")
        writeLog("Peak Memory: \(String(format: "%.0f", peakMemoryMB))MB")
        writeLog("Peak CPU: \(String(format: "%.1f", peakCPU))%")
        writeLog("Total Warnings: \(warningCount)")
        logHandle?.closeFile()
        logHandle = nil
    }

    // MARK: - Log File

    private func setupLogFile() {
        let fm = FileManager.default
        let logsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PickShot")
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "pickshot_perf_\(dateFormatter.string(from: Date())).log"
        logFileURL = logsDir.appendingPathComponent(filename)

        fm.createFile(atPath: logFileURL!.path, contents: nil)
        logHandle = FileHandle(forWritingAtPath: logFileURL!.path)
    }

    var logFilePath: String {
        logFileURL?.path ?? "~/Library/Logs/PickShot/"
    }

    // MARK: - Performance Check

    private func checkPerformance() {
        let memMB = currentMemoryMB()
        let cpu = currentCPUPercent()

        if memMB > peakMemoryMB { peakMemoryMB = memMB }
        if cpu > peakCPU { peakCPU = cpu }

        // Memory warnings
        if memMB > memoryCriticalMB {
            logWarning("🔴 CRITICAL MEMORY: \(String(format: "%.0f", memMB))MB (limit: \(Int(memoryCriticalMB))MB)")
            warningCount += 1
        } else if memMB > memoryWarningMB {
            logWarning("🟡 HIGH MEMORY: \(String(format: "%.0f", memMB))MB")
            warningCount += 1
        }

        // CPU warnings
        if cpu > cpuCriticalPercent {
            logWarning("🔴 CRITICAL CPU: \(String(format: "%.1f", cpu))%")
            warningCount += 1
        } else if cpu > cpuWarningPercent {
            logWarning("🟡 HIGH CPU: \(String(format: "%.1f", cpu))%")
            warningCount += 1
        }

        // Periodic status (every 30 seconds)
        if Date().timeIntervalSince(lastLogTime) > 30 {
            writeLog("📊 Status: Mem=\(String(format: "%.0f", memMB))MB CPU=\(String(format: "%.1f", cpu))% Warnings=\(warningCount) Uptime=\(uptimeString)")
            lastLogTime = Date()
        }
    }

    // MARK: - Operation Timing

    /// Measure an operation and log if it takes too long
    func measure(_ label: String, threshold: TimeInterval = 3.0, block: () -> Void) {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        if elapsed > threshold {
            logWarning("⏱ SLOW OPERATION: \(label) took \(String(format: "%.2f", elapsed))s (threshold: \(threshold)s)")
            warningCount += 1
        }
    }

    /// Log a custom event
    func logEvent(_ message: String) {
        writeLog("📌 \(message)")
    }

    // MARK: - Memory Info

    private func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            return Double(info.resident_size) / 1_048_576
        }
        return 0
    }

    // MARK: - CPU Info

    private func currentCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return 0 }

        var totalCPU: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if result == KERN_SUCCESS && info.flags & TH_FLAGS_IDLE == 0 {
                totalCPU += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }

        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
        return totalCPU
    }

    // MARK: - Helpers

    private var uptimeString: String {
        let seconds = Int(Date().timeIntervalSince(startTime))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func timestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df.string(from: Date())
    }

    private func writeLog(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        if let data = line.data(using: .utf8) {
            logHandle?.write(data)
        }
        #if DEBUG
        print("PERF: \(message)")
        #endif
    }

    private func logWarning(_ message: String) {
        writeLog("⚠️ \(message)")
        // Also write to AppLogger file for remote diagnostics
        AppLogger.log(.performance, message)
        print("PERF WARNING: \(message)")
    }

    // MARK: - Report Generation

    /// Generate a summary report for sharing
    func generateReport() -> String {
        var report = """
        PickShot Performance Report
        ===========================
        Date: \(Date())
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        RAM: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)GB
        CPU Cores: \(ProcessInfo.processInfo.activeProcessorCount)
        Uptime: \(uptimeString)

        Peak Memory: \(String(format: "%.0f", peakMemoryMB))MB
        Current Memory: \(String(format: "%.0f", currentMemoryMB()))MB
        Peak CPU: \(String(format: "%.1f", peakCPU))%
        Current CPU: \(String(format: "%.1f", currentCPUPercent()))%
        Total Warnings: \(warningCount)

        Log File: \(logFilePath)
        """

        if let logURL = logFileURL, let logContent = try? String(contentsOf: logURL) {
            let warnings = logContent.components(separatedBy: "\n")
                .filter { $0.contains("⚠️") || $0.contains("🔴") || $0.contains("⏱") }
            if !warnings.isEmpty {
                report += "\n\nWarnings:\n"
                report += warnings.suffix(20).joined(separator: "\n")
            }
        }

        return report
    }

    /// Open log folder in Finder
    func openLogFolder() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PickShot")
        NSWorkspace.shared.open(logsDir)
    }
}
