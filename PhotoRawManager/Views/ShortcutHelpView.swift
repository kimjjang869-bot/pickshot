import SwiftUI

struct ShortcutHelpView: View {
    @Environment(\.dismiss) var dismiss

    private let leftColumn: [(String, [(String, String)])] = [
        ("탐색", [
            ("\u{2190} \u{2192} \u{2191} \u{2193}", "사진 이동"),
            ("Shift + 방향키", "범위 선택"),
            ("Cmd + 방향키", "개별 선택"),
        ]),
        ("선별", [
            ("1 ~ 5", "별점 매기기"),
            ("0", "별점 제거"),
            ("Space", "스페이스 셀렉"),
            ("G", "G셀렉 (Drive)"),
        ]),
    ]

    private let rightColumn: [(String, [(String, String)])] = [
        ("보기", [
            ("H", "히스토그램"),
            ("Cmd + / Cmd -", "확대 / 축소"),
            ("Cmd + 0", "화면 맞춤"),
            ("C", "비교 모드"),
        ]),
        ("파일", [
            ("Cmd + O", "폴더 열기"),
            ("Cmd + E", "내보내기"),
            ("Cmd + Z", "실행 취소"),
            ("?", "단축키 도움말"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "keyboard")
                    .font(.system(size: 14))
                    .foregroundColor(AppTheme.accent)
                Text("단축키 안내")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("아무 키나 누르면 닫힘")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider().background(Color.white.opacity(0.2))

            // Two-column layout
            HStack(alignment: .top, spacing: 32) {
                // Left column
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(leftColumn, id: \.0) { section in
                        shortcutSection(section.0, shortcuts: section.1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().background(Color.white.opacity(0.15))

                // Right column
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(rightColumn, id: \.0) { section in
                        shortcutSection(section.0, shortcuts: section.1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.85))
        )
        .frame(width: 520, height: 380)
    }

    private func shortcutSection(_ title: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppTheme.accent)
                .textCase(.uppercase)

            ForEach(shortcuts, id: \.0) { key, desc in
                HStack(spacing: 8) {
                    Text(key)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 130, alignment: .leading)
                        .foregroundColor(.white.opacity(0.9))
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }
}
