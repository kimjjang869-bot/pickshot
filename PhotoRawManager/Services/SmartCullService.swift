import Foundation
import AppKit
import Vision

// MARK: - AI 스마트 셀렉 서비스
// 100% 로컬 (Apple Vision + NPU), 무료, 오프라인

class SmartCullService: ObservableObject {
    static let shared = SmartCullService()

    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var groups: [PhotoGroup] = []

    var cancelled = false
    @Published var genre: CullGenre = .general

    // MARK: - 장르별 셀렉 설정
    enum CullGenre: String, CaseIterable, Identifiable {
        case general = "일반"
        case wedding = "웨딩"
        case sports = "스포츠"
        case event = "행사/컨퍼런스"
        case portrait = "인물"
        case landscape = "풍경"

        var id: String { rawValue }

        /// 유사도 임계값 (낮을수록 엄격)
        var similarityThreshold: Float {
            switch self {
            case .general: return 18.0
            case .wedding: return 22.0     // 비슷한 포즈 많으므로 넓게
            case .sports: return 12.0      // 순간 차이 중요 → 엄격
            case .event: return 20.0
            case .portrait: return 15.0    // 표정 차이 중요
            case .landscape: return 25.0   // 구도 유사 많음
            }
        }

        /// 품질 점수 가중치 (선명도 vs 구도)
        var sharpnessWeight: Double {
            switch self {
            case .general: return 1.0
            case .wedding: return 0.8      // 표정 > 선명도
            case .sports: return 1.5       // 선명도 최우선
            case .event: return 0.9
            case .portrait: return 0.7     // 구도/표정 중심
            case .landscape: return 1.2    // 선명도 중요
            }
        }

        /// A컷 선택 비율 (상위 N%)
        var keepRatio: Double {
            switch self {
            case .general: return 0.3      // 30%
            case .wedding: return 0.25     // 25% (많이 촬영)
            case .sports: return 0.15      // 15% (연사 많음)
            case .event: return 0.35       // 35%
            case .portrait: return 0.4     // 40%
            case .landscape: return 0.5    // 50%
            }
        }

        var icon: String {
            switch self {
            case .general: return "camera"
            case .wedding: return "heart"
            case .sports: return "figure.run"
            case .event: return "person.3"
            case .portrait: return "person"
            case .landscape: return "mountain.2"
            }
        }
    }

    // MARK: - 데이터 모델

    struct PhotoGroup: Identifiable {
        let id = UUID()
        var name: String                    // "착장 1", "착장 2" 등
        var clusters: [PhotoCluster]        // 유사 사진 클러스터들
        var timeRange: (start: Date, end: Date)?
    }

    struct PhotoCluster: Identifiable {
        let id = UUID()
        var photoIDs: [UUID]                // 이 클러스터에 속한 사진 ID들
        var bestPhotoID: UUID?              // 품질 최고 (A컷 추천)
        var similarity: Float               // 클러스터 내 평균 유사도
    }

    struct FeatureVector {
        let photoID: UUID
        let url: URL
        var featurePrint: VNFeaturePrintObservation?
        var qualityScore: Double = 0
    }

    // MARK: - 1단계: 유사 그룹핑

    /// 전체 워크플로우 실행
    func runSmartCull(photos: [PhotoItem], store: PhotoStore) {
        guard !isProcessing else { return }
        isProcessing = true
        cancelled = false
        progress = 0
        groups = []
        statusMessage = "분석 준비 중..."

        let photoList = photos.filter { !$0.isFolder && !$0.isParentFolder }
        guard !photoList.isEmpty else {
            isProcessing = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Step 1: FeaturePrint 추출
            self.updateStatus("특징 벡터 추출 중... (0/\(photoList.count))")
            var vectors = self.extractFeatureVectors(photos: photoList)
            guard !self.cancelled else { self.finish(); return }

            // Step 2: 시간 기반 그룹 분리
            self.updateStatus("시간 기반 그룹 분리 중...")
            let timeGroups = self.groupByTime(photos: photoList, gap: 300) // 5분 간격

            // Step 3: 각 그룹 내 유사도 클러스터링
            self.updateStatus("유사 사진 클러스터링 중...")
            var resultGroups: [PhotoGroup] = []

            for (groupIdx, group) in timeGroups.enumerated() {
                guard !self.cancelled else { break }
                let groupVectors = vectors.filter { v in group.contains(where: { $0.id == v.photoID }) }
                fputs("[CULL] 그룹 \(groupIdx+1): 벡터 \(groupVectors.count)개\n", stderr)
                let clusters = self.clusterBySimilarity(vectors: groupVectors, threshold: self.genre.similarityThreshold)

                let timeRange = group.compactMap({ $0.fileModDate }).sorted()
                resultGroups.append(PhotoGroup(
                    name: "그룹 \(groupIdx + 1)",
                    clusters: clusters,
                    timeRange: timeRange.isEmpty ? nil : (timeRange.first!, timeRange.last!)
                ))

                self.updateProgress(Double(groupIdx + 1) / Double(timeGroups.count) * 0.7)
            }
            guard !self.cancelled else { self.finish(); return }

            // Step 4: 품질 점수 기반 A컷 추천
            self.updateStatus("A컷 추천 중...")
            for i in 0..<resultGroups.count {
                for j in 0..<resultGroups[i].clusters.count {
                    let cluster = resultGroups[i].clusters[j]
                    // 클러스터 내 품질 최고 = A컷
                    let bestID = self.findBestInCluster(
                        photoIDs: cluster.photoIDs,
                        photos: photoList,
                        vectors: vectors
                    )
                    resultGroups[i].clusters[j].bestPhotoID = bestID
                }
            }

            self.updateProgress(0.9)

            // Step 5: 결과 적용
            let totalClusters = resultGroups.flatMap(\.clusters).count
            let totalPhotosInClusters = resultGroups.flatMap(\.clusters).flatMap(\.photoIDs).count
            let aCuts = resultGroups.flatMap(\.clusters).compactMap(\.bestPhotoID).count
            fputs("[CULL] 최종 결과: \(resultGroups.count)개 그룹, \(totalClusters)개 클러스터, \(totalPhotosInClusters)장, A컷 \(aCuts)개\n", stderr)

            self.updateStatus("결과 적용 중...")
            DispatchQueue.main.async {
                self.groups = resultGroups
                self.applyResults(groups: resultGroups, store: store)
                self.updateProgress(1.0)
                self.statusMessage = "완료! \(resultGroups.count)개 그룹, \(totalClusters)개 클러스터, A컷 \(aCuts)개"
                self.isProcessing = false
            }
        }
    }

    func cancel() {
        cancelled = true
    }

    // MARK: - FeaturePrint 추출

    private func extractFeatureVectors(photos: [PhotoItem]) -> [FeatureVector] {
        var vectors: [FeatureVector] = []
        let lock = NSLock()
        let total = photos.count
        var failCount = 0

        fputs("[CULL] 특징 벡터 추출 시작: \(total)장\n", stderr)

        DispatchQueue.concurrentPerform(iterations: total) { index in
            guard !cancelled else { return }
            let photo = photos[index]

            // CGImage 로딩 (JPG → RAW 순서 시도)
            let cgImage: CGImage? = Self.loadCGImage(from: photo, maxSize: 800)

            guard let image = cgImage else {
                lock.lock()
                failCount += 1
                lock.unlock()
                if failCount <= 3 {
                    fputs("[CULL] 이미지 로딩 실패: \(photo.jpgURL.lastPathComponent)\n", stderr)
                }
                return
            }

            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                fputs("[CULL] FeaturePrint 추출 실패: \(error.localizedDescription)\n", stderr)
                return
            }

            guard let result = request.results?.first as? VNFeaturePrintObservation else {
                fputs("[CULL] FeaturePrint 결과 없음: \(photo.jpgURL.lastPathComponent)\n", stderr)
                return
            }

            var vector = FeatureVector(photoID: photo.id, url: photo.jpgURL, featurePrint: result)
            vector.qualityScore = Self.quickQualityScore(cgImage: image) * self.genre.sharpnessWeight

            lock.lock()
            vectors.append(vector)
            lock.unlock()

            let done = vectors.count
            if done % 10 == 0 || done == 1 {
                self.updateProgress(Double(done) / Double(total) * 0.5)
                self.updateStatus("특징 벡터 추출 중... (\(done)/\(total))")
            }
        }

        fputs("[CULL] 특징 벡터 추출 완료: \(vectors.count)/\(total)장 성공, \(failCount)장 실패\n", stderr)
        return vectors
    }

    /// CGImage 로딩 — JPG 우선, RAW fallback
    private static func loadCGImage(from photo: PhotoItem, maxSize: Int) -> CGImage? {
        // 1차: jpgURL 시도
        if let img = createThumbnail(url: photo.jpgURL, maxSize: maxSize) {
            return img
        }

        // 2차: RAW URL이 있으면 시도
        if let rawURL = photo.rawURL, rawURL != photo.jpgURL {
            if let img = createThumbnail(url: rawURL, maxSize: maxSize) {
                return img
            }
        }

        // 3차: NSImage fallback (모든 macOS 지원 포맷)
        if let nsImage = NSImage(contentsOf: photo.jpgURL),
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage
        }

        return nil
    }

    private static func createThumbnail(url: URL, maxSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    // MARK: - 시간 기반 그룹 분리

    private func groupByTime(photos: [PhotoItem], gap: TimeInterval) -> [[PhotoItem]] {
        let sorted = photos.sorted { $0.fileModDate < $1.fileModDate }
        var groups: [[PhotoItem]] = []
        var currentGroup: [PhotoItem] = []

        for photo in sorted {
            if let last = currentGroup.last {
                let diff = photo.fileModDate.timeIntervalSince(last.fileModDate)
                if diff > gap {
                    groups.append(currentGroup)
                    currentGroup = [photo]
                } else {
                    currentGroup.append(photo)
                }
            } else {
                currentGroup.append(photo)
            }
        }
        if !currentGroup.isEmpty { groups.append(currentGroup) }

        return groups
    }

    // MARK: - 유사도 클러스터링

    private func clusterBySimilarity(vectors: [FeatureVector], threshold: Float) -> [PhotoCluster] {
        guard !vectors.isEmpty else {
            fputs("[CULL] 클러스터링: 벡터 0개 → 빈 결과\n", stderr)
            return []
        }

        var assigned = Set<UUID>()
        var clusters: [PhotoCluster] = []

        // 디버그: 처음 몇 쌍의 거리 출력
        if vectors.count >= 2, let fp1 = vectors[0].featurePrint, let fp2 = vectors[1].featurePrint {
            var sampleDist: Float = 0
            try? fp1.computeDistance(&sampleDist, to: fp2)
            fputs("[CULL] 샘플 거리(0↔1): \(sampleDist), threshold: \(threshold)\n", stderr)
        }

        for vector in vectors {
            guard !assigned.contains(vector.photoID) else { continue }
            guard let fp = vector.featurePrint else { continue }

            var clusterIDs = [vector.photoID]
            assigned.insert(vector.photoID)
            var totalSimilarity: Float = 0
            var comparisons = 0

            for other in vectors {
                guard !assigned.contains(other.photoID) else { continue }
                guard let otherFP = other.featurePrint else { continue }

                var distance: Float = 0
                try? fp.computeDistance(&distance, to: otherFP)

                // distance가 낮을수록 유사 (0 = 동일)
                if distance < threshold {
                    clusterIDs.append(other.photoID)
                    assigned.insert(other.photoID)
                    totalSimilarity += (1.0 - distance / threshold)
                    comparisons += 1
                }
            }

            clusters.append(PhotoCluster(
                photoIDs: clusterIDs,
                bestPhotoID: nil,
                similarity: comparisons > 0 ? totalSimilarity / Float(comparisons) : 1.0
            ))
        }

        fputs("[CULL] 클러스터링 결과: \(clusters.count)개 클러스터 (2장 이상: \(clusters.filter { $0.photoIDs.count >= 2 }.count)개)\n", stderr)
        return clusters
    }

    // MARK: - A컷 추천

    private func findBestInCluster(photoIDs: [UUID], photos: [PhotoItem], vectors: [FeatureVector]) -> UUID? {
        var bestID: UUID?
        var bestScore: Double = -1

        for id in photoIDs {
            if let vector = vectors.first(where: { $0.photoID == id }) {
                if vector.qualityScore > bestScore {
                    bestScore = vector.qualityScore
                    bestID = id
                }
            }
        }
        return bestID
    }

    // MARK: - 결과 적용

    private func applyResults(groups: [PhotoGroup], store: PhotoStore) {
        for group in groups {
            for cluster in group.clusters {
                // A컷 → 별점 5 + 녹색 라벨
                if let bestID = cluster.bestPhotoID,
                   let idx = store._photoIndex[bestID], idx < store.photos.count {
                    store.photos[idx].rating = 5
                    store.photos[idx].colorLabel = .green
                }

                // 나머지 → 별점 3
                for photoID in cluster.photoIDs where photoID != cluster.bestPhotoID {
                    if let idx = store._photoIndex[photoID], idx < store.photos.count {
                        if store.photos[idx].rating == 0 {
                            store.photos[idx].rating = 3
                        }
                    }
                }
            }
        }
    }

    // MARK: - 빠른 품질 점수 (Laplacian)

    private static func quickQualityScore(cgImage: CGImage) -> Double {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 10, height > 10 else { return 0 }

        // 그레이스케일 변환
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return 0 }

        let ptr = data.bindMemory(to: UInt8.self, capacity: width * height)

        // Laplacian 분산 (선명도 지표)
        var sum: Double = 0
        var sumSq: Double = 0
        var count = 0
        let stride = max(1, width * height / 10000) // 최대 10000 샘플

        for y in Swift.stride(from: 1, to: height - 1, by: max(1, Int(sqrt(Double(stride))))) {
            for x in Swift.stride(from: 1, to: width - 1, by: max(1, Int(sqrt(Double(stride))))) {
                let center = Int(ptr[y * width + x])
                let top = Int(ptr[(y-1) * width + x])
                let bottom = Int(ptr[(y+1) * width + x])
                let left = Int(ptr[y * width + (x-1)])
                let right = Int(ptr[y * width + (x+1)])
                let laplacian = Double(abs(4 * center - top - bottom - left - right))
                sum += laplacian
                sumSq += laplacian * laplacian
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let mean = sum / Double(count)
        let variance = sumSq / Double(count) - mean * mean
        return min(100, variance / 10) // 0~100 정규화
    }

    // MARK: - 헬퍼

    private func updateStatus(_ msg: String) {
        DispatchQueue.main.async { self.statusMessage = msg }
    }

    private func updateProgress(_ value: Double) {
        DispatchQueue.main.async { self.progress = min(1.0, value) }
    }

    private func finish() {
        DispatchQueue.main.async {
            self.isProcessing = false
            self.statusMessage = self.cancelled ? "취소됨" : "완료"
        }
    }
}
