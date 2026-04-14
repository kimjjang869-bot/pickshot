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
        var xmpSnapshot: [(url: URL, rating: Int, label: ColorLabel)] = []
        xmpSnapshot.reserveCapacity(photos.count)
        for photo in photos {
            if photo.rating > 0 { ratings[photo.fileName] = photo.rating }
            if photo.isSpacePicked { spPicks[photo.fileName] = true }
            if photo.colorLabel != .none { colorLabels[photo.fileName] = photo.colorLabel.rawValue }
            if photo.rating > 0 || photo.colorLabel != .none {
                xmpSnapshot.append((photo.jpgURL, photo.rating, photo.colorLabel))
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
                XMPService.writeRating(for: item.url, rating: item.rating, label: xmpLabel, spacePicked: false)
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
        photos[i].colorLabel = (photos[i].colorLabel == label) ? .none : label
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
    }

    func setColorLabelForSelected(_ label: ColorLabel) {
        _suppressDidSet = true
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id], i < photos.count { photos[i].colorLabel = label }
        }
        _suppressDidSet = false
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
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
        _suppressDidSet = true
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id] { photos[i].rating = rating }
        }
        _suppressDidSet = false
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
    }

    func setRating(_ rating: Int, for photoID: UUID) {
        guard let i = idx(photoID) else { return }
        AppLogger.log(.rating, "setRating: \(photos[i].fileName) → \(rating) (was \(photos[i].rating))")
        pushUndo(action: "별점 변경", photoIDs: [photoID])
        photos[i].rating = (photos[i].rating == rating) ? 0 : rating
        invalidateFilterCache()
        photosVersion += 1
        saveRatings()
    }
}
