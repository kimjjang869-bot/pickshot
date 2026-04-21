import SwiftUI
import Foundation

extension PhotoStore {
    func pushUndo(action: String, photoIDs: Set<UUID>) {
        var oldRatings: [UUID: Int] = [:]
        var oldSP: [UUID: Bool] = [:]
        var oldGSelect: [UUID: Bool] = [:]
        for id in photoIDs {
            if let i = _photoIndex[id], i < photos.count {
                oldRatings[id] = photos[i].rating
                oldSP[id] = photos[i].isSpacePicked
                oldGSelect[id] = photos[i].isGSelected
            }
        }
        undoStack.append((action: action, photoIDs: photoIDs, oldRatings: oldRatings, oldSP: oldSP, oldGSelect: oldGSelect, fileMoves: [], removedPhotos: []))
        if undoStack.count > maxUndoSteps {
            undoStack.removeFirst(undoStack.count - maxUndoSteps)
        }
    }

    func undo() {
        // 1) Paste undo 먼저 확인 (복사/잘라내기 붙여넣기는 별도 스택)
        if let pasteRecord = pasteUndoStack.popLast() {
            let fm = FileManager.default
            var restored = 0
            for (origSrc, destURL) in pasteRecord.items.reversed() {
                if pasteRecord.kind == "cut" {
                    // cut 이었으면 dest → orig 로 원복
                    if !fm.fileExists(atPath: origSrc.path) {
                        do {
                            try fm.moveItem(at: destURL, to: origSrc)
                            restored += 1
                        } catch {
                            AppLogger.log(.general, "Paste undo (cut) failed: \(destURL.lastPathComponent) → \(error)")
                        }
                    } else {
                        // 원본 자리에 뭔가 생겼으면 dest 는 삭제
                        try? fm.removeItem(at: destURL)
                    }
                } else {
                    // copy 였으면 dest 파일만 삭제
                    do {
                        try fm.removeItem(at: destURL)
                        restored += 1
                    } catch {
                        AppLogger.log(.general, "Paste undo (copy) failed: \(destURL.lastPathComponent) → \(error)")
                    }
                }
            }
            fputs("[UNDO] Paste \(pasteRecord.kind): \(restored)/\(pasteRecord.items.count)개 원위치\n", stderr)
            // 대상 폴더 리로드
            if folderURL == pasteRecord.destFolder {
                loadFolder(pasteRecord.destFolder, restoreRatings: true)
            } else {
                FolderPreviewCache.shared.invalidateAll()
                NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
            }
            let verb = pasteRecord.kind == "cut" ? "이동" : "복사"
            showToastMessage("↩️ \(verb) 되돌리기 — \(restored)개 파일")
            return
        }

        guard let last = undoStack.popLast() else {
            showToastMessage("되돌릴 항목이 없습니다")
            return
        }

        // 1) 삭제 되돌리기 (목록 복원 + 파일 휴지통 복원)
        if !last.removedPhotos.isEmpty {
            // 파일 휴지통에서 복원
            if !last.fileMoves.isEmpty {
                var restored = 0
                for move in last.fileMoves.reversed() {
                    do {
                        try FileManager.default.moveItem(at: move.destURL, to: move.sourceURL)
                        restored += 1
                    } catch {
                        AppLogger.log(.general, "Undo trash failed: \(move.destURL.lastPathComponent) → \(error)")
                    }
                }
                fputs("[UNDO] 휴지통 복원: \(restored)/\(last.fileMoves.count)개 파일\n", stderr)
            }

            // 목록에 사진 복원 (원래 위치에 삽입)
            _suppressDidSet = true
            let sorted = last.removedPhotos.sorted { $0.originalIndex < $1.originalIndex }
            for item in sorted {
                let insertIdx = min(item.originalIndex, photos.count)
                photos.insert(item.photo, at: insertIdx)
            }
            rebuildIndex()
            _suppressDidSet = false
            photosVersion += 1
            invalidateFilterCache()

            // 복원된 사진 선택
            let restoredIDs = Set(last.removedPhotos.map { $0.photo.id })
            selectedPhotoIDs = restoredIDs
            selectedPhotoID = last.removedPhotos.first?.photo.id

            scrollTrigger &+= 1
            showToastMessage("\(last.removedPhotos.count)장 삭제 되돌리기 완료")
            return
        }

        // 2) 파일 이동 되돌리기
        if !last.fileMoves.isEmpty {
            var undone = 0
            for move in last.fileMoves.reversed() {
                do {
                    try FileManager.default.moveItem(at: move.destURL, to: move.sourceURL)
                    undone += 1
                } catch {
                    AppLogger.log(.general, "Undo move failed: \(move.destURL.lastPathComponent) → \(error)")
                }
            }
            // 폴더 프리뷰 캐시 무효화
            FolderPreviewCache.shared.invalidateAll()
            if let folderURL = folderURL {
                loadFolder(folderURL, restoreRatings: true)
            }
            NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
            showToastMessage("\(undone)장 이동 되돌리기 완료")
            return
        }

        // 3) 별점/SP/GSelect 되돌리기
        var copy = photos
        for id in last.photoIDs {
            guard let i = _photoIndex[id], i < copy.count else { continue }
            if let oldRating = last.oldRatings[id] { copy[i].rating = oldRating }
            if let oldSP = last.oldSP[id] { copy[i].isSpacePicked = oldSP }
            if let oldG = last.oldGSelect[id] { copy[i].isGSelected = oldG }
        }
        applyPhotosUpdate(copy)
        saveRatings()
        showToastMessage("\(last.action) 되돌리기 완료")
    }

    /// 별점/SP/컬러라벨 저장 — 400ms debounce로 연속 변경을 1회 쓰기로 축소.
    /// UI 클릭 즉시 반응을 위해 동기 I/O를 제거.
    func saveRatings() {
        saveRatingsWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performSaveRatings()
        }
        saveRatingsWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// 즉시 저장 (폴더 변경·앱 종료 직전 등).
    func saveRatingsNow() {
        saveRatingsWorkItem?.cancel()
        saveRatingsWorkItem = nil
        performSaveRatings()
    }

    /// 실제 저장 로직 — 메인에서 스냅샷 후 백그라운드에서 UserDefaults + XMP 쓰기.
    func performSaveRatings() {
        guard let folderPath = folderURL?.path else { return }

        // 1) 메인 스레드에서 스냅샷 (photos는 @Published이므로 메인에서만 읽기)
        var ratings: [String: Int] = [:]
        var spPicks: [String: Bool] = [:]
        var colorLabels: [String: String] = [:]
        // v8.6.1: SP 상태도 XMP 에 반영 (이전엔 spacePicked: false 하드코딩으로 XMP 에 안 나감)
        var xmpSnapshot: [(url: URL, rating: Int, label: ColorLabel, sp: Bool)] = []
        xmpSnapshot.reserveCapacity(photos.count)
        for photo in photos {
            if photo.rating > 0 { ratings[photo.fileName] = photo.rating }
            if photo.isSpacePicked { spPicks[photo.fileName] = true }
            if photo.colorLabel != .none { colorLabels[photo.fileName] = photo.colorLabel.rawValue }
            if photo.rating > 0 || photo.colorLabel != .none || photo.isSpacePicked {
                xmpSnapshot.append((photo.jpgURL, photo.rating, photo.colorLabel, photo.isSpacePicked))
            }
        }

        // 2) UserDefaults + XMP 쓰기는 유틸 큐에서 (메인 스레드 블록 해제)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let d = self.defaults

            // 전역 (하위 호환)
            d.set(ratings, forKey: self.ratingsKey)

            // 폴더별 SP + 컬러라벨
            var allSP = d.dictionary(forKey: "folderSpacePicks") as? [String: [String: Bool]] ?? [:]
            var allColors = d.dictionary(forKey: "folderColorLabels") as? [String: [String: String]] ?? [:]
            allSP[folderPath] = spPicks
            allColors[folderPath] = colorLabels
            d.set(allSP, forKey: "folderSpacePicks")
            d.set(allColors, forKey: "folderColorLabels")

            // XMP 사이드카
            for item in xmpSnapshot {
                let xmpLabel = item.label.xmpName.isEmpty ? nil : item.label.xmpName
                XMPService.writeRating(for: item.url, rating: item.rating, label: xmpLabel, spacePicked: item.sp)
            }
        }
    }

    func applySavedRatings() {
        let savedRatings = defaults.dictionary(forKey: ratingsKey) as? [String: Int]
        let folderPath = folderURL?.path ?? ""
        let allSP = defaults.dictionary(forKey: "folderSpacePicks") as? [String: [String: Bool]]
        let allColors = defaults.dictionary(forKey: "folderColorLabels") as? [String: [String: String]]
        let savedSP = allSP?[folderPath]
        let savedColors = allColors?[folderPath]

        fputs("[RESTORE] folder=\(folderURL?.lastPathComponent ?? "nil"), ratings=\(savedRatings?.count ?? 0), SP=\(savedSP?.count ?? 0), colors=\(savedColors?.count ?? 0)\n", stderr)

        var restoredSP = 0
        var restoredRating = 0
        for i in 0..<photos.count {
            let fileName = photos[i].fileName

            // 저장된 별점
            if let saved = savedRatings?[fileName] {
                photos[i].rating = saved
                restoredRating += 1
            }
            // 저장된 SP 셀렉
            if savedSP?[fileName] == true {
                photos[i].isSpacePicked = true
                restoredSP += 1
            }
            // 저장된 컬러라벨 (하위 호환: "주황" → .red)
            if let colorStr = savedColors?[fileName] {
                if let color = ColorLabel(rawValue: colorStr) {
                    photos[i].colorLabel = color
                } else if colorStr == "주황" {
                    photos[i].colorLabel = .red
                }
            }
        }
        fputs("[RESTORE] 적용: rating \(restoredRating)장, SP \(restoredSP)장\n", stderr)

        // 백그라운드: XMP sidecar + EXIF Rating 읽기 (저장된 별점 없는 사진만)
        let photosSnapshot = photos.map { ($0.id, $0.jpgURL, $0.rating) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var exifRatings: [UUID: Int] = [:]
            for (id, url, currentRating) in photosSnapshot {
                guard currentRating == 0 else { continue }
                // XMP sidecar first
                if let xmpResult = XMPService.readRating(for: url), xmpResult.rating > 0 {
                    exifRatings[id] = xmpResult.rating
                    continue
                }
                // EXIF fallback
                if let exif = ExifService.extractExif(from: url), let r = exif.rating, r > 0 {
                    exifRatings[id] = r
                }
            }
            guard !exifRatings.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for (id, rating) in exifRatings {
                    if let idx = self._photoIndex[id], idx < self.photos.count, self.photos[idx].rating == 0 {
                        self.photos[idx].rating = rating
                    }
                }
                if !exifRatings.isEmpty {
                    AppLogger.log(.general, "XMP/EXIF Rating 적용: \(exifRatings.count)장")
                }
            }
        }
    }

    func setColorLabel(_ label: ColorLabel, for photoID: UUID) {
        guard let i = idx(photoID) else { return }
        let anchorIdx = captureSelectionAnchorIndex()
        photos[i].colorLabel = (photos[i].colorLabel == label) ? .none : label
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
        advanceSelectionAfterMutation(fromAnchor: anchorIdx)
    }

    func setColorLabelForSelected(_ label: ColorLabel) {
        // v8.6.1: undo 등록 추가 (다른 벌크 작업과 일관성). 이전엔 누락돼 Cmd+Z 불가.
        pushUndo(action: "일괄 컬러라벨 변경", photoIDs: selectedPhotoIDs)
        // v8.8.2: 토글 동작 — 선택 전부가 이미 해당 라벨이면 해제(.none), 아니면 전부 라벨 적용.
        let allHaveLabel = selectedPhotoIDs.allSatisfy { id in
            guard let i = _photoIndex[id], i < photos.count else { return false }
            return photos[i].colorLabel == label
        }
        let target: ColorLabel = allHaveLabel ? .none : label
        let anchorIdx = captureSelectionAnchorIndex()
        _suppressDidSet = true
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id], i < photos.count { photos[i].colorLabel = target }
        }
        _suppressDidSet = false
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
        advanceSelectionAfterMutation(fromAnchor: anchorIdx)
    }

    func toggleSpacePick(for photoID: UUID) {
        guard let i = idx(photoID) else { return }
        pushUndo(action: "SP 토글", photoIDs: [photoID])
        photos[i].isSpacePicked.toggle()
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
    }

    func toggleSpacePickForSelected() {
        pushUndo(action: "일괄 SP 토글", photoIDs: selectedPhotoIDs)
        _suppressDidSet = true
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id] { photos[i].isSpacePicked.toggle() }
        }
        _suppressDidSet = false
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
    }

    func setRatingForSelected(_ rating: Int) {
        pushUndo(action: "일괄 별점 변경", photoIDs: selectedPhotoIDs)
        // v8.8.2: 토글 동작 — 선택 전부가 이미 해당 별점이면 0 으로 해제, 아니면 전부 해당 별점.
        let allHaveRating = selectedPhotoIDs.allSatisfy { id in
            guard let i = _photoIndex[id], i < photos.count else { return false }
            return photos[i].rating == rating
        }
        let target = allHaveRating ? 0 : rating
        let anchorIdx = captureSelectionAnchorIndex()
        _suppressDidSet = true
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id] { photos[i].rating = target }
        }
        _suppressDidSet = false
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
        advanceSelectionAfterMutation(fromAnchor: anchorIdx)
    }

    func setRating(_ rating: Int, for photoID: UUID) {
        guard let i = idx(photoID) else { return }
        AppLogger.log(.rating, "setRating: \(photos[i].fileName) → \(rating) (was \(photos[i].rating))")
        pushUndo(action: "별점 변경", photoIDs: [photoID])
        let anchorIdx = captureSelectionAnchorIndex()
        photos[i].rating = (photos[i].rating == rating) ? 0 : rating
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
        advanceSelectionAfterMutation(fromAnchor: anchorIdx)
    }

    /// v8.8.3: 선택된 마지막 사진이 현재 filteredPhotos 에서 어느 위치(인덱스)인지 기록.
    ///   rating 변경으로 필터에서 빠지기 전에 호출해둬야 다음 선택 대상을 정확히 찾음.
    private func captureSelectionAnchorIndex() -> Int? {
        let visibleFiles = filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        guard !visibleFiles.isEmpty else { return nil }
        // 포커스 된 selectedPhotoID 우선, 없으면 selectedPhotoIDs 중 하나.
        let anchorID = selectedPhotoID ?? selectedPhotoIDs.first
        guard let id = anchorID else { return nil }
        return visibleFiles.firstIndex(where: { $0.id == id })
    }

    /// v8.8.3: rating/color 변경 후 호출. 기존 선택이 현재 필터에서 사라졌다면
    ///   앵커 위치의 다음 썸네일로 자동 이동. 더 이상 보일 게 없으면 필터를 All 로 리셋.
    private func advanceSelectionAfterMutation(fromAnchor anchor: Int?) {
        let visibleFiles = filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        let visibleIDs = Set(visibleFiles.map { $0.id })

        // 숨어버린 선택 제거
        let hidden = selectedPhotoIDs.subtracting(visibleIDs)
        if !hidden.isEmpty { selectedPhotoIDs.subtract(hidden) }
        if let sid = selectedPhotoID, !visibleIDs.contains(sid) { selectedPhotoID = nil }

        // 선택이 여전히 살아 있으면 종료
        if !selectedPhotoIDs.isEmpty { return }

        // filteredPhotos 에 아직 보여줄 사진이 있으면 앵커 근처로 선택 이동
        if let anchor = anchor, !visibleFiles.isEmpty {
            let targetIdx = min(anchor, visibleFiles.count - 1)
            let next = visibleFiles[targetIdx]
            selectedPhotoIDs = [next.id]
            selectedPhotoID = next.id
            scrollTrigger += 1
            return
        }

        // 보여줄 게 전혀 없으면 필터 리셋
        resetFiltersIfEmpty()
    }
}
