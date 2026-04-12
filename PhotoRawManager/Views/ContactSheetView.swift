import SwiftUI
import PDFKit

// MARK: - Contact Sheet View

struct ContactSheetView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss

    @State private var columns = 4
    @State private var rows = 5
    @State private var pageSizeIndex = 0    // A4 세로
    @State private var showFilename = true
    @State private var showRating = true
    @State private var showExif = false
    @State private var headerText = ""
    @State private var footerText = ""

    @State private var isGenerating = false
    @State private var progress: Double = 0
    @State private var generatedPDF: Data?
    @State private var previewPDF: PDFDocument?

    var targetPhotos: [PhotoItem] {
        let selected = store.selectedPhotoIDs.compactMap { id in
            store._photoIndex[id].flatMap { idx in idx < store.photos.count ? store.photos[idx] : nil }
        }.filter { !$0.isFolder && !$0.isParentFolder }

        if selected.isEmpty {
            return store.photos.filter { !$0.isFolder && !$0.isParentFolder }
        }
        return selected
    }

    var body: some View {
        HSplitView {
            // Left: Settings
            settingsPanel
                .frame(minWidth: 250, maxWidth: 300)

            // Right: Preview
            previewPanel
                .frame(minWidth: 400)
        }
        .frame(width: 900, height: 650)
        .onAppear {
            // 기본 헤더: 폴더명
            if headerText.isEmpty {
                headerText = store.folderURL?.lastPathComponent ?? "PickShot Contact Sheet"
            }
        }
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Header
                HStack {
                    Image(systemName: "tablecells")
                        .foregroundColor(.accentColor)
                    Text("컨택트시트")
                        .font(.headline)
                    Spacer()
                }

                GroupBox(label: Label("페이지 설정", systemImage: "doc")) {
                    VStack(spacing: 8) {
                        Picker("용지 크기", selection: $pageSizeIndex) {
                            ForEach(0..<ContactSheetService.pageSizes.count, id: \.self) { i in
                                Text(ContactSheetService.pageSizes[i].name).tag(i)
                            }
                        }

                        HStack {
                            Text("열")
                                .font(.system(size: 11))
                                .frame(width: 40, alignment: .trailing)
                            Stepper(value: $columns, in: 2...8) {
                                Text("\(columns)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                            }
                        }

                        HStack {
                            Text("행")
                                .font(.system(size: 11))
                                .frame(width: 40, alignment: .trailing)
                            Stepper(value: $rows, in: 2...10) {
                                Text("\(rows)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                            }
                        }

                        let photosPerPage = columns * rows
                        let totalPages = max(1, Int(ceil(Double(targetPhotos.count) / Double(photosPerPage))))
                        HStack {
                            Spacer()
                            Text("\(targetPhotos.count)장 → \(totalPages)페이지")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox(label: Label("표시 항목", systemImage: "text.below.photo")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("파일명", isOn: $showFilename)
                        Toggle("별점", isOn: $showRating)
                        Toggle("EXIF 정보 (ISO, 셔터, 조리개)", isOn: $showExif)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .padding(.vertical, 4)
                }

                GroupBox(label: Label("머리글/바닥글", systemImage: "text.alignleft")) {
                    VStack(spacing: 8) {
                        HStack {
                            Text("제목")
                                .font(.system(size: 11))
                                .frame(width: 40, alignment: .trailing)
                            TextField("컨택트시트 제목", text: $headerText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        HStack {
                            Text("바닥글")
                                .font(.system(size: 11))
                                .frame(width: 40, alignment: .trailing)
                            TextField("작가명, 연락처 등", text: $footerText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                    }
                    .padding(.vertical, 4)
                }

                Spacer()

                // Buttons
                HStack {
                    Button("미리보기") {
                        generatePreview()
                    }
                    .disabled(isGenerating)

                    Spacer()

                    Button("취소") { dismiss() }
                        .keyboardShortcut(.escape)

                    Button(action: exportPDF) {
                        if isGenerating {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("PDF 저장", systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding()
        }
    }

    // MARK: - Preview Panel

    private var previewPanel: some View {
        VStack {
            if let doc = previewPDF {
                PDFKitView(document: doc)
            } else if isGenerating {
                VStack(spacing: 12) {
                    ProgressView(value: progress)
                        .frame(width: 200)
                    Text("PDF 생성 중...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("미리보기를 클릭하세요")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))

                    // 간단한 레이아웃 미리보기
                    let pageSize = ContactSheetService.pageSizes[pageSizeIndex].size
                    let aspectRatio = pageSize.width / pageSize.height
                    let previewW: CGFloat = 200
                    let previewH = previewW / aspectRatio

                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white)
                            .frame(width: previewW, height: previewH)
                            .shadow(radius: 2)

                        // Grid preview
                        VStack(spacing: 2) {
                            ForEach(0..<min(rows, 6), id: \.self) { _ in
                                HStack(spacing: 2) {
                                    ForEach(0..<min(columns, 6), id: \.self) { _ in
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.3))
                                            .aspectRatio(1.5, contentMode: .fit)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .frame(width: previewW, height: previewH)
                    }
                    .padding(.top, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.1))
    }

    // MARK: - Logic

    private func buildOptions() -> ContactSheetService.Options {
        ContactSheetService.Options(
            columns: columns,
            rows: rows,
            pageSize: ContactSheetService.pageSizes[pageSizeIndex].size,
            margin: 30,
            spacing: 8,
            showFilename: showFilename,
            showRating: showRating,
            showExif: showExif,
            headerText: headerText,
            footerText: footerText
        )
    }

    private func generatePreview() {
        isGenerating = true
        progress = 0
        let photos = targetPhotos
        let opts = buildOptions()

        DispatchQueue.global(qos: .userInitiated).async {
            let data = ContactSheetService.generatePDF(photos: photos, options: opts) { current, total in
                DispatchQueue.main.async {
                    progress = Double(current) / Double(max(1, total))
                }
            }

            DispatchQueue.main.async {
                isGenerating = false
                if let data = data {
                    generatedPDF = data
                    previewPDF = PDFDocument(data: data)
                }
            }
        }
    }

    private func exportPDF() {
        isGenerating = true
        progress = 0
        let photos = targetPhotos
        let opts = buildOptions()

        DispatchQueue.global(qos: .userInitiated).async {
            let data = ContactSheetService.generatePDF(photos: photos, options: opts) { current, total in
                DispatchQueue.main.async {
                    progress = Double(current) / Double(max(1, total))
                }
            }

            DispatchQueue.main.async {
                isGenerating = false
                guard let pdfData = data else {
                    store.showToastMessage("PDF 생성 실패")
                    return
                }

                generatedPDF = pdfData
                previewPDF = PDFDocument(data: pdfData)

                // Save dialog
                let panel = NSSavePanel()
                panel.title = "컨택트시트 PDF 저장"
                panel.allowedContentTypes = [.pdf]
                panel.nameFieldStringValue = "\(store.folderURL?.lastPathComponent ?? "ContactSheet").pdf"

                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        try pdfData.write(to: url, options: .atomic)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        store.showToastMessage("PDF 저장 완료 → \(url.lastPathComponent)")
                    } catch {
                        store.showToastMessage("PDF 저장 실패: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

// MARK: - PDFKit SwiftUI Wrapper

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
        }
    }
}
