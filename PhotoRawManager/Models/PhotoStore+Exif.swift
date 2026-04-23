import SwiftUI
import Foundation
import ImageIO
import CoreLocation

extension PhotoStore {
    // MARK: - 주변 썸네일 프리로딩 (키보드 이동 시 빈 썸네일 방지)

    func prefetchNearbyThumbnails() {
        // 디바운스 짧게 (10ms) — 빠른 연타 시 마지막 한 번만, 단일 이동은 즉시
        prefetchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let id = self.selectedPhotoID else { return }
            let list = self.filteredPhotos
            self.ensureFilteredIndex()
            guard let idx = self._filteredIndex[id] else { return }

            // ±30장 (총 60장) 임베디드 JPEG 직접 추출 → ThumbnailCache 적재
            // ThumbnailLoader 우회: 내부 lock/queue 경합 회피 + 풀 디코드 방지
            let start = max(0, idx - 30)
            let end = min(list.count - 1, idx + 30)
            guard start <= end else { return }

            var toLoad: [URL] = []
            for i in start...end {
                let photo = list[i]
                guard !photo.isFolder && !photo.isParentFolder else { continue }
                if ThumbnailCache.shared.get(photo.jpgURL) == nil {
                    toLoad.append(photo.jpgURL)
                }
            }

            // 8-way concurrent 추출
            let concurrentQueue = DispatchQueue(label: "thumb.nearby.prefetch", qos: .userInitiated, attributes: .concurrent)
            for url in toLoad.prefix(60) {
                concurrentQueue.async {
                    autoreleasepool {
                        if ThumbnailCache.shared.get(url) != nil { return }
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                              let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                                kCGImageSourceThumbnailMaxPixelSize: 400,
                                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                                kCGImageSourceCreateThumbnailWithTransform: true
                              ] as CFDictionary) else { return }
                        let img = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
                        ThumbnailCache.shared.set(url, image: img)
                    }
                }
            }
        }
        prefetchWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.01, execute: work)
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
                self?.photosVersion += 1
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
        fputs("[EXIF] loadIfNeeded: \(photos[idx].fileName)\n", stderr)

        exifLoadingIDs.insert(photoID)
        let url = photos[idx].jpgURL
        let fileName = url.lastPathComponent
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let exif = ExifService.extractExif(from: url) else {
                fputs("[EXIF] FAIL \(fileName)\n", stderr)
                DispatchQueue.main.async { self?.exifLoadingIDs.remove(photoID) }
                return
            }
            fputs("[EXIF] OK \(fileName) lens=\(exif.lensModel ?? "nil") w=\(exif.imageWidth ?? 0)\n", stderr)
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
                    self?.photosVersion += 1
                }
                self.exifBatchWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
    }

    /// 목록뷰 전환 시 전체 EXIF 배치 로딩
    func triggerListExifLoad() {
        let needExif = photos.filter { !$0.isFolder && !$0.isParentFolder && $0.exifData == nil }.count
        fputs("[EXIF] triggerListExifLoad: need=\(needExif), version=\(photosVersion), last=\(lastExifLoadVersion)\n", stderr)
        guard lastExifLoadVersion != photosVersion else { return }
        lastExifLoadVersion = photosVersion
        guard needExif > 0 else { return }
        batchLoadExif(count: photos.count)
    }

    func preloadAllThumbnails() {
        guard shouldRunBackgroundPrefetch else { return }
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
        if isNetwork { radius = 30 }       // NAS: 현재 화면 주변만 prewarm
        else if isSlow { radius = 100 }    // 외장 HDD
        else { radius = 40 }               // SSD
        let start = max(0, currentIdx - radius)
        let end = min(list.count, currentIdx + radius)
        guard start < end else { return }

        let urls = (start..<end).sorted { abs($0 - currentIdx) < abs($1 - currentIdx) }.map { list[$0].jpgURL }
        let gen = idlePrefetchGeneration

        // HDD: prewarming concurrency 2로 제한 — visible 로딩(ThumbnailLoader 6-way)과 디스크 경합 최소화
        // (HDD에서 동시 8+ way seek은 NCQ 한계 초과 → 모두 느려짐)
        // SSD: tier 기반 (low=2, standard=3, high=4)
        let concurrency = isSlow ? 2 : SystemSpec.shared.ssdThumbnailConcurrency()
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
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceThumbnailMaxPixelSize: 400,
                            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                            kCGImageSourceCreateThumbnailWithTransform: true
                          ] as CFDictionary) else { return }
                    let img = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
                    ThumbnailCache.shared.set(url, image: img)
                }
            }
        }
    }

    func startIdlePreviewPrefetch() {
        guard shouldRunBackgroundPrefetch else { return }
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
            guard self.shouldRunBackgroundPrefetch else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard self?.idlePrefetchGeneration == gen else { return }
                    prefetchBatch(from: startIdx)
                }
                return
            }

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
                        let cacheKey = url.appendingPathExtension("orig")

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
        guard shouldRunBackgroundPrefetch else { return }
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

        let forwardWindow = lastScrollDirection >= 0 ? 130 : 70
        let backwardWindow = lastScrollDirection >= 0 ? 50 : 110
        let start = max(0, currentIdx - backwardWindow)
        let end = min(total, currentIdx + forwardWindow)

        for i in start..<end {
            let url = list[i].jpgURL
            guard !list[i].isFolder && !list[i].isParentFolder else { continue }
            // 이미 캐시에 있으면 스킵
            if ThumbnailCache.shared.get(url) != nil { continue }
            guard thumbPrefetchGeneration == gen else { continue }
            ThumbnailLoader.shared.prefetch(url: url)
        }

        // 진행률 업데이트
        DispatchQueue.main.async { [weak self] in
            self?.thumbsLoaded = min(end, total)
        }
    }

    func prefetchNearby(list: [PhotoItem], centerIndex: Int, range: Int) {
        guard shouldRunBackgroundPrefetch else { return }
        var urls: [URL] = []
        let forwardRange = lastScrollDirection >= 0 ? Int(Double(range) * 1.5) : range
        let backwardRange = lastScrollDirection >= 0 ? max(1, range / 2) : Int(Double(range) * 1.5)
        let start = max(0, centerIndex - backwardRange)
        let end = min(list.count - 1, centerIndex + forwardRange)
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
        guard shouldRunBackgroundPrefetch else { return }
        Self.thumbPrefetchQueue.cancelAllOperations()

        // 앞뒤 count장씩 수집 (가까운 것부터)
        var indices: [Int] = []
        let forwardCount = lastScrollDirection >= 0 ? Int(Double(count) * 1.6) : count
        let backwardCount = lastScrollDirection >= 0 ? max(1, count / 2) : Int(Double(count) * 1.6)
        let maxOffset = max(forwardCount, backwardCount)
        for offset in 1...maxOffset {
            if offset <= forwardCount {
                let fwd = centerIndex + offset
                if fwd < list.count { indices.append(fwd) }
            }
            if offset <= backwardCount {
                let bwd = centerIndex - offset
                if bwd >= 0 { indices.append(bwd) }
            }
        }

        for i in indices {
            let url = list[i].jpgURL
            if ThumbnailCache.shared.get(url) != nil { continue }
            let op = BlockOperation {
                autoreleasepool {
                    let opts: [NSString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: 1200,
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ]
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
                    let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    ThumbnailCache.shared.set(url, image: ns)
                }
            }
            Self.thumbPrefetchQueue.addOperation(op)
        }
    }
}
