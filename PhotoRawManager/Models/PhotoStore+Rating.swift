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
            plog("[UNDO] Paste \(pasteRecord.kind): \(restored)/\(pasteRecord.items.count)개 원위치\n")
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
                plog("[UNDO] 휴지통 복원: \(restored)/\(last.fileMoves.count)개 파일\n")
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

    /// 별점/SP/컬러라벨 저장 — debounce 로 연속 변경을 1회 쓰기로 축소.
    /// v9.1.2: 400ms → 2000ms (스크롤 중 18초 STALL 발생 → 폭주 방지).
    /// v9.1.2: 키 이동 중이면 추가 1초 더 늦춤 (이동 평균 80-100ms 보장).
    func saveRatings() {
        saveRatingsWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // 이동 중이면 한 번 더 미룸 — 누른 채 이동 중 디스크 I/O 차단.
            if self.isFastNavigation {
                self.saveRatings()
                return
            }
            self.performSaveRatings()
        }
        saveRatingsWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    /// 즉시 저장 (폴더 변경·앱 종료 직전 등).
    func saveRatingsNow() {
        saveRatingsWorkItem?.cancel()
        saveRatingsWorkItem = nil
        performSaveRatings()
    }

    /// 실제 저장 로직 — 메인에서 스냅샷 후 백그라운드에서 UserDefaults + XMP 쓰기.
    /// v9.1.2: 18초 main STALL 원인 수정 — inflight guard, UserDefaults 통합, XMP/JSON diff.
    func performSaveRatings() {
        guard let folderPath = folderURL?.path else { return }

        // ── 0) 재진입 가드 — 진행 중이면 새 호출 무시 (debounce 가 다음 cycle 처리)
        if Self.saveInflight {
            plog("[BACKUP] skip — save inflight\n")
            return
        }
        Self.saveInflight = true

        // 1) 메인 스레드에서 스냅샷 (photos는 @Published이므로 메인에서만 읽기)
        struct FolderGroup {
            var ratings: [String: Int] = [:]
            var spPicks: [String: Bool] = [:]
            var colorLabels: [String: String] = [:]
        }
        var groups: [String: FolderGroup] = [:]
        groups[folderPath] = FolderGroup()  // root 시드 (모두 지워졌을 때도 빈 dict 덮어쓰기)

        // XMP 후보를 (url → 현재 상태) 로 모음 — diff 위해 dict 사용.
        var xmpCurrent: [URL: (rating: Int, label: ColorLabel, sp: Bool)] = [:]
        for photo in photos {
            if photo.isFolder || photo.isParentFolder { continue }
            let containingFolder = photo.jpgURL.deletingLastPathComponent().path
            if groups[containingFolder] == nil { groups[containingFolder] = FolderGroup() }
            if photo.rating > 0 { groups[containingFolder]!.ratings[photo.fileName] = photo.rating }
            if photo.isSpacePicked { groups[containingFolder]!.spPicks[photo.fileName] = true }
            if photo.colorLabel != .none {
                groups[containingFolder]!.colorLabels[photo.fileName] = photo.colorLabel.rawValue
            }
            if photo.rating > 0 || photo.colorLabel != .none || photo.isSpacePicked {
                xmpCurrent[photo.jpgURL] = (photo.rating, photo.colorLabel, photo.isSpacePicked)
            }
        }

        let rootRatings = groups[folderPath]?.ratings ?? [:]
        let groupsCopy = groups

        // 2) 백그라운드 — UserDefaults 1회 통합 쓰기 + XMP diff + JSON 변경 폴더만
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { Self.saveInflight = false }
            guard let self = self else { return }
            let d = self.defaults
            let t0 = CFAbsoluteTimeGetCurrent()

            // 전역 ratingsKey (단일 폴더 호환) — root 만
            d.set(rootRatings, forKey: self.ratingsKey)

            // ── UserDefaults 통합: folderSelections 단일 dict 로 모음 (3 dict → 1 dict, read 1회/write 1회).
            //   기존 키 (folderRatings/folderSpacePicks/folderColorLabels) 는 마이그레이션 fallback 용으로 유지.
            var combined = d.dictionary(forKey: "folderSelections") as? [String: [String: Any]] ?? [:]
            for (path, g) in groupsCopy {
                combined[path] = [
                    "ratings": g.ratings,
                    "spPicks": g.spPicks,
                    "colorLabels": g.colorLabels,
                ]
            }
            d.set(combined, forKey: "folderSelections")

            // ── XMP diff: 마지막 저장 스냅샷과 비교해 변경된 파일만 쓴다.
            var xmpChanges: [(URL, Int, ColorLabel, Bool)] = []
            for (url, cur) in xmpCurrent {
                let prev = Self.lastXMPSnapshot[url]
                if prev == nil || prev!.0 != cur.rating || prev!.1 != cur.label.rawValue || prev!.2 != cur.sp {
                    xmpChanges.append((url, cur.rating, cur.label, cur.sp))
                }
            }
            for (url, rating, label, sp) in xmpChanges {
                let xmpLabel = label.xmpName.isEmpty ? nil : label.xmpName
                XMPService.writeRating(for: url, rating: rating, label: xmpLabel, spacePicked: sp)
                Self.lastXMPSnapshot[url] = (rating, label.rawValue, sp)
            }
            // 사라진 항목 (rating 모두 0 됨) 도 lastSnapshot 에서 제거 — 다음 변경 시 다시 재평가.
            for url in Self.lastXMPSnapshot.keys where xmpCurrent[url] == nil {
                Self.lastXMPSnapshot.removeValue(forKey: url)
            }

            // ── JSON 백업: 변경된 폴더만 다시 쓴다 (해시로 비교).
            var jsonWrites = 0
            let fmt = ISO8601DateFormatter()
            for (path, g) in groupsCopy {
                let key = "\(g.ratings.count):\(g.spPicks.count):\(g.colorLabels.count):" +
                          (g.ratings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))
                if Self.lastJSONHash[path] == key { continue }
                Self.lastJSONHash[path] = key

                let backupURL = URL(fileURLWithPath: path).appendingPathComponent(".pickshot_selection.json")
                if g.ratings.isEmpty && g.spPicks.isEmpty && g.colorLabels.isEmpty
                    && !FileManager.default.fileExists(atPath: backupURL.path) { continue }
                let payload: [String: Any] = [
                    "version": 1,
                    "savedAt": fmt.string(from: Date()),
                    "folder": path,
                    "ratings": g.ratings,
                    "spPicks": g.spPicks,
                    "colorLabels": g.colorLabels
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                    try? data.write(to: backupURL, options: .atomic)
                    var url = backupURL
                    var rv = URLResourceValues()
                    rv.isExcludedFromBackup = true
                    try? url.setResourceValues(rv)
                    jsonWrites += 1
                }
            }
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            plog("[BACKUP] saved folders=\(groupsCopy.count) xmp=\(xmpChanges.count) json=\(jsonWrites) in \(elapsed)ms\n")
        }
    }

    /// v9.1.2: save 재진입 가드 + diff 캐시.
    static var saveInflight = false
    static var lastXMPSnapshot: [URL: (Int, String, Bool)] = [:]
    static var lastJSONHash: [String: String] = [:]

    /// v8.9.7+: 폴더의 .pickshot_selection.json 백업에서 셀렉 정보 복구.
    ///   UserDefaults 가 비어있을 때만 fallback 으로 사용. 우선순위: UserDefaults > JSON 백업.
    func loadSelectionBackup() -> (ratings: [String: Int], spPicks: [String: Bool], colors: [String: String])? {
        guard let folderPath = folderURL?.path else { return nil }
        let backupURL = URL(fileURLWithPath: folderPath).appendingPathComponent(".pickshot_selection.json")
        guard let data = try? Data(contentsOf: backupURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let ratings = (json["ratings"] as? [String: Int]) ?? [:]
        let spPicks = (json["spPicks"] as? [String: Bool]) ?? [:]
        let colors = (json["colorLabels"] as? [String: String]) ?? [:]
        plog("[BACKUP] loaded from JSON \(ratings.count) ratings, \(spPicks.count) SP, \(colors.count) colors\n")
        return (ratings, spPicks, colors)
    }

    func applySavedRatings() {
        let folderPath = folderURL?.path ?? ""
        // v9.1: 폴더별 ratings 우선, 없으면 전역 ratingsKey (단일 폴더 하위 호환)
        let allRatings = defaults.dictionary(forKey: "folderRatings") as? [String: [String: Int]]
        var savedRatings = allRatings?[folderPath]
        if savedRatings == nil || savedRatings!.isEmpty {
            savedRatings = defaults.dictionary(forKey: ratingsKey) as? [String: Int]
        }
        let allSP = defaults.dictionary(forKey: "folderSpacePicks") as? [String: [String: Bool]]
        let allColors = defaults.dictionary(forKey: "folderColorLabels") as? [String: [String: String]]
        var savedSP = allSP?[folderPath]
        var savedColors = allColors?[folderPath]

        // v8.9.7+: UserDefaults 가 비어있으면 JSON 백업에서 복구 (마이그레이션/손상 대응).
        if (savedRatings?.isEmpty ?? true) && (savedSP?.isEmpty ?? true) && (savedColors?.isEmpty ?? true) {
            if let backup = loadSelectionBackup() {
                if !backup.ratings.isEmpty { savedRatings = backup.ratings }
                if !backup.spPicks.isEmpty { savedSP = backup.spPicks }
                if !backup.colors.isEmpty { savedColors = backup.colors }
                plog("[RESTORE] UserDefaults 비어있음 → JSON 백업에서 복구\n")
            }
        }

        plog("[RESTORE] folder=\(folderURL?.lastPathComponent ?? "nil"), ratings=\(savedRatings?.count ?? 0), SP=\(savedSP?.count ?? 0), colors=\(savedColors?.count ?? 0)\n")

        var restoredSP = 0
        var restoredRating = 0
        // v9.1: 하위폴더 모드에서는 각 사진의 *실제 소속 폴더* 별 dict 도 룩업.
        //   root 키 dict (위에서 로드한 savedRatings/SP/Colors) 는 root 직속 사진만 커버.
        //   퍼포먼스: 폴더별 JSON 백업은 1회만 일괄 읽기 (이전엔 photo 마다 disk read → 수천 장 = 수초 hang).
        let needsPerFolderLookup = isRecursiveMode
        struct FolderCache {
            var ratings: [String: Int] = [:]
            var sp: [String: Bool] = [:]
            var colors: [String: String] = [:]
        }
        var perFolderCache: [String: FolderCache] = [:]
        if needsPerFolderLookup {
            // 1) 등장하는 소속 폴더 수집 (중복 제거)
            var folderSet = Set<String>()
            for p in photos where !p.isFolder && !p.isParentFolder {
                let f = p.jpgURL.deletingLastPathComponent().path
                if f != folderPath { folderSet.insert(f) }
            }
            // 2) 각 폴더에 대해 UserDefaults 결과 + JSON 백업 1회 로드
            for f in folderSet {
                var fc = FolderCache()
                fc.ratings = allRatings?[f] ?? [:]
                fc.sp = allSP?[f] ?? [:]
                fc.colors = allColors?[f] ?? [:]
                if fc.ratings.isEmpty && fc.sp.isEmpty && fc.colors.isEmpty {
                    let bu = URL(fileURLWithPath: f).appendingPathComponent(".pickshot_selection.json")
                    if let data = try? Data(contentsOf: bu),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        fc.ratings = (json["ratings"] as? [String: Int]) ?? [:]
                        fc.sp = (json["spPicks"] as? [String: Bool]) ?? [:]
                        fc.colors = (json["colorLabels"] as? [String: String]) ?? [:]
                    }
                }
                perFolderCache[f] = fc
            }
            plog("[RESTORE] 폴더별 백업 \(perFolderCache.count)개 일괄 로드\n")
        }

        // v9.1.2: didSet 폭주 방지 — 17000장 중 800장에 rating 적용 시 매번 didSet 발생하면
        //   filteredCache invalidate / SwiftUI grid 재렌더 누적되어 22초 STALL 발생.
        //   _suppressDidSet=true 로 묶어 일괄 처리 후 마지막에 invalidateFilterCache 1회만.
        _suppressDidSet = true
        for i in 0..<photos.count {
            let fileName = photos[i].fileName
            let containingFolder = photos[i].jpgURL.deletingLastPathComponent().path

            // 폴더별 dict 우선 조회 (재귀 모드)
            var rating: Int? = nil
            var sp: Bool = false
            var colorStr: String? = nil
            if needsPerFolderLookup, containingFolder != folderPath, let fc = perFolderCache[containingFolder] {
                rating = fc.ratings[fileName]
                sp = fc.sp[fileName] ?? false
                colorStr = fc.colors[fileName]
            }
            // root 폴더 dict (기존 경로)
            if rating == nil { rating = savedRatings?[fileName] }
            if !sp { sp = savedSP?[fileName] == true }
            if colorStr == nil { colorStr = savedColors?[fileName] }

            if let r = rating, r > 0 {
                photos[i].rating = r
                restoredRating += 1
            }
            if sp {
                photos[i].isSpacePicked = true
                restoredSP += 1
            }
            if let cs = colorStr {
                if let color = ColorLabel(rawValue: cs) {
                    photos[i].colorLabel = color
                } else if cs == "주황" {
                    photos[i].colorLabel = .red
                }
            }
        }
        _suppressDidSet = false
        invalidateFilterCache()
        plog("[RESTORE] 적용: rating \(restoredRating)장, SP \(restoredSP)장\n")

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
        let target: ColorLabel = (photos[i].colorLabel == label) ? .none : label
        photos[i].colorLabel = target
        invalidateFilterCache()
        saveRatings()
        advanceSelectionAfterMutation(fromAnchor: anchorIdx)
        // v8.9: 학습용 이벤트 기록
        SelectionEventStore.shared.record(
            photoUUID: photoID.uuidString,
            photoPath: photos[i].jpgURL.path,
            folderPath: photos[i].jpgURL.deletingLastPathComponent().path,
            kind: .colorLabel,
            payload: target.rawValue
        )
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
        let affectedIDs = selectedPhotoIDs  // 기록용 스냅샷
        _suppressDidSet = true
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id], i < photos.count { photos[i].colorLabel = target }
        }
        _suppressDidSet = false
        invalidateFilterCache()
        saveRatings()
        advanceSelectionAfterMutation(fromAnchor: anchorIdx)
        // v8.9: 학습 DB 기록 (벌크) — 뿌리 데이터 유실 방지.
        recordBulkEvent(ids: affectedIDs, kind: .colorLabel, payload: target.rawValue)
    }

    func toggleSpacePick(for photoID: UUID) {
        guard let i = idx(photoID) else { return }
        pushUndo(action: "SP 토글", photoIDs: [photoID])
        photos[i].isSpacePicked.toggle()
        let newValue = photos[i].isSpacePicked
        invalidateFilterCache()
        saveRatings()
        SelectionEventStore.shared.record(
            photoUUID: photoID.uuidString,
            photoPath: photos[i].jpgURL.path,
            folderPath: photos[i].jpgURL.deletingLastPathComponent().path,
            kind: .spacePick,
            payload: newValue ? "true" : "false"
        )
    }

    func toggleSpacePickForSelected() {
        pushUndo(action: "일괄 SP 토글", photoIDs: selectedPhotoIDs)
        let affectedIDs = selectedPhotoIDs
        _suppressDidSet = true
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id] { photos[i].isSpacePicked.toggle() }
        }
        _suppressDidSet = false
        invalidateFilterCache()
        saveRatings()
        // 벌크 SP 토글 — 개별 최종 상태 기록
        for id in affectedIDs {
            guard let i = _photoIndex[id], i < photos.count else { continue }
            SelectionEventStore.shared.record(
                photoUUID: id.uuidString,
                photoPath: photos[i].jpgURL.path,
                folderPath: photos[i].jpgURL.deletingLastPathComponent().path,
                kind: .spacePick,
                payload: photos[i].isSpacePicked ? "true" : "false"
            )
        }
    }

    /// v8.9: 벌크 이벤트 기록 헬퍼 — affectedIDs 전체를 동일 payload 로 일괄 append.
    private func recordBulkEvent(ids: Set<UUID>, kind: SelectionEventKind, payload: String?) {
        for id in ids {
            guard let i = _photoIndex[id], i < photos.count else { continue }
            SelectionEventStore.shared.record(
                photoUUID: id.uuidString,
                photoPath: photos[i].jpgURL.path,
                folderPath: photos[i].jpgURL.deletingLastPathComponent().path,
                kind: kind,
                payload: payload
            )
        }
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
        let affectedIDs = selectedPhotoIDs
        _suppressDidSet = true
        for id in selectedPhotoIDs {
            if let i = _photoIndex[id] { photos[i].rating = target }
        }
        _suppressDidSet = false
        invalidateFilterCache()
        saveRatings()
        advanceSelectionAfterMutation(fromAnchor: anchorIdx)
        // v8.9: 학습 DB 기록 (벌크 별점)
        recordBulkEvent(ids: affectedIDs, kind: .rated, payload: "\(target)")
    }

    func setRating(_ rating: Int, for photoID: UUID) {
        guard let i = idx(photoID) else { return }
        AppLogger.log(.rating, "setRating: \(photos[i].fileName) → \(rating) (was \(photos[i].rating))")
        pushUndo(action: "별점 변경", photoIDs: [photoID])
        let anchorIdx = captureSelectionAnchorIndex()
        let targetRating = (photos[i].rating == rating) ? 0 : rating
        photos[i].rating = targetRating
        invalidateFilterCache()
        saveRatings()
        advanceSelectionAfterMutation(fromAnchor: anchorIdx)
        // v8.9: 학습용 이벤트 기록
        SelectionEventStore.shared.record(
            photoUUID: photoID.uuidString,
            photoPath: photos[i].jpgURL.path,
            folderPath: photos[i].jpgURL.deletingLastPathComponent().path,
            kind: .rated,
            payload: "\(targetRating)"
        )
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
