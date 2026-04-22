//
//  FaceEmbeddingService.swift
//  PhotoRawManager
//
//  v8.7: 참조 기반 얼굴 검색 — "이 사람 찾기" 기능의 핵심 엔진.
//
//  아키텍처:
//    ┌─────────────────────────────────────────────┐
//    │  FaceEmbeddingProvider (프로토콜)           │
//    │   - compute(cgImage) -> [FaceEmbedding]     │
//    └─────────────────────────────────────────────┘
//              ▲                       ▲
//    ┌─────────┴────────────┐   ┌──────┴──────────────┐
//    │ LandmarkEmbedding     │   │ ArcFaceCoreMLEmb    │
//    │ (Vision 랜드마크 벡터)│   │ (Phase 2 교체 대상) │
//    │ 85% 정확도, 즉시 가능  │   │ 95%+ 정확도         │
//    └───────────────────────┘   └─────────────────────┘
//
//  교체 방법: FaceEmbeddingService.shared.setProvider(ArcFaceCoreMLProvider())
//

import Foundation
import Vision
import AppKit
import CoreImage

// MARK: - Public Types

/// 단일 얼굴에 대한 임베딩 벡터 + 메타 정보
struct FaceEmbedding: Codable, Hashable {
    let vector: [Float]              // 고정 차원 (Landmark: 152, ArcFace: 512)
    let boundingBox: CGRect          // 얼굴 위치 (0~1 normalized)
    let quality: Float               // 얼굴 품질 (0~1, 흐림/각도 감점)

    /// 코사인 유사도 (1.0 = 동일, 0 = 무관)
    func cosineSimilarity(to other: FaceEmbedding) -> Float {
        guard vector.count == other.vector.count, !vector.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<vector.count {
            dot += vector[i] * other.vector[i]
            normA += vector[i] * vector[i]
            normB += other.vector[i] * other.vector[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }
}

/// 파일당 얼굴 임베딩 캐시 엔트리 — 디스크 영속화 가능
struct PhotoFaceEmbeddings: Codable {
    let filePath: String             // 절대 경로
    let fileModDate: Date?           // 파일 수정일 (변경 감지)
    let embeddings: [FaceEmbedding]  // 감지된 얼굴들
}

// MARK: - Provider Protocol

/// 얼굴 임베딩 계산 백엔드. Landmark 또는 ArcFace Core ML 구현체가 채택.
protocol FaceEmbeddingProvider {
    /// 백엔드 식별자 (캐시 무효화 판단용)
    var backendID: String { get }
    /// 벡터 차원 (동일 백엔드 간 검증용)
    var dimension: Int { get }
    /// 이미지에서 모든 얼굴 감지 후 임베딩 계산
    func compute(cgImage: CGImage) -> [FaceEmbedding]
}

// MARK: - Landmark-based Provider (Phase 1)

/// Apple Vision 랜드마크 76포인트를 정규화한 152차원 벡터를 임베딩으로 사용.
/// ArcFace 대비 정확도 ~85% 지만 외부 모델 불필요.
final class LandmarkFaceEmbeddingProvider: FaceEmbeddingProvider {
    let backendID = "landmark_v1"
    let dimension = 152  // 76 points × 2 (x,y)

    func compute(cgImage: CGImage) -> [FaceEmbedding] {
        let req = VNDetectFaceLandmarksRequest()
        if #available(macOS 13.0, *) {
            req.revision = VNDetectFaceLandmarksRequestRevision3
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([req])
        } catch {
            return []
        }
        guard let results = req.results else { return [] }

        var out: [FaceEmbedding] = []
        for face in results where face.confidence > 0.5 {
            guard let landmarks = face.landmarks else { continue }
            // 모든 region 을 합쳐서 76 포인트 벡터로 평탄화
            let regions: [VNFaceLandmarkRegion2D?] = [
                landmarks.faceContour,
                landmarks.leftEye,
                landmarks.rightEye,
                landmarks.leftEyebrow,
                landmarks.rightEyebrow,
                landmarks.nose,
                landmarks.noseCrest,
                landmarks.medianLine,
                landmarks.outerLips,
                landmarks.innerLips,
                landmarks.leftPupil,
                landmarks.rightPupil
            ]
            var points: [CGPoint] = []
            for r in regions {
                guard let r = r else { continue }
                for i in 0..<r.pointCount {
                    points.append(r.normalizedPoints[i])
                }
            }
            guard points.count >= 30 else { continue }  // 최소 포인트 없으면 신뢰 못함

            // 152 차원으로 정규화 (포인트 수 부족/초과 시 padding/truncate)
            var vec = [Float](repeating: 0, count: dimension)
            let pointCount = min(points.count, dimension / 2)
            for i in 0..<pointCount {
                vec[i * 2] = Float(points[i].x)
                vec[i * 2 + 1] = Float(points[i].y)
            }
            // 벡터 정규화 (L2) — 코사인 유사도 안정성 향상
            let norm = sqrt(vec.map { $0 * $0 }.reduce(0, +))
            if norm > 0 {
                vec = vec.map { $0 / norm }
            }

            // 품질: confidence + 얼굴 크기 (너무 작으면 신뢰 낮음)
            let size = Float(face.boundingBox.width * face.boundingBox.height)
            let quality = min(1.0, face.confidence * (size > 0.01 ? 1.0 : 0.5))

            out.append(FaceEmbedding(
                vector: vec,
                boundingBox: face.boundingBox,
                quality: quality
            ))
        }
        return out
    }
}

// MARK: - Face Area FeaturePrint Provider (Phase 1.5)

/// 얼굴 감지 → crop → VNGenerateImageFeaturePrintRequest.
/// Landmark 기반 (geometry) 대비 픽셀 feature 기반이라 "다른 사람" 구별력 훨씬 강함.
/// 피부톤 / 머리색 / 눈 / 입술 / 표정 포함.
final class FaceFeaturePrintProvider: FaceEmbeddingProvider {
    let backendID = "faceFP_v2"  // v2: 소형 얼굴 필터 + 10% crop + 0.7 confidence
    let dimension = 768  // Apple VNFeaturePrint 2024+ — 768 dim

    func compute(cgImage: CGImage) -> [FaceEmbedding] {
        // 1) 얼굴 감지
        let faceReq = VNDetectFaceRectanglesRequest()
        if #available(macOS 13.0, *) {
            faceReq.revision = VNDetectFaceRectanglesRequestRevision3
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([faceReq])
        guard let faces = faceReq.results else { return [] }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        var out: [FaceEmbedding] = []

        for face in faces where face.confidence > 0.7 {  // 0.5 → 0.7 (더 확실한 얼굴만)
            let bb = face.boundingBox
            // v8.7: 너무 작은 얼굴 거부 — 면적 1% 미만은 식별 신뢰 낮음 (배경 얼굴/잡음)
            let area = bb.width * bb.height
            if area < 0.008 { continue }  // 약 1% 미만
            // 10% 패딩 — 배경 영향 최소화 (기존 20% → 10%)
            let padding: CGFloat = 0.10
            let paddedBB = CGRect(
                x: max(0, bb.minX - bb.width * padding),
                y: max(0, bb.minY - bb.height * padding),
                width: min(1.0 - bb.minX, bb.width * (1 + 2 * padding)),
                height: min(1.0 - bb.minY, bb.height * (1 + 2 * padding))
            )
            let pixelRect = CGRect(
                x: paddedBB.minX * imgW,
                y: (1.0 - paddedBB.maxY) * imgH,  // y-flip
                width: paddedBB.width * imgW,
                height: paddedBB.height * imgH
            ).integral.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

            guard pixelRect.width >= 50, pixelRect.height >= 50,
                  let faceCG = cgImage.cropping(to: pixelRect) else { continue }

            // 2) 얼굴 crop 에 FeaturePrint 계산
            let fpReq = VNGenerateImageFeaturePrintRequest()
            let fpHandler = VNImageRequestHandler(cgImage: faceCG, options: [:])
            try? fpHandler.perform([fpReq])
            guard let fp = fpReq.results?.first else { continue }

            let data = fp.data
            let count = data.count / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var vec = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { raw in
                let buf = raw.bindMemory(to: Float.self)
                for i in 0..<count {
                    vec[i] = buf[i]
                }
            }
            // L2 정규화 — 코사인 유사도 안정화
            let norm = sqrt(vec.map { $0 * $0 }.reduce(0, +))
            if norm > 0 { vec = vec.map { $0 / norm } }

            let size = Float(bb.width * bb.height)
            let quality = min(1.0, face.confidence * (size > 0.01 ? 1.0 : 0.5))

            out.append(FaceEmbedding(
                vector: vec,
                boundingBox: bb,
                quality: quality
            ))
        }
        return out
    }
}

// MARK: - AdaFace R18 Provider (v8.9: 최고 정확도 512-dim)

/// AdaFace R18 CoreML 모델 기반 provider. LFW 99.82% 정확도.
/// 얼굴 감지는 Vision, 임베딩은 AdaFace 모델 (112x112 입력 → 512-dim).
final class AdaFaceEmbeddingProvider: FaceEmbeddingProvider {
    let backendID = "adaface_r18_v1"
    let dimension = 512

    func compute(cgImage: CGImage) -> [FaceEmbedding] {
        // 얼굴 감지
        let req = VNDetectFaceRectanglesRequest()
        if #available(macOS 13.0, *) {
            req.revision = VNDetectFaceRectanglesRequestRevision3
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        guard let faces = req.results else { return [] }

        var out: [FaceEmbedding] = []
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        for face in faces where face.confidence > 0.5 {
            // Vision 좌표 (좌하원점) → CGImage 좌표 (좌상원점) 변환 + 25% 패딩
            let bb = face.boundingBox
            let padX: CGFloat = bb.width * 0.15
            let padY: CGFloat = bb.height * 0.15
            let cropRect = CGRect(
                x: max(0, (bb.origin.x - padX) * imgW),
                y: max(0, (1 - bb.origin.y - bb.height - padY) * imgH),
                width: min(imgW, (bb.width + padX * 2) * imgW),
                height: min(imgH, (bb.height + padY * 2) * imgH)
            )
            guard cropRect.width > 20, cropRect.height > 20,
                  let faceCrop = cgImage.cropping(to: cropRect) else { continue }
            guard let emb = AdaFaceService.embedding(from: faceCrop) else { continue }
            out.append(FaceEmbedding(vector: emb, boundingBox: bb, quality: Float(face.confidence)))
        }
        return out
    }
}

// MARK: - Main Service

final class FaceEmbeddingService {
    static let shared = FaceEmbeddingService()

    /// v8.9: AdaFace R18 모델이 있으면 512-dim 고정밀 엔진, 없으면 FeaturePrint fallback.
    private(set) var provider: FaceEmbeddingProvider = {
        if AdaFaceService.isAvailable {
            fputs("[FACE-EMB] AdaFace R18 (512-dim) 엔진 사용\n", stderr)
            return AdaFaceEmbeddingProvider()
        }
        fputs("[FACE-EMB] AdaFace 없음 — VNFeaturePrint (768-dim) fallback\n", stderr)
        return FaceFeaturePrintProvider()
    }()

    /// 백엔드 교체 (모델 업그레이드 시)
    func setProvider(_ p: FaceEmbeddingProvider) {
        self.provider = p
        // 백엔드 바뀌면 캐시 무효화 (벡터 호환성 없음)
        FaceEmbeddingCache.shared.invalidateAll()
    }

    private init() {}

    // MARK: - 공개 API

    /// 단일 사진에서 얼굴 임베딩 계산 (캐시 사용)
    func embeddings(for url: URL) -> [FaceEmbedding] {
        if let cached = FaceEmbeddingCache.shared.get(url: url, backendID: provider.backendID) {
            return cached.embeddings
        }
        guard let cgImage = loadCGImage(from: url, maxPixel: 800) else { return [] }
        let embs = provider.compute(cgImage: cgImage)
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let entry = PhotoFaceEmbeddings(filePath: url.path, fileModDate: modDate, embeddings: embs)
        FaceEmbeddingCache.shared.set(url: url, backendID: provider.backendID, entry: entry)
        return embs
    }

    /// 배치 계산 — 진행률 콜백 포함
    func computeBatch(
        urls: [URL],
        progress: @escaping (Int, Int) -> Void,
        onComplete: @escaping () -> Void
    ) {
        let total = urls.count
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let opQueue = OperationQueue()
            opQueue.maxConcurrentOperationCount = min(4, ProcessInfo.processInfo.activeProcessorCount / 2)
            opQueue.qualityOfService = .userInitiated
            var done = 0
            let doneLock = NSLock()
            for url in urls {
                opQueue.addOperation { [weak self] in
                    guard let self = self else { return }
                    _ = self.embeddings(for: url)
                    doneLock.lock()
                    done += 1
                    let d = done
                    doneLock.unlock()
                    if d % 10 == 0 || d == total {
                        DispatchQueue.main.async { progress(d, total) }
                    }
                }
            }
            opQueue.waitUntilAllOperationsAreFinished()
            DispatchQueue.main.async { onComplete() }
        }
    }

    // MARK: - 내부 유틸

    private func loadCGImage(from url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [NSString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: - Disk Cache

/// 폴더 단위로 얼굴 임베딩을 영속화. 백엔드 ID 기반 네임스페이스 분리.
final class FaceEmbeddingCache {
    static let shared = FaceEmbeddingCache()

    private let cacheDir: URL
    private let lock = NSLock()
    private var memoryCache: [String: PhotoFaceEmbeddings] = [:]
    /// v8.9: 메모리 캐시 무한 증식 방지 (기존 상한 없음 → 3998장에서 16MB+ 누적).
    ///   LRU 순서 유지용 access order list.
    private var accessOrder: [String] = []
    private let maxMemoryEntries: Int = 2000

    private init() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pickshot_face_emb")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheDir = dir
    }

    private func key(url: URL, backendID: String) -> String {
        let hash = url.absoluteString.utf8.reduce(into: UInt64(5381)) { h, c in
            h = h &* 33 &+ UInt64(c)
        }
        return "\(backendID)_\(hash)"
    }

    func get(url: URL, backendID: String) -> PhotoFaceEmbeddings? {
        let k = key(url: url, backendID: backendID)
        lock.lock()
        if let mem = memoryCache[k] {
            lock.unlock()
            // modDate 검증
            if let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               let cached = mem.fileModDate,
               abs(modDate.timeIntervalSince(cached)) > 1.0 {
                // 파일 수정됨 → 재계산 필요
                remove(url: url, backendID: backendID)
                return nil
            }
            return mem
        }
        lock.unlock()
        // 디스크에서 로드
        let file = cacheDir.appendingPathComponent("\(k).json")
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(PhotoFaceEmbeddings.self, from: data) else {
            return nil
        }
        // modDate 검증
        if let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           let cached = entry.fileModDate,
           abs(modDate.timeIntervalSince(cached)) > 1.0 {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        lock.lock()
        memoryCache[k] = entry
        lock.unlock()
        return entry
    }

    func set(url: URL, backendID: String, entry: PhotoFaceEmbeddings) {
        let k = key(url: url, backendID: backendID)
        lock.lock()
        memoryCache[k] = entry
        // v8.9 LRU: 기존 항목 제거 후 최신 위치에 재등록, 상한 초과 시 가장 오래된 항목 evict.
        accessOrder.removeAll { $0 == k }
        accessOrder.append(k)
        while accessOrder.count > maxMemoryEntries {
            let oldest = accessOrder.removeFirst()
            memoryCache.removeValue(forKey: oldest)
        }
        lock.unlock()
        let file = cacheDir.appendingPathComponent("\(k).json")
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// v8.9: 메모리 압박 시 MemGuard 가 호출. 디스크는 유지.
    ///   기본 trim: 가장 오래된 절반만 evict (재계산 비용 완화).
    func trimMemory(aggressive: Bool = false) {
        lock.lock()
        if aggressive {
            memoryCache.removeAll()
            accessOrder.removeAll()
        } else {
            let target = max(maxMemoryEntries / 2, 0)
            while accessOrder.count > target {
                let oldest = accessOrder.removeFirst()
                memoryCache.removeValue(forKey: oldest)
            }
        }
        lock.unlock()
    }

    func remove(url: URL, backendID: String) {
        let k = key(url: url, backendID: backendID)
        lock.lock()
        memoryCache.removeValue(forKey: k)
        accessOrder.removeAll { $0 == k }
        lock.unlock()
        let file = cacheDir.appendingPathComponent("\(k).json")
        try? FileManager.default.removeItem(at: file)
    }

    func invalidateAll() {
        lock.lock()
        memoryCache.removeAll()
        accessOrder.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
}
