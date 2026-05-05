import Foundation
import AppKit

/// Centralizes preview navigation policy so PhotoPreviewView can focus on state updates.
/// The rule of thumb is FastRawViewer-style culling: navigation stays light, hi-res work waits.
enum PreviewLoadingPolicy {
    struct StagePlan {
        let stage1MaxPixel: CGFloat
        let finalMaxPixel: CGFloat
        let needsStage2: Bool
    }

    static func cacheKey(for url: URL, resolution: Int, sourceURL: URL? = nil) -> URL {
        let source = sourceURL ?? url
        let sourceExt = source.pathExtension.lowercased()
        let sourceTag: String
        if source == url {
            sourceTag = "src-self-\(sourceExt.isEmpty ? "none" : sourceExt)"
        } else if FileMatchingService.rawExtensions.contains(sourceExt) {
            sourceTag = "src-raw-\(sourceExt)"
        } else {
            sourceTag = "src-\(sourceExt.isEmpty ? "file" : sourceExt)"
        }

        let namespaced = url.appendingPathExtension(sourceTag)
        return resolution > 0
            ? namespaced.appendingPathExtension("r\(resolution)")
            : namespaced.appendingPathExtension("orig")
    }

    static func previewSourceURL(for photo: PhotoItem) -> URL {
        let jpgExt = photo.jpgURL.pathExtension.lowercased()
        let jpgIsRAW = FileMatchingService.rawExtensions.contains(jpgExt)

        // RAW-only 항목은 RAW/embedded preview 경로가 맞다.
        guard !jpgIsRAW else {
            return photo.rawURL ?? photo.jpgURL
        }

        // RAW+JPG 페어는 카메라가 만든 JPG를 우선한다.
        // 이 JPG가 카메라 Picture Profile/Creative Look 색감을 가장 정확히 담고 있고,
        // RAW demosaic/CIRAW 경로로 바뀌면 사용자가 보는 색이 달라진다.
        if UserDefaults.standard.bool(forKey: "preferRAWOverJPG"),
           let raw = photo.rawURL,
           raw != photo.jpgURL {
            return raw
        }
        return photo.jpgURL
    }

    /// 레거시 시그니처 — fallback 선형 탐색. 새 호출처는 `decodeURL(for:store:)` 권장.
    static func decodeURL(for url: URL, selectedPhoto: PhotoItem?, allPhotos: [PhotoItem]) -> URL {
        if let selectedPhoto, selectedPhoto.jpgURL == url {
            return previewSourceURL(for: selectedPhoto)
        }
        if let photo = allPhotos.first(where: { $0.jpgURL == url }) {
            return previewSourceURL(for: photo)
        }
        return url
    }

    /// v9.1.4: store 인스턴스를 직접 받아 O(1) 인덱스 룩업 (`store._urlIndex`).
    ///   nav 마다 호출되므로 17,000장 폴더에서 first(where:) 비용 제거.
    static func decodeURL(for url: URL, store: PhotoStore) -> URL {
        if let selected = store.selectedPhoto, selected.jpgURL == url {
            return previewSourceURL(for: selected)
        }
        if let idx = store._urlIndex[url], idx < store.photos.count {
            return previewSourceURL(for: store.photos[idx])
        }
        return url
    }

    static func usesRAWPreviewSource(_ photo: PhotoItem) -> Bool {
        previewSourceURL(for: photo) != photo.jpgURL
    }

    static func stableSizeURL(for photo: PhotoItem) -> URL {
        previewSourceURL(for: photo)
    }

    static func hiResURL(for photo: PhotoItem) -> URL {
        previewSourceURL(for: photo)
    }

    static func legacyRAWDecodeURL(for url: URL, selectedPhoto: PhotoItem?, allPhotos: [PhotoItem]) -> URL {
        if let selectedPhoto,
           selectedPhoto.jpgURL == url,
           let raw = selectedPhoto.rawURL,
           raw != url {
            return raw
        }

        for photo in allPhotos where photo.jpgURL == url {
            if let raw = photo.rawURL, raw != url { return raw }
            break
        }
        return url
    }

    static func jpgStagePlan(resolution: Int, isKeyRepeat: Bool = false) -> StagePlan {
        // v8.9.6: 키 리피트 중엔 stage1 을 작게 (디코드 ~30% 단축) → 횡이동 반응성 향상.
        //   키 멈추면 일반 stage1, 그 후 hi-res 로 풀 화질 승격.
        let stage1 = isKeyRepeat ? min(720, SystemSpec.shared.previewStage1MaxPixel())
                                 : SystemSpec.shared.previewStage1MaxPixel()
        let final = resolution > 0
            ? CGFloat(resolution)
            : SystemSpec.shared.previewStage2MaxPixel()
        return StagePlan(
            stage1MaxPixel: stage1,
            finalMaxPixel: final,
            needsStage2: final > stage1 * 1.2
        )
    }

    static func rawStagePlan(resolution: Int, isKeyRepeat: Bool = false) -> StagePlan {
        let stage1 = isKeyRepeat ? min(720, SystemSpec.shared.previewStage1MaxPixel())
                                 : SystemSpec.shared.previewStage1MaxPixel()
        let optimal = resolution > 0
            ? CGFloat(resolution)
            : PreviewImageCache.optimalPreviewSize()
        let configuredStage2 = SystemSpec.shared.previewStage2MaxPixel()
        let final = configuredStage2 == 0 ? optimal : configuredStage2
        return StagePlan(
            stage1MaxPixel: stage1,
            finalMaxPixel: final,
            needsStage2: final > stage1
        )
    }

    static func shouldPurgeHiResOnSelection(isKeyRepeat: Bool) -> Bool {
        !isKeyRepeat
    }

    // v8.9.6: fastCullingMode 에서도 현재 사진은 hi-res 로 올린다 (FRV 패턴).
    //   이전엔 fastCullingMode 면 영영 hi-res 안 올라 5K 화면에서 임베디드 1616px 흐릿하게 보였음.
    //   neighbor prefetch 는 여전히 shouldPrefetchHiRes 로 차단.
    // v9.1: 슈퍼 셀렉 모드 ON 시 자동 hi-res 차단 (Stage 2 까지만).
    //   사용자 명시 줌/100% (loadHiResForZoom forceDeepScan) 은 별도 경로라 통과.
    static func shouldAutoLoadHiRes(fastCullingMode: Bool) -> Bool {
        if SuperCullMode.isActive { return false }
        return true
    }

    static func hiResDelay(isKeyRepeat: Bool, alreadyCached: Bool, tier: PerformanceTier) -> TimeInterval {
        if alreadyCached { return 0 }
        // v8.9.7+: hi-res 표시 시간 단축. 키 멈춤 후 80ms idle + 짧은 delay.
        // v9.1.4: 일반 클릭(non-keyRepeat) 은 0ms — 캐시 미스 시 1~2초 체감 단축.
        //   stage1 표시 직후 곧바로 hi-res 디코드 시작.
        if isKeyRepeat { return 0.1 }
        return tier == .low ? 0.05 : 0
    }

    /// fastCullingMode 에서 현재 사진 hi-res 까지 추가 delay (nav 도중 디코드 시작 회피)
    static func hiResDelayFastCulling() -> TimeInterval {
        0.25
    }

    static func embeddedNeighborRangeDuringKeyRepeat() -> Int {
        // v8.9.7: ↓/↑ 행이동은 +cols(5장) 점프 — ±2 로는 burst 동안 계속 미스. 폴더 cols*2 까지 미리 채움.
        switch SystemSpec.shared.effectiveTier {
        case .low: return 4
        case .standard: return 6
        case .high: return 10
        case .extreme: return 12
        }
    }

    static func shouldPrefetchHiRes(isKeyRepeat: Bool, fastCullingMode: Bool) -> Bool {
        !isKeyRepeat && !fastCullingMode
    }

    /// 키를 누른 채 이동 중에는 다음/이전 사진의 "화면용 프리뷰"까지 만들지 않는다.
    /// 그 작업은 선택이 멈춘 뒤 최종 사진 1장에만 맡기고, 이동 중 이웃은 작은 썸네일 캐시만 채운다.
    static func keyRepeatNeighborThumbnailMaxPixel() -> CGFloat {
        switch SystemSpec.shared.effectiveTier {
        case .low: return 640
        case .standard: return 720
        case .high: return 800
        case .extreme: return 900
        }
    }

}
