import SwiftUI
import AppKit

// MARK: - NSViewRepresentable Wrapper

struct NSThumbnailCollectionView: NSViewRepresentable {
    /// v8.9.4: 가장 최근에 만들어진 Coordinator 참조 — CacheSweeper 가 isScrollingNow 폴링용
    static weak var activeCoordinator: Coordinator?
    /// v9.1.3: 방향 prefetch throttle 상태
    static var lastPrefetchAt: CFAbsoluteTime = 0
    static var lastPrefetchDirection: Int = 0
    @EnvironmentObject var store: PhotoStore

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(store: store)
        NSThumbnailCollectionView.activeCoordinator = c
        return c
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        // Flow layout
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let size = store.thumbnailSize
        layout.itemSize = ThumbnailCollectionViewItem.itemSize(for: size)

        // Collection view
        let collectionView = ThumbnailNSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.register(ThumbnailCollectionViewItem.self, forItemWithIdentifier: ThumbnailCollectionViewItem.identifier)

        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.thumbnailCoordinator = coordinator
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
        coordinator.rebuildIndexMap()
        coordinator.photosVersion = store.photosVersion
        collectionView.reloadData()
        plog("[GRID] makeNSView: \(coordinator.photos.count) photos, reloaded\n")
        coordinator.thumbnailSize = store.thumbnailSize
        coordinator.showFileExtension = store.showFileExtension
        coordinator.showFileTypeBadge = store.showFileTypeBadge

        // 스크롤 시 대기 중인 썸네일 로딩 취소 (새 영역만 로딩)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let _t0 = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - _t0) * 1000
            if ms > 1 {
                plog("[GRID-UPDATE] \(String(format: "%.0f", ms))ms (photos=\(self.store.filteredPhotos.count))\n")
            }
        }
        let coordinator = context.coordinator
        guard let collectionView = coordinator.collectionView else { return }
        coordinator.store = store

        let newPhotos = store.filteredPhotos
        let newSize = store.thumbnailSize
        let newShowExt = store.showFileExtension
        let newShowBadge = store.showFileTypeBadge
        let newScroll = store.scrollTrigger

        // Update layout if thumbnail size changed
        // v8.9.4: 크기만 invalidateLayout 하면 기존 보이는 셀 내부 subview 좌표가 옛값으로 남아
        //         라벨·별점이 이중 그려짐(잔상). reloadData 까지 해서 모든 셀 재구성 강제.
        let sizeChanged = coordinator.thumbnailSize != newSize
        if sizeChanged {
            coordinator.thumbnailSize = newSize
            if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.itemSize = ThumbnailCollectionViewItem.itemSize(for: newSize)
                layout.invalidateLayout()
            }
        }
        // 열 수 계산 (방향키 행 이동용) — NSCollectionView 실제 폭 기반
        // CRITICAL: view update 중 @Published 변경 금지 → 무한 재렌더 루프 유발.
        //   DispatchQueue.main.async 로 다음 런루프에 지연시켜 업데이트 사이클 탈출.
        let gridWidth = scrollView.frame.width - 16  // sectionInset left+right
        let cellWidth = newSize + 10 + 12  // itemWidth + interItemSpacing
        // v8.9.7+: 5열 cap 제거 — Bridge 스타일. 썸네일 작으면 컬럼 많이, 크면 적게.
        //   사용자가 패널 폭을 늘리면 컬럼이 자동으로 늘어남 (이전 5열 cap 으로 막혀있던 문제).
        let cols = max(1, Int(gridWidth / cellWidth))
        // v9.1.4 (C-5): Coordinator 에 lastCols 추적 — 같은 cols 면 dispatch 자체 skip.
        //   이전엔 store.actualColumnsPerRow != cols 체크만 → 매 updateNSView 마다 dispatch 발사.
        if coordinator.lastDispatchedCols != cols {
            coordinator.lastDispatchedCols = cols
            if store.actualColumnsPerRow != cols {
                DispatchQueue.main.async {
                    if store.actualColumnsPerRow != cols {
                        store.actualColumnsPerRow = cols
                    }
                }
            }
        }

        // Update display options
        let optionsChanged = coordinator.showFileExtension != newShowExt || coordinator.showFileTypeBadge != newShowBadge
        coordinator.showFileExtension = newShowExt
        coordinator.showFileTypeBadge = newShowBadge

        // Data changed - full reload (check version + count + IDs)
        // v8.9.4: sizeChanged 도 reload 트리거에 포함 — 셀 내부 subview 좌표 재계산 강제
        // v9.1.4 (R-2): 썸네일 슬라이더 드래그 중 매 step 마다 17,000셀 reloadData 폭발 방지.
        //   sizeChanged 만 단독 발생 시 150ms throttle — 슬라이더 멈춘 후 1회만 reloadData.
        var sizeChangedReloadEffective = sizeChanged
        if sizeChanged && !optionsChanged
            && coordinator.photos.count == newPhotos.count
            && coordinator.photosVersion == store.photosVersion {
            let now = Date()
            if now.timeIntervalSince(coordinator.lastSizeReloadAt) < 0.15 {
                sizeChangedReloadEffective = false  // throttle: layout 만 invalidate, reload skip
            } else {
                coordinator.lastSizeReloadAt = now
            }
        }
        let photosChanged = coordinator.photos.count != newPhotos.count ||
            coordinator.photosVersion != store.photosVersion ||
            optionsChanged || sizeChangedReloadEffective
        // v8.9.4: recursive scan 중에는 reload 를 250ms throttle (batch coalescing 와 정합)
        //   첫 batch 와 sizeChanged/optionsChanged 는 즉시 반영, 그 외는 250ms 누적.
        // v8.9.6: scan 종료 직후 첫 update 는 강제 reload — throttle 윈도우에 묻혀서
        //   마지막 batch 의 정렬 결과가 화면에 반영 안 되던 버그 수정.
        let scanJustEnded = coordinator.wasRecursiveScanInProgress && !store.isRecursiveScanInProgress
        coordinator.wasRecursiveScanInProgress = store.isRecursiveScanInProgress
        if photosChanged && store.isRecursiveScanInProgress
            && !coordinator.photos.isEmpty && !sizeChanged && !optionsChanged
            && !scanJustEnded {
            let now = Date()
            if now.timeIntervalSince(coordinator.lastRecursiveReloadAt) < 0.25 {
                // 옛 photos snapshot 만 갱신 (다음 throttle 후 reload 시 fresh)
                coordinator.photos = newPhotos
                coordinator.photosVersion = store.photosVersion
                return
            }
            coordinator.lastRecursiveReloadAt = now
        }
        if photosChanged {
            coordinator.isBatchUpdating = true
            coordinator.photos = newPhotos
            coordinator.rebuildIndexMap()
            coordinator.photosVersion = store.photosVersion
            // v8.9.4: 셀 애니메이션 완전 차단 — 다른 PC (구형 GPU/macOS)에서
            //         옛 프레임 잔상이 새 프레임 위에 보이는 현상 해결.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                collectionView.reloadData()
            })
            CATransaction.commit()
            coordinator.isBatchUpdating = false
            // Restore selection after reload
            syncSelectionToCollectionView(coordinator: coordinator, collectionView: collectionView)
            // v8.9.4: 폴더/사이즈 변경 직후 초기 viewport 동기화 — 보이지 않는 cell 의 thumbnail 작업 즉시 폐기
            DispatchQueue.main.async { [weak coordinator, weak collectionView] in
                guard let c = coordinator, let cv = collectionView else { return }
                c.syncViewportToLoader(cv)
            }
        } else {
            // 보이는 셀만 속성 비교 + 변경된 셀만 리로드
            let visiblePaths = collectionView.indexPathsForVisibleItems()
            var changedPaths: Set<IndexPath> = []
            for ip in visiblePaths {
                let i = ip.item
                guard i < newPhotos.count, i < coordinator.photos.count else { continue }
                let old = coordinator.photos[i]
                let new = newPhotos[i]
                if old.rating != new.rating || old.isSpacePicked != new.isSpacePicked ||
                   old.isGSelected != new.isGSelected || old.colorLabel != new.colorLabel ||
                   old.isCorrected != new.isCorrected || old.isAIPick != new.isAIPick {
                    changedPaths.insert(ip)
                }
            }
            coordinator.photos = newPhotos
            if !changedPaths.isEmpty {
                collectionView.reloadItems(at: changedPaths)
            }
        }

        // Sync selection from store to collection view (only selection/focus changes)
        syncSelectionToCollectionView(coordinator: coordinator, collectionView: collectionView)

        // Scroll to selection if triggered
        // v8.9.4: 이미 visible rect 안이면 scroll skip — 방향키 burst 중 scroll 보정으로 끊김 방지
        if coordinator.lastScrollTrigger != newScroll {
            coordinator.lastScrollTrigger = newScroll
            if let selectedID = store.selectedPhotoID,
               let idx = coordinator.indexByID[selectedID] {
                let indexPath = IndexPath(item: idx, section: 0)
                let visiblePaths = collectionView.indexPathsForVisibleItems()
                // 정확히 visible 안에 들어있으면 (가려진 일부분 셀까지 포함) scroll 호출 안 함.
                // 단, edge cell (절반만 보이는) 일 수 있어 visible set 만으로 OK.
                if !visiblePaths.contains(indexPath) {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0  // no animation — 즉시 점프
                        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
                    }
                }
            }
        }
    }

    private func syncSelectionToCollectionView(coordinator: Coordinator, collectionView: NSCollectionView) {
        let focusedID = store.selectedPhotoID
        var storeSelection = store.selectedPhotoIDs
        if let focusedID, !storeSelection.contains(focusedID) {
            if storeSelection.count <= 1 {
                storeSelection = [focusedID]
            } else {
                storeSelection.insert(focusedID)
            }
            DispatchQueue.main.async {
                if self.store.selectedPhotoID == focusedID,
                   !self.store.selectedPhotoIDs.contains(focusedID) {
                    if self.store.selectedPhotoIDs.count <= 1 {
                        self.store.selectedPhotoIDs = [focusedID]
                    } else {
                        self.store.selectedPhotoIDs.insert(focusedID)
                    }
                }
            }
        }

        // v9.1.4: fast-path — selection 도, focus 도 그대로면 즉시 return.
        //   updateNSView 는 임의의 @Published (예: thumbCacheCount) 변경에도 호출됨.
        //   50+ visible cells horizontal nav 시 매 프레임 indexPathsForVisibleItems()/Set 빌드 회피.
        if storeSelection == coordinator.lastSyncedSelection
            && focusedID == coordinator.lastSyncedFocusedID {
            return
        }

        let storeIndexPaths = Set(storeSelection.compactMap { id -> IndexPath? in
            guard let idx = coordinator.indexByID[id] else { return nil }
            return IndexPath(item: idx, section: 0)
        })

        let currentSelection = collectionView.selectionIndexPaths

        if storeIndexPaths != currentSelection {
            coordinator.isBatchUpdating = true
            collectionView.selectionIndexPaths = storeIndexPaths
            coordinator.isBatchUpdating = false
            CATransaction.flush()
        }

        let oldSelection = coordinator.lastSyncedSelection
        let oldFocusedID = coordinator.lastSyncedFocusedID
        coordinator.lastSyncedSelection = storeSelection
        coordinator.lastSyncedFocusedID = focusedID

        // v9.1.3 회귀: 방향 prefetch 제거 — ThumbnailLoader 큐를 점유해서
        //   풀스크린 PhotoPreviewView 의 hi-res 로드가 양보 못받는 문제 발생.
        //   기존 syncViewportToLoader (스크롤 이벤트 기반) 만 사용.

        let visiblePaths = collectionView.indexPathsForVisibleItems()
        let pathsToRefresh: Set<IndexPath>
        let changedIDs = oldSelection.symmetricDifference(storeSelection)
        if changedIDs.count > 24 || abs(oldSelection.count - storeSelection.count) > 24 {
            pathsToRefresh = visiblePaths
        } else {
            var paths = Set(changedIDs.compactMap { id -> IndexPath? in
                guard let idx = coordinator.indexByID[id] else { return nil }
                return IndexPath(item: idx, section: 0)
            })
            if let oldFocusedID, let idx = coordinator.indexByID[oldFocusedID] {
                paths.insert(IndexPath(item: idx, section: 0))
            }
            if let focusedID, let idx = coordinator.indexByID[focusedID] {
                paths.insert(IndexPath(item: idx, section: 0))
            }
            pathsToRefresh = paths.intersection(visiblePaths)
        }

        // Refresh only cells whose selection/focus may have changed.
        for indexPath in pathsToRefresh {
            if let item = collectionView.item(at: indexPath) as? ThumbnailCollectionViewItem {
                let idx = indexPath.item
                guard idx < coordinator.photos.count else { continue }
                let photo = coordinator.photos[idx]
                let isSelected = storeSelection.contains(photo.id)
                let isFocused = focusedID == photo.id
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
        var indexByID: [UUID: Int] = [:]
        var photosVersion: Int = -1
        var thumbnailSize: CGFloat = 120
        var showFileExtension: Bool = true
        var showFileTypeBadge: Bool = true
        var isBatchUpdating: Bool = false
        var lastScrollTrigger: Int = 0
        // v8.9.4: recursive scan 중 reload throttle 타임스탬프
        var lastRecursiveReloadAt: Date = .distantPast
        // v9.1.4 (R-2): 썸네일 사이즈 단독 변경 시 reloadData throttle (150ms).
        var lastSizeReloadAt: Date = .distantPast
        /// v9.1.4 (C-5): actualColumnsPerRow dedup — 같은 값이면 dispatch 자체 skip.
        var lastDispatchedCols: Int = -1
        // v8.9.6: 직전 update 시점의 recursive scan 진행 상태 — 종료 직후 first update 강제 reload 용
        var wasRecursiveScanInProgress: Bool = false
        var lastSyncedSelection: Set<UUID> = []
        var lastSyncedFocusedID: UUID?
        private var lastArrowMoveTime: CFAbsoluteTime = 0
        private var lastNewDirectionKeyCode: UInt16?
        private var lastNewDirectionTime: CFAbsoluteTime = 0

        init(store: PhotoStore) {
            self.store = store
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func rebuildIndexMap() {
            indexByID.removeAll(keepingCapacity: true)
            indexByID.reserveCapacity(photos.count)
            for (idx, photo) in photos.enumerated() {
                indexByID[photo.id] = idx
            }
        }

        private var lastScrollY: CGFloat = 0
        private var lastViewportSyncAt: Date = .distantPast
        // v8.9.4: 스크롤 중 표시 (CacheSweeper 가 폴링)
        private(set) var isScrollingNow: Bool = false
        private var scrollIdleWork: DispatchWorkItem?

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }
            let y = clipView.bounds.origin.y
            let delta = abs(y - lastScrollY)
            lastScrollY = y

            // v8.9.4: 스크롤 시작/지속 표시 → CacheSweeper 가 sweep 중단
            isScrollingNow = true
            scrollIdleWork?.cancel()
            let idle = DispatchWorkItem { [weak self] in self?.isScrollingNow = false }
            scrollIdleWork = idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: idle)
            // 스크롤 시작 첫 1회만 sweep 강제 중단 (notifyActivity 자체는 50ms throttle 됨)
            CacheSweeper.shared.notifyActivity()

            // v8.9.4: 50ms throttle 로 viewport 재동기화 (작은 연속 스크롤도 stale 작업 정리)
            let now = Date()
            if now.timeIntervalSince(lastViewportSyncAt) >= 0.05 {
                lastViewportSyncAt = now
                if let collectionView = clipView.documentView as? NSCollectionView {
                    syncViewportToLoader(collectionView)
                }
            }
            // 매우 큰 점프 (500px+) → 강제 cancel + bumpGeneration
            if delta > 500 {
                ThumbnailLoader.shared.cancelPending()
            }
        }

        /// 보이는 셀 + 1줄 버퍼만 ThumbnailLoader 의 active set 으로 등록.
        /// 옛 generation 작업은 callback 단계에서 자동 폐기.
        func syncViewportToLoader(_ collectionView: NSCollectionView) {
            let visible = collectionView.indexPathsForVisibleItems()
            guard !visible.isEmpty else {
                ThumbnailLoader.shared.setActiveURLs([])
                return
            }
            let items = visible.map { $0.item }
            let rowBuffer = store.isRecursiveMode
                ? max(1, min(store.actualColumnsPerRow, 3))
                : max(2, min(store.actualColumnsPerRow, 8))
            let minIdx = max(0, (items.min() ?? 0) - rowBuffer)
            let maxIdx = min(photos.count - 1, (items.max() ?? 0) + rowBuffer)
            guard minIdx <= maxIdx, !photos.isEmpty else { return }
            var urls: Set<URL> = []
            urls.reserveCapacity(maxIdx - minIdx + 1)
            for i in minIdx...maxIdx {
                if i < photos.count {
                    urls.insert(photos[i].thumbnailSourceURL)
                }
            }
            ThumbnailLoader.shared.cancelPending(keeping: urls)
        }

        // MARK: DataSource

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            return photos.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            layout collectionViewLayout: NSCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> NSSize {
            ThumbnailCollectionViewItem.itemSize(for: thumbnailSize)
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

        // MARK: Keyboard

        func handleKeyDown(event: NSEvent) -> Bool {
            let chars = event.charactersIgnoringModifiers ?? ""
            let hasCmd = event.modifierFlags.contains(.command)
            let hasShift = event.modifierFlags.contains(.shift)
            let keyCode = event.keyCode

            if hasCmd {
                switch chars.lowercased() {
                case "c":
                    copySelectionToPasteboard(store: store)
                    return true
                case "x":
                    cutSelectionToPasteboard(store: store)
                    return true
                case "v":
                    pasteFilesFromPasteboard(store: store)
                    return true
                case "a":
                    store.selectAll()
                    return true
                default:
                    break
                }
            }

            switch keyCode {
            case 123:
                guard prepareArrowNavigation(event: event) else { return true }
                store.selectLeft(shift: hasShift, cmd: hasCmd)
                return true
            case 124:
                guard prepareArrowNavigation(event: event) else { return true }
                store.selectRight(shift: hasShift, cmd: hasCmd)
                return true
            case 125:
                guard prepareArrowNavigation(event: event) else { return true }
                store.selectDown(shift: hasShift, cmd: hasCmd)
                return true
            case 126:
                guard prepareArrowNavigation(event: event) else { return true }
                store.selectUp(shift: hasShift, cmd: hasCmd)
                return true
            case 51, 117:
                if !store.selectedPhotoIDs.isEmpty {
                    store.requestDeleteOriginal(ids: store.selectedPhotoIDs)
                    return true
                }
            case 36:
                if let photo = store.selectedPhoto {
                    if photo.isParentFolder, let parent = store.folderURL?.deletingLastPathComponent() {
                        store.loadFolder(parent, restoreRatings: true)
                        return true
                    } else if photo.isFolder {
                        store.loadFolder(photo.jpgURL, restoreRatings: true)
                        return true
                    }
                }
            default:
                break
            }

            if chars == " " {
                if store.selectedPhotoIDs.count > 1 {
                    let focusRating = store.selectedPhotoID.flatMap { store.idx($0) }.map { store.photos[$0].rating } ?? 0
                    store.setRatingForSelected(focusRating == 5 ? 0 : 5)
                } else if let id = store.selectedPhotoID, let i = store.idx(id) {
                    store.setRating(store.photos[i].rating == 5 ? 0 : 5, for: id)
                }
                return true
            }

            if let ch = chars.first, let rating = Int(String(ch)), rating >= 0 && rating <= 5 {
                if store.selectedPhotoIDs.count > 1 {
                    store.setRatingForSelected(rating)
                } else if let id = store.selectedPhotoID {
                    store.setRating(rating, for: id)
                }
                return true
            }

            if let ch = chars.first, let num = Int(String(ch)), num >= 6 && num <= 9 {
                let labelMap: [Int: ColorLabel] = [6: .red, 7: .yellow, 8: .green, 9: .blue]
                if let label = labelMap[num] {
                    if store.selectedPhotoIDs.count > 1 {
                        store.setColorLabelForSelected(label)
                    } else if let id = store.selectedPhotoID {
                        store.setColorLabel(label, for: id)
                    }
                    return true
                }
            }

            return false
        }

        private func prepareArrowNavigation(event: NSEvent) -> Bool {
            let keyCode = event.keyCode
            let now = CFAbsoluteTimeGetCurrent()

            store.isKeyRepeat = event.isARepeat

            if !event.isARepeat {
                lastNewDirectionKeyCode = keyCode
                lastNewDirectionTime = now
            } else if let lastCode = lastNewDirectionKeyCode,
                      lastCode != keyCode,
                      now - lastNewDirectionTime < 0.10 {
                return false
            }

            lastArrowMoveTime = now
            return true
        }

        func handleKeyUp(event: NSEvent) -> Bool {
            let arrowKeys: Set<UInt16> = [123, 124, 125, 126]
            guard arrowKeys.contains(event.keyCode) else { return false }

            let wasRepeat = store.isKeyRepeat
            store.isKeyRepeat = false
            if wasRepeat, let id = store.selectedPhotoID {
                store.scheduleSelectionIdleWork(for: id, delay: 0.08)
            }
            return true
        }

        // MARK: Context Menu

        func selectForContextMenu(at indexPath: IndexPath) {
            guard indexPath.item < photos.count else { return }
            let photo = photos[indexPath.item]
            guard !photo.isParentFolder else { return }
            let beforeCount = store.selectedPhotoIDs.count
            if !store.selectedPhotoIDs.contains(photo.id) {
                plog("[CTX-MENU] right-click on unselected item — reducing selection \(beforeCount) → 1\n")
                store.selectedPhotoIDs = [photo.id]
                store.selectedPhotoID = photo.id
                // v8.9.7+: 메뉴가 main runloop 을 잡고 있는 동안 SwiftUI 재렌더가 지연되어 파란 선택 표시가
                //   메뉴 닫힐 때까지 안 보임. NSCollectionView 의 selectionIndexPaths 와 cell border 를
                //   즉시 동기적으로 업데이트해서 메뉴 표시 직전에 파란색이 보이도록 강제.
                if let cv = collectionView {
                    cv.selectionIndexPaths = [indexPath]
                    // CATransaction 으로 layer 변경 강제 commit. CALayer.borderColor/backgroundColor 는
                    //   runloop end 의 implicit transaction 에서 flush 되는데, 메뉴가 그 전에 popup →
                    //   파란 선택 표시가 안 보임. CATransaction.flush 로 즉시 commit.
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    let visiblePaths = cv.indexPathsForVisibleItems()
                    for ip in visiblePaths {
                        guard ip.item < photos.count else { continue }
                        let p = photos[ip.item]
                        if let item = cv.item(at: ip) as? ThumbnailCollectionViewItem {
                            let isSelected = (p.id == photo.id)
                            item.updateSelection(isSelected: isSelected, isFocused: isSelected, isSpacePicked: p.isSpacePicked)
                        }
                    }
                    CATransaction.commit()
                    CATransaction.flush()
                }
            } else {
                plog("[CTX-MENU] right-click on selected item — keeping multi-selection (\(beforeCount))\n")
            }
        }

        func buildContextMenu(for indexPath: IndexPath?) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            let anchor: PhotoItem? = {
                if let indexPath, indexPath.item < photos.count { return photos[indexPath.item] }
                // v9.1.4 (perf P2): O(1) indexByID 캐시 사용 — 이전엔 firstIndex(where:) O(N).
                if let id = store.selectedPhotoID, let idx = indexByID[id], idx < photos.count { return photos[idx] }
                return nil
            }()

            guard let photo = anchor else {
                let item = NSMenuItem(title: "선택된 파일 없음", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                return menu
            }

            let ids = store.selectedPhotoIDs.contains(photo.id) ? store.selectedPhotoIDs : [photo.id]
            let count = max(1, ids.count)

            // v9.1.4: 새 폴더로 이동 — 메뉴 최상단 (사용자 요청).
            let moveNewFolder = menuItem("새 폴더로 이동", action: #selector(ctxMoveToNewFolder))
            moveNewFolder.image = NSImage(systemSymbolName: "folder.fill.badge.plus", accessibilityDescription: nil)
            menu.addItem(moveNewFolder)
            menu.addItem(.separator())

            menu.addItem(menuItem("복사", key: "c", action: #selector(ctxCopy), modifier: [.command]))
            menu.addItem(menuItem("잘라내기", key: "x", action: #selector(ctxCut), modifier: [.command]))
            let paste = menuItem("붙여넣기", key: "v", action: #selector(ctxPaste), modifier: [.command])
            paste.isEnabled = !(NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil)?.isEmpty ?? true)
            menu.addItem(paste)
            menu.addItem(.separator())

            let ratingSub = NSMenu(title: "별점")
            for r in 0...5 {
                let title = r == 0 ? "별점 없음" : String(repeating: "★", count: r)
                let item = menuItem(title, key: r == 0 ? "" : "\(r)", action: #selector(ctxSetRating(_:)))
                item.tag = r
                item.keyEquivalentModifierMask = []
                ratingSub.addItem(item)
            }
            let ratingItem = NSMenuItem(title: "별점", action: nil, keyEquivalent: "")
            ratingItem.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
            ratingItem.submenu = ratingSub
            menu.addItem(ratingItem)

            let labelSub = NSMenu(title: "컬러 라벨")
            for (i, label) in ColorLabel.allCases.enumerated() {
                let title = label == .none ? "라벨 해제" : label.rawValue
                let key: String
                switch label {
                case .red: key = "6"
                case .yellow: key = "7"
                case .green: key = "8"
                case .blue: key = "9"
                default: key = ""
                }
                let item = menuItem(title, key: key, action: #selector(ctxSetColorLabel(_:)))
                item.tag = i
                item.keyEquivalentModifierMask = []
                if let nsColor = colorLabelNSColor(label) {
                    item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                        nsColor.setFill()
                        NSBezierPath(ovalIn: rect).fill()
                        return true
                    }
                }
                if photo.colorLabel == label && label != .none { item.state = .on }
                labelSub.addItem(item)
            }
            let labelItem = NSMenuItem(title: "컬러 라벨", action: nil, keyEquivalent: "")
            labelItem.image = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil)
            labelItem.submenu = labelSub
            menu.addItem(labelItem)

            let gItem = menuItem(photo.isGSelected ? "G셀렉 해제" : "G셀렉", action: #selector(ctxToggleGSelect))
            gItem.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
            menu.addItem(gItem)
            menu.addItem(.separator())

            let exportItem = menuItem("내보내기 (\(count)장)", action: #selector(ctxExport))
            exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            menu.addItem(exportItem)

            let rawItem = menuItem("RAW → JPG 변환 (\(count)장)", action: #selector(ctxRawToJpg))
            rawItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            menu.addItem(rawItem)
            menu.addItem(.separator())

            let metaItem = menuItem("메타데이터 편집 (\(count)장)", action: #selector(ctxEditMetadata))
            metaItem.image = NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil)
            menu.addItem(metaItem)

            let renameItem = menuItem("이름 변경 (\(count)장)", action: #selector(ctxRename))
            renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
            menu.addItem(renameItem)

            let rotateSub = NSMenu(title: "회전")
            for (title, degrees) in [("90° 시계방향", 90), ("180°", 180), ("270° (반시계 90°)", 270)] {
                let item = menuItem(title, action: #selector(ctxRotate(_:)))
                item.tag = degrees
                rotateSub.addItem(item)
            }
            let rotateItem = NSMenuItem(title: "회전 (\(count)장)", action: nil, keyEquivalent: "")
            rotateItem.image = NSImage(systemSymbolName: "rotate.right", accessibilityDescription: nil)
            rotateItem.submenu = rotateSub
            menu.addItem(rotateItem)

            let cameraRawItem = menuItem("Camera Raw 에서 열기 (\(count)장)", action: #selector(ctxOpenInCameraRaw))
            cameraRawItem.image = NSImage(systemSymbolName: "camera.metering.matrix", accessibilityDescription: nil)
            cameraRawItem.isEnabled = hasAnyRAW(ids: ids, store: store)
            menu.addItem(cameraRawItem)
            menu.addItem(.separator())

            let copyNameItem = menuItem("파일명 복사", action: #selector(ctxCopyFilename))
            copyNameItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            menu.addItem(copyNameItem)

            let revealItem = menuItem("Finder에서 보기", action: #selector(ctxReveal(_:)))
            revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            revealItem.representedObject = photo.jpgURL
            menu.addItem(revealItem)

            let openItem = menuItem("기본 앱으로 열기", action: #selector(ctxOpenDefault(_:)))
            openItem.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            openItem.representedObject = photo.jpgURL
            menu.addItem(openItem)
            menu.addItem(.separator())

            let deleteItem = menuItem("휴지통으로 이동", action: #selector(ctxDelete))
            deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(deleteItem)

            return menu
        }

        private func menuItem(_ title: String,
                              key: String = "",
                              action: Selector,
                              modifier: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.keyEquivalentModifierMask = modifier
            return item
        }

        private func colorLabelNSColor(_ label: ColorLabel) -> NSColor? {
            switch label {
            case .red: return .systemRed
            case .yellow: return .systemYellow
            case .green: return .systemGreen
            case .blue: return .systemBlue
            case .purple: return .systemPurple
            case .none: return nil
            }
        }

        @objc private func ctxCopy() { copySelectionToPasteboard(store: store) }
        @objc private func ctxCut() { cutSelectionToPasteboard(store: store) }
        @objc private func ctxPaste() { pasteFilesFromPasteboard(store: store) }
        @objc private func ctxDelete() { store.requestDeleteOriginal(ids: store.selectedPhotoIDs) }

        @objc private func ctxReveal(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        @objc private func ctxOpenDefault(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL {
                NSWorkspace.shared.open(url)
            }
        }

        @objc private func ctxSetRating(_ sender: NSMenuItem) {
            if store.selectedPhotoIDs.count > 1 {
                store.setRatingForSelected(sender.tag)
            } else if let id = store.selectedPhotoID {
                store.setRating(sender.tag, for: id)
            }
        }

        @objc private func ctxSetColorLabel(_ sender: NSMenuItem) {
            let allCases = ColorLabel.allCases
            guard sender.tag >= 0, sender.tag < allCases.count else { return }
            let label = allCases[sender.tag]
            if store.selectedPhotoIDs.count > 1 {
                store.setColorLabelForSelected(label)
            } else if let id = store.selectedPhotoID {
                store.setColorLabel(label, for: id)
            }
        }

        @objc private func ctxToggleGSelect() {
            for id in store.selectedPhotoIDs {
                if let idx = store._photoIndex[id] {
                    store.photos[idx].isGSelected.toggle()
                }
            }
        }

        @objc private func ctxExport() { store.showExportSheet = true }

        @objc private func ctxRawToJpg() {
            store.exportOpenAsRawConvert = true
            store.showExportSheet = true
        }

        @objc private func ctxEditMetadata() {
            store.metadataEditorMode = store.selectedPhotoIDs.count > 1 ? .batch : .single
            store.showMetadataEditor = true
        }

        @objc private func ctxRename() { store.showBatchRename = true }

        @objc private func ctxRotate(_ sender: NSMenuItem) {
            store.batchRotate(ids: store.selectedPhotoIDs, degreesCW: sender.tag)
        }

        @objc private func ctxOpenInCameraRaw() {
            openInCameraRaw(ids: store.selectedPhotoIDs, store: store)
        }

        @objc private func ctxCopyFilename() {
            let names = store.selectedPhotoIDs.compactMap { id -> String? in
                guard let idx = store._photoIndex[id], idx < store.photos.count else { return nil }
                return store.photos[idx].jpgURL.lastPathComponent
            }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names, forType: .string)
            store.showToastMessage("📋 \(store.selectedPhotoIDs.count)개 파일명 복사됨")
        }

        @objc private func ctxMoveToNewFolder() {
            guard let folderURL = store.folderURL else { return }
            // 입력 → 중복 체크 → 사용자 선택 → 실행. 새 이름 선택 시 다시 입력 받음.
            promptMoveToNewFolder(parent: folderURL, suggested: nil)
        }

        private func promptMoveToNewFolder(parent: URL, suggested: String?) {
            let alert = NSAlert()
            alert.messageText = "새 폴더로 이동"
            alert.informativeText = "폴더 이름을 입력하세요"
            let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            if let s = suggested { tf.stringValue = s } else { tf.placeholderString = "새 폴더" }
            alert.accessoryView = tf
            alert.addButton(withTitle: "이동")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let newDir = parent.appendingPathComponent(name)

            // v9.1.4: 같은 이름 폴더가 이미 있으면 사용자에게 처리 방식 물음.
            if FileManager.default.fileExists(atPath: newDir.path) {
                let dup = NSAlert()
                dup.messageText = "같은 이름의 폴더가 이미 있습니다"
                dup.informativeText = "\"\(name)\" 폴더가 이미 존재합니다. 어떻게 할까요?"
                dup.addButton(withTitle: "기존 폴더에 추가")  // first
                dup.addButton(withTitle: "이름 다시 정하기")    // second
                dup.addButton(withTitle: "취소")               // third
                let resp = dup.runModal()
                switch resp {
                case .alertFirstButtonReturn:
                    break  // 기존 폴더에 추가 — newDir 그대로 사용 (movePhotosToFolder 가 동일 이름 파일은 skip)
                case .alertSecondButtonReturn:
                    promptMoveToNewFolder(parent: parent, suggested: nextAvailableName(for: name, in: parent))
                    return
                default:
                    return  // 취소
                }
            } else {
                try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            }

            let selectionAtMove = store.selectedPhotoIDs
            plog("[MOVE-NEW] selection count at move=\(selectionAtMove.count)\n")
            var fileURLs: [URL] = []
            var skippedNoIndex = 0
            var skippedFolder = 0
            for id in selectionAtMove {
                guard let idx = store._photoIndex[id], idx < store.photos.count else {
                    skippedNoIndex += 1
                    continue
                }
                let photo = store.photos[idx]
                guard !photo.isFolder && !photo.isParentFolder else {
                    skippedFolder += 1
                    continue
                }
                fileURLs.append(photo.jpgURL)
                if let raw = photo.rawURL, raw != photo.jpgURL { fileURLs.append(raw) }
            }
            plog("[MOVE-NEW] fileURLs=\(fileURLs.count) (skipped: noIndex=\(skippedNoIndex), folder=\(skippedFolder))\n")
            store.movePhotosToFolder(fileURLs: fileURLs, destination: newDir)
        }

        private func nextAvailableName(for base: String, in parent: URL) -> String {
            let fm = FileManager.default
            for i in 2...999 {
                let candidate = "\(base) \(i)"
                if !fm.fileExists(atPath: parent.appendingPathComponent(candidate).path) {
                    return candidate
                }
            }
            return base + " " + UUID().uuidString.prefix(4)
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
            let oldIDs = store.selectedPhotoIDs
            let oldFocus = store.selectedPhotoID
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            let cmd = mods.contains(.command)
            let shift = mods.contains(.shift)
            var newIDs = Set<UUID>()
            var focusID: UUID? = nil

            for indexPath in selectedIndexPaths {
                let idx = indexPath.item
                guard idx < photos.count else { continue }
                let id = photos[idx].id
                newIDs.insert(id)
                focusID = id  // Last one becomes focus
            }
            // v9.1.4: 매 selection 마다 plog 누적 STALL 방지 — 일반 경로 로그 제거.

            // v9.1.4: Shift+드래그(rubber-band) 시 기존 선택 보존 — NSCollectionView 기본이 reset+select 일 때 대응.
            //   shift 누른 상태에서 newIDs 가 oldIDs 의 부분집합이 아니면(=새 항목 추가) 또는 줄어들면 union 강제.
            if shift && !newIDs.isEmpty {
                if !oldIDs.isSubset(of: newIDs) {
                    let merged = oldIDs.union(newIDs)
                    newIDs = merged
                    isBatchUpdating = true
                    let paths = Set(newIDs.compactMap { id -> IndexPath? in
                        guard let idx = indexByID[id] else { return nil }
                        return IndexPath(item: idx, section: 0)
                    })
                    collectionView.selectionIndexPaths = paths
                    isBatchUpdating = false
                }
            }

            // v9.1.4: Cmd+click 인데 cv selection 이 single 로 줄어든 경우 → AppKit 또는 cell subview 가
            //   modifier 를 못 받아 toggle add 가 안 된 것. 우리가 직접 보존하여 multi-select 유지.
            if cmd && newIDs.count == 1 && oldIDs.count >= 1 {
                let newID = newIDs.first!
                if oldIDs.contains(newID) {
                    // 이미 선택된 셀을 Cmd+click → toggle off
                    newIDs = oldIDs.subtracting([newID])
                    focusID = newIDs.first ?? oldIDs.subtracting([newID]).first
                    plog("[SEL] cmd-toggle off: \(newID.uuidString.prefix(4))\n")
                } else {
                    // 새 셀을 Cmd+click → 기존에 add
                    newIDs = oldIDs.union([newID])
                    focusID = newID
                    plog("[SEL] cmd-toggle add: \(newID.uuidString.prefix(4)) (total \(newIDs.count))\n")
                }
                // NSCollectionView selection 도 동기화 (다음 틱에 cv.selectionIndexPaths 가 store 와 일치해야 함)
                isBatchUpdating = true
                let paths = Set(newIDs.compactMap { id -> IndexPath? in
                    guard let idx = indexByID[id] else { return nil }
                    return IndexPath(item: idx, section: 0)
                })
                collectionView.selectionIndexPaths = paths
                isBatchUpdating = false
            }

            // Update store
            store.selectedPhotoIDs = newIDs
            if let focus = focusID {
                store.selectedPhotoID = focus
            } else if newIDs.isEmpty {
                store.selectedPhotoID = nil
            }

            // Handle folder/parent folder double-click is in shouldSelectItems
            // Update visual state only for changed visible cells.
            let visiblePaths = collectionView.indexPathsForVisibleItems()
            let changedIDs = oldIDs.symmetricDifference(newIDs)
            var pathsToRefresh = Set(changedIDs.compactMap { id -> IndexPath? in
                guard let idx = indexByID[id] else { return nil }
                return IndexPath(item: idx, section: 0)
            })
            if let oldFocus, let idx = indexByID[oldFocus] {
                pathsToRefresh.insert(IndexPath(item: idx, section: 0))
            }
            if let focusID, let idx = indexByID[focusID] {
                pathsToRefresh.insert(IndexPath(item: idx, section: 0))
            }
            if pathsToRefresh.count > 24 {
                pathsToRefresh = visiblePaths
            } else {
                pathsToRefresh = pathsToRefresh.intersection(visiblePaths)
            }
            for indexPath in pathsToRefresh {
                if let item = collectionView.item(at: indexPath) as? ThumbnailCollectionViewItem {
                    let i = indexPath.item
                    guard i < photos.count else { continue }
                    let photo = photos[i]
                    let sel = newIDs.contains(photo.id)
                    let foc = store.selectedPhotoID == photo.id
                    item.updateSelection(isSelected: sel, isFocused: foc, isSpacePicked: photo.isSpacePicked)
                }
            }
            lastSyncedSelection = newIDs
            lastSyncedFocusedID = store.selectedPhotoID
        }

        // MARK: Double click for folders

        func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
            // v9.0.2: 더 엄격한 조건 — rubber-band 드래그 중에 발화하지 않게.
            //   double-click 은 단일 cell + leftMouseUp 이벤트일 때만 처리.
            if let event = NSApp.currentEvent,
               event.clickCount == 2,
               event.type == .leftMouseUp,
               indexPaths.count == 1,
               let indexPath = indexPaths.first {
                let idx = indexPath.item
                if idx < photos.count {
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

private final class ThumbnailNSCollectionView: NSCollectionView {
    weak var thumbnailCoordinator: NSThumbnailCollectionView.Coordinator?
    private var rightClickMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // v9.1.4: 빈 영역 좌클릭 → 선택 해제 (Finder 동작과 일치).
        //   modifier 없을 때만 (Cmd/Shift+클릭은 rubber-band 등 다른 의도).
        let point = convert(event.locationInWindow, from: nil)
        if indexPathForItem(at: point) == nil,
           !event.modifierFlags.intersection([.command, .shift]).contains(.command),
           !event.modifierFlags.intersection([.command, .shift]).contains(.shift) {
            if let store = thumbnailCoordinator?.store, !store.selectedPhotoIDs.isEmpty {
                thumbnailCoordinator?.isBatchUpdating = true
                selectionIndexPaths = []
                thumbnailCoordinator?.isBatchUpdating = false
                store.selectedPhotoIDs = []
                store.selectedPhotoID = nil
            }
        }
        super.mouseDown(with: event)
    }

    // v9.1.4: cell 내부 NSImageView/NSTextField 가 rightMouseDown 흡수해서
    //   우클릭이 collection view 까지 도달 못 하는 케이스 (특히 multi-selection).
    //   local monitor 로 우리 view 영역 우클릭을 직접 가로챔.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, rightClickMonitor == nil {
            rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, let win = self.window, event.window === win else { return event }
                let pt = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(pt) {
                    self.rightMouseDown(with: event)
                    return nil  // 이벤트 소비 (cell subview 로 전달 안 됨)
                }
                return event
            }
        } else if window == nil, let m = rightClickMonitor {
            NSEvent.removeMonitor(m)
            rightClickMonitor = nil
        }
    }

    deinit {
        if let m = rightClickMonitor {
            NSEvent.removeMonitor(m)
        }
    }

    // v8.9.6 fix: 다중 선택 후 우클릭하면 NSCollectionView 기본 동작이 우클릭한 셀로 단일 선택을
    //   덮어써서 "다중 선택 → 새 폴더로 이동" 시 1장만 옮겨지던 버그.
    //   우클릭 셀이 이미 multi-selection 에 있으면 super 호출 생략 → 선택 유지.
    // v8.9.7+: 비선택 셀 우클릭 시 super 호출 이전에 selectForContextMenu + 메뉴를 직접 popup.
    //   super 의 NSCollectionView 기본 동작은 selection 변경 + AppKit menu 호출이 비동기로 진행되어
    //   파란색 선택 표시가 메뉴 닫힐 때까지 안 보이던 문제.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        let storeCount = thumbnailCoordinator?.store.selectedPhotoIDs.count ?? -1
        plog("[CTX-MENU] rightMouseDown ip=\(indexPath.map { "\($0.item)" } ?? "nil") cvSel=\(selectionIndexPaths.count) storeSel=\(storeCount)\n")

        // v9.1.4: 다중 선택 셀 위 우클릭은 store.selectedPhotoIDs 도 함께 검사 (NSCollectionView selection sync 지연 대비).
        //   이전: cv.selectionIndexPaths 만 검사 → store=2 인데 cv=1 인 sync 지연 시 selectForContextMenu 가
        //   selection 을 1 로 줄여서 사용자 의도 깨짐. 이제 store 기반 photo.id 도 contains 체크.
        if let ip = indexPath, ip.item < (thumbnailCoordinator?.photos.count ?? 0) {
            let photoID = thumbnailCoordinator!.photos[ip.item].id
            let inStoreMulti = (storeCount > 1) && thumbnailCoordinator!.store.selectedPhotoIDs.contains(photoID)
            let inCVMulti = selectionIndexPaths.contains(ip) && selectionIndexPaths.count > 1
            if inStoreMulti || inCVMulti {
                plog("[CTX-MENU] multi-keep path (storeMulti=\(inStoreMulti) cvMulti=\(inCVMulti))\n")
                if let menu = thumbnailCoordinator?.buildContextMenu(for: ip), menu.numberOfItems > 0 {
                    NSMenu.popUpContextMenu(menu, with: event, for: self)
                } else {
                    plog("[CTX-MENU] WARN menu empty in multi-keep path\n")
                }
                return
            }
        }

        // 단일/비선택 셀 우클릭 → 선택 + 동기 redraw + 메뉴 popup
        if let ip = indexPath {
            thumbnailCoordinator?.selectForContextMenu(at: ip)
        }
        if let menu = thumbnailCoordinator?.buildContextMenu(for: indexPath), menu.numberOfItems > 0 {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            plog("[CTX-MENU] WARN menu empty in single-path indexPath=\(indexPath.map { "\($0.item)" } ?? "nil")\n")
        }
    }

    override func keyDown(with event: NSEvent) {
        if thumbnailCoordinator?.handleKeyDown(event: event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if thumbnailCoordinator?.handleKeyUp(event: event) == true {
            return
        }
        super.keyUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // v8.9.7+: rightMouseDown 에서 직접 popup 하므로 menu(for:) 는 호출되지 않지만
        //   다른 경로 (Ctrl+클릭 등) 대비 fallback 유지.
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        if let indexPath {
            thumbnailCoordinator?.selectForContextMenu(at: indexPath)
        }
        return thumbnailCoordinator?.buildContextMenu(for: indexPath)
    }
}

// MARK: - Collection View Item (Cell)

class ThumbnailCollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCollectionViewItem")
    /// 썸네일 로딩 전용 큐 — 메인스레드와 완전 독립 (방향키 이동과 간섭 없음)
    static let thumbLoadQueue = DispatchQueue(label: "com.pickshot.thumbload", qos: .userInitiated, attributes: .concurrent)

    private enum Layout {
        static let horizontalPadding: CGFloat = 5
        static let topPadding: CGFloat = 5
        static let imageLabelGap: CGFloat = 4
        static let labelHeight: CGFloat = 14
        static let labelStarGap: CGFloat = 3
        static let bottomPadding: CGFloat = 7

        static func starSize(for thumbnailSize: CGFloat) -> CGFloat {
            max(8, thumbnailSize * 0.06) + 1
        }

        static func itemHeight(for thumbnailSize: CGFloat) -> CGFloat {
            let contentHeight = topPadding
                + thumbnailSize * 0.75
                + imageLabelGap
                + labelHeight
                + labelStarGap
                + starSize(for: thumbnailSize)
                + bottomPadding
            return ceil(max(thumbnailSize * 0.75 + 50, contentHeight))
        }
    }

    static func itemSize(for thumbnailSize: CGFloat) -> NSSize {
        NSSize(width: thumbnailSize + Layout.horizontalPadding * 2,
               height: Layout.itemHeight(for: thumbnailSize))
    }

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
    /// v8.9.1 perf: 같은 사진/같은 크기/같은 별점 재구성 시 NSImage SymbolConfiguration 재생성 회피.
    private var lastRating: Int = -1
    private var lastStarSize: CGFloat = -1

    override func loadView() {
        let container = ThumbnailCellContentView()
        container.wantsLayer = true
        // v8.9.4 (revised): 각 서브뷰가 자체 레이어를 갖도록 함 — flatten 시 발생하던
        // 텍스트 이중 렌더 회피 + NSTextField 투명배경 sub-pixel fattening 방지.
        container.layer?.drawsAsynchronously = false
        container.layer?.masksToBounds = true
        self.view = container

        // Border/background view (full cell)
        borderView = NSView()
        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = AppTheme.cellCornerRadius + 2
        borderView.layer?.borderWidth = 0
        container.addSubview(borderView)

        // Thumbnail image
        // v8.9.4 fix: wantsLayer + cornerRadius 면 layer.contentsGravity 가 기본 resize 라
        //   NSImageView 의 imageScaling 무시하고 contents 를 frame 에 강제 stretch.
        //   → portrait 사진이 가로 셀에 짓눌려 정사각형으로 보임. resizeAspect 강제.
        thumbnailImageView = NSImageView()
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.imageAlignment = .alignCenter
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = AppTheme.cellCornerRadius
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailImageView.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        thumbnailImageView.layer?.contentsGravity = .resizeAspect
        container.addSubview(thumbnailImageView)

        // File name
        // v8.9.4: wantsLayer + opaque clear background → sub-pixel AA fattening 방지
        // (텍스트가 "겹쳐 보이는" 잔상 현상 해결)
        fileNameLabel = NSTextField(labelWithString: "")
        fileNameLabel.font = NSFont.systemFont(ofSize: AppTheme.fontCaption)
        fileNameLabel.lineBreakMode = .byTruncatingTail
        fileNameLabel.maximumNumberOfLines = 1
        fileNameLabel.alignment = .center
        fileNameLabel.wantsLayer = true
        fileNameLabel.layer?.drawsAsynchronously = false
        // CALayer + LCD subpixel-AA 충돌 회피: gray scale anti-aliasing 강제
        if let textCell = fileNameLabel.cell as? NSTextFieldCell {
            textCell.backgroundStyle = .normal
        }
        container.addSubview(fileNameLabel)

        // Stars
        // v8.9.4: 각 별 NSImageView 에 자체 레이어 부여 — 컨테이너 레이어 위 이중 그려짐 방지
        starsContainer = NSStackView()
        starsContainer.orientation = .horizontal
        starsContainer.spacing = 0
        starsContainer.alignment = .centerY
        starsContainer.wantsLayer = true
        for _ in 0..<5 {
            let star = NSImageView()
            star.imageScaling = .scaleProportionallyUpOrDown
            star.wantsLayer = true
            star.layer?.drawsAsynchronously = false
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
        guard bounds.width > 1, bounds.height > 1 else { return }
        let padding = Layout.horizontalPadding
        let availableImageWidth = max(20, bounds.width - padding * 2)
        let size = min(currentSize, availableImageWidth)
        let starSize = Layout.starSize(for: size)
        let reservedBelowImage = Layout.imageLabelGap
            + Layout.labelHeight
            + Layout.labelStarGap
            + starSize
            + Layout.bottomPadding
        let imgH = min(size * 0.75, max(20, bounds.height - Layout.topPadding - reservedBelowImage))

        borderView.frame = bounds

        let imgX = (bounds.width - size) / 2
        let imgY = Layout.topPadding
        thumbnailImageView.frame = NSRect(x: imgX, y: imgY, width: size, height: imgH)

        let labelY = imgY + imgH + Layout.imageLabelGap
        fileNameLabel.frame = NSRect(x: padding, y: labelY, width: bounds.width - padding * 2, height: Layout.labelHeight)

        for sv in starViews {
            sv.frame = NSRect(x: 0, y: 0, width: starSize, height: starSize)
        }
        let starsW = starSize * 5
        starsContainer.frame = NSRect(x: (bounds.width - starsW) / 2,
                                      y: labelY + Layout.labelHeight + Layout.labelStarGap,
                                      width: starsW,
                                      height: starSize + 2)

        // Badge overlays on thumbnail
        badgeContainer.frame = NSRect(x: imgX + size - 50, y: imgY + 4, width: 46, height: min(34, imgH - 8))
        pickContainer.frame = NSRect(x: imgX + 4, y: imgY + 4, width: 50, height: min(70, imgH - 8))
        gradeLabel.frame = NSRect(x: imgX + 4, y: imgY + imgH - 20, width: 30, height: 16)
        sceneLabel.frame = NSRect(x: imgX + size - 60, y: imgY + imgH - 20, width: 56, height: 16)
    }

    func configure(photo: PhotoItem, size: CGFloat, isSelected: Bool, isFocused: Bool, showFileExtension: Bool, showFileTypeBadge: Bool) {
        // v8.9.4: configure 동안 layer 의 implicit animation 차단 (잔상 방지)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        currentSize = size
        view.needsLayout = true

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

            // 메모리 캐시 히트 → 즉시, 나머지 → 독립 스레드 + RunLoop common mode
            // v8.8.0: preferRAWOverJPG 설정 반영 — 쌍에서 RAW 우선
            let url = photo.thumbnailSourceURL
            if let cached = ThumbnailCache.shared.get(url) {
                thumbnailImageView.image = cached
                thumbnailImageView.layer?.backgroundColor = nil
            } else {
                Self.thumbLoadQueue.async { [weak self] in
                    if let diskCached = DiskThumbnailCache.shared.getByPath(url: url) {
                        ThumbnailCache.shared.set(url, image: diskCached)
                        // RunLoop common mode — 키보드 이벤트 트래킹 중에도 실행
                        RunLoop.main.perform(inModes: [.common]) {
                            guard self?.currentPhotoURL == url else { return }
                            self?.thumbnailImageView.image = diskCached
                            self?.thumbnailImageView.layer?.backgroundColor = nil
                        }
                        return
                    }
                    ThumbnailLoader.shared.load(url: url) { [weak self] image in
                        RunLoop.main.perform(inModes: [.common]) {
                            guard self?.currentPhotoURL == url else { return }
                            self?.thumbnailImageView.image = image
                            self?.thumbnailImageView.layer?.backgroundColor = nil
                        }
                    }
                }
            }
        }

        thumbnailImageView.isHidden = false

        // File name — v8.6.2: 확장자 항상 표시 (RAW/JPG 구분 명확)
        fileNameLabel.stringValue = photo.fileNameWithExtension
        fileNameLabel.isHidden = false

        // Stars — v8.9.1 perf: 별점/크기 변경 시에만 NSImage 재생성 (스크롤 스파이크 완화)
        let starSize = max(8, size * 0.06)
        if lastRating != photo.rating || lastStarSize != starSize {
            for (i, sv) in starViews.enumerated() {
                let filled = (i + 1) <= photo.rating
                let config = NSImage.SymbolConfiguration(pointSize: starSize, weight: .regular)
                sv.image = NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: nil)?.withSymbolConfiguration(config)
                sv.contentTintColor = filled ? NSColor(AppTheme.starGold) : NSColor.gray.withAlphaComponent(0.25)
            }
            lastRating = photo.rating
            lastStarSize = starSize
        }
        starsContainer.isHidden = false

        // File type badge (top-right)
        clearStack(badgeContainer)
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
        clearStack(pickContainer)
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
        thumbnailImageView.contentTintColor = nil
        clearStack(badgeContainer)
        clearStack(pickContainer)

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

    /// 보이는 셀의 선택/별점 등만 빠르게 업데이트 (reloadItems 없이)
    func updateIfNeeded(photo: PhotoItem, isSelected: Bool, isFocused: Bool) {
        updateSelection(isSelected: isSelected, isFocused: isFocused, isSpacePicked: photo.isSpacePicked)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // v8.9.4: 모든 레이어 애니메이션 강제 종료 — 옛 프레임이 새 프레임 위에 잔상으로 보이는 현상 차단
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.removeAllAnimations()
        thumbnailImageView.layer?.removeAllAnimations()
        fileNameLabel.layer?.removeAllAnimations()
        starsContainer.layer?.removeAllAnimations()
        badgeContainer.layer?.removeAllAnimations()
        pickContainer.layer?.removeAllAnimations()
        gradeLabel.layer?.removeAllAnimations()
        sceneLabel.layer?.removeAllAnimations()
        borderView.layer?.removeAllAnimations()
        currentPhotoURL = nil
        thumbnailImageView.image = nil
        thumbnailImageView.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        thumbnailImageView.contentTintColor = nil
        fileNameLabel.stringValue = ""
        fileNameLabel.isHidden = true
        starsContainer.isHidden = true
        clearStack(badgeContainer)
        clearStack(pickContainer)
        badgeContainer.isHidden = true
        pickContainer.isHidden = true
        gradeLabel.isHidden = true
        gradeLabel.text = ""
        sceneLabel.isHidden = true
        sceneLabel.text = ""
        borderView.layer?.borderWidth = 0
        borderView.layer?.borderColor = NSColor.clear.cgColor
        borderView.layer?.backgroundColor = NSColor.clear.cgColor
        // v8.9.1 perf: star 재생성 강제 (다음 configure 에서 새 별점 반영)
        lastRating = -1
        lastStarSize = -1
        CATransaction.commit()
    }

    // MARK: - Helper

    private func clearStack(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

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

private final class ThumbnailCellContentView: NSView {
    override var isFlipped: Bool { true }

    // v9.1.4: cell 영역은 모두 hit-test 통과 — Cmd+click/Shift+click 등 modifier 클릭이
    //   padding 영역에서 빈 영역으로 잘못 인식되어 selection 전체 해제되던 버그 차단.
    //   "썸네일 사이 빈 공간 클릭 = 해제" 는 layout 의 minimumInteritemSpacing(12pt) /
    //   minimumLineSpacing(10pt) / sectionInset(8pt) 영역에서만 동작 (NSCollectionView 기본).
}

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
