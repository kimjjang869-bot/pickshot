import SwiftUI
import StoreKit

struct PaywallView: View {
    @ObservedObject var subscriptionManager = SubscriptionManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)

                Text("PickShot Pro")
                    .font(.system(size: 22, weight: .bold))

                Text("AI로 사진 선별을 한 단계 업그레이드")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // Free features
                    VStack(alignment: .leading, spacing: 8) {
                        Label("무료로 제공되는 기능", systemImage: "gift.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.green)

                        freeFeatureRow("사진 불러오기 / 미리보기 (무제한)")
                        freeFeatureRow("별점 / 스페이스 셀렉")
                        freeFeatureRow("RAW + Lightroom 내보내기")
                        freeFeatureRow("품질 분석 (로컬)")
                        freeFeatureRow("장면 분류 / 얼굴 그룹핑")
                        freeFeatureRow("슬라이드쇼 / 배치 이름 변경")
                        freeFeatureRow("자동 보정 (로컬)")
                    }
                    .padding(12)
                    .background(Color.green.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2)))

                    // Pro features
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Pro 전용 AI 기능", systemImage: "sparkles")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.blue)

                        proFeatureRow("🤖 AI 스마트 분류", "행사/인물/군중/분위기 자동 분류")
                        proFeatureRow("🤖 AI 자동 보정", "한국 화보 스타일 자동 보정")
                        proFeatureRow("🤖 AI 베스트샷", "연사 중 최고의 한 장 자동 선별")
                        proFeatureRow("🤖 AI 사진 설명", "사진 내용 자연어 설명")
                        proFeatureRow("🤖 AI 보정 제안", "프로 수준 보정값 제안")
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.2)))

                    // Price cards
                    VStack(spacing: 8) {
                        ForEach(subscriptionManager.proProducts, id: \.id) { product in
                            let isYearly = subscriptionManager.isYearly(product)
                            let isPurchased = subscriptionManager.purchasedProductIDs.contains(product.id)

                            Button(action: {
                                Task { await subscriptionManager.purchase(product) }
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(isYearly ? "연간" : "월간")
                                                .font(.system(size: 14, weight: .bold))
                                            if isYearly {
                                                Text("2개월 무료")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.orange)
                                                    .cornerRadius(4)
                                            }
                                        }
                                        Text(isYearly ? "매월 ₩1,250 (34% 할인)" : "매월 결제")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if isPurchased {
                                        Label("구독 중", systemImage: "checkmark.circle.fill")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.green)
                                    } else {
                                        VStack(alignment: .trailing) {
                                            Text(product.displayPrice)
                                                .font(.system(size: 16, weight: .bold))
                                            Text(isYearly ? "/년" : "/월")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding(14)
                                .background(isPurchased ? Color.green.opacity(0.1) : isYearly ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(isPurchased ? Color.green : isYearly ? Color.blue : Color.gray.opacity(0.2), lineWidth: isYearly ? 2 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isPurchased)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()

            // Footer
            HStack {
                Button("구매 복원") {
                    Task { await subscriptionManager.restorePurchases() }
                }
                .font(.caption)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: subscriptionManager.currentTier.icon)
                        .font(.system(size: 10))
                    Text("현재: \(subscriptionManager.currentTier.displayName)")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundColor(subscriptionManager.currentTier == .pro ? .blue : .gray)
                .background((subscriptionManager.currentTier == .pro ? Color.blue : Color.gray).opacity(0.1))
                .cornerRadius(5)

                Spacer()

                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 440, height: 620)
    }

    private func freeFeatureRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.green)
            Text(text)
                .font(.system(size: 11))
        }
    }

    private func proFeatureRow(_ title: String, _ desc: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
            Text(desc)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}
