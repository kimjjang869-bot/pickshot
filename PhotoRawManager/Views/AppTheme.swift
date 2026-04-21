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
    static let starGold = Color(red: 255/255, green: 184/255, blue: 0/255)     // #FFB800 (별 아이콘용)
    /// v8.7: ★5 썸네일 테두리 전용 — 노란 컬러 라벨과 명확히 구분되도록 오렌지 계열
    static let ratingFiveBorder = Color(red: 255/255, green: 110/255, blue: 0/255)  // #FF6E00 (vivid orange)

    // MARK: - Text Colors
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textDim = Color.secondary.opacity(0.5)
    static let textMuted = Color.white.opacity(0.7)

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
    static let toolbarDivider = Color.gray.opacity(0.15)
    static let toolbarButtonBg = Color.gray.opacity(0.08)
    static let toolbarButtonActiveBg = accent
    static let toolbarDividerHeight: CGFloat = 16

    // MARK: - Selection & Hover
    static let selectionBg = accent.opacity(0.15)
    static let hoverBg = Color.gray.opacity(0.08)

    // MARK: - Corner Radius System
    static let radiusSmall: CGFloat = 4     // 배지, 태그
    static let radiusMedium: CGFloat = 6    // 버튼, 입력 필드
    static let radiusLarge: CGFloat = 10    // 카드, 큰 영역

    // MARK: - Grid
    static let gridSpacing: CGFloat = 12

    // MARK: - Sidebar
    static let sidebarCollapsed: CGFloat = 36
    static let sidebarExpanded: CGFloat = 250

    // MARK: - UI 스케일 팩터
    //   v8.8.2: 사용자 설정 (UserDefaults "uiScale", 기본 1.0) 우선.
    //   자동 모드 (uiScale=0) 는 해상도 기반이지만 cap 을 1.0 으로 낮춤 — 5K 환경에서 너무 커지지 않도록.
    static let displayScale: CGFloat = {
        let userScale = UserDefaults.standard.double(forKey: "uiScale")
        if userScale > 0 {
            return max(0.7, min(1.5, CGFloat(userScale)))
        }
        // 자동 — 3200px 기준 비례, 범위 [0.85, 1.0]
        let screenW = NSScreen.main?.frame.width ?? 2560
        return max(0.85, min(1.0, screenW / 3200.0))
    }()

    /// 해상도별 자동 조정값
    static func scaled(_ base: CGFloat) -> CGFloat {
        return round(base * displayScale)
    }

    // MARK: - 모든 값 앱 시작 시 1회 계산 (모니터 변경/포커스 변경 시 안 바뀜)
    // v8.7: base 값 상향 — 5K 환경 가독성 개선
    static let buttonHeight: CGFloat = scaled(38)   // 34 → 38
    static let pillSize: CGFloat = scaled(32)       // 30 → 32

    static let iconSmall: CGFloat = scaled(15)      // 13 → 15
    static let iconMedium: CGFloat = scaled(17)     // 15 → 17
    static let iconLarge: CGFloat = scaled(20)      // 18 → 20

    static let fontMicro: CGFloat = scaled(12)      // 11 → 12
    static let fontCaption: CGFloat = scaled(13)    // 12 → 13
    static let fontBody: CGFloat = scaled(14)       // 13 → 14
    static let fontSubhead: CGFloat = scaled(15)    // 14 → 15
    static let fontHeading: CGFloat = scaled(16)    // 15 → 16

    // MARK: - Min Touch Target
    static let minTouchTarget: CGFloat = 24
}
