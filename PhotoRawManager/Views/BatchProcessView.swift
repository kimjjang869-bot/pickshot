import SwiftUI
import AppKit

struct BatchProcessView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) private var dismiss

    // Source
    enum SourceMode: String, CaseIterable {
        case selected = "선택한 사진"
        case filtered = "필터된 사진"
        case all = "전체 사진"
    }
    @State private var sourceMode: SourceMode = .selected

    // Resize
    enum ResizePreset: String, CaseIterable {
        case original = "원본"
        case px4000 = "4000px"
        case px3000 = "3000px"
        case px2000 = "2000px"
        case px1000 = "1000px"
        case px500 = "500px"
        case custom = "직접 입력"

        var longEdge: Int {
            switch self {
            case .original: return 0
            case .px4000: return 4000
            case .px3000: return 3000
            case .px2000: return 2000
            case .px1000: return 1000
            case .px500: return 500
            case .custom: return 0
            }
        }
    }
    @State private var resizePreset: ResizePreset = .original
    @State private var customWidth: String = "2000"
    @State private var customHeight: String = ""
    @State private var maintainAspect: Bool = true

    // Quality / Format
    @State private var jpegQuality: Double = 0.92
    @State private var outputFormat: BatchProcessService.OutputFormat = .jpeg

    // Watermark
    @State private var watermarkText: String = ""
    @State private var watermarkImageURL: URL? = nil
    @State private var watermarkPosition: BatchProcessService.WatermarkPosition = .bottomRight
    @State private var watermarkOpacity: Double = 0.5
    @State private var watermarkFontSize: CGFloat = 24
    @State private var watermarkImageScale: Double = 0.15

    // Destination
    @State private var destinationURL: URL?

    // Progress
    @State private var isProcessing = false
    @State private var processDone: Int = 0
    @State private var processTotal: Int = 0
    @State private var processStartTime: CFAbsoluteTime = 0
    @State private var cancelled = false
    @State private var resultMessage: String?

    private var sourcePhotos: [PhotoItem] {
        switch sourceMode {
        case .selected:
            let ids = store.selectedPhotoIDs
            return store.photos.filter { ids.contains($0.id) && !$0.isFolder && !$0.isParentFolder }
        case .filtered:
            return store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        case .all:
            return store.photos.filter { !$0.isFolder && !$0.isParentFolder }
        }
    }

    private var progressFraction: Double {
        guard processTotal > 0 else { return 0 }
        return Double(processDone) / Double(processTotal)
    }

    private var eta: String {
        guard processDone > 0, processTotal > processDone else { return "" }
        let elapsed = CFAbsoluteTimeGetCurrent() - processStartTime
        guard elapsed > 0.5 else { return "" }
        let rate = Double(processDone) / elapsed
        let remaining = Double(processTotal - processDone) / rate
        if remaining < 60 { return "\(Int(remaining))초 남음" }
        return "\(Int(remaining / 60))분 \(Int(remaining.truncatingRemainder(dividingBy: 60)))초 남음"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                Text("배치 처리")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Source section
                    sectionHeader("소스", icon: "photo.stack")
                    Picker("대상", selection: $sourceMode) {
                        ForEach(SourceMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("\(sourcePhotos.count)장")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)

                    Divider()

                    // Resize section
                    sectionHeader("리사이즈", icon: "arrow.up.left.and.arrow.down.right")
                    Picker("크기", selection: $resizePreset) {
                        ForEach(ResizePreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    if resizePreset == .custom {
                        HStack(spacing: 8) {
                            Text("긴 변:")
                                .font(.system(size: 12))
                            TextField("너비", text: $customWidth)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            Text("px")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }

                    Toggle("비율 유지", isOn: $maintainAspect)
                        .font(.system(size: 12))

                    Divider()

                    // Format section
                    sectionHeader("출력 형식", icon: "doc")
                    Picker("형식", selection: $outputFormat) {
                        ForEach(BatchProcessService.OutputFormat.allCases, id: \.self) { fmt in
                            Text(fmt.rawValue).tag(fmt)
                        }
                    }
                    .pickerStyle(.segmented)

                    if outputFormat == .jpeg {
                        HStack {
                            Text("JPEG 품질:")
                                .font(.system(size: 12))
                            Slider(value: $jpegQuality, in: 0.5...1.0, step: 0.01)
                            Text("\(Int(jpegQuality * 100))%")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .frame(width: 40)
                        }
                    }

                    if outputFormat == .tiff16 {
                        Text("RAW 파일이 있으면 16비트 깊이를 유지합니다")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Watermark section
                    sectionHeader("워터마크", icon: "textformat")
                    TextField("워터마크 텍스트 (비우면 생략)", text: $watermarkText)
                        .textFieldStyle(.roundedBorder)

                    if !watermarkText.isEmpty {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("위치")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Picker("위치", selection: $watermarkPosition) {
                                    ForEach(BatchProcessService.WatermarkPosition.allCases, id: \.self) { pos in
                                        Text(pos.rawValue).tag(pos)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 80)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("폰트 크기")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                HStack {
                                    Slider(value: $watermarkFontSize, in: 12...72, step: 1)
                                        .frame(width: 120)
                                    Text("\(Int(watermarkFontSize))pt")
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(width: 36)
                                }
                            }
                        }

                        HStack {
                            Text("불투명도:")
                                .font(.system(size: 12))
                            Slider(value: $watermarkOpacity, in: 0.1...1.0, step: 0.05)
                            Text("\(Int(watermarkOpacity * 100))%")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .frame(width: 40)
                        }
                    }

                    // 이미지 워터마크 (로고)
                    HStack {
                        Text("로고 이미지:")
                            .font(.system(size: 12))
                        if let url = watermarkImageURL {
                            Text(url.lastPathComponent)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Button("제거") { watermarkImageURL = nil }
                                .font(.system(size: 10))
                        }
                        Spacer()
                        Button("선택") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.png, .jpeg, .tiff]
                            panel.message = "워터마크로 사용할 로고 이미지를 선택하세요"
                            if panel.runModal() == .OK {
                                watermarkImageURL = panel.url
                            }
                        }
                        .font(.system(size: 11))
                    }

                    if watermarkImageURL != nil {
                        HStack {
                            Text("로고 크기:")
                                .font(.system(size: 12))
                            Slider(value: $watermarkImageScale, in: 0.05...0.4, step: 0.01)
                            Text("\(Int(watermarkImageScale * 100))%")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .frame(width: 40)
                        }
                    }

                    Divider()

                    // Destination section
                    sectionHeader("저장 위치", icon: "folder")
                    HStack {
                        if let url = destinationURL {
                            Text(url.lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(4)
                        } else {
                            Text("폴더를 선택하세요")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button("선택...") {
                            chooseDestination()
                        }
                        .controlSize(.small)
                    }

                    // Progress
                    if isProcessing {
                        Divider()
                        VStack(spacing: 8) {
                            ProgressView(value: progressFraction)
                                .progressViewStyle(.linear)

                            HStack {
                                Text("\(processDone) / \(processTotal)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                Spacer()
                                if !eta.isEmpty {
                                    Text(eta)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    // Result
                    if let msg = resultMessage {
                        Text(msg)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.green)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
                .padding()
            }

            Divider()

            // Footer buttons
            HStack {
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if isProcessing {
                    Button("중지") {
                        cancelled = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.regular)
                } else {
                    Button("시작") {
                        startProcessing()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(sourcePhotos.isEmpty || destinationURL == nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 480, height: 680)
        .onAppear {
            // Default source: if there's a selection, use it; otherwise filtered
            if store.selectedPhotoIDs.count > 1 {
                sourceMode = .selected
            } else {
                sourceMode = .filtered
            }
            // Default destination: same folder as source
            if let folderURL = store.folderURL {
                destinationURL = folderURL.appendingPathComponent("BatchOutput")
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.message = "배치 처리 결과를 저장할 폴더를 선택하세요"
        if let url = destinationURL {
            panel.directoryURL = url
        }
        if panel.runModal() == .OK, let url = panel.url {
            destinationURL = url
        }
    }

    private func startProcessing() {
        guard let dest = destinationURL else { return }
        let photos = sourcePhotos
        guard !photos.isEmpty else { return }

        // Create destination folder if needed
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        isProcessing = true
        cancelled = false
        processDone = 0
        processTotal = photos.count
        processStartTime = CFAbsoluteTimeGetCurrent()
        resultMessage = nil

        // Build options
        var opts = BatchProcessService.Options()
        if resizePreset == .custom {
            opts.targetWidth = Int(customWidth) ?? 0
        } else {
            opts.targetWidth = resizePreset.longEdge
        }
        opts.targetHeight = 0
        opts.maintainAspect = maintainAspect
        opts.quality = jpegQuality
        opts.format = outputFormat
        opts.watermarkText = watermarkText
        opts.watermarkImageURL = watermarkImageURL
        opts.watermarkPosition = watermarkPosition
        opts.watermarkOpacity = watermarkOpacity
        opts.watermarkFontSize = watermarkFontSize
        opts.watermarkImageScale = watermarkImageScale

        DispatchQueue.global(qos: .userInitiated).async {
            let result = BatchProcessService.process(
                photos: photos,
                options: opts,
                destination: dest,
                progress: { done, total in
                    self.processDone = done
                    self.processTotal = total
                },
                cancelled: { self.cancelled }
            )

            DispatchQueue.main.async {
                self.isProcessing = false
                let elapsed = CFAbsoluteTimeGetCurrent() - self.processStartTime
                let timeStr: String
                if elapsed < 60 {
                    timeStr = String(format: "%.1f초", elapsed)
                } else {
                    timeStr = String(format: "%d분 %d초", Int(elapsed) / 60, Int(elapsed) % 60)
                }
                self.resultMessage = "완료: \(result.success)장 성공, \(result.failed)장 실패 (\(timeStr))"
            }
        }
    }
}
