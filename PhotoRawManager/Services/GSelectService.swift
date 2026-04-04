import Foundation
import AppKit

// MARK: - G Select Service
// G키로 사진 선택 → Google Drive API로 즉시 업로드
// 다시 G키 → Google Drive에서 즉시 삭제
// 클라이언트는 공유 링크로 실시간 확인

class GSelectService: ObservableObject {
    static let shared = GSelectService()

    // Session state
    @Published var isActive: Bool = false
    @Published var gSelectedIDs: Set<UUID> = []
    @Published var uploadedCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var currentlyUploading: UUID? = nil
    @Published var shareLink: String? = nil
    @Published var viewerLink: String? = nil  // Client web viewer link
    @Published var sessionFolderName: String = ""
    @Published var showSetupSheet: Bool = false

    // Google Drive
    @Published var isLoggedIn: Bool = false  // Updated lazily to avoid keychain popup at launch
    @Published var driveFolderID: String? = nil
    @Published var uploadType: GSelectUploadType = .both
    @Published var pendingUploads: Int = 0  // uploads in progress

    // File ID mapping (photoID → driveFileID) for deletion
    private var uploadedFileIDs: [UUID: [String]] = [:]  // photoID → [jpgFileID, rawFileID]

    private let uploadQueue = DispatchQueue(label: "com.pickshot.gselect.upload", qos: .userInitiated)

    // MARK: - Login

    func loginToGoogle() {
        GoogleDriveService.startOAuthLogin { [weak self] token, error in
            DispatchQueue.main.async {
                if let _ = token {
                    self?.isLoggedIn = true
                } else if let error = error {
                    let alert = NSAlert()
                    alert.messageText = "Google 로그인 실패"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    func logout() {
        GoogleDriveService.logout()
        isLoggedIn = false
    }

    // MARK: - Session Setup

    /// Show setup sheet before starting G Select
    func requestStartSession() {
        // Refresh login state (lazy — avoids keychain at launch)
        isLoggedIn = GoogleDriveService.isLoggedIn
        if !isLoggedIn {
            loginToGoogle()
            return
        }
        showSetupSheet = true
    }

    /// Actually start the session with a folder name
    func startSession(folderName: String, uploadType: GSelectUploadType = .both) {
        guard let token = GoogleDriveService.savedAccessToken else { return }

        sessionFolderName = folderName
        self.uploadType = uploadType
        gSelectedIDs = []
        uploadedCount = 0
        failedCount = 0
        pendingUploads = 0
        uploadedFileIDs = [:]
        shareLink = nil

        // Create folder on Google Drive
        GoogleDriveService.createFolder(name: folderName, accessToken: token) { [weak self] folderId, error in
            DispatchQueue.main.async {
                if let folderId = folderId {
                    self?.driveFolderID = folderId
                    self?.isActive = true
                    self?.showSetupSheet = false

                    // Create share link for the folder
                    GoogleDriveService.createShareLink(fileId: folderId, accessToken: token) { link, _ in
                        DispatchQueue.main.async {
                            self?.shareLink = link
                            // Generate client web viewer link
                            if let token = GoogleDriveService.savedAccessToken {
                                let name = folderName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? folderName
                                self?.viewerLink = "https://kimjjang869-bot.github.io/pickshot-viewer/?folder=\(folderId)&token=\(token)&name=\(name)"
                            }
                        }
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "폴더 생성 실패"
                    alert.informativeText = error?.localizedDescription ?? "알 수 없는 오류"
                    alert.runModal()
                }
            }
        }
    }

    /// End session - with warning if uploads pending
    func endSession() {
        // Check if uploads are in progress
        if pendingUploads > 0 {
            let warning = NSAlert()
            warning.messageText = "업로드가 진행 중입니다"
            warning.informativeText = """
            현재 \(pendingUploads)개 파일이 업로드 중입니다.
            \(uploadedCount)/\(gSelectedIDs.count)장 완료됨.

            지금 종료하면 업로드 중인 파일이 중단됩니다.
            정말 종료하시겠습니까?
            """
            warning.alertStyle = .warning
            warning.addButton(withTitle: "계속 업로드")
            warning.addButton(withTitle: "종료")
            let response = warning.runModal()
            if response == .alertFirstButtonReturn {
                return  // Don't end session
            }
        }

        isActive = false

        // Copy share link to clipboard
        if let link = shareLink {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }

        // Show summary
        let alert = NSAlert()
        alert.messageText = "G셀렉 완료"
        alert.informativeText = """
        📂 \(sessionFolderName)
        📷 \(uploadedCount)/\(gSelectedIDs.count)장 업로드 완료
        \(failedCount > 0 ? "⚠️ \(failedCount)개 실패" : "")

        \(shareLink != nil ? "🔗 공유 링크가 클립보드에 복사되었습니다.\n클라이언트에게 전달해주세요." : "")
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        if shareLink != nil {
            alert.addButton(withTitle: "링크 열기")
        }
        let response = alert.runModal()
        if response == .alertSecondButtonReturn, let link = shareLink, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Toggle G Select

    func toggleGSelect(photo: PhotoItem) {
        guard isActive, let token = GoogleDriveService.savedAccessToken, let folderId = driveFolderID else { return }

        if gSelectedIDs.contains(photo.id) {
            // Deselect → delete from Google Drive
            gSelectedIDs.remove(photo.id)
            deleteFromDrive(photoID: photo.id, token: token)
        } else {
            // Select → upload to Google Drive
            gSelectedIDs.insert(photo.id)
            uploadToDrive(photo: photo, folderId: folderId, token: token)
        }
    }

    func gSelectMultiple(photos: [PhotoItem]) {
        guard isActive, let token = GoogleDriveService.savedAccessToken, let folderId = driveFolderID else { return }

        for photo in photos where !gSelectedIDs.contains(photo.id) {
            gSelectedIDs.insert(photo.id)
            uploadToDrive(photo: photo, folderId: folderId, token: token)
        }
    }

    // MARK: - Upload / Delete

    private func uploadToDrive(photo: PhotoItem, folderId: String, token: String) {
        DispatchQueue.main.async { [weak self] in
            self?.currentlyUploading = photo.id
            self?.pendingUploads += 1
        }

        let shouldUploadJPG = uploadType == .both || uploadType == .jpgOnly
        let shouldUploadRAW = (uploadType == .both || uploadType == .rawOnly) && photo.rawURL != nil

        // Upload JPG
        if shouldUploadJPG {
            GoogleDriveService.uploadFile(fileURL: photo.jpgURL, folderId: folderId, accessToken: token) { [weak self] result, error in
                DispatchQueue.main.async {
                    if let result = result {
                        self?.uploadedFileIDs[photo.id, default: []].append(result.fileId)
                        self?.uploadedCount += 1
                    } else {
                        self?.failedCount += 1
                        print("G Select upload failed: \(error?.localizedDescription ?? "unknown")")
                    }
                    guard let self = self else { return }
                    self.pendingUploads = max(0, self.pendingUploads - 1)
                    if self.pendingUploads == 0 { self.currentlyUploading = nil }
                }
            }
        }

        // Upload RAW
        if shouldUploadRAW, let rawURL = photo.rawURL {
            DispatchQueue.main.async { [weak self] in self?.pendingUploads += 1 }
            GoogleDriveService.uploadFile(fileURL: rawURL, folderId: folderId, accessToken: token) { [weak self] result, error in
                DispatchQueue.main.async {
                    if let result = result {
                        self?.uploadedFileIDs[photo.id, default: []].append(result.fileId)
                    } else {
                        self?.failedCount += 1
                    }
                    guard let self = self else { return }
                    self.pendingUploads = max(0, self.pendingUploads - 1)
                    if self.pendingUploads == 0 { self.currentlyUploading = nil }
                }
            }
        }

        // If nothing to upload (e.g., rawOnly but no raw file)
        if !shouldUploadJPG && !shouldUploadRAW {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pendingUploads = max(0, self.pendingUploads - 1)
                self.currentlyUploading = nil
            }
        }
    }

    private func deleteFromDrive(photoID: UUID, token: String) {
        guard let fileIDs = uploadedFileIDs[photoID] else { return }

        for fileId in fileIDs {
            GoogleDriveService.deleteFile(fileId: fileId, accessToken: token) { [weak self] success, _ in
                if success {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.uploadedCount = max(0, self.uploadedCount - 1)
                    }
                }
            }
        }
        uploadedFileIDs.removeValue(forKey: photoID)
    }

    // MARK: - Status

    var statusText: String {
        if !isActive { return "" }
        if let _ = currentlyUploading {
            return "G셀렉 ↑업로드 중... (\(gSelectedIDs.count)장)"
        }
        return "G셀렉 \(gSelectedIDs.count)장"
    }

    // MARK: - Local fallback (Google Drive app installed)

    var hasLocalGoogleDrive: Bool {
        GoogleDriveService.findGoogleDriveFolder() != nil
    }
}
