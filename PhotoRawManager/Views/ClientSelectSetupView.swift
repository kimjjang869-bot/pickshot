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
    @State private var uploadOriginal = false
    @State private var originalResolution = 2000
    @State private var filePrefix = ""
    // 고객 최대 선택 수
    @State private var selectionLimit: Int = 0  // 0 = 무제한
    @State private var customPresets: [Int] = []
    @State private var limitInputText: String = ""
    // 업로드 범위: false = 전체, true = 선택한 썸네일만
    @State private var uploadOnlySelected: Bool = false

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
        .frame(width: 520, height: service.viewerLink != nil ? 620 : 600)
        .onAppear {
            sessionName = defaultSessionName
            gSelect.isLoggedIn = GoogleDriveService.isLoggedIn
        }
        .alert("업로드 오류", isPresented: Binding(
            get: { service.errorMessage != nil },
            set: { if !$0 { service.errorMessage = nil } }
        )) {
            Button("확인") { service.errorMessage = nil }
        } message: {
            Text(service.errorMessage ?? "")
        }
    }

    // MARK: - 설정 폼

    private var setupFormView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Google 연결
                HStack {
                    Image(systemName: gSelect.isLoggedIn ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(gSelect.isLoggedIn ? .green : .red)
                    Text(gSelect.isLoggedIn ? "Google Drive 연결됨" : "Google Drive 미연결")
                        .font(.system(size: 13))
                    Spacer()
                    if !gSelect.isLoggedIn {
                        Button("Google 로그인") { gSelect.loginToGoogle() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .background(gSelect.isLoggedIn ? Color.green.opacity(0.06) : Color.red.opacity(0.06))
                .cornerRadius(8)

                // 세션 정보
                GroupBox {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Text("세션 이름")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 80, alignment: .trailing)
                            TextField("예: 김철수-이영희 웨딩", text: $sessionName)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 12) {
                            Text("클라이언트")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 80, alignment: .trailing)
                            TextField("예: 김철수, 이영희", text: $clientName)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 12) {
                            Text("파일 이름")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 80, alignment: .trailing)
                            TextField("예: 뜜_나나_루카루카", text: $filePrefix)
                                .textFieldStyle(.roundedBorder)
                            Text("_0001.jpg")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 65)
                        }
                        if !filePrefix.isEmpty {
                            HStack {
                                Spacer().frame(width: 92)
                                Text("미리보기: \(filePrefix)_0001.jpg")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.purple)
                                Spacer()
                            }
                        }
                    }
                    .padding(4)
                }

                // 접근 권한
                GroupBox {
                    VStack(spacing: 10) {
                        HStack(spacing: 12) {
                            Text("접근 권한")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 80, alignment: .trailing)
                            Picker("", selection: $accessMode) {
                                ForEach(ClientSelectService.AccessMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        if accessMode == .emailRestricted {
                            HStack(spacing: 12) {
                                Text("Gmail")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 80, alignment: .trailing)
                                TextField("client@gmail.com", text: $clientEmail)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .padding(4)
                }

                // 업로드 범위 (다중 선택 시 — 전체 vs 선택한 것만)
                uploadScopeSection

                // 최대 선택 수 (하드 캡)
                selectionLimitSection

                // 원본 업로드
                GroupBox {
                    VStack(spacing: 8) {
                        Toggle(isOn: $uploadOriginal) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .foregroundColor(.blue)
                                Text("원본 파일 업로드 (클라이언트 다운로드용)")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .toggleStyle(.checkbox)

                        if uploadOriginal {
                            HStack(spacing: 12) {
                                Text("해상도")
                                    .font(.system(size: 11))
                                    .frame(width: 80, alignment: .trailing)
                                Picker("", selection: $originalResolution) {
                                    Text("1200px").tag(1200)
                                    Text("2000px").tag(2000)
                                    Text("2500px").tag(2500)
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }
                    .padding(4)
                }

                // 요약
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 14))
                        .foregroundColor(.purple)
                    Text("\(photoCount)장")
                        .font(.system(size: 14, weight: .bold))
                    Text("셀렉용 1200px\(uploadOriginal ? " + 원본 \(originalResolution)px ZIP" : "")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(Color.purple.opacity(0.06))
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

            Text(service.uploadSpeed.contains("ZIP") ? "원본 ZIP 처리 중..." : "업로드 중...")
                .font(.system(size: 14, weight: .medium))

            // 진행 바
            ProgressView(value: uploadProgress)
                .progressViewStyle(.linear)
                .frame(width: 300)

            // 속도 + 남은 시간
            if !service.uploadSpeed.isEmpty {
                Text(service.uploadSpeed)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.purple)
            }

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

                Divider().padding(.vertical, 6)

                // 새 세션 시작 (다른 폴더 업로드)
                Button(action: {
                    service.resetForNewSession()
                    sessionName = defaultSessionName
                    clientName = ""
                    clientEmail = ""
                    filePrefix = ""
                }) {
                    Label("새 세션 시작 (다른 폴더 업로드)", systemImage: "plus.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(colors: [.purple, .blue],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
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
        let allPhotos = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        // 업로드 범위: 사용자가 "선택한 것만" 골랐고 다중 선택 상태면 선택 항목만 필터
        let photos: [PhotoItem]
        if uploadOnlySelected && store.selectedPhotoIDs.count >= 2 {
            let selectedIDs = store.selectedPhotoIDs
            photos = allPhotos.filter { selectedIDs.contains($0.id) }
        } else {
            photos = allPhotos
        }
        service.filePrefix = filePrefix
        service.uploadOriginal = uploadOriginal
        service.originalResolution = originalResolution
        service.selectionLimit = selectionLimit
        service.startSession(
            name: name,
            client: clientName,
            email: clientEmail,
            photos: photos,
            accessMode: accessMode
        )
    }

    // MARK: - 업로드 범위 선택 섹션 (전체 vs 선택한 썸네일만)

    private var uploadScopeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                    Text("업로드 범위")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }

                let totalCount = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }.count
                let selectedCount = store.selectedPhotoIDs.count
                let hasMultiSelection = selectedCount >= 2

                // 전체
                Button(action: { uploadOnlySelected = false }) {
                    HStack(spacing: 10) {
                        Image(systemName: uploadOnlySelected ? "circle" : "largecircle.fill.circle")
                            .font(.system(size: 14))
                            .foregroundColor(uploadOnlySelected ? .secondary : .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("전체 사진")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(totalCount)장 전부 업로드 (기본)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                // 선택한 것만
                Button(action: {
                    if hasMultiSelection { uploadOnlySelected = true }
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: uploadOnlySelected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 14))
                            .foregroundColor(uploadOnlySelected ? .accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("선택한 썸네일만")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(hasMultiSelection ? .primary : .secondary)
                            if hasMultiSelection {
                                Text("\(selectedCount)장만 업로드")
                                    .font(.system(size: 10))
                                    .foregroundColor(.accentColor)
                            } else {
                                Text("썸네일 2장 이상 선택 후 다시 열어주세요")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(!hasMultiSelection)
            }
            .padding(4)
        }
        .onAppear {
            // 다중 선택이 있으면 기본값을 "선택한 것만" 으로 자동 설정 (직관적)
            if store.selectedPhotoIDs.count >= 2 { uploadOnlySelected = true }
        }
    }

    // MARK: - 최대 선택 수 (하드 캡) 섹션

    private var selectionLimitSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text("고객 최대 선택 수")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(selectionLimit == 0 ? "무제한" : "\(selectionLimit)장")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(selectionLimit == 0 ? .secondary : .accentColor)
                }

                // 프리셋 버튼들 (기본 + 커스텀)
                FlowLayout(spacing: 6) {
                    ForEach(ClientSelectService.defaultSelectionPresets, id: \.self) { value in
                        presetButton(value: value, isCustom: false)
                    }
                    ForEach(customPresets, id: \.self) { value in
                        presetButton(value: value, isCustom: true)
                    }
                }

                // 직접 입력 + 프리셋 저장
                HStack(spacing: 8) {
                    Text("직접 입력")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("0 = 무제한", text: $limitInputText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: limitInputText) { newValue in
                            if let v = Int(newValue.trimmingCharacters(in: .whitespaces)), v >= 0 {
                                selectionLimit = v
                            }
                        }
                    Text("장")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: saveCurrentPreset) {
                        Label("프리셋 저장", systemImage: "plus.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectionLimit == 0 || ClientSelectService.defaultSelectionPresets.contains(selectionLimit) || customPresets.contains(selectionLimit))
                }
            }
            .padding(4)
        }
        .onAppear {
            selectionLimit = service.selectionLimit
            customPresets = service.loadCustomSelectionPresets()
            limitInputText = selectionLimit == 0 ? "" : "\(selectionLimit)"
        }
    }

    @ViewBuilder
    private func presetButton(value: Int, isCustom: Bool) -> some View {
        let isSelected = selectionLimit == value
        let label = value == 0 ? "무제한" : "\(value)장"
        HStack(spacing: 3) {
            Button(action: {
                selectionLimit = value
                limitInputText = value == 0 ? "" : "\(value)"
            }) {
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.accentColor : Color.gray.opacity(0.15))
                    .foregroundColor(isSelected ? .white : .primary)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)

            // 커스텀 프리셋은 삭제 버튼 제공
            if isCustom {
                Button(action: {
                    customPresets = service.removeCustomPreset(value)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func saveCurrentPreset() {
        service.selectionLimit = selectionLimit
        customPresets = service.saveCurrentAsCustomPreset()
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
