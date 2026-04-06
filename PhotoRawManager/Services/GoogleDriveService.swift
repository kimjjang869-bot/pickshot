import Foundation
import AppKit
import Network
import CommonCrypto

// MARK: - Local OAuth Server (receives callback from browser)

class LocalOAuthServer {
    private var listener: NWListener?
    private let port: UInt16
    private let completion: (String?, Error?) -> Void

    init(port: UInt16, completion: @escaping (String?, Error?) -> Void) {
        self.port = port
        self.completion = completion
    }

    func start() {
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                completion(nil, NSError(domain: "LocalOAuthServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"]))
                return
            }
            listener = try NWListener(using: .tcp, on: nwPort)
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener?.start(queue: .global(qos: .userInitiated))
        } catch {
            completion(nil, error)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let data = data, let request = String(data: data, encoding: .utf8) else {
                self?.stop()
                return
            }

            // Parse authorization code from GET request
            var code: String?
            if let range = request.range(of: "code=") {
                let codeStart = request[range.upperBound...]
                if let end = codeStart.firstIndex(of: "&") ?? codeStart.firstIndex(of: " ") {
                    code = String(codeStart[..<end])
                } else {
                    code = String(codeStart)
                }
            }

            // Send response HTML
            let html = """
            <html><body style="font-family:-apple-system;text-align:center;padding:60px;background:#1a1a2e;color:white;">
            <h1>✅ PickShot 로그인 성공!</h1>
            <p>이 창을 닫고 PickShot으로 돌아가세요.</p>
            <script>setTimeout(function(){window.close()},2000);</script>
            </body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"

            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            self?.stop()
            DispatchQueue.main.async {
                self?.completion(code, nil)
            }
        }
    }
}

// MARK: - Google Drive Service
// Method 1: Local Google Drive folder copy (no API needed)
// Method 2: Google Drive REST API upload with share link

class GoogleDriveService {

    // MARK: - Method 1: Local Google Drive Folder

    /// Search for Google Drive for Desktop folder on this Mac
    static func findGoogleDriveFolder() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 1. ~/Library/CloudStorage/GoogleDrive-*/
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let contents = try? fm.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: nil) {
            for folder in contents {
                if folder.lastPathComponent.hasPrefix("GoogleDrive-") {
                    // Look for "My Drive" subfolder
                    let myDrive = folder.appendingPathComponent("My Drive")
                    if fm.fileExists(atPath: myDrive.path) {
                        return myDrive
                    }
                    // Some installs put it directly
                    return folder
                }
            }
        }

        // 2. ~/Google Drive/
        let googleDrive = home.appendingPathComponent("Google Drive")
        if fm.fileExists(atPath: googleDrive.path) {
            let myDrive = googleDrive.appendingPathComponent("My Drive")
            if fm.fileExists(atPath: myDrive.path) {
                return myDrive
            }
            return googleDrive
        }

        // 3. ~/Google Drive My Drive/
        let myDriveDirect = home.appendingPathComponent("Google Drive My Drive")
        if fm.fileExists(atPath: myDriveDirect.path) {
            return myDriveDirect
        }

        // 4. /Volumes/GoogleDrive/
        let volumeGD = URL(fileURLWithPath: "/Volumes/GoogleDrive")
        if fm.fileExists(atPath: volumeGD.path) {
            return volumeGD
        }

        return nil
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

    /// Upload a single file to Google Drive via REST API (multipart upload)
    /// - Parameters:
    ///   - fileURL: local file to upload
    ///   - folderId: optional Google Drive folder ID to upload into
    ///   - accessToken: OAuth2 Bearer token
    ///   - completion: (UploadResult?, Error?)
    static func uploadFile(
        fileURL: URL,
        folderId: String?,
        accessToken: String,
        completion: @escaping (UploadResult?, Error?) -> Void
    ) {
        guard let fileData = try? Data(contentsOf: fileURL) else {
            completion(nil, APIError(message: "파일을 읽을 수 없습니다: \(fileURL.lastPathComponent)"))
            return
        }

        let fileName = fileURL.lastPathComponent
        let mimeType = mimeTypeForExtension(fileURL.pathExtension)

        // Build metadata JSON
        var metadata: [String: Any] = ["name": fileName]
        if let folderId = folderId, !folderId.isEmpty {
            metadata["parents"] = [folderId]
        }
        fputs("[GDRIVE] upload \(fileName) → folder=\(folderId ?? "ROOT")\n", stderr)

        guard let metadataJSON = try? JSONSerialization.data(withJSONObject: metadata) else {
            completion(nil, APIError(message: "메타데이터 생성 실패"))
            return
        }

        // Build multipart/related body
        let boundary = "fastSelector_\(UUID().uuidString)"
        var body = Data()

        // Force unwraps are safe here: these ASCII-only strings always produce valid UTF-8
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataJSON)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        // Build request
        let urlString = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name"
        guard let url = URL(string: urlString) else {
            completion(nil, APIError(message: "잘못된 API URL"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }

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
        }.resume()
    }

    /// Create a public share link for a file on Google Drive
    /// - Parameters:
    ///   - fileId: Google Drive file ID
    ///   - accessToken: OAuth2 Bearer token
    ///   - completion: (shareLink: String?, Error?)
    static func createShareLink(
        fileId: String,
        accessToken: String,
        completion: @escaping (String?, Error?) -> Void
    ) {
        // Step 1: Create permission (anyone with link can view)
        guard let permURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)/permissions") else {
            completion(nil, APIError(message: "잘못된 permissions URL"))
            return
        }
        var permRequest = URLRequest(url: permURL)
        permRequest.httpMethod = "POST"
        permRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        permRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let permBody: [String: Any] = [
            "role": "reader",
            "type": "anyone"
        ]
        permRequest.httpBody = try? JSONSerialization.data(withJSONObject: permBody)

        URLSession.shared.dataTask(with: permRequest) { data, response, error in
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

            URLSession.shared.dataTask(with: fileRequest) { data, response, error in
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
            }.resume()
        }.resume()
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

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                fputs("[GDRIVE] createFolder HTTP \(httpResponse.statusCode)\n", stderr)
            }
            guard let data = data else {
                completion(nil, APIError(message: "응답 데이터 없음"))
                return
            }
            let responseStr = String(data: data, encoding: .utf8) ?? ""
            fputs("[GDRIVE] createFolder response: \(responseStr)\n", stderr)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folderId = json["id"] as? String else {
                completion(nil, APIError(message: "폴더 생성 실패: \(responseStr.prefix(200))"))
                return
            }

            completion(folderId, nil)
        }.resume()
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

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(false, error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 204 No Content = success, 404 = already deleted
            completion(status == 204 || status == 404, nil)
        }.resume()
    }

    // MARK: - OAuth 2.0

    // OAuth credentials loaded lazily (avoids keychain popup at app launch)
    static var oauthClientID: String {
        KeychainService.read(key: "gdrive_client_id") ?? ""
    }
    static var oauthClientSecret: String {
        KeychainService.read(key: "gdrive_client_secret") ?? ""
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

        let scopes = "https://www.googleapis.com/auth/drive.file"
        let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
            + "?client_id=\(oauthClientID)"
            + "&redirect_uri=\(oauthRedirectURI)"
            + "&response_type=code"
            + "&scope=\(scopes)"
            + "&access_type=offline"
            + "&prompt=consent"
            + "&code_challenge=\(codeChallenge)"
            + "&code_challenge_method=S256"

        // Start local HTTP server to receive callback
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

        // Open browser
        if let url = URL(string: authURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private static var localServer: LocalOAuthServer?

    private static func startLocalOAuthServer(completion: @escaping (String?, Error?) -> Void) {
        localServer = LocalOAuthServer(port: 8085, completion: completion)
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

        let body = "code=\(code)"
            + "&client_id=\(oauthClientID)"
            + "&client_secret=\(oauthClientSecret)"
            + "&redirect_uri=\(oauthRedirectURI)"
            + "&grant_type=authorization_code"
            + "&code_verifier=\(codeVerifier)"
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

            // Debug: print Google's response
            let responseStr = String(data: data, encoding: .utf8) ?? "unreadable"
            print("🔑 Token exchange response: \(responseStr)")

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, APIError(message: "토큰 교환: JSON 파싱 실패\n\(responseStr)"))
                return
            }

            if let errorMsg = json["error"] as? String {
                let desc = json["error_description"] as? String ?? ""
                print("🔑 Token error: \(errorMsg) - \(desc)")
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

    /// Refresh access token using saved refresh token
    static func refreshAccessToken(completion: @escaping (String?, Error?) -> Void) {
        guard let refreshToken = savedRefreshToken, !oauthClientID.isEmpty else {
            completion(nil, APIError(message: "리프레시 토큰이 없습니다. 다시 로그인해주세요."))
            return
        }

        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            completion(nil, APIError(message: "잘못된 token URL"))
            return
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "refresh_token=\(refreshToken)"
            + "&client_id=\(oauthClientID)"
            + "&client_secret=\(oauthClientSecret)"
            + "&grant_type=refresh_token"
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(nil, error)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                completion(nil, APIError(message: "토큰 갱신 실패"))
                return
            }
            savedAccessToken = accessToken
            completion(accessToken, nil)
        }.resume()
    }

    /// Logout - clear saved tokens
    static func logout() {
        savedAccessToken = nil
        savedRefreshToken = nil
    }

    // MARK: - Helpers

    private static func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "tiff", "tif": return "image/tiff"
        case "heic": return "image/heic"
        case "cr2": return "image/x-canon-cr2"
        case "cr3": return "image/x-canon-cr3"
        case "nef": return "image/x-nikon-nef"
        case "arw": return "image/x-sony-arw"
        case "raf": return "image/x-fuji-raf"
        case "dng": return "image/x-adobe-dng"
        case "orf": return "image/x-olympus-orf"
        case "rw2": return "image/x-panasonic-rw2"
        default: return "application/octet-stream"
        }
    }
}
