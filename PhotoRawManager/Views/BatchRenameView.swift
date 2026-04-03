import SwiftUI

// MARK: - Rename Component Types

enum RenameComponent: String, CaseIterable, Identifiable {
    case text = "텍스트"
    case sequence = "파일 번호"
    case date = "촬영 날짜"
    case original = "원본 파일명"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .text: return "textformat"
        case .sequence: return "number"
        case .date: return "calendar"
        case .original: return "doc"
        }
    }
}

enum DateFormatOption: String, CaseIterable, Identifiable {
    case yyyymmdd = "YYYYMMDD"
    case dashSeparated = "YYYY-MM-DD"
    case yymmdd = "YYMMDD"
    case dotSeparated = "YYYY.MM.DD"

    var id: String { rawValue }

    var dateFormat: String {
        switch self {
        case .yyyymmdd: return "yyyyMMdd"
        case .dashSeparated: return "yyyy-MM-dd"
        case .yymmdd: return "yyMMdd"
        case .dotSeparated: return "yyyy.MM.dd"
        }
    }

    var example: String {
        switch self {
        case .yyyymmdd: return "20260322"
        case .dashSeparated: return "2026-03-22"
        case .yymmdd: return "260322"
        case .dotSeparated: return "2026.03.22"
        }
    }
}

enum SeparatorOption: String, CaseIterable, Identifiable {
    case underscore = "_"
    case dash = "-"
    case dot = "."
    case none = ""

    var id: String { rawValue + "sep" }

    var displayName: String {
        switch self {
        case .underscore: return "_ (언더스코어)"
        case .dash: return "- (대시)"
        case .dot: return ". (점)"
        case .none: return "없음"
        }
    }
}

enum RenameTarget: String, CaseIterable, Identifiable {
    case selected = "선택한 사진만"
    case all = "전체 사진"

    var id: String { rawValue }
}

struct RenamePreset: Identifiable {
    let id = UUID()
    let name: String
    let components: [RenameComponent]
    let separator: SeparatorOption
    let example: String
}

struct RenameComponentItem: Identifiable {
    let id = UUID()
    var type: RenameComponent
    var textValue: String = ""
}

// MARK: - BatchRenameView

struct BatchRenameView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss

    @State private var components: [RenameComponentItem] = [
        RenameComponentItem(type: .text, textValue: ""),
        RenameComponentItem(type: .sequence)
    ]
    @State private var separator: SeparatorOption = .underscore
    @State private var dateFormat: DateFormatOption = .yyyymmdd
    @State private var seqStart: Int = 1
    @State private var seqDigits: Int = 3
    @State private var target: RenameTarget = .selected
    @State private var isRenaming = false
    @State private var resultMessage: String?
    @State private var resultIsError = false

    private let presets: [RenamePreset] = [
        RenamePreset(name: "텍스트 + 번호", components: [.text, .sequence], separator: .underscore, example: "행사_001"),
        RenamePreset(name: "날짜 + 텍스트 + 번호", components: [.date, .text, .sequence], separator: .underscore, example: "20260322_행사_001"),
        RenamePreset(name: "날짜 + 번호", components: [.date, .sequence], separator: .underscore, example: "20260322_001"),
        RenamePreset(name: "원본 + 번호", components: [.original, .sequence], separator: .dash, example: "IMG_0001-001"),
        RenamePreset(name: "텍스트 + 날짜 + 번호", components: [.text, .date, .sequence], separator: .underscore, example: "촬영_20260322_001"),
    ]

    private var targetPhotos: [PhotoItem] {
        switch target {
        case .selected:
            if store.selectedPhotoIDs.count > 1 {
                return store.filteredPhotos.filter { store.selectedPhotoIDs.contains($0.id) }
            }
            return store.filteredPhotos
        case .all:
            return store.filteredPhotos
        }
    }

    private var builtPattern: String {
        let parts = components.map { comp -> String in
            switch comp.type {
            case .text: return comp.textValue
            case .sequence: return "{seq}"
            case .date: return "{date}"
            case .original: return "{original}"
            }
        }
        return parts.joined(separator: separator.rawValue)
    }

    private var previewItems: [(original: String, renamed: String)] {
        let photos = Array(targetPhotos.prefix(4))
        return photos.enumerated().map { (index, photo) in
            let newName = PhotoStore.previewRename(
                photo: photo,
                pattern: builtPattern,
                index: index,
                dateFormat: dateFormat.dateFormat,
                seqDigits: seqDigits,
                seqStart: seqStart
            )
            let ext = photo.jpgURL.pathExtension
            return (original: photo.fileName + "." + ext, renamed: newName + "." + ext)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            contentSection
            Divider()
            previewSection
            if let msg = resultMessage {
                resultSection(msg)
            }
            Divider()
            footerSection
        }
        .frame(minWidth: 750, idealWidth: 850, minHeight: 600, idealHeight: 700)
        .onAppear { target = store.selectedPhotoIDs.count > 1 ? .selected : .all }
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack {
            Image(systemName: "pencil.and.list.clipboard")
                    .font(.system(size: 14))
                    .foregroundColor(.blue)
                Text("파일 이름 변경")
                    .font(.system(size: 14, weight: .bold))
                Spacer()

                // Target + count
                Picker("", selection: $target) {
                    ForEach(RenameTarget.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)

                Text("\(targetPhotos.count)장")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    // MARK: - Content
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Preset + Component builder side by side
                HStack(alignment: .top, spacing: 12) {
                    // Left: Component builder
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("이름 구성")
                                .font(.system(size: 11, weight: .bold))
                            Spacer()

                            // Preset dropdown
                            Menu {
                                ForEach(presets) { preset in
                                    Button(action: { applyPreset(preset) }) {
                                        Text("\(preset.name)  →  \(preset.example)")
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 9))
                                    Text("프리셋")
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(.blue)
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 70)
                        }

                        List {
                            ForEach(components) { comp in
                                RenameComponentRow(
                                    comp: comp,
                                    components: $components,
                                    dateFormat: dateFormat,
                                    seqDigits: seqDigits,
                                    seqStart: seqStart
                                )
                            }
                            .onMove { from, to in
                                components.move(fromOffsets: from, toOffset: to)
                            }
                        }
                        .listStyle(.plain)
                        .frame(height: CGFloat(min(components.count, 5)) * 42 + 4)

                        // Add component
                        if components.count < 5 {
                            Menu {
                                ForEach(RenameComponent.allCases) { type in
                                    Button { components.append(RenameComponentItem(type: type)) } label: {
                                        Label(type.rawValue, systemImage: type.icon)
                                    }
                                }
                            } label: {
                                Label("추가", systemImage: "plus.circle")
                                    .font(.system(size: 10))
                                    .foregroundColor(.blue)
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }

                    Divider()

                    // Right: Options
                    VStack(alignment: .leading, spacing: 8) {
                        Text("옵션")
                            .font(.system(size: 11, weight: .bold))

                        // Separator
                        HStack(spacing: 4) {
                            Text("구분자")
                                .font(.system(size: 10))
                                .frame(width: 45, alignment: .leading)
                            Picker("", selection: $separator) {
                                ForEach(SeparatorOption.allCases) { opt in
                                    Text(opt.displayName).tag(opt)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }

                        // Date format
                        if components.contains(where: { $0.type == .date }) {
                            HStack(spacing: 4) {
                                Text("날짜")
                                    .font(.system(size: 10))
                                    .frame(width: 45, alignment: .leading)
                                Picker("", selection: $dateFormat) {
                                    ForEach(DateFormatOption.allCases) { opt in
                                        Text(opt.rawValue).tag(opt)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 120)
                            }
                        }

                        // Sequence options
                        if components.contains(where: { $0.type == .sequence }) {
                            HStack(spacing: 4) {
                                Text("시작")
                                    .font(.system(size: 10))
                                    .frame(width: 45, alignment: .leading)
                                TextField("", value: $seqStart, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 45)
                                    .font(.system(size: 10, design: .monospaced))

                                Text("자릿수")
                                    .font(.system(size: 10))
                                Picker("", selection: $seqDigits) {
                                    Text("01").tag(2)
                                    Text("001").tag(3)
                                    Text("0001").tag(4)
                                }
                                .labelsHidden()
                                .frame(width: 65)
                            }
                        }
                    }
                    .frame(width: 190)
                }

            }
            .padding(14)
    }

    // MARK: - Preview
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("미리보기")
                            .font(.system(size: 11, weight: .bold))
                        Spacer()
                        Text(builtPattern)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if previewItems.isEmpty {
                        Text("미리보기할 사진이 없습니다")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(6)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(previewItems.enumerated()), id: \.offset) { _, item in
                                HStack(spacing: 0) {
                                    Text(item.original)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.4))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.blue)
                                        .frame(width: 24)

                                    Text(item.renamed)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(.blue)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                            }

                            if targetPhotos.count > 4 {
                                Text("... 외 \(targetPhotos.count - 4)개")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .padding(4)
                            }
                        }
                        .background(Color.black.opacity(0.15))
                        .cornerRadius(6)
                    }
                }
            .padding(14)
    }

    // MARK: - Result
    private func resultSection(_ msg: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(resultIsError ? .red : .green)
            Text(msg)
                .font(.system(size: 10))
                .foregroundColor(resultIsError ? .red : .green)
        }
        .padding(6)
        .background((resultIsError ? Color.red : Color.green).opacity(0.1))
        .cornerRadius(5)
        .padding(.horizontal, 14)
    }

    // MARK: - Footer
    private var footerSection: some View {
        HStack {
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("⚠️ 되돌릴 수 없음")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                Spacer()
                Button(action: performRename) {
                    HStack(spacing: 3) {
                        if isRenaming { ProgressView().scaleEffect(0.5) }
                        Text("이름 변경 (\(targetPhotos.count)장)")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(builtPattern.trimmingCharacters(in: .whitespaces).isEmpty || isRenaming)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
    }

    // MARK: - Helpers

    private func componentDescription(_ type: RenameComponent) -> String {
        switch type {
        case .text: return ""
        case .sequence: return "\(String(repeating: "0", count: seqDigits - 1))\(seqStart)~"
        case .date: return dateFormat.example
        case .original: return "원본 유지"
        }
    }

    private func moveComponent(_ index: Int, by offset: Int) {
        let newIndex = index + offset
        guard newIndex >= 0 && newIndex < components.count else { return }
        components.swapAt(index, newIndex)
    }

    private func applyPreset(_ preset: RenamePreset) {
        components = preset.components.map { type in
            RenameComponentItem(type: type)
        }
        separator = preset.separator
    }

    private func performRename() {
        isRenaming = true
        resultMessage = nil
        let pat = builtPattern
        let df = dateFormat.dateFormat
        let digits = seqDigits
        let start = seqStart

        DispatchQueue.global(qos: .userInitiated).async {
            let result = store.batchRename(pattern: pat, dateFormat: df, seqDigits: digits, seqStart: start)
            DispatchQueue.main.async {
                isRenaming = false
                if result.errors.isEmpty {
                    resultMessage = "✅ \(result.success)개 파일 이름 변경 완료"
                    resultIsError = false
                } else {
                    resultMessage = "성공: \(result.success)개, 실패: \(result.errors.count)개"
                    resultIsError = true
                }
            }
        }
    }
}

// MARK: - Rename Component Row (Draggable)

struct RenameComponentRow: View {
    let comp: RenameComponentItem
    @Binding var components: [RenameComponentItem]
    let dateFormat: DateFormatOption
    let seqDigits: Int
    let seqStart: Int

    private var index: Int {
        components.firstIndex(where: { $0.id == comp.id }) ?? 0
    }

    var body: some View {
        HStack(spacing: 8) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.4))

            // Type picker
            Picker("", selection: Binding(
                get: { comp.type },
                set: { newType in
                    let i = index
                    components[i].type = newType
                    if newType != .text { components[i].textValue = "" }
                }
            )) {
                ForEach(RenameComponent.allCases) { type in
                    Label(type.rawValue, systemImage: type.icon).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            // Value
            if comp.type == .text {
                TextField("텍스트 입력", text: Binding(
                    get: { comp.textValue },
                    set: { components[index].textValue = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            } else if comp.type == .sequence {
                Text(String(format: "%0\(seqDigits)d~", seqStart))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if comp.type == .date {
                Text(dateFormat.example)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("원본 유지")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Remove
            if components.count > 1 {
                Button(action: {
                    let i = index
                    withAnimation { _ = components.remove(at: i) }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.red.opacity(0.6))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}
