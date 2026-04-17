//
//  ExportSettingsTab.swift
//  PhotoRawManager
//
//  Extracted from SettingsView.swift split.
//

import SwiftUI


struct ExportSettingsTab: View {
    @AppStorage("defaultExportPath") private var defaultExportPath = ""
    @AppStorage("autoLaunchLightroom") private var autoLaunchLightroom = false
    @AppStorage("createXMPSidecar") private var createXMPSidecar = true
    @AppStorage("openFinderAfterExport") private var openFinderAfterExport = true
    @AppStorage("exportFolderStructure") private var exportFolderStructure = "rawOnly"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("내보내기 설정")
                    .font(.title3.bold())
                Text("사진/영상 내보내기의 기본 동작을 설정합니다.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("기본 내보내기 폴더")
                            Spacer()
                            Text(defaultExportPath.isEmpty ? "선택 안 됨" : abbreviatePath(defaultExportPath))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("폴더 선택") {
                                selectExportFolder()
                            }
                        }

                        Divider()

                        Toggle("Lightroom 자동 실행", isOn: $autoLaunchLightroom)

                        Divider()

                        Toggle("XMP 사이드카 생성", isOn: $createXMPSidecar)

                        Divider()

                        Toggle("내보내기 후 Finder 열기", isOn: $openFinderAfterExport)

                        Divider()

                        Picker("내보내기 시 하위 폴더 구조", selection: $exportFolderStructure) {
                            Text("RAW만").tag("rawOnly")
                            Text("RAW+JPG 분리").tag("separated")
                            Text("통합").tag("combined")
                        }
                    }
                    .padding(4)
                }

            }
            .padding(20)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("SettingsResetTab"))) { _ in
            defaultExportPath = ""; autoLaunchLightroom = false
            createXMPSidecar = true; openFinderAfterExport = true; exportFolderStructure = "rawOnly"
        }
    }

    private func selectExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.message = "기본 내보내기 폴더를 선택하세요"
        if panel.runModal() == .OK, let url = panel.url {
            defaultExportPath = url.path
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Tab 4: AI 엔진 (AI Engine)
