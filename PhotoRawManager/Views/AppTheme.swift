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

    // MARK: - Standard Button Height
    static let buttonHeight: CGFloat = 32
    static let pillSize: CGFloat = 28

    // MARK: - Icon Sizes
    static let iconSmall: CGFloat = 12
    static let iconMedium: CGFloat = 14
    static let iconLarge: CGFloat = 16

    // MARK: - Font Sizes
    static let fontMicro: CGFloat = 10
    static let fontCaption: CGFloat = 11
    static let fontBody: CGFloat = 12
    static let fontSubhead: CGFloat = 13
    static let fontHeading: CGFloat = 14
}
