import SwiftUI
import Foundation
import ImageIO
import CoreLocation

extension PhotoStore {
    // MARK: - 주변 썸네일 프리로딩 (키보드 이동 시 빈 썸네일 방지)

    func scheduleSelectionIdleWork(for photoID: UUID, delay: TimeInterval = 0.55) {
        selectionIdleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  !self.isFastNavigation,
                  self.selectedPhotoID == photoID else { return }

            NotificationCenter.default.post(name: .pickShotSelectionSettled, object: photoID)
            self.scheduleNavigationIdlePrefetch(delay: 0.0)
            self.reverseGeocodeIfNeeded(for: photoID)
        }
        selectionIdleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func scheduleNavigationIdlePrefetch(delay: TimeInterval = 0.45) {
        prefetchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isFastNavigation else { return }
            self.prefetchNearbyThumbnails()
        }
        prefetchWorkItem = work
        let effectiveDelay = isRecursiveMode ? max(delay, 0.25) : delay
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + effectiveDelay, execute: work)
    }

    func prefetchNearbyThumbnails() {
        // FRV식: 방향키/클릭 반응이 먼저다. 주변 썸네일은 사용자가 잠깐 멈춘 뒤 보수적으로 채운다.
        prefetchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let id = self.selectedPhotoID, !self.isFastNavigation else { return }
            let list = self.filteredPhotos
            self.ensureFilteredIndex()
            guard let idx = self._filteredIndex[id] else { return }

            // 주변 임베디드 JPEG 추출 → ThumbnailCache 적재.
            // 하드웨어 끝까지 쓰지 않고 약 20% 여유를 남기도록 tier별 범위/동시성을 제한한다.
            // ThumbnailLoader 우회: 내부 lock/queue 경합 회피 + 풀 디코드 방지
            let radius: Int = {
                if self.isRecursiveMode {
                    return ThumbnailLoader.shared.isSlowDisk ? 2 : 3
                }
                switch SystemSpec.shared.effectiveTier {
                case .low: return 6
                case .standard: return 8
                case .high: return 10
                case .extreme: return 12
                }
            }()
            let start = max(0, idx - radius)
            let end = min(list.count - 1, idx + radius)
            guard start <= end else { return }

            var toLoad: [URL] = []
            for i in start...end {
                let photo = list[i]
                guard !photo.isFolder && !photo.isParentFolder else { continue }
                if ThumbnailCache.shared.get(photo.jpgURL) == nil {
                    toLoad.append(photo.jpgURL)
                }
            }

            // 제한된 병렬 추출 — v8.8.0: ThumbnailLoader 경유로 변경.
            //   직접 CGImageSourceCreateThumbnailAtIndex 호출 시 NEF 등 RAW 의 EXIF orientation
            //   이 적용 안 돼서 세로 사진이 가로로 캐시되는 버그 발생. generateThumbnailSync 는
            //   내부에서 extractThumbnailFast 를 통해 orientation 을 정확히 처리.
            let concurrency = self.isRecursiveMode ? 1 : max(1, min(2, SystemSpec.shared.ssdThumbnailConcurrency()))
            let semaphore = DispatchSemaphore(value: concurrency)
            let concurrentQueue = DispatchQueue(label: "thumb.nearby.prefetch", qos: .utility, attributes: .concurrent)
            let limit = self.isRecursiveMode ? min(4, radius * 2) : radius * 2
            for url in toLoad.prefix(limit) {
                concurrentQueue.async {
                    semaphore.wait()
                    defer { semaphore.signal() }
                    autoreleasepool {
                        if ThumbnailCache.shared.get(url) != nil { return }
                        if let img = ThumbnailLoader.shared.generateThumbnailSync(url: url) {
                            ThumbnailCache.shared.set(url, image: img)
                        } else {
                            // generateThumbnailSync 는 이미 캐시에 있으면 nil 리턴 — 그 경우 직접 get
                            if ThumbnailCache.shared.get(url) == nil,
                               let disk = DiskThumbnailCache.shared.getByPath(url: url) {
                                ThumbnailCache.shared.set(url, image: disk)
                            }
                        }
                    }
                }
            }
        }
        prefetchWorkItem = work
        let delay: TimeInterval = isRecursiveMode ? 0.18 : 0.05
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Lazy-load RAW EXIF when a photo is selected (not at folder load time)
    /// EXIF loading is now handled by ExifInfoView directly
    func ensureRawExifLoaded(for photoID: UUID) {
        // No-op: ExifInfoView loads its own EXIF via @State
    }

    /// Replace photos array while preserving selection state
    /// Forces SwiftUI to detect the change by assigning a new array
    func applyPhotosUpdate(_ newPhotos: [PhotoItem]) {
        let savedSel = selectedPhotoID
        let savedMulti = selectedPhotoIDs
        photos = newPhotos   // triggers didSet → rebuildIndex, invalidate cache
        selectedPhotoID = savedSel
        selectedPhotoIDs = savedMulti
    }

    /// 폴더 열 때 첫 N장 EXIF 배치 로딩
    func batchLoadExif(count: Int) {
        let list = photos.filter { !$0.isFolder && !$0.isParentFolder && $0.exifData == nil }
        let batch = list.prefix(count)
        guard !batch.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var loaded = 0
            for photo in batch {
                guard let exif = ExifService.extractExif(from: photo.jpgURL) else { continue }
                DispatchQueue.main.async {
                    guard let self = self,
                          let i = self._photoIndex[photo.id], i < self.photos.count else { return }
                    self._suppressDidSet = true
                    self.photos[i].exifData = exif
                    self._suppressDidSet = false
                    self.exifLoadingIDs.insert(photo.id)
                }
                loaded += 1
            }
            // 배치 완료 → UI 업데이트 (Table 갱신을 위해 photosVersion 증가)
            DispatchQueue.main.async { [weak self] in
                self?.invalidateFilterCache()
                // @Published가 자동 알림 → objectWillChange 중복 제거
            }
        }
    }

    func reverseGeocodeIfNeeded(for photoID: UUID) {
        guard let idx = _photoIndex[photoID], idx < photos.count else { return }
        guard let exif = photos[idx].exifData,
              let lat = exif.latitude, let lon = exif.longitude,
              exif.placeName == nil else { return }

        let key = String(format: "%.4f,%.4f", lat, lon)
        if let cached = geocodeCache[key] {
            photos[idx].exifData?.placeName = cached
            return
        }

        let location = CLLocation(latitude: lat, longitude: lon)
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self, let pm = placemarks?.first else { return }
            let name = [pm.locality, pm.subLocality, pm.thoroughfare]
                .compactMap { $0 }
                .joined(separator: " ")
            let result = name.isEmpty ? (pm.country ?? "Unknown") : name
            DispatchQueue.main.async {
                if self.geocodeCache.count > 500 { self.geocodeCache.removeAll() }
                self.geocodeCache[key] = result
                guard let i = self._photoIndex[photoID], i < self.photos.count else { return }
                self.photos[i].exifData?.placeName = result
            }
        }
    }

    func exifFor(_ id: UUID) -> ExifData? {
        guard let idx = _photoIndex[id], idx < photos.count else { return nil }
        return photos[idx].exifData
    }

    func livePhoto(_ id: UUID) -> PhotoItem? {
        guard let idx = _photoIndex[id], idx < photos.count else { return nil }
        return photos[idx]
    }

    func loadExifIfNeeded(for photoID: UUID) {
        guard let idx = _photoIndex[photoID], idx < photos.count else { return }
        guard photos[idx].exifData == nil else { return }
        guard !photos[idx].isFolder && !photos[idx].isParentFolder else { return }
        guard !exifLoadingIDs.contains(photoID) else { return }
        plog("[EXIF] loadIfNeeded: \(photos[idx].fileName)\n")

        exifLoadingIDs.insert(photoID)
        let url = photos[idx].jpgURL
        let fileName = url.lastPathComponent
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let exif = ExifService.extractExif(from: url) else {
                plog("[EXIF] FAIL \(fileName)\n")
                DispatchQueue.main.async { self?.exifLoadingIDs.remove(photoID) }
                return
            }
            plog("[EXIF] OK \(fileName) lens=\(exif.lensModel ?? "nil") w=\(exif.imageWidth ?? 0)\n")
            DispatchQueue.main.async {
                guard let self = self,
                      let i = self._photoIndex[photoID], i < self.photos.count else { return }
                self._suppressDidSet = true
                self.photos[i].exifData = exif
                self._suppressDidSet = false

                // 배치: 0.3초 디바운스로 Table 갱신
                self.exifBatchWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.invalidateFilterCache()
                }
                self.exifBatchWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
    }

    /// 목록뷰 전환 시 전체 EXIF 배치 로딩
    func triggerListExifLoad() {
        guard !isRecursiveMode else { return }
        let needExif = photos.filter { !$0.isFolder && !$0.isParentFolder && $0.exifData == nil }.count
        plog("[EXIF] triggerListExifLoad: need=\(needExif), version=\(photosVersion), last=\(lastExifLoadVersion)\n")
        guard lastExifLoadVersion != photosVersion else { return }
        lastExifLoadVersion = photosVersion
        guard needExif > 0 else { return }
        batchLoadExif(count: photos.count)
    }

    func preloadAllThumbnails() {
        guard !isRecursiveMode else {
            thumbsTotal = photos.count
            thumbsLoaded = thumbsTotal
            return
        }
        let list = photos.filter { !$0.isFolder && !$0.isParentFolder }
        thumbsTotal = list.count
        thumbsLoaded = thumbsTotal

        // 디스크 속도별 차별화:
        // - SSD: visible-first가 충분히 빠르므로 prewarming은 보조적 (±40장)
        // - HDD/SD: 한 장당 100-300ms 소요 → 미리 많이 채워둬야 스크롤 시 cache hit
        //   ±100장으로 확대, concurrency도 4-way로 (HDD NCQ 활용)
        guard !list.isEmpty else { return }

        let currentIdx: Int = {
            if let selID = selectedPhotoID, let idx = list.firstIndex(where: { $0.id == selID }) { return idx }
            return 0
        }()

        let isSlow = currentFolderIsSlowDisk
        // NAS 의 경우 네트워크 대역폭 제한으로 radius 를 작게 (30장)
        // 외장 HDD 는 NCQ 활용으로 100장 유지
        let isNetwork = ThumbnailLoader.shared.isNetworkMode
        let radius: Int
        if fastCullingMode || isRecursiveScanInProgress {
            // 빠른 셀렉/대량 재귀 스캔 직후에는 보이는 주변만 얇게 채운다.
            // 전체 성능을 다 쓰지 않고 입력/스크롤 여유를 남기는 보수적 기본값.
            if isNetwork { radius = 10 }
            else if isSlow { radius = 24 }
            else { radius = 18 }
        } else if isNetwork { radius = 30 }       // NAS: 현재 화면 주변만 prewarm
        else if isSlow { radius = 100 }           // 외장 HDD
        else { radius = 40 }                      // SSD
        let start = max(0, currentIdx - radius)
        let end = min(list.count, currentIdx + radius)
        guard start < end else { return }

        let urls = (start..<end).sorted { abs($0 - currentIdx) < abs($1 - currentIdx) }.map { list[$0].jpgURL }
        let gen = idlePrefetchGeneration

        // HDD: prewarming concurrency 2로 제한 — visible 로딩(ThumbnailLoader 6-way)과 디스크 경합 최소화
        // (HDD에서 동시 8+ way seek은 NCQ 한계 초과 → 모두 느려짐)
        // SSD: tier 기반 (low=2, standard=3, high=4)
        let concurrency = (fastCullingMode || isRecursiveScanInProgress)
            ? 1
            : (isSlow ? 2 : SystemSpec.shared.ssdThumbnailConcurrency())
        let sem = DispatchSemaphore(value: concurrency)
        let concurrentQueue = DispatchQueue(label: "preview.thumb.prewarm", qos: .utility, attributes: .concurrent)
        for url in urls {
            concurrentQueue.async { [weak self] in
                sem.wait()
                defer { sem.signal() }
                // background queue 는 main RunLoop 의 autorelease pool 과 독립적
                // key repeat 꾹 누르기 시 이미지 객체가 GCD worker thread pool 에 누적되는 것을 막기 위해 명시적 pool
                autoreleasepool {
                    guard self?.idlePrefetchGeneration == gen else { return }
                    if ThumbnailCache.shared.get(url) != nil { return }  // 이미 캐시됨
                    // v8.8.0: ThumbnailLoader 경유 (NEF 등 RAW orientation 처리 보장)
                    if let img = ThumbnailLoader.shared.generateThumbnailSync(url: url) {
                        ThumbnailCache.shared.set(url, image: img)
                    }
                }
            }
        }
    }

    func startIdlePreviewPrefetch() {
        guard !fastCullingMode, !isRecursiveScanInProgress, !isRecursiveMode else { return }
        idlePrefetchGeneration += 1
        let gen = idlePrefetchGeneration
        let list = photos.filter { !$0.isFolder && !$0.isParentFolder }
        guard !list.isEmpty else { return }

        // 선택 위치에서 가까운 순으로 정렬
        let currentIdx: Int
        if let selID = selectedPhotoID,
           let idx = list.firstIndex(where: { $0.id == selID }) {
            currentIdx = idx
        } else {
            currentIdx = 0
        }

        // 가까운 것부터 정렬
        let sorted = list.indices.sorted { abs($0 - currentIdx) < abs($1 - currentIdx) }

        let batchSize = 3
        func prefetchBatch(from startIdx: Int) {
            guard startIdx < sorted.count, self.idlePrefetchGeneration == gen else { return }

            // CPU/메모리 체크 — 여유 있을 때만
            let memMB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
            let currentMemMB = Self.currentAppMemoryMB()
            let memUsage = currentMemMB / memMB
            guard memUsage < 0.3 else {
                // 메모리 30% 이상 사용 중 → 10초 후 재시도
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard self?.idlePrefetchGeneration == gen else { return }
                    prefetchBatch(from: startIdx)
                }
                return
            }

            let end = min(startIdx + batchSize, sorted.count)
            DispatchQueue.global(qos: .background).async { [weak self] in
                for i in startIdx..<end {
                    // 각 preview 로드마다 autoreleasepool — background queue 의 worker thread 는
                    // main autorelease pool 과 독립이라 누적 방지 필수
                    autoreleasepool {
                        guard self?.idlePrefetchGeneration == gen else { return }
                        let photo = list[sorted[i]]
                        let url = photo.jpgURL
                        let cacheKey = PreviewLoadingPolicy.cacheKey(for: url, resolution: 0, sourceURL: url)

                        // 이미 캐시에 있으면 스킵
                        if PreviewImageCache.shared.get(cacheKey) != nil { return }

                        // 고화질 로딩 → 캐시에 저장
                        if let img = PreviewImageCache.loadOptimized(url: url, maxPixel: PreviewImageCache.optimalPreviewSize()) {
                            PreviewImageCache.shared.set(cacheKey, image: img)
                            // 썸네일 캐시에도
                            ThumbnailCache.shared.set(url, image: img)
                        }
                    }
                }

                // 다음 배치: 1초 간격 (CPU 부담 최소)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard self?.idlePrefetchGeneration == gen else { return }
                    prefetchBatch(from: end)
                }
            }
        }

        prefetchBatch(from: 0)
    }

    /// 선택 변경 시 호출 — 현재 위치 앞뒤 50장만 프리페치
    func preloadThumbnailsAroundSelection(initialLoad: Bool = false) {
        let list = filteredPhotos
        let total = list.count
        guard total > 0 else { return }

        thumbPrefetchGeneration += 1
        let gen = thumbPrefetchGeneration
        thumbsTotal = total

        // 현재 선택 위치 찾기
        let currentIdx: Int
        if let selID = selectedPhotoID,
           let idx = list.firstIndex(where: { $0.id == selID }) {
            currentIdx = idx
        } else {
            currentIdx = 0
        }

        // 윈도우: 현재 위치에서 앞뒤 100장
        let windowSize = 100
        let start = max(0, currentIdx - windowSize)
        let end = min(total, currentIdx + windowSize)

        for i in start..<end {
            let url = list[i].jpgURL
            guard !list[i].isFolder && !list[i].isParentFolder else { continue }
            // 이미 캐시에 있으면 스킵
            if ThumbnailCache.shared.get(url) != nil { continue }
            ThumbnailLoader.shared.load(url: url) { [weak self] _ in
                guard self?.thumbPrefetchGeneration == gen else { return }
            }
        }

        // 진행률 업데이트
        DispatchQueue.main.async { [weak self] in
            self?.thumbsLoaded = min(end, total)
        }
    }

    func prefetchNearby(list: [PhotoItem], centerIndex: Int, range: Int) {
        var urls: [URL] = []
        let start = max(0, centerIndex - range)
        let end = min(list.count - 1, centerIndex + range)
        guard end >= start else { return }
        for i in start...end {
            if i == centerIndex { continue }
            let url = list[i].jpgURL
            // RAW 파일은 고해상도 프리페치 스킵 (RawCamera 디모자이킹 CPU 폭발 방지)
            let ext = url.pathExtension.lowercased()
            if FileMatchingService.rawExtensions.contains(ext) { continue }
            urls.append(url)
        }
        guard !urls.isEmpty else { return }
        PreviewImageCache.shared.prefetch(urls: urls)
    }

    func prefetchThumbnailsBoth(list: [PhotoItem], centerIndex: Int, count: Int) {
        Self.thumbPrefetchQueue.cancelAllOperations()

        // 앞뒤 count장씩 수집 (가까운 것부터)
        var indices: [Int] = []
        for offset in 1...count {
            let fwd = centerIndex + offset
            let bwd = centerIndex - offset
            if fwd < list.count { indices.append(fwd) }
            if bwd >= 0 { indices.append(bwd) }
        }

        for i in indices {
            let url = list[i].jpgURL
            if ThumbnailCache.shared.get(url) != nil { continue }
            let op = BlockOperation {
                autoreleasepool {
                    // v8.8.0: ThumbnailLoader 경유 (NEF 등 RAW orientation 처리 보장)
                    if let ns = ThumbnailLoader.shared.generateThumbnailSync(url: url) {
                        ThumbnailCache.shared.set(url, image: ns)
                    }
                }
            }
            Self.thumbPrefetchQueue.addOperation(op)
        }
    }
}
