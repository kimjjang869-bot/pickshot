//
//  AppConfig.swift
//  PhotoRawManager
//
//  앱 전역 Feature Flag. 출시 시점에 켜거나 끌 기능을 한 곳에서 관리.
//

import Foundation

enum AppConfig {
    /// AI 기능(스마트 셀렉/컬, AI 분류, 얼굴 그룹/비교, AI 엔진 설정, AI 추천 필터 등)을
    /// UI에서 숨긴다. 코드 자체는 유지해 두고 릴리스 시점에만 off.
    ///
    /// 출시 후 AI 기능이 안정화되면 `false` 로 바꿔 전체 기능을 다시 노출.
    static let hideAIFeatures: Bool = true

    /// 테더링 기능 공개 여부 (Sony/Canon/Nikon SDK 통합).
    /// - Debug 빌드 → 항상 ON (개발자 테스트용)
    /// - Release 빌드 → OFF (UI 에 "Coming Soon" 표시) — SDK 승인 + 안정화 후 true 로 변경
    static let enableTethering: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
}
