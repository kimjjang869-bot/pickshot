import Foundation
import AppKit
import Vision
import ImageIO
import Accelerate

struct FaceGroupResult {
    var assignments: [UUID: Int] = [:]   // photoID -> groupID
    var groups: [Int: [UUID]] = [:]       // groupID -> [photoIDs]
    var faceCountPerPhoto: [UUID: Int] = [:]  // photoID -> face count
    var faceThumbnails: [Int: NSImage] = [:]  // groupID -> representative face crop
}

/// Extracts a face thumbnail from a photo for display in the group filter
func extractFaceThumbnail(url: URL, maxSize: CGFloat = 80) -> NSImage? {
    let sourceOptions: [NSString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
    let thumbOptions: [NSString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: 640,
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCache: false
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }

    let faceRequest = VNDetectFaceRectanglesRequest()
    if #available(macOS 13.0, *) {
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
    }
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([faceRequest])
    } catch { return nil }

    guard let face = faceRequest.results?.filter({ $0.confidence > 0.7 }).max(by: {
        $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
    }) else { return nil }

    let imgW = CGFloat(cgImage.width)
    let imgH = CGFloat(cgImage.height)
    let box = face.boundingBox
    let faceRect = CGRect(
        x: box.origin.x * imgW,
        y: (1 - box.origin.y - box.height) * imgH,
        width: box.width * imgW,
        height: box.height * imgH
    ).integral.insetBy(dx: -box.width * imgW * 0.2, dy: -box.height * imgH * 0.2)
        .intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

    guard faceRect.width > 10, faceRect.height > 10,
          let cropped = cgImage.cropping(to: faceRect) else { return nil }

    return NSImage(cgImage: cropped, size: NSSize(width: maxSize, height: maxSize))
}

struct FaceGroupingService {

    // MARK: - AdaFace 기반 얼굴 그룹핑 (우선) + VNFeaturePrint fallback

    /// Group photos by detected faces.
    /// AdaFace R18 사용 가능 시 → 512차원 임베딩 (정확도 99.82%)
    /// 없으면 → VNFeaturePrint fallback
    static func groupFaces(
        photos: [PhotoItem],
        progress: @escaping (Int) -> Void
    ) -> FaceGroupResult {

        let useAdaFace = AdaFaceService.isAvailable
        fputs("[FACE] 엔진: \(useAdaFace ? "AdaFace R18 (512-dim)" : "VNFeaturePrint (fallback)")\n", stderr)

        if useAdaFace {
            return groupFacesAdaFace(photos: photos, progress: progress)
        } else {
            return groupFacesVNFeaturePrint(photos: photos, progress: progress)
        }
    }

    // MARK: - AdaFace 기반 그룹핑

    private static func groupFacesAdaFace(
        photos: [PhotoItem],
        progress: @escaping (Int) -> Void
    ) -> FaceGroupResult {

        struct FaceEntry {
            let photoID: UUID
            let embedding: [Float]    // 512-dim AdaFace embedding
            let faceSize: CGFloat
            let faceIndex: Int
            let faceCrop: CGImage     // 얼굴 썸네일용
        }

        var allFaces: [FaceEntry] = []
        var faceCountMap: [UUID: Int] = [:]
        let lock = NSLock()
        let total = photos.count

        // Step 1: 얼굴 감지 + AdaFace 임베딩 추출
        // AdaFace 모델은 직렬 추론 (CoreML thread-safe 보장 안 됨)
        // → 얼굴 감지는 병렬, 임베딩 추출은 직렬
        struct DetectedFace {
            let photoID: UUID
            let crop: CGImage
            let faceSize: CGFloat
            let faceIndex: Int
        }

        var detectedFaces: [DetectedFace] = []

        DispatchQueue.concurrentPerform(iterations: total) { idx in
            autoreleasepool {
                let photo = photos[idx]
                let faces = detectFaces(url: photo.jpgURL)

                lock.lock()
                faceCountMap[photo.id] = faces.count
                for (i, face) in faces.enumerated() {
                    detectedFaces.append(DetectedFace(
                        photoID: photo.id,
                        crop: face.crop,
                        faceSize: face.relativeSize,
                        faceIndex: i
                    ))
                }
                let done = faceCountMap.count
                lock.unlock()

                if done % 20 == 0 || done == total {
                    progress(done)
                }
            }
        }

        guard !detectedFaces.isEmpty else {
            return FaceGroupResult(faceCountPerPhoto: faceCountMap)
        }

        fputs("[FACE] 감지된 얼굴: \(detectedFaces.count)개 (\(faceCountMap.count)장 사진)\n", stderr)

        // Step 2: AdaFace 임베딩 추출 (직렬)
        for face in detectedFaces {
            autoreleasepool {
                if let emb = AdaFaceService.embedding(from: face.crop) {
                    lock.lock()
                    allFaces.append(FaceEntry(
                        photoID: face.photoID,
                        embedding: emb,
                        faceSize: face.faceSize,
                        faceIndex: face.faceIndex,
                        faceCrop: face.crop
                    ))
                    lock.unlock()
                }
            }
        }

        fputs("[FACE] AdaFace 임베딩 추출: \(allFaces.count)/\(detectedFaces.count)개 성공\n", stderr)

        guard !allFaces.isEmpty else {
            fputs("[FACE] 임베딩 추출 실패 - 모든 얼굴에서 임베딩을 추출하지 못함\n", stderr)
            return FaceGroupResult(faceCountPerPhoto: faceCountMap)
        }

        // 디버그: 처음 5쌍의 유사도 출력
        if allFaces.count >= 2 {
            let debugCount = min(allFaces.count, 5)
            for i in 0..<debugCount {
                for j in (i+1)..<debugCount {
                    let sim = AdaFaceService.cosineSimilarity(allFaces[i].embedding, allFaces[j].embedding)
                    fputs("[FACE] 유사도 디버그: face[\(i)] vs face[\(j)] = \(String(format: "%.4f", sim)) (photo: \(allFaces[i].photoID == allFaces[j].photoID ? "같은사진" : "다른사진"))\n", stderr)
                }
            }
        }

        // Step 3: Union-Find 클러스터링 (코사인 유사도)
        var result = FaceGroupResult()
        result.faceCountPerPhoto = faceCountMap

        var parent = Array(0..<allFaces.count)
        var rank = Array(repeating: 0, count: allFaces.count)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra == rb { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }

        let n = allFaces.count

        // Step 3-1: 모든 쌍의 유사도 매트릭스 (N×N은 메모리 문제 → 매칭 쌍만 저장)
        struct SimPair { let i: Int; let j: Int; let sim: Float }
        let pairLock = NSLock()
        var allSimPairs: [SimPair] = []
        let facesSnapshot = allFaces

        // 1차 threshold: 0.50 (적당히 엄격)
        let strictThreshold: Float = 0.50

        DispatchQueue.concurrentPerform(iterations: n) { i in
            var localPairs: [SimPair] = []
            for j in (i + 1)..<n {
                if facesSnapshot[i].photoID == facesSnapshot[j].photoID { continue }

                let sim = AdaFaceService.cosineSimilarity(
                    facesSnapshot[i].embedding,
                    facesSnapshot[j].embedding
                )

                if sim > strictThreshold {
                    localPairs.append(SimPair(i: i, j: j, sim: sim))
                }
            }
            if !localPairs.isEmpty {
                pairLock.lock()
                allSimPairs.append(contentsOf: localPairs)
                pairLock.unlock()
            }
        }

        fputs("[FACE] 1차 매칭 쌍 (threshold \(strictThreshold)): \(allSimPairs.count)개\n", stderr)

        // Step 3-2: Union-Find 클러스터링
        for pair in allSimPairs {
            union(pair.i, pair.j)
        }

        var clusterMap: [Int: [Int]] = [:]
        for i in 0..<allFaces.count {
            let root = find(i)
            clusterMap[root, default: []].append(i)
        }

        // Step 3-3: 그룹 검증 — 각 멤버가 그룹 중심(centroid)과 충분히 유사한지 확인
        // Union-Find 단일 연결 문제 방지: 체인 연결된 이상치 제거
        let verifyThreshold: Float = 0.45
        var verifiedClusters: [[Int]] = []

        for (_, members) in clusterMap {
            guard members.count >= 2 else { continue }

            // 그룹 centroid 계산
            var centroid = [Float](repeating: 0, count: 512)
            for idx in members {
                let emb = allFaces[idx].embedding
                for d in 0..<512 { centroid[d] += emb[d] }
            }
            let count = Float(members.count)
            for d in 0..<512 { centroid[d] /= count }
            // L2 정규화
            var norm: Float = 0
            vDSP_svesq(centroid, 1, &norm, vDSP_Length(512))
            norm = sqrt(norm)
            if norm > 0 {
                var inv = 1.0 / norm
                vDSP_vsmul(centroid, 1, &inv, &centroid, 1, vDSP_Length(512))
            }

            // centroid와의 유사도로 멤버 검증
            var verified: [Int] = []
            for idx in members {
                let sim = AdaFaceService.cosineSimilarity(allFaces[idx].embedding, centroid)
                if sim >= verifyThreshold {
                    verified.append(idx)
                }
            }

            if verified.count >= 2 {
                verifiedClusters.append(verified)
            }
        }

        fputs("[FACE] 검증 후 초기 그룹: \(verifiedClusters.count)개\n", stderr)

        // Step 3-4: 그룹 병합 — centroid 유사도가 높은 그룹끼리 합치기
        // 같은 사람이 각도/조명 차이로 분리된 경우를 해결
        let mergeThreshold: Float = 0.45

        func computeCentroid(_ members: [Int]) -> [Float] {
            var c = [Float](repeating: 0, count: 512)
            for idx in members {
                let emb = allFaces[idx].embedding
                for d in 0..<512 { c[d] += emb[d] }
            }
            let cnt = Float(members.count)
            for d in 0..<512 { c[d] /= cnt }
            var nm: Float = 0
            vDSP_svesq(c, 1, &nm, vDSP_Length(512))
            nm = sqrt(nm)
            if nm > 0 {
                var inv = 1.0 / nm
                vDSP_vsmul(c, 1, &inv, &c, 1, vDSP_Length(512))
            }
            return c
        }

        // 반복적으로 가장 유사한 그룹 쌍을 병합 (Agglomerative)
        var mergedClusters = verifiedClusters
        var centroids = mergedClusters.map { computeCentroid($0) }
        var mergeCount = 0

        while mergedClusters.count >= 2 {
            // 가장 유사한 그룹 쌍 찾기
            var bestSim: Float = -1
            var bestI = -1, bestJ = -1

            for i in 0..<mergedClusters.count {
                for j in (i+1)..<mergedClusters.count {
                    let sim = AdaFaceService.cosineSimilarity(centroids[i], centroids[j])
                    if sim > bestSim {
                        bestSim = sim
                        bestI = i
                        bestJ = j
                    }
                }
            }

            guard bestSim >= mergeThreshold else { break }

            // 병합 전 추가 검증: 두 그룹 멤버 간 평균 유사도 확인
            let membersI = mergedClusters[bestI]
            let membersJ = mergedClusters[bestJ]
            var crossSimSum: Float = 0
            var crossCount = 0
            let sampleI = membersI.count > 10 ? Array(membersI.prefix(10)) : membersI
            let sampleJ = membersJ.count > 10 ? Array(membersJ.prefix(10)) : membersJ
            for mi in sampleI {
                for mj in sampleJ {
                    crossSimSum += AdaFaceService.cosineSimilarity(allFaces[mi].embedding, allFaces[mj].embedding)
                    crossCount += 1
                }
            }
            let avgCrossSim = crossCount > 0 ? crossSimSum / Float(crossCount) : 0

            // 평균 교차 유사도도 기준 이상이어야 병합
            guard avgCrossSim >= 0.40 else {
                // 이 쌍은 병합 불가 — 더 이상 병합 없음
                break
            }

            fputs("[FACE] 그룹 병합: \(bestI)(\(membersI.count)개) + \(bestJ)(\(membersJ.count)개), centroid유사도=\(String(format: "%.3f", bestSim)), 교차평균=\(String(format: "%.3f", avgCrossSim))\n", stderr)

            // 병합 실행
            mergedClusters[bestI] = membersI + membersJ
            centroids[bestI] = computeCentroid(mergedClusters[bestI])
            mergedClusters.remove(at: bestJ)
            centroids.remove(at: bestJ)
            mergeCount += 1
        }

        // 큰 그룹 순으로 정렬
        mergedClusters.sort { $0.count > $1.count }

        fputs("[FACE] 병합 \(mergeCount)회 → 최종 \(mergedClusters.count)개 그룹\n", stderr)
        for (i, cluster) in mergedClusters.prefix(10).enumerated() {
            let photoCount = Set(cluster.map { allFaces[$0].photoID }).count
            fputs("[FACE]   그룹 \(i): 얼굴 \(cluster.count)개, 사진 \(photoCount)장\n", stderr)
        }

        // Step 5: 결과 구성
        var groupID = 0
        for members in mergedClusters {
            let photoIDs = Set(members.map { allFaces[$0].photoID })
            if photoIDs.count >= 2 {
                for photoID in photoIDs {
                    result.assignments[photoID] = groupID
                }
                result.groups[groupID] = Array(photoIDs)

                // 가장 큰 얼굴을 대표 썸네일로
                if let bestIdx = members.max(by: { allFaces[$0].faceSize < allFaces[$1].faceSize }) {
                    let crop = allFaces[bestIdx].faceCrop
                    result.faceThumbnails[groupID] = NSImage(
                        cgImage: crop,
                        size: NSSize(width: 80, height: 80)
                    )
                }

                groupID += 1
            }
        }

        fputs("[FACE] 최종 그룹: \(groupID)개 (2장 이상)\n", stderr)
        return result
    }

    // MARK: - 얼굴 감지 (공통)

    /// 사진에서 얼굴 감지 + 크롭 (AdaFace/VNFeaturePrint 공통)
    private static func detectFaces(url: URL) -> [(crop: CGImage, relativeSize: CGFloat)] {
        let sourceOptions: [NSString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return [] }
        let thumbOptions: [NSString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 1280,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return [] }

        let faceRequest = VNDetectFaceRectanglesRequest()
        if #available(macOS 13.0, *) {
            faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([faceRequest])
        } catch { return [] }

        guard let faces = faceRequest.results?.filter({ $0.confidence > 0.7 }), !faces.isEmpty else { return [] }

        let sortedFaces = faces.sorted {
            ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height)
        }.prefix(3)

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        var results: [(crop: CGImage, relativeSize: CGFloat)] = []

        for face in sortedFaces {
            let box = face.boundingBox
            let relativeSize = box.width * box.height
            guard relativeSize > 0.02, relativeSize < 0.8 else { continue }

            let faceRect = CGRect(
                x: box.origin.x * imgW,
                y: (1 - box.origin.y - box.height) * imgH,
                width: box.width * imgW,
                height: box.height * imgH
            ).integral

            let expanded = faceRect.insetBy(dx: -faceRect.width * 0.15, dy: -faceRect.height * 0.15)
            let clipped = expanded.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

            guard clipped.width > 15, clipped.height > 15,
                  let faceCrop = cgImage.cropping(to: clipped) else { continue }

            results.append((crop: faceCrop, relativeSize: relativeSize))
        }

        return results
    }

    // MARK: - VNFeaturePrint Fallback (기존 방식)

    private static func groupFacesVNFeaturePrint(
        photos: [PhotoItem],
        progress: @escaping (Int) -> Void
    ) -> FaceGroupResult {

        struct FaceEntry {
            let photoID: UUID
            let featurePrint: VNFeaturePrintObservation
            let faceSize: CGFloat
            let faceIndex: Int
        }

        var allFaces: [FaceEntry] = []
        var faceCountMap: [UUID: Int] = [:]
        let lock = NSLock()
        let total = photos.count

        DispatchQueue.concurrentPerform(iterations: total) { idx in
            autoreleasepool {
                let photo = photos[idx]
                let faces = extractAllFaceFeaturePrints(url: photo.jpgURL)

                lock.lock()
                faceCountMap[photo.id] = faces.count
                for (i, face) in faces.enumerated() {
                    allFaces.append(FaceEntry(
                        photoID: photo.id,
                        featurePrint: face.featurePrint,
                        faceSize: face.relativeSize,
                        faceIndex: i
                    ))
                }
                let done = faceCountMap.count
                lock.unlock()

                if done % 20 == 0 || done == total {
                    progress(done)
                }
            }
        }

        guard !allFaces.isEmpty else { return FaceGroupResult(faceCountPerPhoto: faceCountMap) }

        var result = FaceGroupResult()
        result.faceCountPerPhoto = faceCountMap

        var parent = Array(0..<allFaces.count)
        var rank = Array(repeating: 0, count: allFaces.count)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra == rb { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }

        let n = allFaces.count
        let maxCompare = min(n, 5000)

        struct PairResult { let i: Int; let j: Int }
        let pairLock = NSLock()
        var matchedPairs: [PairResult] = []
        let facesSnapshot = allFaces

        DispatchQueue.concurrentPerform(iterations: min(n, maxCompare)) { i in
            var localPairs: [PairResult] = []
            for j in (i + 1)..<min(n, maxCompare) {
                if facesSnapshot[i].photoID == facesSnapshot[j].photoID { continue }

                var distance: Float = 0
                do {
                    try facesSnapshot[i].featurePrint.computeDistance(&distance, to: facesSnapshot[j].featurePrint)
                } catch { continue }

                let avgSize = Float((facesSnapshot[i].faceSize + facesSnapshot[j].faceSize) / 2)
                let threshold: Float = avgSize > 0.15 ? 0.62 : (avgSize > 0.08 ? 0.58 : 0.52)

                if distance < threshold {
                    localPairs.append(PairResult(i: i, j: j))
                }
            }
            if !localPairs.isEmpty {
                pairLock.lock()
                matchedPairs.append(contentsOf: localPairs)
                pairLock.unlock()
            }
        }

        for pair in matchedPairs {
            union(pair.i, pair.j)
        }

        var clusterMap: [Int: [Int]] = [:]
        for i in 0..<allFaces.count {
            let root = find(i)
            clusterMap[root, default: []].append(i)
        }

        var groupID = 0
        for (_, members) in clusterMap.sorted(by: { $0.value.count > $1.value.count }) {
            let photoIDs = Set(members.map { allFaces[$0].photoID })
            if photoIDs.count >= 2 {
                for photoID in photoIDs {
                    result.assignments[photoID] = groupID
                }
                result.groups[groupID] = Array(photoIDs)
                groupID += 1
            }
        }

        return result
    }

    /// Extract ALL faces from a photo with VNFeaturePrint (fallback)
    private static func extractAllFaceFeaturePrints(url: URL) -> [(featurePrint: VNFeaturePrintObservation, relativeSize: CGFloat)] {
        let sourceOptions: [NSString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return [] }
        let thumbOptions: [NSString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return [] }

        let faceRequest = VNDetectFaceRectanglesRequest()
        if #available(macOS 13.0, *) {
            faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([faceRequest])
        } catch { return [] }

        guard let faces = faceRequest.results?.filter({ $0.confidence > 0.7 }), !faces.isEmpty else { return [] }

        let sortedFaces = faces.sorted {
            ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height)
        }.prefix(3)

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        var results: [(featurePrint: VNFeaturePrintObservation, relativeSize: CGFloat)] = []

        for face in sortedFaces {
            let box = face.boundingBox
            let relativeSize = box.width * box.height
            guard relativeSize > 0.02, relativeSize < 0.8 else { continue }

            let faceRect = CGRect(
                x: box.origin.x * imgW,
                y: (1 - box.origin.y - box.height) * imgH,
                width: box.width * imgW,
                height: box.height * imgH
            ).integral

            let expanded = faceRect.insetBy(dx: -faceRect.width * 0.15, dy: -faceRect.height * 0.15)
            let clipped = expanded.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

            guard clipped.width > 15, clipped.height > 15,
                  let faceCrop = cgImage.cropping(to: clipped) else { continue }

            let fpRequest = VNGenerateImageFeaturePrintRequest()
            let fpHandler = VNImageRequestHandler(cgImage: faceCrop, options: [:])
            do {
                try fpHandler.perform([fpRequest])
                if let fp = fpRequest.results?.first {
                    results.append((featurePrint: fp, relativeSize: relativeSize))
                }
            } catch { continue }
        }

        return results
    }
}
