import SwiftUI
import AppKit

// MARK: - NSViewRepresentable Wrapper

struct NSThumbnailCollectionView: NSViewRepresentable {
    @EnvironmentObject var store: PhotoStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        // Flow layout
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let size = store.thumbnailSize
        layout.itemSize = NSSize(width: size + 10, height: size * 0.75 + 50)

        // Collection view
        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.register(ThumbnailCollectionViewItem.self, forItemWithIdentifier: ThumbnailCollectionViewItem.identifier)

        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        coordinator.collectionView = collectionView

        // Scroll view
        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        coordinator.scrollView = scrollView

        // Initial data load
        coordinator.photos = store.filteredPhotos
        coordinator.photosVersion = store.photosVersion
        collectionView.reloadData()
        fputs("[GRID] makeNSView: \(coordinator.photos.count) photos, reloaded\n", stderr)
        coordinator.thumbnailSize = store.thumbnailSize
        coordinator.showFileExtension = store.showFileExtension
        coordinator.showFileTypeBadge = store.showFileTypeBadge

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let collectionView = coordinator.collectionView else { return }
        coordinator.store = store

        fputs("[GRID] update: old=\(coordinator.photos.count) new=\(store.filteredPhotos.count) ver=\(store.photosVersion) frame=\(Int(scrollView.frame.width))x\(Int(scrollView.frame.height))\n", stderr)

        let newPhotos = store.filteredPhotos
        let newSize = store.thumbnailSize
        let newShowExt = store.showFileExtension
        let newShowBadge = store.showFileTypeBadge
        let newScroll = store.scrollTrigger

        // Update layout if thumbnail size changed
        if coordinator.thumbnailSize != newSize {
            coordinator.thumbnailSize = newSize
            if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.itemSize = NSSize(width: newSize + 10, height: newSize * 0.75 + 50)
                layout.invalidateLayout()
            }
        }

        // Update display options
        let optionsChanged = coordinator.showFileExtension != newShowExt || coordinator.showFileTypeBadge != newShowBadge
        coordinator.showFileExtension = newShowExt
        coordinator.showFileTypeBadge = newShowBadge

        // Data changed - full reload (check version + count + IDs)
        let photosChanged = coordinator.photos.count != newPhotos.count ||
            coordinator.photosVersion != store.photosVersion ||
            optionsChanged
        if photosChanged {
            coordinator.isBatchUpdating = true
            coordinator.photos = newPhotos
            coordinator.photosVersion = store.photosVersion
            collectionView.reloadData()
            coordinator.isBatchUpdating = false
            // Restore selection after reload
            syncSelectionToCollectionView(coordinator: coordinator, collectionView: collectionView)
        } else {
            // Check if individual photo properties changed (ratings, SP, etc.)
            var changedIndices: [Int] = []
            for i in 0..<newPhotos.count {
                let old = coordinator.photos[i]
                let new = newPhotos[i]
                if old.rating != new.rating || old.isSpacePicked != new.isSpacePicked ||
                   old.isGSelected != new.isGSelected || old.colorLabel != new.colorLabel ||
                   old.quality?.isAnalyzed != new.quality?.isAnalyzed ||
                   old.isCorrected != new.isCorrected || old.isAIPick != new.isAIPick ||
                   old.sceneTag != new.sceneTag || old.aiCategory != new.aiCategory ||
                   old.aiScore != new.aiScore || old.comments.count != new.comments.count ||
                   old.faceGroupID != new.faceGroupID {
                    changedIndices.append(i)
                }
            }
            coordinator.photos = newPhotos
            if !changedIndices.isEmpty {
                let indexPaths = Set(changedIndices.map { IndexPath(item: $0, section: 0) })
                // Reload only changed cells
                collectionView.reloadItems(at: indexPaths)
            }
        }

        // Sync selection from store to collection view (only selection/focus changes)
        syncSelectionToCollectionView(coordinator: coordinator, collectionView: collectionView)

        // Scroll to selection if triggered
        if coordinator.lastScrollTrigger != newScroll {
            coordinator.lastScrollTrigger = newScroll
            if let selectedID = store.selectedPhotoID,
               let idx = coordinator.photos.firstIndex(where: { $0.id == selectedID }) {
                let indexPath = IndexPath(item: idx, section: 0)
                collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
            }
        }
    }

    private func syncSelectionToCollectionView(coordinator: Coordinator, collectionView: NSCollectionView) {
        let storeSelection = store.selectedPhotoIDs
        let storeIndexPaths = Set(storeSelection.compactMap { id -> IndexPath? in
            guard let idx = coordinator.photos.firstIndex(where: { $0.id == id }) else { return nil }
            return IndexPath(item: idx, section: 0)
        })

        let currentSelection = collectionView.selectionIndexPaths

        if storeIndexPaths != currentSelection {
            coordinator.isBatchUpdating = true
            collectionView.selectionIndexPaths = storeIndexPaths
            coordinator.isBatchUpdating = false
        }

        // Refresh visible cells for focus/selection highlighting
        for indexPath in collectionView.indexPathsForVisibleItems() {
            if let item = collectionView.item(at: indexPath) as? ThumbnailCollectionViewItem {
                let idx = indexPath.item
                guard idx < coordinator.photos.count else { continue }
                let photo = coordinator.photos[idx]
                let isSelected = storeSelection.contains(photo.id)
                let isFocused = store.selectedPhotoID == photo.id
                item.updateSelection(isSelected: isSelected, isFocused: isFocused, isSpacePicked: photo.isSpacePicked)
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
        var store: PhotoStore
        var collectionView: NSCollectionView?
        var scrollView: NSScrollView?
        var photos: [PhotoItem] = []
        var photosVersion: Int = -1
        var thumbnailSize: CGFloat = 120
        var showFileExtension: Bool = true
        var showFileTypeBadge: Bool = true
        var isBatchUpdating: Bool = false
        var lastScrollTrigger: Int = 0

        init(store: PhotoStore) {
            self.store = store
        }

        // MARK: DataSource

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            fputs("[GRID] numberOfItems: \(photos.count)\n", stderr)
            return photos.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailCollectionViewItem.identifier, for: indexPath) as! ThumbnailCollectionViewItem
            let idx = indexPath.item
            guard idx < photos.count else { return item }
            let photo = photos[idx]
            let isSelected = store.selectedPhotoIDs.contains(photo.id)
            let isFocused = store.selectedPhotoID == photo.id
            item.configure(
                photo: photo,
                size: thumbnailSize,
                isSelected: isSelected,
                isFocused: isFocused,
                showFileExtension: showFileExtension,
                showFileTypeBadge: showFileTypeBadge
            )
            return item
        }

        // MARK: Delegate - Selection

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard !isBatchUpdating else { return }
            handleSelectionChange(collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            guard !isBatchUpdating else { return }
            handleSelectionChange(collectionView)
        }

        private func handleSelectionChange(_ collectionView: NSCollectionView) {
            let selectedIndexPaths = collectionView.selectionIndexPaths
            var newIDs = Set<UUID>()
            var focusID: UUID? = nil

            for indexPath in selectedIndexPaths {
                let idx = indexPath.item
                guard idx < photos.count else { continue }
                let id = photos[idx].id
                newIDs.insert(id)
                focusID = id  // Last one becomes focus
            }

            // Update store
            store.selectedPhotoIDs = newIDs
            if let focus = focusID {
                store.selectedPhotoID = focus
            } else if newIDs.isEmpty {
                store.selectedPhotoID = nil
            }

            // Handle folder/parent folder double-click is in shouldSelectItems
            // Update visual state for visible cells
            for indexPath in collectionView.indexPathsForVisibleItems() {
                if let item = collectionView.item(at: indexPath) as? ThumbnailCollectionViewItem {
                    let i = indexPath.item
                    guard i < photos.count else { continue }
                    let photo = photos[i]
                    let sel = newIDs.contains(photo.id)
                    let foc = store.selectedPhotoID == photo.id
                    item.updateSelection(isSelected: sel, isFocused: foc, isSpacePicked: photo.isSpacePicked)
                }
            }
        }

        // MARK: Double click for folders

        func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
            // Check for double-click on folder
            if let event = NSApp.currentEvent, event.clickCount == 2 {
                for indexPath in indexPaths {
                    let idx = indexPath.item
                    guard idx < photos.count else { continue }
                    let photo = photos[idx]
                    if photo.isFolder || photo.isParentFolder {
                        DispatchQueue.main.async { [weak self] in
                            self?.store.loadFolder(photo.jpgURL)
                        }
                        return []  // Don't select, navigate instead
                    }
                }
            }
            return indexPaths
        }
    }
}

// MARK: - Collection View Item (Cell)

class ThumbnailCollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCollectionViewItem")

    private var thumbnailImageView: NSImageView!
    private var fileNameLabel: NSTextField!
    private var starsContainer: NSStackView!
    private var badgeContainer: NSStackView!  // top-right badges (file type, corrected)
    private var pickContainer: NSStackView!   // top-left badges (G, SP, PICK, etc.)
    private var gradeLabel: BadgeLabel!       // bottom-left grade
    private var sceneLabel: BadgeLabel!       // bottom-right scene tag
    private var borderView: NSView!
    private var currentPhotoURL: URL?
    private var currentSize: CGFloat = 120
    private var starViews: [NSImageView] = []

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        self.view = container

        // Border/background view (full cell)
        borderView = NSView()
        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = AppTheme.cellCornerRadius + 2
        borderView.layer?.borderWidth = 0
        container.addSubview(borderView)

        // Thumbnail image
        thumbnailImageView = NSImageView()
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = AppTheme.cellCornerRadius
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailImageView.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        container.addSubview(thumbnailImageView)

        // File name
        fileNameLabel = NSTextField(labelWithString: "")
        fileNameLabel.font = NSFont.systemFont(ofSize: AppTheme.fontCaption)
        fileNameLabel.lineBreakMode = .byTruncatingTail
        fileNameLabel.maximumNumberOfLines = 1
        fileNameLabel.alignment = .center
        container.addSubview(fileNameLabel)

        // Stars
        starsContainer = NSStackView()
        starsContainer.orientation = .horizontal
        starsContainer.spacing = 0
        starsContainer.alignment = .centerY
        for _ in 0..<5 {
            let star = NSImageView()
            star.imageScaling = .scaleProportionallyUpOrDown
            starViews.append(star)
            starsContainer.addArrangedSubview(star)
        }
        container.addSubview(starsContainer)

        // Badge containers (positioned as overlays on thumbnail)
        badgeContainer = NSStackView()
        badgeContainer.orientation = .vertical
        badgeContainer.alignment = .trailing
        badgeContainer.spacing = 2
        container.addSubview(badgeContainer)

        pickContainer = NSStackView()
        pickContainer.orientation = .vertical
        pickContainer.alignment = .leading
        pickContainer.spacing = 2
        container.addSubview(pickContainer)

        // Grade label (bottom-left)
        gradeLabel = BadgeLabel()
        gradeLabel.isHidden = true
        container.addSubview(gradeLabel)

        // Scene label (bottom-right)
        sceneLabel = BadgeLabel()
        sceneLabel.isHidden = true
        container.addSubview(sceneLabel)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutSubviews()
    }

    private func layoutSubviews() {
        let bounds = view.bounds
        let padding: CGFloat = 5
        let size = currentSize
        let imgH = size * 0.75

        borderView.frame = bounds

        let imgX = (bounds.width - size) / 2
        let imgY = bounds.height - padding - imgH
        thumbnailImageView.frame = NSRect(x: imgX, y: imgY, width: size, height: imgH)

        let labelY = imgY - 16
        fileNameLabel.frame = NSRect(x: padding, y: labelY, width: bounds.width - padding * 2, height: 14)

        let starSize = max(8, size * 0.06) + 1
        for sv in starViews {
            sv.frame = NSRect(x: 0, y: 0, width: starSize, height: starSize)
        }
        let starsW = starSize * 5
        starsContainer.frame = NSRect(x: (bounds.width - starsW) / 2, y: labelY - starSize - 4, width: starsW, height: starSize + 2)

        // Badge overlays on thumbnail
        badgeContainer.frame = NSRect(x: imgX + size - 50, y: imgY + imgH - 30, width: 46, height: 28)
        pickContainer.frame = NSRect(x: imgX + 4, y: imgY + imgH - 60, width: 50, height: 56)
        gradeLabel.frame = NSRect(x: imgX + 4, y: imgY + 4, width: 30, height: 16)
        sceneLabel.frame = NSRect(x: imgX + size - 60, y: imgY + 4, width: 56, height: 16)
    }

    func configure(photo: PhotoItem, size: CGFloat, isSelected: Bool, isFocused: Bool, showFileExtension: Bool, showFileTypeBadge: Bool) {
        currentSize = size
        let imgH = size * 0.75

        // Resize item
        view.frame = NSRect(x: 0, y: 0, width: size + 10, height: size * 0.75 + 50)

        // Handle folder items
        if photo.isParentFolder || photo.isFolder {
            configureFolderItem(photo: photo, size: size, isSelected: isSelected)
            return
        }

        // Thumbnail loading
        if currentPhotoURL != photo.jpgURL {
            currentPhotoURL = photo.jpgURL
            thumbnailImageView.image = nil
            thumbnailImageView.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor

            // Load from cache or async
            if let cached = ThumbnailCache.shared.get(photo.jpgURL) {
                thumbnailImageView.image = cached
                thumbnailImageView.layer?.backgroundColor = nil
            } else {
                ThumbnailLoader.shared.load(url: photo.jpgURL) { [weak self] image in
                    DispatchQueue.main.async {
                        guard self?.currentPhotoURL == photo.jpgURL else { return }
                        self?.thumbnailImageView.image = image
                        self?.thumbnailImageView.layer?.backgroundColor = nil
                    }
                }
            }
        }

        thumbnailImageView.isHidden = false

        // File name
        let name = showFileExtension ? photo.fileNameWithExtension : photo.fileName
        fileNameLabel.stringValue = name
        fileNameLabel.isHidden = false

        // Stars
        let starSize = max(8, size * 0.06)
        for (i, sv) in starViews.enumerated() {
            let filled = (i + 1) <= photo.rating
            let config = NSImage.SymbolConfiguration(pointSize: starSize, weight: .regular)
            sv.image = NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            sv.contentTintColor = filled ? NSColor(AppTheme.starGold) : NSColor.gray.withAlphaComponent(0.25)
        }
        starsContainer.isHidden = false

        // File type badge (top-right)
        badgeContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if showFileTypeBadge {
            let badge = photo.fileTypeBadge
            let badgeColor = badgeNSColor(badge.color)
            let label = makeBadgeLabel(badge.text, color: badgeColor)
            badgeContainer.addArrangedSubview(label)
            if photo.isCorrected {
                let corrLabel = makeBadgeLabel("보정", color: NSColor.systemTeal)
                badgeContainer.addArrangedSubview(corrLabel)
            }
        }
        badgeContainer.isHidden = !showFileTypeBadge

        // Pick badges (top-left)
        pickContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if photo.isGSelected {
            let gl = makeBadgeLabel("G", color: NSColor.systemGreen)
            pickContainer.addArrangedSubview(gl)
        }
        if photo.isSpacePicked {
            let spl = makeBadgeLabel("SP", color: NSColor(AppTheme.error))
            pickContainer.addArrangedSubview(spl)
        }
        if !photo.comments.isEmpty {
            let cl = makeBadgeLabel("\(photo.comments.count)", color: NSColor.systemOrange)
            pickContainer.addArrangedSubview(cl)
        }
        if photo.isAIPick {
            let pl = makeBadgeLabel("PICK", color: NSColor(AppTheme.pickBadge))
            pickContainer.addArrangedSubview(pl)
        }
        if let fgID = photo.faceGroupID {
            let fl = makeBadgeLabel("\(fgID + 1)", color: NSColor.systemOrange.withAlphaComponent(0.85))
            pickContainer.addArrangedSubview(fl)
        }
        pickContainer.isHidden = pickContainer.arrangedSubviews.isEmpty

        // Grade (bottom-left)
        if let quality = photo.quality, quality.isAnalyzed {
            gradeLabel.text = quality.overallGrade.rawValue
            gradeLabel.bgColor = NSColor(AppTheme.gradeColor(quality.overallGrade)).withAlphaComponent(0.85)
            gradeLabel.isHidden = false
        } else {
            gradeLabel.isHidden = true
        }

        // Scene tag (bottom-right)
        let tag = photo.aiCategory ?? photo.sceneTag
        if let tag = tag {
            var tagText = tag
            if let score = photo.aiScore { tagText += " \(score)" }
            sceneLabel.text = tagText
            sceneLabel.bgColor = photo.aiCategory != nil ? NSColor.purple.withAlphaComponent(0.6) : NSColor.black.withAlphaComponent(0.5)
            sceneLabel.isHidden = false
        } else {
            sceneLabel.isHidden = true
        }

        // Selection / focus
        updateSelection(isSelected: isSelected, isFocused: isFocused, isSpacePicked: photo.isSpacePicked)

        layoutSubviews()
    }

    private func configureFolderItem(photo: PhotoItem, size: CGFloat, isSelected: Bool) {
        // Hide photo-specific views
        starsContainer.isHidden = true
        badgeContainer.isHidden = true
        pickContainer.isHidden = true
        gradeLabel.isHidden = true
        sceneLabel.isHidden = true
        currentPhotoURL = nil

        // Show folder icon
        let iconName = photo.isParentFolder ? "chevron.up" : "folder.fill"
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.25, weight: .medium)
        thumbnailImageView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        thumbnailImageView.contentTintColor = .systemBlue
        thumbnailImageView.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.08).cgColor
        thumbnailImageView.isHidden = false

        fileNameLabel.stringValue = photo.jpgURL.lastPathComponent
        fileNameLabel.isHidden = false

        updateSelection(isSelected: isSelected, isFocused: false, isSpacePicked: false)
        layoutSubviews()
    }

    func updateSelection(isSelected: Bool, isFocused: Bool, isSpacePicked: Bool) {
        guard let layer = borderView.layer else { return }

        if isSpacePicked {
            layer.borderColor = NSColor(AppTheme.spPickBorder).cgColor
            layer.borderWidth = AppTheme.focusBorderWidth
        } else if isFocused {
            layer.borderColor = NSColor(AppTheme.focusBorder).cgColor
            layer.borderWidth = AppTheme.focusBorderWidth
        } else if isSelected {
            layer.borderColor = NSColor(AppTheme.selectionBorder).withAlphaComponent(0.5).cgColor
            layer.borderWidth = AppTheme.cellBorderWidth
        } else {
            layer.borderColor = NSColor.clear.cgColor
            layer.borderWidth = 0
        }

        if isFocused {
            layer.backgroundColor = NSColor(AppTheme.accent).withAlphaComponent(0.12).cgColor
        } else if isSelected {
            layer.backgroundColor = NSColor(AppTheme.accent).withAlphaComponent(0.06).cgColor
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentPhotoURL = nil
        thumbnailImageView.image = nil
        thumbnailImageView.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        thumbnailImageView.contentTintColor = nil
        fileNameLabel.stringValue = ""
        starsContainer.isHidden = true
        badgeContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pickContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        gradeLabel.isHidden = true
        sceneLabel.isHidden = true
        borderView.layer?.borderWidth = 0
        borderView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    // MARK: - Helper

    private func badgeNSColor(_ colorName: String) -> NSColor {
        switch colorName {
        case "orange": return .systemOrange
        case "green": return .systemGreen
        case "purple": return .systemPurple
        case "teal": return .systemTeal
        case "gray": return .systemGray
        default: return .systemBlue
        }
    }

    private func makeBadgeLabel(_ text: String, color: NSColor) -> NSView {
        let label = BadgeLabel()
        label.text = text
        label.bgColor = color.withAlphaComponent(0.85)
        label.frame = NSRect(x: 0, y: 0, width: 36, height: 14)
        return label
    }
}

// MARK: - Badge Label (simple rounded-bg text)

class BadgeLabel: NSView {
    var text: String = "" { didSet { needsDisplay = true } }
    var bgColor: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var textColor: NSColor = .white { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var intrinsicContentSize: NSSize {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 8)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        return NSSize(width: size.width + 8, height: size.height + 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        bgColor.setFill()
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 8),
            .foregroundColor: textColor
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let x = (bounds.width - size.width) / 2
        let y = (bounds.height - size.height) / 2
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }
}
