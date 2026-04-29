import Foundation
import AppKit
import CoreImage
import Compression

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
    /// 고객 최대 선택 가능 수 (0 = 무제한). 업로드 시 manifest에 포함되어 뷰어에서 하드캡 적용.
    @Published var selectionLimit: Int = 0
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

    /// 기본 Cloudflare Worker 프록시 (PickShot 개발자가 운영 — 사용자 설정 불필요).
    /// 이 URL 은 항상 살아 있도록 유지. 무료 tier 10만 req/day.
    static let defaultCloudflareProxyURL = "https://pickshot-proxy.kimjjang8699.workers.dev"

    /// 사용자 커스텀 프록시 URL (고급 사용자 전용. 빈 값이면 위 기본 사용).
    /// UserDefaults 키는 구 Apps Script 시절 이름 유지 — 기존 설정 호환용.
    var customProxyURL: String {
        get { UserDefaults.standard.string(forKey: "cs_appsScriptProxyURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cs_appsScriptProxyURL") }
    }

    /// 실제 사용될 프록시 URL — 커스텀이 있으면 커스텀, 없으면 기본 CF Worker.
    var effectiveProxyURL: String {
        let custom = customProxyURL.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? Self.defaultCloudflareProxyURL : custom
    }

    /// 하위 호환 — 기존 코드가 `appsScriptProxyURL` 참조할 때 effectiveProxyURL 반환.
    var appsScriptProxyURL: String {
        get { effectiveProxyURL }
        set { customProxyURL = newValue }
    }

    /// URL embed 로 충분한 사진 수 임계값.
    /// 이 수 이하는 `&g=` 로 매니페스트를 URL 에 내장 (Worker 요청 0회, is.gd 단축 OK).
    /// 초과하면 Worker 프록시 사용 (manifest 를 Drive 에 업로드 후 중계).
    static let urlEmbedPhotoThreshold = 500
    @Published var qrCodeImage: NSImage?
    @Published var driveFolderID: String?
    @Published var accessMode: AccessMode = .publicLink
    @Published var showSetup = false
    @Published var showSessionList = false
    @Published var showProxySetup = false
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
        // 이전 세션 결과 화면 초기화 — 새 폴더/세션 시작 시 입력 화면으로 복귀
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.viewerLink = nil
            self.shareLink = nil
            self.qrCodeImage = nil
            self.driveFolderID = nil
            self.uploadDone = 0
            self.uploadTotal = 0
            self.isUploading = false
            self.errorMessage = nil
            self.showSetup = true
        }
    }

    /// 완료 화면에서 "새 세션 시작" 누를 때 — 결과 상태 클리어 후 입력 화면으로.
    func resetForNewSession() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.viewerLink = nil
            self.shareLink = nil
            self.qrCodeImage = nil
            self.driveFolderID = nil
            self.uploadDone = 0
            self.uploadTotal = 0
            self.sessionName = ""
            self.clientName = ""
            self.clientEmail = ""
            self.isUploading = false
            self.errorMessage = nil
        }
    }

    // MARK: - 세션 시작

    func startSession(name: String, client: String, email: String,
                      photos: [PhotoItem], accessMode: AccessMode) {
        fputs("[CLIENT] startSession: name=\(name), photos=\(photos.count)\n", stderr)

        // 토큰 확보 (비동기 — 메인스레드 블로킹 없음)
        resolveToken { [weak self] token in
            guard let self = self, let token = token else {
                DispatchQueue.main.async {
                    self?.errorMessage = "Google Drive 로그인이 필요합니다.\n설정에서 Google 로그인을 해주세요."
                    self?.isUploading = false
                }
                return
            }
            fputs("[CLIENT] 토큰 준비: \(token.prefix(10))...\n", stderr)
            self.continueSession(token: token, name: name, client: client, email: email, photos: photos, accessMode: accessMode)
        }
    }

    /// 토큰 확보: 리프레시 → 실패 시 재로그인 (메인스레드 안 막음)
    private func resolveToken(completion: @escaping (String?) -> Void) {
        if GoogleDriveService.savedAccessToken != nil {
            GoogleDriveService.refreshAccessToken { newToken, error in
                if let newToken = newToken {
                    fputs("[CLIENT] 토큰 갱신 성공\n", stderr)
                    completion(newToken)
                } else {
                    fputs("[CLIENT] 토큰 갱신 실패 — 재로그인\n", stderr)
                    GoogleDriveService.startOAuthLogin { token, _ in
                        fputs("[CLIENT] 재로그인: \(token != nil ? "성공" : "실패")\n", stderr)
                        completion(token)
                    }
                }
            }
        } else {
            GoogleDriveService.startOAuthLogin { token, _ in
                fputs("[CLIENT] 새 로그인: \(token != nil ? "성공" : "실패")\n", stderr)
                completion(token)
            }
        }
    }

    private func continueSession(token: String, name: String, client: String, email: String,
                                  photos: [PhotoItem], accessMode: AccessMode) {
        fputs("[CLIENT] continueSession with token\n", stderr)

        // 상태 초기화 — 반드시 메인스레드에서 @Published 변경
        let ensureMain = { [weak self] in
            guard let self = self else { return }
            self.sessionName = name
            self.clientName = client
            self.clientEmail = email
            self.accessMode = accessMode
            self.uploadDone = 0
            self.uploadTotal = photos.count
            self.isUploading = true
            self.isActive = true
            self.cancelled = false
            self.shareLink = nil
            self.viewerLink = nil
            self.qrCodeImage = nil
            self.driveFolderID = nil
            self.errorMessage = nil
            self.uploadStartTime = Date()
            self.showSetup = false
        }
        if Thread.isMainThread { ensureMain() }
        else { DispatchQueue.main.sync { ensureMain() } }

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
        fputs("[CLIENT] executeUploadWorkflow: \(photos.count)장, token=\(token.prefix(10))...\n", stderr)
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

        // 3. 중복 체크 — 기존 파일 목록 조회
        var existingFileNames: Set<String> = []
        let listSemaphore = DispatchSemaphore(value: 0)
        GoogleDriveService.listFiles(folderId: folderID, accessToken: token) { names, _ in
            existingFileNames = Set(names)
            listSemaphore.signal()
        }
        listSemaphore.wait()

        // 중복 제거
        let originalCount = photos.count
        let filteredPhotos = photos.filter { !existingFileNames.contains($0.jpgURL.lastPathComponent) }
        let skippedCount = originalCount - filteredPhotos.count
        if skippedCount > 0 {
            fputs("[CLIENT] 중복 건너뛰기: \(skippedCount)장 (기존 파일과 동일 이름)\n", stderr)
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "\(skippedCount)장 중복 건너뛰기"
            }
        }

        let photosToUpload = filteredPhotos
        guard !photosToUpload.isEmpty else {
            fputs("[CLIENT] 업로드할 새 파일 없음 (전부 중복)\n", stderr)
            DispatchQueue.main.async { [weak self] in
                self?.isUploading = false
                self?.errorMessage = "업로드할 새 파일 없음 (\(skippedCount)장 이미 존재)"
            }
            return
        }

        // 4. 사진 리사이즈 + 업로드
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pickshot_clientselect_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var uploadedFiles: [[String: Any]] = []
        var uploadedBytes: Int64 = 0
        let uploadLock = NSLock()
        let concurrency = 4  // 4장 동시 업로드
        let uploadQueue = DispatchQueue(label: "com.pickshot.upload", attributes: .concurrent)
        let uploadGroup = DispatchGroup()
        let uploadSemaphore = DispatchSemaphore(value: concurrency)

        fputs("[CLIENT] 사진 업로드 시작: \(photosToUpload.count)장 (중복 \(skippedCount)장 건너뜀)\n", stderr)
        for (index, photo) in photosToUpload.enumerated() {
            guard !cancelled else { break }
            fputs("[CLIENT] 업로드 \(index+1)/\(photosToUpload.count): \(photo.jpgURL.lastPathComponent)\n", stderr)

            uploadSemaphore.wait()  // 동시 4개 제한
            uploadGroup.enter()

            uploadQueue.async { [weak self] in
                defer {
                    uploadSemaphore.signal()
                    uploadGroup.leave()
                }
                guard !(self?.cancelled ?? true) else { return }

                // 리사이즈 (1200px max, JPEG 0.8)
                guard let resizedURL = self?.resizePhoto(photo: photo, index: index, tempDir: tempDir) else { return }

                // 업로드
                let fileSem = DispatchSemaphore(value: 0)
                GoogleDriveService.uploadFile(fileURL: resizedURL, folderId: folderID, accessToken: token) { result, error in
                    if let result = result {
                        let fileSize = (try? FileManager.default.attributesOfItem(atPath: resizedURL.path)[.size] as? Int64) ?? 0
                        let info: [String: Any] = [
                            "index": index + 1,
                            "filename": resizedURL.lastPathComponent,
                            "originalFilename": photo.jpgURL.lastPathComponent,
                            "driveFileId": result.fileId
                        ]
                        uploadLock.lock()
                        uploadedFiles.append(info)
                        uploadedBytes += fileSize
                        uploadLock.unlock()
                    }
                    fileSem.signal()
                }
                fileSem.wait()

                // 진행률 업데이트 (병렬 안전)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.uploadDone += 1
                    if let start = self.uploadStartTime {
                        let elapsed = Date().timeIntervalSince(start)
                        if elapsed > 1 {
                            uploadLock.lock()
                            let bytes = uploadedBytes
                            uploadLock.unlock()
                            let mbps = Double(bytes) / elapsed / 1_048_576
                            let photosPerSec = Double(self.uploadDone) / elapsed
                            let remaining = Double(self.uploadTotal - self.uploadDone) / max(photosPerSec, 0.01)
                            let speed = String(format: "%.1f MB/s", mbps)
                            let eta: String
                            if remaining < 60 {
                                eta = String(format: "%.0f초", remaining)
                            } else {
                                eta = String(format: "%.0f분 %.0f초", remaining / 60, remaining.truncatingRemainder(dividingBy: 60))
                            }
                            self.uploadSpeed = "\(speed) · 남은 시간: \(eta)"
                        }
                    }
                }
            } // uploadQueue.async
        } // for

        // 모든 업로드 완료 대기
        uploadGroup.wait()

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
        // 클라이언트 셀렉 폴더는 writer 로 공유 — 클라이언트가 .pickshot 파일 업로드 가능해야 하므로
        GoogleDriveService.createShareLink(fileId: folderID, accessToken: token, role: "writer") { [weak self] link, _ in
            DispatchQueue.main.async {
                self?.shareLink = link

                // 웹 뷰어 링크 생성
                let encodedName = self?.sessionName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let encodedClient = self?.clientName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                var viewerURL = "\(self?.viewerBaseURL ?? "https://kimjjang869-bot.github.io/pickshot-viewer")/?session=\(folderID)&name=\(encodedName)&client=\(encodedClient)"
                if let mid = manifestId {
                    viewerURL += "&manifest=\(mid)"
                }

                // 전략: 항상 CF Worker 프록시 사용 — URL 을 짧게 유지 (단축 전 ~200자, is.gd 단축 후 20자).
                // URL embed 는 단축 실패 시 400자 넘어가므로 폐기.
                let photoCount = uploadedFiles.count
                if let mid = manifestId {
                    let proxyURL = self?.effectiveProxyURL ?? Self.defaultCloudflareProxyURL
                    if let encodedProxy = proxyURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                        viewerURL += "&proxy=\(encodedProxy)"
                        fputs("[CLIENT] ✅ Worker 프록시 모드 (\(photoCount)장) \(proxyURL)?id=\(mid)\n", stderr)
                    }
                }

                let urlLen = viewerURL.count
                fputs("[CLIENT] 원본 URL 길이: \(urlLen) chars\n", stderr)
                self?.viewerLink = viewerURL  // 우선 원본 URL 로 표시

                // is.gd URL 단축은 백그라운드에서 실행 후 UI 업데이트 (메인 블로킹 방지)
                if urlLen > 150 {
                    let urlToShorten = viewerURL
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self = self else { return }
                        let shortURL = self.shortenURL(urlToShorten)
                        if shortURL != urlToShorten && shortURL.hasPrefix("https://is.gd/") {
                            DispatchQueue.main.async {
                                self.viewerLink = shortURL
                                self.qrCodeImage = self.generateQRCode(from: shortURL)
                                fputs("[CLIENT] 🔗 단축 URL 적용 (\(urlLen)자 → \(shortURL.count)자)\n", stderr)
                            }
                        }
                    }
                }

                // QR 코드 생성
                self?.qrCodeImage = self?.generateQRCode(from: viewerURL)
            }
            linkSemaphore.signal()
        }
        linkSemaphore.wait()

        // 완료 → 결과 창 자동 열기
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isUploading = false
            self.uploadSpeed = "완료"
            self.showSetup = true
            // 세션 정보 저장 (재시작해도 Drive에서 가져오기 가능)
            self.saveLastSession()

            // 세션 히스토리에 영구 저장 (목록 창에서 볼 수 있게)
            let record = ClientSession(
                id: UUID(),
                sessionName: self.sessionName,
                clientName: self.clientName,
                driveFolderID: self.driveFolderID ?? "",
                viewerURL: self.viewerLink ?? "",
                shareLink: self.shareLink,
                uploadedCount: self.uploadDone,
                selectionLimit: self.selectionLimit,
                createdAt: Date()
            )
            self.saveSession(record)
            fputs("[CLIENT] ✅ 업로드 완료: \(self.uploadDone)장, 링크: \(self.viewerLink ?? "없음")\n", stderr)
        }
    }

    // MARK: - 세션 저장/복원 (앱 재시작해도 Drive 가져오기 가능)

    private func saveLastSession() {
        let d = UserDefaults.standard
        d.set(driveFolderID, forKey: "cs_lastFolderID")
        d.set(sessionName, forKey: "cs_lastSessionName")
        d.set(clientName, forKey: "cs_lastClientName")
        d.set(viewerLink, forKey: "cs_lastViewerLink")
    }

    func restoreLastSession() -> Bool {
        let d = UserDefaults.standard
        guard let fid = d.string(forKey: "cs_lastFolderID"), !fid.isEmpty else { return false }
        driveFolderID = fid
        sessionName = d.string(forKey: "cs_lastSessionName") ?? ""
        clientName = d.string(forKey: "cs_lastClientName") ?? ""
        viewerLink = d.string(forKey: "cs_lastViewerLink")
        isActive = true
        fputs("[CLIENT] 세션 복원: \(sessionName) folder=\(fid)\n", stderr)
        return true
    }

    var hasLastSession: Bool {
        UserDefaults.standard.string(forKey: "cs_lastFolderID")?.isEmpty == false
    }

    var lastSessionName: String {
        UserDefaults.standard.string(forKey: "cs_lastSessionName") ?? ""
    }

    // MARK: - 사진 리사이즈

    private func resizePhoto(photo: PhotoItem, index: Int, tempDir: URL) -> URL? {
        // v9.0.2: RAWConversionService 의 새 파이프라인 사용 — Stage 3 임베디드 추출 + orientation +
        //   다단계 Lanczos 다운샘플. 색감 / 화질 / 회전 모두 본 변환 엔진과 동일.
        let sourceURL = photo.jpgURL
        let targetMax: CGFloat = 1200

        let cgImage: CGImage? = autoreleasepool {
            // 1차: deep embedded JPEG (RAW 면 Stage 3, JPG 면 임베디드/풀이미지).
            if let cg = RAWConversionService.extractDeepEmbeddedJPEG(url: sourceURL) {
                var ci = CIImage(cgImage: cg)
                // 2차: 부모 orientation 적용 (세로 사진 정방향).
                ci = RAWConversionService.applyParentOrientationIfNeeded(ci, url: sourceURL, embeddedSize: CGSize(width: cg.width, height: cg.height))
                // 3차: 다단계 Lanczos 다운샘플.
                let extent = ci.extent
                let origMax = max(extent.width, extent.height)
                if origMax > targetMax {
                    ci = RAWConversionService.highQualityDownscale(ci, targetMax: targetMax)
                }
                return RAWConversionService.ciContext.createCGImage(ci, from: ci.extent,
                                                                     format: .RGBA8,
                                                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            // 폴백: PreviewImageCache.loadOptimized (DNG without thumb 등).
            fputs("[CLIENT] embedded extraction 실패 → loadOptimized 폴백: \(sourceURL.lastPathComponent)\n", stderr)
            if let nsImage = PreviewImageCache.loadOptimized(url: sourceURL, maxPixel: targetMax),
               let cgImg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cgImg
            }
            return nil
        }

        guard let finalThumb = cgImage else {
            fputs("[CLIENT] ❌ 리사이즈 완전 실패: \(sourceURL.lastPathComponent)\n", stderr)
            return nil
        }
        fputs("[CLIENT] 리사이즈 완료 \(finalThumb.width)x\(finalThumb.height) — \(sourceURL.lastPathComponent)\n", stderr)

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
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        CGImageDestinationAddImage(dest, finalThumb, jpegOptions as CFDictionary)

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

    /// 일반 매니페스트 JSON (GitHub 업로드용, 사람이 읽을 수 있음)
    private func getManifestJSON(photos: [[String: Any]]) -> Data? {
        let manifest: [String: Any] = [
            "sessionName": sessionName,
            "clientName": clientName,
            "selectionLimit": selectionLimit,   // 0 = 무제한
            "totalPhotos": photos.count,
            "originalZipFileId": originalZipFileId ?? "",
            "photos": photos.map { info -> [String: Any] in
                let fid = info["driveFileId"] as? String ?? ""
                return [
                    "filename": info["filename"] ?? "",
                    "originalFilename": info["originalFilename"] ?? "",
                    "driveFileId": fid,
                    "thumbUrl": "https://lh3.googleusercontent.com/d/\(fid)=s200",
                    "fullUrl": "https://lh3.googleusercontent.com/d/\(fid)=s1200"
                ]
            }
        ]
        return try? JSONSerialization.data(withJSONObject: manifest)
    }

    /// 압축용 최소 매니페스트 — URL 해시 임베딩용. 축약 키 + URL 생략 (driveFileId 만으로 viewer 가 재구성).
    /// 포맷: {v:1, s:세션, c:고객, l:리미트, z:zipID, p:[[driveId,filename,origFilename]]}
    /// 크기: 기존 대비 약 85-90% 축소 (200B → ~25B per 사진)
    private func getCompactManifestJSON(photos: [[String: Any]]) -> Data? {
        let compact: [String: Any] = [
            "v": 1,                                 // 포맷 버전
            "s": sessionName,
            "c": clientName,
            "l": selectionLimit,
            "z": originalZipFileId ?? "",
            "p": photos.map { info -> [String] in
                let fid = info["driveFileId"] as? String ?? ""
                let fn = (info["filename"] as? String) ?? ""
                let ofn = (info["originalFilename"] as? String) ?? fn
                // 압축: [driveId, filename, originalFilename]
                // origFilename 이 filename 과 같으면 생략
                if fn == ofn { return [fid, fn] }
                return [fid, fn, ofn]
            }
        ]
        return try? JSONSerialization.data(withJSONObject: compact)
    }

    // MARK: - 세션 히스토리 (업로드한 모든 세션 기록)

    struct ClientSession: Codable, Identifiable {
        var id: UUID
        var sessionName: String
        var clientName: String
        var driveFolderID: String
        var viewerURL: String           // 최종 (단축) URL
        var shareLink: String?          // Drive 폴더 링크
        var uploadedCount: Int
        var selectionLimit: Int
        var createdAt: Date
        // 피드백 수신 시 업데이트
        var feedbackSelectedCount: Int? = nil
        var feedbackCommentCount: Int? = nil
        var feedbackReceivedAt: Date? = nil
    }

    private static let historyKey = "cs_sessionHistory_v1"
    private static let historyMaxCount = 100

    @Published var sessionHistory: [ClientSession] = []

    func loadSessionHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let sessions = try? JSONDecoder().decode([ClientSession].self, from: data) else {
            sessionHistory = []
            return
        }
        // 최신순 정렬
        sessionHistory = sessions.sorted { $0.createdAt > $1.createdAt }
    }

    func saveSession(_ session: ClientSession) {
        var history = sessionHistory
        // 같은 folderID 중복 제거 (재업로드 시 덮어쓰기)
        history.removeAll { $0.driveFolderID == session.driveFolderID }
        history.insert(session, at: 0)
        if history.count > Self.historyMaxCount {
            history = Array(history.prefix(Self.historyMaxCount))
        }
        sessionHistory = history
        persistHistory()
    }

    func deleteSession(id: UUID) {
        sessionHistory.removeAll { $0.id == id }
        persistHistory()
    }

    func updateSessionFeedback(folderID: String, selectedCount: Int, commentCount: Int) {
        if let idx = sessionHistory.firstIndex(where: { $0.driveFolderID == folderID }) {
            sessionHistory[idx].feedbackSelectedCount = selectedCount
            sessionHistory[idx].feedbackCommentCount = commentCount
            sessionHistory[idx].feedbackReceivedAt = Date()
            persistHistory()
        }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(sessionHistory) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    // MARK: - 선택 제한 프리셋 관리

    /// 기본 프리셋 (수정 불가)
    static let defaultSelectionPresets: [Int] = [5, 10, 20, 30, 50, 100, 0]

    /// 사용자 커스텀 프리셋 (UserDefaults 에 저장)
    func loadCustomSelectionPresets() -> [Int] {
        (UserDefaults.standard.array(forKey: "cs_customSelectionPresets") as? [Int]) ?? []
    }

    /// 현재 selectionLimit 값을 커스텀 프리셋으로 저장 (중복/기본값은 무시)
    /// - 반환: 저장된 프리셋 목록 (UI 갱신용)
    @discardableResult
    func saveCurrentAsCustomPreset() -> [Int] {
        var customs = loadCustomSelectionPresets()
        let defaults = Self.defaultSelectionPresets
        // 기본 프리셋에 있으면 굳이 추가 안 함
        guard !defaults.contains(selectionLimit),
              !customs.contains(selectionLimit),
              selectionLimit > 0 else { return customs }
        customs.append(selectionLimit)
        customs.sort()
        // 최대 10개까지만 유지
        if customs.count > 10 { customs = Array(customs.prefix(10)) }
        UserDefaults.standard.set(customs, forKey: "cs_customSelectionPresets")
        return customs
    }

    /// 커스텀 프리셋 삭제
    func removeCustomPreset(_ value: Int) -> [Int] {
        var customs = loadCustomSelectionPresets()
        customs.removeAll(where: { $0 == value })
        UserDefaults.standard.set(customs, forKey: "cs_customSelectionPresets")
        return customs
    }

    // MARK: - zlib 압축 + URL-safe Base64 (뷰어 #gz= 파라미터용)

    /// Data → zlib deflate 압축 → URL-safe Base64 인코딩.
    /// 뷰어의 DecompressionStream('deflate') 과 호환.
    private func compressAndBase64(_ data: Data) -> String? {
        let src = [UInt8](data)
        let dstSize = src.count + 64
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }

        let compressedSize = src.withUnsafeBufferPointer { srcBuf -> Int in
            guard let srcPtr = srcBuf.baseAddress else { return 0 }
            return compression_encode_buffer(dst, dstSize, srcPtr, src.count, nil, COMPRESSION_ZLIB)
        }
        guard compressedSize > 0 else { return nil }

        let compressed = Data(bytes: dst, count: compressedSize)
        let b64 = compressed.base64EncodedString()
        // URL-safe Base64 (RFC 4648 §5): + → -, / → _, padding 제거.
        // is.gd 등 URL 단축기 통과 + URLSearchParams 안전 (+ 공백 변환 이슈 없음).
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - GitHub Pages에 manifest 업로드

    @discardableResult
    private func uploadManifestToGitHub(sessionId: String, data: Data) -> Bool {
        // 앱 Keychain에서 GitHub 토큰 (App Sandbox 호환)
        let ghToken: String? = KeychainService.read(key: "github_token")

        guard let ghToken = ghToken, !ghToken.isEmpty else {
            fputs("[CLIENT] GitHub 토큰 없음 — manifest GitHub 업로드 스킵\n", stderr)
            return false
        }

        let b64Content = data.base64EncodedString()
        guard let apiURL = URL(string: "https://api.github.com/repos/kimjjang869-bot/pickshot-viewer/contents/data/\(sessionId).json") else {
            fputs("[CLIENT] Invalid GitHub API URL\n", stderr)
            return false
        }

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
        var success = false
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                fputs("[CLIENT] GitHub manifest 업로드: HTTP \(http.statusCode)\n", stderr)
                success = (200...299).contains(http.statusCode)
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        return success
    }

    // MARK: - URL 단축 (is.gd POST — 긴 해시 URL 도 처리 가능)

    func shortenURL(_ longURL: String) -> String {
        guard let apiURL = URL(string: "https://is.gd/create.php") else { return longURL }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Form body 인코딩: & = + ? # 은 반드시 퍼센트 인코딩 해야 is.gd 가 URL 을 온전히 받음.
        // `.urlQueryAllowed` 는 &,= 를 허용해서 is.gd 가 원본 URL 의 쿼리를 별도 폼 필드로 오해함.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let urlParam = longURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? longURL
        request.httpBody = "format=simple&url=\(urlParam)".data(using: .utf8)

        let sem = DispatchSemaphore(value: 0)
        var shortURL = longURL
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                fputs("[CLIENT] URL 단축 에러: \(error.localizedDescription)\n", stderr)
            } else if let data = data,
                      let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if result.hasPrefix("https://") {
                    shortURL = result
                    fputs("[CLIENT] ✅ URL 단축 성공: \(result)\n", stderr)
                } else {
                    fputs("[CLIENT] URL 단축 응답 이상: \(result.prefix(120))\n", stderr)
                }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 8)
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
            "selectionLimit": selectionLimit,   // 0 = 무제한
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
                    "thumbUrl": "https://lh3.googleusercontent.com/d/\(fileId)=s200",
                    "fullUrl": "https://lh3.googleusercontent.com/d/\(fileId)=s1200",
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
            guard let permURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)/permissions") else { return nil }
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
                let sourceURL = photo.jpgURL
                let ext = sourceURL.pathExtension.lowercased()
                let isRAW = FileMatchingService.rawExtensions.contains(ext)

                var thumb: CGImage? = nil

                // RAW 는 ImageIO 가 검정 이미지를 반환할 수 있어 CGImageSource 경로 건너뜀.
                if !isRAW {
                    if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) {
                        let opts: [CFString: Any] = [
                            kCGImageSourceThumbnailMaxPixelSize: originalResolution,
                            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                            kCGImageSourceCreateThumbnailWithTransform: true
                        ]
                        thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
                    }
                }
                if thumb == nil {
                    // RAW 또는 CGImageSource 실패: loadOptimized 로 fallback (embedded JPEG 추출)
                    if let nsImage = PreviewImageCache.loadOptimized(url: sourceURL, maxPixel: CGFloat(originalResolution)),
                       let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        thumb = cg
                    }
                }
                guard let finalThumb = thumb else {
                    fputs("[CLIENT] ❌ 원본 리사이즈 실패: \(sourceURL.lastPathComponent)\n", stderr)
                    return
                }

                let name: String
                if !filePrefix.isEmpty {
                    name = String(format: "%@_%04d.jpg", filePrefix, index + 1)
                } else {
                    name = String(format: "%04d_%@.jpg", index + 1, sourceURL.deletingPathExtension().lastPathComponent)
                }
                let destURL = zipDir.appendingPathComponent(name)
                guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(dest, finalThumb, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
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

        // v8.6.1: coordinator 실패 시 early return (기존엔 nil ZIP 업로드 시도해 500 에러)
        if let err = zipError {
            fputs("[CLIENT] ❌ ZIP coordinator 실패: \(err.localizedDescription)\n", stderr)
            return nil
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
        _ = Set(localFiles)

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

    // MARK: - Drive에서 .pickshot 파일 검색 + 다운로드

    func checkForPickshotInDrive(folderId: String, token: String, completion: @escaping (URL?) -> Void) {
        // 폴더 내 .pickshot 파일 검색
        let query = "'\(folderId)' in parents and name contains '.pickshot' and trashed = false"
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let listURL = URL(string: "https://www.googleapis.com/drive/v3/files?q=\(encodedQuery)&fields=files(id,name)") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: listURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]],
                  let firstFile = files.first,
                  let fileId = firstFile["id"] as? String,
                  let fileName = firstFile["name"] as? String else {
                fputs("[CLIENT] Drive에서 .pickshot 파일 없음\n", stderr)
                completion(nil)
                return
            }

            fputs("[CLIENT] Drive에서 .pickshot 발견: \(fileName) (\(fileId))\n", stderr)

            // 파일 다운로드
            guard let downloadURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media") else {
                completion(nil)
                return
            }
            var dlRequest = URLRequest(url: downloadURL)
            dlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            URLSession.shared.dataTask(with: dlRequest) { data, _, error in
                guard let data = data else {
                    fputs("[CLIENT] .pickshot 다운로드 실패: \(error?.localizedDescription ?? "")\n", stderr)
                    completion(nil)
                    return
                }
                // 임시 파일에 저장
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                do {
                    try data.write(to: tempURL)
                    fputs("[CLIENT] .pickshot 다운로드 완료: \(tempURL.path)\n", stderr)
                    completion(tempURL)
                } catch {
                    fputs("[CLIENT] .pickshot 저장 실패: \(error.localizedDescription)\n", stderr)
                    completion(nil)
                }
            }.resume()
        }.resume()
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
