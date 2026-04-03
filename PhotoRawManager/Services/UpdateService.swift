import Foundation
import SwiftUI

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    // MARK: - Published Properties

    @Published var isUpdateAvailable = false
    @Published var latestVersion = ""
    @Published var currentVersion = ""
    @Published var downloadURL: URL?
    @Published var releaseNotes = ""
    @Published var isChecking = false
    @Published var showUpdateSheet = false
    @Published var showUpToDateAlert = false

    // MARK: - Google Drive 공개 링크
    // version.json 파일 공개 링크 (직접 다운로드 형식)
    // Google Drive 파일 공유 → "링크가 있는 모든 사용자" 설정 후
    // https://drive.google.com/file/d/FILE_ID/view → FILE_ID 추출
    // 직접 다운로드: https://drive.google.com/uc?export=download&id=FILE_ID

    private let versionFileID = ""  // TODO: version.json 파일 ID 입력
    @AppStorage("skippedVersion") private var skippedVersion = ""

    private var versionCheckURL: String {
        "https://drive.google.com/uc?export=download&id=\(versionFileID)"
    }

    // MARK: - Init

    private init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Check for Update

    func checkForUpdate(userInitiated: Bool = false) {
        guard !isChecking, !versionFileID.isEmpty else {
            if userInitiated { showUpToDateAlert = true }
            return
        }
        isChecking = true

        Task {
            defer { isChecking = false }

            guard let url = URL(string: versionCheckURL) else { return }

            var request = URLRequest(url: url)
            request.timeoutInterval = 10

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { return }

                let info = try JSONDecoder().decode(UpdateInfo.self, from: data)

                latestVersion = info.version
                releaseNotes = info.notes ?? ""

                // Google Drive DMG 공개 링크 (직접 다운로드)
                if !info.dmgFileID.isEmpty {
                    downloadURL = URL(string: "https://drive.google.com/uc?export=download&id=\(info.dmgFileID)&confirm=t")
                } else if let directURL = info.downloadURL {
                    downloadURL = URL(string: directURL)
                }

                let hasUpdate = isNewerVersion(info.version, than: currentVersion)

                if hasUpdate {
                    if userInitiated || info.version != skippedVersion {
                        isUpdateAvailable = true
                        showUpdateSheet = true
                    }
                } else if userInitiated {
                    isUpdateAvailable = false
                    showUpToDateAlert = true
                }
            } catch {
                print("[UpdateService] 업데이트 확인 실패: \(error.localizedDescription)")
                if userInitiated { showUpToDateAlert = true }
            }
        }
    }

    // MARK: - Actions

    func openDownloadPage() {
        guard let url = downloadURL else { return }
        NSWorkspace.shared.open(url)
    }

    func skipVersion() {
        skippedVersion = latestVersion
        showUpdateSheet = false
        isUpdateAvailable = false
    }

    func dismissUpdate() {
        showUpdateSheet = false
    }

    // MARK: - Version Comparison

    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        let maxCount = max(remoteParts.count, localParts.count)
        for i in 0..<maxCount {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
}

// MARK: - Update Info (Google Drive version.json)
// version.json 예시:
// {
//   "version": "3.6",
//   "dmgFileID": "1aBcDeFgHiJkLmNoPqRsTuVwXyZ",
//   "notes": "- 얼굴 감지 개선\n- 장면 분류 정확도 향상\n- 성능 최적화",
//   "downloadURL": "https://example.com/PickShot.dmg"  // (선택) dmgFileID 대신 직접 URL
// }

private struct UpdateInfo: Decodable {
    let version: String
    let dmgFileID: String
    let notes: String?
    let downloadURL: String?  // dmgFileID 대신 직접 URL (선택)

    enum CodingKeys: String, CodingKey {
        case version, dmgFileID, notes, downloadURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        dmgFileID = (try? c.decode(String.self, forKey: .dmgFileID)) ?? ""
        notes = try? c.decode(String.self, forKey: .notes)
        downloadURL = try? c.decode(String.self, forKey: .downloadURL)
    }
}
