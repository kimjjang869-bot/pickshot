//
//  ShortcutsSettingsTab.swift
//  PhotoRawManager
//
//  Extracted from SettingsView.swift split.
//

import SwiftUI


struct ShortcutsSettingsTab: View {
    private let shortcutSections: [(String, [(String, String)])] = [
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
        ("파일", [
            ("Cmd + O", "폴더 열기"),
            ("Cmd + E", "내보내기"),
            ("Cmd + ,", "설정"),
            ("Cmd + /", "단축키 안내"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("단축키 안내")
                    .font(.title3.bold())
                Text("현재 사용 가능한 단축키 목록입니다. (읽기 전용)")
                    .font(.callout)
                    .foregroundColor(.secondary)

                ForEach(shortcutSections, id: \.0) { section in
                    GroupBox(section.0) {
                        VStack(spacing: 0) {
                            ForEach(Array(section.1.enumerated()), id: \.offset) { index, shortcut in
                                HStack {
                                    Text(shortcut.0)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .frame(width: 160, alignment: .leading)
                                    Text(shortcut.1)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 3)

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

// MARK: - Cache Settings Tab (캐시)
