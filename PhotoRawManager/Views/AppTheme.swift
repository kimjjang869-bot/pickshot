import SwiftUI

// MARK: - App Design System (Lightroom/Capture One inspired dark theme)

enum AppTheme {

    // =========================================================================
    // MARK: - Spacing System (4pt grid)
    // =========================================================================
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24

    // =========================================================================
    // MARK: - Background Colors (dark theme palette)
    // =========================================================================
    /// Main window background — deepest layer (#1A1A1A)
    static let bgMain = Color(red: 0x1A/255, green: 0x1A/255, blue: 0x1A/255)
    /// Side panels, inspectors (#222222)
    static let bgPanel = Color(red: 0x22/255, green: 0x22/255, blue: 0x22/255)
    /// Cards, popovers, elevated surfaces (#2A2A2A)
    static let bgCard = Color(red: 0x2A/255, green: 0x2A/255, blue: 0x2A/255)
    /// Subtle hover / highlight row (#333333)
    static let bgHover = Color(red: 0x33/255, green: 0x33/255, blue: 0x33/255)
    /// Dividers & thin separators (#3A3A3A)
    static let bgDivider = Color(red: 0x3A/255, green: 0x3A/255, blue: 0x3A/255)

    // =========================================================================
    // MARK: - Primary Colors
    // =========================================================================
    /// Primary accent blue (#4A90D9) — buttons, links, selection
    static let accent = Color(red: 0x4A/255, green: 0x90/255, blue: 0xD9/255)
    /// Positive / success green (#4CAF50)
    static let success = Color(red: 0x4C/255, green: 0xAF/255, blue: 0x50/255)
    /// Caution orange (#FF9800)
    static let warning = Color(red: 0xFF/255, green: 0x98/255, blue: 0x00/255)
    /// Destructive / error red (#F44336)
    static let error = Color(red: 0xF4/255, green: 0x43/255, blue: 0x36/255)

    // =========================================================================
    // MARK: - Muted Accent Colors (for subtle backgrounds)
    // =========================================================================
    static let mutedBlue = accent.opacity(0.12)
    static let mutedGreen = success.opacity(0.12)
    static let mutedOrange = warning.opacity(0.12)
    static let mutedRed = error.opacity(0.12)
    static let mutedPurple = Color(red: 175/255, green: 82/255, blue: 222/255).opacity(0.12)

    // =========================================================================
    // MARK: - Badge Colors
    // =========================================================================
    static let rawBadge = success
    static let spBadge = error
    static let pickBadge = Color(red: 175/255, green: 82/255, blue: 222/255)    // purple
    static let correctedBadge = Color.teal
    static let sceneBadge = Color.cyan

    // =========================================================================
    // MARK: - Quality Grade Colors
    // =========================================================================
    static func gradeColor(_ grade: QualityAnalysis.Grade) -> Color {
        switch grade {
        case .excellent: return success
        case .good: return accent
        case .average: return Color.yellow
        case .belowAverage: return warning
        case .poor: return error
        }
    }

    // =========================================================================
    // MARK: - Star Color
    // =========================================================================
    static let starGold = Color(red: 255/255, green: 184/255, blue: 0/255)     // #FFB800

    // =========================================================================
    // MARK: - Text Colors
    // =========================================================================
    /// Primary text — bright white (#FFFFFF)
    static let textPrimary = Color.primary
    /// Secondary text — medium gray (#999999)
    static let textSecondary = Color(red: 0x99/255, green: 0x99/255, blue: 0x99/255)
    /// Dim / disabled text (#666666)
    static let textDim = Color(red: 0x66/255, green: 0x66/255, blue: 0x66/255)

    // =========================================================================
    // MARK: - Thumbnail Grid
    // =========================================================================
    static let selectionBorder = Color(red: 50/255, green: 140/255, blue: 255/255)  // vivid blue
    static let focusBorder = Color(red: 80/255, green: 180/255, blue: 255/255)      // bright cyan-blue
    static let spPickBorder = error
    static let cellCornerRadius: CGFloat = 6
    static let cellBorderWidth: CGFloat = 3
    static let focusBorderWidth: CGFloat = 3

    // =========================================================================
    // MARK: - Star Rating
    // =========================================================================
    static let starFilled = starGold
    static let starEmpty = Color.gray.opacity(0.25)

    // =========================================================================
    // MARK: - Toolbar
    // =========================================================================
    static let toolbarDivider = Color.gray.opacity(0.2)
    static let toolbarButtonBg = Color.gray.opacity(0.08)
    static let toolbarButtonActiveBg = accent

    // =========================================================================
    // MARK: - Layout Dimensions
    // =========================================================================
    /// Standard toolbar row height
    static let toolbarHeight: CGFloat = 40
    /// Filter / tag bar height
    static let filterBarHeight: CGFloat = 34
    /// Default button height (existing)
    static let buttonHeight: CGFloat = 26
    /// Pill-shaped toggle size
    static let pillSize: CGFloat = 28
    /// Standard corner radius for buttons / cards
    static let cornerRadius: CGFloat = 6

    // =========================================================================
    // MARK: - Icon Sizes
    // =========================================================================
    static let iconSmall: CGFloat = 12
    static let iconMedium: CGFloat = 14
    static let iconLarge: CGFloat = 16

    // =========================================================================
    // MARK: - Typography
    // =========================================================================
    /// 9 pt — micro labels (badge counts, timestamps)
    static let fontMicro: CGFloat = 9
    /// 10 pt — captions, secondary info
    static let fontCaption: CGFloat = 10
    /// 12 pt — default body text
    static let fontBody: CGFloat = 12
    /// 13 pt semibold — section headings
    static let fontSubhead: CGFloat = 13
    /// 14 pt — panel headings (kept for backward compat)
    static let fontHeading: CGFloat = 14
    /// 16 pt bold — view / window titles
    static let fontTitle: CGFloat = 16

    // =========================================================================
    // MARK: - Semantic Font Helpers
    // =========================================================================
    /// Title font — 16 pt bold
    static let titleFont: Font = .system(size: fontTitle, weight: .bold)
    /// Heading font — 13 pt semibold
    static let headingFont: Font = .system(size: fontSubhead, weight: .semibold)
    /// Body font — 12 pt regular
    static let bodyFont: Font = .system(size: fontBody)
    /// Caption font — 10 pt regular
    static let captionFont: Font = .system(size: fontCaption)
    /// Micro font — 9 pt regular
    static let microFont: Font = .system(size: fontMicro)
}

// MARK: - Button Styles

/// Primary action button — accent background, white text, rounded corners.
struct PrimaryButtonStyle: ButtonStyle {
    var isCompact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppTheme.fontBody, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, isCompact ? AppTheme.space8 : AppTheme.space16)
            .frame(height: AppTheme.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? AppTheme.accent.opacity(0.8) : AppTheme.accent)
            )
    }
}

/// Secondary / ghost button — translucent gray background, rounded corners.
struct SecondaryButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var isCompact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppTheme.fontBody, weight: .medium))
            .foregroundColor(isActive ? .white : AppTheme.textSecondary)
            .padding(.horizontal, isCompact ? AppTheme.space8 : AppTheme.space12)
            .frame(height: AppTheme.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(
                        isActive
                            ? AppTheme.accent
                            : (configuration.isPressed
                                ? Color.gray.opacity(0.22)
                                : Color.gray.opacity(0.15))
                    )
            )
    }
}

/// Destructive button — error-colored background, white text.
struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppTheme.fontBody, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, AppTheme.space16)
            .frame(height: AppTheme.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? AppTheme.error.opacity(0.8) : AppTheme.error)
            )
    }
}
