import SwiftUI

// MARK: - Rename Types

enum RenameComponent: String, CaseIterable, Identifiable {
    case text = "텍스트"
    case sequence = "시퀀스 번호"
    case date = "촬영 날짜"
    case original = "원본 파일명"
    case camera = "카메라 모델"
    var id: String { rawValue }
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

struct RenameComponentItem: Identifiable {
    let id = UUID()
    var type: RenameComponent
    var textValue: String = ""
}

// MARK: - BatchRenameView (Capture One 스타일)

struct BatchRenameView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss

    @State private var components: [RenameComponentItem] = [
        RenameComponentItem(type: .sequence),
        RenameComponentItem(type: .text, textValue: "")
    ]
    @State private var separator: SeparatorOption = .underscore
    @State private var dateFormat: DateFormatOption = .yyyymmdd
    @State private var seqStart: Int = 1
    @State private var seqDigits: Int = 4
    @State private var target: RenameTarget = .selected
    @State private var preserveRatings = true
    @State private var isRenaming = false
    @State private var resultMessage: String?
    @State private var resultIsError = false
    @State private var canUndo = false

    private var targetPhotos: [PhotoItem] {
        let photos = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        switch target {
        case .selected:
            if store.selectedPhotoIDs.count > 1 {
                return photos.filter { store.selectedPhotoIDs.contains($0.id) }
            }
            return photos
        case .all:
            return photos
        }
    }

    private var builtPattern: String {
        let parts = components.map { comp -> String in
            switch comp.type {
            case .text: return comp.textValue
            case .sequence: return "{seq}"
            case .date: return "{date}"
            case .original: return "{original}"
            case .camera: return "{camera}"
            }
        }.filter { !$0.isEmpty }
        return parts.joined(separator: separator.rawValue)
    }

    private var previewItems: [(original: String, renamed: String)] {
        Array(targetPhotos.prefix(5)).enumerated().map { (index, photo) in
            let newName = PhotoStore.previewRename(
                photo: photo, pattern: builtPattern, index: index,
                dateFormat: dateFormat.dateFormat, seqDigits: seqDigits, seqStart: seqStart
            )
            let ext = photo.jpgURL.pathExtension
            return (photo.fileNameWithExtension, newName + "." + ext)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 타이틀 바
            HStack {
                Text("일괄 이름 바꾸기")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))

            ScrollView {
                VStack(spacing: 12) {
                    presetSection
                    nameBuilderSection
                    optionsSection
                    previewSection
                }
                .padding(16)
            }

            Divider()
            footerSection
        }
        .frame(width: 620, height: 580)
        .onAppear { target = store.selectedPhotoIDs.count > 1 ? .selected : .all }
    }

    // MARK: - 사전 설정

    private var presetSection: some View {
        GroupBox(label: sectionLabel("사전 설정")) {
            HStack(spacing: 8) {
                Menu {
                    Button("텍스트 + 번호") { applyPreset([.text, .sequence], .underscore) }
                    Button("번호 + 텍스트") { applyPreset([.sequence, .text], .underscore) }
                    Divider()
                    Button("날짜 + 번호") { applyPreset([.date, .sequence], .underscore) }
                    Button("날짜 + 텍스트 + 번호") { applyPreset([.date, .text, .sequence], .underscore) }
                    Divider()
                    Button("원본 + 번호") { applyPreset([.original, .sequence], .dash) }
                } label: {
                    HStack {
                        Text("프리셋 선택")
                            .font(.system(size: 11))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(5)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity)

                // 대상 선택
                Picker("", selection: $target) {
                    ForEach(RenameTarget.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Text("\(targetPhotos.count)장")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(4)
            }
        }
    }

    // MARK: - 새 파일 이름

    @State private var draggingCompID: UUID?
    @State private var dropInsertIndex: Int?

    private var nameBuilderSection: some View {
        GroupBox(label: sectionLabel("새 파일 이름")) {
            VStack(spacing: 0) {
                ForEach(Array(components.enumerated()), id: \.element.id) { idx, comp in
                    VStack(spacing: 0) {
                        // 드롭 인디케이터 (행 위)
                        if dropInsertIndex == idx {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(height: 3)
                                .cornerRadius(1.5)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                        }

                        componentRow(comp: comp, index: idx)
                            .opacity(draggingCompID == comp.id ? 0.3 : 1.0)
                            .onDrag {
                                draggingCompID = comp.id
                                return NSItemProvider(object: comp.id.uuidString as NSString)
                            }
                            .onDrop(of: [.utf8PlainText], delegate: CompReorderDropDelegate(
                                targetID: comp.id, components: $components,
                                draggingID: $draggingCompID, dropInsertIndex: $dropInsertIndex
                            ))
                    }
                }
                // 마지막 행 아래 드롭 인디케이터
                if dropInsertIndex == components.count {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .cornerRadius(1.5)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                }

                HStack {
                    // 구분자
                    HStack(spacing: 6) {
                        Text("구분자")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Picker("", selection: $separator) {
                            ForEach(SeparatorOption.allCases) { opt in
                                Text(opt.displayName).tag(opt)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }

                    Spacer()

                    // 추가 버튼
                    if components.count < 5 {
                        Menu {
                            ForEach(RenameComponent.allCases) { type in
                                Button(type.rawValue) {
                                    components.append(RenameComponentItem(type: type))
                                }
                            }
                        } label: {
                            Label("추가", systemImage: "plus")
                                .font(.system(size: 10))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 60)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func componentRow(comp: RenameComponentItem, index: Int) -> some View {
        HStack(spacing: 6) {
            // 드래그 핸들
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.5))
                .frame(width: 14)

            // 타입 선택
            Picker("", selection: Binding(
                get: { comp.type },
                set: { newType in
                    components[index].type = newType
                    if newType != .text { components[index].textValue = "" }
                }
            )) {
                ForEach(RenameComponent.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            // 값 입력
            switch comp.type {
            case .text:
                TextField("텍스트 입력", text: Binding(
                    get: { comp.textValue },
                    set: { components[index].textValue = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))

            case .sequence:
                HStack(spacing: 6) {
                    TextField("", value: Binding(
                        get: { seqStart },
                        set: { seqStart = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.system(size: 11, design: .monospaced))

                    Picker("", selection: $seqDigits) {
                        Text("2자리").tag(2)
                        Text("3자리").tag(3)
                        Text("4자리").tag(4)
                    }
                    .labelsHidden()
                    .frame(width: 80)

                    Spacer()
                }

            case .date:
                HStack(spacing: 6) {
                    Picker("", selection: $dateFormat) {
                        ForEach(DateFormatOption.allCases) { opt in
                            Text(opt.example).tag(opt)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Spacer()
                }

            case .original, .camera:
                Text(comp.type == .original ? "원본 파일명 유지" : "카메라 모델명")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 삭제 / 추가 버튼
            Button(action: {
                if components.count > 1 {
                    withAnimation { components.remove(at: index) }
                }
            }) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .disabled(components.count <= 1)

            Button(action: {
                if components.count < 5 {
                    components.insert(RenameComponentItem(type: .text), at: index + 1)
                }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .disabled(components.count >= 5)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .cornerRadius(5)
    }

    // MARK: - 옵션

    private var optionsSection: some View {
        GroupBox(label: sectionLabel("옵션")) {
            HStack(spacing: 16) {
                Toggle(isOn: $preserveRatings) {
                    Text("레이팅/컬러라벨 보존")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)

                Spacer()

                HStack(spacing: 6) {
                    Text("호환성")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Mac")
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(3)
                }
            }
        }
    }

    // MARK: - 미리 보기

    private var previewSection: some View {
        GroupBox(label: sectionLabel("미리 보기")) {
            VStack(spacing: 0) {
                if previewItems.isEmpty {
                    Text("미리보기할 사진이 없습니다")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(8)
                } else {
                    ForEach(Array(previewItems.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 0) {
                            Text(item.original)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.blue)
                                .frame(width: 28)

                            Text(item.renamed)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.blue)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        if item.original != previewItems.last?.original {
                            Divider().padding(.horizontal, 8)
                        }
                    }

                    if targetPhotos.count > 5 {
                        Text("... 외 \(targetPhotos.count - 5)개")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    }

                    Divider()

                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 11))
                        Text("\(targetPhotos.count)개 파일 이름 변경 예정")
                            .font(.system(size: 11))
                        Spacer()
                    }
                    .padding(6)
                }
            }
        }
    }

    // MARK: - 결과 + 하단

    private var footerSection: some View {
        HStack {
            Button(action: performRename) {
                HStack(spacing: 4) {
                    if isRenaming { ProgressView().scaleEffect(0.5) }
                    Text("이름 바꾸기")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(builtPattern.trimmingCharacters(in: .whitespaces).isEmpty || isRenaming)
            .keyboardShortcut(.defaultAction)

            if canUndo {
                Button(action: performUndo) {
                    Label("되돌리기", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if let msg = resultMessage {
                HStack(spacing: 4) {
                    Image(systemName: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(resultIsError ? .orange : .green)
                    Text(msg)
                        .font(.system(size: 10))
                }
            }

            Spacer()

            Button("닫기") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func applyPreset(_ types: [RenameComponent], _ sep: SeparatorOption) {
        components = types.map { RenameComponentItem(type: $0) }
        separator = sep
    }

    private func performRename() {
        isRenaming = true
        resultMessage = nil
        canUndo = false

        let pat = builtPattern
        let df = dateFormat.dateFormat
        let digits = seqDigits
        let start = seqStart
        let preserve = preserveRatings

        DispatchQueue.global(qos: .userInitiated).async {
            let result = store.batchRename(
                pattern: pat, dateFormat: df,
                seqDigits: digits, seqStart: start,
                preserveRatings: preserve
            )
            DispatchQueue.main.async {
                isRenaming = false
                if result.errors.isEmpty {
                    resultMessage = "\(result.success)개 파일 변경 완료"
                    resultIsError = false
                    canUndo = !store.lastRenameMap.isEmpty
                } else {
                    resultMessage = "성공 \(result.success), 실패 \(result.errors.count)"
                    resultIsError = true
                    canUndo = !store.lastRenameMap.isEmpty
                }
            }
        }
    }

    private func performUndo() {
        isRenaming = true
        DispatchQueue.global(qos: .userInitiated).async {
            let success = store.undoBatchRename()
            DispatchQueue.main.async {
                isRenaming = false
                canUndo = false
                resultMessage = success ? "되돌리기 완료" : "되돌리기 실패"
                resultIsError = !success
            }
        }
    }

    // MARK: - Helper

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
    }
}

// MARK: - 컴포넌트 순서 변경 DropDelegate

struct CompReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var components: [RenameComponentItem]
    @Binding var draggingID: UUID?
    @Binding var dropInsertIndex: Int?

    func performDrop(info: DropInfo) -> Bool {
        guard let dragID = draggingID else { dropInsertIndex = nil; return false }
        guard let fromIdx = components.firstIndex(where: { $0.id == dragID }),
              let toIdx = components.firstIndex(where: { $0.id == targetID }),
              fromIdx != toIdx else {
            draggingID = nil
            dropInsertIndex = nil
            return true
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            components.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
        }
        draggingID = nil
        dropInsertIndex = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragID = draggingID, dragID != targetID else { return }
        guard let fromIdx = components.firstIndex(where: { $0.id == dragID }),
              let toIdx = components.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            dropInsertIndex = toIdx > fromIdx ? toIdx + 1 : toIdx
        }
    }

    func dropExited(info: DropInfo) {
        dropInsertIndex = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
