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

        let spec = SystemSpec.shared
        let ramGB = spec.ramGB
        let isAppleSilicon = spec.isAppleSilicon

        // 썸네일 표시 크기는 100px 고정 (생성 픽셀 200px이면 Retina 충분)
        UserDefaults.standard.set(Double(100), forKey: "savedThumbnailSize")
        UserDefaults.standard.set(100.0, forKey: "defaultThumbnailSize")
        thumbnailSize = 100

        // SystemSpec tier 기반 자동 최적화 (중앙화)
        let previewMax = spec.previewMaxPixel()
        switch spec.effectiveTier {
        case .extreme:
            UserDefaults.standard.set("original", forKey: "previewMaxResolution")
            UserDefaults.standard.set(30.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(4.0, forKey: "thumbnailCacheMaxGB")
            previewResolution = 0
        case .high:
            UserDefaults.standard.set("original", forKey: "previewMaxResolution")
            UserDefaults.standard.set(25.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(3.0, forKey: "thumbnailCacheMaxGB")
            previewResolution = 0
        case .standard:
            UserDefaults.standard.set("original", forKey: "previewMaxResolution")
            UserDefaults.standard.set(15.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(1.5, forKey: "thumbnailCacheMaxGB")
            previewResolution = 0
        case .low:
            // MBA 8GB 등 저사양: 500px 미리보기 × 50장 캐시 + 2GB 썸네일 캐시
            // (기존 3000px × 10장 × 0.5GB 는 첫 폴더는 부드럽지만 다음 폴더부터 체감 느려짐 —
            //  500px 로 줄이면 한 장당 메모리가 훨씬 작아서 많이 캐시 가능 → 폴더 이동 쾌적)
            UserDefaults.standard.set("500", forKey: "previewMaxResolution")
            UserDefaults.standard.set(50.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(2.0, forKey: "thumbnailCacheMaxGB")
            previewResolution = 500
        }

        UserDefaults.standard.set(true, forKey: key)
        fputs("[OPT] 첫 실행 자동 최적화 완료 — tier: \(spec.effectiveTier.rawValue), RAM: \(ramGB)GB, AppleSilicon: \(isAppleSilicon)\n", stderr)
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
