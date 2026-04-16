import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) var dismiss

    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "8.0"
    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

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

                    // v8.0 Changelog (최신)
                    changelogSection("v8.0 새로운 기능", items: [
                        "비디오 플레이어 — MP4/MOV 재생, 썸네일 미리보기",
                        "LUT 관리 — .cube 파일 로딩 + 실시간 프리뷰",
                        "컬러 라벨 전면 개편 — 빨강/노랑/초록/파랑/보라 (6~9키)",
                        "AI 모델 업데이트 (NIMA + AdaFace R18)",
                        "삭제 UX 개선 — 확인 건너뛰기 옵션 + 다음 사진 자동 이동",
                        "썸네일/필름스트립 보더 체계 재정비 (별점/라벨/SP)",
                        "외부 Finder 드롭 지원 (필름스트립/그리드)",
                        "마우스 뒤로/앞으로 버튼 → 폴더 히스토리 이동",
                        "PhotoStore 대규모 모듈화 (Selection/Folder/Rating/...)",
                        "크래시/데이터레이스/메모리누수 수정 (v7.6~v7.7)",
                        "보안 강화 — OAuth PKCE, Secrets.xcconfig 분리",
                    ])

                    changelogSection("v7.x", items: [
                        "AdaFace 얼굴 인식 (R18 CoreML)",
                        "JPG+RAW 매칭 + 내보내기 UI 개편",
                        "수평/수직 보정 + 썸네일 최적화",
                        "3주 트라이얼 시스템",
                        "FolderWatcher 리로드/CPU 과부하 수정",
                        "SmartCull + 인물 메뉴 + HDD/SD 최적화",
                    ])

                    changelogSection("v6.0", items: [
                        "NIMA AI 미적 품질 점수 (CoreML)",
                        "표정 감지 + 얼굴 비교 패널",
                        "컬링 강도 조절 (엄격/보통/느슨)",
                        "XMP 사이드카 (Lightroom/Bridge 호환)",
                        "Upright 가이드 + 듀얼 스크린 뷰어",
                        "EXIF Rating 자동 적용",
                    ])

                    changelogSection("v5.0 이전", items: [
                        "전체화면 컬링 모드 (Cmd+F) + 필름스트립",
                        "메모리카드 자동 백업",
                        "Before/After 보정 비교",
                        "HW JPEG 디코더 + Metal GPU 가속",
                        "Vision 장면 분류 + 얼굴 그룹핑",
                        "Google Drive 업로드 + G Select 웹 뷰어",
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

                    // 법적 링크
                    HStack(spacing: 14) {
                        Link("개인정보 처리방침", destination: URL(string: "https://pickshot.app/privacy.html")!)
                            .font(.system(size: 11))
                        Link("서비스 약관", destination: URL(string: "https://pickshot.app/terms.html")!)
                            .font(.system(size: 11))
                        Link("홈페이지", destination: URL(string: "https://pickshot.app")!)
                            .font(.system(size: 11))
                    }

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
