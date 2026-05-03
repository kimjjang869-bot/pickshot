import SwiftUI
import Foundation
import AppKit
import Vision

extension PhotoStore {
    // MARK: - Face grouping

    func setFaceGroupName(_ groupID: Int, name: String) {
        faceGroupNames[groupID] = name.isEmpty ? nil : name
        saveFaceGroupNames()
    }


    func faceGroupName(for groupID: Int) -> String {
        faceGroupNames[groupID] ?? "인물 \(groupID)"
    }


    private func saveFaceGroupNames() {
        guard let folderPath = folderURL?.path else { return }
        var all = UserDefaults.standard.dictionary(forKey: "faceGroupNames") as? [String: [String: String]] ?? [:]
        all[folderPath] = faceGroupNames.reduce(into: [:]) { $0["\($1.key)"] = $1.value }
        UserDefaults.standard.set(all, forKey: "faceGroupNames")
    }


    func loadFaceGroupNames() {
        guard let folderPath = folderURL?.path else { return }
        let all = UserDefaults.standard.dictionary(forKey: "faceGroupNames") as? [String: [String: String]] ?? [:]
        guard let saved = all[folderPath] else { return }
        faceGroupNames = saved.reduce(into: [:]) { dict, pair in
            if let key = Int(pair.key) { dict[key] = pair.value }
        }
    }

    // MARK: - ZIP 파일 열기 → openZipFile/cleanupZipTemp는 PhotoStore+Folder.swift


    // MARK: - Quality / Duplicate analysis

    func runQualityAnalysis() {
        guard !photos.isEmpty, !isAnalyzing else { return }
        isAnalyzing = true
        analyzeProgress = 0
        analysisCancel = false

        let photoSnapshots = photos
        let total = photoSnapshots.count
        let options = analysisOptions

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = ImageAnalysisService.analyzeBatch(
                photos: photoSnapshots,
                options: options,
                cancelCheck: {
                    // Cancel if user requested OR system overheating
                    if self?.analysisCancel == true { return true }
                    let thermal = ProcessInfo.processInfo.thermalState
                    if thermal == .critical {
                        DispatchQueue.main.async { self?.analysisCancel = true }
                        return true
                    }
                    return false
                },
                progress: { done in
                    let p = Double(done) / Double(total)
                    DispatchQueue.main.async {
                        self?.analyzeProgress = p
                    }
                }
            )

            DispatchQueue.main.async {
                guard let self = self else { return }
                if !results.isEmpty {
                    // in-place 업데이트 — 전체 배열 복사 방지 (10K 사진 시 ~8MB 절약)
                    self._suppressDidSet = true
                    for i in self.photos.indices {
                        if let quality = results[self.photos[i].id] {
                            self.photos[i].quality = quality
                        }
                    }
                    self._suppressDidSet = false
                    self.invalidateFilterCache()
                }
                self.isAnalyzing = false
                self.analysisCancel = false

                // Run duplicate grouping after analysis
                self.findDuplicates()

                // NIMA 미적 점수 분석 (모델 있을 때만)
                if NIMAService.isAvailable {
                    self.runNIMAScoring()
                }
            }
        }
    }


    private func runNIMAScoring() {
        let photoSnapshots = photos.filter { !$0.isFolder && !$0.isParentFolder }
        guard !photoSnapshots.isEmpty else { return }

        AppLogger.log(.general, "NIMA: \(photoSnapshots.count)장 미적 점수 분석 시작")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scores = NIMAService.scoreBatch(
                photos: photoSnapshots,
                cancelCheck: { false },
                progress: { _ in }
            )

            guard !scores.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                var updated = false
                for (id, nimaScore) in scores {
                    if let idx = self._photoIndex[id], idx < self.photos.count {
                        self.photos[idx].quality?.nimaScore = nimaScore
                        updated = true
                    }
                }
                if updated {
                    AppLogger.log(.general, "NIMA: \(scores.count)장 점수 적용 완료")
                }
            }
        }
    }


    func findDuplicates() {
        // 메인스레드에서 photos 스냅샷을 먼저 찍어서 백그라운드로 전달
        let snapshot = self.photos
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let groups = ImageAnalysisService.findDuplicateGroups(photos: snapshot)
            guard !groups.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let selectedID = self.selectedPhotoID
                self._suppressDidSet = true
                for i in 0..<self.photos.count {
                    if let group = groups[self.photos[i].id] {
                        self.photos[i].duplicateGroupID = group.groupID
                        self.photos[i].isBestInGroup = group.isBest
                    }
                }
                self._suppressDidSet = false
                self.rebuildIndex(); self.invalidateFilterCache()
                self.objectWillChange.send()
                self.selectedPhotoID = selectedID
            }
        }
    }


    func stopAnalysis() {
        analysisCancel = true
    }

    // MARK: - Smart Auto-Select


    // MARK: - Smart select

    func previewSmartSelect() {
        smartSelectResult = SmartSelectService.detectAndSelect(photos: photos, config: smartSelectConfig)
    }


    func applySmartSelect() {
        guard let result = smartSelectResult, !result.selectedIndices.isEmpty else { return }
        let validIndices = result.selectedIndices.filter { $0 < photos.count }
        pushUndo(action: "스마트 셀렉", photoIDs: Set(validIndices.map { photos[$0].id }))
        for idx in result.selectedIndices {
            guard idx < photos.count else { continue }
            photos[idx].isSpacePicked = true
        }
        saveRatings()
        showToastMessage("\(result.selectedCount)장 베스트샷 셀렉 완료")
    }


    // MARK: - Scene classification

    func classifyScenes() {
        guard !photos.isEmpty, !isClassifyingScenes else { return }
        isClassifyingScenes = true
        classifyProgress = 0
        classifyStartTime = CFAbsoluteTimeGetCurrent()

        let photoSnapshots = photos.filter { !$0.isFolder && !$0.isParentFolder }
        let total = photoSnapshots.count
        classifyTotalCount = total
        classifyDoneCount = 0
        classifyStatusMessage = "장면 분류 준비 중..."
        let startTime = classifyStartTime
        print("🏷 [SCENE] Start: \(total) photos")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.classifyStatusMessage = "장면 + 얼굴 + 색상 + 구도 분석 중..."
            }
            // 고급 분류 서비스 사용 (장면+얼굴+텍스트+동물+색상+구도 통합)
            let results = AdvancedClassificationService.classifyBatch(
                photos: photoSnapshots,
                cancelCheck: { false },
                progress: { done in
                    let c = done
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let rate = elapsed > 0 ? Double(c) / elapsed : 0
                    if c % 50 == 0 || c == total {
                        if c == total {
                            print("🏷 [SCENE] DONE: \(total) photos in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", rate)) photos/s)")
                        } else {
                            print("🏷 [SCENE] Progress: \(c)/\(total) in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", rate)) photos/s)")
                        }
                    }
                    // 더 빈번한 UI 업데이트 (10장마다 또는 전체 200장 이하면 매장)
                    if c % (total < 200 ? 1 : 10) == 0 || c == total {
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self else { return }
                            self.classifyProgress = Double(c) / Double(total)
                            self.classifyDoneCount = c
                            if c < total {
                                let eta = rate > 0 ? Double(total - c) / rate : 0
                                let etaStr = eta < 60 ? "\(Int(eta))초" : "\(Int(eta/60))분 \(Int(eta) % 60)초"
                                self.classifyStatusMessage = "분석 중 (\(String(format: "%.1f", rate))장/초) · 약 \(etaStr) 남음"
                            } else {
                                self.classifyStatusMessage = "결과 적용 중..."
                            }
                        }
                    }
                }
            )

            DispatchQueue.main.async {
                guard let self = self else { return }
                if !results.isEmpty {
                    let selectedID = self.selectedPhotoID
                    self._suppressDidSet = true
                    for i in 0..<self.photos.count {
                        if let result = results[self.photos[i].id] {
                            self.photos[i].sceneTag = result.sceneTag
                            self.photos[i].keywords = result.keywords
                            self.photos[i].colorMood = result.colorMood.rawValue
                            self.photos[i].compositionType = result.compositionType.rawValue
                            self.photos[i].timeOfDay = result.timeOfDay.rawValue
                            self.photos[i].dominantColors = result.dominantColors
                            self.photos[i].hasText = result.hasText
                            self.photos[i].personCoverage = result.personCoverage
                        }
                    }
                    self._suppressDidSet = false
                    self.rebuildIndex(); self.invalidateFilterCache()
                    self.selectedPhotoID = selectedID
                }
                self.isClassifyingScenes = false
                self.classifyProgress = 1.0
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                self.classifyStatusMessage = "완료! \(String(format: "%.1f", elapsed))초"

                // === 분류 결과 통계 로그 (stderr) ===
                let classified = self.photos.filter { $0.sceneTag != nil && !$0.isFolder && !$0.isParentFolder }
                let unclassified = self.photos.filter { $0.sceneTag == nil && !$0.isFolder && !$0.isParentFolder }
                var tagCounts: [String: Int] = [:]
                var moodCounts: [String: Int] = [:]
                var compCounts: [String: Int] = [:]
                var todCounts: [String: Int] = [:]
                // var totalFaces = 0  // v8.6.3: 미사용 제거 (집계 코드는 디버그 로그에서만 사용됐음)
                var personPhotos = 0
                var textPhotos = 0
                for p in classified {
                    tagCounts[p.sceneTag ?? "nil", default: 0] += 1
                    if let m = p.colorMood, !m.isEmpty { moodCounts[m, default: 0] += 1 }
                    if let c = p.compositionType, !c.isEmpty { compCounts[c, default: 0] += 1 }
                    if let t = p.timeOfDay, !t.isEmpty { todCounts[t, default: 0] += 1 }
                    if p.personCoverage > 0.03 { personPhotos += 1 }
                    if p.hasText { textPhotos += 1 }
                }
                // stderr + 파일 동시 출력
                var log = "\n[CLASSIFY] ━━━ 장면분류 결과 ━━━\n"
                log += "[CLASSIFY] 총 \(photoSnapshots.count)장 → 분류됨: \(classified.count)장, 미분류: \(unclassified.count)장\n"
                log += "[CLASSIFY] 장면태그:\n"
                for (tag, cnt) in tagCounts.sorted(by: { $0.value > $1.value }) {
                    log += "[CLASSIFY]   \(tag): \(cnt)장\n"
                }
                log += "[CLASSIFY] 색상분위기:\n"
                for (m, cnt) in moodCounts.sorted(by: { $0.value > $1.value }) {
                    log += "[CLASSIFY]   \(m): \(cnt)장\n"
                }
                log += "[CLASSIFY] 구도:\n"
                for (c, cnt) in compCounts.sorted(by: { $0.value > $1.value }) {
                    log += "[CLASSIFY]   \(c): \(cnt)장\n"
                }
                log += "[CLASSIFY] 시간대:\n"
                for (t, cnt) in todCounts.sorted(by: { $0.value > $1.value }) {
                    log += "[CLASSIFY]   \(t): \(cnt)장\n"
                }
                log += "[CLASSIFY] 인물감지: \(personPhotos)장, 텍스트감지: \(textPhotos)장\n"
                log += "[CLASSIFY] ━━━━━━━━━━━━━━━\n\n"
                plog(log)
                try? log.write(toFile: FileManager.default.temporaryDirectory.appendingPathComponent("pickshot_classify.log").path, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Face Grouping

    /// Available face group IDs

    // MARK: - Face grouping run

    func groupByFaces() {
        guard !photos.isEmpty, !isGroupingFaces else { return }
        isGroupingFaces = true
        faceGroupProgress = 0
        faceGroupStartTime = CFAbsoluteTimeGetCurrent()

        // 선택 여부 무관하게 폴더 내 전체 사진 대상
        let photoSnapshots = photos
        let total = photoSnapshots.count
        plog("[FACE] 전체 사진 \(total)장 대상 얼굴 그룹핑 시작\n")
        faceGroupTotalCount = total
        faceGroupDoneCount = 0
        faceGroupStatusMessage = "얼굴 감지 준비 중..."
        let startTime = faceGroupStartTime

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.faceGroupStatusMessage = "얼굴 감지 + 특징 추출 중..."
            }
            let results = FaceGroupingService.groupFaces(
                photos: photoSnapshots,
                progress: { [weak self] done in
                    let p = Double(done) / Double(total)
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let rate = elapsed > 0 ? Double(done) / elapsed : 0
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.faceGroupProgress = p
                        self.faceGroupDoneCount = done
                        if done < total {
                            let eta = rate > 0 ? Double(total - done) / rate : 0
                            let etaStr = eta < 60 ? "\(Int(eta))초" : "\(Int(eta/60))분 \(Int(eta) % 60)초"
                            self.faceGroupStatusMessage = "얼굴 분석 중 (\(String(format: "%.1f", rate))장/초) · 약 \(etaStr) 남음"
                        } else {
                            self.faceGroupStatusMessage = "얼굴 그룹 매칭 중..."
                        }
                    }
                }
            )

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !results.assignments.isEmpty {
                    let selectedID = self.selectedPhotoID
                    self._suppressDidSet = true
                    for (photoID, groupID) in results.assignments {
                        if let idx = self._photoIndex[photoID], idx < self.photos.count {
                            self.photos[idx].faceGroupID = groupID
                        }
                    }
                    self._suppressDidSet = false
                    self.rebuildIndex(); self.invalidateFilterCache()
                    self.objectWillChange.send()
                    self.selectedPhotoID = selectedID
                    self.faceGroups = results.groups
                    self.faceThumbnails = results.faceThumbnails

                    // Extract face thumbnails for groups that don't have one
                    for (groupID, photoIDs) in results.groups {
                        if self.faceThumbnails[groupID] == nil, let firstID = photoIDs.first,
                           let photo = self.photos.first(where: { $0.id == firstID }) {
                            if let thumb = extractFaceThumbnail(url: photo.jpgURL) {
                                self.faceThumbnails[groupID] = thumb
                            }
                        }
                    }
                }
                let groupCount = results.groups.count
                let faceCount = results.assignments.count
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                self.faceGroupStatusMessage = "완료! \(groupCount)명, \(faceCount)장 · \(String(format: "%.1f", elapsed))초"
                self.isGroupingFaces = false
                self.faceGroupProgress = 1.0
            }
        }
    }

    // MARK: - AI Smart Classification

    /// 커스텀 프롬프트 저장 (UI에서 설정)

    // MARK: - AI classification

    func runAIClassification(customPrompt: String? = nil, selectedOnly: Bool = false) {
        // 엔진에 따라 적절한 API 키 확인
        let engine = UserDefaults.standard.string(forKey: "aiClassifyEngine") ?? "claudeHaiku"
        let hasKey = engine.hasPrefix("gemini") ? GeminiService.hasAPIKey : ClaudeVisionService.hasAPIKey
        guard !photos.isEmpty, !isAIClassifying, hasKey else { return }
        // v9.1.4: 외부 전송 동의 (보안 감사 M-5). UI 액션 경로 → 메인 액터 가정 안전.
        guard MainActor.assumeIsolated({ AIConsentGate.requireConsent() }) else { return }
        isAIClassifying = true
        aiClassifyErrors = []

        // 선택된 사진만 or 전체
        let photoSnapshots: [PhotoItem]
        if selectedOnly {
            photoSnapshots = multiSelectedPhotos.isEmpty ? (selectedPhoto.map { [$0] } ?? []) : multiSelectedPhotos
        } else {
            photoSnapshots = filteredPhotos
        }
        aiClassifyProgress = (0, photoSnapshots.count)
        let prompt = customPrompt?.isEmpty == false ? customPrompt : nil

        let baseURL = folderURL

        // 폴더 제외 + 이미 분류된 사진 스킵
        let unclassified = photoSnapshots.filter { !$0.isFolder && !$0.isParentFolder && $0.aiCategory == nil }
        let skippedCount = photoSnapshots.count - unclassified.count
        if skippedCount > 0 {
            plog("[CLASSIFY] \(skippedCount)장 이미 분류됨 → 스킵, \(unclassified.count)장 처리\n")
        }
        guard !unclassified.isEmpty else {
            showToastMessage("모든 사진이 이미 분류되어 있습니다")
            isAIClassifying = false
            return
        }
        aiClassifyProgress = (skippedCount, photoSnapshots.count)

        Task { @MainActor in
            do {
                let results = try await ClaudeVisionService.batchClassify(
                    photos: unclassified,
                    customPrompt: prompt,
                    progress: { [weak self] done, total in
                        self?.aiClassifyProgress = (skippedCount + done, photoSnapshots.count)
                    },
                    onClassified: { photo, classification in
                        // 분류 즉시 폴더 이동 (중간에 멈춰도 처리됨)
                        let category = classification.category
                        plog("[CLASSIFY] base=\(baseURL?.path ?? "nil") cat='\(category)' file=\(photo.jpgURL.lastPathComponent)\n")
                        guard let base = baseURL else {
                            plog("[CLASSIFY] ❌ baseURL nil\n")
                            return
                        }
                        guard !category.isEmpty else {
                            plog("[CLASSIFY] ❌ category empty\n")
                            return
                        }
                        let fm = FileManager.default
                        let categoryFolder = base.appendingPathComponent(category)
                        do {
                            try fm.createDirectory(at: categoryFolder, withIntermediateDirectories: true)
                        } catch {
                            plog("[CLASSIFY] ❌ mkdir failed: \(error)\n")
                        }

                        // JPG 이동
                        let jpgDest = categoryFolder.appendingPathComponent(photo.jpgURL.lastPathComponent)
                        if !fm.fileExists(atPath: jpgDest.path) {
                            do {
                                try fm.moveItem(at: photo.jpgURL, to: jpgDest)
                                plog("[CLASSIFY] ✅ \(photo.jpgURL.lastPathComponent) → \(category)/\n")
                            } catch {
                                plog("[CLASSIFY] ❌ move failed: \(error)\n")
                            }
                        }
                        // RAW 매칭 파일도 이동
                        if let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                            let rawDest = categoryFolder.appendingPathComponent(rawURL.lastPathComponent)
                            if !fm.fileExists(atPath: rawDest.path) {
                                try? fm.moveItem(at: rawURL, to: rawDest)
                            }
                        }
                    },
                    onError: { [weak self] photo, errorMsg in
                        // 에러 수집 (메인 스레드에서 실행)
                        DispatchQueue.main.async {
                            self?.aiClassifyErrors.append((photo.jpgURL.lastPathComponent, errorMsg))
                        }
                    }
                )

                // 분류 결과를 photos 배열에도 반영
                let selectedID = self.selectedPhotoID
                var updated = self.photos
                for i in 0..<updated.count {
                    if let classification = results[updated[i].id] {
                        updated[i].aiCategory = classification.category
                        updated[i].aiSubcategory = classification.subcategory
                        updated[i].aiMood = classification.mood
                        updated[i].aiUsability = classification.usability
                        updated[i].aiBestFor = classification.bestFor
                        updated[i].aiDescription = classification.description
                        updated[i].aiScore = classification.score
                    }
                }
                self.photos = updated
                self.selectedPhotoID = selectedID

                // 완료 → 결과 생성 + 폴더 리로딩
                let successCount = results.count
                let errorCount = self.aiClassifyErrors.count
                let totalCount = unclassified.count

                // 카테고리별 통계
                var categoryStats: [String: Int] = [:]
                for (_, c) in results {
                    categoryStats[c.category, default: 0] += 1
                }
                let sortedCats = categoryStats.sorted { $0.value > $1.value }

                // 결과 메시지 생성
                let engine = UserDefaults.standard.string(forKey: "aiClassifyEngine") ?? "claudeHaiku"
                let cost = APIUsageTracker.shared.estimatedCostUSD
                var msg = "━━━━ AI 분류 완료 ━━━━\n\n"
                msg += "📊 전체: \(totalCount)장\n"
                msg += "✅ 성공: \(successCount)장\n"
                if errorCount > 0 {
                    msg += "❌ 실패: \(errorCount)장\n"
                }
                msg += "🤖 엔진: \(engine)\n"
                msg += "💰 비용: $\(String(format: "%.4f", cost))\n\n"

                if !sortedCats.isEmpty {
                    msg += "━━━━ 카테고리별 ━━━━\n"
                    for (cat, count) in sortedCats {
                        let pct = Int(Double(count) / Double(max(successCount, 1)) * 100)
                        msg += "📁 \(cat): \(count)장 (\(pct)%)\n"
                    }
                }

                if errorCount > 0 {
                    msg += "\n━━━━ 실패 항목 ━━━━\n"
                    for (filename, errMsg) in self.aiClassifyErrors.suffix(5) {
                        msg += "⚠️ \(filename): \(errMsg)\n"
                    }
                    if errorCount > 5 {
                        msg += "... 외 \(errorCount - 5)건\n"
                    }
                }

                self.aiClassifyResultMessage = msg
                self.showAIClassifyResult = true

                if successCount > 0, let base = baseURL {
                    NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
                    self.loadFolder(base, restoreRatings: true)
                }
            } catch {
                self.aiClassifyResultMessage = "❌ AI 분류 실패\n\n\(error.localizedDescription)"
                self.showAIClassifyResult = true
            }
            self.isAIClassifying = false
        }
    }

    /// 분류 완료 결과 표시

    // MARK: - Organize by AI category

    func organizeByAICategory() {
        guard let baseURL = folderURL else { return }
        let fm = FileManager.default
        var movedCount = 0
        var failedCount = 0

        // 분류된 사진만 대상
        let categorized = photos.filter { $0.aiCategory != nil && !$0.isFolder && !$0.isParentFolder }
        guard !categorized.isEmpty else { return }

        for photo in categorized {
            guard let category = photo.aiCategory else { continue }

            // 카테고리 폴더 생성
            let categoryFolder = baseURL.appendingPathComponent(category)
            try? fm.createDirectory(at: categoryFolder, withIntermediateDirectories: true)

            // JPG 이동
            let jpgDest = categoryFolder.appendingPathComponent(photo.jpgURL.lastPathComponent)
            if !fm.fileExists(atPath: jpgDest.path) {
                do {
                    try fm.moveItem(at: photo.jpgURL, to: jpgDest)
                    movedCount += 1
                } catch {
                    failedCount += 1
                    plog("[ORGANIZE] 이동 실패: \(photo.jpgURL.lastPathComponent) → \(error.localizedDescription)\n")
                }
            }

            // RAW 매칭 파일도 이동
            if let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                let rawDest = categoryFolder.appendingPathComponent(rawURL.lastPathComponent)
                if !fm.fileExists(atPath: rawDest.path) {
                    try? fm.moveItem(at: rawURL, to: rawDest)
                }
            }
        }

        plog("[ORGANIZE] 완료: \(movedCount)장 이동, \(failedCount)장 실패\n")
        showToastMessage("📂 \(movedCount)장을 \(Set(categorized.compactMap { $0.aiCategory }).count)개 폴더로 정리 완료")

        // 폴더 트리 새로고침 알림
        NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)

        // 폴더 다시 로딩
        loadFolder(baseURL, restoreRatings: true)
    }

    /// Available AI categories

}
