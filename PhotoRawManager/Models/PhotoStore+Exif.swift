import SwiftUI
import Foundation
import ImageIO
import CoreLocation

extension PhotoStore {
    // MARK: - 주변 썸네일 프리로딩 (키보드 이동 시 빈 썸네일 방지)

    func prefetchNearbyThumbnails() {
        // 디바운스: 빠른 키 연타 시 마지막 한 번만 실행
        prefetchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let id = self.selectedPhotoID else { return }
            let list = self.filteredPhotos
            self.ensureFilteredIndex()
            guard let idx = self._filteredIndex[id] else { return }

            // 앞뒤 20장 중 메모리 캐시 미스만 로딩
            let start = max(0, idx - 20)
            let end = min(list.count - 1, idx + 20)
            guard start <= end else { return }

            var toLoad: [URL] = []
            for i in start...end {
                let photo = list[i]
                guard !photo.isFolder && !photo.isParentFolder else { continue }
                if ThumbnailCache.shared.get(photo.jpgURL) == nil {
                    toLoad.append(photo.jpgURL)
                }
            }

            // 최대 10장만 큐에 추가 (과도한 큐 적재 방지)
            for url in toLoad.prefix(10) {
                ThumbnailLoader.shared.load(url: url) { _ in }
            }
        }
        prefetchWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05, execute: work)
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
        thumbsTotal = photos.filter { !$0.isFolder && !$0.isParentFolder }.count
        thumbsLoaded = thumbsTotal
    }

    func startIdlePreviewPrefetch() {
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
                    guard self?.idlePrefetchGeneration == gen else { return }
                    let photo = list[sorted[i]]
                    let url = photo.jpgURL
                    let cacheKey = url.appendingPathExtension("orig")

                    // 이미 캐시에 있으면 스킵
                    if PreviewImageCache.shared.get(cacheKey) != nil { continue }

                    // 고화질 로딩 → 캐시에 저장
                    if let img = PreviewImageCache.loadOptimized(url: url, maxPixel: PreviewImageCache.optimalPreviewSize()) {
                        PreviewImageCache.shared.set(cacheKey, image: img)
                        // 썸네일 캐시에도
                        ThumbnailCache.shared.set(url, image: img)
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
            Self.thumbPrefetchQueue.addOperation(op)
        }
    }
}
