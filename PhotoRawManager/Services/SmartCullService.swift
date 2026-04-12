import Foundation
import AppKit
import Vision
import os

// MARK: - AI 스마트 셀렉 서비스
// 100% 로컬 (Apple Vision + NPU), 무료, 오프라인

class SmartCullService: ObservableObject {
    static let shared = SmartCullService()

    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var groups: [PhotoGroup] = []

    private var _cancelled = false
    private var cancelLock = os_unfair_lock_s()
    var cancelled: Bool {
        get { os_unfair_lock_lock(&cancelLock); defer { os_unfair_lock_unlock(&cancelLock) }; return _cancelled }
        set { os_unfair_lock_lock(&cancelLock); _cancelled = newValue; os_unfair_lock_unlock(&cancelLock) }
    }
    @Published var genre: CullGenre = .general

    // MARK: - 장르별 셀렉 설정
    enum CullGenre: String, CaseIterable, Identifiable {
        case general = "일반"
        case wedding = "웨딩"
        case sports = "스포츠"
        case event = "행사/컨퍼런스"
        case portrait = "인물"
        case landscape = "풍경"
        case lookbook = "쇼핑몰/룩북"

        var id: String { rawValue }

        /// 유사도 임계값 (VNFeaturePrint 거리 0~1, 낮을수록 엄격)
        var similarityThreshold: Float {
            switch self {
            case .general: return 0.38      // 메가 클러스터 방지
            case .wedding: return 0.55     // 비슷한 포즈 많으므로 넓게
            case .sports: return 0.30      // 순간 차이 중요 → 엄격
            case .event: return 0.40       // 부스/공간 구분 위해 엄격하게
            case .portrait: return 0.40    // 표정 차이 중요
            case .landscape: return 0.60   // 구도 유사 많음
            case .lookbook: return 0.55    // 같은 옷끼리 묶기 (포즈/앵글 차이 허용)
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
            case .lookbook: return 1.3     // 선명도 + 디테일 중요 (옷 질감)
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
            case .lookbook: return 0.2     // 20% (연사 많고 베스트컷만)
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
            case .lookbook: return "tshirt"
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
        var isBlurry: Bool = false
        var hasClosedEyes: Bool = false
        var sharpness: Double = 0
        var colorSignature: [Float] = []  // 옷 컬러 시그니처 (상의RGB + 하의RGB = 6차원)
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

            // Step 2: 시간 기반 그룹 분리 (장르별 간격)
            self.updateStatus("시간 기반 그룹 분리 중...")
            let timeGap: TimeInterval
            switch self.genre {
            case .lookbook: timeGap = 90    // 옷 교체 ~100초
            case .sports:   timeGap = 30    // 경기 장면 전환
            case .wedding:  timeGap = 600   // 세레모니 간격 넓음
            case .event:    timeGap = 300
            case .portrait: timeGap = 120
            case .landscape: timeGap = 600
            case .general:  timeGap = 300
            }
            let timeGroups = self.groupByTime(photos: photoList, gap: timeGap)
            fputs("[CULL] 시간 그룹: \(timeGroups.count)개 (간격 \(Int(timeGap))초)\n", stderr)

            // Step 3: 각 그룹 내 유사도 클러스터링
            self.updateStatus("유사 사진 클러스터링 중...")
            var resultGroups: [PhotoGroup] = []

            for (groupIdx, group) in timeGroups.enumerated() {
                guard !self.cancelled else { break }
                let groupVectors = vectors.filter { v in group.contains(where: { $0.id == v.photoID }) }
                fputs("[CULL] 그룹 \(groupIdx+1): 벡터 \(groupVectors.count)개\n", stderr)
                // 자동 threshold: 샘플 거리 기반 (상대적)
                let autoThreshold = self.calculateAutoThreshold(vectors: groupVectors, genre: self.genre)
                fputs("[CULL] 자동 threshold: \(String(format: "%.4f", autoThreshold)) (장르: \(self.genre.rawValue))\n", stderr)

                var clusters = self.clusterBySimilarity(vectors: groupVectors, threshold: autoThreshold)

                // 2차 병합: 룩북에서만 (같은 옷 묶기)
                if self.genre == .lookbook {
                    clusters = self.mergeSimilarClusters(clusters: clusters, vectors: groupVectors, mergeThreshold: autoThreshold * 1.3)
                }

                // 메가 클러스터 재분할: 30장 이상 클러스터를 더 엄격한 threshold로 분할
                let maxClusterSize = 30
                var finalClusters: [PhotoCluster] = []
                for cluster in clusters {
                    if cluster.photoIDs.count > maxClusterSize {
                        let subVectors = groupVectors.filter { cluster.photoIDs.contains($0.photoID) }
                        let tighterThreshold = autoThreshold * 0.6  // 40% 더 엄격
                        fputs("[CULL] 메가 클러스터 재분할: \(cluster.photoIDs.count)장 → threshold \(String(format: "%.4f", tighterThreshold))\n", stderr)
                        var subClusters = self.clusterBySimilarity(vectors: subVectors, threshold: tighterThreshold)
                        // 여전히 큰 경우 한번 더 분할
                        var splitAgain: [PhotoCluster] = []
                        for sc in subClusters {
                            if sc.photoIDs.count > maxClusterSize {
                                let sv = subVectors.filter { sc.photoIDs.contains($0.photoID) }
                                let tighter2 = tighterThreshold * 0.7
                                fputs("[CULL]   2차 재분할: \(sc.photoIDs.count)장 → threshold \(String(format: "%.4f", tighter2))\n", stderr)
                                splitAgain.append(contentsOf: self.clusterBySimilarity(vectors: sv, threshold: tighter2))
                            } else {
                                splitAgain.append(sc)
                            }
                        }
                        finalClusters.append(contentsOf: splitAgain)
                    } else {
                        finalClusters.append(cluster)
                    }
                }
                clusters = finalClusters

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
            let capturedVectors = vectors
            DispatchQueue.main.async {
                self.groups = resultGroups
                self.applyResults(groups: resultGroups, store: store, vectors: capturedVectors)
                self.updateProgress(1.0)
                self.statusMessage = "완료! \(resultGroups.count)개 그룹, \(totalClusters)개 클러스터, A컷 \(aCuts)개"
                self.isProcessing = false
            }
        }
    }

    func cancel() {
        cancelled = true
    }

    /// 클러스터별 폴더 분류 — 유사 사진끼리 하위 폴더로 이동/복사
    func sortIntoFolders(store: PhotoStore, copy: Bool = true) {
        guard !groups.isEmpty, let folderURL = store.folderURL else { return }

        let fm = FileManager.default
        let baseDir = folderURL.appendingPathComponent("_AI분류")
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

        var totalMoved = 0

        for group in groups {
            for (clusterIdx, cluster) in group.clusters.enumerated() {
                guard cluster.photoIDs.count >= 2 else { continue }  // 1장짜리는 건너뜀

                let folderName = String(format: "클러스터_%03d_%d장", clusterIdx + 1, cluster.photoIDs.count)
                let clusterDir = baseDir.appendingPathComponent(folderName)
                try? fm.createDirectory(at: clusterDir, withIntermediateDirectories: true)

                for photoID in cluster.photoIDs {
                    guard let idx = store._photoIndex[photoID], idx < store.photos.count else { continue }
                    let photo = store.photos[idx]

                    // JPG 복사/이동
                    let destJPG = clusterDir.appendingPathComponent(photo.jpgURL.lastPathComponent)
                    if !fm.fileExists(atPath: destJPG.path) {
                        if copy {
                            try? fm.copyItem(at: photo.jpgURL, to: destJPG)
                        } else {
                            try? fm.moveItem(at: photo.jpgURL, to: destJPG)
                        }
                    }

                    // RAW 복사/이동
                    if let rawURL = photo.rawURL, rawURL != photo.jpgURL {
                        let destRAW = clusterDir.appendingPathComponent(rawURL.lastPathComponent)
                        if !fm.fileExists(atPath: destRAW.path) {
                            if copy {
                                try? fm.copyItem(at: rawURL, to: destRAW)
                            } else {
                                try? fm.moveItem(at: rawURL, to: destRAW)
                            }
                        }
                    }

                    // A컷은 파일명 앞에 ★ 표시
                    if cluster.bestPhotoID == photoID {
                        let starName = "★_" + photo.jpgURL.lastPathComponent
                        let starDest = clusterDir.appendingPathComponent(starName)
                        try? fm.copyItem(at: photo.jpgURL, to: starDest)
                    }

                    totalMoved += 1
                }
            }
        }

        fputs("[CULL] 폴더 분류 완료: \(totalMoved)장 → \(baseDir.path)\n", stderr)

        // 분류 폴더 열기
        DispatchQueue.main.async {
            store.loadFolder(baseDir, restoreRatings: false)
            NSWorkspace.shared.open(baseDir)
        }
    }

    // MARK: - FeaturePrint 추출

    private func extractFeatureVectors(photos: [PhotoItem]) -> [FeatureVector] {
        let total = photos.count
        // 고정 배열로 인덱스별 직접 기록 (lock 경합 최소화)
        var slots = [FeatureVector?](repeating: nil, count: total)
        let lock = NSLock()
        var doneCount = 0

        fputs("[CULL] 특징 벡터 추출 시작: \(total)장 (Phase 1: FeaturePrint만)\n", stderr)
        let startTime = CFAbsoluteTimeGetCurrent()

        // Phase 1: FeaturePrint만 빠르게 추출 (320px, 품질평가 없음)
        // UnsafeMutableBufferPointer로 concurrent index 접근 안전하게 처리
        slots.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: total) { index in
                guard !self.cancelled else { return }
                autoreleasepool {
                    let photo = photos[index]

                    // 320px 썸네일 — FeaturePrint에 충분, 로딩 3배 빠름
                    guard let image = Self.loadCGImage(from: photo, maxSize: 320) else { return }

                    let request = VNGenerateImageFeaturePrintRequest()
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    do {
                        try handler.perform([request])
                    } catch { return }

                    guard let result = request.results?.first as? VNFeaturePrintObservation else { return }

                    let vector = FeatureVector(photoID: photo.id, url: photo.jpgURL, featurePrint: result)
                    buffer[index] = vector

                    lock.lock()
                    doneCount += 1
                    let done = doneCount
                    lock.unlock()

                    if done % 50 == 0 || done == 1 || done == total {
                        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                        let rate = elapsed > 0 ? Double(done) / elapsed : 0
                        let eta = rate > 0 ? Double(total - done) / rate : 0
                        let etaStr = eta < 60 ? "\(Int(eta))초" : "\(Int(eta/60))분 \(Int(eta) % 60)초"
                        self.updateProgress(Double(done) / Double(total) * 0.4)
                        self.updateStatus("특징 벡터 추출 중... (\(done)/\(total)) · \(String(format: "%.1f", rate))장/초 · 약 \(etaStr) 남음")
                    }
                }
            }
        }

        var vectors = slots.compactMap { $0 }
        let phase1Time = CFAbsoluteTimeGetCurrent() - startTime
        fputs("[CULL] Phase 1 완료: \(vectors.count)/\(total)장 (\(String(format: "%.1f", phase1Time))초, \(String(format: "%.1f", Double(vectors.count)/phase1Time))장/초)\n", stderr)

        // Phase 2: 품질 평가 (선명도, 눈감김 등) — 480px
        let isLookbook = self.genre == .lookbook
        let needEyeCheck = self.genre == .lookbook || self.genre == .portrait || self.genre == .wedding
        let sharpWeight = self.genre.sharpnessWeight
        let phase2Total = vectors.count
        var phase2Done = 0

        // URL 빠른 조회용 맵
        let photoMap: [UUID: PhotoItem] = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })

        self.updateStatus("품질 분석 중... (0/\(phase2Total))")

        // UnsafeMutableBufferPointer로 concurrent index 접근 안전하게 처리
        vectors.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: phase2Total) { index in
                guard !self.cancelled else { return }
                autoreleasepool {
                    guard let p = photoMap[buffer[index].photoID],
                          let image = Self.loadCGImage(from: p, maxSize: 480) else { return }

                    let sharpness = Self.quickQualityScore(cgImage: image)
                    buffer[index].sharpness = sharpness
                    buffer[index].qualityScore = sharpness * sharpWeight
                    buffer[index].isBlurry = sharpness < 8

                    if needEyeCheck {
                        buffer[index].hasClosedEyes = Self.detectClosedEyes(cgImage: image)
                    }

                    if isLookbook {
                        buffer[index].colorSignature = Self.extractClothingColorSignature(cgImage: image)

                        // 룩북: 인물 세그멘테이션 FeaturePrint
                        if let personOnly = Self.extractPersonRegion(cgImage: image) {
                            let req2 = VNGenerateImageFeaturePrintRequest()
                            let h2 = VNImageRequestHandler(cgImage: personOnly, options: [:])
                            try? h2.perform([req2])
                            if let fp2 = req2.results?.first as? VNFeaturePrintObservation {
                                buffer[index].featurePrint = fp2
                            }
                        }
                    }

                    lock.lock()
                    phase2Done += 1
                    let done = phase2Done
                    lock.unlock()

                    if done % 50 == 0 || done == phase2Total {
                        self.updateProgress(0.4 + Double(done) / Double(phase2Total) * 0.1)
                        self.updateStatus("품질 분석 중... (\(done)/\(phase2Total))")
                    }
                }
            }
        }

        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        fputs("[CULL] 전체 추출 완료: \(vectors.count)장 (\(String(format: "%.1f", totalTime))초)\n", stderr)
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

    /// 상의/하의 컬러 시그니처 추출 (6차원: 상의RGB + 하의RGB)
    private static func extractClothingColorSignature(cgImage: CGImage) -> [Float] {
        let w = cgImage.width
        let h = cgImage.height

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return [] }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // 인물 세그멘테이션 마스크
        let segRequest = VNGeneratePersonSegmentationRequest()
        segRequest.qualityLevel = .fast
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([segRequest])

        var maskData: UnsafeMutablePointer<UInt8>?
        var maskW = 0, maskH = 0, maskBPR = 0

        if let seg = segRequest.results?.first {
            let buf: CVPixelBuffer = seg.pixelBuffer
            CVPixelBufferLockBaseAddress(buf, .readOnly)
            if let baseAddr = CVPixelBufferGetBaseAddress(buf) {
                maskData = baseAddr.assumingMemoryBound(to: UInt8.self)
            }
            maskW = CVPixelBufferGetWidth(buf)
            maskH = CVPixelBufferGetHeight(buf)
            maskBPR = CVPixelBufferGetBytesPerRow(buf)
        }

        // 상의 영역: 인물 마스크 상위 40~60% (가슴~허리)
        // 하의 영역: 인물 마스크 하위 60~80% (허리~무릎)
        var topR: Float = 0, topG: Float = 0, topB: Float = 0, topCount: Float = 0
        var botR: Float = 0, botG: Float = 0, botB: Float = 0, botCount: Float = 0

        let centerX = w / 2
        let sampleWidth = w / 3  // 중앙 1/3만 샘플링

        for y in 0..<h {
            let yRatio = Float(y) / Float(h)  // CGContext: y=0이 top

            for x in (centerX - sampleWidth/2)..<(centerX + sampleWidth/2) {
                // 마스크 체크 (인물 영역만)
                if let mask = maskData, maskW > 0 {
                    let mx = x * maskW / w
                    let my = y * maskH / h
                    let maskVal = mask[my * maskBPR + mx]
                    if maskVal < 128 { continue }  // 배경 스킵
                }

                let i = (y * w + x) * 4
                let r = Float(ptr[i])
                let g = Float(ptr[i + 1])
                let b = Float(ptr[i + 2])

                if yRatio > 0.25 && yRatio < 0.50 {
                    // 상의 영역
                    topR += r; topG += g; topB += b; topCount += 1
                } else if yRatio > 0.50 && yRatio < 0.75 {
                    // 하의 영역
                    botR += r; botG += g; botB += b; botCount += 1
                }
            }
        }

        if let seg = segRequest.results?.first {
            CVPixelBufferUnlockBaseAddress(seg.pixelBuffer, .readOnly)
        }

        // 정규화 (0~1)
        let sig: [Float]
        if topCount > 0 && botCount > 0 {
            sig = [
                topR / topCount / 255, topG / topCount / 255, topB / topCount / 255,
                botR / botCount / 255, botG / botCount / 255, botB / botCount / 255
            ]
        } else if topCount > 0 {
            sig = [topR / topCount / 255, topG / topCount / 255, topB / topCount / 255, 0, 0, 0]
        } else {
            sig = [0, 0, 0, 0, 0, 0]
        }

        return sig
    }

    /// 컬러 시그니처 거리 (유클리드)
    private static func colorDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }
        var sum: Float = 0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sqrt(sum)
    }

    /// Vision 인물 세그멘테이션 — 사람+옷 영역만 추출 (배경 완전 제거)
    private static func extractPersonRegion(cgImage: CGImage) -> CGImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast  // balanced보다 빠름
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let result = request.results?.first else { return nil }
        let maskBuffer = result.pixelBuffer

        // 마스크를 CIImage로 변환
        let maskCI = CIImage(cvPixelBuffer: maskBuffer)
        let originalCI = CIImage(cgImage: cgImage)

        // 마스크 크기를 원본에 맞춤
        let scaleX = originalCI.extent.width / maskCI.extent.width
        let scaleY = originalCI.extent.height / maskCI.extent.height
        let scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // 마스크 적용 (사람 영역만 남기고 배경은 검정)
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
        blendFilter.setValue(originalCI, forKey: kCIInputImageKey)
        blendFilter.setValue(CIImage(color: .black).cropped(to: originalCI.extent), forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(scaledMask, forKey: kCIInputMaskImageKey)

        guard let output = blendFilter.outputImage else { return nil }

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(output, from: originalCI.extent)
    }

    /// 중앙 크롭 — 배경 제거하고 옷 영역만 추출
    private static func centerCrop(cgImage: CGImage, ratio: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let cropW = w * ratio
        let cropH = h * ratio
        let x = (w - cropW) / 2
        let y = (h - cropH) / 2
        let rect = CGRect(x: x, y: y, width: cropW, height: cropH)
        return cgImage.cropping(to: rect)
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

        // 시간순 정렬 (인접한 사진끼리 묶이도록)
        let sorted = vectors.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }

        for vector in sorted {
            guard !assigned.contains(vector.photoID) else { continue }
            guard let fp = vector.featurePrint else { continue }

            var clusterIDs = [vector.photoID]
            var clusterFPs = [fp]  // centroid 비교용
            assigned.insert(vector.photoID)
            var totalSimilarity: Float = 0
            var comparisons = 0

            for other in sorted {
                guard !assigned.contains(other.photoID) else { continue }
                guard let otherFP = other.featurePrint else { continue }

                // Centroid 비교: 클러스터 내 모든 FP와의 평균 거리
                var avgDist: Float = 0
                for cfp in clusterFPs {
                    var d: Float = 0
                    try? cfp.computeDistance(&d, to: otherFP)
                    avgDist += d
                }
                avgDist /= Float(clusterFPs.count)

                // 컬러 거리 합산 (룩북)
                var distance = avgDist
                if !vector.colorSignature.isEmpty && !other.colorSignature.isEmpty {
                    let colorDist = Self.colorDistance(vector.colorSignature, other.colorSignature)
                    distance = avgDist * 0.4 + colorDist * 0.6
                }

                if distance < threshold {
                    clusterIDs.append(other.photoID)
                    clusterFPs.append(otherFP)
                    assigned.insert(other.photoID)
                    totalSimilarity += (1.0 - distance / threshold)
                    comparisons += 1

                    // centroid 비교 비용 제한: FP 최대 10개만 유지
                    if clusterFPs.count > 10 {
                        clusterFPs.removeFirst()
                    }
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

    // MARK: - 자동 Threshold 계산 (거리 분포 기반)

    private func calculateAutoThreshold(vectors: [FeatureVector], genre: CullGenre) -> Float {
        guard vectors.count >= 2 else { return genre.similarityThreshold }

        // 랜덤 쌍 100개의 거리 샘플링
        var distances: [Float] = []
        let sampleCount = min(100, vectors.count * (vectors.count - 1) / 2)

        for _ in 0..<sampleCount {
            let i = Int.random(in: 0..<vectors.count)
            var j = Int.random(in: 0..<vectors.count)
            while j == i { j = Int.random(in: 0..<vectors.count) }

            guard let fpA = vectors[i].featurePrint,
                  let fpB = vectors[j].featurePrint else { continue }
            var dist: Float = 0
            try? fpA.computeDistance(&dist, to: fpB)
            distances.append(dist)
        }

        guard !distances.isEmpty else { return genre.similarityThreshold }
        distances.sort()

        // 장르별 퍼센타일로 threshold 결정
        let percentile: Double
        switch genre {
        case .lookbook:  percentile = 0.25  // 하위 25% = 같은 옷 수준
        case .sports:    percentile = 0.10  // 하위 10% = 매우 유사만
        case .portrait:  percentile = 0.20
        case .wedding:   percentile = 0.30
        case .landscape: percentile = 0.35
        case .event:     percentile = 0.25
        case .general:   percentile = 0.20
        }

        let idx = Int(Double(distances.count) * percentile)
        let threshold = distances[min(idx, distances.count - 1)]

        fputs("[CULL] 거리 분포: min=\(String(format: "%.4f", distances.first!)), median=\(String(format: "%.4f", distances[distances.count/2])), max=\(String(format: "%.4f", distances.last!)), P\(Int(percentile*100))=\(String(format: "%.4f", threshold))\n", stderr)

        return threshold
    }

    // MARK: - 2차 병합 (클러스터 대표 벡터끼리 비교)

    private func mergeSimilarClusters(clusters: [PhotoCluster], vectors: [FeatureVector], mergeThreshold: Float) -> [PhotoCluster] {
        guard clusters.count > 1 else { return clusters }
        var merged = clusters
        var changed = true

        while changed {
            changed = false
            var i = 0
            while i < merged.count {
                var j = i + 1
                while j < merged.count {
                    // 각 클러스터의 첫 번째 사진 벡터로 대표
                    guard let fpA = vectors.first(where: { $0.photoID == merged[i].photoIDs.first })?.featurePrint,
                          let fpB = vectors.first(where: { $0.photoID == merged[j].photoIDs.first })?.featurePrint else {
                        j += 1; continue
                    }

                    var distance: Float = 0
                    try? fpA.computeDistance(&distance, to: fpB)

                    if distance < mergeThreshold {
                        // 병합
                        merged[i].photoIDs.append(contentsOf: merged[j].photoIDs)
                        merged[i].similarity = (merged[i].similarity + merged[j].similarity) / 2
                        merged.remove(at: j)
                        changed = true
                    } else {
                        j += 1
                    }
                }
                i += 1
            }
        }

        fputs("[CULL] 2차 병합: \(clusters.count) → \(merged.count) 클러스터\n", stderr)
        return merged
    }

    // MARK: - A컷 추천 (품질 + 이슈 감점)

    private func findBestInCluster(photoIDs: [UUID], photos: [PhotoItem], vectors: [FeatureVector]) -> UUID? {
        var bestID: UUID?
        var bestScore: Double = -1

        for id in photoIDs {
            guard let vector = vectors.first(where: { $0.photoID == id }) else { continue }

            var score = vector.qualityScore

            // 이슈 감점
            if vector.isBlurry { score -= 50 }        // 흔들림 → 크게 감점
            if vector.hasClosedEyes { score -= 40 }    // 눈감김 → 감점

            if score > bestScore {
                bestScore = score
                bestID = id
            }
        }
        return bestID
    }

    // MARK: - 눈감김 감지 (Vision)

    private static func detectClosedEyes(cgImage: CGImage) -> Bool {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let results = request.results else { return false }

        for face in results {
            guard let landmarks = face.landmarks else { continue }

            // 눈 열림 비율 체크 (눈 높이 / 눈 폭)
            if let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye {
                let leftRatio = eyeOpenRatio(leftEye)
                let rightRatio = eyeOpenRatio(rightEye)
                // 양쪽 눈 모두 0.15 이하면 감김
                if leftRatio < 0.15 && rightRatio < 0.15 {
                    return true
                }
            }
        }
        return false
    }

    private static func eyeOpenRatio(_ eye: VNFaceLandmarkRegion2D) -> CGFloat {
        guard eye.pointCount >= 6 else { return 1.0 }
        let points = eye.normalizedPoints

        // 눈의 상하 높이 vs 좌우 폭 비율
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0

        let width = maxX - minX
        guard width > 0 else { return 1.0 }
        return (maxY - minY) / width
    }

    // MARK: - 결과 적용

    private func applyResults(groups: [PhotoGroup], store: PhotoStore, vectors: [FeatureVector] = []) {
        var rejectCount = 0
        for group in groups {
            for cluster in group.clusters {
                // A컷 → 별점 5 + 녹색 라벨
                if let bestID = cluster.bestPhotoID,
                   let idx = store._photoIndex[bestID], idx < store.photos.count {
                    store.photos[idx].rating = 5
                    store.photos[idx].colorLabel = .green
                }

                for photoID in cluster.photoIDs where photoID != cluster.bestPhotoID {
                    guard let idx = store._photoIndex[photoID], idx < store.photos.count else { continue }

                    // 이슈 체크 (흔들림/눈감김 → 탈락)
                    if let vec = vectors.first(where: { $0.photoID == photoID }) {
                        if vec.isBlurry || vec.hasClosedEyes {
                            store.photos[idx].rating = 1  // 탈락
                            store.photos[idx].colorLabel = .orange
                            rejectCount += 1
                            continue
                        }
                    }

                    // 정상 사진 → 별점 3
                    if store.photos[idx].rating == 0 {
                        store.photos[idx].rating = 3
                    }
                }
            }
        }
        if rejectCount > 0 {
            fputs("[CULL] 이슈 탈락: \(rejectCount)장 (흔들림/눈감김)\n", stderr)
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
