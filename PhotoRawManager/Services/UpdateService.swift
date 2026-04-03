import Foundation
import SwiftUI

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published var isUpdateAvailable = false
    @Published var latestVersion = ""
    @Published var currentVersion = ""
    @Published var downloadURL: URL?
    @Published var releaseNotes = ""
    @Published var isChecking = false
    @Published var showUpdateSheet = false
    @Published var showUpToDateAlert = false

    private let githubAPI = "https://api.github.com/repos/kimjjang869-bot/pickshot/releases/latest"
    @AppStorage("skippedVersion") private var skippedVersion = ""

    private init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdate(userInitiated: Bool = false) {
        guard !isChecking else { return }
        isChecking = true

        Task {
            defer { isChecking = false }
            guard let url = URL(string: githubAPI) else { return }

            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

                latestVersion = version
                releaseNotes = release.body ?? ""

                // DMG 에셋 찾기, 없으면 릴리즈 페이지
                if let dmg = release.assets?.first(where: { $0.name.hasSuffix(".dmg") }) {
                    downloadURL = URL(string: dmg.browserDownloadURL)
                } else {
                    downloadURL = URL(string: release.htmlURL)
                }

                if isNewerVersion(version, than: currentVersion) {
                    if userInitiated || version != skippedVersion {
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

    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let body: String?
    let assets: [GitHubAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
