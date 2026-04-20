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

/// 검색 타입 — 얼굴은 얼굴 전용 임베딩, 사물/장면은 CLIP 임베딩
enum VisualSearchMode: String, Codable {
    case face    // ArcFace / Landmark embedding — 얼굴 식별 특화
    case object  // MobileCLIP image embedding — 사물/장면/스타일 범용
}

/// 사용자가 드래그한 참조 영역
struct VisualSearchReference: Identifiable {
    let id = UUID()
    let mode: VisualSearchMode
    let sourceURL: URL           // 원본 사진
    let cropRect: CGRect?        // 크롭 영역 (nil = 전체 이미지)
    let embedding: [Float]       // 계산된 임베딩
    let label: String?           // "신부", "부케" 등 (UI용, 없으면 자동 이름)
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
    @Published var threshold: Float = 0.72           // 기본 중간 — 엄격(0.85) / 보통(0.72) / 느슨(0.60)
    @Published var isSearching: Bool = false
    @Published var progress: (done: Int, total: Int) = (0, 0)
    @Published var matchedURLs: Set<URL> = []        // PhotoStore 필터가 참조

    enum CombineMode: String, CaseIterable {
        case or = "한 명이라도"     // 하나라도 매칭되면 포함
        case and = "전부 포함"      // 모든 레퍼런스가 매칭돼야 포함
    }

    private var searchWork: DispatchWorkItem?

    private init() {}

    // MARK: - 참조 관리

    /// 기준 추가 (드래그 크롭 + 모드 선택 후 호출)
    func addReference(
        mode: VisualSearchMode,
        sourceURL: URL,
        cropRect: CGRect?,
        label: String? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let vec = self.computeEmbedding(mode: mode, url: sourceURL, cropRect: cropRect)
            guard !vec.isEmpty else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let ref = VisualSearchReference(
                mode: mode,
                sourceURL: sourceURL,
                cropRect: cropRect,
                embedding: vec,
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
    }

    // MARK: - 검색 실행

    /// 대상 사진들에 대해 모든 참조와 비교. matchedURLs 채움.
    func runSearch(on urls: [URL]) {
        guard !references.isEmpty else {
            matchedURLs = []
            return
        }
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

        // 얼굴 매칭 — 사진의 모든 얼굴 중 하나라도 참조와 유사하면 match
        if !faceRefs.isEmpty {
            let embs = FaceEmbeddingService.shared.embeddings(for: url)
            for ref in faceRefs {
                var bestSim: Float = 0
                for face in embs {
                    // 임시: ref.embedding 과 face.vector 모두 face 백엔드 차원이라고 가정
                    guard face.vector.count == ref.embedding.count else { continue }
                    let sim = cosineSimilarity(face.vector, ref.embedding)
                    if sim > bestSim { bestSim = sim }
                }
                if bestSim >= threshold { faceMatchCount += 1 }
            }
        }

        // 사물 매칭 — Phase 2 (MobileCLIP) 구현 후 활성화. 지금은 얼굴만.
        // TODO: ObjectEmbeddingService.shared.embedding(for: url, rect: ref.cropRect) 비교
        _ = objectRefs
        _ = objectMatchCount

        let totalRefs = faceRefs.count + objectRefs.count
        let totalMatches = faceMatchCount + objectMatchCount

        switch combine {
        case .or:  return totalMatches >= 1
        case .and: return totalMatches == totalRefs
        }
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
            // Phase 2: MobileCLIP image embedding
            // TODO: ObjectEmbeddingService.shared.embedding(from: cg) 호출
            return []
        }
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

