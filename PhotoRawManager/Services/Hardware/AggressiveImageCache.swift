//
//  AggressiveImageCache.swift
//  PhotoRawManager
//
//  SystemSpec tier 기반 적응형 이미지 NSCache. 메모리 압박(warning/critical)
//  이벤트를 감지해 자동으로 캐시를 해제한다.
//

import Foundation
import AppKit

// MARK: - Aggressive Memory Cache

/// High-performance memory pool for frequently accessed images.
/// RAM 기반 적응형 cost limit + 메모리 압박 시 자동 해제.
class AggressiveImageCache {
    static let shared = AggressiveImageCache()

    private let cache = NSCache<NSURL, NSImage>()
    private let lock = NSLock()
    // 메모리 압박 감지 소스 (warning/critical 시 캐시 해제)
    private var pressureSource: DispatchSourceMemoryPressure?

    init() {
        // SystemSpec tier 기반 적응형 cost limit (과거 계단식 RAM 분기 → 중앙화)
        // 16GB M1 Pro = standard tier → 200MB (기존 300MB에서 더 축소해 peak 방지)
        let limitMB = SystemSpec.shared.aggressiveCacheLimitMB()
        cache.totalCostLimit = limitMB * 1024 * 1024

        // 엔트리 수 제한: 5000 → 1000 (M1 Pro 4K 썸네일 기준 ~200MB/1000장)
        cache.countLimit = 1000

        let tier = SystemSpec.shared.effectiveTier.rawValue
        let ramGB = SystemSpec.shared.ramGB
        AppLogger.log(.general, "🧠 AggressiveImageCache 초기화: \(limitMB)MB limit, countLimit=1000 (tier=\(tier), RAM \(ramGB)GB)")

        // 메모리 압박 핸들러 등록
        setupMemoryPressureHandler()
    }

    deinit {
        pressureSource?.cancel()
    }

    /// 메모리 압박 이벤트 수신 시 캐시를 해제한다.
    private func setupMemoryPressureHandler() {
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = src.data
            if event.contains(.critical) {
                self.cache.removeAllObjects()
                AppLogger.log(.general, "🆘 AggressiveImageCache 전체 해제 (critical)")
            } else if event.contains(.warning) {
                // 단순화: 경고 단계에서도 전량 해제 (NSCache 재채움이 빠름)
                self.cache.removeAllObjects()
                AppLogger.log(.general, "⚠️ AggressiveImageCache 해제 (warning)")
            }
        }
        src.resume()
        self.pressureSource = src
    }

    func get(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func set(_ url: URL, image: NSImage) {
        // 실제 픽셀 크기 기반 비용 계산 (points가 아닌 pixels — Retina 대응)
        var pixelW = image.size.width
        var pixelH = image.size.height
        if let rep = image.representations.first {
            pixelW = CGFloat(rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width))
            pixelH = CGFloat(rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height))
        }
        let cost = Int(pixelW * pixelH * 4)  // ~bytes (RGBA)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
