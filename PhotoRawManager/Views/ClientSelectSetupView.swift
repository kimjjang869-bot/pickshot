import SwiftUI

// MARK: - 클라이언트 셀렉 설정 뷰
// 세션 이름, 클라이언트 정보, 접근 모드 설정 → 업로드 시작 → QR/링크 표시

struct ClientSelectSetupView: View {
    @ObservedObject var service = ClientSelectService.shared
    @ObservedObject var gSelect = GSelectService.shared
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss

    @State private var sessionName = ""
    @State private var clientName = ""
    @State private var clientEmail = ""
    @State private var accessMode: ClientSelectService.AccessMode = .publicLink
    @State private var linkCopied = false

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.rectangle.stack.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.purple)
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.blue)
                }

                Text("클라이언트 셀렉")
                    .font(.system(size: 18, weight: .bold))

                Text("사진을 리사이즈하여 Google Drive에 업로드합니다\n클라이언트는 웹 브라우저에서 셀렉 + 코멘트를 남길 수 있습니다")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            if service.isUploading {
                // 업로드 진행 중
                uploadProgressView
            } else if service.viewerLink != nil {
                // 업로드 완료 — 링크/QR 표시
                uploadCompleteView
            } else {
                // 설정 폼
                setupFormView
            }

            Divider()

            // 하단 버튼
            HStack {
                Button("닫기") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if service.isUploading {
                    Button("업로드 취소") {
                        service.cancelUpload()
                    }
                    .foregroundColor(.red)
                } else if service.viewerLink == nil {
                    Button("업로드 시작") {
                        startUpload()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(!gSelect.isLoggedIn || photoCount == 0)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(width: 460, height: service.viewerLink != nil ? 580 : 540)
        .onAppear {
            sessionName = defaultSessionName
            gSelect.isLoggedIn = GoogleDriveService.isLoggedIn
        }
    }

    // MARK: - 설정 폼

    private var setupFormView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Google 연결 상태
                HStack {
                    Image(systemName: gSelect.isLoggedIn ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(gSelect.isLoggedIn ? .green : .red)
                    Text(gSelect.isLoggedIn ? "Google Drive 연결됨" : "Google Drive 미연결")
                        .font(.system(size: 13))
                    Spacer()
                    if !gSelect.isLoggedIn {
                        Button("Google 로그인") { gSelect.loginToGoogle() }
                            .font(.system(size: 11))
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(8)

                // 세션 이름
                VStack(alignment: .leading, spacing: 4) {
                    Text("세션 이름")
                        .font(.system(size: 12, weight: .medium))
                    TextField("예: 김철수-이영희 웨딩", text: $sessionName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }

                // 클라이언트 이름
                VStack(alignment: .leading, spacing: 4) {
                    Text("클라이언트 이름")
                        .font(.system(size: 12, weight: .medium))
                    TextField("예: 김철수, 이영희", text: $clientName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }

                // 접근 모드
                VStack(alignment: .leading, spacing: 4) {
                    Text("접근 권한")
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $accessMode) {
                        ForEach(ClientSelectService.AccessMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                // 이메일 (이메일 제한 모드일 때만)
                if accessMode == .emailRestricted {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("클라이언트 Gmail")
                            .font(.system(size: 12, weight: .medium))
                        TextField("client@gmail.com", text: $clientEmail)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                        Text("이 이메일만 사진을 볼 수 있습니다")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                // 사진 수
                HStack {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundColor(.purple)
                    Text("\(photoCount)장 업로드 예정")
                        .font(.system(size: 13, weight: .medium))
                    Text("(1200px 리사이즈)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color.purple.opacity(0.06))
                .cornerRadius(8)

                // 안내
                VStack(spacing: 4) {
                    infoRow(icon: "arrow.up.doc.fill", color: .blue, text: "사진을 1200px JPEG으로 리사이즈 후 업로드")
                    infoRow(icon: "link", color: .green, text: "QR코드 + 링크 생성 (카톡으로 전달)")
                    infoRow(icon: "hand.tap.fill", color: .orange, text: "클라이언트가 웹에서 셀렉 + 코멘트")
                    infoRow(icon: "arrow.down.doc.fill", color: .purple, text: ".pickshot 파일로 셀렉 결과 자동 연동")
                }
                .padding(8)
                .background(Color.blue.opacity(0.04))
                .cornerRadius(8)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 업로드 진행

    private var uploadProgressView: some View {
        VStack(spacing: 20) {
            Spacer()

            // 진행률 원형
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: uploadProgress)
                    .stroke(Color.purple, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: uploadProgress)

                VStack(spacing: 2) {
                    Text("\(service.uploadDone)/\(service.uploadTotal)")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                    Text(String(format: "%.0f%%", uploadProgress * 100))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Text("업로드 중...")
                .font(.system(size: 14, weight: .medium))

            if !service.uploadSpeed.isEmpty {
                Text(service.uploadSpeed)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // 진행 바
            ProgressView(value: uploadProgress)
                .progressViewStyle(.linear)
                .frame(width: 300)

            Spacer()
        }
        .padding(.horizontal, 28)
    }

    // MARK: - 업로드 완료

    private var uploadCompleteView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 완료 표시
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)

                Text("\(service.uploadDone)장 업로드 완료")
                    .font(.system(size: 16, weight: .bold))

                // QR 코드
                if let qrImage = service.qrCodeImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 180)
                        .background(Color.white)
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.1), radius: 4)
                }

                // 뷰어 링크
                if let link = service.viewerLink {
                    VStack(spacing: 4) {
                        Text("뷰어 링크")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(link)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.blue)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .background(Color.gray.opacity(0.06))
                    .cornerRadius(6)
                }

                // 버튼 그룹
                HStack(spacing: 12) {
                    Button(action: {
                        service.copyLink()
                        linkCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { linkCopied = false }
                    }) {
                        Label(linkCopied ? "복사됨!" : "링크 복사", systemImage: linkCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)

                    Button(action: { service.saveQRCode() }) {
                        Label("QR 저장", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)

                    if let link = service.viewerLink, let url = URL(string: link) {
                        Button(action: { NSWorkspace.shared.open(url) }) {
                            Label("브라우저에서 열기", systemImage: "safari")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // Drive 링크
                if let driveLink = service.shareLink, let url = URL(string: driveLink) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        Label("Google Drive 폴더 열기", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 헬퍼

    private var photoCount: Int {
        store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }.count
    }

    private var uploadProgress: CGFloat {
        guard service.uploadTotal > 0 else { return 0 }
        return CGFloat(service.uploadDone) / CGFloat(service.uploadTotal)
    }

    private var defaultSessionName: String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let folderName = store.folderURL?.lastPathComponent ?? "PickShot"
        return "\(folderName)_\(df.string(from: Date()))"
    }

    private func startUpload() {
        let name = sessionName.isEmpty ? defaultSessionName : sessionName
        let photos = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        service.startSession(
            name: name,
            client: clientName,
            email: clientEmail,
            photos: photos,
            accessMode: accessMode
        )
    }

    private func infoRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 11))
        }
    }
}
