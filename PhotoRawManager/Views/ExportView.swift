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
    @State private var convProgress: Double = 0
    @State private var isConverting = false
    @State private var convResult: RAWConversionService.ConversionResult?

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
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                Text("사진 내보내기")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
            }

            // Export target tabs
            HStack(spacing: 0) {
                ForEach(ExportTarget.allCases, id: \.self) { target in
                    Button(action: { exportTarget = target }) {
                        Text(target.rawValue)
                            .font(.system(size: 13, weight: exportTarget == target ? .bold : .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(exportTarget == target ? Color.accentColor : Color.gray.opacity(0.15))
                            .foregroundColor(exportTarget == target ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .cornerRadius(8)

            // RAW → JPG options — all inline rows
            if exportTarget == .rawToJpg {
                VStack(spacing: 10) {
                    // Row 1: Title + GPU badge
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                        Text("RAW → JPG 변환")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("GPU 가속")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(4)
                    }

                    // Row 2: Resolution + Quality (single line)
                    HStack(spacing: 0) {
                        Text("해상도")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 45, alignment: .trailing)
                        Picker("", selection: $convResolution) {
                            ForEach(RAWConversionService.Resolution.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .frame(width: 100)
                        .padding(.trailing, 16)

                        Text("품질")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 30, alignment: .trailing)
                        Picker("", selection: $convQuality) {
                            ForEach(RAWConversionService.Quality.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .frame(width: 130)
                        Spacer()
                    }

                    // Progress / Result
                    if isConverting {
                        HStack(spacing: 8) {
                            ProgressView(value: convProgress)
                                .progressViewStyle(.linear)
                                .tint(.orange)
                            Text("\(Int(convProgress * 100))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange)
                                .frame(width: 35)
                        }
                    }

                    if let result = convResult {
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
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(6)
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

            // Export mode picker — single line
            HStack(spacing: 8) {
                Text("대상")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 30, alignment: .trailing)
                ForEach(ExportMode.allCases, id: \.self) { mode in
                    Button(action: { exportMode = mode }) {
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: exportMode == mode ? .bold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(exportMode == mode ? Color.green : Color.gray.opacity(0.15))
                            .foregroundColor(exportMode == mode ? .white : .primary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

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

            HStack {
                Button("닫기") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isComplete {
                    Button("완료") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(exportTarget == .rawToJpg ? "JPG 변환 시작" : (exportTarget == .lightroom ? "Lightroom으로 내보내기" : "폴더 선택 후 내보내기")) {
                        if exportTarget == .rawToJpg {
                            startConversion()
                        } else {
                            startExport()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(photos.isEmpty || store.isExporting)
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "변환된 JPG를 저장할 폴더를 선택하세요"
        guard panel.runModal() == .OK, let outputFolder = panel.url else { return }

        let photos = photosToExport.filter { !$0.isFolder && !$0.isParentFolder }
        guard !photos.isEmpty else { return }

        isConverting = true
        convProgress = 0
        convResult = nil
        store.conversionTotal = photos.count
        store.conversionDone = 0

        DispatchQueue.global(qos: .userInitiated).async {
            let result = RAWConversionService.batchConvert(
                photos: photos,
                outputFolder: outputFolder,
                resolution: convResolution,
                quality: convQuality
            ) { done, total in
                convProgress = Double(done) / Double(total)
                DispatchQueue.main.async {
                    store.conversionDone = done
                }
            }

            DispatchQueue.main.async {
                isConverting = false
                convResult = result
                convProgress = 1.0
                store.conversionTotal = 0
                store.conversionDone = 0
                NSWorkspace.shared.open(outputFolder)
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
