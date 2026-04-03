import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) var dismiss

    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0"
    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "3"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PickShot 정보")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // App icon and version
                    HStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 36))
                            .foregroundColor(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PickShot")
                                .font(.system(size: 18, weight: .bold))
                            Text("v\(appVersion) (Build \(buildNumber))")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // v3.0 Changelog
                    changelogSection("v3.0 새로운 기능", items: [
                        "필름스트립 레이아웃 모드",
                        "Vision 장면 분류 (인물/풍경/음식/건물 등)",
                        "얼굴 그룹핑",
                        "GPS 지도 뷰",
                        "배치 이름 변경",
                        "슬라이드쇼 전환 효과",
                        "히스토그램 오버레이 (H키)",
                        "메타데이터 오버레이 (I키)",
                        "Quick Look 미리보기 (P키)",
                        "Google Drive 업로드/공유",
                        "Touch Bar 지원",
                        "실시간 폴더 감시",
                        "CIRAWFilter 초고속 RAW 로딩",
                        "macOS 네이티브 API 최적화",
                    ])

                    Divider()

                    Text("Copyright 2026. All rights reserved.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(16)
            }
        }
        .frame(width: 420, height: 520)
    }

    private func changelogSection(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(AppTheme.accent)

            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("\u{2022}")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(item)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                }
            }
        }
    }
}
