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
        // v8.6.2: 기존 사용자가 구 기본값 그대로면 새 기본값(1000px / 50장 / 2GB) 으로 마이그레이션
        migrateToV8_6_2DefaultsIfNeeded()

        let key = "hasOptimized_v6"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let spec = SystemSpec.shared
        let ramGB = spec.ramGB
        let isAppleSilicon = spec.isAppleSilicon

        // 썸네일 표시 크기는 100px 고정 (생성 픽셀 200px이면 Retina 충분)
        UserDefaults.standard.set(Double(100), forKey: "savedThumbnailSize")
        UserDefaults.standard.set(100.0, forKey: "defaultThumbnailSize")
        thumbnailSize = 100

        // PR fix: MBA(저사양) 기본값을 SystemSpec tier 기반으로 자동 분기.
        //   기존 통일 기본값(1000px × 50장)은 8GB MBA 에서 OOM/렉 유발 → tier 별 분기 복원.
        let previewMax = spec.previewMaxPixel()
        _ = previewMax
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
            // MBA 8GB 등 저사양: 500px × 50장 + 2GB 썸네일 캐시
            UserDefaults.standard.set("500", forKey: "previewMaxResolution")
            UserDefaults.standard.set(50.0, forKey: "previewCacheSize")
            UserDefaults.standard.set(2.0, forKey: "thumbnailCacheMaxGB")
            previewResolution = 500
        }

        UserDefaults.standard.set(true, forKey: key)
        fputs("[OPT] 첫 실행 자동 최적화 완료 — tier: \(spec.effectiveTier.rawValue), RAM: \(ramGB)GB, AppleSilicon: \(isAppleSilicon)\n", stderr)
    }

    /// v8.6.2: 기존 사용자가 구 tier-기반 기본값 그대로 쓰고 있으면 새 기본값으로 업데이트.
    /// 사용자가 Settings 에서 의도적으로 변경했으면 유지 (값이 구 기본값이 아니면 건드리지 않음).
    /// v8.6.2 (late): 디스크 캐시 cap 은 0(자동) 으로 변경 — macOS isPurgeable 로 자동 관리.
    private func migrateToV8_6_2DefaultsIfNeeded() {
        let migrationKey = "migratedTo_v8_6_2_defaults_rev2"  // 개정: 디스크 cap 재조정
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let d = UserDefaults.standard
        // 구 기본값 셋 (이 중 하나와 일치하면 "사용자 미변경" 으로 간주)
        let oldPreviewRes: Set<String> = ["original", "500"]
        let oldPreviewCache: Set<Double> = [15.0, 20.0, 25.0, 30.0, 50.0]
        let oldThumbDiskGB: Set<Double> = [0.5, 1.5, 2.0, 3.0, 4.0]

        let curRes = d.string(forKey: "previewMaxResolution") ?? "original"
        let curCache = d.double(forKey: "previewCacheSize")
        let curDisk = d.double(forKey: "thumbnailCacheMaxGB")

        if oldPreviewRes.contains(curRes) {
            d.set("1000", forKey: "previewMaxResolution")
            previewResolution = 1000
        }
        if oldPreviewCache.contains(curCache) || curCache == 0 {
            d.set(50.0, forKey: "previewCacheSize")
        }
        // 디스크 cap: 구 값이든 신규 2GB 기본값이든 모두 "자동(0)" 으로 마이그레이션.
        // macOS 가 isPurgeable 플래그로 자동 관리하므로 앱 측 하드 캡 불필요.
        if oldThumbDiskGB.contains(curDisk) || curDisk == 2.0 || curDisk == 0 {
            d.set(0.0, forKey: "thumbnailCacheMaxGB")
        }
        d.set(true, forKey: migrationKey)
        fputs("[OPT] v8.6.2 기본값 마이그레이션 완료 — 디스크 캐시는 macOS 자동 관리로 전환\n", stderr)
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
