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

                    // v5.0 Changelog
                    changelogSection("v5.0 새로운 기능", items: [
                        "스마트 셀렉 — 연사 베스트샷 자동 선택 (Cmd+Shift+S)",
                        "전체화면 컬링 모드 (Cmd+F) + 필름스트립",
                        "타임라인 뷰 — 촬영 시간대별 그룹화",
                        "셀렉 통계 대시보드",
                        "Before/After 보정 비교 슬라이더",
                        "메모리카드 자동 백업 (DCIM 감지 → 안전 복사)",
                        "캐시 관리 설정 (크기 제한/경로 변경/삭제)",
                        "빠른 탐색 최적화 (onQuickPreview 썸네일 즉시 표시)",
                        "마지막 폴더 자동 복원 + 폴더 트리 자동 스크롤",
                        "RAW 프리페치 스킵 (CPU/메모리 최적화)",
                    ])

                    changelogSection("v3.6 주요 개선", items: [
                        "Apple Vision 프레임워크 (수평보정/장면분류/인물분석)",
                        "품질 시스템 3단계 (좋음/보통/문제) + 100점 단일 점수",
                        "AI Pick: 75점 이상 자동 추천",
                        "RAW → JPG 배치 변환 + 리사이즈",
                        "내보내기 폴더명 커스텀",
                    ])

                    changelogSection("v3.0 기반 기능", items: [
                        "필름스트립 레이아웃 모드",
                        "Vision 장면 분류 (인물/풍경/음식/건물 등)",
                        "얼굴 그룹핑 + GPS 지도 뷰",
                        "히스토그램/메타데이터 오버레이 (H/I키)",
                        "Google Drive 업로드 + G Select 웹 뷰어",
                        "HW JPEG 디코더 + Metal GPU 가속",
                        "실시간 폴더 감시 + USB 테더링",
                    ])

                    Divider()

                    // Send Log button
                    VStack(alignment: .leading, spacing: 8) {
                        Text("진단")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(AppTheme.accent)

                        HStack(spacing: 8) {
                            Button(action: sendLog) {
                                HStack(spacing: 4) {
                                    Image(systemName: isSendingLog ? "arrow.up.circle" : "paperplane.fill")
                                        .font(.system(size: 11))
                                    Text(isSendingLog ? "전송 중..." : "Google Drive 전송")
                                        .font(.system(size: 11, weight: .medium))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isSendingLog)

                            Button(action: sendLogByEmail) {
                                HStack(spacing: 4) {
                                    Image(systemName: "envelope.fill")
                                        .font(.system(size: 11))
                                    Text("이메일 전송")
                                        .font(.system(size: 11, weight: .medium))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(action: saveLogToDesktop) {
                                HStack(spacing: 4) {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 11))
                                    Text("파일 저장")
                                        .font(.system(size: 11, weight: .medium))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if let msg = logSendResult {
                            Text(msg)
                                .font(.system(size: 10))
                                .foregroundColor(logSendSuccess ? .green : .red)
                        }

                        Text("성능 데이터(폴더 로딩 시간, 썸네일 속도, 메모리/CPU 사용량)를\n개발자에게 전송합니다. 개인정보는 포함되지 않습니다.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Text("Copyright 2026. All rights reserved.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(16)
            }
        }
        .frame(width: 420, height: 580)
    }

    @State private var isSendingLog = false
    @State private var logSendResult: String?
    @State private var logSendSuccess = false

    private func sendLog() {
        isSendingLog = true
        logSendResult = nil
        AppLogger.sendLogToGoogleDrive { success, message in
            DispatchQueue.main.async {
                isSendingLog = false
                logSendSuccess = success
                logSendResult = message
            }
        }
    }

    private func sendLogByEmail() {
        // Flush log
        AppLogger.log(.general, "로그 이메일 전송 요청")
        let logFile = AppLogger.currentLogFile
        guard FileManager.default.fileExists(atPath: logFile.path) else {
            logSendResult = "로그 파일이 없습니다"
            logSendSuccess = false
            return
        }

        let fileName = "\(AppLogger.deviceName)_v\(AppLogger.appVersion)_log.txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.copyItem(at: logFile, to: tempURL)

        // Open Mail.app with attachment via mailto + NSSharingService
        let service = NSSharingService(named: .composeEmail)
        service?.recipients = ["potokan@pickshot.app"]
        service?.subject = "PickShot 로그 (\(AppLogger.deviceName) v\(AppLogger.appVersion))"
        let body = "PickShot 성능 로그입니다.\n\n장치: \(AppLogger.deviceName)\nIP: \(AppLogger.localIP)\n버전: \(AppLogger.appVersion)"
        service?.perform(withItems: [body, tempURL])

        logSendResult = "이메일 앱이 열렸습니다"
        logSendSuccess = true
    }

    private func saveLogToDesktop() {
        AppLogger.log(.general, "로그 파일 저장 요청")
        let logFile = AppLogger.currentLogFile
        guard FileManager.default.fileExists(atPath: logFile.path) else {
            logSendResult = "로그 파일이 없습니다"
            logSendSuccess = false
            return
        }

        let panel = NSSavePanel()
        panel.title = "로그 파일 저장"
        panel.nameFieldStringValue = "\(AppLogger.deviceName)_v\(AppLogger.appVersion)_log.txt"
        panel.allowedContentTypes = [.plainText]

        if panel.runModal() == .OK, let saveURL = panel.url {
            do {
                try FileManager.default.copyItem(at: logFile, to: saveURL)
                logSendResult = "저장 완료: \(saveURL.lastPathComponent)"
                logSendSuccess = true
            } catch {
                logSendResult = "저장 실패: \(error.localizedDescription)"
                logSendSuccess = false
            }
        }
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
