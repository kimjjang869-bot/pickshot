import SwiftUI
import Foundation
import AppKit

extension PhotoStore {

    // MARK: - XMP Sidecar Helper (v8.6.1)

    /// 원본 파일 옆에 `.xmp` 사이드카가 있으면 동일한 상대 경로로 함께 이동.
    /// Adobe Bridge/Lightroom/Camera Raw 가 생성하는 XMP 가 이동 시 고아가 되는 문제 해결.
    static func moveXMPSidecarIfExists(from src: URL, to dst: URL) {
        let fm = FileManager.default
        // e.g. photo.ARW → photo.xmp (확장자 치환), photo.JPG → photo.xmp
        let srcXMP = src.deletingPathExtension().appendingPathExtension("xmp")
        let dstXMP = dst.deletingPathExtension().appendingPathExtension("xmp")
        guard fm.fileExists(atPath: srcXMP.path), !fm.fileExists(atPath: dstXMP.path) else { return }
        try? fm.moveItem(at: srcXMP, to: dstXMP)
    }

    // MARK: - Cache Invalidation (v8.6.1 메모리 누수 수정)

    /// 삭제/이동된 사진 URL 들의 모든 캐시 엔트리 일괄 제거.
    /// 이전에는 photos[] 에서만 제거하고 ThumbnailCache / PreviewImageCache / hiResCache /
    /// FolderPreviewCache / DevelopStore / _dimensionCache 등에 NSImage 들이 그대로 남아
    /// 35회 삭제에서 수백 MB ~ 수 GB 씩 누수가 발생. 60GB 메모리 사용 + 38GB 스왑 유발.
    static func invalidateCachesForDeletedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 1) 프리뷰 전용 캐시 (메모리 + 디스크)
        for url in urls {
            PreviewImageCache.shared.remove(url: url)
            ThumbnailCache.shared.remove(url: url)
            PhotoPreviewView.invalidateImageDimensions(for: url)
            PhotoPreviewView.removeHiResCache(for: url)
            DevelopStore.shared.invalidateMemory(for: url)
        }
        // 2) 디스크 썸네일 — getByPath path-only key 기반
        for url in urls {
            DiskThumbnailCache.shared.invalidate(url: url)
        }
        plog("[CACHE-INVALIDATE] \(urls.count) URLs 캐시 정리 완료\n")
    }

    // MARK: - Remove / Delete

    /// Remove selected photos from the list (NOT from disk)
    func removeSelectedFromList() {
        let idsToRemove = photosToRemove
        guard !idsToRemove.isEmpty else { return }

        // Step 1: 다음 선택 대상 미리 계산 — 뒤(다음) 사진 우선
        // 표준 뷰어 관행: 삭제 후 다음 사진으로 이동 (이정열 작가 재피드백)
        let list = filteredPhotos
        ensureFilteredIndex()
        var nextID: UUID? = nil
        if let currentID = selectedPhotoID, let currentFilteredIdx = _filteredIndex[currentID] {
            // 뒤(다음) 사진을 먼저 찾기
            for i in (currentFilteredIdx + 1)..<list.count {
                if !idsToRemove.contains(list[i].id) && !list[i].isFolder && !list[i].isParentFolder {
                    nextID = list[i].id
                    break
                }
            }
            // 뒤에 없으면(마지막 사진이었으면) 앞(이전) 사진
            if nextID == nil {
                for i in stride(from: currentFilteredIdx - 1, through: 0, by: -1) {
                    if !idsToRemove.contains(list[i].id) && !list[i].isFolder && !list[i].isParentFolder {
                        nextID = list[i].id
                        break
                    }
                }
            }
        }

        // Step 2: 삭제 전 undo 정보 저장
        var removedItems: [RemovedPhoto] = []
        for (i, photo) in photos.enumerated() {
            if idsToRemove.contains(photo.id) {
                removedItems.append(RemovedPhoto(photo: photo, originalIndex: i))
            }
        }
        undoStack.append((action: "목록 제거", photoIDs: idsToRemove, oldRatings: [:], oldSP: [:], oldGSelect: [:], fileMoves: [], removedPhotos: removedItems))
        if undoStack.count > maxUndoSteps { undoStack.removeFirst(undoStack.count - maxUndoSteps) }

        // Step 3: didSet 억제하고 직접 배열 수정 (중복 재계산 방지)
        _suppressDidSet = true

        // in-place 제거 (배열 복사 없음)
        photos.removeAll { idsToRemove.contains($0.id) }

        // 인덱스 직접 재구축
        rebuildIndex()

        _suppressDidSet = false
        photosVersion += 1

        // 필터 캐시도 직접 업데이트 (전체 재계산 대신 제거만)
        filterLock.lock()
        if let cached = _cachedFiltered {
            _cachedFiltered = cached.filter { !idsToRemove.contains($0.id) }
            _cacheKey = "\(photosVersion)"
        }
        _filteredIndex.removeAll()
        _filteredIndexVersion = ""
        filterLock.unlock()

        // Step 3: 선택 업데이트
        selectedPhotoIDs.subtract(idsToRemove)
        if let next = nextID {
            selectedPhotoID = next
            selectedPhotoIDs = [next]
        } else if let first = _cachedFiltered?.first(where: { !$0.isFolder && !$0.isParentFolder }) ?? photos.first {
            selectedPhotoID = first.id
            selectedPhotoIDs = [first.id]
        } else {
            selectedPhotoID = nil
            selectedPhotoIDs = []
        }

        photosToRemove = []
        scrollTrigger &+= 1

        // 삭제 효과음 (macOS 휴지통 비우기, 0.28초로 자름)
        if !idsToRemove.isEmpty {
            Self.playDeleteSound()
        }

        // 폴더 사이즈는 비동기로 (렉 방지)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let totalBytes = self.photos.reduce(Int64(0)) { sum, photo in
                guard !photo.isFolder && !photo.isParentFolder else { return sum }
                return sum + photo.jpgFileSize + photo.rawFileSize
            }
            let text: String
            if totalBytes <= 0 {
                text = "\(self.photos.filter { !$0.isFolder }.count)장"
            } else if totalBytes > 1_073_741_824 {
                text = String(format: "%.1f GB", Double(totalBytes) / 1_073_741_824)
            } else if totalBytes > 1_048_576 {
                text = String(format: "%.0f MB", Double(totalBytes) / 1_048_576)
            } else {
                text = String(format: "%.0f KB", Double(totalBytes) / 1024)
            }
            DispatchQueue.main.async { self.cachedFolderSizeText = text }
        }
    }

    /// Remove photos from list without file deletion (backspace default)
    func removePhotosFromList(ids: Set<UUID>) {
        photosToRemove = ids
        removeSelectedFromList()
    }

    /// Delete original files from disk + remove from list (backspace with setting)
    func deleteOriginalFiles(ids: Set<UUID>) {
        let fm = FileManager.default
        var deleted = 0
        var failed = 0
        var trashMoves: [FileMove] = []   // 휴지통 복원용
        var deletedURLs: [URL] = []       // v8.6.1: 삭제된 URL 캐시 무효화용

        for id in ids {
            // 안전장치: _photoIndex가 스테일할 수 있으므로 photo.id == id 검증
            // 실패 시 선형 탐색으로 폴백하여 엉뚱한 파일 삭제 방지
            let photo: PhotoItem
            if let idx = _photoIndex[id], idx < photos.count, photos[idx].id == id {
                photo = photos[idx]
            } else if let fallback = photos.first(where: { $0.id == id }) {
                plog("[DELETE] WARN: _photoIndex 스테일 감지 — id=\(id.uuidString.prefix(8)), 선형 탐색으로 폴백: \(fallback.fileName)\n")
                photo = fallback
            } else {
                plog("[DELETE] ERROR: photo를 찾을 수 없음 — id=\(id.uuidString.prefix(8))\n")
                continue
            }
            guard !photo.isFolder && !photo.isParentFolder else { continue }

            // v8.6.1: 삭제되는 파일의 모든 캐시 엔트리 수집 → 아래에서 일괄 제거
            deletedURLs.append(photo.jpgURL)
            if let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                deletedURLs.append(rawURL)
            }

            // 무엇을 삭제하는지 명시 로그 (디버깅 용)
            let rawLog = photo.rawURL.map { $0.lastPathComponent } ?? "nil"
            plog("[DELETE] 삭제 대상: jpgURL=\(photo.jpgURL.lastPathComponent), rawURL=\(rawLog)\n")

            // Delete JPG → 휴지통 (복원 경로 기록)
            // v8.6.1: JPG 삭제 실패 시 RAW 도 건드리지 않음 (반쪽 삭제로 페어 깨짐 방지)
            var jpgDeleteOK = true
            if fm.fileExists(atPath: photo.jpgURL.path) {
                do {
                    var trashURL: NSURL?
                    try fm.trashItem(at: photo.jpgURL, resultingItemURL: &trashURL)
                    if let t = trashURL as URL? {
                        trashMoves.append(FileMove(sourceURL: photo.jpgURL, destURL: t))
                    }
                } catch {
                    failed += 1
                    jpgDeleteOK = false
                }
            }
            // JPG 삭제 실패했으면 RAW 건너뛰고 이 사진은 deleted 카운트 미증가
            guard jpgDeleteOK else { continue }

            // Delete RAW → 휴지통 (jpgURL과 같으면 스킵 — 이미 삭제됨)
            if let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                do {
                    if fm.fileExists(atPath: rawURL.path) {
                        var trashURL: NSURL?
                        try fm.trashItem(at: rawURL, resultingItemURL: &trashURL)
                        if let t = trashURL as URL? {
                            trashMoves.append(FileMove(sourceURL: rawURL, destURL: t))
                        }
                    }
                } catch { failed += 1 }
            }
            deleted += 1
        }

        AppLogger.log(.export, "Deleted \(deleted) files (\(failed) failed) to Trash")

        // v8.6.1 메모리 누수 수정: 삭제된 사진들의 캐시 일괄 무효화.
        // (이전에는 photos[] 에서만 제거하고 각 캐시엔 NSImage 가 그대로 남아
        //  35회 × 수십 MB → 60GB 누수 발생. MemGuard 가 감지했어도 일부만 해제)
        PhotoStore.invalidateCachesForDeletedURLs(deletedURLs)

        // 삭제 효과음 (macOS 휴지통 비우기, 0.28초)
        // 주의: removePhotosFromList 안에서도 재생되므로 여기는 생략 — 이중 재생 방지

        // Remove from list (undo 스택에 목록 제거 정보 저장됨)
        removePhotosFromList(ids: ids)

        // undo 스택 마지막 항목에 파일 이동 정보 추가 (휴지통 복원용)
        if !trashMoves.isEmpty, var lastUndo = undoStack.popLast() {
            lastUndo.action = "파일 삭제"
            lastUndo.fileMoves = trashMoves
            undoStack.append(lastUndo)
        }

        // 우리가 직접 삭제한 파일이므로 FolderWatcher가 리로드를 트리거하지 않도록 baseline 동기화
        // → 1~3초 후 발생하는 화면 깜빡임 방지
        folderWatcher.syncBaselineSilently()
        folderReloadWork?.cancel()
    }

    /// 폴더를 휴지통으로 이동
    func deleteFolders(ids: Set<UUID>) {
        let fm = FileManager.default
        var deleted = 0
        for id in ids {
            guard let idx = _photoIndex[id], idx < photos.count else { continue }
            let photo = photos[idx]
            guard photo.isFolder else { continue }
            do {
                try fm.trashItem(at: photo.jpgURL, resultingItemURL: nil)
                deleted += 1
                plog("[DELETE] 폴더 휴지통 이동: \(photo.jpgURL.lastPathComponent)\n")
            } catch {
                plog("[DELETE] 폴더 삭제 실패: \(error.localizedDescription)\n")
            }
        }
        if deleted > 0 {
            Self.playDeleteSound()
        }
        if deleted > 0, let url = folderURL {
            // 폴더 삭제는 구조가 바뀌므로 리로드가 필요. 다만 watcher 중복 리로드는 막음.
            folderReloadWork?.cancel()
            loadFolder(url, restoreRatings: true)
            folderWatcher.syncBaselineSilently()
        }
    }

    /// 삭제 요청 — 설정에 따라 확인 대화상자 표시 or 바로 실행
    /// 기본값: 확인 없이 바로 휴지통으로 이동 (빠른 셀렉 워크플로우)
    func requestDeleteOriginal(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeleteIDs = ids

        // 설정 확인 — skipDeleteConfirm 기본값 true (빠른 워크플로우)
        let skipConfirm = UserDefaults.standard.object(forKey: "skipDeleteConfirm") as? Bool ?? true

        if skipConfirm {
            // 바로 실행 (파일은 휴지통으로, Undo 가능)
            let hasFolder = ids.contains { id in
                guard let idx = _photoIndex[id], idx < photos.count else { return false }
                return photos[idx].isFolder
            }
            if hasFolder { deleteFolders(ids: ids) }
            let fileIDs = ids.filter { id in
                guard let idx = _photoIndex[id], idx < photos.count else { return false }
                return !photos[idx].isFolder && !photos[idx].isParentFolder
            }
            if !fileIDs.isEmpty { deleteOriginalFiles(ids: Set(fileIDs)) }
            pendingDeleteIDs = []
        } else {
            // 확인 대화상자 표시
            showDeleteOriginalConfirm = true
        }
    }

    /// 선택된 파일/폴더를 휴지통으로 이동 (통합)
    func deleteSelectedItems() {
        let ids = selectedPhotoIDs
        guard !ids.isEmpty else { return }

        let hasFolder = ids.contains { id in
            guard let idx = _photoIndex[id], idx < photos.count else { return false }
            return photos[idx].isFolder
        }
        let hasFile = ids.contains { id in
            guard let idx = _photoIndex[id], idx < photos.count else { return false }
            return !photos[idx].isFolder && !photos[idx].isParentFolder
        }

        if hasFolder { deleteFolders(ids: ids) }
        if hasFile { deleteOriginalFiles(ids: ids) }
    }

    // MARK: - Import / Move To Folder

    /// 선택된 사진 파일을 대상 폴더로 이동
    /// Finder 등 외부에서 드래그된 파일을 현재 폴더로 복사(또는 이동).
    /// - moveInstead가 true면 이동, 아니면 복사.
    /// - 폴더가 열려 있어야 하며(folderURL 존재), 이미지/RAW/비디오 파일만 받아들임.
    /// - 중복 이름은 " (1)", " (2)" 로 자동 네이밍.
    func importFilesFromExternal(urls: [URL], moveInstead: Bool = false) {
        guard let destination = folderURL else {
            showToastMessage("먼저 폴더를 열어주세요")
            return
        }

        let fm = FileManager.default
        // 원본 경로의 폴더(현재 열린 폴더)에서 온 파일은 스킵 — 리오더 같은 내부 드롭 충돌 방지
        let destPath = destination.standardizedFileURL.path
        let filtered = urls.filter { url in
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            return parent != destPath
        }
        guard !filtered.isEmpty else { return }

        // 지원 가능한 파일만 (이미지/RAW/비디오)
        let accepted = filtered.filter { url in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return false }
            return FileMatchingService.isImportableFile(url)
        }
        guard !accepted.isEmpty else {
            showToastMessage("지원하는 이미지/RAW/비디오 파일이 없습니다")
            return
        }

        let total = accepted.count
        let label = moveInstead ? "파일 이동" : "파일 복사"

        DispatchQueue.main.async {
            self.fileMoveActive = true
            self.fileMoveDone = 0
            self.fileMoveTotal = total
            self.fileMoveLabel = label
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var done = 0
            var failed = 0
            var copiedRecords: [FileMove] = []

            for (index, srcURL) in accepted.enumerated() {
                // 중복 이름 해결
                let base = srcURL.deletingPathExtension().lastPathComponent
                let ext = srcURL.pathExtension
                var candidate = destination.appendingPathComponent(srcURL.lastPathComponent)
                var n = 1
                while fm.fileExists(atPath: candidate.path) {
                    let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                    candidate = destination.appendingPathComponent(newName)
                    n += 1
                    if n > 999 { break }
                }

                do {
                    if moveInstead {
                        try fm.moveItem(at: srcURL, to: candidate)
                    } else {
                        try fm.copyItem(at: srcURL, to: candidate)
                    }
                    copiedRecords.append(FileMove(sourceURL: srcURL, destURL: candidate))
                    done += 1
                } catch {
                    failed += 1
                    AppLogger.log(.general, "\(label) 실패: \(srcURL.lastPathComponent) → \(error.localizedDescription)")
                }

                DispatchQueue.main.async {
                    self.fileMoveDone = index + 1
                }
            }

            DispatchQueue.main.async {
                self.fileMoveActive = false

                // FolderWatcher가 중복 리로드하지 않도록 baseline 갱신
                self.folderWatcher.syncBaselineSilently()

                // Undo 기록 (이동만, 복사는 수동 삭제가 안전)
                if moveInstead, !copiedRecords.isEmpty {
                    self.undoStack.append((action: "파일 가져오기", photoIDs: Set<UUID>(),
                                           oldRatings: [:], oldSP: [:], oldGSelect: [:],
                                           fileMoves: copiedRecords, removedPhotos: []))
                    if self.undoStack.count > self.maxUndoSteps {
                        self.undoStack.removeFirst(self.undoStack.count - self.maxUndoSteps)
                    }
                }

                let verb = moveInstead ? "이동" : "복사"
                let msg = "\(done)장 \(verb) 완료" + (failed > 0 ? " (\(failed)장 실패)" : "") + (moveInstead ? " (Cmd+Z 되돌리기)" : "")
                self.showToastMessage(msg)

                // 새 파일이 현재 폴더에 들어왔으므로 리로드
                if done > 0 {
                    self.loadFolder(destination, restoreRatings: true)
                    FolderPreviewCache.shared.invalidate(destination)
                    NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
                }
            }
        }
    }

    func movePhotosToFolder(fileURLs: [URL], destination: URL) {
        let fm = FileManager.default
        var moved = 0
        var failed = 0
        var movedIDs = Set<UUID>()
        var fileMoveRecords: [FileMove] = []
        let total = fileURLs.count

        // v9.1 진단: 하위폴더 모드 이동 실패 추적용
        plog("[MOVE] start: \(total) URLs → \(destination.path)\n")
        if total == 0 {
            plog("[MOVE] WARN: fileURLs empty (selection / filter mismatch?)\n")
        }
        if !fm.fileExists(atPath: destination.path) {
            plog("[MOVE] WARN: destination does not exist before move: \(destination.path)\n")
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        DispatchQueue.main.async {
            self.fileMoveActive = true
            self.fileMoveDone = 0
            self.fileMoveTotal = total
            self.fileMoveLabel = "파일 이동"
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            for (index, srcURL) in fileURLs.enumerated() {
                let destURL = destination.appendingPathComponent(srcURL.lastPathComponent)
                do {
                    if !fm.fileExists(atPath: srcURL.path) {
                        // 원본이 없음 (이미 다른 항목 이동 시 RAW 페어로 함께 이동된 케이스)
                        plog("[MOVE] SKIP src missing: \(srcURL.lastPathComponent)\n")
                        continue
                    }
                    if fm.fileExists(atPath: destURL.path) {
                        // 같은 이름 파일 존재 → 스킵
                        plog("[MOVE] SKIP name collision at dest: \(destURL.lastPathComponent)\n")
                        failed += 1
                        continue
                    }
                    try fm.moveItem(at: srcURL, to: destURL)
                    fileMoveRecords.append(FileMove(sourceURL: srcURL, destURL: destURL))
                    moved += 1

                    // v8.6.1: XMP 사이드카 동반 이동 (Adobe/Lightroom 레이팅 메타 유실 방지).
                    Self.moveXMPSidecarIfExists(from: srcURL, to: destURL)

                    // photos 배열에서 해당 파일 찾아서 ID 수집
                    if let photo = self.photos.first(where: {
                        $0.jpgURL.path == srcURL.path || $0.rawURL?.path == srcURL.path
                    }) {
                        // JPG+RAW 쌍의 다른 파일도 이동 (+ XMP)
                        if photo.jpgURL.path == srcURL.path, let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                            let rawDest = destination.appendingPathComponent(rawURL.lastPathComponent)
                            try? fm.moveItem(at: rawURL, to: rawDest)
                            Self.moveXMPSidecarIfExists(from: rawURL, to: rawDest)
                        } else if photo.rawURL?.path == srcURL.path {
                            let jpgDest = destination.appendingPathComponent(photo.jpgURL.lastPathComponent)
                            if !fm.fileExists(atPath: jpgDest.path) {
                                try? fm.moveItem(at: photo.jpgURL, to: jpgDest)
                                Self.moveXMPSidecarIfExists(from: photo.jpgURL, to: jpgDest)
                            }
                        }
                        movedIDs.insert(photo.id)
                    }
                } catch {
                    failed += 1
                    plog("[MOVE] FAIL \(srcURL.lastPathComponent) → \(destURL.path): \(error)\n")
                    AppLogger.log(.general, "File move failed: \(srcURL.lastPathComponent) → \(error.localizedDescription)")
                }
                // 진행률 업데이트
                DispatchQueue.main.async {
                    self.fileMoveDone = index + 1
                }
            }

            DispatchQueue.main.async {
                self.fileMoveActive = false
                // Undo 기록
                if !fileMoveRecords.isEmpty {
                    self.undoStack.append((action: "파일 이동", photoIDs: movedIDs, oldRatings: [:], oldSP: [:], oldGSelect: [:], fileMoves: fileMoveRecords, removedPhotos: []))
                }
                // v8.6.1 메모리 누수 수정: 이동된 사진들의 캐시 일괄 정리.
                //   현재 폴더에서는 이동 후 해당 사진이 사라지므로 캐시를 유지할 이유 없음.
                let movedURLs = fileMoveRecords.map { $0.sourceURL }
                PhotoStore.invalidateCachesForDeletedURLs(movedURLs)
                // 이동된 사진 목록에서 제거
                if !movedIDs.isEmpty {
                    self.removePhotosFromList(ids: movedIDs)
                }
                let msg = "\(moved)장 이동 완료 (Cmd+Z 되돌리기)" + (failed > 0 ? " (\(failed)장 실패)" : "")
                plog("[MOVE] done: moved=\(moved) failed=\(failed) records=\(fileMoveRecords.count) → \(destination.path)\n")
                self.showToastMessage(msg)
                AppLogger.log(.export, "Moved \(moved) files to \(destination.lastPathComponent) (\(failed) failed)")
                // 폴더 프리뷰 캐시 무효화 (이동 원본 + 대상 폴더)
                FolderPreviewCache.shared.invalidate(destination)
                if let srcParent = fileURLs.first?.deletingLastPathComponent() {
                    FolderPreviewCache.shared.invalidate(srcParent)
                }
                // 폴더 트리 새로고침 알림
                NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
            }
        }
    }

    // MARK: - Pickshot 가져오기 결과 적용

    func importPickshotFile() {
        let result = PickshotFileService.importSelection(to: &photos, photoIndex: _photoIndex)
        if let result = result {
            photosVersion += 1
            // clientComments 딕셔너리 구축 (preview에서 표시용)
            buildClientComments()
            lastImportResult = result
            showPickshotImportSheet = true
        }
    }

    /// photos 배열의 고객 코멘트(clientComments)를 dict 로 복사 (preview 오버레이 표시용)
    /// ⚠️ `photo.comments` (내 메모) 가 아니라 `photo.clientComments` (고객 피드백) 를 읽어야 함.
    func buildClientComments() {
        var dict: [UUID: String] = [:]
        for photo in photos {
            if !photo.clientComments.isEmpty {
                dict[photo.id] = photo.clientComments.joined(separator: " / ")
            }
        }
        clientComments = dict
    }

    // MARK: - 드래그 리오더

    /// 사진 위치 이동 (드래그드롭)
    func movePhoto(from sourceID: UUID, to targetID: UUID) {
        let list = filteredPhotos
        guard let fromIdx = list.firstIndex(where: { $0.id == sourceID }),
              let toIdx = list.firstIndex(where: { $0.id == targetID }),
              fromIdx != toIdx else { return }

        // 커스텀 순서 맵 초기화 (처음이면)
        if customOrderMap.isEmpty {
            for (i, photo) in list.enumerated() {
                customOrderMap[photo.id] = i
            }
        }

        // from을 to 위치로 이동
        let fromOrder = customOrderMap[sourceID] ?? fromIdx
        let toOrder = customOrderMap[targetID] ?? toIdx

        if fromOrder < toOrder {
            for (id, order) in customOrderMap where order > fromOrder && order <= toOrder {
                customOrderMap[id] = order - 1
            }
        } else {
            for (id, order) in customOrderMap where order >= toOrder && order < fromOrder {
                customOrderMap[id] = order + 1
            }
        }
        customOrderMap[sourceID] = toOrder

        // 사용자 정렬 모드로 전환 + 뷰 리프레시
        if sortMode != .customOrder {
            sortMode = .customOrder
        }
        invalidateFilterCache()
        objectWillChange.send()
        plog("[REORDER] \(sourceID.uuidString.prefix(8)) → \(targetID.uuidString.prefix(8))\n")
    }

    /// 여러 사진을 한 번에 target 위치로 이동 (다중 선택 드래그 리오더).
    /// - sourceIDs가 1개면 movePhoto로 위임.
    /// - target이 source에 포함되면 무시.
    /// - insertBefore=true면 target 앞, false면 뒤에 블록 삽입.
    func movePhotos(_ sourceIDs: Set<UUID>, to targetID: UUID, insertBefore: Bool = true) {
        guard !sourceIDs.isEmpty else { return }
        if sourceIDs.count == 1, let only = sourceIDs.first {
            movePhoto(from: only, to: targetID)
            return
        }
        guard !sourceIDs.contains(targetID) else { return }

        let list = filteredPhotos
        let allOrdered = list.map { $0.id }
        let selectedInOrder = allOrdered.filter { sourceIDs.contains($0) }
        let remaining = allOrdered.filter { !sourceIDs.contains($0) }

        guard let targetIdx = remaining.firstIndex(of: targetID) else { return }
        let insertAt = insertBefore ? targetIdx : targetIdx + 1

        var newOrder = remaining
        newOrder.insert(contentsOf: selectedInOrder, at: insertAt)

        customOrderMap.removeAll()
        for (i, id) in newOrder.enumerated() {
            customOrderMap[id] = i
        }

        if sortMode != .customOrder {
            sortMode = .customOrder
        }
        invalidateFilterCache()
        // photosVersion @Published 변경으로 충분 — objectWillChange.send() 중복 호출 제거
        plog("[REORDER MULTI] \(sourceIDs.count)장 → \(targetID.uuidString.prefix(8)) (before=\(insertBefore))\n")
    }

    // MARK: - Batch Rename

    /// Perform batch rename on selected photos
    func batchRename(pattern: String) -> (success: Int, errors: [String]) {
        return batchRename(pattern: pattern, dateFormat: "yyyyMMdd", seqDigits: 3, seqStart: 1)
    }

    func batchRename(pattern: String, dateFormat: String, seqDigits: Int, seqStart: Int, preserveRatings: Bool = true) -> (success: Int, errors: [String]) {
        // v8.6.1 데이터 무결성: batchRename 진입 전 debounce 중인 레이팅 저장 강제 플러시.
        //   이전엔 400ms debounce 작업이 나중에 깨어나면 구 파일명 키로 rating 덮어써 두 버전 공존.
        saveRatingsNow()

        let targets: [PhotoItem]
        if selectedPhotoIDs.count > 1 {
            targets = filteredPhotos.filter { selectedPhotoIDs.contains($0.id) && !$0.isFolder && !$0.isParentFolder }
        } else {
            targets = filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        }

        var successCount = 0
        var errors: [String] = []
        let fm = FileManager.default
        var renameMap: [(oldURL: URL, newURL: URL)] = []
        var nameMap: [(oldName: String, newName: String)] = []  // Undo용 파일명 매핑
        var ratingMap: [String: Int] = [:]         // oldFilename → rating
        var colorMap: [String: String] = [:]       // oldFilename → colorLabel.rawValue
        var spaceMap: [String: Bool] = [:]         // oldFilename → isSpacePicked

        // 레이팅/컬러라벨/스페이스픽 보존: 이름 변경 전에 메모리 값 수집
        if preserveRatings {
            for photo in targets {
                if photo.rating > 0 {
                    ratingMap[photo.fileName] = photo.rating
                }
                if photo.colorLabel != .none {
                    colorMap[photo.fileName] = photo.colorLabel.rawValue
                }
                if photo.isSpacePicked {
                    spaceMap[photo.fileName] = true
                }
            }
        }

        let folderPathKey = folderURL?.path ?? ""

        for (index, photo) in targets.enumerated() {
            var newBaseName = Self.previewRename(photo: photo, pattern: pattern, index: index, dateFormat: dateFormat, seqDigits: seqDigits, seqStart: seqStart)
            // 보안: 경로 구분자, null 문자 제거 (경로 이탈 방지)
            newBaseName = newBaseName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\0", with: "")
                .replacingOccurrences(of: ":", with: "_")
                .replacingOccurrences(of: "..", with: "_")
            let jpgExt = photo.jpgURL.pathExtension
            let parentDir = photo.jpgURL.deletingLastPathComponent()
            let newJPGURL = parentDir.appendingPathComponent("\(newBaseName).\(jpgExt)")

            if newJPGURL == photo.jpgURL { continue }

            if fm.fileExists(atPath: newJPGURL.path) {
                errors.append("\(photo.fileName): 이름 충돌")
                continue
            }

            do {
                // JPG 이름 변경
                try fm.moveItem(at: photo.jpgURL, to: newJPGURL)
                renameMap.append((photo.jpgURL, newJPGURL))
                nameMap.append((photo.fileName, newBaseName))

                // RAW 이름 변경
                if let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                    let rawExt = rawURL.pathExtension
                    let rawParent = rawURL.deletingLastPathComponent()
                    let newRAWURL = rawParent.appendingPathComponent("\(newBaseName).\(rawExt)")
                    if !fm.fileExists(atPath: newRAWURL.path) {
                        try fm.moveItem(at: rawURL, to: newRAWURL)
                        renameMap.append((rawURL, newRAWURL))
                    }
                }

                // XMP 사이드카 이동
                let xmpURL = photo.jpgURL.deletingPathExtension().appendingPathExtension("xmp")
                if fm.fileExists(atPath: xmpURL.path) {
                    let newXMPURL = parentDir.appendingPathComponent("\(newBaseName).xmp")
                    try? fm.moveItem(at: xmpURL, to: newXMPURL)
                    renameMap.append((xmpURL, newXMPURL))
                }

                // 레이팅/컬러라벨/스페이스픽 보존: UserDefaults 키를 새 파일명으로 갱신
                if preserveRatings {
                    // 1) 전역 photoRatings (파일명 → 별점)
                    if let rating = ratingMap[photo.fileName] {
                        var saved = UserDefaults.standard.dictionary(forKey: ratingsKey) as? [String: Int] ?? [:]
                        saved.removeValue(forKey: photo.fileName)
                        saved[newBaseName] = rating
                        UserDefaults.standard.set(saved, forKey: ratingsKey)
                    }
                    // 2) 폴더별 컬러라벨 (folderColorLabels[folderPath][fileName])
                    if !folderPathKey.isEmpty, let colorRaw = colorMap[photo.fileName] {
                        var allColors = UserDefaults.standard.dictionary(forKey: "folderColorLabels") as? [String: [String: String]] ?? [:]
                        var folderColors = allColors[folderPathKey] ?? [:]
                        folderColors.removeValue(forKey: photo.fileName)
                        folderColors[newBaseName] = colorRaw
                        allColors[folderPathKey] = folderColors
                        UserDefaults.standard.set(allColors, forKey: "folderColorLabels")
                    }
                    // 3) 폴더별 스페이스픽 (folderSpacePicks[folderPath][fileName])
                    if !folderPathKey.isEmpty, spaceMap[photo.fileName] == true {
                        var allSP = UserDefaults.standard.dictionary(forKey: "folderSpacePicks") as? [String: [String: Bool]] ?? [:]
                        var folderSP = allSP[folderPathKey] ?? [:]
                        folderSP.removeValue(forKey: photo.fileName)
                        folderSP[newBaseName] = true
                        allSP[folderPathKey] = folderSP
                        UserDefaults.standard.set(allSP, forKey: "folderSpacePicks")
                    }
                }

                successCount += 1
            } catch {
                errors.append("\(photo.fileName): \(error.localizedDescription)")
            }
        }

        // Undo 기록 저장
        lastRenameMap = renameMap
        lastRenameNameMap = nameMap
        lastRenameFolderPath = folderPathKey
        plog("[RENAME] 완료: \(successCount)개 성공, \(errors.count)개 실패, undo \(renameMap.count)개 기록\n")

        // 폴더 리로드
        if successCount > 0, let url = folderURL {
            loadFolder(url, restoreRatings: true)
        }

        return (successCount, errors)
    }

    /// 이름 변경 되돌리기
    func undoBatchRename() -> Bool {
        guard !lastRenameMap.isEmpty else { return false }
        let fm = FileManager.default
        var success = true

        // 1) 파일 역순으로 되돌리기
        for entry in lastRenameMap.reversed() {
            do {
                if fm.fileExists(atPath: entry.newURL.path) {
                    try fm.moveItem(at: entry.newURL, to: entry.oldURL)
                }
            } catch {
                plog("[RENAME] Undo 파일 복원 실패: \(error.localizedDescription)\n")
                success = false
            }
        }

        // 2) UserDefaults 레이팅/컬러라벨/스페이스픽 복원
        //    (newName에 있던 값을 oldName으로 되돌림)
        let folderPathKey = lastRenameFolderPath
        if !lastRenameNameMap.isEmpty {
            // 전역 레이팅
            var ratings = UserDefaults.standard.dictionary(forKey: ratingsKey) as? [String: Int] ?? [:]
            // 폴더별 컬러라벨
            var allColors = UserDefaults.standard.dictionary(forKey: "folderColorLabels") as? [String: [String: String]] ?? [:]
            var folderColors = folderPathKey.isEmpty ? [:] : (allColors[folderPathKey] ?? [:])
            // 폴더별 스페이스픽
            var allSP = UserDefaults.standard.dictionary(forKey: "folderSpacePicks") as? [String: [String: Bool]] ?? [:]
            var folderSP = folderPathKey.isEmpty ? [:] : (allSP[folderPathKey] ?? [:])

            for entry in lastRenameNameMap {
                // 레이팅: newName → oldName
                if let r = ratings[entry.newName] {
                    ratings.removeValue(forKey: entry.newName)
                    ratings[entry.oldName] = r
                }
                // 컬러라벨
                if !folderPathKey.isEmpty, let c = folderColors[entry.newName] {
                    folderColors.removeValue(forKey: entry.newName)
                    folderColors[entry.oldName] = c
                }
                // 스페이스픽
                if !folderPathKey.isEmpty, folderSP[entry.newName] == true {
                    folderSP.removeValue(forKey: entry.newName)
                    folderSP[entry.oldName] = true
                }
            }

            UserDefaults.standard.set(ratings, forKey: ratingsKey)
            if !folderPathKey.isEmpty {
                allColors[folderPathKey] = folderColors
                UserDefaults.standard.set(allColors, forKey: "folderColorLabels")
                allSP[folderPathKey] = folderSP
                UserDefaults.standard.set(allSP, forKey: "folderSpacePicks")
            }
        }

        lastRenameMap = []
        lastRenameNameMap = []
        lastRenameFolderPath = ""

        // 폴더 리로드
        if let url = folderURL {
            loadFolder(url, restoreRatings: true)
        }

        plog("[RENAME] Undo 완료: \(success)\n")
        return success
    }
}
