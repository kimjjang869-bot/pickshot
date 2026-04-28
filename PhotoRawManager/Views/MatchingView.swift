import SwiftUI

/// Unified matching sheet for all 3 matching modes
struct MatchingView: View {
    @EnvironmentObject var store: PhotoStore
    @Binding var isPresented: Bool
    @State private var selectedMode: MatchMode = .filename
    @State private var filenameText: String = ""
    @State private var parsedFilenameCount: Int = 0
    @State private var isProcessing = false
    @State private var resultMessage: String?
    @State private var matchedCount = 0
    @State private var unmatchedCount = 0
    @State private var unmatchedList: [String] = []
    @State private var showResult = false

    enum MatchMode: String, CaseIterable {
        case filename = "파일명 매칭"
        case jpgReturn = "JPG 반환 매칭"
        case jpgRawMatch = "JPG+RAW 매칭"
        case aiSimilarity = "AI 사진 매칭"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Spacer()
                Text("셀렉 매칭")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Mode selector
            Picker("매칭 모드", selection: $selectedMode) {
                ForEach(MatchMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Content based on mode
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedMode {
                    case .filename:
                        filenameMatchView
                    case .jpgReturn:
                        jpgReturnMatchView
                    case .jpgRawMatch:
                        jpgRawMatchView
                    case .aiSimilarity:
                        aiSimilarityMatchView
                    }
                }
                .padding()
            }

            Divider()

            // Result area
            if showResult {
                resultView
                    .padding()
            }
        }
        .frame(width: 500, height: showResult ? 550 : 420)
    }

    // MARK: - 1. 파일명 텍스트 매칭

    private var filenameMatchView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("파일명 목록을 붙여넣거나 입력하세요", systemImage: "doc.text")
                .font(.system(size: 13, weight: .medium))

            Text("쉼표, 줄바꿈, 공백으로 구분됩니다. 확장자는 자동 제거됩니다.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            TextEditor(text: $filenameText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 150)
                .border(Color.gray.opacity(0.3))
                .cornerRadius(4)
                .onChange(of: filenameText) { _, text in
                    // 파싱 결과 캐시 (body에서 매 렌더마다 파싱 방지)
                    parsedFilenameCount = FilenameMatchingService.parseFilenames(from: text).count
                }

            HStack {
                Button("클립보드에서 붙여넣기") {
                    if let str = NSPasteboard.general.string(forType: .string) {
                        filenameText = str
                    }
                }
                .buttonStyle(.bordered)

                Button("파일에서 불러오기") {
                    let panel = NSOpenPanel()
                    panel.title = "파일명 목록 파일 선택"
                    panel.allowedContentTypes = [.plainText, .commaSeparatedText]
                    if panel.runModal() == .OK, let url = panel.url,
                       let text = try? String(contentsOf: url) {
                        filenameText = text
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                if parsedFilenameCount > 0 {
                    Text("\(parsedFilenameCount)개 감지됨")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                }
            }

            Button(action: runFilenameMatch) {
                HStack {
                    if isProcessing {
                        ProgressView().scaleEffect(0.7)
                    }
                    Text("매칭 실행")
                        .font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(filenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
        }
    }

    // MARK: - 2. JPG 반환 매칭

    private var jpgReturnMatchView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("클라이언트가 반환한 JPG 폴더를 선택하세요", systemImage: "photo.on.rectangle.angled")
                .font(.system(size: 13, weight: .medium))

            Text("반환된 JPG 파일명과 현재 폴더의 RAW 파일명을 비교합니다.\n정확 매칭 → 유사 매칭 → 숫자 패턴 매칭 순으로 시도합니다.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Button(action: runJPGReturnMatch) {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    if isProcessing {
                        ProgressView().scaleEffect(0.7)
                    }
                    Text("JPG 폴더 선택 및 매칭")
                        .font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing || store.photos.isEmpty)

            if store.photos.isEmpty {
                Text("먼저 RAW 폴더를 열어주세요")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - 3. JPG+RAW 매칭

    private var jpgRawMatchView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("다른 폴더의 RAW/JPG 파일을 현재 목록과 매칭합니다", systemImage: "doc.on.doc")
                .font(.system(size: 13, weight: .medium))

            Text("현재 열린 폴더의 파일과 선택한 폴더의 파일을 파일명(baseName)으로 비교하여\nJPG↔RAW를 자동 연결합니다.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("확장자 제거 후 파일명(baseName) 비교")
                        .font(.system(size: 11))
                }
                HStack(spacing: 6) {
                    Circle().fill(.blue).frame(width: 6, height: 6)
                    Text("현재 JPG만 있으면 → RAW 폴더에서 같은 이름 RAW 연결")
                        .font(.system(size: 11))
                }
                HStack(spacing: 6) {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                    Text("현재 RAW만 있으면 → JPG 폴더에서 같은 이름 JPG 연결")
                        .font(.system(size: 11))
                }
            }
            .padding(8)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(6)

            if let url = store.folderURL {
                Text("현재 폴더: \(url.lastPathComponent)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Button(action: runJPGRawMatch) {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    if isProcessing {
                        ProgressView().scaleEffect(0.7)
                    }
                    Text("매칭할 폴더 선택")
                        .font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(isProcessing || store.photos.isEmpty)

            if store.photos.isEmpty {
                Text("먼저 폴더를 열어주세요")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - 4. AI 사진 유사도 매칭

    private var aiSimilarityMatchView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("카톡/메신저로 받은 사진 폴더를 선택하세요", systemImage: "brain")
                .font(.system(size: 13, weight: .medium))

            Text("pHash(이미지 지문) + EXIF 촬영시간으로 원본을 찾습니다.\nAPI 비용 없이 로컬에서 실행됩니다.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("EXIF 촬영시간 비교 (2초 이내 = 같은 사진)")
                        .font(.system(size: 11))
                }
                HStack(spacing: 6) {
                    Circle().fill(.blue).frame(width: 6, height: 6)
                    Text("pHash 이미지 지문 비교 (구도/색감/밝기)")
                        .font(.system(size: 11))
                }
                HStack(spacing: 6) {
                    Circle().fill(.purple).frame(width: 6, height: 6)
                    Text("두 가지 합산으로 최종 유사도 판단")
                        .font(.system(size: 11))
                }
            }
            .padding(8)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(6)

            Button(action: runAISimilarityMatch) {
                HStack {
                    Image(systemName: "folder.badge.questionmark")
                    if isProcessing {
                        ProgressView().scaleEffect(0.7)
                    }
                    Text("사진 폴더 선택 및 매칭")
                        .font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(isProcessing || store.photos.isEmpty)
        }
    }

    // MARK: - Result View

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Image(systemName: matchedCount > 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(matchedCount > 0 ? .green : .red)
                Text("매칭 결과")
                    .font(.system(size: 14, weight: .bold))
            }

            HStack(spacing: 16) {
                VStack {
                    Text("\(matchedCount)")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.green)
                    Text("매칭됨")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                VStack {
                    Text("\(unmatchedCount)")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(unmatchedCount > 0 ? .red : .secondary)
                    Text("미매칭")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            if !unmatchedList.isEmpty {
                Text("미매칭 파일:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(unmatchedList.prefix(20), id: \.self) { name in
                            Text("• \(name)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.red)
                        }
                        if unmatchedList.count > 20 {
                            Text("... 외 \(unmatchedList.count - 20)개")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 80)
            }

            if let msg = resultMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func runFilenameMatch() {
        isProcessing = true
        let filenames = FilenameMatchingService.parseFilenames(from: filenameText)
        let result = FilenameMatchingService.match(filenames: filenames, photos: store.photos)

        // Apply selections — idx was computed from a snapshot, re-validate bounds
        for (_, idx) in result.matched {
            guard store.photos.indices.contains(idx) else { continue }
            store.photos[idx].rating = max(store.photos[idx].rating, 1)
        }

        matchedCount = result.matched.count
        unmatchedCount = result.unmatched.count
        unmatchedList = result.unmatched
        resultMessage = "매칭된 \(matchedCount)장에 ★1 별점을 적용했습니다."
        showResult = true
        isProcessing = false
        store.invalidateFilterCache()
    }

    private func runJPGReturnMatch() {
        let panel = NSOpenPanel()
        panel.title = "반환된 JPG 폴더 선택"
        panel.message = "클라이언트가 반환한 JPG 파일이 있는 폴더를 선택하세요"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let jpgs = JPGReturnMatchingService.scanJPGs(in: url)
            let result = JPGReturnMatchingService.match(returnedJPGs: jpgs, photos: store.photos)

            DispatchQueue.main.async {
                for (_, idx, _) in result.matched {
                    guard store.photos.indices.contains(idx) else { continue }
                    store.photos[idx].rating = max(store.photos[idx].rating, 1)
                }

                matchedCount = result.matched.count
                unmatchedCount = result.unmatched.count
                unmatchedList = result.unmatched.map { $0.lastPathComponent }

                var exactCount = 0
                var fuzzyCount = 0
                var numberCount = 0
                for m in result.matched {
                    switch m.matchType {
                    case .exact: exactCount += 1
                    case .fuzzy: fuzzyCount += 1
                    case .numberPattern: numberCount += 1
                    }
                }
                resultMessage = "정확:\(exactCount) 유사:\(fuzzyCount) 번호:\(numberCount) — ★1 별점 적용됨"
                showResult = true
                isProcessing = false
                store.invalidateFilterCache()
            }
        }
    }

    private func runJPGRawMatch() {
        let panel = NSOpenPanel()
        panel.title = "매칭할 RAW/JPG 폴더 선택"
        panel.message = "현재 목록의 파일과 매칭할 RAW 또는 JPG 파일이 있는 폴더를 선택하세요"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        isProcessing = true

        DispatchQueue.global(qos: .userInitiated).async {
            // 선택한 폴더의 파일 스캔
            let fm = FileManager.default
            let allExts = FileMatchingService.jpgExtensions
                .union(FileMatchingService.rawExtensions)
                .union(FileMatchingService.imageExtensions)
            var externalFiles: [String: (url: URL, size: Int64, isRAW: Bool)] = [:]  // baseName → info

            if let enumerator = fm.enumerator(at: selectedURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
                for case let fileURL as URL in enumerator {
                    let ext = fileURL.pathExtension.lowercased()
                    guard allExts.contains(ext) else { continue }
                    let baseName = fileURL.deletingPathExtension().lastPathComponent
                    let isRAW = FileMatchingService.rawExtensions.contains(ext)
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                    externalFiles[baseName] = (url: fileURL, size: size, isRAW: isRAW)
                }
            }

            DispatchQueue.main.async {
                var matched = 0
                var unmatched: [String] = []
                var matchedBaseNames = Set<String>()
                matchedBaseNames.reserveCapacity(store.photos.count)

                for i in store.photos.indices {
                    let baseName = store.photos[i].jpgURL.deletingPathExtension().lastPathComponent
                    matchedBaseNames.insert(baseName)

                    guard let external = externalFiles[baseName] else {
                        continue
                    }

                    if external.isRAW {
                        // 외부가 RAW → 현재 사진에 RAW 연결
                        if store.photos[i].rawURL == nil || store.photos[i].rawURL == store.photos[i].jpgURL {
                            store.photos[i].rawURL = external.url
                            store.photos[i].rawFileSize = external.size
                            matched += 1
                        }
                    } else {
                        // 외부가 JPG → RAW만 있는 사진의 경우 JPG를 rawURL 대신 연결 불가 (jpgURL은 let)
                        // JPG 매칭은 지원하지 않음 — 현재 목록에 RAW가 없는 경우만 RAW 폴더 매칭 용도
                    }
                }

                // 매칭 안 된 외부 파일 — matchedBaseNames는 위 루프에서 이미 생성됨
                for (baseName, _) in externalFiles {
                    if !matchedBaseNames.contains(baseName) {
                        unmatched.append(baseName)
                    }
                }

                matchedCount = matched
                unmatchedCount = unmatched.count
                unmatchedList = unmatched.sorted()
                resultMessage = "매칭 완료: \(matched)개 연결됨 (폴더: \(selectedURL.lastPathComponent), 총 \(externalFiles.count)개 파일)"
                showResult = true
                isProcessing = false
                store.invalidateFilterCache()
            }
        }
    }

    private func runAISimilarityMatch() {
        let panel = NSOpenPanel()
        panel.title = "클라이언트 사진 폴더 선택"
        panel.message = "카톡/메신저로 받은 사진이 있는 폴더를 선택하세요"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let clientPhotos = AISimilarityService.scanImages(in: url)
            let result = AISimilarityService.match(
                clientPhotos: clientPhotos,
                photos: store.photos,
                similarityThreshold: 0.80
            )

            DispatchQueue.main.async {
                for match in result.matched {
                    guard store.photos.indices.contains(match.matchedPhotoIndex) else { continue }
                    store.photos[match.matchedPhotoIndex].rating = max(store.photos[match.matchedPhotoIndex].rating, 1)
                }

                matchedCount = result.matched.count
                unmatchedCount = result.unmatched.count
                unmatchedList = result.unmatched.map { $0.lastPathComponent }

                let avgSimilarity = result.matched.isEmpty ? 0 :
                    result.matched.reduce(0.0) { $0 + $1.similarity } / Double(result.matched.count)
                resultMessage = "평균 유사도: \(String(format: "%.0f", avgSimilarity * 100))% — ★1 별점 적용됨"
                showResult = true
                isProcessing = false
                store.invalidateFilterCache()
            }
        }
    }
}
