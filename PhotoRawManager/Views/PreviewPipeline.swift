import Foundation
import AppKit

/// Executes the progressive preview decode pipeline.
///
/// PhotoPreviewView owns UI state. This type owns the heavy "how do we decode and cache it"
/// workflow so navigation can stay small and predictable.
enum PreviewPipeline {
    struct Context {
        let url: URL
        let decodeURL: URL
        let cacheKey: URL
        let photoID: UUID
        let resolution: Int
        let fileName: String
        let startedAt: CFAbsoluteTime
        let fastCullingMode: Bool
        let currentFolderIsSlowDisk: Bool
        let isKeyRepeat: Bool
        let stage1Portrait: Bool?
        let isCurrent: () -> Bool
        let notePreviewLoaded: (URL) -> Void
        let onStage1Portrait: (Bool) -> Void
        let onDisplayImage: (NSImage) -> Void
        let onSchedulePreload: () -> Void
    }

    static func run(_ context: Context) {
        guard context.isCurrent() else { return }

        let ext = context.decodeURL.pathExtension.lowercased()
        let isJPG = ["jpg", "jpeg"].contains(ext)

        if isJPG {
            runJPG(context)
        } else {
            runRAW(context)
        }

        guard context.isCurrent() else { return }
        DispatchQueue.main.async {
            guard context.isCurrent() else { return }
            context.onSchedulePreload()
        }
    }

    private static func runJPG(_ context: Context) {
        let stagePlan = PreviewLoadingPolicy.jpgStagePlan(resolution: context.resolution, isKeyRepeat: context.isKeyRepeat)
        let s1Trace = LoadTrace()
        let fastImage = PreviewImageCache.loadOptimized(
            url: context.decodeURL,
            maxPixel: stagePlan.stage1MaxPixel,
            trace: s1Trace
        )
        guard context.isCurrent() else { return }

        if let fast = fastImage {
            let ms1Double = (CFAbsoluteTimeGetCurrent() - context.startedAt) * 1000
            let ms1 = Int(ms1Double)
            let sizeMB = Double(s1Trace.fileSizeBytes) / 1_048_576.0
            let stratDesc = s1Trace.strategy == "subsample" ? "subsample=\(s1Trace.subsample)" : s1Trace.strategy
            fputs("[LD] JPG-S1 \(context.fileName) \(Int(fast.size.width))x\(Int(fast.size.height)) \(ms1)ms size=\(String(format: "%.1f", sizeMB))MB strat=\(stratDesc) orig=\(s1Trace.origPx)px\n", stderr)
            ProgressiveLoadStats.shared.record(bucket: "JPG-S1-\(s1Trace.strategy)", ms: ms1Double)

            ThumbnailCache.shared.set(context.url, image: fast)
            DispatchQueue.main.async {
                guard context.isCurrent() else { return }
                context.onDisplayImage(fast)
            }

            if !stagePlan.needsStage2 || context.fastCullingMode || context.isKeyRepeat {
                let s1Ms = (CFAbsoluteTimeGetCurrent() - context.startedAt) * 1000
                PreviewImageCache.shared.setIfSlow(context.cacheKey, image: fast, decodeMs: s1Ms, force: true)
                context.notePreviewLoaded(context.url)
                return
            }
        }

        guard context.isCurrent() else { return }
        if context.currentFolderIsSlowDisk, let fastImage {
            let s1Ms = (CFAbsoluteTimeGetCurrent() - context.startedAt) * 1000
            PreviewImageCache.shared.setIfSlow(context.cacheKey, image: fastImage, decodeMs: s1Ms, force: true)
            context.notePreviewLoaded(context.url)
            return
        }

        let s2Trace = LoadTrace()
        let s2Start = CFAbsoluteTimeGetCurrent()
        let full = PreviewImageCache.loadOptimized(
            url: context.decodeURL,
            maxPixel: stagePlan.finalMaxPixel,
            trace: s2Trace
        ) ?? (context.resolution == 0 ? NSImage(contentsOf: context.decodeURL) : nil)
        guard context.isCurrent() else { return }

        guard let loaded = full else {
            if let fast = fastImage {
                let s1Ms = (CFAbsoluteTimeGetCurrent() - context.startedAt) * 1000
                PreviewImageCache.shared.setIfSlow(context.cacheKey, image: fast, decodeMs: s1Ms, force: true)
                context.notePreviewLoaded(context.url)
            }
            return
        }

        let totalMs = (CFAbsoluteTimeGetCurrent() - context.startedAt) * 1000
        let s2OnlyMs = (CFAbsoluteTimeGetCurrent() - s2Start) * 1000
        let s2Strat = s2Trace.strategy == "subsample" ? "subsample=\(s2Trace.subsample)" : s2Trace.strategy
        fputs("[LD] JPG-S2 \(context.fileName) \(Int(loaded.size.width))x\(Int(loaded.size.height)) total=\(Int(totalMs))ms s2only=\(Int(s2OnlyMs))ms strat=\(s2Strat)\n", stderr)
        ProgressiveLoadStats.shared.record(bucket: "JPG-S2-\(s2Trace.strategy)", ms: s2OnlyMs)
        ProgressiveLoadStats.shared.record(bucket: "JPG-total", ms: totalMs)

        PreviewImageCache.shared.setIfSlow(context.cacheKey, image: loaded, decodeMs: totalMs)
        context.notePreviewLoaded(context.url)
        ThumbnailCache.shared.set(context.url, image: loaded)
        DispatchQueue.main.async {
            guard context.isCurrent() else { return }
            context.onDisplayImage(loaded)
        }
    }

    private static func runRAW(_ context: Context) {
        let stagePlan = PreviewLoadingPolicy.rawStagePlan(resolution: context.resolution, isKeyRepeat: context.isKeyRepeat)
        guard let fast = PreviewImageCache.loadOptimized(
            url: context.decodeURL,
            maxPixel: min(stagePlan.stage1MaxPixel, stagePlan.finalMaxPixel)
        ) else {
            // v9.0: RAW 디코드 실패 (손상/지원 안되는 포맷/권한 등) — 무음 return 대신 로그.
            //   notePreviewLoaded 호출해 카운터는 진행하고 (deadlock 방지) stderr 로그 남김.
            fputs("[LD] RAW-FAIL \(context.fileName) — decode failed (corrupted/unsupported)\n", stderr)
            DispatchQueue.main.async {
                context.notePreviewLoaded(context.url)
            }
            return
        }
        guard context.isCurrent() else { return }

        let ms1 = Int((CFAbsoluteTimeGetCurrent() - context.startedAt) * 1000)
        let dinfo = PhotoPreviewView.readImageDimensionInfo(url: context.url)
        fputs("[LD] RAW-S1 \(context.fileName) loaded=\(Int(fast.size.width))x\(Int(fast.size.height)) raw=\(Int(dinfo?.size.width ?? 0))x\(Int(dinfo?.size.height ?? 0)) orient=\(dinfo?.orientation ?? -1) \(ms1)ms\n", stderr)

        DispatchQueue.main.async {
            guard context.isCurrent() else { return }
            context.onStage1Portrait(fast.size.height > fast.size.width)
            context.onDisplayImage(fast)
        }

        ThumbnailCache.shared.set(context.url, image: fast)
        context.notePreviewLoaded(context.url)

        guard context.isCurrent() else { return }
        if context.isKeyRepeat {
            fputs("[LD] RAW-S2 SKIP (key repeat) \(context.fileName)\n", stderr)
            PreviewImageCache.shared.set(context.cacheKey, image: fast)
            return
        }

        guard stagePlan.needsStage2,
              let hr = PreviewImageCache.loadOptimized(url: context.decodeURL, maxPixel: stagePlan.finalMaxPixel) else {
            PreviewImageCache.shared.set(context.cacheKey, image: fast)
            return
        }
        guard context.isCurrent() else { return }

        let finalHR = PhotoPreviewView.enforceAspectOfStage1(
            hr,
            url: context.url,
            stage1Portrait: fast.size.height > fast.size.width
        )
        fputs("[LD] RAW-S2 \(context.fileName) loaded=\(Int(hr.size.width))x\(Int(hr.size.height)) → \(Int(finalHR.size.width))x\(Int(finalHR.size.height)) stage2Px=\(Int(stagePlan.finalMaxPixel))\n", stderr)
        PreviewImageCache.shared.set(context.cacheKey, image: finalHR)
        DispatchQueue.main.async {
            guard context.isCurrent() else { return }
            context.onDisplayImage(finalHR)
        }
    }
}
