//
//  SubscriptionSettingsTab.swift
//  PickShot v9.0.2 — 구독 상태 / 변경 / 해지 / 복원 탭.
//

import SwiftUI
import StoreKit

struct SubscriptionSettingsTab: View {
    @ObservedObject private var sub = SubscriptionManager.shared
    @ObservedObject private var tier = TierManager.shared
    @State private var showPaywall = false
    @State private var isRestoring = false
    @State private var restoreMessage: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 현재 상태 카드
                currentStatusCard

                // 구독 변경
                if sub.currentTier != .pro {
                    upgradeCTA
                }

                // 트라이얼 정보
                if sub.trialDaysRemaining > 0 && !sub.isTrialExpired {
                    trialInfo
                }

                // 결제 / 복원 / 관리
                actionsRow

                // 가격 정책 안내
                pricingInfo

                Spacer(minLength: 12)
            }
            .padding(20)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    // MARK: - 카드 컴포넌트

    private var currentStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("현재 플랜")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: sub.currentTier.icon)
                    .font(.system(size: 28))
                    .foregroundColor(planColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(sub.currentTier.displayName)
                            .font(.system(size: 20, weight: .bold))
                        if tier.isInTrial {
                            Text("체험 중")
                                .font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }
                    }
                    Text(planDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(planColor.opacity(0.06))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(planColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var upgradeCTA: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(sub.currentTier == .free ? "구독 시작" : "Pro 로 업그레이드")
                        .font(.system(size: 13, weight: .bold))
                    Text("Simple ₩2,900/월 · Pro ₩8,900/월")
                        .font(.system(size: 10))
                        .opacity(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.7)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.purple, .blue],
                                       startPoint: .leading, endPoint: .trailing))
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private var trialInfo: some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass")
                .foregroundColor(.orange)
            Text("Pro 체험 \(sub.trialDaysRemaining)일 남음")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("종료 후 자동으로 \(SubscriptionTier.simple.displayName) 로 강등 — 돈 안 빠짐")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.06))
        .cornerRadius(8)
    }

    private var actionsRow: some View {
        VStack(spacing: 8) {
            Button {
                Task { await restorePurchases() }
            } label: {
                HStack {
                    if isRestoring {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRestoring ? "복원 중..." : "구매 복원")
                    Spacer()
                }
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .padding(10)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(isRestoring)

            Button {
                if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack {
                    Image(systemName: "creditcard")
                    Text("Apple ID 구독 관리 (해지 · 변경)")
                    Spacer()
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 10))
                        .opacity(0.5)
                }
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .padding(10)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            if !restoreMessage.isEmpty {
                Text(restoreMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private var pricingInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("가격 안내")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            HStack(alignment: .top, spacing: 12) {
                pricingMini(name: "Simple", monthly: "₩2,900", yearly: "₩29,000", color: .green)
                pricingMini(name: "Pro", monthly: "₩8,900", yearly: "₩89,000", color: .blue, recommended: true)
            }

            Text("연 결제 시 17% 할인 (1개월 무료 효과). 부가세 포함. 첫 7일 Pro 무료 체험.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(14)
        .background(Color.gray.opacity(0.04))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func pricingMini(name: String, monthly: String, yearly: String, color: Color, recommended: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(name).font(.system(size: 12, weight: .bold))
                if recommended {
                    Text("추천").font(.system(size: 8, weight: .heavy))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(color.opacity(0.18))
                        .foregroundColor(color)
                        .cornerRadius(3)
                }
            }
            Text(monthly).font(.system(size: 14, weight: .semibold))
            Text("/월 또는 \(yearly)/년")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08))
        .cornerRadius(6)
    }

    // MARK: - Helpers

    private var planColor: Color {
        switch sub.currentTier {
        case .free: return .gray
        case .simple: return .green
        case .pro: return .blue
        }
    }
    private var planDescription: String {
        switch sub.currentTier {
        case .free: return "구독을 시작하면 모든 기능 사용 가능"
        case .simple: return "셀렉 도구 — Pro 기능 사용 시 업그레이드 필요"
        case .pro: return "모든 기능 사용 가능 — 우선 지원 + 신기능 우선 공개"
        }
    }

    private func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }
        await sub.restorePurchases()
        restoreMessage = sub.purchasedProductIDs.isEmpty
            ? "복원할 구독이 없습니다."
            : "✓ 구매 \(sub.purchasedProductIDs.count)건 복원 완료"
    }
}
