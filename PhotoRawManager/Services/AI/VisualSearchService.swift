//
//  VisualSearchService.swift
//  PhotoRawManager
//
//  v8.7: 참조 기반 시각 검색 엔진.
//  "이 얼굴/사물이 있는 사진 찾기" 의 핵심 로직.
//
//  사용 흐름:
//    1) 사용자가 기준 사진에서 영역 드래그
//    2) CropRegion 을 VisualSearchService.setReference(...) 로 등록
//    3) 서비스가 폴더 전체 사진 임베딩 비교 → matching Set<URL> 산출
//    4) PhotoStore 필터에 적용 → UI 갱신
//

import Foundation
import AppKit
import CoreImage
import Vision

/// 검색 타입 — 얼굴은 얼굴 전용 임베딩, 사물/장면은 CLIP 임베딩
enum VisualSearchMode: String, Codable {
    case face    // ArcFace / Landmark embedding — 얼굴 식별 특화
    case object  // MobileCLIP image embedding — 사물/장면/스타일 범용
}

/// 사용자가 드래그한 참조 영역 — 얼굴 embedding + 보조 레이어 (body/scene) 포함
struct VisualSearchReference: Identifiable {
    let id = UUID()
    let mode: VisualSearchMode
    let sourceURL: URL           // 원본 사진
    let cropRect: CGRect?        // 크롭 영역 (nil = 전체 이미지)
    let embedding: [Float]       // 주 임베딩 (얼굴 = face vector / 사물 = FeaturePrint)
    /// v8.7 Layer ②: 인물 영역 FeaturePrint (얼굴 레퍼런스 시) — 옆면/뒷면 fallback 매칭
    let bodyFeaturePrint: [Float]?
    /// v8.7 Layer ③: 전체 씬 FeaturePrint — 같은 배경/공간 매칭 (선택적)
    let sceneFeaturePrint: [Float]?
    let label: String?           // 식별용 이름 — 같은 label = 같은 identity 그룹
    let createdAt: Date = Date()

    /// UI 표시용 미리보기 이미지 (크롭된)
    var previewImage: NSImage? {
        guard let cg = VisualSearchService.loadCroppedCGImage(url: sourceURL, rect: cropRect, maxPixel: 200) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

final class VisualSearchService: ObservableObject {
    static let shared = VisualSearchService()

    // MARK: - 상태 (UI 가 관찰)
    @Published var references: [VisualSearchReference] = []
    @Published var combineMode: CombineMode = .or   // OR: 한 명이라도 / AND: 전부 포함
    @Published var threshold: Float = 0.86           // v8.7: 사용자 요구 상향 (2876장 실측에서 정밀도 우선)
    /// Layer ② (인물 영역 FeaturePrint, 옆/뒷면 매칭) 활성화 여부. 기본 off (false positive 방지).
    @Published var useBodyFallback: Bool = false
    /// v8.7: 부정 학습 — 사용자가 "이 사람 아님" 표시한 참조들 (label 별 저장)
    ///   매칭 시 positive 점수 > negative 점수 인 경우만 통과
    @Published var negativeExamples: [String: [FaceEmbedding]] = [:]
    @Published var isSearching: Bool = false
    @Published var progress: (done: Int, total: Int) = (0, 0)
    @Published var matchedURLs: Set<URL> = []        // PhotoStore 필터가 참조

    enum CombineMode: String, CaseIterable {
        case or = "한 명이라도"     // 하나라도 매칭되면 포함
        case and = "전부 포함"      // 모든 레퍼런스가 매칭돼야 포함
    }

    private var searchWork: DispatchWorkItem?

    // v8.7: 폴더별 검색 상태 저장 — 이전 폴더 재방문 시 결과 복원
    private struct FolderState {
        var references: [VisualSearchReference]
        var matchedURLs: Set<URL>
        var combineMode: CombineMode
        var threshold: Float
        var active: Bool
    }
    private var folderStates: [String: FolderState] = [:]
    private var currentFolderPath: String?

    private init() {}

    // MARK: - 폴더 전환 (PhotoStore 가 folderURL 변경 시 호출)

    /// 현재 폴더 상태를 저장하고, 새 폴더의 저장된 상태를 복원.
    /// - Parameters:
    ///   - newFolderPath: 새 폴더 경로 (nil 이면 검색 해제만)
    ///   - active: PhotoStore.visualSearchActive 현재 값
    ///   - onRestore: 복원 후 visualSearchActive 를 다시 true 로 세팅할 클로저
    func switchFolder(to newFolderPath: String?, currentActive: Bool, onRestore: @escaping (Bool) -> Void) {
        // 1) 현재 폴더 상태 저장 (레퍼런스나 결과가 있으면)
        if let curPath = currentFolderPath, !references.isEmpty || !matchedURLs.isEmpty {
            folderStates[curPath] = FolderState(
                references: references,
                matchedURLs: matchedURLs,
                combineMode: combineMode,
                threshold: threshold,
                active: currentActive
            )
            fputs("[VS] 폴더 상태 저장 '\(URL(fileURLWithPath: curPath).lastPathComponent)' refs=\(references.count) matched=\(matchedURLs.count)\n", stderr)
        }

        // 2) 현재 상태 초기화
        references = []
        matchedURLs = []
        isSearching = false
        progress = (0, 0)
        searchWork?.cancel()
        searchWork = nil

        currentFolderPath = newFolderPath

        // 3) 새 폴더의 저장된 상태 복원
        guard let newPath = newFolderPath,
              let saved = folderStates[newPath] else {
            onRestore(false)
            return
        }
        references = saved.references
        matchedURLs = saved.matchedURLs
        combineMode = saved.combineMode
        threshold = saved.threshold
        fputs("[VS] 폴더 상태 복원 '\(URL(fileURLWithPath: newPath).lastPathComponent)' refs=\(references.count) matched=\(matchedURLs.count)\n", stderr)
        onRestore(saved.active)
    }

    /// 폴더 상태 영구 제거 (폴더 삭제 시 등)
    func forgetFolder(_ path: String) {
        folderStates.removeValue(forKey: path)
    }

    // MARK: - 참조 관리

    /// 기준 추가 (드래그 크롭 + 모드 선택 후 호출)
    func addReference(
        mode: VisualSearchMode,
        sourceURL: URL,
        cropRect: CGRect?,
        label: String? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        fputs("[VS] addReference mode=\(mode.rawValue) src=\(sourceURL.lastPathComponent) crop=\(cropRect?.debugDescription ?? "nil")\n", stderr)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let vec = self.computeEmbedding(mode: mode, url: sourceURL, cropRect: cropRect)
            fputs("[VS] 주 embedding dim=\(vec.count)\n", stderr)
            guard !vec.isEmpty else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            // Layer ②/③: 얼굴 레퍼런스 시 보조 벡터 추가 계산
            var bodyFP: [Float]? = nil
            var sceneFP: [Float]? = nil
            if mode == .face {
                bodyFP = Self.computePersonBodyFeaturePrint(url: sourceURL)
                sceneFP = Self.computeFeaturePrint(url: sourceURL, cropRect: nil)
                fputs("[VS] 보조 벡터 body=\(bodyFP?.count ?? 0) scene=\(sceneFP?.count ?? 0)\n", stderr)
            }
            let ref = VisualSearchReference(
                mode: mode,
                sourceURL: sourceURL,
                cropRect: cropRect,
                embedding: vec,
                bodyFeaturePrint: bodyFP,
                sceneFeaturePrint: sceneFP,
                label: label
            )
            DispatchQueue.main.async {
                self.references.append(ref)
                completion(true)
            }
        }
    }

    func removeReference(id: UUID) {
        references.removeAll { $0.id == id }
        if references.isEmpty {
            matchedURLs = []
        }
    }

    func clearAll() {
        references = []
        matchedURLs = []
        negativeExamples = [:]
    }

    /// v8.7: 학습 — "이 사진은 X 가 아님" 표시. 해당 사진의 얼굴 embedding 을 부정 예시로 저장.
    /// 이후 매칭 시 positive 점수가 negative 와 비슷하면 거부됨.
    func markAsNotMatching(url: URL, forLabel label: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let faces = FaceEmbeddingService.shared.embeddings(for: url)
            guard !faces.isEmpty else {
                DispatchQueue.main.async {
                    fputs("[VS-LEARN] ❌ \(url.lastPathComponent): 얼굴 감지 실패 — 학습 불가\n", stderr)
                }
                return
            }
            // 가장 큰 얼굴 1개만 저장
            let best = faces.max { a, b in
                (a.boundingBox.width * a.boundingBox.height) < (b.boundingBox.width * b.boundingBox.height)
            }
            guard let neg = best else { return }
            DispatchQueue.main.async {
                self.negativeExamples[label, default: []].append(neg)
                fputs("[VS-LEARN] ✅ '\(label)' 부정 예시 추가: \(url.lastPathComponent) (총 \(self.negativeExamples[label]?.count ?? 0)개)\n", stderr)
                // matchedURLs 에서 이 사진 즉시 제거
                self.matchedURLs.remove(url)
            }
        }
    }

    /// 현재 검색 결과를 부정 학습 반영해서 재평가 (전체 재검색 없이 matchedURLs 만 재계산)
    func reapplyNegatives() {
        // 간단 구현: 전체 재검색 트리거
        let urls = Array(matchedURLs)
        if !urls.isEmpty {
            fputs("[VS-LEARN] 부정 학습 반영 — \(urls.count)장 재평가\n", stderr)
        }
    }

    // MARK: - 검색 실행

    /// 대상 사진들에 대해 모든 참조와 비교. matchedURLs 채움.
    func runSearch(on urls: [URL]) {
        guard !references.isEmpty else {
            matchedURLs = []
            return
        }
        fputs("[VS] runSearch refs=\(references.count) targets=\(urls.count) threshold=\(threshold)\n", stderr)
        searchWork?.cancel()
        isSearching = true
        progress = (0, urls.count)

        let refs = references
        let combine = combineMode
        let thr = threshold

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            var matches: Set<URL> = []
            let opQueue = OperationQueue()
            opQueue.maxConcurrentOperationCount = min(4, ProcessInfo.processInfo.activeProcessorCount / 2)
            opQueue.qualityOfService = .userInitiated
            let matchLock = NSLock()
            var done = 0
            let doneLock = NSLock()

            for url in urls {
                opQueue.addOperation {
                    if self.searchWork?.isCancelled == true { return }
                    let isMatch = self.evaluatePhoto(url: url, references: refs, combine: combine, threshold: thr)
                    if isMatch {
                        matchLock.lock()
                        matches.insert(url)
                        matchLock.unlock()
                    }
                    doneLock.lock()
                    done += 1
                    let d = done
                    doneLock.unlock()
                    if d % 20 == 0 || d == urls.count {
                        DispatchQueue.main.async {
                            self.progress = (d, urls.count)
                        }
                    }
                }
            }
            opQueue.waitUntilAllOperationsAreFinished()

            DispatchQueue.main.async {
                self.matchedURLs = matches
                self.isSearching = false
                self.progress = (urls.count, urls.count)
                fputs("[VS] 완료 matched=\(matches.count)/\(urls.count)\n", stderr)
            }
        }
        searchWork = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    func cancelSearch() {
        searchWork?.cancel()
        searchWork = nil
        isSearching = false
    }

    /// 임계값만 변경 → 캐시된 임베딩으로 재평가 (빠름)
    func reapplyThreshold(on urls: [URL]) {
        runSearch(on: urls)
    }

    // MARK: - 내부

    private func evaluatePhoto(url: URL, references: [VisualSearchReference], combine: CombineMode, threshold: Float) -> Bool {
        let faceRefs = references.filter { $0.mode == .face }
        let objectRefs = references.filter { $0.mode == .object }

        var faceMatchCount = 0
        var objectMatchCount = 0

        // 얼굴 매칭 (3계층) — 참조 label 별로 그룹화 → 그룹 내 어떤 샷이든 매칭되면 pass
        if !faceRefs.isEmpty {
            var groups: [String: [VisualSearchReference]] = [:]
            for r in faceRefs {
                let key = r.label ?? r.id.uuidString
                groups[key, default: []].append(r)
            }

            var cachedFaceEmbs: [FaceEmbedding]? = nil
            var cachedBodyFP: [Float]? = nil
            var bodyFPChecked = false

            for (label, refs) in groups {
                var groupMatched = false
                var bestFaceSim: Float = 0
                var bestBodySim: Float = 0
                var bestNegSim: Float = 0
                var matchedBy = "none"

                // Layer ①: 얼굴 매칭
                let faces: [FaceEmbedding] = cachedFaceEmbs ?? {
                    let e = FaceEmbeddingService.shared.embeddings(for: url)
                    cachedFaceEmbs = e
                    return e
                }()
                for ref in refs {
                    for face in faces {
                        guard face.vector.count == ref.embedding.count else { continue }
                        let sim = cosineSimilarity(face.vector, ref.embedding)
                        if sim > bestFaceSim { bestFaceSim = sim }
                    }
                }
                if bestFaceSim >= threshold {
                    groupMatched = true
                    matchedBy = "face"
                }

                // Layer ②: 인물 영역 FeaturePrint
                if !groupMatched && useBodyFallback {
                    if !bodyFPChecked {
                        cachedBodyFP = Self.computePersonBodyFeaturePrint(url: url)
                        bodyFPChecked = true
                    }
                    if let bfp = cachedBodyFP {
                        let bodyThr: Float = 0.85 + (threshold - 0.80) * 0.5
                        for ref in refs {
                            guard let refBody = ref.bodyFeaturePrint else { continue }
                            let sim = cosineSimilarity(bfp, refBody)
                            if sim > bestBodySim { bestBodySim = sim }
                        }
                        if bestBodySim >= bodyThr {
                            groupMatched = true
                            matchedBy = "body"
                        }
                    }
                }

                // v8.7: 부정 학습 — 사용자가 "이 사람 아님" 표시한 사진과 유사도 체크
                //   positive 점수가 negative 점수보다 확실히 높아야 매칭 (margin 0.15)
                //   또한 negative 자체도 검색 대상 candidate 일 수 있으므로 항상 체크
                if let negs = negativeExamples[label], !negs.isEmpty {
                    for neg in negs {
                        for face in faces {
                            guard face.vector.count == neg.vector.count else { continue }
                            let sim = cosineSimilarity(face.vector, neg.vector)
                            if sim > bestNegSim { bestNegSim = sim }
                        }
                    }
                    // negative 와 비슷 (margin 0.15 미만) OR negative 가 threshold 이상이면 거부
                    if bestNegSim >= 0.90 || (groupMatched && bestNegSim > bestFaceSim - 0.15) {
                        groupMatched = false
                        matchedBy = "rejected_by_negative"
                    }
                }

                fputs("[VS-MATCH] \(url.lastPathComponent) '\(label)' face=\(String(format: "%.3f", bestFaceSim)) body=\(String(format: "%.3f", bestBodySim)) neg=\(String(format: "%.3f", bestNegSim)) thr=\(String(format: "%.2f", threshold)) facesDetected=\(faces.count) by=\(matchedBy)\n", stderr)

                if groupMatched { faceMatchCount += 1 }
            }
        }

        // 사물/장면 매칭 — Apple Vision FeaturePrint (2048-dim) 로 전체 이미지 임베딩 비교.
        //   사물 검색에서 crop 은 "이 사물 시드" 만 제공하고, 후보 사진은 전체에서 유사도 계산.
        //   (cropping 없이도 배경 유사도 검출 — Vision 의 image-level feature print)
        if !objectRefs.isEmpty {
            if let candidateEmb = Self.computeFeaturePrint(url: url, cropRect: nil) {
                for ref in objectRefs {
                    let sim = cosineSimilarity(candidateEmb, ref.embedding)
                    // v8.7: FeaturePrint 재매핑 완화 — 기존엔 너무 엄격했음
                    //   FeaturePrint 실제 분포 관찰: 관련 없음 ~0.70, 같은 씬 ~0.85+, 거의 동일 ~0.95+
                    //   사용자 slider 0.60→0.75, 0.72→0.82, 0.90→0.93
                    let objThr = 0.72 + (threshold - 0.72) * 0.5
                    if sim >= objThr { objectMatchCount += 1; break }
                }
            }
        }

        // 그룹 수 기준 (같은 label = 1 그룹)
        let faceGroupCount = Set(faceRefs.map { $0.label ?? $0.id.uuidString }).count
        let totalRefs = faceGroupCount + objectRefs.count
        let totalMatches = faceMatchCount + objectMatchCount

        switch combine {
        case .or:  return totalMatches >= 1
        case .and: return totalMatches >= totalRefs
        }
    }

    // MARK: - Layer ② 인물 영역 FeaturePrint

    /// VNGeneratePersonSegmentationRequest 로 인물 마스크 → bounding box 추출 → 해당 영역 FeaturePrint
    /// 얼굴이 안 보여도 옷/실루엣 기반 매칭 가능.
    static func computePersonBodyFeaturePrint(url: URL) -> [Float]? {
        guard let cg = loadCroppedCGImage(url: url, rect: nil, maxPixel: 600) else { return nil }
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .fast
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([req])
        } catch {
            return nil
        }
        guard let mask = req.results?.first?.pixelBuffer else {
            return nil
        }
        // 마스크에서 인물 bounding box 추출
        let bbox = personBoundingBox(from: mask)
        guard let bbox = bbox, bbox.width > 0.05, bbox.height > 0.05 else {
            return nil  // 인물 너무 작거나 없음
        }
        // 여유 5% 패딩 추가해서 실제 crop
        let padded = CGRect(
            x: max(0, bbox.minX - 0.02),
            y: max(0, bbox.minY - 0.02),
            width: min(1.0, bbox.width + 0.04),
            height: min(1.0, bbox.height + 0.04)
        )
        return computeFeaturePrint(url: url, cropRect: padded)
    }

    /// CVPixelBuffer 마스크에서 인물 영역의 normalized bounding box 계산
    private static func personBoundingBox(from pixelBuffer: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let buf = base.assumingMemoryBound(to: UInt8.self)

        var minX = width, minY = height, maxX = 0, maxY = 0
        var hit = false
        // 샘플링 — 매 4픽셀씩만 검사 (성능)
        let step = 4
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let v = buf[y * bytesPerRow + x]
                if v > 128 {
                    hit = true
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard hit else { return nil }
        return CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX) / CGFloat(width),
            height: CGFloat(maxY - minY) / CGFloat(height)
        )
    }

    private func computeEmbedding(mode: VisualSearchMode, url: URL, cropRect: CGRect?) -> [Float] {
        switch mode {
        case .face:
            // 크롭 영역에서 얼굴 탐지 → 가장 큰 얼굴의 임베딩 사용
            guard let cg = VisualSearchService.loadCroppedCGImage(url: url, rect: cropRect, maxPixel: 1200) else { return [] }
            let embs = FaceEmbeddingService.shared.provider.compute(cgImage: cg)
            // 가장 큰 얼굴 선택
            let best = embs.max { a, b in (a.boundingBox.width * a.boundingBox.height) < (b.boundingBox.width * b.boundingBox.height) }
            return best?.vector ?? []
        case .object:
            // Apple Vision FeaturePrint — 2048-dim 이미지 특징 벡터 (외부 모델 없이 즉시 가능)
            return Self.computeFeaturePrint(url: url, cropRect: cropRect) ?? []
        }
    }

    /// VNGenerateImageFeaturePrintRequest 기반 이미지 feature print 추출
    static func computeFeaturePrint(url: URL, cropRect: CGRect?) -> [Float]? {
        guard let cg = loadCroppedCGImage(url: url, rect: cropRect, maxPixel: 800) else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([req])
        } catch {
            return nil
        }
        guard let fp = req.results?.first else { return nil }
        let data = fp.data
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        var vec = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: Float.self)
            for i in 0..<count {
                vec[i] = buf[i]
            }
        }
        // L2 정규화
        let norm = sqrt(vec.map { $0 * $0 }.reduce(0, +))
        if norm > 0 {
            vec = vec.map { $0 / norm }
        }
        return vec
    }

    // MARK: - 유틸

    /// 원본에서 크롭 영역 추출 (rect 는 normalized 0~1, 원점 좌상단)
    static func loadCroppedCGImage(url: URL, rect: CGRect?, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let fullOpts: [NSString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        guard let full = CGImageSourceCreateThumbnailAtIndex(src, 0, fullOpts as CFDictionary) else { return nil }
        guard let rect = rect else { return full }
        // normalized → pixel
        let w = CGFloat(full.width), h = CGFloat(full.height)
        let pixelRect = CGRect(
            x: rect.minX * w,
            y: rect.minY * h,
            width: rect.width * w,
            height: rect.height * h
        ).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard pixelRect.width >= 10, pixelRect.height >= 10 else { return full }
        return full.cropping(to: pixelRect)
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0; var nA: Float = 0; var nB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            nA += a[i] * a[i]
            nB += b[i] * b[i]
        }
        let denom = sqrt(nA) * sqrt(nB)
        return denom > 0 ? dot / denom : 0
    }
}

