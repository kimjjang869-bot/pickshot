import SwiftUI

struct ExportView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss

    @State private var exportMode: ExportMode = .selected
    @State private var exportTarget: ExportTarget = .folder
    @State private var didApplyInitialTarget = false
    @State private var copyResult: CopyResult?
    @State private var isComplete = false
    // v8.9.4: 단순화 — 무엇을 내보낼지를 단일 enum 으로
    @State private var contentChoice: ContentChoice = .all
    @State private var folderLayout: FolderLayout = .separate
    // 보정값 적용은 개발 완료 시점에 노출. 현재는 항상 false.
    private let applyDevelopSettings: Bool = false
    private let developJPEGQuality: Double = 0.92
    // 폴더명은 항상 자동 (JPG / RAW). 사용자 입력 제거.
    private let jpgFolderName: String = "JPG"
    private let rawFolderName: String = "RAW"

    enum ContentChoice: String, CaseIterable, Identifiable {
        case all = "사진+RAW 모두"
        case mediaOnly = "사진/영상만"
        case rawOnly = "RAW만"
        var id: String { rawValue }
        var doJPG: Bool { self == .all || self == .mediaOnly }
        var doRAW: Bool { self == .all || self == .rawOnly }
    }
    enum FolderLayout: String, CaseIterable, Identifiable {
        case separate = "JPG/RAW 분리 폴더"
        case singleSubfolder = "선택 폴더에 바로"
        var id: String { rawValue }
        // singleSubfolder = 사용자가 고른 그 폴더에 모든 파일 직행 (서브폴더 없음)
        var isSingleFolder: Bool { self == .singleSubfolder }
    }

    // 중복 처리 상태
    @State private var showDuplicateAlert = false
    @State private var duplicateFiles: [String] = []
    @State private var pendingExportDestination: URL?
    @State private var pendingExportTarget: ExportTarget?
    @State private var pendingPhotos: [PhotoItem] = []

    enum ExportMode: String, CaseIterable {
        case selected = "선택된 사진"
        case rated = "별점 있는 사진만"
        case filtered = "현재 필터 기준"
        case all = "전체 사진"
    }

    enum ExportTarget: String, CaseIterable {
        case folder = "폴더 내보내기"
        case lightroom = "Lightroom 내보내기"
        case rawToJpg = "RAW → JPG 변환"
    }

    @State private var convOptions = RAWConversionService.ExportOptions()

    private var photosToExport: [PhotoItem] {
        switch exportMode {
        case .selected:
            return store.multiSelectedPhotos
        case .rated:
            return store.photos.filter { $0.rating > 0 }
        case .filtered:
            return store.filteredPhotos
        case .all:
            return store.photos
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            Text("사진/영상 내보내기")
                .font(.system(size: 18, weight: .bold))

            // Export target tabs — full width
            HStack(spacing: 0) {
                ForEach(ExportTarget.allCases, id: \.self) { target in
                    Button(action: { exportTarget = target }) {
                        Text(target.rawValue)
                            .font(.system(size: 13, weight: exportTarget == target ? .bold : .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(exportTarget == target ? Color.accentColor : Color.gray.opacity(0.12))
                            .foregroundColor(exportTarget == target ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .cornerRadius(8)

            // RAW → JPG options
            if exportTarget == .rawToJpg {
                VStack(spacing: 10) {
                    // Row 1: Resolution + Quality
                    HStack(spacing: 10) {
                        Spacer()
                        Text("해상도").font(.system(size: 11)).foregroundColor(.secondary)
                        Picker("", selection: $convOptions.resolution) {
                            ForEach(RAWConversionService.Resolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 85)
                        Text("품질").font(.system(size: 11)).foregroundColor(.secondary)
                        Picker("", selection: $convOptions.quality) {
                            ForEach(RAWConversionService.Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 120)
                        Text("GPU").font(.system(size: 9, weight: .bold)).foregroundColor(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(Color.orange.opacity(0.12)).cornerRadius(3)
                        Spacer()
                    }

                    // Row 2: Sharpening + Color Space + Auto Horizon
                    HStack(spacing: 10) {
                        Spacer()
                        Text("샤프닝").font(.system(size: 11)).foregroundColor(.secondary)
                        Picker("", selection: $convOptions.sharpening) {
                            ForEach(RAWConversionService.Sharpening.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 80)
                        Text("색공간").font(.system(size: 11)).foregroundColor(.secondary)
                        Picker("", selection: $convOptions.colorSpace) {
                            ForEach(RAWConversionService.OutputColorSpace.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 110)
                        // 수평 보정 — 추후 활성화 예정
                        // Toggle("수평", isOn: $convOptions.autoHorizon)
                        Spacer()
                    }

                    // Row 3: Filename pattern
                    HStack(spacing: 10) {
                        Spacer()
                        Text("파일명").font(.system(size: 11)).foregroundColor(.secondary)
                        Picker("", selection: $convOptions.filenamePattern) {
                            ForEach(RAWConversionService.FilenamePattern.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 120)
                        if convOptions.filenamePattern == .prefixNumber {
                            TextField("접두사", text: $convOptions.filenamePrefix)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .font(.system(size: 11))
                        }
                        Spacer()
                    }

                    // Progress (변환 진행은 시트 내에서도 표시)
                    if store.isConverting {
                        VStack(spacing: 4) {
                            HStack(spacing: 8) {
                                ProgressView(value: store.conversionProgress)
                                    .progressViewStyle(.linear)
                                    .tint(.orange)
                                Text("\(store.conversionDone)/\(store.conversionTotal)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .frame(minWidth: 80, alignment: .trailing)
                                Button(action: { store.conversionCancelled = true }) {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("변환 중지")
                            }
                            if !store.conversionETA.isEmpty {
                                Text(store.conversionETA)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                    // Result
                    if let result = store.conversionResult {
                        HStack(spacing: 6) {
                            Image(systemName: result.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(result.failed == 0 ? .green : .orange)
                            Text("\(result.succeeded)장 완료 (\(String(format: "%.1f", result.totalTime))초)")
                                .font(.system(size: 12, weight: .medium))
                            if result.failed > 0 {
                                Text("· \(result.failed)장 실패")
                                    .font(.system(size: 11)).foregroundColor(.red)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
            }

            // Lightroom info
            if exportTarget == .lightroom {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RAW 파일 + XMP 사이드카(별점 포함)를 내보냅니다")
                            .font(.caption)
                        Text("Lightroom에서 폴더를 가져오면 별점이 자동 적용됩니다")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(6)
            }

            // Export mode picker — centered, full width
            HStack(spacing: 0) {
                ForEach(ExportMode.allCases, id: \.self) { mode in
                    Button(action: { exportMode = mode }) {
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: exportMode == mode ? .bold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(exportMode == mode ? Color.green : Color.gray.opacity(0.12))
                            .foregroundColor(exportMode == mode ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .cornerRadius(8)

            // v8.9.4: 폴더 내보내기 옵션 단순화
            //   - "무엇" : 사진+RAW 모두 / 사진영상만 / RAW만  (단일 segmented)
            //   - "어떻게" : JPG/RAW 분리 폴더 / 선택 폴더에 바로 (서브폴더 없음)
            //   - 폴더명 입력란 제거 (자동 JPG/RAW 사용)
            //   - 보정값 토글 — 개발 완료 시점에 다시 노출
            if exportTarget == .folder {
                VStack(alignment: .leading, spacing: 12) {
                    // 무엇을 내보낼까?
                    VStack(alignment: .leading, spacing: 6) {
                        Text("무엇을 내보낼까요?")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        segmentedRow(
                            options: ContentChoice.allCases,
                            selection: $contentChoice,
                            color: .green
                        )
                    }
                    // 어떻게 저장할까?
                    //   contentChoice 가 분리 가능한 케이스 (사진+RAW 모두) 일 때만 노출.
                    //   단일 종류만 내보낼 땐 자동으로 "선택 폴더에 바로" 처리.
                    if contentChoice == .all {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("어디에 저장할까요?")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            segmentedRow(
                                options: FolderLayout.allCases,
                                selection: $folderLayout,
                                color: .blue
                            )
                            if folderLayout == .separate {
                                Text("선택한 폴더 안에 JPG / RAW 두 개의 하위 폴더가 만들어집니다.")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("선택한 폴더에 모든 파일이 바로 저장됩니다 (하위 폴더 없음).")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(8)
            }

            // Summary — 단일 루프로 통계 계산
            let photos = photosToExport
            let (withRAW, ratedCount, videoCount, photoCount, videoMarkerCount): (Int, Int, Int, Int, Int) = {
                var raw = 0, rated = 0, video = 0, photo = 0, videoMarker = 0
                for p in photos {
                    if p.hasRAW { raw += 1 }
                    if p.rating > 0 { rated += 1 }
                    if p.isVideoFile {
                        video += 1
                        let xmpPath = p.jpgURL.appendingPathExtension("xmp").path
                        if FileManager.default.fileExists(atPath: xmpPath) { videoMarker += 1 }
                    } else if !p.isRawOnly {
                        photo += 1
                    }
                }
                return (raw, rated, video, photo, videoMarker)
            }()

            VStack(alignment: .leading, spacing: 4) {
                if exportTarget == .lightroom {
                    Text("RAW: \(withRAW)장")
                    if withRAW < photos.count {
                        Text("RAW 없는 사진 \(photos.count - withRAW)장은 제외됩니다")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    Text("XMP (별점): \(withRAW)장 생성 예정")
                        .foregroundColor(.purple)
                    if ratedCount > 0 {
                        Text("별점 포함: \(ratedCount)장")
                            .foregroundColor(.orange)
                    }
                } else {
                    if photoCount > 0 {
                        Text("사진: \(photoCount)장")
                    }
                    if videoCount > 0 {
                        Text("영상: \(videoCount)개")
                            .foregroundColor(.purple)
                    }
                    if videoMarkerCount > 0 {
                        Text("영상 마커(IN/OUT) XMP: \(videoMarkerCount)개 동반")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    Text("RAW: \(withRAW)장 (매칭됨)")
                        .foregroundColor(withRAW > 0 ? .green : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            // 백그라운드 내보내기 진행 중 표시
            if store.bgExportActive {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("백그라운드에서 내보내기 진행 중...")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                    Text("\(store.bgExportDone)/\(store.bgExportTotal)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.blue)
                        .frame(minWidth: 80, alignment: .trailing)
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(6)
            }

            if let result = copyResult, isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: result.verified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(result.verified ? .green : .red)
                        Text(result.verified ? "검증 완료" : "검증 실패")
                            .fontWeight(.medium)
                    }

                    if exportTarget == .lightroom {
                        Text("RAW \(result.copiedRAW)장, XMP \(result.copiedXMP)장 내보냄")
                            .font(.caption)
                    } else {
                        Text("JPG \(result.copiedJPG)장, RAW \(result.copiedRAW)장 복사됨")
                            .font(.caption)
                    }

                    if result.skipped > 0 {
                        Text("건너뛴 파일: \(result.skipped)개")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if !result.failedFiles.isEmpty {
                        Divider()
                        Text("실패 항목:")
                            .font(.caption)
                            .foregroundColor(.red)
                        ForEach(result.failedFiles, id: \.self) { msg in
                            Text(msg)
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }

            HStack(spacing: 12) {
                Button(action: { dismiss() }) {
                    Text("닫기")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 100, height: 36)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isComplete {
                    Button(action: { dismiss() }) {
                        Text("완료")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 180, height: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(action: {
                        if exportTarget == .rawToJpg {
                            startConversion()
                        } else {
                            startExport()
                        }
                    }) {
                        Text(exportTarget == .rawToJpg ? "JPG 변환 시작" : (exportTarget == .lightroom ? "Lightroom 내보내기" : "폴더 선택 후 내보내기"))
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 180, height: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(photos.isEmpty || store.isConverting || store.bgExportActive)
                }
            }
        }
        .padding(28)
        .frame(width: 650)
        .onAppear {
            if !didApplyInitialTarget && store.exportOpenAsRawConvert {
                exportTarget = .rawToJpg
                store.exportOpenAsRawConvert = false
                didApplyInitialTarget = true
            }
        }
        // 중복 파일 경고 시트
        .sheet(isPresented: $showDuplicateAlert) {
            DuplicateAlertView(
                duplicateFiles: duplicateFiles,
                onOverwrite: { handleDuplicateChoice(.overwrite) },
                onRename: { handleDuplicateChoice(.rename) },
                onSkip: { handleDuplicateChoice(.skip) },
                onCancel: {
                    showDuplicateAlert = false
                    pendingExportDestination = nil
                    pendingExportTarget = nil
                    pendingPhotos = []
                }
            )
        }
    }

    // MARK: - 중복 처리 선택 후 실행

    private func handleDuplicateChoice(_ handling: DuplicateHandling) {
        showDuplicateAlert = false
        guard let destURL = pendingExportDestination,
              let target = pendingExportTarget else { return }
        let photos = pendingPhotos
        pendingExportDestination = nil
        pendingExportTarget = nil
        pendingPhotos = []

        executeBackgroundExport(photos: photos, target: target, destURL: destURL, duplicateHandling: handling)
    }

    // MARK: - RAW → JPG 변환

    private func startConversion() {
        guard !store.isConverting else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "변환된 JPG를 저장할 폴더를 선택하세요"
        guard panel.runModal() == .OK, let outputFolder = panel.url else { return }

        let photos = photosToExport.filter { !$0.isFolder && !$0.isParentFolder }
        guard !photos.isEmpty else { return }

        // 중복 검사
        let fm = FileManager.default
        let existingFiles = photos.compactMap { photo -> String? in
            let url = photo.rawURL ?? photo.jpgURL
            let outputName = url.deletingPathExtension().lastPathComponent + ".jpg"
            let outputURL = outputFolder.appendingPathComponent(outputName)
            return fm.fileExists(atPath: outputURL.path) ? outputName : nil
        }

        if !existingFiles.isEmpty {
            // 중복 다이얼로그 표시 — 건너뛰기 로직이 변환 경로에 구현되지 않아
            // 오도하지 않도록 덮어쓰기 / 취소만 제공한다.
            let alert = NSAlert()
            alert.messageText = "이미 존재하는 파일 \(existingFiles.count)개"
            alert.informativeText = existingFiles.prefix(5).joined(separator: "\n") +
                (existingFiles.count > 5 ? "\n... 외 \(existingFiles.count - 5)개" : "") +
                "\n\n덮어쓰기로 진행하시겠습니까?"
            alert.addButton(withTitle: "덮어쓰기")
            alert.addButton(withTitle: "취소")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return }
        }

        store.conversionTotal = photos.count
        store.conversionDone = 0
        store.conversionProgress = 0
        store.conversionCancelled = false
        store.conversionResult = nil
        store.conversionStartTime = CFAbsoluteTimeGetCurrent()

        // 시트 닫고 백그라운드에서 계속 실행
        dismiss()

        DispatchQueue.global(qos: .userInitiated).async {
            // UnsafeMutablePointer로 스레드 간 안전한 취소 플래그 전달
            let cancelPtr = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            cancelPtr.initialize(to: false)
            defer { cancelPtr.deinitialize(count: 1); cancelPtr.deallocate() }

            let result = RAWConversionService.batchConvert(
                photos: photos,
                outputFolder: outputFolder,
                options: convOptions,
                cancelFlag: cancelPtr
            ) { done, total in
                DispatchQueue.main.async {
                    store.conversionDone = done
                    store.conversionProgress = Double(done) / Double(total)
                    if store.conversionCancelled { cancelPtr.pointee = true }
                }
            }

            DispatchQueue.main.async {
                store.conversionResult = result
                store.conversionTotal = 0
                store.conversionDone = 0
                if !store.conversionCancelled {
                    // 완료 시 Finder에서 폴더 열기
                    NSWorkspace.shared.open(outputFolder)
                }
            }
        }
    }

    // MARK: - Segmented row helper (v8.9.4)

    @ViewBuilder
    private func segmentedRow<T: Hashable & Identifiable & RawRepresentable>(
        options: [T],
        selection: Binding<T>,
        color: Color
    ) -> some View where T.RawValue == String {
        HStack(spacing: 6) {
            ForEach(options) { option in
                let isOn = selection.wrappedValue == option
                Button(action: { selection.wrappedValue = option }) {
                    Text(option.rawValue)
                        .font(.system(size: 12, weight: isOn ? .bold : .regular))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(isOn ? color : Color.gray.opacity(0.15))
                        .foregroundColor(isOn ? .white : .primary)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 폴더/Lightroom 내보내기

    private func startExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = exportTarget == .lightroom
            ? "Lightroom으로 가져올 RAW + XMP 파일을 저장할 폴더를 선택하세요"
            : "JPG와 RAW 파일을 복사할 대상 폴더를 선택하세요"

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        let photos = photosToExport
        let target = exportTarget

        // v8.9.4: contentChoice/folderLayout → 기존 인자로 변환
        let isSingleFolder = (contentChoice != .all) || folderLayout.isSingleFolder

        // 중복 검사
        let duplicates: [String]
        if target == .lightroom {
            duplicates = FileCopyService.findDuplicatesForLightroom(photos: photos, destinationURL: destURL)
        } else {
            duplicates = FileCopyService.findDuplicates(photos: photos, destinationURL: destURL, jpgFolderName: jpgFolderName, rawFolderName: rawFolderName, singleFolder: isSingleFolder)
        }

        if !duplicates.isEmpty {
            // 중복 발견 → 다이얼로그 표시
            duplicateFiles = duplicates
            pendingExportDestination = destURL
            pendingExportTarget = target
            pendingPhotos = photos
            showDuplicateAlert = true
        } else {
            // 중복 없음 → 바로 백그라운드 실행
            executeBackgroundExport(photos: photos, target: target, destURL: destURL, duplicateHandling: .overwrite)
        }
    }

    // MARK: - 백그라운드 내보내기 실행

    private func executeBackgroundExport(photos: [PhotoItem], target: ExportTarget, destURL: URL, duplicateHandling: DuplicateHandling) {
        let totalOps: Int
        if target == .lightroom {
            totalOps = photos.count * 2
        } else {
            let rawCount = photos.filter { $0.hasRAW }.count
            totalOps = photos.count + rawCount
        }

        // 백그라운드 내보내기 상태 설정
        store.bgExportActive = true
        store.bgExportProgress = 0
        store.bgExportDone = 0
        store.bgExportTotal = totalOps
        store.bgExportCancelled = false
        store.bgExportLabel = target == .lightroom ? "Lightroom 내보내기" : "폴더 내보내기"
        store.bgExportDestination = destURL

        // 시트 닫기 — 사용자는 계속 작업 가능
        dismiss()

        // v8.9.4: contentChoice/folderLayout 기반 — 단일 종류만 내보낼 땐 자동으로 single folder
        let jpgName = jpgFolderName
        let rawName = rawFolderName
        let doJPG = contentChoice.doJPG
        let doRAW = contentChoice.doRAW
        let isSingleFolder = (contentChoice != .all) || folderLayout.isSingleFolder

        DispatchQueue.global(qos: .userInitiated).async {
            let result: CopyResult

            if target == .lightroom {
                result = FileCopyService.exportForLightroom(
                    photos: photos,
                    to: destURL,
                    duplicateHandling: duplicateHandling
                ) { done, total in
                    DispatchQueue.main.async {
                        guard !store.bgExportCancelled else { return }
                        store.bgExportDone = done
                        store.bgExportProgress = Double(done) / Double(total)
                    }
                }
            } else {
                result = FileCopyService.copyPhotos(
                    photos: photos,
                    to: destURL,
                    jpgFolderName: jpgName,
                    rawFolderName: rawName,
                    duplicateHandling: duplicateHandling,
                    exportJPG: doJPG,
                    exportRAW: doRAW,
                    singleFolder: isSingleFolder,
                    applyDevelopSettings: applyDevelopSettings,
                    developJPEGQuality: CGFloat(developJPEGQuality)
                ) { done, total in
                    DispatchQueue.main.async {
                        guard !store.bgExportCancelled else { return }
                        store.bgExportDone = done
                        store.bgExportProgress = Double(done) / Double(total)
                    }
                }
            }

            DispatchQueue.main.async {
                store.bgExportActive = false

                if !store.bgExportCancelled {
                    // 완료 시 Finder에서 폴더 열기
                    if target == .lightroom {
                        FileCopyService.openLightroom(folderURL: destURL)
                    } else {
                        NSWorkspace.shared.open(destURL)
                    }

                    // 토스트 알림
                    let msg: String
                    if target == .lightroom {
                        msg = "내보내기 완료 — RAW \(result.copiedRAW)장, XMP \(result.copiedXMP)장"
                    } else {
                        msg = "내보내기 완료 — JPG \(result.copiedJPG)장, RAW \(result.copiedRAW)장"
                    }
                    store.toastMessage = msg
                    store.showToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        store.showToast = false
                    }
                }

                store.bgExportCancelled = false
            }
        }
    }
}

// MARK: - 중복 파일 경고 뷰

struct DuplicateAlertView: View {
    let duplicateFiles: [String]
    let onOverwrite: () -> Void
    let onRename: () -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)
                Text("중복 파일 발견")
                    .font(.system(size: 16, weight: .bold))
            }

            Text("대상 폴더에 이미 존재하는 파일 \(duplicateFiles.count)개:")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            // 중복 파일 목록 (최대 5개)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(duplicateFiles.prefix(5), id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text(name)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if duplicateFiles.count > 5 {
                    Text("... 외 \(duplicateFiles.count - 5)개")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.leading, 16)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(6)

            // 버튼들
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("닫기")
                        .frame(width: 80, height: 30)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: onSkip) {
                    Text("건너뛰기")
                        .frame(width: 80, height: 30)
                }
                .buttonStyle(.bordered)

                Button(action: onRename) {
                    Text("이름 변경하여 내보내기")
                        .frame(height: 30)
                }
                .buttonStyle(.bordered)

                Button(action: onOverwrite) {
                    Text("덮어쓰기")
                        .frame(width: 80, height: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
