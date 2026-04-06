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
        guard let token = GoogleDriveService.savedAccessToken else {
            errorMessage = "Google Drive 로그인이 필요합니다"
            return
        }

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

        GoogleDriveService.createFolder(name: sessionName, accessToken: token) { id, error in
            folderId = id
            if let error = error {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = "폴더 생성 실패: \(error.localizedDescription)"
                    self?.isUploading = false
                }
            }
            folderSemaphore.signal()
        }
        folderSemaphore.wait()

        guard let folderID = folderId, !cancelled else { return }

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

        // 4. manifest.json 생성 + 업로드
        uploadManifest(photos: uploadedFiles, folderId: folderID, token: token)

        // 5. 링크 생성
        let linkSemaphore = DispatchSemaphore(value: 0)
        GoogleDriveService.createShareLink(fileId: folderID, accessToken: token) { [weak self] link, _ in
            DispatchQueue.main.async {
                self?.shareLink = link

                // 웹 뷰어 링크 생성
                let encodedName = self?.sessionName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let encodedClient = self?.clientName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                self?.viewerLink = "https://kimjjang869-bot.github.io/pickshot-viewer/?session=\(folderID)&name=\(encodedName)&client=\(encodedClient)"

                // QR 코드 생성
                if let viewerLink = self?.viewerLink {
                    self?.qrCodeImage = self?.generateQRCode(from: viewerLink)
                }
            }
            linkSemaphore.signal()
        }
        linkSemaphore.wait()

        // 완료
        DispatchQueue.main.async { [weak self] in
            self?.isUploading = false
            self?.uploadSpeed = "완료"
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

        // JPEG 0.8 품질로 저장
        let fileName = String(format: "%04d_%@.jpg", index + 1, sourceURL.deletingPathExtension().lastPathComponent)
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
            // 누구나 접근 가능 (GoogleDriveService.createShareLink에서 처리)
            break
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

    // MARK: - Manifest 업로드

    private func uploadManifest(photos: [[String: Any]], folderId: String, token: String) {
        let manifest: [String: Any] = [
            "version": "1.0",
            "sessionName": sessionName,
            "clientName": clientName,
            "clientEmail": clientEmail,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "totalPhotos": uploadTotal,
            "driveFolder": folderId,
            "photos": photos.map { info -> [String: Any] in
                [
                    "index": info["index"] ?? 0,
                    "filename": info["filename"] ?? "",
                    "originalFilename": info["originalFilename"] ?? "",
                    "selected": false,
                    "comments": [] as [Any],
                    "annotations": [] as [Any]
                ]
            }
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) else { return }

        // 임시 파일로 저장 후 업로드
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("manifest.json")
        try? jsonData.write(to: tempURL)

        let sem = DispatchSemaphore(value: 0)
        GoogleDriveService.uploadFile(fileURL: tempURL, folderId: folderId, accessToken: token) { _, _ in
            sem.signal()
        }
        sem.wait()

        try? FileManager.default.removeItem(at: tempURL)
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
