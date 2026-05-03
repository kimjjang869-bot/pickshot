//
//  GoogleDriveService.swift
//  PhotoRawManager
//
//  Extracted from GoogleDriveService.swift split.
//

import Foundation
import AppKit
import Network
import CommonCrypto

// MARK: - Google Drive Service
// Method 1: Local Google Drive folder copy (no API needed)
// Method 2: Google Drive REST API upload with share link

class GoogleDriveService {

    // MARK: - Method 1: Local Google Drive Folder

    /// Search for Google Drive for Desktop folder on this Mac
    /// - Sandbox: ~/Library/CloudStorage 직접 접근 불가 → 저장된 bookmark 또는 nil 반환
    static func findGoogleDriveFolder() -> URL? {
        // 1. 이전에 사용자가 선택한 Google Drive 폴더 (security-scoped bookmark)
        if let bookmarked = SandboxBookmarkService.resolveBookmark(key: "googleDriveFolder") {
            return bookmarked
        }

        // 2. 경로 직접 탐색 — 샌드박스 빌드에서는 접근이 차단되므로 동작하지 않음.
        //    샌드박스를 비활성화한(non-sandbox) 빌드에서만 폴백으로 사용됨.
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // ~/Google Drive/ — 샌드박스 비활성화 빌드 전용 폴백
        let googleDrive = home.appendingPathComponent("Google Drive")
        if fm.fileExists(atPath: googleDrive.path) {
            let myDrive = googleDrive.appendingPathComponent("My Drive")
            if fm.fileExists(atPath: myDrive.path) {
                return myDrive
            }
            return googleDrive
        }

        // /Volumes/GoogleDrive/ — 샌드박스 비활성화 빌드 전용 폴백
        let volumeGD = URL(fileURLWithPath: "/Volumes/GoogleDrive")
        if fm.fileExists(atPath: volumeGD.path) {
            return volumeGD
        }

        return nil
    }

    /// 사용자가 NSOpenPanel으로 Google Drive 폴더를 선택한 후 bookmark 저장
    static func saveGoogleDriveFolderBookmark(_ url: URL) {
        SandboxBookmarkService.saveBookmark(for: url, key: "googleDriveFolder")
    }

    /// Copy files to a subfolder inside Google Drive local folder
    /// - Parameters:
    ///   - files: file URLs to copy
    ///   - driveRoot: Google Drive root folder
    ///   - folderName: subfolder name to create (e.g. "PickShot_20260322")
    ///   - progress: callback with (completedCount, totalCount)
    /// - Returns: destination folder URL on success
    static func copyToGoogleDrive(
        files: [URL],
        driveRoot: URL,
        folderName: String,
        progress: @escaping (Int, Int) -> Void
    ) throws -> URL {
        let fm = FileManager.default
        let destFolder = driveRoot.appendingPathComponent(folderName)

        if !fm.fileExists(atPath: destFolder.path) {
            try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
        }

        let total = files.count
        for (index, fileURL) in files.enumerated() {
            let destFile = destFolder.appendingPathComponent(fileURL.lastPathComponent)

            // Skip if already exists
            if fm.fileExists(atPath: destFile.path) {
                try fm.removeItem(at: destFile)
            }
            try fm.copyItem(at: fileURL, to: destFile)

            DispatchQueue.main.async {
                progress(index + 1, total)
            }
        }

        return destFolder
    }

    // MARK: - Method 2: Google Drive REST API

    struct UploadResult {
        let fileId: String
        let fileName: String
    }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 대용량 파일 업로드용 전용 URLSession (타임아웃 연장, 연결 복구 대기)
    private static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120     // 요청 타임아웃 2분
        config.timeoutIntervalForResource = 600    // 리소스 타임아웃 10분
        config.waitsForConnectivity = true          // 연결 복구 대기
        return URLSession(configuration: config)
    }()

    /// 5MB 이상 → resumable upload, 미만 → multipart (기존 방식)
    private static let resumableThreshold = 5 * 1024 * 1024

    /// Upload a single file to Google Drive via REST API
    /// 5MB 미만: multipart, 5MB 이상: resumable upload (청크 전송, 메모리 효율)
    static func uploadFile(
        fileURL: URL,
        folderId: String?,
        accessToken: String,
        completion: @escaping (UploadResult?, Error?) -> Void
    ) {
        let fileName = fileURL.lastPathComponent
        let mimeType = mimeTypeForExtension(fileURL.pathExtension)

        // 파일 크기 확인
        let fileSize: Int
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            fileSize = (attrs[.size] as? Int) ?? 0
        } catch {
            completion(nil, APIError(message: "파일을 읽을 수 없습니다: \(fileName)"))
            return
        }

        plog("[GDRIVE] upload \(fileName) (\(fileSize / 1024)KB) → folder=\(folderId ?? "ROOT")\n")

        if fileSize >= resumableThreshold {
            // 대용량: resumable upload (스트리밍, 메모리 절약)
            uploadResumable(fileURL: fileURL, fileName: fileName, mimeType: mimeType,
                           fileSize: fileSize, folderId: folderId, accessToken: accessToken, completion: completion)
        } else {
            // 소용량: 기존 multipart
            uploadMultipart(fileURL: fileURL, fileName: fileName, mimeType: mimeType,
                           folderId: folderId, accessToken: accessToken, completion: completion)
        }
    }

    // MARK: - Multipart Upload (< 5MB)

    private static func uploadMultipart(
        fileURL: URL, fileName: String, mimeType: String,
        folderId: String?, accessToken: String,
        completion: @escaping (UploadResult?, Error?) -> Void
    ) {
        guard let fileData = try? Data(contentsOf: fileURL) else {
            completion(nil, APIError(message: "파일을 읽을 수 없습니다: \(fileName)"))
            return
        }

        var metadata: [String: Any] = ["name": fileName]
        if let folderId = folderId, !folderId.isEmpty {
            metadata["parents"] = [folderId]
        }
        guard let metadataJSON = try? JSONSerialization.data(withJSONObject: metadata) else {
            completion(nil, APIError(message: "메타데이터 생성 실패"))
            return
        }

        let boundary = "pickshot_\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataJSON)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        uploadSession.dataTask(with: request) { data, response, error in
            if let error = error { completion(nil, error); return }
            parseUploadResponse(data: data, response: response, fileName: fileName, completion: completion)
        }.resume()
    }

    // MARK: - Resumable Upload (≥ 5MB) — 스트리밍, 메모리 절약

    private static func uploadResumable(
        fileURL: URL, fileName: String, mimeType: String,
        fileSize: Int, folderId: String?, accessToken: String,
        completion: @escaping (UploadResult?, Error?) -> Void
    ) {
        var metadata: [String: Any] = ["name": fileName]
        if let folderId = folderId, !folderId.isEmpty {
            metadata["parents"] = [folderId]
        }
        guard let metadataJSON = try? JSONSerialization.data(withJSONObject: metadata) else {
            completion(nil, APIError(message: "메타데이터 생성 실패"))
            return
        }

        // Step 1: resumable 세션 시작 요청
        var initRequest = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,name")!)
        initRequest.httpMethod = "POST"
        initRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        initRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initRequest.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        initRequest.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        initRequest.httpBody = metadataJSON

        uploadSession.dataTask(with: initRequest) { _, response, error in
            if let error = error { completion(nil, error); return }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let uploadURL = httpResponse.value(forHTTPHeaderField: "Location") else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion(nil, APIError(message: "Resumable 세션 시작 실패 (HTTP \(code))"))
                return
            }

            plog("[GDRIVE] resumable session started: \(fileName)\n")

            // Step 2: 파일 데이터 PUT (uploadTask로 스트리밍 — 메모리에 전체 로드 안 함)
            // v9.0: 서버 응답 URL 파싱 실패 시 force unwrap 크래시 방지.
            guard let putURL = URL(string: uploadURL) else {
                plog("[GDRIVE] invalid upload URL from server: \(uploadURL)\n")
                completion(nil, NSError(domain: "GoogleDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"]))
                return
            }
            var putRequest = URLRequest(url: putURL)
            putRequest.httpMethod = "PUT"
            putRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            putRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            putRequest.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")

            // uploadTask(with:fromFile:)는 파일을 스트리밍하므로 메모리에 전체 로드하지 않음
            uploadSession.uploadTask(with: putRequest, fromFile: fileURL) { data, response, error in
                if let error = error { completion(nil, error); return }
                parseUploadResponse(data: data, response: response, fileName: fileName, completion: completion)
            }.resume()
        }.resume()
    }

    // MARK: - 응답 파싱 (공통)

    private static func parseUploadResponse(
        data: Data?, response: URLResponse?, fileName: String,
        completion: @escaping (UploadResult?, Error?) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completion(nil, APIError(message: "잘못된 응답"))
            return
        }
        guard httpResponse.statusCode == 200 else {
            let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No body"
            completion(nil, APIError(message: "API 오류 (\(httpResponse.statusCode)): \(responseBody)"))
            return
        }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileId = json["id"] as? String else {
            completion(nil, APIError(message: "응답 파싱 실패"))
            return
        }
        let name = json["name"] as? String ?? fileName
        completion(UploadResult(fileId: fileId, fileName: name), nil)
    }

    /// Create a public share link for a file on Google Drive
    /// - Parameters:
    ///   - fileId: Google Drive file ID
    ///   - accessToken: OAuth2 Bearer token
    ///   - completion: (shareLink: String?, Error?)
    /// - Warning: v9.1.4 보안 (H-1): role="writer" + type="anyone" 조합은 링크 아는 누구나
    ///   해당 폴더에 파일 upload/edit/delete 가능. 폐쇄 클라이언트 셀렉 워크플로우에서만 사용 권장.
    ///   범용 공유에는 반드시 "reader" 사용. ⚠️ 향후 per-file permission 으로 리팩토링 권장.
    static func createShareLink(
        fileId: String,
        accessToken: String,
        role: String = "reader",
        completion: @escaping (String?, Error?) -> Void
    ) {
        // v9.1.4 보안 (H-1): writer 권한 사용 시 명시적 로그 — 잘못된 호출 추적용.
        if role == "writer" {
            plog("[GDRIVE-SEC] ⚠️ createShareLink(role=writer) called for \(fileId.prefix(8)) — anyone with link can modify\n")
        }
        // Step 1: Create permission (anyone with link can view/edit based on role)
        guard let permURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)/permissions") else {
            completion(nil, APIError(message: "잘못된 permissions URL"))
            return
        }
        var permRequest = URLRequest(url: permURL)
        permRequest.httpMethod = "POST"
        permRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        permRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let permBody: [String: Any] = [
            "role": role,
            "type": "anyone"
        ]
        permRequest.httpBody = try? JSONSerialization.data(withJSONObject: permBody)

        // v9.1.4 (H-3): 401 자동 갱신 재시도
        performWithAutoRefresh(permRequest) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(nil, APIError(message: "공유 권한 설정 실패 (\(statusCode))"))
                return
            }

            // Step 2: Get the webViewLink
            guard let fileURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?fields=webViewLink,webContentLink") else {
                completion(nil, APIError(message: "잘못된 file URL"))
                return
            }
            var fileRequest = URLRequest(url: fileURL)
            fileRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            performWithAutoRefresh(fileRequest) { data, response, error in
                if let error = error {
                    completion(nil, error)
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    // Fallback: construct link manually
                    completion("https://drive.google.com/file/d/\(fileId)/view?usp=sharing", nil)
                    return
                }

                let link = json["webViewLink"] as? String
                    ?? json["webContentLink"] as? String
                    ?? "https://drive.google.com/file/d/\(fileId)/view?usp=sharing"

                completion(link, nil)
            }
        }
    }

    /// Create a folder on Google Drive and return its ID
    static func createFolder(
        name: String,
        accessToken: String,
        completion: @escaping (String?, Error?) -> Void
    ) {
        let urlString = "https://www.googleapis.com/drive/v3/files?fields=id"
        guard let url = URL(string: urlString) else {
            completion(nil, APIError(message: "잘못된 API URL"))
            return
        }

        let metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder"
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: metadata)

        // v9.1.4 (H-3): 401 자동 갱신 재시도
        performWithAutoRefresh(request) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            plog("[GDRIVE] createFolder HTTP \(statusCode)\n")
            guard let data = data else {
                completion(nil, APIError(message: "응답 데이터 없음"))
                return
            }
            // v9.1.4 보안 (M-1): 에러일 때만 응답 본문 로깅 (정상 200 응답은 id 만이라 누출 없지만,
            //   에러 응답에 OAuth scope/계정 정보 포함될 수 있어 로그 분리).
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folderId = json["id"] as? String else {
                let responseStr = String(data: data, encoding: .utf8) ?? ""
                plog("[GDRIVE] createFolder error response: \(responseStr.prefix(200))\n")
                completion(nil, APIError(message: "폴더 생성 실패 (HTTP \(statusCode))"))
                return
            }

            completion(folderId, nil)
        }
    }

    /// Delete a file from Google Drive
    static func deleteFile(
        fileId: String,
        accessToken: String,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        let urlString = "https://www.googleapis.com/drive/v3/files/\(fileId)"
        guard let url = URL(string: urlString) else {
            completion(false, APIError(message: "잘못된 API URL"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        // v9.1.4 (H-3): 401 자동 갱신 재시도
        performWithAutoRefresh(request) { _, response, error in
            if let error = error {
                completion(false, error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 204 No Content = success, 404 = already deleted
            completion(status == 204 || status == 404, nil)
        }
    }

    // MARK: - 폴더 내 파일 목록 조회 (중복 체크용)

    static func listFiles(
        folderId: String,
        accessToken: String,
        completion: @escaping ([String], Error?) -> Void  // 파일명 배열
    ) {
        let query = "'\(folderId)' in parents and trashed = false"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://www.googleapis.com/drive/v3/files?q=\(encoded)&fields=files(name)&pageSize=1000"
        guard let url = URL(string: urlString) else {
            completion([], APIError(message: "잘못된 API URL"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        // v9.1.4 (H-3): 401 자동 갱신 재시도
        performWithAutoRefresh(request) { data, _, error in
            if let error = error {
                completion([], error)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]] else {
                completion([], nil)
                return
            }
            let names = files.compactMap { $0["name"] as? String }
            completion(names, nil)
        }
    }

    // MARK: - OAuth 2.0

    // v9.1.4: Client Secret 소스 하드코딩 제거 (보안 감사 C-1).
    //   Google Desktop App 의 OAuth flow 는 PKCE 사용 시 Secret 없이도 동작 가능.
    //   Client ID 는 public, Secret 은 Keychain / Secrets.xcconfig 에서만 로드.
    //   ⚠ 이전 노출 Secret (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) 은 Google Cloud Console 에서 즉시 rotate 필요.
    // v9.1.4: Desktop OAuth Client 유지. Secret 만 회전 (Reset Secret).
    private static let defaultClientID = "661638823938-f9bk0a503pv0js0iskdqd196erkg40ua.apps.googleusercontent.com"
    static var oauthClientID: String {
        let saved = KeychainService.read(key: "gdrive_client_id") ?? ""
        return saved.isEmpty ? defaultClientID : saved
    }
    static var oauthClientSecret: String {
        // Keychain 우선, 없으면 빈 문자열 → token endpoint 가 PKCE-only 모드로 동작.
        return KeychainService.read(key: "gdrive_client_secret") ?? ""
    }

    static func setOAuthCredentials(clientID: String, clientSecret: String) {
        _ = KeychainService.save(key: "gdrive_client_id", value: clientID)
        _ = KeychainService.save(key: "gdrive_client_secret", value: clientSecret)
    }

    /// Load OAuth secrets from Secrets.xcconfig file (project root)
    static func loadSecretsFromConfig() {
        // Try project root (development) and bundle (release)
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Secrets.xcconfig"),
            Bundle.main.url(forResource: "Secrets", withExtension: "xcconfig"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Secrets.xcconfig")
        ].compactMap { $0 }

        for url in candidates {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var cid = "", cs = ""
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("GDRIVE_CLIENT_ID") {
                    cid = trimmed.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""
                } else if trimmed.hasPrefix("GDRIVE_CLIENT_SECRET") {
                    cs = trimmed.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""
                }
            }
            if !cid.isEmpty && !cs.isEmpty {
                setOAuthCredentials(clientID: cid, clientSecret: cs)
                return
            }
        }
    }

    static var oauthRedirectURI: String {
        // For macOS desktop apps, use loopback
        "http://127.0.0.1:8085/oauth/callback"
    }

    static var savedAccessToken: String? {
        get {
            if let key = KeychainService.read(key: "gdrive_access_token") { return key }
            // Migrate from UserDefaults
            KeychainService.migrateFromUserDefaults(userDefaultsKey: "GoogleDriveAccessToken", keychainKey: "gdrive_access_token")
            return KeychainService.read(key: "gdrive_access_token")
        }
        set {
            if let v = newValue { _ = KeychainService.save(key: "gdrive_access_token", value: v) }
            else { _ = KeychainService.delete(key: "gdrive_access_token") }
        }
    }

    static var savedRefreshToken: String? {
        get {
            if let key = KeychainService.read(key: "gdrive_refresh_token") { return key }
            KeychainService.migrateFromUserDefaults(userDefaultsKey: "GoogleDriveRefreshToken", keychainKey: "gdrive_refresh_token")
            return KeychainService.read(key: "gdrive_refresh_token")
        }
        set {
            if let v = newValue { _ = KeychainService.save(key: "gdrive_refresh_token", value: v) }
            else { _ = KeychainService.delete(key: "gdrive_refresh_token") }
        }
    }

    static var isLoggedIn: Bool {
        savedAccessToken != nil
    }

    // PKCE code verifier/challenge for secure auth without client secret
    private static var codeVerifier: String = ""

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Start OAuth login flow with PKCE - no client secret needed
    static func startOAuthLogin(completion: @escaping (String?, Error?) -> Void) {
        guard !oauthClientID.isEmpty else {
            completion(nil, APIError(message: "Google OAuth Client ID가 설정되지 않았습니다."))
            return
        }

        // Generate PKCE verifier and challenge
        codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        // v9.1.4 보안 (C-2): state 파라미터는 CSRF 방어의 유일한 수단 → 암호학적 RNG 필수.
        //   이전 UInt8.random(in:) 은 표준 lib RNG (보장 없음). SecRandomCopyBytes 로 통일.
        var stateBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)
        let stateToken = Data(stateBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        oauthState = stateToken

        // v8.8.0: 서버를 먼저 시작해서 실제 바인딩된 port 를 얻은 뒤 redirect_uri 에 반영.
        //   8085 가 사용중이면 8086, 8087 … 로 fallback.
        startLocalOAuthServer { code, error in
            if let error = error {
                completion(nil, error)
                return
            }
            guard let code = code else {
                completion(nil, APIError(message: "인증 코드를 받지 못했습니다"))
                return
            }
            exchangeCodeForToken(code: code, completion: completion)
        }

        // 바인딩된 port 로 redirect_uri 구성
        let port = localServer?.boundPort ?? 8085
        let redirect = "http://127.0.0.1:\(port)/oauth/callback"
        oauthRedirectURIRuntime = redirect

        let scopes = "https://www.googleapis.com/auth/drive.file"
        let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
            + "?client_id=\(oauthClientID)"
            + "&redirect_uri=\(redirect)"
            + "&response_type=code"
            + "&scope=\(scopes)"
            + "&access_type=offline"
            + "&prompt=consent"
            + "&code_challenge=\(codeChallenge)"
            + "&code_challenge_method=S256"
            + "&state=\(stateToken)"

        // Open browser
        if let url = URL(string: authURL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// v8.8.0: 실제 서버가 바인딩된 redirect URI. token 교환 시 동일한 값 사용해야 함.
    private static var oauthRedirectURIRuntime: String = "http://127.0.0.1:8085/oauth/callback"

    private static var localServer: LocalOAuthServer?
    private static var oauthState: String = ""  // CSRF 방지용 state 토큰

    private static func startLocalOAuthServer(completion: @escaping (String?, Error?) -> Void) {
        _ = oauthState
        // v8.8.0: 이전 OAuth 시도가 완료/취소 안 된 경우 listener 가 port 를 잡고 있을 수 있음 → 먼저 해제.
        localServer?.stop()
        localServer = nil
        // v8.6.1 보안: LocalOAuthServer 에 expectedState 전달 (CSRF 방지)
        localServer = LocalOAuthServer(port: 8085, expectedState: oauthState, completion: { code, error in
            // state 파라미터 미검증 시 CSRF 공격 가능 — 서버에서 state 추출 후 비교
            completion(code, error)
        })
        localServer?.start()
    }

    private static func exchangeCodeForToken(code: String, completion: @escaping (String?, Error?) -> Void) {
        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            completion(nil, APIError(message: "잘못된 token URL"))
            return
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // PKCE 사용 시 client_secret이 없어도 됨 (Desktop App)
        // 빈 문자열로 보내면 Google이 invalid_request 에러 → 빈 값이면 파라미터 생략
        var body = "code=\(code)"
            + "&client_id=\(oauthClientID)"
            + "&redirect_uri=\(oauthRedirectURIRuntime)"  // v8.8.0: start 시 바인딩된 port 와 일치
            + "&grant_type=authorization_code"
            + "&code_verifier=\(codeVerifier)"
        if !oauthClientSecret.isEmpty {
            body += "&client_secret=\(oauthClientSecret)"
        }
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(nil, error)
                return
            }
            guard let data = data else {
                completion(nil, APIError(message: "토큰 교환: 응답 없음"))
                return
            }

            // 보안: 토큰 응답은 로그에 출력하지 않음 (access_token 노출 방지)
            _ = String(data: data, encoding: .utf8) ?? "unreadable"

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, APIError(message: "토큰 교환: JSON 파싱 실패"))
                return
            }

            if let errorMsg = json["error"] as? String {
                let desc = json["error_description"] as? String ?? ""
                plog("[GDRIVE] Token error: \(errorMsg) - \(desc)\n")
                completion(nil, APIError(message: "Google 오류: \(errorMsg)\n\(desc)"))
                return
            }

            guard let accessToken = json["access_token"] as? String else {
                completion(nil, APIError(message: "토큰 교환: access_token 없음"))
                return
            }

            savedAccessToken = accessToken
            if let refreshToken = json["refresh_token"] as? String {
                savedRefreshToken = refreshToken
            }
            completion(accessToken, nil)
        }.resume()
    }

    // v9.1.4 보안 (H-2): refreshAccessToken race condition 방어 — 동시 호출 시
    //   첫 요청만 실제 갱신, 나머지는 대기 후 동일 결과 수신.
    //   이전엔 병렬 401 발생 시 refresh token 이 일회성 교체되어 invalid_grant → 강제 로그아웃.
    private static let refreshLock = NSLock()
    private static var isRefreshing = false
    private static var refreshWaiters: [(String?, Error?) -> Void] = []

    // v9.1.4 보안 (H-3): 401 받으면 토큰 자동 갱신 후 1회 재시도. 재시도 401 시 최종 실패.
    //   사용자가 1시간마다 수동 재로그인하던 문제 해결. createFolder/listFiles/deleteFile/createShareLink 적용.
    //   uploadMultipart/uploadResumable 은 multipart 본문 재전송 복잡성 → follow-up.
    private static func performWithAutoRefresh(
        _ request: URLRequest,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                refreshAccessToken { newToken, refreshErr in
                    guard let newToken = newToken else {
                        completion(data, response, refreshErr ?? error)
                        return
                    }
                    var retry = request
                    retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    URLSession.shared.dataTask(with: retry, completionHandler: completion).resume()
                }
                return
            }
            completion(data, response, error)
        }.resume()
    }

    /// v9.1.4 (H-4): refresh_token 만료 vs 일반 실패 구분용 sentinel.
    ///   호출자가 이 에러 코드 감지 시 사용자에게 "재로그인 필요" 안내 가능.
    static let refreshTokenExpiredError = APIError(message: "리프레시 토큰이 만료되었습니다. 다시 로그인해주세요. [GDRIVE_REAUTH_REQUIRED]")

    /// Refresh access token using saved refresh token
    static func refreshAccessToken(completion: @escaping (String?, Error?) -> Void) {
        // race 방어: 진행 중이면 대기열에 추가하고 종료.
        refreshLock.lock()
        if isRefreshing {
            refreshWaiters.append(completion)
            refreshLock.unlock()
            return
        }
        isRefreshing = true
        refreshLock.unlock()

        let finish: (String?, Error?) -> Void = { token, err in
            refreshLock.lock()
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            isRefreshing = false
            refreshLock.unlock()
            completion(token, err)
            for w in waiters { w(token, err) }
        }

        guard let refreshToken = savedRefreshToken, !oauthClientID.isEmpty else {
            finish(nil, refreshTokenExpiredError)
            return
        }

        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            finish(nil, APIError(message: "잘못된 token URL"))
            return
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = "refresh_token=\(refreshToken)"
            + "&client_id=\(oauthClientID)"
            + "&grant_type=refresh_token"
        if !oauthClientSecret.isEmpty {
            body += "&client_secret=\(oauthClientSecret)"
        }
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                finish(nil, error)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                finish(nil, APIError(message: "토큰 갱신 응답 파싱 실패"))
                return
            }
            // v9.1.4 (H-4): invalid_grant 감지 → 명확한 에러 코드.
            //   Google OAuth: refresh_token 만료/취소 시 error="invalid_grant".
            if let errorCode = json["error"] as? String {
                if errorCode == "invalid_grant" {
                    // refresh token 폐기 + 재로그인 유도
                    savedRefreshToken = nil
                    savedAccessToken = nil
                    finish(nil, refreshTokenExpiredError)
                } else {
                    let desc = json["error_description"] as? String ?? errorCode
                    finish(nil, APIError(message: "토큰 갱신 실패: \(desc)"))
                }
                return
            }
            guard let accessToken = json["access_token"] as? String else {
                finish(nil, APIError(message: "토큰 갱신 실패: access_token 없음"))
                return
            }
            savedAccessToken = accessToken
            // v9.1.4: refresh_token 도 회전될 수 있음 (Google 정책에 따라).
            if let newRefresh = json["refresh_token"] as? String {
                savedRefreshToken = newRefresh
            }
            finish(accessToken, nil)
        }.resume()
    }

    /// Logout - Google 서버에서 토큰 revoke + 로컬 토큰 삭제
    /// Google API 정책 준수: https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke
    static func logout() {
        // 1. Google 서버에 revoke 요청 (refresh token 우선, 없으면 access token)
        let tokenToRevoke = savedRefreshToken ?? savedAccessToken
        if let token = tokenToRevoke, !token.isEmpty {
            revokeToken(token) { success in
                if success {
                    AppLogger.log(.general, "Google OAuth 토큰 revoke 성공")
                } else {
                    AppLogger.log(.general, "Google OAuth 토큰 revoke 실패 (로컬 삭제는 완료)")
                }
            }
        }
        // 2. 로컬 토큰/캐시 즉시 삭제 (revoke 결과 기다리지 않음)
        savedAccessToken = nil
        savedRefreshToken = nil
        // 3. Google Drive 폴더 bookmark 도 삭제 (사용자가 선택한 저장 위치)
        SandboxBookmarkService.removeBookmark(key: "googleDriveFolder")
    }

    /// Google OAuth 토큰을 서버에서 revoke
    private static func revokeToken(_ token: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://oauth2.googleapis.com/revoke") else {
            completion(false); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(token)".data(using: .utf8)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                completion(true)
            } else {
                completion(false)
            }
        }.resume()
    }

    // MARK: - Helpers

    private static func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "tiff", "tif": return "image/tiff"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "jxl": return "image/jxl"
        case "jp2", "j2k", "jpx": return "image/jp2"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "psd": return "image/vnd.adobe.photoshop"
        case "tga": return "image/x-tga"
        case "exr": return "image/x-exr"
        case "ico": return "image/x-icon"
        case "hdr": return "image/vnd.radiance"
        case "cr2": return "image/x-canon-cr2"
        case "cr3": return "image/x-canon-cr3"
        case "nef": return "image/x-nikon-nef"
        case "arw": return "image/x-sony-arw"
        case "raf": return "image/x-fuji-raf"
        case "dng": return "image/x-adobe-dng"
        case "orf": return "image/x-olympus-orf"
        case "rw2": return "image/x-panasonic-rw2"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "avi": return "video/x-msvideo"
        default: return "application/octet-stream"
        }
    }
}
