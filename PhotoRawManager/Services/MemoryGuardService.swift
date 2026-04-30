//
//  MemoryGuardService.swift
//  PhotoRawManager
//
//  v8.6.3: 적응형 3층 메모리 방어 (Adaptive 3-Tier Memory Guard).
//  철학: "하드코딩 상한 X, 시스템 RAM 에 비례한 동적 목표치 + OS pressure 신호 신뢰"
//
//  ┌─────────── Layer 1: Soft Target ────────────┐
//  │   = min(RAM × 0.40, RAM - 3GB)              │
//  │   8GB → 3.2GB / 16GB → 6.4GB / 32GB → 12.8  │
//  │   체감: 평상시 이 아래에서 머뭄             │
//  └──────────────────────────────────────────────┘
//  ┌─────────── Layer 2: Warning (Proactive) ─────┐
//  │   = soft target × 1.5                        │
//  │   8GB → 4.8GB / 16GB → 9.6GB                 │
//  │   액션: HiRes 캐시만 trim (체감 영향 최소)   │
//  └──────────────────────────────────────────────┘
//  ┌─────────── Layer 3: Emergency (Hard Cap) ────┐
//  │   = min(RAM × 0.65, RAM - 2GB)               │
//  │   8GB → 5.2GB / 16GB → 10.4GB                │
//  │   액션: 모든 옵션 캐시 flush + autorelease   │
//  └──────────────────────────────────────────────┘
//
//  추가: DispatchSource.memorypressure 신호 수신 → 즉시 Layer 3 실행.
//        OS 가 "이제 진짜 부족해" 라고 하면 우리 카운터 안 믿고 OS 판단 따름.
//

import Foundation
import AppKit

final class MemoryGuardService {
    static let shared = MemoryGuardService()

    // MARK: - 설정 (SystemSpec 기반 계산)
    private let physicalRamGB: Int
    private let softTargetMB: Int   // Layer 1
    private let warningMB: Int      // Layer 2
    private let emergencyMB: Int    // Layer 3

    // MARK: - 상태
    private var baselineRamMB: Int = 0
    private var lastLayer: Int = 0           // 0=정상 / 2=warning / 3=emergency
    private var lastEmergencyTime: CFAbsoluteTime = 0
    private var lastWarningTime: CFAbsoluteTime = 0

    // 같은 레이어 연속 발화 최소 간격 (초)
    private let warningCooldown: CFAbsoluteTime = 8.0
    private let emergencyCooldown: CFAbsoluteTime = 3.0

    // MARK: - 타이머 + OS 압박 신호
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?

    private init() {
        let ramGB = SystemSpec.shared.ramGB
        self.physicalRamGB = ramGB
        let ramMB = ramGB * 1024

        // v8.9 실전 한도 — 사용자 체감 "메모리 많이 쓴다" 는 대략 8~12GB 부터.
        //   RAM 이 많아도 사진 앱 1개가 18GB+ 쓰는 건 비정상 → 더 공격적으로 하향.
        // Layer 1: soft target — RAM 20%, 캡 8GB
        let soft = min(Int(Double(ramMB) * 0.20), 8192)
        self.softTargetMB = max(soft, 1024)

        // Layer 2: warning — soft × 1.5, 캡 12GB
        self.warningMB = min(Int(Double(self.softTargetMB) * 1.5), 12288)

        // Layer 3: emergency — RAM 30%, 캡 16GB
        let emergency = min(Int(Double(ramMB) * 0.30), 16384)
        self.emergencyMB = max(emergency, self.warningMB + 512)

        fputs("[MemGuard] 초기화 — RAM \(ramGB)GB / soft \(softTargetMB)MB / warn \(warningMB)MB / emerg \(emergencyMB)MB\n", stderr)
    }

    // MARK: - Public API

    /// 앱 시작 시 호출
    func start() {
        baselineRamMB = currentRamMB()
        fputs("[MemGuard] 시작 — baseline \(baselineRamMB)MB\n", stderr)

        // 1) 주기적 타이머 체크 (utility 큐 — main 간섭 최소)
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 2.0, repeating: 2.0)
        t.setEventHandler { [weak self] in
            self?.check()
        }
        t.resume()
        timer = t

        // 2) OS memorypressure 신호 구독 — warning/critical 받으면 즉시 반응
        pressureSource?.cancel()
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self = self, let src = src else { return }
            let ev = src.mask
            if ev.contains(.critical) {
                fputs("[MemGuard] 🔴 OS memorypressure CRITICAL → Layer 3 강제\n", stderr)
                DispatchQueue.main.async { self.executeLayer3(reason: "OS CRITICAL") }
            } else if ev.contains(.warning) {
                fputs("[MemGuard] 🟡 OS memorypressure WARNING → Layer 2\n", stderr)
                DispatchQueue.main.async { self.executeLayer2(reason: "OS WARNING") }
            }
        }
        src.resume()
        pressureSource = src
    }

    /// 기준점 리셋 (새 폴더 열 때 등)
    func resetBaseline() {
        baselineRamMB = currentRamMB()
        fputs("[MemGuard] baseline reset → \(baselineRamMB)MB\n", stderr)
    }

    /// 외부에서 강제 flush 호출 (기존 API 유지)
    func flushAll() {
        DispatchQueue.main.async { [weak self] in
            self?.executeLayer3(reason: "external")
        }
    }

    /// 현재 상태 스냅샷 (HUD 용)
    func debugSnapshot() -> (currentMB: Int, softMB: Int, warnMB: Int, emergMB: Int, layer: Int) {
        return (currentRamMB(), softTargetMB, warningMB, emergencyMB, lastLayer)
    }

    // MARK: - 체크 로직

    private func check() {
        let now = currentRamMB()
        let t = CFAbsoluteTimeGetCurrent()

        // v9.0.2: baseline 기반 dynamic warning — baseline 대비 +2GB 시 Layer 2.
        //   64GB Mac 에서 8GB cap 까지 가기 전, 작은 누수도 일찍 잡음.
        //   기존: 절대 임계값 (8GB/12GB/16GB) 만 → 수 시간 사용 시 누적 캐시 안 잡힘.
        let dynamicWarning = baselineRamMB + 2048   // +2GB
        let dynamicEmergency = baselineRamMB + 4096 // +4GB

        if now >= emergencyMB || now >= dynamicEmergency {
            // Layer 3 — 한계선 돌파
            if t - lastEmergencyTime >= emergencyCooldown {
                lastEmergencyTime = t
                let why = now >= emergencyMB ? "abs cap" : "baseline+4GB"
                fputs("[MemGuard] 🔴 \(now)MB ≥ \(why) — Layer 3 발동 (baseline=\(baselineRamMB)MB)\n", stderr)
                DispatchQueue.main.async { [weak self] in self?.executeLayer3(reason: "self-monitored") }
            }
            lastLayer = 3
        } else if now >= warningMB || now >= dynamicWarning {
            // Layer 2 — 주의선
            if t - lastWarningTime >= warningCooldown {
                lastWarningTime = t
                let why = now >= warningMB ? "abs cap" : "baseline+2GB"
                fputs("[MemGuard] 🟡 \(now)MB ≥ \(why) — Layer 2 (HiRes trim, baseline=\(baselineRamMB)MB)\n", stderr)
                DispatchQueue.main.async { [weak self] in self?.executeLayer2(reason: "self-monitored") }
            }
            lastLayer = 2
        } else {
            lastLayer = 0
        }
    }

    // MARK: - 액션: Layer 2 (선제 trim — 체감 영향 최소)

    private func executeLayer2(reason: String) {
        let before = currentRamMB()
        // HiRes 캐시만 — 현재 보고 있지 않은 고해상도 이미지들이 제일 무거움
        PhotoPreviewView.clearAllHiResCache()
        // PreviewImageCache 도 가장 오래된 30% 정리 (메소드 없으면 skip)
        if let cache = PreviewImageCache.shared as PreviewImageCache? {
            cache.trimOldest(ratio: 0.3)
        }
        // autorelease pool drain 힌트
        DispatchQueue.global(qos: .utility).async { autoreleasepool { } }
        let after = currentRamMB()
        fputs("[MemGuard] Layer 2 (\(reason)) 완료: \(before)MB → \(after)MB\n", stderr)
    }

    // MARK: - 액션: Layer 3 (비상 — 전체 옵션 캐시 해제)

    private func executeLayer3(reason: String) {
        let before = currentRamMB()
        PreviewImageCache.shared.clearCache()
        ThumbnailCache.shared.removeAll()
        AggressiveImageCache.shared.removeAll()
        PhotoPreviewView.clearAllHiResCache()
        // v8.9: AI 계층 메모리 캐시도 해제 — 이전에 flush 누락으로 상시 점유됨.
        FaceEmbeddingCache.shared.trimMemory(aggressive: true)
        EmbeddingIndex.shared.close()  // 다음 쿼리 시 재오픈 + 메모리 캐시도 리셋
        DispatchQueue.global(qos: .utility).async { autoreleasepool { } }
        let after = currentRamMB()
        fputs("[MemGuard] Layer 3 (\(reason)) 완료: \(before)MB → \(after)MB (감소 \(before - after)MB)\n", stderr)
    }

    // MARK: - RAM 측정

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
