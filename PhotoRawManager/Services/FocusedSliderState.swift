import Foundation
import SwiftUI

/// 현재 키보드 `[` / `]` 입력이 영향을 미치는 "포커스된 슬라이더".
/// 사용자가 레이블 클릭 → 포커스 변경 → [ / ] 키로 해당 값 조절.
final class FocusedSliderState: ObservableObject {
    static let shared = FocusedSliderState()

    enum Focus: Hashable {
        case exposure
        case contrast
        case temperature
        case tint
        case toneHighlights
        case toneLights
        case toneDarks
        case toneShadows
        case levelsBlack
        case levelsWhite
        case levelsGamma

        var displayName: String {
            switch self {
            case .exposure: return "노출"
            case .contrast: return "대비"
            case .temperature: return "온도"
            case .tint: return "틴트"
            case .toneHighlights: return "밝은 영역"
            case .toneLights: return "밝음"
            case .toneDarks: return "어두움"
            case .toneShadows: return "어두운 영역"
            case .levelsBlack: return "검정점"
            case .levelsWhite: return "흰점"
            case .levelsGamma: return "감마"
            }
        }

        /// [ / ] 1회 눌렀을 때 증감 (fine)
        var fineStep: Double {
            switch self {
            case .exposure: return 0.1
            case .contrast: return 1
            case .temperature: return 5
            case .tint: return 1
            case .toneHighlights, .toneLights, .toneDarks, .toneShadows: return 1
            case .levelsBlack, .levelsWhite: return 0.01
            case .levelsGamma: return 0.02
            }
        }

        /// Shift + [ / ] 눌렀을 때 증감 (big)
        var bigStep: Double {
            switch self {
            case .exposure: return 0.5
            case .contrast: return 10
            case .temperature: return 25
            case .tint: return 10
            case .toneHighlights, .toneLights, .toneDarks, .toneShadows: return 10
            case .levelsBlack, .levelsWhite: return 0.05
            case .levelsGamma: return 0.1
            }
        }

        /// 값의 허용 범위 (min, max)
        var range: ClosedRange<Double> {
            switch self {
            case .exposure: return -3.0...3.0
            case .contrast: return -100...100
            case .temperature, .tint: return -100...100
            case .toneHighlights, .toneLights, .toneDarks, .toneShadows: return -100...100
            case .levelsBlack: return 0...0.5
            case .levelsWhite: return 0.5...1.0
            case .levelsGamma: return 0.5...2.0
            }
        }
    }

    @Published var focused: Focus = .exposure

    /// 현재 focused 값 읽기 + 쓰기 (DevelopSettings 필드에 바인딩)
    func currentValue(in settings: DevelopSettings) -> Double {
        switch focused {
        case .exposure: return settings.exposure
        case .contrast: return settings.contrast
        case .temperature: return settings.temperature
        case .tint: return settings.tint
        case .toneHighlights: return settings.toneHighlights
        case .toneLights: return settings.toneLights
        case .toneDarks: return settings.toneDarks
        case .toneShadows: return settings.toneShadows
        case .levelsBlack: return settings.levelsBlack
        case .levelsWhite: return settings.levelsWhite
        case .levelsGamma: return settings.levelsGamma
        }
    }

    func setValue(_ v: Double, in settings: inout DevelopSettings) {
        let clamped = max(focused.range.lowerBound, min(focused.range.upperBound, v))
        switch focused {
        case .exposure: settings.exposure = clamped
        case .contrast: settings.contrast = clamped
        case .temperature: settings.temperature = clamped
        case .tint: settings.tint = clamped
        case .toneHighlights: settings.toneHighlights = clamped
        case .toneLights: settings.toneLights = clamped
        case .toneDarks: settings.toneDarks = clamped
        case .toneShadows: settings.toneShadows = clamped
        case .levelsBlack: settings.levelsBlack = clamped
        case .levelsWhite: settings.levelsWhite = clamped
        case .levelsGamma: settings.levelsGamma = clamped
        }
    }
}
