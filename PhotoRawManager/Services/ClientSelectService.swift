import Foundation
import AppKit
import CoreImage

// MARK: - Client Select Service
// 클라이언트 셀렉: 사진 리사이즈 → Google Drive 업로드 → QR/링크 생성
// 클라이언트는 웹 뷰어에서 사진 확인 + SP 셀렉 + 코멘트 + 펜 마크

class ClientSelectService: ObservableObject {
    static let shared = ClientSelectService()

    // 세션 상태
    @Published var isActive = false
    @Published var isUploading = false
    @Published var uploadDone = 0
    @Published var uploadTotal = 0
    @Published var uploadSpeed = ""
    @Published var sessionName = ""
    @Published var clientName = ""
    @Published var clientEmail = ""
    @Published var shareLink: String?
    @Published var viewerLink: String?
    // 원본 업로드 옵션
    var uploadOriginal = false
    var originalResolution = 2000
    var filePrefix = ""
    @Published var originalZipFileId: String?

    var viewerBaseURL: String {
        UserDefaults.standard.string(forKey: "clientSelectViewerURL")
            ?? "https://kimjjang869-bot.github.io/pickshot-viewer"
    }
    @Published var qrCodeImage: NSImage?
    @Published var driveFolderID: String?
    @Published var accessMode: AccessMode = .publicLink
    @Published var showSetup = false
    @Published var errorMessage: String?

    enum AccessMode: String, CaseIterable {
        case publicLink = "공개 링크"
        case emailRestricted = "이메일 제한"
    }

    private var cancelled = false
    private let uploadQueue = DispatchQueue(label: "com.pickshot.clientselect", qos: .userInitiated)
    private var uploadStartTime: Date?

    // MARK: - 세션 시작 요청

    func requestStart() {
        // Google 로그인 확인
        guard GoogleDriveService.isLoggedIn else {
            GSelectService.shared.loginToGoogle()
            return
        }
        showSetup = true
    }

    // MARK: - 세션 시작

    func startSession(name: String, client: String, email: String,
                      photos: [PhotoItem], accessMode: AccessMode) {
        fputs("[CLIENT] startSession: name=\(name), photos=\(photos.count)\n", stderr)

        // 토큰 갱신 시도 후 시작
        let sem = DispatchSemaphore(value: 0)
        var finalToken: String?

        if let token = GoogleDriveService.savedAccessToken {
            finalToken = token
            // 먼저 토큰 갱신 시도 (만료 대비)
            GoogleDriveService.refreshAccessToken { newToken, error in
                if let newToken = newToken {
                    fputs("[CLIENT] 토큰 갱신 성공\n", stderr)
                    finalToken = newToken
                } else {
                    fputs("[CLIENT] 토큰 갱신 실패 (기존 토큰 사용): \(error?.localizedDescription ?? "")\n", stderr)
                }
                sem.signal()
            }
            sem.wait()
        }

        guard let token = finalToken ?? GoogleDriveService.savedAccessToken else {
            fputs("[CLIENT] ❌ Google Drive 토큰 없음\n", stderr)
            errorMessage = "Google Drive 로그인이 필요합니다"
            return
        }
        fputs("[CLIENT] 토큰 준비: \(token.prefix(10))...\n", stderr)

        // 상태 초기화
        sessionName = name
        clientName = client
        clientEmail = email
        self.accessMode = accessMode
        uploadDone = 0
        uploadTotal = photos.count
        isUploading = true
        isActive = true
        cancelled = false
        shareLink = nil
        viewerLink = nil
        qrCodeImage = nil
        driveFolderID = nil
        errorMessage = nil
        uploadStartTime = Date()
        showSetup = false

        // 백그라운드에서 전체 워크플로우 실행
        uploadQueue.async { [weak self] in
            self?.executeUploadWorkflow(token: token, photos: photos)
        }
    }

    // MARK: - 업로드 취소

    func cancelUpload() {
        cancelled = true
        DispatchQueue.main.async { [weak self] in
            self?.isUploading = false
            self?.uploadSpeed = "취소됨"
        }
    }

    // MARK: - 업로드 워크플로우

    private func executeUploadWorkflow(token: String, photos: [PhotoItem]) {
        // 1. Google Drive 폴더 생성
        let folderSemaphore = DispatchSemaphore(value: 0)
        var folderId: String?

        fputs("[CLIENT] 폴더 생성 시도: \(sessionName)\n", stderr)
        GoogleDriveService.createFolder(name: sessionName, accessToken: token) { id, error in
            folderId = id
            if let error = error {
                fputs("[CLIENT] ❌ 폴더 생성 실패: \(error.localizedDescription)\n", stderr)
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = "폴더 생성 실패: \(error.localizedDescription)"
                    self?.isUploading = false
                }
            } else {
                fputs("[CLIENT] ✅ 폴더 생성: \(id ?? "nil")\n", stderr)
            }
            folderSemaphore.signal()
        }
        folderSemaphore.wait()

        guard let folderID = folderId, !cancelled else {
            fputs("[CLIENT] ❌ 폴더 ID 없음 또는 취소됨\n", stderr)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.driveFolderID = folderID
        }

        // 2. 권한 설정
        setFolderPermissions(folderId: folderID, token: token)

        guard !cancelled else { return }

        // 3. 사진 리사이즈 + 업로드
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pickshot_clientselect_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var uploadedFiles: [[String: Any]] = []

        for (index, photo) in photos.enumerated() {
            guard !cancelled else { break }

            // 리사이즈 (1200px max, JPEG 0.8)
            guard let resizedURL = resizePhoto(photo: photo, index: index, tempDir: tempDir) else {
                continue
            }

            // 업로드
            let uploadSemaphore = DispatchSemaphore(value: 0)

            GoogleDriveService.uploadFile(fileURL: resizedURL, folderId: folderID, accessToken: token) { [weak self] result, error in
                if let result = result {
                    let info: [String: Any] = [
                        "index": index + 1,
                        "filename": resizedURL.lastPathComponent,
                        "originalFilename": photo.jpgURL.lastPathComponent,
                        "driveFileId": result.fileId
                    ]
                    uploadedFiles.append(info)
                }
                uploadSemaphore.signal()
            }
            uploadSemaphore.wait()

            // 진행률 업데이트
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.uploadDone = index + 1
                // 업로드 속도 계산
                if let start = self.uploadStartTime {
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed > 0 {
                        let photosPerSec = Double(self.uploadDone) / elapsed
                        let remaining = Double(self.uploadTotal - self.uploadDone) / max(photosPerSec, 0.01)
                        if remaining < 60 {
                            self.uploadSpeed = String(format: "%.0f초 남음", remaining)
                        } else {
                            self.uploadSpeed = String(format: "%.0f분 남음", remaining / 60)
                        }
                    }
                }
            }
        }

        // 임시 폴더 정리
        try? FileManager.default.removeItem(at: tempDir)

        guard !cancelled else { return }

        // 3.5. 원본 파일 ZIP 업로드 (옵션)
        if uploadOriginal && !cancelled {
            fputs("[CLIENT] 원본 ZIP 생성 중 (\(originalResolution)px)...\n", stderr)
            DispatchQueue.main.async { [weak self] in
                self?.uploadSpeed = "원본 ZIP 생성 중..."
            }
            if let zipId = createAndUploadOriginalZip(photos: photos, folderId: folderID, token: token, tempDir: tempDir) {
                DispatchQueue.main.async { [weak self] in
                    self?.originalZipFileId = zipId
                }
            }
        }

        // 4. manifest.json 생성 + 업로드
        let manifestId = uploadManifest(photos: uploadedFiles, folderId: folderID, token: token)

        // 5. 링크 생성
        let linkSemaphore = DispatchSemaphore(value: 0)
        GoogleDriveService.createShareLink(fileId: folderID, accessToken: token) { [weak self] link, _ in
            DispatchQueue.main.async {
                self?.shareLink = link

                // 웹 뷰어 링크 생성
                let encodedName = self?.sessionName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let encodedClient = self?.clientName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                // manifest를 Base64로 인코딩해서 URL 해시에 포함 (CORS 문제 완전 회피)
                var viewerURL = "\(self?.viewerBaseURL ?? "https://kimjjang869-bot.github.io/pickshot-viewer")/?session=\(folderID)&name=\(encodedName)&client=\(encodedClient)"
                if let mid = manifestId {
                    viewerURL += "&manifest=\(mid)"
                }
                // manifest를 GitHub Pages에 업로드 (CORS 없음 + 짧은 URL)
                let sid = String(folderID.prefix(12))
                if let manifestData = self?.getManifestJSON(photos: uploadedFiles) {
                    self?.uploadManifestToGitHub(sessionId: sid, data: manifestData)
                }
                viewerURL += "&mid=\(sid)"
                self?.viewerLink = viewerURL

                // QR 코드 생성
                self?.qrCodeImage = self?.generateQRCode(from: viewerURL)
            }
            linkSemaphore.signal()
        }
        linkSemaphore.wait()

        // 완료 → 결과 창 자동 열기
        DispatchQueue.main.async { [weak self] in
            self?.isUploading = false
            self?.uploadSpeed = "완료"
            self?.showSetup = true  // 완료 창 자동 표시
            fputs("[CLIENT] ✅ 업로드 완료: \(self?.uploadDone ?? 0)장, 링크: \(self?.viewerLink ?? "없음")\n", stderr)
        }
    }

    // MARK: - 사진 리사이즈

    private func resizePhoto(photo: PhotoItem, index: Int, tempDir: URL) -> URL? {
        let sourceURL = photo.jpgURL

        // CGImageSource로 빠른 리사이즈 (전체 RAW 디코딩 불필요)
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 1200,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }

        // 파일명: 접두어 있으면 "접두어_0001.jpg", 없으면 "0001_원본이름.jpg"
        let fileName: String
        if !filePrefix.isEmpty {
            fileName = String(format: "%@_%04d.jpg", filePrefix, index + 1)
        } else {
            fileName = String(format: "%04d_%@.jpg", index + 1, sourceURL.deletingPathExtension().lastPathComponent)
        }
        let destURL = tempDir.appendingPathComponent(fileName)

        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return nil }

        let jpegOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ]
        CGImageDestinationAddImage(dest, thumbnail, jpegOptions as CFDictionary)

        guard CGImageDestinationFinalize(dest) else { return nil }

        return destURL
    }

    // MARK: - 권한 설정

    private func setFolderPermissions(folderId: String, token: String) {
        switch accessMode {
        case .publicLink:
            // 누구나 접근 가능 — 폴더에 공개 읽기 권한 설정
            guard let permURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(folderId)/permissions") else { return }
            var pubReq = URLRequest(url: permURL)
            pubReq.httpMethod = "POST"
            pubReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            pubReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let pubBody: [String: Any] = ["role": "reader", "type": "anyone"]
            pubReq.httpBody = try? JSONSerialization.data(withJSONObject: pubBody)
            let pubSem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: pubReq) { data, response, _ in
                if let http = response as? HTTPURLResponse {
                    fputs("[CLIENT] 공개 권한 설정: HTTP \(http.statusCode)\n", stderr)
                }
                pubSem.signal()
            }.resume()
            pubSem.wait()
        case .emailRestricted:
            guard !clientEmail.isEmpty else { return }
            // 특정 이메일만 접근 가능
            guard let permURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(folderId)/permissions") else { return }
            var request = URLRequest(url: permURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let permBody: [String: Any] = [
                "role": "reader",
                "type": "user",
                "emailAddress": clientEmail
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: permBody)

            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { _, _, _ in
                sem.signal()
            }.resume()
            sem.wait()
        }
    }

    private func getManifestJSON(photos: [[String: Any]]) -> Data? {
        let manifest: [String: Any] = [
            "sessionName": sessionName,
            "clientName": clientName,
            "totalPhotos": photos.count,
            "originalZipFileId": originalZipFileId ?? "",
            "photos": photos.map { info -> [String: Any] in
                let fid = info["driveFileId"] as? String ?? ""
                return [
                    "filename": info["filename"] ?? "",
                    "originalFilename": info["originalFilename"] ?? "",
                    "driveFileId": fid,
                    "thumbUrl": "https://drive.google.com/thumbnail?id=\(fid)&sz=w200",
                    "fullUrl": "https://drive.google.com/thumbnail?id=\(fid)&sz=w1200"
                ]
            }
        ]
        return try? JSONSerialization.data(withJSONObject: manifest)
    }

    // MARK: - GitHub Pages에 manifest 업로드

    private func uploadManifestToGitHub(sessionId: String, data: Data) {
        // macOS Keychain에서 GitHub 토큰
        let ghToken: String? = {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            proc.arguments = ["find-internet-password", "-s", "github.com", "-w"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        guard let ghToken = ghToken, !ghToken.isEmpty else {
            fputs("[CLIENT] GitHub 토큰 없음 — manifest GitHub 업로드 스킵\n", stderr)
            return
        }

        let b64Content = data.base64EncodedString()
        let apiURL = URL(string: "https://api.github.com/repos/kimjjang869-bot/pickshot-viewer/contents/data/\(sessionId).json")!

        var request = URLRequest(url: apiURL)
        request.httpMethod = "PUT"
        request.setValue("token \(ghToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "message": "Add manifest \(sessionId)",
            "content": b64Content
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                fputs("[CLIENT] GitHub manifest 업로드: HTTP \(http.statusCode)\n", stderr)
            }
            sem.signal()
        }.resume()
        sem.wait()
    }

    // MARK: - URL 단축 (is.gd)

    private func shortenURL(_ longURL: String) -> String {
        guard let encoded = longURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let apiURL = URL(string: "https://is.gd/create.php?format=simple&url=\(encoded)") else {
            return longURL
        }
        let sem = DispatchSemaphore(value: 0)
        var shortURL = longURL
        URLSession.shared.dataTask(with: apiURL) { data, _, _ in
            if let data = data, let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               result.hasPrefix("https://") {
                shortURL = result
                fputs("[CLIENT] URL 단축: \(result)\n", stderr)
            } else {
                fputs("[CLIENT] URL 단축 실패, 원본 사용\n", stderr)
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return shortURL
    }

    // MARK: - Manifest 업로드

    @discardableResult
    private func uploadManifest(photos: [[String: Any]], folderId: String, token: String) -> String? {
        var manifestFileId: String?
        let manifest: [String: Any] = [
            "version": "1.0",
            "sessionName": sessionName,
            "clientName": clientName,
            "clientEmail": clientEmail,
            "originalZipFileId": originalZipFileId ?? "",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "totalPhotos": uploadTotal,
            "driveFolder": folderId,
            "photos": photos.map { info -> [String: Any] in
                let fileId = info["driveFileId"] as? String ?? ""
                return [
                    "index": info["index"] ?? 0,
                    "filename": info["filename"] ?? "",
                    "originalFilename": info["originalFilename"] ?? "",
                    "driveFileId": fileId,
                    "thumbUrl": "https://drive.google.com/thumbnail?id=\(fileId)&sz=w300",
                    "fullUrl": "https://drive.google.com/thumbnail?id=\(fileId)&sz=w1200",
                    "selected": false,
                    "comments": [] as [Any],
                    "annotations": [] as [Any]
                ]
            }
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) else { return nil }

        // 임시 파일로 저장 후 업로드
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("manifest.json")
        try? jsonData.write(to: tempURL)

        let sem = DispatchSemaphore(value: 0)
        GoogleDriveService.uploadFile(fileURL: tempURL, folderId: folderId, accessToken: token) { result, _ in
            manifestFileId = result?.fileId
            sem.signal()
        }
        sem.wait()

        try? FileManager.default.removeItem(at: tempURL)

        // manifest 파일도 공개 권한 설정 (웹 뷰어에서 CORS 없이 접근 가능)
        if let fileId = manifestFileId {
            let permURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)/permissions")!
            var permReq = URLRequest(url: permURL)
            permReq.httpMethod = "POST"
            permReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            permReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            permReq.httpBody = try? JSONSerialization.data(withJSONObject: ["role": "reader", "type": "anyone"])
            let permSem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: permReq) { _, resp, _ in
                if let http = resp as? HTTPURLResponse {
                    fputs("[CLIENT] manifest 공개 권한: HTTP \(http.statusCode)\n", stderr)
                }
                permSem.signal()
            }.resume()
            permSem.wait()
        }

        fputs("[CLIENT] manifest 업로드: \(manifestFileId ?? "실패")\n", stderr)
        return manifestFileId
    }

    // MARK: - 원본 ZIP 생성 + 업로드

    private func createAndUploadOriginalZip(photos: [PhotoItem], folderId: String, token: String, tempDir: URL) -> String? {
        let zipDir = tempDir.appendingPathComponent("originals")
        try? FileManager.default.createDirectory(at: zipDir, withIntermediateDirectories: true)

        // 사진 리사이즈 (원본 해상도)
        for (index, photo) in photos.enumerated() {
            guard !cancelled else { break }
            autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(photo.jpgURL as CFURL, nil) else { return }
                let opts: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: originalResolution,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return }

                let name: String
                if !filePrefix.isEmpty {
                    name = String(format: "%@_%04d.jpg", filePrefix, index + 1)
                } else {
                    name = String(format: "%04d_%@.jpg", index + 1, photo.jpgURL.deletingPathExtension().lastPathComponent)
                }
                let destURL = zipDir.appendingPathComponent(name)
                guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
        }

        // ZIP 압축
        let zipName = "\(sessionName)_원본.zip"
        let zipURL = tempDir.appendingPathComponent(zipName)
        let coordinator = NSFileCoordinator()
        var zipError: NSError?

        coordinator.coordinate(readingItemAt: zipDir, options: .forUploading, error: &zipError) { zipTempURL in
            try? FileManager.default.moveItem(at: zipTempURL, to: zipURL)
        }

        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            fputs("[CLIENT] ❌ ZIP 생성 실패\n", stderr)
            return nil
        }

        let zipSize = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int64) ?? 0
        fputs("[CLIENT] ZIP 생성: \(zipName) (\(zipSize / 1024 / 1024)MB)\n", stderr)

        // 업로드
        DispatchQueue.main.async { [weak self] in
            self?.uploadSpeed = "원본 ZIP 업로드 중..."
        }

        var fileId: String?
        let sem = DispatchSemaphore(value: 0)
        GoogleDriveService.uploadFile(fileURL: zipURL, folderId: folderId, accessToken: token) { result, error in
            fileId = result?.fileId
            if let error = error {
                fputs("[CLIENT] ❌ ZIP 업로드 실패: \(error.localizedDescription)\n", stderr)
            } else {
                fputs("[CLIENT] ✅ ZIP 업로드: \(fileId ?? "")\n", stderr)
            }
            sem.signal()
        }
        sem.wait()

        // 정리
        try? FileManager.default.removeItem(at: zipDir)
        try? FileManager.default.removeItem(at: zipURL)

        return fileId
    }

    // MARK: - .pickshot 파일 가져오기

    struct PickshotResult {
        var sessionName: String
        var clientName: String
        var totalPhotos: Int
        var selectedCount: Int
        var matchedPhotos: [(filename: String, originalFilename: String, selected: Bool, comments: [String])]
        var unmatchedCount: Int
    }

    func importPickshotFile(url: URL, matchFolder: URL) -> PickshotResult? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let session = json["sessionName"] as? String ?? ""
        let client = json["clientName"] as? String ?? ""
        let total = json["totalPhotos"] as? Int ?? 0

        guard let photosArray = json["photos"] as? [[String: Any]] else { return nil }

        // 매칭 폴더의 파일 목록
        let fm = FileManager.default
        let localFiles = (try? fm.contentsOfDirectory(at: matchFolder, includingPropertiesForKeys: nil))?.map { $0.lastPathComponent.lowercased() } ?? []
        let localFileSet = Set(localFiles)

        var matched: [(String, String, Bool, [String])] = []
        var unmatchedCount = 0
        var selectedCount = 0

        for photoInfo in photosArray {
            let filename = photoInfo["filename"] as? String ?? ""
            let originalFilename = photoInfo["originalFilename"] as? String ?? ""
            let selected = photoInfo["selected"] as? Bool ?? false

            // 코멘트 추출
            var comments: [String] = []
            if let commentArray = photoInfo["comments"] as? [[String: Any]] {
                comments = commentArray.compactMap { $0["text"] as? String }
            }

            if selected { selectedCount += 1 }

            // 원본 파일명으로 매칭 (확장자 무시)
            let baseName = (originalFilename as NSString).deletingPathExtension.lowercased()
            let hasMatch = localFiles.contains(where: { ($0 as NSString).deletingPathExtension.lowercased() == baseName })

            if hasMatch {
                matched.append((filename, originalFilename, selected, comments))
            } else {
                unmatchedCount += 1
            }
        }

        return PickshotResult(
            sessionName: session,
            clientName: client,
            totalPhotos: total,
            selectedCount: selectedCount,
            matchedPhotos: matched,
            unmatchedCount: unmatchedCount
        )
    }

    // MARK: - QR 코드 생성

    func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter?.outputImage else { return nil }

        // 스케일 업 (QR 코드가 작으므로)
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: scale)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)

        return nsImage
    }

    // MARK: - 링크 복사

    func copyLink() {
        guard let link = viewerLink ?? shareLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    // MARK: - QR 코드 저장

    func saveQRCode() {
        guard let image = qrCodeImage else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sessionName)_QR.png"
        panel.allowedContentTypes = [.png]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        try? pngData.write(to: url)
    }
}
