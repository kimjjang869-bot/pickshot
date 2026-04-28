//
//  GeneralSettingsTab.swift
//  PhotoRawManager
//
//  Extracted from SettingsView.swift split.
//

import SwiftUI

struct GeneralSettingsTab: View {
    @AppStorage("autoOpenLastFolder") private var autoOpenLastFolder = true
    @AppStorage("showFileTypeBadge") private var showFileTypeBadge = true
    @AppStorage("showFileExtension") private var showFileExtension = true
    @AppStorage("showFolderPreview") private var showFolderPreview = true
    // v8.7: JPG+RAW 매칭을 파일번호 기반으로 (예: IMG_1234_LR.jpg ↔ IMG_1234.ARW)
    @AppStorage("matchByFileNumber") private var matchByFileNumber = false
    @AppStorage("deleteOriginalFile") private var deleteOriginalFile = false
    @AppStorage("skipDeleteConfirm") private var skipDeleteConfirm = true
    @AppStorage("windowStartSize") private var windowStartSize = "default"
    @AppStorage("appLanguage") private var appLanguage = "ko"
    @AppStorage("appearance") private var appearance = "system"
    /// v8.8.2: UI 전체 스케일 (툴바/폰트/아이콘). 0 = 자동, 0.85/1.0/1.15/1.3 수동 선택.
    @AppStorage("uiScale") private var uiScale: Double = 1.0
    @AppStorage("showNotifications") private var showNotifications = true
    @AppStorage("autoSaveOnExit") private var autoSaveOnExit = true
    @AppStorage("autoBackupEnabled") private var autoBackupEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("일반 설정")
                    .font(.title3.bold())
                Text("앱의 기본 동작과 외관을 설정합니다.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("시작 시 마지막 폴더 자동 열기", isOn: $autoOpenLastFolder)
                        Toggle("파일 확장자 배지 표시 (JPG, R+J, RAW 등)", isOn: $showFileTypeBadge)
                        Toggle("파일명에 확장자 표시 (IMG_9741.JPG)", isOn: $showFileExtension)

                        Divider()

                        Toggle("JPG+RAW 매칭을 파일번호 기반으로 (편집 접미사 무시)", isOn: $matchByFileNumber)
                        if matchByFileNumber {
                            Text("예: IMG_1234_LR.jpg ↔ IMG_1234.ARW 자동 매칭. 다음 폴더 로드부터 적용됩니다.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        Toggle("Backspace 키로 원본 파일 삭제 (휴지통)", isOn: $deleteOriginalFile)
                            .foregroundColor(deleteOriginalFile ? .red : .primary)
                        if deleteOriginalFile {
                            Text("⚠️ 주의: Backspace 키를 누르면 원본 파일이 휴지통으로 이동됩니다. 실수로 삭제할 수 있으니 주의하세요.")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }

                        Toggle("삭제 시 확인 대화상자 건너뛰기 (빠른 워크플로우)", isOn: $skipDeleteConfirm)
                        if skipDeleteConfirm {
                            Text("확인 없이 바로 휴지통으로 이동합니다. ⌘Z 로 되돌릴 수 있습니다.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        Picker("프로그램 시작 시 윈도우 크기", selection: $windowStartSize) {
                            Text("기본").tag("default")
                            Text("최대화").tag("maximized")
                            Text("마지막 크기").tag("lastSize")
                        }

                        Divider()

                        Picker("언어 설정", selection: $appLanguage) {
                            Text("한국어").tag("ko")
                            Text("English").tag("en")
                        }

                        Divider()

                        Picker("다크 모드", selection: $appearance) {
                            Text("시스템").tag("system")
                            Text("항상 다크").tag("dark")
                            Text("항상 라이트").tag("light")
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Picker("UI 크기", selection: $uiScale) {
                                Text("자동").tag(0.0)
                                Text("85% (작게)").tag(0.85)
                                Text("100% (기본)").tag(1.0)
                                Text("115%").tag(1.15)
                                Text("130% (크게)").tag(1.3)
                                Text("150% (최대)").tag(1.5)
                            }
                            Text("변경 후 앱을 재시작해야 적용됩니다.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        Toggle("알림 표시 (내보내기 완료, 분석 완료 등)", isOn: $showNotifications)

                        Divider()

                        Toggle("종료 시 별점/셀렉 자동 저장", isOn: $autoSaveOnExit)

                        Divider()

                        Toggle("메모리카드 자동 백업", isOn: $autoBackupEnabled)
                            .onChange(of: autoBackupEnabled) { _, enabled in
                                if enabled { MemoryCardBackupService.shared.startMonitoring() }
                                else { MemoryCardBackupService.shared.stopMonitoring() }
                            }
                        Text("메모리카드(SD/CF) 연결 시 자동으로 백업 폴더를 묻고 복사합니다")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Divider()

                        // v8.9.7+: 셀렉 백업 파일 (.pickshot_selection.json) 수동 불러오기
                        VStack(alignment: .leading, spacing: 6) {
                            Text("셀렉 백업 파일 불러오기")
                                .font(.system(size: 12, weight: .semibold))
                            Text("폴더 안의 .pickshot_selection.json 파일을 선택해 별점/SP/컬러라벨을 복원합니다")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Button(action: importSelectionBackup) {
                                Label("셀렉 백업 가져오기...", systemImage: "square.and.arrow.down")
                            }
                        }
                    }
                    .padding(4)
                }

            }
            .padding(20)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("SettingsResetTab"))) { _ in
            autoOpenLastFolder = true; showFileTypeBadge = true; showFileExtension = true
            deleteOriginalFile = false; windowStartSize = "default"; appLanguage = "ko"
            appearance = "system"; showNotifications = true; autoSaveOnExit = true
            autoBackupEnabled = false
        }
    }

    // v8.9.7+: 셀렉 백업 파일 수동 불러오기.
    private func importSelectionBackup() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.message = ".pickshot_selection.json 파일 선택"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            NotificationCenter.default.post(name: .init("ImportSelectionBackupFailed"), object: nil)
            return
        }

        let ratings = (json["ratings"] as? [String: Int]) ?? [:]
        let spPicks = (json["spPicks"] as? [String: Bool]) ?? [:]
        let colors = (json["colorLabels"] as? [String: String]) ?? [:]
        let folderInBackup = (json["folder"] as? String) ?? ""

        let alert = NSAlert()
        alert.messageText = "셀렉 백업 가져오기"
        alert.informativeText = "원본 폴더: \(folderInBackup)\n\n별점 \(ratings.count)개 / SP \(spPicks.count)개 / 컬러 \(colors.count)개\n\n현재 열린 폴더의 사진과 파일명이 일치하면 적용됩니다."
        alert.addButton(withTitle: "적용")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 현재 열린 폴더의 PhotoStore 에 적용
        NotificationCenter.default.post(
            name: .init("ApplyImportedSelection"),
            object: nil,
            userInfo: ["ratings": ratings, "spPicks": spPicks, "colorLabels": colors]
        )
    }
}

// MARK: - Tab 2: 미리보기 (Preview)
