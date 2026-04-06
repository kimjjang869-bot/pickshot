import SwiftUI

// MARK: - App Design System (macOS Ventura/Sonoma inspired)

enum AppTheme {
    // MARK: - Spacing System (4pt grid)
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24

    // MARK: - Primary Colors
    static let accent = Color(red: 10/255, green: 132/255, blue: 255/255)       // #0A84FF macOS system blue
    static let success = Color(red: 48/255, green: 209/255, blue: 88/255)       // #30D158 green
    static let warning = Color(red: 255/255, green: 159/255, blue: 10/255)      // #FF9F0A orange
    static let error = Color(red: 255/255, green: 69/255, blue: 58/255)         // #FF453A red

    // MARK: - Muted Accent Colors
    static let mutedBlue = Color(red: 10/255, green: 132/255, blue: 255/255).opacity(0.12)
    static let mutedGreen = Color(red: 48/255, green: 209/255, blue: 88/255).opacity(0.12)
    static let mutedOrange = Color(red: 255/255, green: 159/255, blue: 10/255).opacity(0.12)
    static let mutedRed = Color(red: 255/255, green: 69/255, blue: 58/255).opacity(0.12)
    static let mutedPurple = Color(red: 175/255, green: 82/255, blue: 222/255).opacity(0.12)

    // MARK: - Badge Colors
    static let rawBadge = success
    static let spBadge = error
    static let pickBadge = Color(red: 175/255, green: 82/255, blue: 222/255)    // purple
    static let correctedBadge = Color.teal
    static let sceneBadge = Color.cyan

    // MARK: - Quality Grade Colors
    static func gradeColor(_ grade: QualityAnalysis.Grade) -> Color {
        switch grade {
        case .excellent: return success
        case .good: return accent
        case .average: return Color.yellow
        case .belowAverage: return warning
        case .poor: return error
        }
    }

    // MARK: - Star Color
    static let starGold = Color(red: 255/255, green: 184/255, blue: 0/255)     // #FFB800

    // MARK: - Text Colors
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textDim = Color.secondary.opacity(0.5)

    // MARK: - Thumbnail Grid
    static let selectionBorder = Color(red: 50/255, green: 140/255, blue: 255/255)  // vivid blue
    static let focusBorder = Color(red: 80/255, green: 180/255, blue: 255/255)  // bright cyan-blue
    static let spPickBorder = error
    static let cellCornerRadius: CGFloat = 6
    static let cellBorderWidth: CGFloat = 3
    static let focusBorderWidth: CGFloat = 3

    // MARK: - Star Rating
    static let starFilled = starGold
    static let starEmpty = Color.gray.opacity(0.25)

    // MARK: - Toolbar
    static let toolbarDivider = Color.gray.opacity(0.2)
    static let toolbarButtonBg = Color.gray.opacity(0.08)
    static let toolbarButtonActiveBg = accent

    // MARK: - 해상도 기반 스케일 팩터
    // 기준: 현재 화면의 논리 해상도 기반 (3200px = 1.0x)
    // 1440 = 0.8x, 1920 = 0.85x, 2560 = 0.9x, 3200 = 1.0x, 3840 = 1.1x
    static var displayScale: CGFloat {
        let screenW = NSScreen.main?.frame.width ?? 3200
        return max(0.8, min(1.2, screenW / 3200.0))
    }

    /// 해상도별 자동 조정값
    static func scaled(_ base: CGFloat) -> CGFloat {
        return round(base * displayScale)
    }

    // MARK: - Standard Button Height
    static var buttonHeight: CGFloat { scaled(32) }
    static var pillSize: CGFloat { scaled(28) }

    // MARK: - Icon Sizes
    static var iconSmall: CGFloat { scaled(12) }
    static var iconMedium: CGFloat { scaled(14) }
    static var iconLarge: CGFloat { scaled(16) }

    // MARK: - Font Sizes
    static var fontMicro: CGFloat { scaled(10) }
    static var fontCaption: CGFloat { scaled(11) }
    static var fontBody: CGFloat { scaled(12) }
    static var fontSubhead: CGFloat { scaled(13) }
    static var fontHeading: CGFloat { scaled(14) }
}
