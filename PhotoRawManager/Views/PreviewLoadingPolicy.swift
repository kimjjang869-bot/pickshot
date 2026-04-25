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

    static func cacheKey(for url: URL, resolution: Int) -> URL {
        resolution > 0
            ? url.appendingPathExtension("r\(resolution)")
            : url.appendingPathExtension("orig")
    }

    static func decodeURL(for url: URL, selectedPhoto: PhotoItem?, allPhotos: [PhotoItem]) -> URL {
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
        let stage1 = isKeyRepeat ? min(1000, SystemSpec.shared.previewStage1MaxPixel())
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
        let stage1 = isKeyRepeat ? min(1000, SystemSpec.shared.previewStage1MaxPixel())
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
    static func shouldAutoLoadHiRes(fastCullingMode: Bool) -> Bool {
        true
    }

    static func hiResDelay(isKeyRepeat: Bool, alreadyCached: Bool, tier: PerformanceTier) -> TimeInterval {
        if alreadyCached { return 0 }
        if isKeyRepeat { return 1.2 }
        return tier == .low ? 0.7 : 0.45
    }

    /// fastCullingMode 에서 현재 사진 hi-res 까지 추가 delay (nav 도중 디코드 시작 회피)
    static func hiResDelayFastCulling() -> TimeInterval {
        0.9
    }

    static func embeddedNeighborRangeDuringKeyRepeat() -> Int {
        2
    }

    static func shouldPrefetchHiRes(isKeyRepeat: Bool, fastCullingMode: Bool) -> Bool {
        !isKeyRepeat && !fastCullingMode
    }

    static func hiResURL(for photo: PhotoItem) -> URL {
        photo.displayURL
    }
}
