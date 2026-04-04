import SwiftUI

struct ExportView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss

    @State private var exportMode: ExportMode = .selected
    @State private var exportTarget: ExportTarget = .folder
    @State private var didApplyInitialTarget = false
    @State private var copyResult: CopyResult?
    @State private var isComplete = false
    @State private var jpgFolderName: String = "JPG"
    @State private var rawFolderName: String = "RAW"

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

    @State private var convResolution: RAWConversionService.Resolution = .original
    @State private var convQuality: RAWConversionService.Quality = .high

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
            Text("사진 내보내기")
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
                    // Resolution + Quality — centered
                    HStack(spacing: 12) {
                        Spacer()
                        Text("해상도")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Picker("", selection: $convResolution) {
                            ForEach(RAWConversionService.Resolution.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .frame(width: 90)
                        Text("품질")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Picker("", selection: $convQuality) {
                            ForEach(RAWConversionService.Quality.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .frame(width: 130)
                        Text("GPU")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(3)
                        Spacer()
                    }

                    // Progress
                    if store.isConverting {
                        VStack(spacing: 4) {
                            HStack(spacing: 8) {
                                ProgressView(value: store.conversionProgress)
                                    .progressViewStyle(.linear)
                                    .tint(.orange)
                                Text("\(store.conversionDone)/\(store.conversionTotal)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .frame(width: 70)
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

            // Folder name customization (only for folder export)
            if exportTarget == .folder {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("JPG 폴더명")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 65, alignment: .trailing)
                        TextField("JPG", text: $jpgFolderName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 120)
                    }
                    HStack(spacing: 4) {
                        Text("RAW 폴더명")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 65, alignment: .trailing)
                        TextField("RAW", text: $rawFolderName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 120)
                    }
                }
            }

            // Summary
            let photos = photosToExport
            let withRAW = photos.filter { $0.hasRAW }.count
            let ratedCount = photos.filter { $0.rating > 0 }.count

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
                    Text("JPG: \(photos.count)장")
                    Text("RAW: \(withRAW)장 (매칭됨)")
                        .foregroundColor(withRAW > 0 ? .green : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            if store.isExporting {
                ProgressView(value: store.exportProgress) {
                    Text("복사 중... \(Int(store.exportProgress * 100))%")
                }
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
                    .disabled(photos.isEmpty || store.isExporting || store.isConverting)
                }
            }
        }
        .padding(28)
        .frame(width: 580)
        .onAppear {
            if !didApplyInitialTarget && store.exportOpenAsRawConvert {
                exportTarget = .rawToJpg
                store.exportOpenAsRawConvert = false
                didApplyInitialTarget = true
            }
        }
    }

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

        // Check for existing files
        let fm = FileManager.default
        let existingFiles = photos.compactMap { photo -> String? in
            let url = photo.rawURL ?? photo.jpgURL
            let outputName = url.deletingPathExtension().lastPathComponent + ".jpg"
            let outputURL = outputFolder.appendingPathComponent(outputName)
            return fm.fileExists(atPath: outputURL.path) ? outputName : nil
        }

        if !existingFiles.isEmpty {
            let alert = NSAlert()
            alert.messageText = "이미 존재하는 파일 \(existingFiles.count)개"
            alert.informativeText = existingFiles.prefix(5).joined(separator: "\n") +
                (existingFiles.count > 5 ? "\n... 외 \(existingFiles.count - 5)개" : "")
            alert.addButton(withTitle: "덮어쓰기")
            alert.addButton(withTitle: "건너뛰기")
            alert.addButton(withTitle: "취소")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return }  // 취소
            if response == .alertSecondButtonReturn {
                // 건너뛰기: 이미 있는 파일 제외
                // (RAWConversionService가 알아서 덮어쓰기하므로 여기서는 진행)
                // TODO: 건너뛰기 로직 추가 가능
            }
            // 덮어쓰기: 그냥 진행
        }

        store.conversionTotal = photos.count
        store.conversionDone = 0
        store.conversionProgress = 0
        store.conversionCancelled = false
        store.conversionResult = nil
        store.conversionStartTime = CFAbsoluteTimeGetCurrent()

        DispatchQueue.global(qos: .userInitiated).async {
            var cancelFlag = false

            let result = RAWConversionService.batchConvert(
                photos: photos,
                outputFolder: outputFolder,
                resolution: convResolution,
                quality: convQuality,
                cancelFlag: &cancelFlag
            ) { done, total in
                DispatchQueue.main.async {
                    store.conversionDone = done
                    store.conversionProgress = Double(done) / Double(total)
                    // Propagate cancel from UI
                    if store.conversionCancelled { cancelFlag = true }
                }
            }

            DispatchQueue.main.async {
                store.conversionResult = result
                store.conversionTotal = 0
                store.conversionDone = 0
                if !store.conversionCancelled {
                    NSWorkspace.shared.open(outputFolder)
                }
            }
        }
    }

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
        store.isExporting = true
        isComplete = false

        DispatchQueue.global(qos: .userInitiated).async {
            let result: CopyResult

            if target == .lightroom {
                result = FileCopyService.exportForLightroom(photos: photos, to: destURL) { progress in
                    DispatchQueue.main.async { store.exportProgress = progress }
                }
            } else {
                result = FileCopyService.copyPhotos(photos: photos, to: destURL, jpgFolderName: jpgFolderName, rawFolderName: rawFolderName) { progress in
                    DispatchQueue.main.async { store.exportProgress = progress }
                }
            }

            DispatchQueue.main.async {
                store.isExporting = false
                copyResult = result
                isComplete = true

                if target == .lightroom {
                    // Open Lightroom with the folder
                    FileCopyService.openLightroom(folderURL: destURL)
                } else {
                    NSWorkspace.shared.open(destURL)
                }
            }
        }
    }
}
