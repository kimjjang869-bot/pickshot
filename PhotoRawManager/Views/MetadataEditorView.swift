import SwiftUI

// MARK: - Metadata Editor View

struct MetadataEditorView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss

    // 편집 필드
    @State private var title: String = ""
    @State private var description: String = ""
    @State private var creator: String = ""
    @State private var copyright: String = ""
    @State private var keywords: String = ""    // 쉼표 구분
    @State private var usageTerms: String = ""
    @State private var instructions: String = ""
    @State private var city: String = ""
    @State private var country: String = ""
    @State private var event: String = ""

    // 배치 적용 시 필드 선택
    @State private var applyTitle = true
    @State private var applyDescription = true
    @State private var applyCreator = true
    @State private var applyCopyright = true
    @State private var applyKeywords = true
    @State private var applyUsageTerms = false
    @State private var applyInstructions = false
    @State private var applyCity = false
    @State private var applyCountry = false

    // 상태
    @State private var isSaving = false
    @State private var savedCount = 0
    @State private var showSavedAlert = false
    @State private var isLoading = true

    // 템플릿
    @State private var templates: [MetadataTemplate] = []
    @State private var selectedTemplateName: String = ""
    @State private var showSaveTemplate = false
    @State private var newTemplateName: String = ""

    let mode: EditorMode

    enum EditorMode {
        case single(PhotoItem)      // 개별 편집
        case batch([PhotoItem])     // 배치 적용
    }

    var targetPhotos: [PhotoItem] {
        switch mode {
        case .single(let photo): return [photo]
        case .batch(let photos): return photos
        }
    }

    var isBatch: Bool {
        if case .batch = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    // 템플릿 섹션
                    templateSection

                    // 기본 정보
                    GroupBox(label: Label("기본 정보", systemImage: "doc.text")) {
                        VStack(spacing: 8) {
                            MetadataField(label: "제목", text: $title, apply: isBatch ? $applyTitle : nil, placeholder: "사진 제목")
                            MetadataField(label: "설명", text: $description, apply: isBatch ? $applyDescription : nil, placeholder: "사진 설명 (캡션)", isMultiline: true)
                        }
                        .padding(.vertical, 4)
                    }

                    // 저작권
                    GroupBox(label: Label("저작권", systemImage: "c.circle")) {
                        VStack(spacing: 8) {
                            MetadataField(label: "작가", text: $creator, apply: isBatch ? $applyCreator : nil, placeholder: "촬영자 이름")
                            MetadataField(label: "저작권", text: $copyright, apply: isBatch ? $applyCopyright : nil, placeholder: "© 2026 작가 이름")
                            MetadataField(label: "사용조건", text: $usageTerms, apply: isBatch ? $applyUsageTerms : nil, placeholder: "사용 조건 (예: All Rights Reserved)")
                            MetadataField(label: "지시사항", text: $instructions, apply: isBatch ? $applyInstructions : nil, placeholder: "특별 지시사항")
                        }
                        .padding(.vertical, 4)
                    }

                    // 키워드
                    GroupBox(label: Label("키워드", systemImage: "tag")) {
                        VStack(alignment: .leading, spacing: 6) {
                            if isBatch {
                                HStack {
                                    Toggle("적용", isOn: $applyKeywords)
                                        .toggleStyle(.checkbox)
                                        .font(.system(size: 11))
                                    Spacer()
                                }
                            }

                            TextField("키워드 (쉼표로 구분)", text: $keywords)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))

                            // 현재 키워드 태그 표시
                            let keywordArray = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            if !keywordArray.isEmpty {
                                FlowLayout(spacing: 4) {
                                    ForEach(keywordArray, id: \.self) { kw in
                                        HStack(spacing: 2) {
                                            Text(kw)
                                                .font(.system(size: 10, weight: .medium))
                                            Image(systemName: "xmark")
                                                .font(.system(size: 7, weight: .bold))
                                                .onTapGesture {
                                                    removeKeyword(kw)
                                                }
                                        }
                                        .foregroundColor(.teal)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.teal.opacity(0.12))
                                        .cornerRadius(4)
                                    }
                                }
                            }

                            // 자동 생성 키워드 (Vision)
                            if !isBatch, let photo = targetPhotos.first, !photo.keywords.isEmpty {
                                Divider()
                                HStack {
                                    Text("자동 생성 키워드")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button("모두 추가") {
                                        let existing = Set(keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                                        let newKW = photo.keywords.filter { !existing.contains($0) }
                                        if !newKW.isEmpty {
                                            if keywords.isEmpty {
                                                keywords = newKW.joined(separator: ", ")
                                            } else {
                                                keywords += ", " + newKW.joined(separator: ", ")
                                            }
                                        }
                                    }
                                    .font(.system(size: 10))
                                    .buttonStyle(.link)
                                }
                                FlowLayout(spacing: 4) {
                                    ForEach(photo.keywords, id: \.self) { kw in
                                        Text(kw)
                                            .font(.system(size: 10))
                                            .foregroundColor(.purple)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.purple.opacity(0.1))
                                            .cornerRadius(3)
                                            .onTapGesture {
                                                addKeyword(kw)
                                            }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // 촬영 위치
                    GroupBox(label: Label("위치", systemImage: "location")) {
                        VStack(spacing: 8) {
                            MetadataField(label: "도시", text: $city, apply: isBatch ? $applyCity : nil, placeholder: "서울")
                            MetadataField(label: "국가", text: $country, apply: isBatch ? $applyCountry : nil, placeholder: "대한민국")
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 520, height: 680)
        .onAppear { loadMetadata(); loadTemplates() }
        .sheet(isPresented: $showSaveTemplate) {
            saveTemplateSheet
        }
        .alert("메타데이터 저장 완료", isPresented: $showSavedAlert) {
            Button("확인") { dismiss() }
        } message: {
            Text("\(savedCount)개 파일에 메타데이터가 저장되었습니다.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "doc.badge.gearshape")
                .foregroundColor(.accentColor)
            if isBatch {
                Text("메타데이터 배치 편집")
                    .font(.headline)
                Text("(\(targetPhotos.count)장)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("메타데이터 편집")
                    .font(.headline)
                if let photo = targetPhotos.first {
                    Text("— \(photo.fileNameWithExtension)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Template Section

    private var templateSection: some View {
        GroupBox(label: Label("템플릿", systemImage: "rectangle.stack")) {
            HStack {
                Picker("", selection: $selectedTemplateName) {
                    Text("선택...").tag("")
                    ForEach(templates, id: \.name) { t in
                        Text(t.name).tag(t.name)
                    }
                }
                .frame(maxWidth: .infinity)
                .onChange(of: selectedTemplateName) { _, name in
                    if let t = templates.first(where: { $0.name == name }) {
                        applyTemplate(t)
                    }
                }

                Button("저장") {
                    showSaveTemplate = true
                }
                .disabled(creator.isEmpty && copyright.isEmpty)

                Button("삭제") {
                    deleteTemplate(selectedTemplateName)
                }
                .disabled(selectedTemplateName.isEmpty)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if isBatch {
                let activeFields = countActiveFields()
                Text("\(activeFields)개 필드 → \(targetPhotos.count)장에 적용")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("취소") { dismiss() }
                .keyboardShortcut(.escape)

            Button(action: save) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isBatch ? "일괄 적용 (\(targetPhotos.count)장)" : "저장")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
        }
        .padding()
    }

    // MARK: - Save Template Sheet

    private var saveTemplateSheet: some View {
        VStack(spacing: 16) {
            Text("템플릿 저장")
                .font(.headline)

            TextField("템플릿 이름", text: $newTemplateName)
                .textFieldStyle(.roundedBorder)

            Text("작가, 저작권, 사용조건이 저장됩니다.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button("취소") { showSaveTemplate = false }
                Spacer()
                Button("저장") {
                    saveTemplate()
                    showSaveTemplate = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newTemplateName.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }

    // MARK: - Logic

    private func loadMetadata() {
        guard let photo = targetPhotos.first else { return }
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let meta = XMPService.readIPTCMetadata(from: photo.jpgURL) ?? XMPService.IPTCMetadata()

            DispatchQueue.main.async {
                title = meta.title
                description = meta.description
                creator = meta.creator
                copyright = meta.copyright
                keywords = meta.keywords.joined(separator: ", ")
                usageTerms = meta.usageTerms
                instructions = meta.instructions
                city = meta.city
                country = meta.country

                // PhotoItem 필드로 보완
                if title.isEmpty { title = photo.iptcTitle }
                if description.isEmpty { description = photo.iptcDescription }
                if creator.isEmpty { creator = photo.iptcCreator }
                if copyright.isEmpty { copyright = photo.iptcCopyright }
                if city.isEmpty { city = photo.iptcCity }
                if country.isEmpty { country = photo.iptcCountry }

                isLoading = false
            }
        }
    }

    private func save() {
        isSaving = true
        let keywordArray = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let meta = XMPService.IPTCMetadata(
            title: title, description: description, creator: creator,
            copyright: copyright, keywords: keywordArray, usageTerms: usageTerms,
            instructions: instructions, city: city, country: country, event: event
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let count: Int
            if isBatch {
                var fields = Set<String>()
                if applyTitle { fields.insert("title") }
                if applyDescription { fields.insert("description") }
                if applyCreator { fields.insert("creator") }
                if applyCopyright { fields.insert("copyright") }
                if applyKeywords { fields.insert("keywords") }
                if applyUsageTerms { fields.insert("usageTerms") }
                if applyInstructions { fields.insert("instructions") }
                if applyCity { fields.insert("city") }
                if applyCountry { fields.insert("country") }
                count = XMPService.batchWriteIPTC(photos: targetPhotos, metadata: meta, fieldsToApply: fields)
            } else {
                count = XMPService.writeIPTCMetadata(url: targetPhotos[0].jpgURL, metadata: meta) ? 1 : 0
            }

            DispatchQueue.main.async {
                isSaving = false
                savedCount = count
                // PhotoItem 업데이트
                updatePhotoItems(meta: meta, keywordArray: keywordArray)
                showSavedAlert = true
            }
        }
    }

    private func updatePhotoItems(meta: XMPService.IPTCMetadata, keywordArray: [String]) {
        for photo in targetPhotos {
            if let idx = store.photos.firstIndex(where: { $0.id == photo.id }) {
                if !isBatch || applyTitle { store.photos[idx].iptcTitle = meta.title }
                if !isBatch || applyDescription { store.photos[idx].iptcDescription = meta.description }
                if !isBatch || applyCreator { store.photos[idx].iptcCreator = meta.creator }
                if !isBatch || applyCopyright { store.photos[idx].iptcCopyright = meta.copyright }
                if !isBatch || applyKeywords { store.photos[idx].keywords = keywordArray }
                if !isBatch || applyCity { store.photos[idx].iptcCity = meta.city }
                if !isBatch || applyCountry { store.photos[idx].iptcCountry = meta.country }
            }
        }
        store.invalidateFilterCache()
    }

    private func removeKeyword(_ kw: String) {
        var arr = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        arr.removeAll { $0 == kw }
        keywords = arr.joined(separator: ", ")
    }

    private func addKeyword(_ kw: String) {
        let existing = Set(keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        if !existing.contains(kw) {
            keywords = keywords.isEmpty ? kw : keywords + ", " + kw
        }
    }

    private func countActiveFields() -> Int {
        var c = 0
        if applyTitle { c += 1 }
        if applyDescription { c += 1 }
        if applyCreator { c += 1 }
        if applyCopyright { c += 1 }
        if applyKeywords { c += 1 }
        if applyUsageTerms { c += 1 }
        if applyInstructions { c += 1 }
        if applyCity { c += 1 }
        if applyCountry { c += 1 }
        return c
    }

    // MARK: - Templates

    private static let templateKey = "metadataTemplates"

    private func loadTemplates() {
        guard let data = UserDefaults.standard.data(forKey: Self.templateKey),
              let saved = try? JSONDecoder().decode([MetadataTemplate].self, from: data) else { return }
        templates = saved
    }

    private func saveTemplate() {
        let t = MetadataTemplate(
            name: newTemplateName,
            creator: creator, copyright: copyright,
            usageTerms: usageTerms, instructions: instructions,
            city: city, country: country
        )
        templates.removeAll { $0.name == newTemplateName }
        templates.append(t)
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: Self.templateKey)
        }
        selectedTemplateName = newTemplateName
        newTemplateName = ""
    }

    private func deleteTemplate(_ name: String) {
        templates.removeAll { $0.name == name }
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: Self.templateKey)
        }
        selectedTemplateName = ""
    }

    private func applyTemplate(_ t: MetadataTemplate) {
        creator = t.creator
        copyright = t.copyright
        usageTerms = t.usageTerms
        instructions = t.instructions
        if !t.city.isEmpty { city = t.city }
        if !t.country.isEmpty { country = t.country }
    }
}

// MARK: - MetadataField

struct MetadataField: View {
    let label: String
    @Binding var text: String
    var apply: Binding<Bool>?
    var placeholder: String = ""
    var isMultiline: Bool = false

    var body: some View {
        HStack(alignment: isMultiline ? .top : .center, spacing: 6) {
            if let apply = apply {
                Toggle("", isOn: apply)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .trailing)

            if isMultiline {
                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .frame(height: 50)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3))
                    )
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 12))
                                .foregroundColor(.gray.opacity(0.5))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }
}

// MARK: - Metadata Template

struct MetadataTemplate: Codable, Identifiable {
    var id: String { name }
    let name: String
    var creator: String = ""
    var copyright: String = ""
    var usageTerms: String = ""
    var instructions: String = ""
    var city: String = ""
    var country: String = ""
}

// MARK: - Sheet Wrapper (컴파일러 타입체크 분리)

struct MetadataEditorSheet: View {
    @ObservedObject var store: PhotoStore

    var body: some View {
        MetadataEditorView(mode: resolveMode())
            .environmentObject(store)
    }

    private func resolveMode() -> MetadataEditorView.EditorMode {
        switch store.metadataEditorMode {
        case .batch:
            let selected = store.selectedPhotoIDs.compactMap { id -> PhotoItem? in
                guard let idx = store._photoIndex[id], idx < store.photos.count else { return nil }
                return store.photos[idx]
            }.filter { !$0.isFolder && !$0.isParentFolder }
            if selected.isEmpty, let photo = store.selectedPhoto {
                return .single(photo)
            }
            return .batch(selected)
        case .single:
            if let photo = store.selectedPhoto {
                return .single(photo)
            }
            return .batch([])
        }
    }
}
