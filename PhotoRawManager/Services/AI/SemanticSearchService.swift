//
//  SemanticSearchService.swift
//  PhotoRawManager
//
//  v8.9: 시맨틱 검색 오케스트레이터.
//  - 폴더 진입 시 백그라운드 인덱싱 (ImageEmbeddingService × EmbeddingIndex)
//  - 참조 이미지 기반 유사도 top-K 검색 ("이 사진과 비슷한 것")
//  - 텍스트 검색은 TextEncoderService 완성 후 활성화 (v8.9 Phase 2)
//

import Foundation
import AppKit

final class SemanticSearchService {
    static let shared = SemanticSearchService()

    /// 현재 인덱싱 진행 상태 (0.0 ~ 1.0).
    private(set) var indexProgress: Double = 0
    private(set) var indexTotal: Int = 0
    private(set) var indexDone: Int = 0
    private(set) var isIndexing: Bool = false

    private let indexQueue = DispatchQueue(label: "com.pickshot.semantic.index", qos: .utility)
    private var indexWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: - Indexing

    /// 폴더의 모든 이미지에 대해 임베딩 생성 (누락된 것만).
    /// - Parameters:
    ///   - folderURL: 폴더 URL (DB isolation 용)
    ///   - urls: 이미지 파일 URL 배열
    ///   - onProgress: (done, total) 콜백 (main thread 안전 보장)
    func startIndexing(folderURL: URL, urls: [URL], onProgress: ((Int, Int) -> Void)? = nil) {
        // 이전 작업 취소
        indexWorkItem?.cancel()
        indexWorkItem = nil

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.runIndexing(folderURL: folderURL, urls: urls, onProgress: onProgress)
        }
        indexWorkItem = work
        indexQueue.async(execute: work)
    }

    /// 인덱싱 중단.
    func stopIndexing() {
        indexWorkItem?.cancel()
        indexWorkItem = nil
        isIndexing = false
    }

    private func runIndexing(folderURL: URL, urls: [URL], onProgress: ((Int, Int) -> Void)?) {
        guard ImageEmbeddingService.shared.isAvailable else {
            fputs("[SEMANTIC] MobileCLIP 모델 없음 — 인덱싱 스킵\n", stderr)
            return
        }

        EmbeddingIndex.shared.open(for: folderURL)
        isIndexing = true
        indexTotal = urls.count
        indexDone = 0
        indexProgress = 0

        // Stale 정리 (삭제된 파일 임베딩 제거)
        let existingPaths = Set(urls.map { $0.path })
        _ = EmbeddingIndex.shared.removeStale(existingPaths: existingPaths)

        let fm = FileManager.default
        let startTime = CFAbsoluteTimeGetCurrent()
        var newCount = 0
        var skipCount = 0

        for (idx, url) in urls.enumerated() {
            if let work = indexWorkItem, work.isCancelled { break }

            // mtime 조회 — 변경 없으면 스킵
            let mtime: TimeInterval = {
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let date = attrs[.modificationDate] as? Date else { return 0 }
                return date.timeIntervalSince1970
            }()

            // v8.9 fix: 저장된 DB mtime 과 파일 mtime 비교 (이전 버전은 둘 다 파일 mtime 이라 항상 skip).
            if let storedMtime = EmbeddingIndex.shared.getStoredMtime(url: url),
               abs(storedMtime - mtime) < 1.0 {
                skipCount += 1
            } else {
                autoreleasepool {
                    if let emb = ImageEmbeddingService.shared.embed(url: url) {
                        _ = EmbeddingIndex.shared.upsert(url: url, mtime: mtime, embedding: emb)
                        newCount += 1
                    }
                }
            }

            indexDone = idx + 1
            indexProgress = Double(indexDone) / Double(max(1, indexTotal))

            if let onProgress = onProgress {
                let d = indexDone, t = indexTotal
                DispatchQueue.main.async { onProgress(d, t) }
            }

            if indexDone % 50 == 0 {
                fputs("[SEMANTIC] indexing \(indexDone)/\(indexTotal) (new=\(newCount), skip=\(skipCount))\n", stderr)
            }
        }

        isIndexing = false
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        fputs("[SEMANTIC] ✅ done \(indexDone)/\(indexTotal) — new=\(newCount), skip=\(skipCount) in \(String(format: "%.1f", elapsed))s\n", stderr)
    }

    // MARK: - Search

    /// 이미지 → 유사 이미지 검색 (쿼리 URL 과 가장 비슷한 top-K).
    /// - Returns: (url, score) 배열. score 는 코사인 유사도 (-1 ~ 1).
    func searchSimilar(to queryURL: URL, k: Int = 50) -> [(url: URL, score: Float)] {
        // 1) 쿼리 임베딩 획득 (캐시 히트면 재사용)
        let queryEmbedding: [Float]
        if let cached = EmbeddingIndex.shared.get(url: queryURL) {
            queryEmbedding = cached
        } else if let fresh = ImageEmbeddingService.shared.embed(url: queryURL) {
            queryEmbedding = fresh
            // 부가로 DB 에도 저장
            if let attrs = try? FileManager.default.attributesOfItem(atPath: queryURL.path),
               let date = attrs[.modificationDate] as? Date {
                _ = EmbeddingIndex.shared.upsert(url: queryURL, mtime: date.timeIntervalSince1970, embedding: fresh)
            }
        } else {
            fputs("[SEMANTIC] 쿼리 임베딩 실패: \(queryURL.lastPathComponent)\n", stderr)
            return []
        }

        return EmbeddingIndex.shared.topK(queryEmbedding: queryEmbedding, k: k, excludePath: queryURL.path)
    }

    /// CVPixelBuffer (예: 크롭한 영역) → 유사 이미지 검색.
    /// 사용처: 드래그 박스로 의상 영역 선택 → 비슷한 옷 찾기
    func searchSimilar(to pixelBuffer: CVPixelBuffer, k: Int = 50) -> [(url: URL, score: Float)] {
        guard let emb = ImageEmbeddingService.shared.embed(pixelBuffer: pixelBuffer) else {
            return []
        }
        return EmbeddingIndex.shared.topK(queryEmbedding: emb, k: k)
    }

    // MARK: - Helpers

    private func getMtime(url: URL) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970
    }
}
