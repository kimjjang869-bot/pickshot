import SwiftUI
import Foundation
import AppKit

extension PhotoStore {
    func rebuildIndex() {
        _photoIndex.removeAll()
        for (i, p) in photos.enumerated() {
            _photoIndex[p.id] = i
        }
    }

    /// 미리보기용: 최대 N장만 반환 (대량 선택 시 성능 보호)
    func multiSelectedPhotosLimited(_ limit: Int) -> [PhotoItem] {
        var result: [PhotoItem] = []
        result.reserveCapacity(limit)
        for id in selectedPhotoIDs {
            if let idx = _photoIndex[id], idx < photos.count, photos[idx].id == id {
                result.append(photos[idx])
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// 검색창 등 TextField 포커스를 KeyCaptureView로 복원 (방향키 동작 보장)
    func restoreKeyFocus() {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }
        // KeyCaptureView를 찾아서 first responder로
        func find(_ view: NSView) -> NSView? {
            let name = String(describing: type(of: view))
            if name == "KeyCaptureView" { return view }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        if let keyView = find(contentView) {
            window.makeFirstResponder(keyView)
        }
    }

    func selectPhoto(_ id: UUID, cmdKey: Bool, shiftKey: Bool = false) {
        restoreKeyFocus()
        // SwiftUI가 다음 RunLoop에서 TextField로 되돌리는 걸 방지
        DispatchQueue.main.async { [weak self] in self?.restoreKeyFocus() }
        // 폴더/상위폴더는 선택 불가
        if let idx = _photoIndex[id], idx < photos.count {
            let photo = photos[idx]
            // 무결성 검증: id 불일치 감지
            if photo.id != id {
                fputs("[SELECT] WARN: _photoIndex 스테일! 클릭 id=\(id.uuidString.prefix(8)) → photos[\(idx)].id=\(photo.id.uuidString.prefix(8)) (\(photo.fileName))\n", stderr)
            }
        } else {
            fputs("[SELECT] WARN: 클릭된 id=\(id.uuidString.prefix(8))가 _photoIndex에 없음\n", stderr)
        }
        if shiftKey {
            // Shift+Click: range selection from anchor
            let list = filteredPhotos
            ensureFilteredIndex()
            guard let toIndex = _filteredIndex[id] else {
                selectedPhotoIDs = [id]
                selectedPhotoID = id
                return
            }

            // Set anchor on first shift-click
            if shiftClickAnchorIndex == nil {
                if let currentID = selectedPhotoID, let idx = _filteredIndex[currentID] {
                    shiftClickAnchorIndex = idx
                } else {
                    shiftClickAnchorIndex = toIndex
                }
            }

            guard let anchor = shiftClickAnchorIndex else { return }
            let rangeStart = min(anchor, toIndex)
            let rangeEnd = max(anchor, toIndex)

            // Replace selection with exact range (shrinks if clicking back)
            //   v8.9.7+: 폴더도 shift-range 선택 가능. parentFolder (..) 만 제외.
            let safeEnd = min(rangeEnd, list.count - 1)
            guard safeEnd >= rangeStart else { return }
            var newSelection = Set<UUID>()
            for i in rangeStart...safeEnd {
                let item = list[i]
                if !item.isParentFolder {
                    newSelection.insert(item.id)
                }
            }
            selectedPhotoIDs = newSelection
            selectedPhotoID = id
        } else if cmdKey {
            shiftClickAnchorIndex = nil
            // Cmd+Click: toggle individual selection
            if selectedPhotoIDs.contains(id) {
                selectedPhotoIDs.remove(id)
                if selectedPhotoID == id {
                    selectedPhotoID = selectedPhotoIDs.first
                }
            } else {
                selectedPhotoIDs.insert(id)
                selectedPhotoID = id
            }
        } else {
            // Normal click: single select, clear multi
            shiftClickAnchorIndex = nil
            selectedPhotoIDs = [id]
            selectedPhotoID = id
        }
    }

    func selectAll() {
        // v8.9.7+: 폴더도 select-all 포함. parentFolder (..) 만 제외.
        let ids = Set(filteredPhotos.filter { !$0.isParentFolder }.map { $0.id })
        selectedPhotoIDs = ids
    }

    func deselectAll() {
        selectedPhotoIDs.removeAll()
    }

    func idx(_ id: UUID) -> Int? {
        if let i = _photoIndex[id], i >= 0, i < photos.count, photos[i].id == id { return i }
        return nil
    }

    func isSelected(_ id: UUID) -> Bool {
        selectedPhotoIDs.contains(id)
    }

    func moveSelection(by offset: Int, shiftKey: Bool = false, cmdKey: Bool = false) {
        // v8.9.4: 방향키 burst 동안 ThumbnailLoader 양보 (concurrency 다운) → 250ms 후 자동 복구
        let t0 = CFAbsoluteTimeGetCurrent()
        markNavigationBurstIfNeeded()
        let t1 = CFAbsoluteTimeGetCurrent()
        ThumbnailLoader.shared.throttle()
        PhotoStore.scheduleUnthrottle()
        let t2 = CFAbsoluteTimeGetCurrent()
        executeMoveSelection(by: offset, shiftKey: shiftKey, cmdKey: cmdKey)
        let t3 = CFAbsoluteTimeGetCurrent()
        let totalMs = (t3 - t0) * 1000
        if totalMs > 5 {
            fputs("[MOVE] total=\(String(format: "%.0f", totalMs))ms burst=\(String(format: "%.0f", (t1-t0)*1000))ms throttle=\(String(format: "%.0f", (t2-t1)*1000))ms exec=\(String(format: "%.0f", (t3-t2)*1000))ms\n", stderr)
        }
    }

    /// 빠른 연타는 NSEvent.isARepeat 이 false 여도 사용감은 key-repeat 과 같다.
    /// 이 짧은 burst 동안 Stage2/HiRes/EXIF 작업을 미뤄 마지막 사진만 따라오게 한다.
    private func markNavigationBurstIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        let rapidTap = now - Self.lastNavigationMoveTime < 0.10
        Self.lastNavigationMoveTime = now

        if rapidTap || isKeyRepeat {
            isNavigationBurst = true
            Self.navigationBurstWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.isNavigationBurst = false
                if let id = self.selectedPhotoID {
                    self.scheduleSelectionIdleWork(for: id, delay: 0.05)
                }
                Self.scheduleNavigationIdleCleanup()
            }
            Self.navigationBurstWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }

    private static var navigationIdleCleanupWork: DispatchWorkItem?
    static func scheduleNavigationIdleCleanup() {
        navigationIdleCleanupWork?.cancel()
        let work = DispatchWorkItem {
            PreviewImageCache.shared.trimOldest(ratio: 0.6)
        }
        navigationIdleCleanupWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// burst 끝나면(250ms idle) 자동 unthrottle. 연속 호출 시 마지막 1회만 실행.
    private static var unthrottleWork: DispatchWorkItem?
    static func scheduleUnthrottle() {
        unthrottleWork?.cancel()
        let w = DispatchWorkItem { ThumbnailLoader.shared.unthrottle() }
        unthrottleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func executeMoveSelection(by offset: Int, shiftKey: Bool, cmdKey: Bool) {
        let list = filteredPhotos  // 1번만 호출
        guard !list.isEmpty else { return }

        ensureFilteredIndex()

        guard let result = NavigationCore.move(.init(
            photos: list,
            filteredIndex: _filteredIndex,
            currentID: selectedPhotoID,
            currentSelection: selectedPhotoIDs,
            shiftAnchorIndex: shiftAnchorIndex,
            offset: offset,
            shiftKey: shiftKey,
            cmdKey: cmdKey
        )) else { return }

        scrollAnchor = offset > 0 ? .bottom : .top
        selectedPhotoIDs = result.selection
        shiftAnchorIndex = result.shiftAnchorIndex

        // 성능 측정 시작 — scrollTrigger/selectedPhotoID 변경 직전에 측정 시작
        // (SwiftUI body 재계산 + onChange 호출이 모두 동기 구간에 포함되도록)
        let measuring: Bool = {
            #if DEBUG
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated {
                NavigationPerformanceMonitor.shared.isEnabled
            }
            #else
            return false
            #endif
        }()
        if measuring {
            MainActor.assumeIsolated {
                NavigationPerformanceMonitor.shared.notifyMoveStart(photoIndex: result.targetIndex, direction: result.directionSymbol)
            }
        }

        #if DEBUG
        let fromName = selectedPhotoID.flatMap { _filteredIndex[$0] }.flatMap { list.indices.contains($0) ? list[$0].fileName : nil } ?? "nil"
        let toName = list.indices.contains(result.targetIndex) ? list[result.targetIndex].fileName : "nil"
        fputs("[SELECT-MOVE] \(fromName) -> \(toName) offset=\(offset) target=\(result.targetIndex) cols=\(actualColumnsPerRow) repeat=\(isKeyRepeat) burst=\(isNavigationBurst)\n", stderr)
        #endif
        selectedPhotoID = result.focusedID
        // v8.9.7+: 진짜 병목은 TouchBarProvider 의 매-nav RAW 디코드였음. scrollTrigger 증가는
        //   NSCollectionView 자동 스크롤에 필수 — burst 중에도 유지.
        scrollTrigger &+= 1

        // v8.9.7+: 빠른 프리뷰도 selectedPhotoID onChange 단일 경로에서 처리한다.
        // 별도 콜백 우회 표시를 허용하면 키를 놓는 순간 늦게 도착한 프레임이 현재 선택을 덮을 수 있다.

        // 측정 종료 — 동기 구간 끝난 직후
        if measuring {
            MainActor.assumeIsolated {
                NavigationPerformanceMonitor.shared.notifyMoveCompleted()
            }
        }
    }

    func selectRight(shift: Bool = false, cmd: Bool = false) { moveSelection(by: 1, shiftKey: shift, cmdKey: cmd) }
    func selectLeft(shift: Bool = false, cmd: Bool = false) { moveSelection(by: -1, shiftKey: shift, cmdKey: cmd) }
    func selectDown(shift: Bool = false, cmd: Bool = false) {
        // 마지막 행에서 아래로 갈 곳이 없으면 가장 마지막 파일로 점프
        ensureFilteredIndex()
        let list = filteredPhotos
        if !list.isEmpty,
           let currentID = selectedPhotoID,
           let currentIdx = _filteredIndex[currentID] {
            if let offset = NavigationCore.downOffset(currentIndex: currentIdx, count: list.count, columns: columnsPerRow) {
                moveSelection(by: offset, shiftKey: shift, cmdKey: cmd)
                return
            }
        }
        // 정상적으로 한 행 아래
        moveSelection(by: columnsPerRow, shiftKey: shift, cmdKey: cmd)
    }
    func selectUp(shift: Bool = false, cmd: Bool = false) {
        moveSelection(by: -columnsPerRow, shiftKey: shift, cmdKey: cmd)
    }
}
