import SwiftUI
import Foundation

extension PhotoStore {
    func saveCurrentFilter(name: String) {
        let col = SmartCollection(
            name: name,
            minRating: minimumRatingFilter,
            colorLabel: colorLabelFilters.first?.rawValue ?? "없음",
            qualityFilter: qualityFilter.rawValue,
            sceneTag: sceneTagFilter,
            keyword: keywordFilter,
            searchText: searchText
        )
        savedCollections.append(col)
    }

    func applyCollection(_ col: SmartCollection) {
        minimumRatingFilter = col.minRating
        if let label = ColorLabel(rawValue: col.colorLabel), label != .none {
            colorLabelFilters = [label]
        } else {
            colorLabelFilters = []
        }
        qualityFilter = QualityFilter(rawValue: col.qualityFilter) ?? .all
        sceneTagFilter = col.sceneTag
        keywordFilter = col.keyword
        searchText = col.searchText
    }

    func deleteCollection(_ id: UUID) {
        savedCollections.removeAll { $0.id == id }
    }

    func saveCollections() {
        if let data = try? JSONEncoder().encode(savedCollections) {
            UserDefaults.standard.set(data, forKey: "smartCollections")
        }
    }

    func loadCollections() {
        guard let data = UserDefaults.standard.data(forKey: "smartCollections"),
              let cols = try? JSONDecoder().decode([SmartCollection].self, from: data) else { return }
        savedCollections = cols
    }

    // MARK: - System Auto-Optimization on First Launch

    func autoOptimizeOnFirstLaunch() {
        let key = "hasOptimized_v6"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        let isAppleSilicon = ProcessInfo.processInfo.processorCount >= 8

        // 썸네일 표시 크기는 100px 고정 (생성 픽셀 200px이면 Retina 충분)
        UserDefaults.standard.set(Double(100), forKey: "savedThumbnailSize")
        UserDefaults.standard.set(100.0, forKey: "defaultThumbnailSize")
        thumbnailSize = 100

        if ramGB >= 64 && isAppleSilicon {
            UserDefaults.standard.set("original", forKey: "previewMaxResolution")
            UserDefaults.standard.set(30.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(4.0, forKey: "thumbnailCacheMaxGB")
            previewResolution = 0
        } else if ramGB >= 32 {
            UserDefaults.standard.set("original", forKey: "previewMaxResolution")
            UserDefaults.standard.set(25.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(3.0, forKey: "thumbnailCacheMaxGB")
            previewResolution = 0
        } else if ramGB >= 16 {
            UserDefaults.standard.set("original", forKey: "previewMaxResolution")
            UserDefaults.standard.set(15.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(1.5, forKey: "thumbnailCacheMaxGB")
            previewResolution = 0
        } else {
            UserDefaults.standard.set("3000", forKey: "previewMaxResolution")
            UserDefaults.standard.set(10.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(0.5, forKey: "thumbnailCacheMaxGB")
            previewResolution = 3000
        }

        UserDefaults.standard.set(true, forKey: key)
        fputs("[OPT] 첫 실행 자동 최적화 완료 — RAM: \(ramGB)GB, AppleSilicon: \(isAppleSilicon)\n", stderr)
    }

    /// Settings 창에서 변경된 값을 라이브 프로퍼티에 동기화
    func applySettingsFromDefaults() {
        // 썸네일 크기: defaultThumbnailSize → savedThumbnailSize + thumbnailSize
        let newThumbSize = UserDefaults.standard.double(forKey: "defaultThumbnailSize")
        if newThumbSize > 0 {
            thumbnailSize = CGFloat(newThumbSize)
        }
        // 미리보기 해상도: previewMaxResolution → previewResolution
        let resStr = UserDefaults.standard.string(forKey: "previewMaxResolution") ?? "original"
        previewResolution = (resStr == "original") ? 0 : (Int(resStr) ?? 0)
    }
}
