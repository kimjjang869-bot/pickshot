import Foundation
import SwiftUI

/// 사용자 커스텀 단축키 저장소.
///
/// 저장 위치: UserDefaults `keybinding:<actionID>` = "<modifiers>|<keyCode>|<char>"
/// - modifiers: "cmd,shift,opt" 등 콤마 구분
/// - keyCode: 정수 (없으면 -1)
/// - char: 단일 문자 (없으면 빈 문자열)
///
/// KeyEventHandling 에서 매 입력마다 `KeyBindingStore.shared.matches(action:event:)` 로 확인.
final class KeyBindingStore: ObservableObject {
    static let shared = KeyBindingStore()

    /// 커스텀 재매핑 가능한 단축키 action 목록.
    /// 기본값은 KeyEventHandling 의 하드코딩 조건과 일치.
    enum Action: String, CaseIterable, Identifiable {
        // ── 보정 (기존) ──
        case exposureDown, exposureUp
        case tempCooler, tempWarmer
        case autoExposure, autoWB, autoCurve
        case resetAdjustments
        case cropMode
        case copyAdjust, pasteAdjust
        // ── v9.1 격차 #5: FRV 식 핵심 단축키 커스터마이징 ──
        case nextPhoto, prevPhoto                  // 다음/이전 사진
        case nextPhotoRow, prevPhotoRow            // 다음/이전 줄 (그리드)
        case toggleFullscreen                      // 전체화면
        case toggleHistogram                       // 히스토그램
        case toggleClippingOverlay                 // 클리핑 오버레이
        case toggleFocusPeaking                    // 포커스 피킹
        case zoomFit, zoom100                      // 맞춤/100%
        case rotateCW, rotateCCW                   // 시계/반시계 90°
        case toggleMetadataPanel                   // 메타데이터 패널
        case markGreen, markYellow, markRed, markBlue, markPurple   // 컬러 라벨

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .exposureDown: return "노출 내리기"
            case .exposureUp: return "노출 올리기"
            case .tempCooler: return "색온도 차갑게"
            case .tempWarmer: return "색온도 따뜻하게"
            case .autoExposure: return "자동 노출 적용"
            case .autoWB: return "자동 화이트밸런스 적용"
            case .autoCurve: return "자동 커브 적용"
            case .resetAdjustments: return "현재 사진 보정 리셋"
            case .cropMode: return "인라인 크롭 모드"
            case .copyAdjust: return "보정값 복사"
            case .pasteAdjust: return "보정값 붙여넣기"
            case .nextPhoto: return "다음 사진"
            case .prevPhoto: return "이전 사진"
            case .nextPhotoRow: return "다음 줄 (그리드)"
            case .prevPhotoRow: return "이전 줄 (그리드)"
            case .toggleFullscreen: return "전체화면 토글"
            case .toggleHistogram: return "히스토그램 토글"
            case .toggleClippingOverlay: return "클리핑 오버레이 토글"
            case .toggleFocusPeaking: return "포커스 피킹 토글"
            case .zoomFit: return "맞춤"
            case .zoom100: return "100% 줌"
            case .rotateCW: return "시계방향 90° 회전"
            case .rotateCCW: return "반시계방향 90° 회전"
            case .toggleMetadataPanel: return "메타데이터 패널 토글"
            case .markGreen: return "초록 라벨"
            case .markYellow: return "노랑 라벨"
            case .markRed: return "빨강 라벨"
            case .markBlue: return "파랑 라벨"
            case .markPurple: return "보라 라벨"
            }
        }

        var defaultBinding: Binding {
            switch self {
            case .exposureDown: return Binding(key: "[", keyCode: 33, modifiers: [])
            case .exposureUp:   return Binding(key: "]", keyCode: 30, modifiers: [])
            case .tempCooler:   return Binding(key: ";", keyCode: 41, modifiers: [])
            case .tempWarmer:   return Binding(key: "'", keyCode: 39, modifiers: [])
            case .autoExposure: return Binding(key: "e", keyCode: 14, modifiers: [.option])
            case .autoWB:       return Binding(key: "w", keyCode: 13, modifiers: [.option])
            case .autoCurve:    return Binding(key: "k", keyCode: 40, modifiers: [.option])
            case .resetAdjustments: return Binding(key: "r", keyCode: 15, modifiers: [])
            case .cropMode:     return Binding(key: "c", keyCode: 8, modifiers: [])
            case .copyAdjust:   return Binding(key: "c", keyCode: 8, modifiers: [.command, .shift])
            case .pasteAdjust:  return Binding(key: "v", keyCode: 9, modifiers: [.command, .shift])
            case .nextPhoto:        return Binding(key: "→", keyCode: 124, modifiers: [])
            case .prevPhoto:        return Binding(key: "←", keyCode: 123, modifiers: [])
            case .nextPhotoRow:     return Binding(key: "↓", keyCode: 125, modifiers: [])
            case .prevPhotoRow:     return Binding(key: "↑", keyCode: 126, modifiers: [])
            case .toggleFullscreen: return Binding(key: "f", keyCode: 3,  modifiers: [.command])
            case .toggleHistogram:  return Binding(key: "h", keyCode: 4,  modifiers: [])
            case .toggleClippingOverlay: return Binding(key: "h", keyCode: 4, modifiers: [.shift])
            case .toggleFocusPeaking:    return Binding(key: "p", keyCode: 35, modifiers: [.shift])
            case .zoomFit:          return Binding(key: "0", keyCode: 29, modifiers: [.command])
            case .zoom100:          return Binding(key: "1", keyCode: 18, modifiers: [.command])
            case .rotateCW:         return Binding(key: "]", keyCode: 30, modifiers: [.command])
            case .rotateCCW:        return Binding(key: "[", keyCode: 33, modifiers: [.command])
            case .toggleMetadataPanel: return Binding(key: "i", keyCode: 34, modifiers: [])
            case .markGreen:        return Binding(key: "8", keyCode: 28, modifiers: [])
            case .markYellow:       return Binding(key: "7", keyCode: 26, modifiers: [])
            case .markRed:          return Binding(key: "6", keyCode: 22, modifiers: [])
            case .markBlue:         return Binding(key: "9", keyCode: 25, modifiers: [])
            case .markPurple:       return Binding(key: "0", keyCode: 29, modifiers: [])
            }
        }
    }

    /// 단일 단축키 조합.
    struct Binding: Codable, Hashable {
        /// 표기용 문자 (예: "[", "e")
        var key: String
        /// NSEvent.keyCode — 한글 IME 호환
        var keyCode: Int
        /// 수정자 플래그
        var modifiers: ModifierFlags

        struct ModifierFlags: OptionSet, Codable, Hashable {
            let rawValue: Int
            static let command = ModifierFlags(rawValue: 1 << 0)
            static let shift   = ModifierFlags(rawValue: 1 << 1)
            static let option  = ModifierFlags(rawValue: 1 << 2)
            static let control = ModifierFlags(rawValue: 1 << 3)
        }

        /// 사람이 읽을 수 있는 표시 (예: "⌘⇧C", "R", "⌥W")
        var displayLabel: String {
            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("⌃") }
            if modifiers.contains(.option)  { parts.append("⌥") }
            if modifiers.contains(.shift)   { parts.append("⇧") }
            if modifiers.contains(.command) { parts.append("⌘") }
            parts.append(key.uppercased())
            return parts.joined()
        }
    }

    // MARK: - Storage

    private let prefix = "keybinding:"

    @Published private(set) var overrides: [Action: Binding] = [:]

    private init() {
        load()
    }

    /// 특정 action 의 현재 유효한 binding (override 있으면 그것, 없으면 기본값).
    func binding(for action: Action) -> Binding {
        overrides[action] ?? action.defaultBinding
    }

    /// Action 에 커스텀 binding 설정. nil 로 넘기면 기본값 복원.
    func setBinding(_ binding: Binding?, for action: Action) {
        if let b = binding {
            overrides[action] = b
            if let data = try? JSONEncoder().encode(b) {
                UserDefaults.standard.set(data, forKey: prefix + action.rawValue)
            }
        } else {
            overrides.removeValue(forKey: action)
            UserDefaults.standard.removeObject(forKey: prefix + action.rawValue)
        }
        objectWillChange.send()
    }

    /// 모든 커스텀 값 초기화.
    func resetAll() {
        for action in Action.allCases {
            UserDefaults.standard.removeObject(forKey: prefix + action.rawValue)
        }
        overrides.removeAll()
        objectWillChange.send()
    }

    private func load() {
        for action in Action.allCases {
            if let data = UserDefaults.standard.data(forKey: prefix + action.rawValue),
               let binding = try? JSONDecoder().decode(Binding.self, from: data) {
                overrides[action] = binding
            }
        }
    }

    // MARK: - Match against NSEvent

    /// 현재 입력된 (keyCode, chars, modifierFlags) 이 지정된 action 에 매칭되는지 검사.
    /// KeyEventHandling 에서 사용.
    func matches(
        action: Action,
        keyCode: UInt16,
        chars: String,
        hasCmd: Bool,
        hasShift: Bool,
        hasOption: Bool,
        hasControl: Bool
    ) -> Bool {
        let b = binding(for: action)
        // modifier 정확히 일치해야 함 (추가 modifier 가 눌리면 매칭 실패)
        let expCmd = b.modifiers.contains(.command)
        let expShift = b.modifiers.contains(.shift)
        let expOption = b.modifiers.contains(.option)
        let expControl = b.modifiers.contains(.control)
        guard expCmd == hasCmd, expShift == hasShift, expOption == hasOption, expControl == hasControl else {
            return false
        }
        // 키 일치: 문자 or keyCode
        if !b.key.isEmpty && chars.lowercased() == b.key.lowercased() { return true }
        if b.keyCode >= 0 && Int(keyCode) == b.keyCode { return true }
        return false
    }
}
