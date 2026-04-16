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
            AppLogger.log(.selection, "selectPhoto: \(photo.fileName)\(cmdKey ? " +Cmd" : "")\(shiftKey ? " +Shift" : "")")
            // 무결성 검증: id 불일치 감지
            if photo.id != id {
                fputs("[SELECT] WARN: _photoIndex 스테일! 클릭 id=\(id.uuidString.prefix(8)) → photos[\(idx)].id=\(photo.id.uuidString.prefix(8)) (\(photo.fileName))\n", stderr)
            } else {
                fputs("[SELECT] click: id=\(id.uuidString.prefix(8)) → \(photo.fileName)\n", stderr)
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
            let safeEnd = min(rangeEnd, list.count - 1)
            guard safeEnd >= rangeStart else { return }
            var newSelection = Set<UUID>()
            for i in rangeStart...safeEnd {
                let item = list[i]
                if !item.isFolder && !item.isParentFolder {
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
        // 폴더/상위폴더 제외 — 사진만 선택
        let ids = Set(filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }.map { $0.id })
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
        executeMoveSelection(by: offset, shiftKey: shiftKey, cmdKey: cmdKey)
    }

    func executeMoveSelection(by offset: Int, shiftKey: Bool, cmdKey: Bool) {
        let list = filteredPhotos  // 1번만 호출
        guard !list.isEmpty else { return }

        ensureFilteredIndex()

        guard let currentID = selectedPhotoID else { return }
        guard let currentIndex = _filteredIndex[currentID] else {
            let firstID = list[0].id
            selectedPhotoIDs = [firstID]
            selectedPhotoID = firstID
            return
        }

        let newIndex = currentIndex + offset
        guard newIndex >= 0 && newIndex < list.count else { return }

        let newID = list[newIndex].id

        scrollAnchor = offset > 0 ? .bottom : .top

        if shiftKey {
            // Shift: range select from anchor to new position
            if shiftAnchorIndex == nil {
                shiftAnchorIndex = currentIndex
            }
            guard let anchor = shiftAnchorIndex else { return }
            let rangeStart = min(anchor, newIndex)
            let rangeEnd = max(anchor, newIndex)
            var newSelection = Set<UUID>()
            for i in rangeStart...rangeEnd {
                newSelection.insert(list[i].id)
            }
            selectedPhotoIDs = newSelection
        } else if cmdKey {
            // Cmd: toggle individual selection, keep existing
            if selectedPhotoIDs.contains(newID) {
                // Already selected - just move focus
            } else {
                selectedPhotoIDs.insert(newID)
            }
            shiftAnchorIndex = nil
        } else {
            // Normal: single select
            selectedPhotoIDs = [newID]
            shiftAnchorIndex = nil
        }

        selectedPhotoID = newID
        scrollTrigger &+= 1

        // 성능 측정 시작 (NavPerfMonitor 활성 시에만 의미 있음)
        let dirSymbol = offset == 1 ? "→" : offset == -1 ? "←" : (offset > 0 ? "↓" : "↑")
        let capturedIndex = newIndex
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                NavigationPerformanceMonitor.shared.notifyMoveStart(photoIndex: capturedIndex, direction: dirSymbol)
            }
        }

        // 빠른 탐색: 썸네일 즉시 표시 (SwiftUI onChange 병합 우회)
        let photo = list[newIndex]
        if !photo.isFolder && !photo.isParentFolder {
            onQuickPreview?(photo.jpgURL)
        }

        // 측정 종료 (다음 프레임)
        DispatchQueue.main.async {
            NavigationPerformanceMonitor.shared.notifyMoveCompleted()
        }
    }

    func selectRight(shift: Bool = false, cmd: Bool = false) { moveSelection(by: 1, shiftKey: shift, cmdKey: cmd) }
    func selectLeft(shift: Bool = false, cmd: Bool = false) { moveSelection(by: -1, shiftKey: shift, cmdKey: cmd) }
    func selectDown(shift: Bool = false, cmd: Bool = false) {
        fputs("[NAV] down cols=\(columnsPerRow) actual=\(actualColumnsPerRow)\n", stderr)
        // 마지막 행에서 아래로 갈 곳이 없으면 가장 마지막 파일로 점프
        ensureFilteredIndex()
        let list = filteredPhotos
        if !list.isEmpty,
           let currentID = selectedPhotoID,
           let currentIdx = _filteredIndex[currentID] {
            let targetIdx = currentIdx + columnsPerRow
            if targetIdx >= list.count {
                // 아래 행이 없음 → 마지막 파일로 이동
                let lastIdx = list.count - 1
                if lastIdx > currentIdx {
                    moveSelection(by: lastIdx - currentIdx, shiftKey: shift, cmdKey: cmd)
                }
                return
            }
        }
        // 정상적으로 한 행 아래
        moveSelection(by: columnsPerRow, shiftKey: shift, cmdKey: cmd)
    }
    func selectUp(shift: Bool = false, cmd: Bool = false) {
        fputs("[NAV] up cols=\(columnsPerRow) actual=\(actualColumnsPerRow)\n", stderr)
        moveSelection(by: -columnsPerRow, shiftKey: shift, cmdKey: cmd)
    }
}
