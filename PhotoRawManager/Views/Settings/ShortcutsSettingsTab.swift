//
//  ShortcutsSettingsTab.swift
//  PhotoRawManager
//
//  v8.6 — 2개 세부 탭 추가:
//   1) "단축키 안내" — 전체 단축키 목록 (v8.5 보정 단축키 포함, read-only)
//   2) "커스텀" — 주요 action 재매핑 UI (KeyBindingStore 기반)
//

import SwiftUI
import AppKit

struct ShortcutsSettingsTab: View {
    @State private var selectedSubTab: SubTab = .list

    enum SubTab: String, CaseIterable {
        case list = "단축키 안내"
        case custom = "커스텀"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 서브탭 선택 Pill
            HStack(spacing: 8) {
                ForEach(SubTab.allCases, id: \.rawValue) { tab in
                    Button(action: { selectedSubTab = tab }) {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .foregroundColor(selectedSubTab == tab ? .white : .secondary)
                            .background(
                                Capsule().fill(
                                    selectedSubTab == tab
                                    ? Color.accentColor
                                    : Color.secondary.opacity(0.15)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            Group {
                switch selectedSubTab {
                case .list: ShortcutsListView()
                case .custom: ShortcutsCustomView()
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Tab 1: 전체 목록 (v8.5 보정 단축키 포함)

private struct ShortcutsListView: View {
    private let sections: [(String, [(String, String)])] = [
        ("탐색", [
            ("← →", "이전 / 다음 사진"),
            ("↑ ↓", "위 / 아래 행 이동"),
            ("Shift + 방향키", "범위 선택 확장"),
        ]),
        ("선택", [
            ("클릭", "단일 선택"),
            ("Cmd + 클릭", "개별 추가/해제"),
            ("Shift + 클릭", "범위 선택"),
            ("Cmd + A", "전체 선택"),
            ("Cmd + D", "전체 해제"),
        ]),
        ("별점 / 라벨", [
            ("1 ~ 5", "별점 매기기"),
            ("0", "별점 초기화"),
            ("6", "색상 라벨 해제"),
            ("7 / 8 / 9", "빨강 / 주황 / 노랑 라벨"),
        ]),
        ("셀렉 / 미리보기", [
            ("Space", "스페이스 셀렉 (SP) 토글"),
            ("P", "Quick Look 미리보기"),
            ("I", "메타데이터 오버레이 토글"),
            ("H", "히스토그램 오버레이 토글"),
        ]),
        ("보기", [
            ("Cmd + 0", "화면 맞춤"),
            ("Cmd + =", "확대"),
            ("Cmd + -", "축소"),
        ]),
        ("비파괴 보정 (v8.5+)", [
            ("[ / ]", "노출 ±0.1 EV"),
            ("Shift + [ / ]", "노출 ±0.5 EV"),
            ("; / '", "색온도 ±5"),
            ("Shift + ; / '", "색온도 ±25"),
            ("Option + E", "자동 노출 적용"),
            ("Option + W", "자동 화이트밸런스 적용"),
            ("Option + K", "자동 커브 적용"),
            ("R", "현재 사진 보정 리셋"),
            ("C", "인라인 크롭 모드"),
            ("Cmd + Shift + C", "보정값 복사"),
            ("Cmd + Shift + V", "선택된 사진에 붙여넣기"),
            ("ESC", "보정 패널 닫기"),
        ]),
        ("파일", [
            ("Cmd + O", "폴더 열기"),
            ("Cmd + E", "내보내기"),
            ("Cmd + ,", "설정"),
            ("Cmd + /", "단축키 안내"),
        ]),
        ("영상 (비디오 파일 선택 시)", [
            ("J / K / L", "역재생 / 정지 / 재생"),
            ("I / O", "IN / OUT 마커"),
            ("Shift + I / O", "IN/OUT 지점으로 점프"),
            ("Option + I / O", "IN/OUT 마커 개별 해제"),
            ("X", "모든 마커 해제"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("사용 가능한 모든 단축키")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                ForEach(sections, id: \.0) { section in
                    GroupBox(section.0) {
                        VStack(spacing: 0) {
                            ForEach(Array(section.1.enumerated()), id: \.offset) { index, shortcut in
                                HStack {
                                    Text(shortcut.0)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .frame(width: 180, alignment: .leading)
                                    Text(shortcut.1)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                if index < section.1.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Tab 2: 커스텀

private struct ShortcutsCustomView: View {
    @ObservedObject var store: KeyBindingStore = .shared
    @State private var recordingAction: KeyBindingStore.Action? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("단축키 커스텀")
                            .font(.system(size: 13, weight: .bold))
                        Text("아래 핵심 단축키를 원하는 키로 재매핑할 수 있습니다. 나머지는 기본값 고정.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("모두 기본값으로") {
                        store.resetAll()
                    }
                    .disabled(store.overrides.isEmpty)
                }
                .padding(.top, 4)

                GroupBox("재매핑 가능한 단축키") {
                    VStack(spacing: 0) {
                        ForEach(KeyBindingStore.Action.allCases) { action in
                            customRow(action: action)
                            if action != KeyBindingStore.Action.allCases.last {
                                Divider()
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("안내") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• 변경 버튼을 누르고 원하는 단축키 조합을 한 번 누르세요.")
                            .font(.system(size: 11))
                        Text("• 이미 다른 액션에 쓰이는 조합은 충돌합니다 — 권장: 수정자 키(⌥/⇧) 조합.")
                            .font(.system(size: 11))
                        Text("• 기본값으로 복원하려면 '기본값' 버튼을 눌러주세요.")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                    .padding(8)
                }
            }
            .padding(20)
        }
    }

    private func customRow(action: KeyBindingStore.Action) -> some View {
        let binding = store.binding(for: action)
        let isOverride = store.overrides[action] != nil
        let isRecording = recordingAction == action

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName)
                    .font(.system(size: 12, weight: .medium))
                if isOverride {
                    Text("커스텀")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.orange)
                } else {
                    Text("기본값")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 현재 키 표시
            Text(isRecording ? "키를 누르세요..." : binding.displayLabel)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(isRecording ? .white : (isOverride ? .orange : .primary))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isRecording ? Color.accentColor : Color.secondary.opacity(0.12))
                )
                .frame(width: 140)

            if isRecording {
                Button("취소") {
                    recordingAction = nil
                }
                .controlSize(.small)
            } else {
                Button("변경") {
                    recordingAction = action
                    startRecording(for: action)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }

            Button("기본값") {
                store.setBinding(nil, for: action)
            }
            .controlSize(.small)
            .disabled(!isOverride)
        }
        .padding(.vertical, 6)
    }

    /// 키 녹화 — NSEvent.addLocalMonitor 로 한 번만 받고 해제.
    private func startRecording(for action: KeyBindingStore.Action) {
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ESC 로 취소
            if event.keyCode == 53 {
                recordingAction = nil
                if let m = monitor { NSEvent.removeMonitor(m) }
                return nil
            }

            var mods: KeyBindingStore.Binding.ModifierFlags = []
            if event.modifierFlags.contains(.command) { mods.insert(.command) }
            if event.modifierFlags.contains(.shift)   { mods.insert(.shift) }
            if event.modifierFlags.contains(.option)  { mods.insert(.option) }
            if event.modifierFlags.contains(.control) { mods.insert(.control) }

            let chars = event.charactersIgnoringModifiers ?? ""
            let keyChar = chars.isEmpty ? "" : String(chars.prefix(1))
            let binding = KeyBindingStore.Binding(
                key: keyChar,
                keyCode: Int(event.keyCode),
                modifiers: mods
            )
            store.setBinding(binding, for: action)
            recordingAction = nil
            if let m = monitor { NSEvent.removeMonitor(m) }
            return nil
        }
    }
}
