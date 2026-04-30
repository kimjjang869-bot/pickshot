//
//  SuperCullMode.swift
//  PickShot v9.1+ — 슈퍼 셀렉 모드 (테스트용)
//
//  목표: 썸네일 + 미리보기 속도에만 집중. 모든 부가 기능 OFF.
//
//  비활성화:
//   - InitialPreviewGenerator (백그라운드 풀 디코드)
//   - IdlePreviewPrefetch (idle 시 prefetch)
//   - EXIF batch loading
//   - 얼굴 그룹 / AI 분류
//   - 비파괴 보정 / 클리핑 오버레이 / 포커스 피킹
//   - 히스토그램 자동 계산
//   - 메타데이터 사이드바 자동 갱신
//   - DebugHUD / NavigationPerformanceMonitor
//   - LUT 자동 적용
//   - 메모리카드 백업 알림
//
//  활성화 (최소):
//   - 썸네일 디스크 캐시 HIT
//   - 임베디드 JPEG Stage 1/2/3 추출
//   - LibRaw 폴백
//   - 키보드 네비
//

import Foundation
import Combine

@MainActor
final class SuperCullMode: ObservableObject {
    static let shared = SuperCullMode()

    /// 모드 활성화 여부 (UserDefaults 저장)
    @Published var isActive: Bool {
        didSet {
            UserDefaults.standard.set(isActive, forKey: Self.key)
            AppLogger.log(.general, "[SuperCull] \(isActive ? "ON 🚀" : "OFF") — 부가 기능 \(isActive ? "비활성" : "복원")")
            applyModeChange()
        }
    }

    private static let key = "superCullModeActive"

    private init() {
        self.isActive = UserDefaults.standard.bool(forKey: Self.key)
    }

    /// 다른 코드가 빠른 분기 결정 시 참조 — `if SuperCullMode.shared.isActive { skip }`.
    /// @Published 의존 X (성능 hot path 에서 호출 가능).
    nonisolated(unsafe) static var unsafeIsActive: Bool = false

    private func applyModeChange() {
        Self.unsafeIsActive = isActive
        if isActive {
            // ON 시 진행 중인 작업 즉시 취소
            InitialPreviewGenerator.shared.cancel()
        }
    }
}
