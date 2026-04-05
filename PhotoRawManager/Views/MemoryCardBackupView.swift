import SwiftUI

/// 메모리카드 백업 폴더 선택 다이얼로그
struct MemoryCardBackupPromptView: View {
    @ObservedObject var backup = MemoryCardBackupService.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            // 헤더
            Image(systemName: "sdcard.fill")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)

            Text("메모리카드 감지됨")
                .font(.system(size: 18, weight: .bold))

            Text("'\(backup.detectedVolumeName)' 카드의 사진을 백업합니다")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            // 파일 수 미리보기
            if let volume = backup.detectedVolumeURL {
                let count = backup.scanPhotos(from: volume).count
                HStack(spacing: 6) {
                    Image(systemName: "photo.stack")
                        .foregroundColor(.accentColor)
                    Text("\(count)장의 사진이 발견되었습니다")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(6)
            }

            Divider()

            // 백업 폴더 선택
            Text("백업할 폴더를 선택하세요")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("취소") {
                    dismiss()
                }

                Button("폴더 선택...") {
                    selectBackupFolder()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func selectBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "사진을 백업할 폴더를 선택하세요 (새 폴더 생성 가능)"
        panel.prompt = "백업 시작"

        if panel.runModal() == .OK, let url = panel.url, let volume = backup.detectedVolumeURL {
            dismiss()
            backup.startBackup(from: volume, to: url)
        }
    }
}

/// 백업 완료 + 다음 메모리카드 다이얼로그
struct MemoryCardBackupResultView: View {
    @ObservedObject var backup = MemoryCardBackupService.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            if let result = backup.backupResult {
                // 완료 아이콘
                Image(systemName: result.failed.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(result.failed.isEmpty ? .green : .orange)

                Text("백업 완료")
                    .font(.system(size: 18, weight: .bold))

                Text("'\(result.volumeName)' 카드")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                // 결과 수치
                HStack(spacing: 20) {
                    VStack(spacing: 2) {
                        Text("\(result.total)").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("전체").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    VStack(spacing: 2) {
                        Text("\(result.success)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(.green)
                        Text("성공").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    if !result.failed.isEmpty {
                        VStack(spacing: 2) {
                            Text("\(result.failed.count)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(.red)
                            Text("실패").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }

                // 실패 목록
                if !result.failed.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("실패한 파일:").font(.system(size: 12, weight: .semibold)).foregroundColor(.red)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(result.failed) { f in
                                    HStack(spacing: 4) {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 9)).foregroundColor(.red)
                                        Text(f.name).font(.system(size: 11, design: .monospaced))
                                        Text("- \(f.reason)").font(.system(size: 10)).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 100)
                    }
                }

                Divider()

                // 다음 메모리카드
                Text("다음 메모리카드를 백업하시겠습니까?")
                    .font(.system(size: 13))

                HStack(spacing: 12) {
                    Button("종료") {
                        backup.finishBackup()
                        dismiss()
                    }

                    Button("다음 카드 대기") {
                        backup.waitForNextCard()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
