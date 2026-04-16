import Foundation

/// Sandbox Security-Scoped Bookmark 관리 서비스
/// - NSOpenPanel 에서 선택한 URL → bookmark Data 저장
/// - 재실행 시 bookmark Data → URL 복원 + startAccessingSecurityScopedResource
enum SandboxBookmarkService {

    private static let bookmarkStoreKey = "sandboxBookmarks"

    /// URL에 대한 security-scoped bookmark 저장
    static func saveBookmark(for url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var store = UserDefaults.standard.dictionary(forKey: bookmarkStoreKey) as? [String: Data] ?? [:]
            store[key] = data
            UserDefaults.standard.set(store, forKey: bookmarkStoreKey)
        } catch {
            AppLogger.log(.general, "Bookmark 저장 실패 [\(key)]: \(error.localizedDescription)")
        }
    }

    /// 저장된 bookmark에서 URL 복원 (security-scoped access 시작됨 — 반드시 stop 호출 필요)
    static func resolveBookmark(key: String) -> URL? {
        guard let store = UserDefaults.standard.dictionary(forKey: bookmarkStoreKey) as? [String: Data],
              let data = store[key] else { return nil }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                // Re-save fresh bookmark
                saveBookmark(for: url, key: key)
            }
            guard url.startAccessingSecurityScopedResource() else {
                AppLogger.log(.general, "Security scope 접근 실패: \(key)")
                return nil
            }
            return url
        } catch {
            AppLogger.log(.general, "Bookmark 복원 실패 [\(key)]: \(error.localizedDescription)")
            return nil
        }
    }

    /// 여러 URL의 bookmark 일괄 저장 (recent folders, favorites 등)
    static func saveBookmarks(for urls: [URL], keyPrefix: String) {
        for (i, url) in urls.enumerated() {
            saveBookmark(for: url, key: "\(keyPrefix)_\(i)")
        }
        // Count 저장
        UserDefaults.standard.set(urls.count, forKey: "\(keyPrefix)_count")
    }

    /// 여러 bookmark 일괄 복원 (security-scoped access 시작됨 — 반드시 stop 필요)
    static func resolveBookmarks(keyPrefix: String) -> [URL] {
        let count = UserDefaults.standard.integer(forKey: "\(keyPrefix)_count")
        var urls: [URL] = []
        for i in 0..<count {
            if let url = resolveBookmark(key: "\(keyPrefix)_\(i)") {
                urls.append(url)
            }
        }
        return urls
    }

    /// 여러 bookmark 의 URL 만 조회 (security scope 시작하지 않음 — 목록 표시용)
    static func resolveBookmarkURLs(keyPrefix: String) -> [URL] {
        guard let store = UserDefaults.standard.dictionary(forKey: bookmarkStoreKey) as? [String: Data] else { return [] }
        let count = UserDefaults.standard.integer(forKey: "\(keyPrefix)_count")
        var urls: [URL] = []
        for i in 0..<count {
            let key = "\(keyPrefix)_\(i)"
            guard let data = store[key] else { continue }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                urls.append(url)
            }
        }
        return urls
    }

    /// Security-scoped resource 접근 해제
    static func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    // MARK: - 활성 접근 관리

    /// 현재 활성화된 security-scoped URL (폴더 전환 시 이전 것을 해제)
    private static var activeAccessURL: URL?

    /// 폴더 접근 시작 — 이전 활성 접근 해제 + 새 접근 유지
    /// bookmark 으로 먼저 시도하고, 실패 시 false 반환
    static func startFolderAccess(for url: URL) -> Bool {
        // 이미 읽을 수 있으면 추가 작업 불필요
        if FileManager.default.isReadableFile(atPath: url.path) { return true }

        // 저장된 모든 bookmark 에서 이 URL 또는 부모 URL 을 커버하는 것 찾기
        guard let store = UserDefaults.standard.dictionary(forKey: bookmarkStoreKey) as? [String: Data] else {
            return false
        }

        for (bookmarkKey, data) in store {
            do {
                var isStale = false
                let bookmarkedURL = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                let bookmarkedPath = bookmarkedURL.path
                let targetPath = url.path
                // 경로 경계 정확히 확인: /Volumes/Photos 가 /Volumes/Photos2 와 매치되지 않도록
                let isMatch = targetPath == bookmarkedPath
                    || targetPath.hasPrefix(bookmarkedPath + "/")
                if isMatch {
                    if bookmarkedURL.startAccessingSecurityScopedResource() {
                        // 이전 활성 접근 해제
                        if let prev = activeAccessURL, prev != bookmarkedURL {
                            prev.stopAccessingSecurityScopedResource()
                        }
                        activeAccessURL = bookmarkedURL
                        if isStale { saveBookmark(for: bookmarkedURL, key: bookmarkKey) }
                        return true
                    }
                }
            } catch { continue }
        }
        return false
    }

    /// 현재 활성 접근 해제
    static func stopFolderAccess() {
        if let url = activeAccessURL {
            url.stopAccessingSecurityScopedResource()
            activeAccessURL = nil
        }
    }

    /// 특정 키의 bookmark 삭제
    static func removeBookmark(key: String) {
        var store = UserDefaults.standard.dictionary(forKey: bookmarkStoreKey) as? [String: Data] ?? [:]
        store.removeValue(forKey: key)
        UserDefaults.standard.set(store, forKey: bookmarkStoreKey)
    }
}
