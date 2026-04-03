import SwiftUI

struct GoogleDriveUploadView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss

    enum DriveMode: String, CaseIterable {
        case local = "로컬 드라이브"
        case api = "API 업로드"
    }

    enum FileTypeOption: String, CaseIterable {
        case jpgOnly = "JPG만"
        case rawOnly = "RAW만"
        case both = "JPG + RAW"
    }

    @State private var driveMode: DriveMode = .local
    @State private var fileTypeOption: FileTypeOption = .jpgOnly

    // Local drive state
    @State private var detectedDrivePath: URL?
    @State private var folderName: String = ""
    @State private var isCopying = false
    @State private var copyProgress: Int = 0
    @State private var copyTotal: Int = 0
    @State private var copyComplete = false
    @State private var copiedFolderURL: URL?

    // API state
    @State private var accessToken: String = ""
    @State private var isUploading = false
    @State private var uploadProgress: Int = 0
    @State private var uploadTotal: Int = 0
    @State private var uploadComplete = false
    @State private var shareLinks: [String] = []
    @State private var folderShareLink: String = ""
    @State private var uploadErrors: [String] = []

    // Common
    @State private var errorMessage: String?

    private var photosToUpload: [PhotoItem] {
        if store.selectionCount > 0 {
            return store.multiSelectedPhotos
        } else {
            return store.filteredPhotos
        }
    }

    private var filesToUpload: [URL] {
        var urls: [URL] = []
        for photo in photosToUpload {
            switch fileTypeOption {
            case .jpgOnly:
                urls.append(photo.jpgURL)
            case .rawOnly:
                if let rawURL = photo.rawURL {
                    urls.append(rawURL)
                }
            case .both:
                urls.append(photo.jpgURL)
                if let rawURL = photo.rawURL {
                    urls.append(rawURL)
                }
            }
        }
        return urls
    }

    private var totalFileSize: Int64 {
        var size: Int64 = 0
        for photo in photosToUpload {
            switch fileTypeOption {
            case .jpgOnly:
                size += photo.jpgFileSize
            case .rawOnly:
                size += photo.rawFileSize
            case .both:
                size += photo.jpgFileSize + photo.rawFileSize
            }
        }
        return size
    }

    private var fileSizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalFileSize)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Title
            HStack {
                Image(systemName: "icloud.and.arrow.up.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text("Google Drive 업로드")
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            // Mode selector
            Picker("", selection: $driveMode) {
                ForEach(DriveMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            // File selection info
            fileInfoSection

            Divider()

            // Mode-specific content
            if driveMode == .local {
                localDriveSection
            } else {
                apiUploadSection
            }

            Spacer()

            // Close button
            HStack {
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .onAppear {
            detectedDrivePath = GoogleDriveService.findGoogleDriveFolder()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd_HHmm"
            folderName = "PickShot_\(dateFormatter.string(from: Date()))"

            // Restore saved token
            accessToken = KeychainService.read(key: "gdrive_access_token") ?? ""
        }
    }

    // MARK: - File Info Section

    private var fileInfoSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("업로드 대상")
                    .font(.headline)
                Spacer()
            }

            // File type picker
            Picker("파일 유형", selection: $fileTypeOption) {
                ForEach(FileTypeOption.allCases, id: \.self) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.segmented)

            // Summary
            HStack(spacing: 16) {
                Label("\(photosToUpload.count)장", systemImage: "photo.on.rectangle")
                Label("\(filesToUpload.count)개 파일", systemImage: "doc")
                Label(fileSizeString, systemImage: "internaldrive")
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundColor(.secondary)

            if store.selectionCount > 0 {
                Text("선택된 사진 \(store.selectionCount)장을 업로드합니다")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("현재 필터 기준 전체 사진을 업로드합니다")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Local Drive Section

    private var localDriveSection: some View {
        VStack(spacing: 12) {
            // Drive path detection
            HStack {
                Image(systemName: detectedDrivePath != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(detectedDrivePath != nil ? .green : .red)

                if let path = detectedDrivePath {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Google Drive 감지됨")
                            .font(.system(size: 12, weight: .medium))
                        Text(path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text("Google Drive for Desktop이 설치되지 않았습니다")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()

                Button("경로 찾기") {
                    detectedDrivePath = GoogleDriveService.findGoogleDriveFolder()
                }
                .font(.system(size: 11))
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            // Folder name input
            HStack {
                Text("폴더 이름:")
                    .font(.system(size: 12))
                TextField("폴더 이름", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            // Copy progress / result
            if isCopying {
                VStack(spacing: 6) {
                    ProgressView(value: Double(copyProgress), total: Double(max(copyTotal, 1)))
                    Text("복사 중... \(copyProgress)/\(copyTotal)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            if copyComplete, let folder = copiedFolderURL {
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("복사 완료!")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.green)
                    }

                    HStack(spacing: 8) {
                        Button("Finder에서 열기") {
                            NSWorkspace.shared.open(folder)
                        }
                        .font(.system(size: 11))

                        Button("경로 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(folder.path, forType: .string)
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(8)
                .background(Color.green.opacity(0.08))
                .cornerRadius(6)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Copy button
            Button(action: startLocalCopy) {
                Label("Google Drive에 복사", systemImage: "doc.on.doc.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(detectedDrivePath == nil || isCopying || filesToUpload.isEmpty || folderName.isEmpty)
        }
    }

    // MARK: - API Upload Section

    private var apiUploadSection: some View {
        VStack(spacing: 12) {
            // Token input
            VStack(alignment: .leading, spacing: 4) {
                Text("OAuth2 Access Token")
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    SecureField("Bearer 토큰 입력", text: $accessToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                    Button("저장") {
                        _ = KeychainService.save(key: "gdrive_access_token", value: accessToken)
                    }
                    .font(.system(size: 11))
                }

                Text("Google OAuth Playground에서 토큰을 생성하세요 (scope: drive.file)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Button("OAuth Playground 열기") {
                    if let url = URL(string: "https://developers.google.com/oauthplayground/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.blue)
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            // Upload progress
            if isUploading {
                VStack(spacing: 6) {
                    ProgressView(value: Double(uploadProgress), total: Double(max(uploadTotal, 1)))
                    Text("업로드 중... \(uploadProgress)/\(uploadTotal)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // Upload errors
            if !uploadErrors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("오류:")
                        .font(.caption)
                        .foregroundColor(.red)
                    ForEach(uploadErrors.prefix(5), id: \.self) { err in
                        Text("- \(err)")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                    if uploadErrors.count > 5 {
                        Text("... 외 \(uploadErrors.count - 5)건")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.05))
                .cornerRadius(4)
            }

            // Results
            if uploadComplete {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("업로드 완료!")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.green)
                    }

                    if !folderShareLink.isEmpty {
                        HStack {
                            Text(folderShareLink)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button("링크 복사") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(folderShareLink, forType: .string)
                            }
                            .font(.system(size: 11))
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(4)
                    }

                    if !shareLinks.isEmpty && folderShareLink.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("공유 링크 (\(shareLinks.count)개):")
                                .font(.system(size: 11, weight: .medium))

                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(shareLinks, id: \.self) { link in
                                        HStack {
                                            Text(link)
                                                .font(.system(size: 9, design: .monospaced))
                                                .lineLimit(1)
                                                .truncationMode(.middle)

                                            Button {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(link, forType: .string)
                                            } label: {
                                                Image(systemName: "doc.on.clipboard")
                                                    .font(.system(size: 9))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 100)
                        }

                        Button("전체 링크 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(shareLinks.joined(separator: "\n"), forType: .string)
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(8)
                .background(Color.green.opacity(0.08))
                .cornerRadius(6)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Upload button
            Button(action: startAPIUpload) {
                Label("Google Drive에 업로드", systemImage: "icloud.and.arrow.up.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(accessToken.isEmpty || isUploading || filesToUpload.isEmpty)
        }
    }

    // MARK: - Actions

    private func startLocalCopy() {
        guard let drivePath = detectedDrivePath else { return }
        let files = filesToUpload
        guard !files.isEmpty else { return }

        isCopying = true
        copyComplete = false
        copyProgress = 0
        copyTotal = files.count
        errorMessage = nil
        copiedFolderURL = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let resultFolder = try GoogleDriveService.copyToGoogleDrive(
                    files: files,
                    driveRoot: drivePath,
                    folderName: folderName,
                    progress: { completed, total in
                        copyProgress = completed
                        copyTotal = total
                    }
                )
                DispatchQueue.main.async {
                    isCopying = false
                    copyComplete = true
                    copiedFolderURL = resultFolder
                }
            } catch {
                DispatchQueue.main.async {
                    isCopying = false
                    errorMessage = "복사 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startAPIUpload() {
        let files = filesToUpload
        guard !files.isEmpty, !accessToken.isEmpty else { return }

        isUploading = true
        uploadComplete = false
        uploadProgress = 0
        uploadTotal = files.count
        shareLinks = []
        folderShareLink = ""
        uploadErrors = []
        errorMessage = nil

        // Save token for next time
        _ = KeychainService.save(key: "gdrive_access_token", value: accessToken)

        let token = accessToken

        DispatchQueue.global(qos: .userInitiated).async {
            // Create a folder first
            let group = DispatchGroup()
            var folderId: String?

            group.enter()
            GoogleDriveService.createFolder(name: folderName, accessToken: token) { id, error in
                folderId = id
                if let error = error {
                    DispatchQueue.main.async {
                        uploadErrors.append("폴더 생성 실패: \(error.localizedDescription)")
                    }
                }
                group.leave()
            }
            group.wait()

            // Upload files sequentially
            var fileIds: [String] = []

            for (index, fileURL) in files.enumerated() {
                let semaphore = DispatchSemaphore(value: 0)

                GoogleDriveService.uploadFile(fileURL: fileURL, folderId: folderId, accessToken: token) { result, error in
                    if let result = result {
                        fileIds.append(result.fileId)
                    } else if let error = error {
                        DispatchQueue.main.async {
                            uploadErrors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                    semaphore.signal()
                }

                semaphore.wait()
                DispatchQueue.main.async {
                    uploadProgress = index + 1
                }
            }

            // Create share link for folder if we have one
            if let folderId = folderId {
                let semaphore = DispatchSemaphore(value: 0)
                GoogleDriveService.createShareLink(fileId: folderId, accessToken: token) { link, error in
                    if let link = link {
                        DispatchQueue.main.async {
                            folderShareLink = link
                        }
                    }
                    semaphore.signal()
                }
                semaphore.wait()
            } else {
                // Create individual share links
                for fileId in fileIds {
                    let semaphore = DispatchSemaphore(value: 0)
                    GoogleDriveService.createShareLink(fileId: fileId, accessToken: token) { link, error in
                        if let link = link {
                            DispatchQueue.main.async {
                                shareLinks.append(link)
                            }
                        }
                        semaphore.signal()
                    }
                    semaphore.wait()
                }
            }

            DispatchQueue.main.async {
                isUploading = false
                uploadComplete = true
            }
        }
    }
}
