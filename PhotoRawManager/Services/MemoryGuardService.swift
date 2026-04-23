//
//  MemoryGuardService.swift
//  PhotoRawManager
//
//  상시 RAM 감시 서비스 — HUD 와 독립적으로 앱 실행 중 항상 동작.
//  RAM 이 2GB 이상 초과 시 자동으로 모든 이미지 캐시 해제.
//
//  OS memoryPressure 이벤트는 8-10GB 이후에나 발화하므로, 그 전에 선제 차단.
//

import Foundation
import AppKit

final class MemoryGuardService {
    static let shared = MemoryGuardService()

    // 기준점 (앱 시작 시 또는 폴더 열 때 설정)
    private var baselineRamMB: Int = 0
    // 마지막 flush 시점의 RAM (같은 수준에서 계속 flush 하지 않도록)
    private var lastFlushRamMB: Int = 0

    // 감시 타이머 (1초 간격)
    private var timer: DispatchSourceTimer?

    /// 2GB 이상 증가 시 자동 flush
    private let growthThresholdMB: Int = 2000
    /// 연속 flush 방지 간격 (이전 flush 대비 500MB 이상 더 증가해야 재flush)
    private let reflushDeltaMB: Int = 500
    /// RAM 사용 비율이 이 값 이상이면 prefetch/동시성을 먼저 보수적으로 조정
    private let softLimitRatio: Double = 0.14
    /// RAM 사용 비율이 이 값 이상이면 flush 수행 (선제 예산 기반)
    private let hardLimitRatio: Double = 0.18

    private init() {}

    /// 앱 시작 또는 기준점 초기화 시 호출
    func start() {
        baselineRamMB = currentRamMB()
        lastFlushRamMB = baselineRamMB
        fputs("[MemGuard] 시작 — baseline \(baselineRamMB)MB\n", stderr)

        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in
            self?.check()
        }
        t.resume()
        timer = t
    }

    /// 기준점 리셋 (예: 새 폴더 열 때)
    func resetBaseline() {
        baselineRamMB = currentRamMB()
        lastFlushRamMB = baselineRamMB
        fputs("[MemGuard] baseline reset → \(baselineRamMB)MB\n", stderr)
    }

    private func check() {
        let now = currentRamMB()
        let growth = now - baselineRamMB
        let sinceFlush = now - lastFlushRamMB
        let totalRamMB = max(1, Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)))
        let usageRatio = Double(now) / Double(totalRamMB)
        ThumbnailLoader.shared.updateMemoryPressure(usageRatio)

        if usageRatio >= softLimitRatio {
            ThumbnailLoader.shared.throttle()
        } else {
            ThumbnailLoader.shared.unthrottle()
        }

        if usageRatio >= hardLimitRatio && sinceFlush >= reflushDeltaMB {
            fputs("[MemGuard] RAM 비율 \(Int(usageRatio * 100))% (hard limit) → 캐시 해제\n", stderr)
            flushAll()
            lastFlushRamMB = currentRamMB()
            return
        }

        // 2GB 이상 증가하고, 지난 flush 대비 500MB 이상 더 늘었으면 flush
        if growth >= growthThresholdMB && sinceFlush >= reflushDeltaMB {
            fputs("[MemGuard] RAM 증가 \(growth)MB (2GB 초과) → 자동 캐시 해제\n", stderr)
            flushAll()
            lastFlushRamMB = currentRamMB()
        }
    }

    /// 모든 이미지 캐시 해제 (OS pressure 발화 전 선제 차단)
    func flushAll() {
        let before = currentRamMB()
        PreviewImageCache.shared.clearCache()
        ThumbnailCache.shared.removeAll()
        AggressiveImageCache.shared.removeAll()
        PhotoPreviewView.clearHiResCache()
        // Thread-local autorelease pool 비우기 트리거
        DispatchQueue.global(qos: .utility).async { autoreleasepool { } }
        let after = currentRamMB()
        fputs("[MemGuard] 캐시 해제 완료: \(before)MB → \(after)MB (감소 \(before - after)MB)\n", stderr)
    }

    private func currentRamMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / (1024 * 1024))
    }
}
