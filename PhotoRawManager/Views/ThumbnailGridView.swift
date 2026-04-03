import SwiftUI

struct ThumbnailGridView: View {
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    if store.filteredPhotos.isEmpty {
                        VStack(spacing: 8) {
                            Spacer().frame(height: 80)
                            Image(systemName: store.folderURL != nil ? "photo.on.rectangle.angled" : "folder")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.1))
                            Text(store.folderURL != nil ? "이미지 없음" : "폴더를 선택하세요")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.2))
                        }
                        .frame(maxWidth: .infinity)
                    } else if store.viewMode == .grid {
                        gridView
                    } else {
                        listView
                    }
                }
                .scrollIndicators(.visible)
                .onChange(of: store.scrollTrigger) { _ in
                    guard let id = store.selectedPhotoID else { return }
                    // anchor: nil → SwiftUI scrolls minimum amount to make item visible
                    // Only scrolls when item is outside visible area
                    proxy.scrollTo(id, anchor: nil)
                }
            }
            .onAppear {
                store.gridWidth = geo.size.width
                updateActualColumns(width: geo.size.width)
            }
            .onChange(of: geo.size.width) { newWidth in
                store.gridWidth = newWidth
                updateActualColumns(width: newWidth)
            }
        }
    }

    private func updateActualColumns(width: CGFloat) {
        let size = store.thumbnailSize
        let spacing: CGFloat = 8
        // Match GridItem(.adaptive(minimum: size, maximum: size + 40), spacing: 8)
        let cellWidth = size + spacing
        let cols = max(1, Int(width / cellWidth))
        if store.actualColumnsPerRow != cols {
            store.actualColumnsPerRow = cols
        }
    }

    private func listSortButton(_ title: String, mode: SortMode, altMode: SortMode, width: CGFloat?) -> some View {
        Button(action: {
            if store.sortMode == mode {
                store.sortMode = altMode
            } else if store.sortMode == altMode {
                store.sortMode = mode
            } else {
                store.sortMode = mode
            }
        }) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: store.sortMode == mode || store.sortMode == altMode ? .bold : .regular))
                if store.sortMode == mode {
                    Image(systemName: "chevron.up").font(.system(size: 7))
                } else if store.sortMode == altMode {
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
            }
            .foregroundColor(store.sortMode == mode || store.sortMode == altMode ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Grid View

    private var gridView: some View {
        let size = store.thumbnailSize
        let columns = [GridItem(.adaptive(minimum: size, maximum: size + 40), spacing: 8)]

        let photos = store.filteredPhotos  // Compute once, not per-cell
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(photos) { photo in
                LazyThumbnailWrapper(
                    photo: photo,
                    size: size,
                    isSelected: store.isSelected(photo.id),
                    isFocused: store.selectedPhotoID == photo.id,
                    onTap: {
                        let flags = NSEvent.modifierFlags
                        store.selectPhoto(photo.id, cmdKey: flags.contains(.command), shiftKey: flags.contains(.shift))
                    }
                )
                .id(photo.id)
            }
        }
        .padding(8)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    store.deselectAll()
                }
        )
    }

    // MARK: - List View

    private var listView: some View {
        return VStack(spacing: 0) {
            // Sort header
            HStack(spacing: 0) {
                listSortButton("이름", mode: .nameAsc, altMode: .nameDesc, width: nil)
                Spacer()
                listSortButton("크기", mode: .nameAsc, altMode: .nameDesc, width: 80)
                listSortButton("수정일", mode: .dateDesc, altMode: .dateAsc, width: 120)
                listSortButton("종류", mode: .nameAsc, altMode: .nameDesc, width: 60)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            LazyVStack(spacing: 1) {
            ForEach(store.filteredPhotos) { photo in
                LazyListRowWrapper(
                    photo: photo,
                    isSelected: store.isSelected(photo.id),
                    isFocused: store.selectedPhotoID == photo.id,
                    onTap: {
                        let flags = NSEvent.modifierFlags
                        store.selectPhoto(photo.id, cmdKey: flags.contains(.command), shiftKey: flags.contains(.shift))
                    }
                )
                .id(photo.id)
            }
        }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Lazy Wrappers (prevent full grid re-render on selection change)

struct LazyThumbnailWrapper: View {
    let photo: PhotoItem
    let size: CGFloat
    let isSelected: Bool
    let isFocused: Bool
    let onTap: () -> Void
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        if photo.isParentFolder {
            let isSelected = store.selectedPhotoID == photo.id || store.selectedPhotoIDs.contains(photo.id)
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? AppTheme.accent.opacity(0.2) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .frame(width: size, height: size * 0.75)
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(isSelected ? 0.3 : 0.12))
                                .frame(width: size * 0.35, height: size * 0.35)
                            Image(systemName: "chevron.up")
                                .font(.system(size: size * 0.14, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                        Text(photo.jpgURL.lastPathComponent)
                            .font(.system(size: max(9, size * 0.055), weight: .medium))
                            .foregroundColor(isSelected ? .white : .secondary)
                            .lineLimit(1)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? AppTheme.selectionBorder : Color.clear, lineWidth: AppTheme.cellBorderWidth)
                )
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? AppTheme.selectionBorder.opacity(0.15) : Color.clear)
                )
            }
            .frame(width: size)
            .padding(4)
            .contentShape(Rectangle())
            .onTapGesture {
                if NSApp.currentEvent?.clickCount == 2 {
                    store.loadFolder(photo.jpgURL)
                } else {
                    store.selectedPhotoID = photo.id
                    store.selectedPhotoIDs = [photo.id]
                }
            }
            .help("클릭: 선택 / 더블클릭: 이동 / Enter: 이동")
        } else if photo.isFolder {
            // Subfolder item
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.gray.opacity(0.08))
                        .frame(width: size, height: size * 0.75)
                    Image(systemName: "folder.fill")
                        .font(.system(size: size * 0.25))
                        .foregroundColor(.blue.opacity(0.6))
                }
                Text(photo.jpgURL.lastPathComponent)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size)
            }
            .frame(width: size)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? AppTheme.selectionBorder : Color.clear, lineWidth: AppTheme.cellBorderWidth)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if NSApp.currentEvent?.clickCount == 2 {
                    store.loadFolder(photo.jpgURL)
                } else {
                    store.selectedPhotoID = photo.id
                    store.selectedPhotoIDs = [photo.id]
                }
            }
        } else {
            ThumbnailCell(
                photo: photo,
                isSelected: isSelected,
                isFocused: isFocused,
                size: size
            )
            .contentShape(Rectangle())
            .overlay(
                MultiFileDragView(photo: photo, store: store)
            )
            .onTapGesture { onTap() }
            .contextMenu { PhotoContextMenu(photo: photo, store: store) }
        }
    }
}

struct LazyListRowWrapper: View {
    let photo: PhotoItem
    let isSelected: Bool
    let isFocused: Bool
    let onTap: () -> Void
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        ListRow(photo: photo, isSelected: isSelected, isFocused: isFocused)
            .contentShape(Rectangle())
            .onDrag {
                let ids = store.selectedPhotoIDs.contains(photo.id) ? store.selectedPhotoIDs : [photo.id]
                var urls: [URL] = []
                for id in ids {
                    guard let idx = store._photoIndex[id], idx < store.photos.count else { continue }
                    let p = store.photos[idx]
                    guard !p.isFolder && !p.isParentFolder else { continue }
                    urls.append(p.jpgURL)
                    if let rawURL = p.rawURL, rawURL != p.jpgURL { urls.append(rawURL) }
                }
                let provider = NSItemProvider()
                for url in urls {
                    provider.registerFileRepresentation(forTypeIdentifier: "public.file-url", visibility: .all) { completion in
                        completion(url, false, nil)
                        return nil
                    }
                }
                return provider
            }
            .onTapGesture { onTap() }
            .contextMenu { PhotoContextMenu(photo: photo, store: store) }
    }
}

// MARK: - Photo Context Menu (Right-click)

struct PhotoContextMenu: View {
    let photo: PhotoItem
    let store: PhotoStore

    private var targetIDs: Set<UUID> {
        store.selectedPhotoIDs.contains(photo.id) ? store.selectedPhotoIDs : [photo.id]
    }

    private var targetCount: Int {
        targetIDs.count
    }

    private static let recentFoldersKey = "recentCopyFolders"

    private var recentCopyFolders: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.recentFoldersKey) ?? [])
            .compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addRecentFolder(_ url: URL) {
        var folders = UserDefaults.standard.stringArray(forKey: Self.recentFoldersKey) ?? []
        folders.removeAll { $0 == url.path }
        folders.insert(url.path, at: 0)
        if folders.count > 5 { folders = Array(folders.prefix(5)) }
        UserDefaults.standard.set(folders, forKey: Self.recentFoldersKey)
    }

    private func collectFileURLs() -> [URL] {
        var urls: [URL] = []
        for id in targetIDs {
            guard let idx = store._photoIndex[id], idx < store.photos.count else { continue }
            let p = store.photos[idx]
            guard !p.isFolder && !p.isParentFolder else { continue }
            urls.append(p.jpgURL)
            if let rawURL = p.rawURL, rawURL != p.jpgURL { urls.append(rawURL) }
        }
        return urls
    }

    private func copyFilesToFolder(_ destFolder: URL) {
        let fm = FileManager.default
        let files = collectFileURLs()
        var copied = 0
        for file in files {
            let dest = destFolder.appendingPathComponent(file.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: file, to: dest)
                copied += 1
            } catch {}
        }
        addRecentFolder(destFolder)
        store.showToastMessage("📂 \(copied)개 파일 복사 완료 → \(destFolder.lastPathComponent)")
    }

    private func copyFilesToNewFolder() {
        let panel = NSOpenPanel()
        panel.title = "복사할 폴더 선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        copyFilesToFolder(url)
    }

    var body: some View {
        // Rating submenu
        Menu {
            ForEach(0...5, id: \.self) { rating in
                Button(action: {
                    for id in targetIDs {
                        if let idx = store._photoIndex[id] { store.photos[idx].rating = rating }
                    }
                }) {
                    if rating == 0 {
                        Label("별점 없음", systemImage: "star.slash")
                    } else {
                        Label(String(repeating: "★", count: rating), systemImage: "star.fill")
                    }
                }
            }
        } label: {
            Label("별점", systemImage: "star.fill")
        }

        Divider()

        // SP Select
        Button(action: {
            for id in targetIDs {
                if let idx = store._photoIndex[id] { store.photos[idx].isSpacePicked.toggle() }
            }
        }) {
            Label(photo.isSpacePicked ? "SP 셀렉 해제" : "SP 셀렉", systemImage: photo.isSpacePicked ? "checkmark.circle" : "circle")
        }

        // G Select
        Button(action: {
            for id in targetIDs {
                if let idx = store._photoIndex[id] { store.photos[idx].isGSelected.toggle() }
            }
        }) {
            Label(photo.isGSelected ? "G셀렉 해제" : "G셀렉", systemImage: "cloud")
        }

        Divider()

        // Color label submenu
        Menu {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                Button(action: {
                    for id in targetIDs {
                        if let idx = store._photoIndex[id] { store.photos[idx].colorLabel = label }
                    }
                }) {
                    HStack {
                        Circle().fill(label.color ?? .gray).frame(width: 10, height: 10)
                        Text(label == .none ? "라벨 없음" : label.rawValue)
                    }
                }
            }
        } label: {
            Label("컬러 라벨", systemImage: "tag.fill")
        }

        Divider()

        // Export selected
        Button(action: {
            store.showExportSheet = true
        }) {
            Label("내보내기 (\(targetCount)장)", systemImage: "square.and.arrow.up")
        }

        // Copy to Finder (with recent folders)
        Menu {
            // Recent 5 folders
            ForEach(recentCopyFolders.prefix(5), id: \.self) { folder in
                Button(action: { copyFilesToFolder(folder) }) {
                    Label(folder.lastPathComponent, systemImage: "folder")
                }
            }

            if !recentCopyFolders.isEmpty { Divider() }

            Button(action: { copyFilesToNewFolder() }) {
                Label("폴더 선택...", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("Finder로 복사 (\(targetCount)장)", systemImage: "doc.on.doc.fill")
        }

        Divider()

        // Copy filename
        Button(action: {
            let names = targetIDs.compactMap { id -> String? in
                guard let idx = store._photoIndex[id] else { return nil }
                return store.photos[idx].jpgURL.lastPathComponent
            }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names, forType: .string)
            store.showToastMessage("📋 \(targetCount)개 파일명 복사됨")
        }) {
            Label("파일명 복사", systemImage: "doc.on.clipboard")
        }

        // Show in Finder
        Button(action: {
            NSWorkspace.shared.activateFileViewerSelecting([photo.jpgURL])
        }) {
            Label("Finder에서 보기", systemImage: "folder")
        }

        // Quick Look
        Button(action: {
            NSWorkspace.shared.open(photo.jpgURL)
        }) {
            Label("Quick Look", systemImage: "eye")
        }

        Divider()

        // Rename
        Button(action: {
            store.showBatchRename = true
        }) {
            Label("이름 변경 (\(targetCount)장)", systemImage: "pencil")
        }

        // Remove from list
        Button(action: {
            store.photosToRemove = targetIDs
            store.showDeleteConfirm = true
        }) {
            Label("목록에서 제거", systemImage: "eye.slash")
        }

        // Delete original (if setting enabled)
        if UserDefaults.standard.bool(forKey: "deleteOriginalFile") {
            Button(role: .destructive, action: {
                store.pendingDeleteIDs = targetIDs
                store.showDeleteOriginalConfirm = true
            }) {
                Label("원본 삭제 (휴지통)", systemImage: "trash")
            }
        }
    }
}

// MARK: - Thumbnail Cell (Grid)

struct ThumbnailCell: View {
    @EnvironmentObject var store: PhotoStore
    let photo: PhotoItem
    let isSelected: Bool
    let isFocused: Bool
    let size: CGFloat

    @State private var isHovered = false

    private var badgeFont: Font { .system(size: max(8, size * 0.065), weight: .bold) }
    private var imgH: CGFloat { size * 0.75 }

    var body: some View {
        VStack(spacing: 3) {
            AsyncThumbnailView(url: photo.jpgURL)
                .frame(width: size, height: imgH)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cellCornerRadius, style: .continuous))
                .overlay(badgeOverlay, alignment: .topTrailing)
                .overlay(pickOverlay, alignment: .topLeading)
                .overlay(gradeOverlay, alignment: .bottomLeading)
                .overlay(sceneOverlay, alignment: .bottomTrailing)

            // File name
            Text(store.showFileExtension ? photo.fileNameWithExtension : photo.fileName)
                .font(.system(size: AppTheme.fontCaption))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.primary)

            // Star rating
            starsView
        }
        .padding(5)
        .background(cellBackground)
        .overlay(cellBorder)
        .onHover { isHovered = $0 }
    }

    // MARK: - Badge overlays

    @ViewBuilder
    private var badgeOverlay: some View {
        if store.showFileTypeBadge {
            let badge = photo.fileTypeBadge
            let badgeColor: Color = badge.color == "orange" ? .orange :
                                    badge.color == "green" ? .green :
                                    badge.color == "purple" ? .purple :
                                    badge.color == "teal" ? .teal :
                                    badge.color == "gray" ? .gray : .blue
            VStack(alignment: .trailing, spacing: 2) {
                badgeText(badge.text, color: badgeColor)
                if photo.isCorrected {
                    badgeText("보정", color: AppTheme.correctedBadge)
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var pickOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            if photo.isGSelected {
                let isUploading = GSelectService.shared.currentlyUploading == photo.id
                HStack(spacing: 2) {
                    Text("G")
                        .font(.system(size: max(8, size * 0.07), weight: .black))
                    Image(systemName: isUploading ? "arrow.up.circle" : "checkmark.icloud.fill")
                        .font(.system(size: max(7, size * 0.06)))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.85))
                .cornerRadius(3)
                .padding(3)
            }
            if photo.isSpacePicked {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: max(8, size * 0.07)))
                    Text("SP")
                        .font(.system(size: AppTheme.fontMicro, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(AppTheme.error)
                .clipShape(Capsule())
            }
            if !photo.comments.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: max(8, size * 0.07)))
                    Text("\(photo.comments.count)")
                        .font(.system(size: AppTheme.fontMicro, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.orange)
                .clipShape(Capsule())
            }
            if photo.isAIPick {
                badgeText("PICK", color: AppTheme.pickBadge)
            }
            if let fgID = photo.faceGroupID {
                HStack(spacing: 2) {
                    Image(systemName: "person.fill")
                        .font(.system(size: max(7, size * 0.06)))
                    Text("\(fgID + 1)")
                        .font(.system(size: max(7, size * 0.06), weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.85))
                .cornerRadius(3)
            }
        }
        .padding(4)
    }

    @ViewBuilder
    private var gradeOverlay: some View {
        if let quality = photo.quality, quality.isAnalyzed {
            badgeText(quality.overallGrade.rawValue, color: AppTheme.gradeColor(quality.overallGrade))
                .padding(4)
        }
    }

    @ViewBuilder
    private var sceneOverlay: some View {
        let tag = photo.aiCategory ?? photo.sceneTag
        if let tag = tag {
            HStack(spacing: 2) {
                Text(tag)
                    .font(.system(size: max(7, size * 0.06), weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                // AI score badge
                if let score = photo.aiScore {
                    Text("\(score)")
                        .font(.system(size: max(6, size * 0.05), weight: .bold, design: .monospaced))
                        .foregroundColor(score >= 80 ? .green : score >= 50 ? .yellow : .red)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(photo.aiCategory != nil ? Color.purple.opacity(0.6) : Color.black.opacity(0.5))
            .cornerRadius(2)
            .padding(4)
        }
    }

    private func badgeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var starsView: some View {
        let starSize = max(7, size * 0.06)
        return HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= photo.rating ? "star.fill" : "star")
                    .font(.system(size: max(8, starSize)))
                    .foregroundColor(i <= photo.rating ? AppTheme.starGold : AppTheme.starEmpty.opacity(0.4))
            }
        }
        .frame(height: starSize + 4)
    }

    private var cellBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.cellCornerRadius + 2, style: .continuous)
            .fill(
                isFocused ? AppTheme.accent.opacity(0.12) :
                isSelected ? AppTheme.accent.opacity(0.06) :
                isHovered ? Color.gray.opacity(0.08) :
                Color.clear
            )
    }

    private var cellBorder: some View {
        RoundedRectangle(cornerRadius: AppTheme.cellCornerRadius + 2, style: .continuous)
            .stroke(
                photo.isSpacePicked ? AppTheme.spPickBorder :
                isFocused ? AppTheme.focusBorder :
                isSelected ? AppTheme.selectionBorder.opacity(0.5) :
                Color.clear,
                lineWidth: photo.isSpacePicked ? AppTheme.focusBorderWidth :
                           isFocused ? AppTheme.focusBorderWidth :
                           AppTheme.cellBorderWidth
            )
    }
}

// MARK: - List Row

struct ListRow: View {
    let photo: PhotoItem
    let isSelected: Bool
    let isFocused: Bool
    @EnvironmentObject var store: PhotoStore

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail or folder icon
            if photo.isParentFolder {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 48, height: 36)
                    Image(systemName: "chevron.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                }
            } else if photo.isFolder {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 48, height: 36)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                }
            } else {
                AsyncThumbnailView(url: photo.jpgURL)
                    .frame(width: 48, height: 36)
                    .clipped()
                    .cornerRadius(4)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(store.showFileExtension ? photo.fileNameWithExtension : photo.fileName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if photo.isAIPick {
                        Text("PICK")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.85))
                            .cornerRadius(2)
                    }
                }

                if let date = photo.exifData?.dateTaken {
                    Text(Self.timeFormatter.string(from: date))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if photo.rating > 0 {
                HStack(spacing: 1) {
                    ForEach(1...photo.rating, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.yellow)
                    }
                }
            }

            if let quality = photo.quality, quality.isAnalyzed {
                Text(quality.overallGrade.rawValue)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(listQualityColor(quality.overallGrade).opacity(0.85))
                    .cornerRadius(3)
            }

            if !photo.isFolder && !photo.isParentFolder {
                let listBadge = photo.fileTypeBadge
                let listBadgeColor: Color = listBadge.color == "orange" ? .orange :
                                            listBadge.color == "green" ? .green : .blue
                Text(listBadge.text)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(listBadgeColor.opacity(0.8))
                    .cornerRadius(3)
            } else {
                Text("FILE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.5))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cellCornerRadius + 2)
                .fill(
                    isFocused ? AppTheme.accent.opacity(0.2) :
                    isSelected ? AppTheme.accent.opacity(0.1) :
                    Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cellCornerRadius + 2)
                .stroke(isFocused ? AppTheme.focusBorder : Color.clear, lineWidth: AppTheme.cellBorderWidth)
        )
        .padding(.horizontal, 4)
    }

    private func listQualityColor(_ grade: QualityAnalysis.Grade) -> Color {
        AppTheme.gradeColor(grade)
    }
}

// MARK: - Thumbnail Cache

class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: NSImage] = [:]
    private let memoryCache = NSCache<NSURL, NSImage>()
    private let lock = NSLock()
    private let maxEntries: Int
    private var accessOrder: [URL] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        maxEntries = ramGB >= 16 ? 8000 : (ramGB >= 8 ? 4000 : 1500)

        memoryCache.countLimit = maxEntries
        // Use 10% of RAM for thumbnail cache (balanced - thumbnails are small ~40KB each)
        memoryCache.totalCostLimit = Int(ProcessInfo.processInfo.physicalMemory / 10)  // 10% RAM

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            if event.contains(.critical) {
                self.removeAll()
            } else {
                // .warning: evict 50%
                self.lock.lock()
                let removeCount = self.accessOrder.count / 2
                if removeCount > 0 {
                    let keysToRemove = Array(self.accessOrder.prefix(removeCount))
                    self.accessOrder.removeFirst(removeCount)
                    for key in keysToRemove {
                        self.cache.removeValue(forKey: key)
                        self.memoryCache.removeObject(forKey: key as NSURL)
                    }
                }
                self.lock.unlock()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func get(_ url: URL) -> NSImage? {
        // L1: NSCache (thread-safe, no lock needed)
        if let image = memoryCache.object(forKey: url as NSURL) {
            // Update LRU access order
            lock.lock()
            if let idx = accessOrder.firstIndex(of: url) {
                accessOrder.remove(at: idx)
                accessOrder.append(url)
            }
            lock.unlock()
            return image
        }
        // L2: Dictionary
        lock.lock()
        defer { lock.unlock() }
        if let image = cache[url] {
            // Promote to L1
            memoryCache.setObject(image, forKey: url as NSURL)
            // Update LRU access order
            if let idx = accessOrder.firstIndex(of: url) {
                accessOrder.remove(at: idx)
                accessOrder.append(url)
            }
            return image
        }
        return nil
    }

    func set(_ url: URL, image: NSImage) {
        lock.lock()
        if cache.count >= maxEntries {
            // Remove ~20% least recently used
            let removeCount = maxEntries / 5
            let keysToRemove = Array(accessOrder.prefix(removeCount))
            accessOrder.removeFirst(removeCount)
            for key in keysToRemove {
                cache.removeValue(forKey: key)
                memoryCache.removeObject(forKey: key as NSURL)
            }
        }
        cache[url] = image
        memoryCache.setObject(image, forKey: url as NSURL)
        accessOrder.append(url)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        cache.removeAll()
        memoryCache.removeAllObjects()
        accessOrder.removeAll()
        lock.unlock()
    }
}

// MARK: - Concurrent Thumbnail Loader

class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    let queue = OperationQueue()
    private var pendingCallbacks: [URL: [(NSImage) -> Void]] = [:]
    private let lock = NSLock()

    init() {
        // Default for local SSD
        queue.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount * 2
        queue.qualityOfService = .userInitiated
    }

    /// Auto-detect NAS/network volume and increase concurrency
    enum StorageType { case localSSD, externalHDD, network }

    func optimizeForPath(_ path: String) {
        let type = detectStorageType(path)
        switch type {
        case .localSSD:
            isNetworkMode = false
            queue.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount * 2
            AppLogger.log(.performance, "Local SSD: concurrency=\(queue.maxConcurrentOperationCount)")
        case .externalHDD:
            // HDD: seek time is bottleneck, moderate concurrency helps
            // Too many concurrent = HDD head thrashing, too few = slow
            isNetworkMode = false
            queue.maxConcurrentOperationCount = 8
            AppLogger.log(.performance, "External HDD: concurrency=8, thumbSize=160 for \(path)")
        case .network:
            // NAS: network I/O bound, high concurrency
            isNetworkMode = true
            queue.maxConcurrentOperationCount = 64
            AppLogger.log(.performance, "NAS/Network: concurrency=64, thumbSize=160 for \(path)")
        }
    }

    var isNetworkMode: Bool = false

    /// Check if path is on external HDD (not SSD)
    var isSlowDisk: Bool {
        isNetworkMode || queue.maxConcurrentOperationCount == 8
    }

    private func detectStorageType(_ path: String) -> StorageType {
        let url = URL(fileURLWithPath: path)

        // Check if network volume (authoritative — uses OS volume metadata)
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           let isLocal = values.volumeIsLocal, !isLocal {
            return .network
        }

        // External volume detection
        if path.hasPrefix("/Volumes/") {
            // Check if SSD using IOKit / volume properties
            if let isSSD = checkIfSSD(path: path) {
                return isSSD ? .localSSD : .externalHDD
            }
            // Fallback: assume external SSD (modern external drives are mostly SSD)
            // Better to be fast and wrong than slow and safe
            return .externalHDD
        }

        return .localSSD
    }

    private func checkIfSSD(path: String) -> Bool? {
        let url = URL(fileURLWithPath: path)

        // Check volume properties
        if let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey]),
           let isInternal = values.volumeIsInternal {
            if isInternal { return true }  // Internal = SSD on modern Macs
        }

        // Check volume name hints for known SSD brands
        let volumeName = url.pathComponents.count >= 3 ? url.pathComponents[2].lowercased() : ""
        let ssdHints = ["ssd", "extreme", "samsung t", "sandisk", "nvme", "thunderbolt"]
        if ssdHints.contains(where: { volumeName.contains($0) }) {
            return true
        }

        // Check if the volume supports TRIM (SSD indicator) via diskutil
        let mountPoint = "/Volumes/" + (url.pathComponents.count >= 3 ? url.pathComponents[2] : "")
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: mountPoint),
           let totalSize = attrs[.systemSize] as? Int64 {
            // Volumes < 100GB with no Spotlight are likely SD cards or small external media
            // Volumes > 100GB without Spotlight are likely unindexed external drives (not NAS)
            _ = totalSize  // Keep for future heuristics
        }

        return nil  // Unknown
    }

    /// Cancel all pending operations (call when scrolling fast to prioritize new visible cells)
    func cancelAll() {
        queue.cancelAllOperations()
        lock.lock()
        pendingCallbacks.removeAll()
        lock.unlock()
    }

    /// Get file modification date for disk cache key
    private static func fileModDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date.distantPast
    }

    func load(url: URL, completion: @escaping (NSImage) -> Void) {
        // 1. Memory cache hit → return directly
        if let cached = ThumbnailCache.shared.get(url) {
            AppLogger.log(.cache, "thumbnail cache HIT: \(url.lastPathComponent)")
            completion(cached)
            return
        }
        AppLogger.log(.thumbnail, "thumbnail cache MISS: \(url.lastPathComponent)")

        // Queue callback; if already loading, just add callback
        lock.lock()
        if pendingCallbacks[url] != nil {
            pendingCallbacks[url]?.append(completion)
            lock.unlock()
            return
        }
        pendingCallbacks[url] = [completion]
        lock.unlock()

        queue.addOperation { [weak self] in
            // For NAS: skip expensive stat on cache miss path — use file path hash only
            // Disk cache uses modDate for invalidation, but for NAS the stat() is ~50-100ms per file
            let isNAS = ThumbnailLoader.shared.isNetworkMode
            let modDate: Date
            if isNAS {
                // Defer expensive stat: check disk cache with a sentinel date first
                // If disk cache has ANY entry for this URL hash, use it (modDate mismatch = stale but fast)
                modDate = Date.distantPast  // Will be updated on cache save
            } else {
                modDate = Self.fileModDate(url)
            }

            // 2. Disk cache hit → load from disk, populate memory cache
            // For NAS: try path-only lookup first (skip modDate check)
            let diskCached = isNAS
                ? DiskThumbnailCache.shared.getByPath(url: url)
                : DiskThumbnailCache.shared.get(url: url, modDate: modDate)
            if let diskCached = diskCached {
                AppLogger.log(.cache, "disk cache HIT: \(url.lastPathComponent)")
                ThumbnailCache.shared.set(url, image: diskCached)

                self?.lock.lock()
                let callbacks = self?.pendingCallbacks.removeValue(forKey: url) ?? []
                self?.lock.unlock()

                DispatchQueue.main.async {
                    for cb in callbacks { cb(diskCached) }
                }
                return
            }

            // 3. Extract from file
            let thumbStart = CFAbsoluteTimeGetCurrent()
            var image = Self.extractThumbnail(url: url)
            if image == nil && ThumbnailLoader.shared.isSlowDisk {
                Thread.sleep(forTimeInterval: 0.1)
                image = Self.extractThumbnail(url: url)
            }
            let extractElapsed = (CFAbsoluteTimeGetCurrent() - thumbStart) * 1000

            if let image = image {
                // Memory cache: immediate (needed for UI)
                ThumbnailCache.shared.set(url, image: image)
                // Disk cache: deferred to background (was 289ms avg, now non-blocking)
                DispatchQueue.global(qos: .utility).async {
                    let realModDate = isNAS ? Self.fileModDate(url) : modDate
                    DiskThumbnailCache.shared.set(url: url, modDate: realModDate, image: image)
                }
            }

            // Always clean up callbacks (even on failure) to prevent leaks
            self?.lock.lock()
            let callbacks = self?.pendingCallbacks.removeValue(forKey: url) ?? []
            self?.lock.unlock()

            DispatchQueue.main.async {
                if let image = image {
                    for cb in callbacks { cb(image) }
                } else {
                    // Still call callbacks with placeholder so progress tracking works
                    let placeholder = NSImage(size: NSSize(width: 1, height: 1))
                    for cb in callbacks { cb(placeholder) }
                }
            }
        }
    }

    private static var thumbSize: Int {
        // Smaller thumbnails for slow storage = faster loading
        ThumbnailLoader.shared.isSlowDisk ? 160 : 200
    }

    private static let allKnownExtensions: Set<String> = {
        FileMatchingService.jpgExtensions
            .union(FileMatchingService.rawExtensions)
            .union(FileMatchingService.imageExtensions)
            .union(FileMatchingService.videoExtensions)
    }()

    /// Read EXIF orientation from image file (1-8)
    private static func readOrientation(url: URL) -> Int {
        let opts: [NSString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return 1 }
        return props[kCGImagePropertyOrientation as String] as? Int ?? 1
    }

    /// Rotate NSImage based on EXIF orientation
    private static func rotateImage(_ image: NSImage, orientation: Int) -> NSImage {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return image }

        let w = cgImage.width, h = cgImage.height
        let swap = orientation >= 5 && orientation <= 8
        let outW = swap ? h : w
        let outH = swap ? w : h

        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: CGFloat(-w), y: 0)
        case 3: transform = CGAffineTransform(translationX: CGFloat(w), y: CGFloat(h)).rotated(by: .pi)
        case 4: transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: CGFloat(-h))
        case 5: transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: CGFloat(-h), y: 0).rotated(by: .pi / 2)
        case 6: transform = CGAffineTransform(translationX: CGFloat(h), y: 0).rotated(by: .pi / 2)
        case 7: transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: 0, y: CGFloat(-w)).rotated(by: -.pi / 2)
        case 8: transform = CGAffineTransform(translationX: 0, y: CGFloat(w)).rotated(by: -.pi / 2)
        default: return image
        }

        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                   bitsPerComponent: cgImage.bitsPerComponent, bytesPerRow: 0,
                                   space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: cgImage.bitmapInfo.rawValue) else { return image }
        ctx.concatenate(transform)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rotated = ctx.makeImage() else { return image }
        return NSImage(cgImage: rotated, size: NSSize(width: outW, height: outH))
    }

    private static func extractThumbnail(url: URL) -> NSImage? {
        let ext = url.pathExtension.lowercased()

        // Generic files: use system icon
        if !allKnownExtensions.contains(ext) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: thumbSize, height: thumbSize)
            return icon
        }

        // Video files: use AVAssetImageGenerator
        if FileMatchingService.videoExtensions.contains(ext) {
            return FileMatchingService.generateVideoThumbnail(url: url)
        }

        let isRAW = FileMatchingService.rawExtensions.contains(ext)

        // RAW: ALWAYS try embedded JPEG first (3MB read vs 40MB+ full decode)
        if isRAW {
            let t0 = CFAbsoluteTimeGetCurrent()
            if var img = extractEmbeddedJPEG(url: url, maxSize: thumbSize) {
                // Check if CGImageSource reports correct orientation-applied dimensions
                // Compare embedded JPEG aspect ratio with RAW's intended aspect ratio
                let orient = readOrientation(url: url)
                if orient >= 5 && orient <= 8 {
                    // RAW says portrait (orientation 5-8 = rotated 90°)
                    // If embedded JPEG is landscape (w > h), it needs rotation
                    if img.size.width > img.size.height {
                        img = rotateImage(img, orientation: orient)
                    }
                } else if orient == 1 {
                    // RAW says normal (no rotation needed)
                    // But some cameras store embedded JPEG already rotated
                    // If RAW pixel W > H (landscape) but embedded is H > W (portrait), undo rotation
                    let srcOpts: [NSString: Any] = [kCGImageSourceShouldCache: false]
                    if let source = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary),
                       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                       let rawW = props[kCGImagePropertyPixelWidth as String] as? Int,
                       let rawH = props[kCGImagePropertyPixelHeight as String] as? Int {
                        let rawIsLandscape = rawW > rawH
                        let imgIsLandscape = img.size.width > img.size.height
                        if rawIsLandscape != imgIsLandscape {
                            // Mismatch: embedded JPEG has wrong orientation, rotate to match RAW
                            img = rotateImage(img, orientation: 6)  // 90° CW
                        }
                    }
                }
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                if ms > 300 { print("⏱ [EMB] \(url.lastPathComponent): \(String(format: "%.0f", ms))ms (embedded OK)") }
                return img
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("⏱ [EMB] \(url.lastPathComponent): \(String(format: "%.0f", ms))ms (embedded FAIL → CGImageSource)")
        }

        // CGImageSource path
        let srcOpts: [NSString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else {
            return nil
        }
        let imageCount = CGImageSourceGetCount(source)

        if isRAW {
            // RAW: try existing embedded thumbnail ONLY (no full decode for thumbnails)
            let opts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: thumbSize,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false
            ]
            // Try each image index for an existing thumbnail
            for idx in 0..<imageCount {
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, idx, opts as CFDictionary) {
                    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                }
            }

            // Last resort: decode at smallest possible size
            let fallbackOpts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: thumbSize,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceSubsampleFactor: 8,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, fallbackOpts as CFDictionary) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        } else {
            // JPG/PNG: use SubsampleFactor for 2-4x faster JPEG decode
            // SubsampleFactor: 2 = 1/2 size decode, 4 = 1/4 size decode
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            let origW = props?[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let origH = props?[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            let origMax = max(origW, origH)

            // Calculate optimal subsample factor
            var subsample = 1
            if origMax > thumbSize * 8 { subsample = 8 }       // 6000px+ → 1/8 decode
            else if origMax > thumbSize * 4 { subsample = 4 }  // 800px+ → 1/4 decode
            else if origMax > thumbSize * 2 { subsample = 2 }  // 400px+ → 1/2 decode

            var options: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: thumbSize,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false
            ]
            if subsample > 1 {
                options[kCGImageSourceSubsampleFactor as NSString] = subsample
            }

            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        return nil
    }

    /// Extract embedded JPEG from RAW files that macOS can't decode (e.g., Nikon Z8/Z9 High Efficiency)
    /// Scans for FFD8 JPEG markers and returns the best-sized embedded preview.
    /// Uses tiered read: 512KB first (covers most thumbnails), then 3MB if needed.
    private static func extractEmbeddedJPEG(url: URL, maxSize: Int) -> NSImage? {
        let isNAS = ThumbnailLoader.shared.isNetworkMode

        // Tiered read: small read first, expand only if no JPEG found
        // Most RAW embedded thumbnails live within the first 200-500KB
        let firstReadSize = isNAS ? 512_000 : 1_000_000
        let maxReadSize = isNAS ? 1_500_000 : 3_000_000

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { return nil }

        var data = handle.readData(ofLength: firstReadSize)
        guard data.count > 100 else { handle.closeFile(); return nil }

        // Scan for FFD8 markers
        if let img = findBestEmbeddedJPEG(in: data, maxSize: maxSize) {
            handle.closeFile()
            return img
        }

        // First read had no usable JPEG — read more (only if not NAS-constrained or needed)
        if data.count >= firstReadSize && maxReadSize > firstReadSize {
            let moreData = handle.readData(ofLength: maxReadSize - firstReadSize)
            if !moreData.isEmpty {
                data.append(moreData)
                handle.closeFile()
                return findBestEmbeddedJPEG(in: data, maxSize: maxSize)
            }
        }

        handle.closeFile()
        return nil
    }

    /// Find best embedded JPEG in data by scanning for FFD8 markers (parallel)
    private static func findBestEmbeddedJPEG(in data: Data, maxSize: Int) -> NSImage? {
        // Use parallel scanner for finding FFD8 markers
        let offsets = ParallelFFD8Scanner.findMarkers(in: data, maxMarkers: 8)
        guard !offsets.isEmpty else { return nil }

        var bestImage: NSImage?
        var bestSize = 0

        for offset in offsets {
            let end = min(offset + 1_500_000, data.count)
            let subData = data.subdata(in: offset..<end)
            guard let imgSource = CGImageSourceCreateWithData(subData as CFData, nil),
                  CGImageSourceGetCount(imgSource) > 0 else { continue }

            let thumbOpts: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(imgSource, 0, thumbOpts as CFDictionary) {
                let size = cgImage.width * cgImage.height
                if size > bestSize {
                    bestSize = size
                    bestImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    if cgImage.width >= maxSize { return bestImage }
                }
            }
        }

        return bestImage
    }
}

// MARK: - Async Thumbnail View

struct AsyncThumbnailView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
            }
        }
        .onAppear {
            if image == nil || loadedURL != url {
                loadThumbnail()
            }
        }
        .onChange(of: url) { newURL in
            if loadedURL != newURL {
                // Don't nil out image - keep old one until new loads
                loadThumbnail()
            }
        }
    }

    private func loadThumbnail() {
        loadedURL = url
        let currentURL = url
        ThumbnailLoader.shared.load(url: currentURL) { img in
            if self.loadedURL == currentURL && img.size.width > 2 {
                self.image = img
            }
        }
        // Retry after 1s if still no image (handles race conditions)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if self.image == nil && self.loadedURL == currentURL {
                ThumbnailLoader.shared.load(url: currentURL) { img in
                    if self.loadedURL == currentURL {
                        self.image = img
                    }
                }
            }
        }
    }
}

// MARK: - Multi-File Drag (NSView-based, bypasses SwiftUI single-item limitation)

struct MultiFileDragView: NSViewRepresentable {
    let photo: PhotoItem
    let store: PhotoStore

    func makeNSView(context: Context) -> DragOverlayNSView {
        let view = DragOverlayNSView()
        view.photo = photo
        view.store = store
        return view
    }

    func updateNSView(_ nsView: DragOverlayNSView, context: Context) {
        nsView.photo = photo
        nsView.store = store
    }

    class DragOverlayNSView: NSView {
        var photo: PhotoItem?
        var store: PhotoStore?
        private var mouseDownPoint: NSPoint?
        private var didStartDrag = false

        override var acceptsFirstResponder: Bool { false }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = event.locationInWindow
            didStartDrag = false
            // Don't call super — let SwiftUI handle via nextResponder
            nextResponder?.mouseDown(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownPoint = nil
            didStartDrag = false
            nextResponder?.mouseUp(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !didStartDrag, let startPoint = mouseDownPoint else {
                nextResponder?.mouseDragged(with: event)
                return
            }

            let current = event.locationInWindow
            let distance = hypot(current.x - startPoint.x, current.y - startPoint.y)

            // Need 8px movement to start drag
            guard distance > 8 else {
                nextResponder?.mouseDragged(with: event)
                return
            }

            didStartDrag = true
            mouseDownPoint = nil

            guard let store = store, let photo = photo else { return }
            guard !photo.isFolder && !photo.isParentFolder else { return }

            // Collect all selected file URLs
            let ids = store.selectedPhotoIDs.contains(photo.id) ? store.selectedPhotoIDs : [photo.id]
            var fileURLs: [URL] = []
            for id in ids {
                guard let idx = store._photoIndex[id], idx < store.photos.count else { continue }
                let p = store.photos[idx]
                guard !p.isFolder && !p.isParentFolder else { continue }
                fileURLs.append(p.jpgURL)
                if let rawURL = p.rawURL, rawURL != p.jpgURL { fileURLs.append(rawURL) }
            }
            guard !fileURLs.isEmpty else { return }

            // Create dragging items for each file
            var items: [NSDraggingItem] = []
            for (i, url) in fileURLs.enumerated() {
                let pbItem = NSPasteboardItem()
                pbItem.setString(url.absoluteString, forType: .fileURL)
                let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
                let offset = CGFloat(i * 3)
                dragItem.setDraggingFrame(
                    NSRect(x: offset, y: offset, width: 40, height: 40),
                    contents: NSWorkspace.shared.icon(forFile: url.path)
                )
                items.append(dragItem)
            }

            beginDraggingSession(with: items, event: event, source: self)
        }
    }
}

extension MultiFileDragView.DragOverlayNSView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? [.copy] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] {
            store?.showToastMessage("📂 파일 복사 완료")
        }
    }
}

