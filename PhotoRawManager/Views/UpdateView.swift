import SwiftUI

struct UpdateView: View {
    @ObservedObject var updateService: UpdateService

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)

                Text("새로운 버전이 있습니다!")
                    .font(.headline)
            }

            // Version info
            HStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text("현재 버전")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("v\(updateService.currentVersion)")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                }

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)

                VStack(spacing: 2) {
                    Text("최신 버전")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("v\(updateService.latestVersion)")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 8)

            // Release notes
            if !updateService.releaseNotes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("변경 사항")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    ScrollView {
                        Text(updateService.releaseNotes)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 150)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .cornerRadius(6)
                }
            }

            // Buttons
            VStack(spacing: 8) {
                Button(action: {
                    updateService.openDownloadPage()
                }) {
                    Text("다운로드")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 12) {
                    Button("나중에") {
                        updateService.dismissUpdate()
                    }
                    .buttonStyle(.bordered)

                    Button("이 버전 건너뛰기") {
                        updateService.skipVersion()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.caption)
                }
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
