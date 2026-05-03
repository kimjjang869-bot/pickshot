//
//  SuperCullMode.swift
//  PickShot v9.1+ — 슈퍼 셀렉 모드 (안전 버전 — Stage 3 만 차단)
//
//  shouldAutoLoadHiRes 1곳만 변경 → 응답없음 위험 0.
//  loadHiResForZoom 직접 호출 (zoom slider, 사용자 명시 줌) 은 통과.
//

import Foundation

/// 슈퍼 셀렉 모드 — Stage 3 자동 hi-res 디코드 차단 토글.
final class SuperCullMode {
    /// hot path 에서 호출 — UserDefaults 직접 read (캐시 X 단순함).
    static var isActive: Bool {
        get { UserDefaults.standard.bool(forKey: "superCullModeActive") }
        set { UserDefaults.standard.set(newValue, forKey: "superCullModeActive") }
    }
}
