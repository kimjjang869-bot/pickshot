import Foundation

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

struct AppLogger {
    static var isEnabled: Bool {
        return true  // Always enabled for now (disable before App Store release)
    }

    static func log(_ category: LogCategory, _ message: String) {
        guard isEnabled else { return }
        let timestamp = String(format: "%.3f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000))
        print("\(category.rawValue) [\(timestamp)] \(message)")
    }

    static func time(_ category: LogCategory, _ label: String, _ block: () -> Void) {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        log(category, "\(label) took \(String(format: "%.1f", elapsed))ms")
    }
}
