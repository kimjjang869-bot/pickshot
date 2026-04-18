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
        case exposureDown, exposureUp
        case tempCooler, tempWarmer
        case autoExposure, autoWB, autoCurve
        case resetAdjustments
        case cropMode
        case copyAdjust, pasteAdjust

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
