//
//  TierManager.swift
//  PickShot v9.0.2 — Pro 잠금 UI 용 thin facade.
//
//  실제 구독/트라이얼 상태 관리는 기존 SubscriptionManager 가 담당.
//  여기는 새 가격 정책 (Simple ₩2,900 / Pro ₩8,900) 의 UI 표기와
//  Pro 잠금 게이트 진입점만 제공.
//

import Foundation
import Combine

/// 새 가격 모델의 티어 라벨 — UI 표시 전용.
///   기존 SubscriptionManager.SubscriptionTier (.free / .pro) 와 별개.
enum PickShotTier: String, CaseIterable {
    case simple
    case pro

    var displayName: String {
        switch self {
        case .simple: return "Simple"
        case .pro: return "Pro"
        }
    }
    var monthlyPriceKRW: Int {
        switch self {
        case .simple: return 2_900
        case .pro: return 8_900
        }
    }
    var yearlyPriceKRW: Int {
        switch self {
        case .simple: return 29_000
        case .pro: return 89_000
        }
    }
}

/// 티어/잠금 게이트 facade — SubscriptionManager 와 sync.
@MainActor
final class TierManager: ObservableObject {
    static let shared = TierManager()

    @Published private(set) var hasPro: Bool = false
    @Published private(set) var trialDaysRemaining: Int = 0
    @Published private(set) var isInTrial: Bool = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // SubscriptionManager 상태를 그대로 mirror.
        let sm = SubscriptionManager.shared
        sync(from: sm)

        sm.$currentTier
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync(from: sm) }
            .store(in: &cancellables)
        sm.$trialDaysRemaining
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync(from: sm) }
            .store(in: &cancellables)
        sm.$isTrialExpired
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync(from: sm) }
            .store(in: &cancellables)
    }

    private func sync(from sm: SubscriptionManager) {
        // 정식 Pro 구독 OR 트라이얼 미만료 → Pro 권한 보유.
        // Simple 구독자는 Pro 권한 없음.
        let proSubscribed = (sm.currentTier == .pro)
        let trialActive = !sm.isTrialExpired && sm.trialDaysRemaining > 0 && sm.currentTier != .simple
        hasPro = proSubscribed || trialActive
        trialDaysRemaining = sm.trialDaysRemaining
        isInTrial = trialActive && !proSubscribed
    }

    /// 현재 보여줄 티어 라벨 — UI 표시용.
    var effectiveTier: PickShotTier {
        return hasPro ? .pro : .simple
    }

    /// "7일 무료 체험 시작" 버튼을 보여줄 수 있는 상태?
    /// (기존 21일 trial 시스템 사용 — 새 7일 체험은 별도 카운터 안 만들고 trial 만료 여부로 판정)
    var canStartTrial: Bool {
        let sm = SubscriptionManager.shared
        return sm.isTrialExpired || sm.trialDaysRemaining <= 0
    }

    /// Pro 7일 체험 시작 — 현재는 Pro 임시 활성화 알림만.
    /// 실제 7일 카운트는 SubscriptionManager 의 21일 trial 을 그대로 활용 (이미 진행 중일 수도).
    func startProTrial() {
        // 기존 trial 만료 상태 강제 리셋 + Paywall 닫기.
        let sm = SubscriptionManager.shared
        sm.showTrialExpiredPaywall = false
        // 별도 동작 없음 — 기존 trial 가동 중이라 추가 처리 불요.
        AppLogger.log(.general, "[Tier] Pro trial CTA — using existing SubscriptionManager trial")
    }
}
