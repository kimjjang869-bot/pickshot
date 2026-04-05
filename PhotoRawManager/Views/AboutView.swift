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

                    // v6.0 Changelog
                    changelogSection("v6.0 새로운 기능", items: [
                        "NIMA AI 미적 품질 점수 (CoreML, 1~10점)",
                        "표정 감지 — 웃는 얼굴 자동 인식 + 점수",
                        "얼굴 비교 패널 — 연사 표정 나란히 비교",
                        "컬링 강도 조절 (엄격/보통/느슨)",
                        "XMP 사이드카 읽기/쓰기 (Lightroom/Bridge 호환)",
                        "키워드 자동 태깅 (Vision 분류 → IPTC 키워드)",
                        "Upright 가이드 모드 (수직선 드래그 → 원근 보정)",
                        "듀얼 스크린 뷰어 (D키, 별도 윈도우)",
                        "성능 최적화 탭 (벤치마크 + 원클릭 최적화)",
                        "드래그 앤 드롭 파일 이동 (썸네일 → 폴더 트리)",
                        "화면 크기 자동 대응 (14인치~32인치)",
                        "EXIF Rating 자동 적용 (카메라 별점)",
                    ])

                    changelogSection("v5.0", items: [
                        "전체화면 컬링 모드 (Cmd+F) + 필름스트립",
                        "메모리카드 자동 백업 (DCIM 감지 → 안전 복사)",
                        "Before/After 보정 비교 슬라이더",
                        "빠른 탐색 최적화 (썸네일 즉시 표시)",
                        "마지막 폴더 자동 복원",
                    ])

                    changelogSection("v3.0 ~ v3.6", items: [
                        "HW JPEG 디코더 + Metal GPU 가속",
                        "Vision 장면 분류 + 얼굴 그룹핑",
                        "RAW → JPG 배치 변환",
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
