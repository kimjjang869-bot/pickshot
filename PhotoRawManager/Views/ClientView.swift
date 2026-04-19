import SwiftUI

// MARK: - PickShot Client (Simplified view for customers)

struct ClientView: View {
    @EnvironmentObject var store: PhotoStore
    @State private var commentText: String = ""
    @State private var showExportDone: Bool = false
    @State private var useGridView: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            clientToolbar

            // Main content
            HSplitView {
                // Thumbnail area (left)
                VStack(spacing: 0) {
                    // Grid/List toggle
                    HStack {
                        Button(action: { useGridView = true }) {
                            Image(systemName: "square.grid.2x2")
                                .foregroundColor(useGridView ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        Button(action: { useGridView = false }) {
                            Image(systemName: "list.bullet")
                                .foregroundColor(!useGridView ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if !store.photos.isEmpty {
                            Text("\(store.filteredPhotos.filter { !$0.isFolder }.count)장")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                    if useGridView {
                        thumbnailGrid
                    } else {
                        thumbnailList
                    }
                }
                .frame(minWidth: 200, maxWidth: 400)

                // Preview + Comment (right)
                VStack(spacing: 0) {
                    // Preview
                    ZStack {
                        if let photo = store.selectedPhoto, !photo.isFolder {
                            PhotoPreviewView(photo: photo)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Color(nsColor: .controlBackgroundColor)
                                .overlay(
                                    Text("사진을 선택하세요")
                                        .font(.title3)
                                        .foregroundColor(.secondary)
                                )
                        }

                        // SP border on preview
                        if let photo = store.selectedPhoto, photo.isSpacePicked {
                            RoundedRectangle(cornerRadius: 0)
                                .stroke(Color.red, lineWidth: 4)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Comment area
                    if let photo = store.selectedPhoto, !photo.isFolder {
                        commentInputArea(photo: photo)
                    }
                }
            }
        }
        .background(ClientKeyHandler(store: store))
        .alert("내보내기 완료", isPresented: $showExportDone) {
            Button("확인") {}
        } message: {
            Text("셀렉 파일이 저장되었습니다.\n작가에게 이 파일을 전달해주세요!")
        }
    }

    // MARK: - Grid View

    private var thumbnailGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let size: CGFloat = 100
                let columns = [GridItem(.adaptive(minimum: size, maximum: size + 20), spacing: 6)]
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }) { photo in
                        let isSelected = store.selectedPhotoID == photo.id
                        VStack(spacing: 2) {
                            AsyncThumbnailView(url: photo.displayURL)
                                .frame(width: size, height: size * 0.75)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                                )

                            // Badges
                            HStack(spacing: 3) {
                                if photo.isSpacePicked {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundColor(.red)
                                }
                                if !photo.comments.isEmpty {
                                    Image(systemName: "bubble.left.fill")
                                        .font(.system(size: 8))
                                        .foregroundColor(.orange)
                                }
                                Spacer()
                            }
                            .frame(height: 10)

                            Text(photo.jpgURL.deletingPathExtension().lastPathComponent)
                                .font(.system(size: 9))
                                .lineLimit(1)
                                .foregroundColor(.secondary)
                        }
                        .padding(3)
                        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                        .cornerRadius(6)
                        .id(photo.id)
                        .onTapGesture {
                            store.selectedPhotoID = photo.id
                            store.selectedPhotoIDs = [photo.id]
                        }
                    }
                }
                .padding(6)
            }
            .onChange(of: store.selectedPhotoID) { _, newID in
                if let id = newID {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: nil)
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    private var clientToolbar: some View {
        HStack(spacing: 12) {
            // Folder open
            Button(action: { store.openFolder() }) {
                Label("폴더 열기", systemImage: "folder.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            if let url = store.folderURL {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.cyan)
            }

            Spacer()

            // Photo count
            if !store.photos.isEmpty {
                let spCount = store.photos.filter { $0.isSpacePicked }.count
                let commentCount = store.photos.filter { !$0.comments.isEmpty }.count
                HStack(spacing: 8) {
                    if spCount > 0 {
                        Text("셀렉: \(spCount)장")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.red)
                            .cornerRadius(4)
                    }
                    if commentCount > 0 {
                        Text("코멘트: \(commentCount)장")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange)
                            .cornerRadius(4)
                    }
                }
            }

            // Export button
            Button(action: exportSelection) {
                Label("셀렉 내보내기", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(store.photos.filter({ $0.isSpacePicked || !$0.comments.isEmpty }).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Thumbnail List

    private var thumbnailList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }) { photo in
                        clientThumbnailRow(photo: photo)
                            .id(photo.id)
                            .onTapGesture {
                                store.selectedPhotoID = photo.id
                                store.selectedPhotoIDs = [photo.id]
                            }
                    }
                }
                .padding(8)
            }
            .onChange(of: store.selectedPhotoID) { _, newID in
                if let id = newID {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: nil)
                    }
                }
            }
        }
    }

    private func clientThumbnailRow(photo: PhotoItem) -> some View {
        let isSelected = store.selectedPhotoID == photo.id

        return HStack(spacing: 8) {
            // Thumbnail
            AsyncThumbnailView(url: photo.displayURL)
                .frame(width: 60, height: 40)
                .cornerRadius(4)
                .clipped()

            // Filename
            Text(photo.jpgURL.deletingPathExtension().lastPathComponent)
                .font(.system(size: 11))
                .lineLimit(1)

            Spacer()

            // Badges
            if photo.isSpacePicked {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 14))
            }
            if !photo.comments.isEmpty {
                HStack(spacing: 1) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10))
                    Text("\(photo.comments.count)")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    // MARK: - Comment Input

    private func commentInputArea(photo: PhotoItem) -> some View {
        VStack(spacing: 0) {
            Divider()

            // Existing comments
            if !photo.comments.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(photo.comments.indices, id: \.self) { i in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "person.circle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 14))
                                Text(photo.comments[i])
                                    .font(.system(size: 12))
                                    .padding(8)
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(8)
                                Spacer()
                                // Delete comment
                                Button(action: { deleteComment(at: i) }) {
                                    Image(systemName: "xmark.circle")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 100)
            }

            // Input field
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .foregroundColor(.orange)

                TextField("이 사진에 대한 요청사항 입력...", text: $commentText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { addComment() }

                Button(action: addComment) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(commentText.isEmpty ? .secondary : .orange)
                }
                .buttonStyle(.plain)
                .disabled(commentText.isEmpty)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))

            // SP select bar
            HStack {
                Spacer()
                Button(action: toggleSpacePick) {
                    HStack(spacing: 4) {
                        Image(systemName: photo.isSpacePicked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                        Text(photo.isSpacePicked ? "선택됨" : "이 사진 선택하기")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(photo.isSpacePicked ? Color.red : Color.gray.opacity(0.5))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: - Actions

    private func addComment() {
        guard !commentText.isEmpty,
              let id = store.selectedPhotoID,
              let idx = store._photoIndex[id] else { return }
        store._suppressDidSet = true
        store.photos[idx].comments.append(commentText)
        store._suppressDidSet = false
        store.objectWillChange.send()
        commentText = ""
    }

    private func deleteComment(at index: Int) {
        guard let id = store.selectedPhotoID,
              let idx = store._photoIndex[id],
              index < store.photos[idx].comments.count else { return }
        store._suppressDidSet = true
        store.photos[idx].comments.remove(at: index)
        store._suppressDidSet = false
        store.objectWillChange.send()
    }

    private func toggleSpacePick() {
        guard let id = store.selectedPhotoID,
              let idx = store._photoIndex[id] else { return }
        store.photos[idx].isSpacePicked.toggle()
    }

    private func exportSelection() {
        let folderName = store.folderURL?.lastPathComponent ?? "PickShot"
        if let _ = PickshotFileService.exportSelection(photos: store.photos, folderName: folderName) {
            showExportDone = true
        }
    }
}

// MARK: - Client Keyboard Handler

struct ClientKeyHandler: NSViewRepresentable {
    let store: PhotoStore

    func makeNSView(context: Context) -> ClientKeyView {
        let view = ClientKeyView()
        view.store = store
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: ClientKeyView, context: Context) {
        nsView.store = store
    }

    class ClientKeyView: NSView {
        var store: PhotoStore?
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard let store = store else { super.keyDown(with: event); return }
            guard !store.photos.isEmpty else { super.keyDown(with: event); return }

            store.isKeyRepeat = event.isARepeat

            switch event.keyCode {
            case 123: store.selectLeft()       // ←
            case 124: store.selectRight()      // →
            case 125: store.selectDown()       // ↓
            case 126: store.selectUp()         // ↑
            case 49:  // Space - toggle SP
                if let id = store.selectedPhotoID, let idx = store._photoIndex[id] {
                    guard !store.photos[idx].isFolder && !store.photos[idx].isParentFolder else { return }
                    store.photos[idx].isSpacePicked.toggle()
                }
            default:
                super.keyDown(with: event)
            }
        }

        override func keyUp(with event: NSEvent) {
            store?.isKeyRepeat = false
        }
    }
}
