import SwiftUI
import StoreKit

/// v9.0.2: Simple / Pro 2-tier 구독 페이월 — Annual 17% 할인 토글 포함.
struct PaywallView: View {
    @ObservedObject var subscriptionManager = SubscriptionManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var billingMode: BillingMode = .monthly

    enum BillingMode { case monthly, yearly }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.purple, .blue],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 56, height: 56)
                        .blur(radius: 14)
                        .opacity(0.6)
                    Image(systemName: "sparkles")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [.purple, .blue],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                Text("PickShot 구독")
                    .font(.system(size: 22, weight: .bold))
                Text("행사 사진 만장을 약 30분만에 추리는 도구.\n7일 무료 체험, 카드는 끝나기 하루 전에만 요청.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            // 월 / 연 토글
            HStack(spacing: 4) {
                billingButton(.monthly, label: "월 결제")
                billingButton(.yearly, label: "연 결제 (17% 할인)")
            }
            .padding(4)
            .background(Color.gray.opacity(0.12))
            .cornerRadius(20)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 12) {
                    // Simple 카드
                    tierCard(
                        title: "Simple",
                        subtitle: "가볍게, 셀렉만 빠르게",
                        price: billingMode == .monthly ? "₩2,900" : "₩29,000",
                        unit: billingMode == .monthly ? "/ 월" : "/ 년",
                        yearlyHint: billingMode == .yearly ? "월 환산 ₩2,420" : nil,
                        accent: .gray,
                        productID: billingMode == .monthly
                            ? SubscriptionManager.simpleMonthlyID
                            : SubscriptionManager.simpleYearlyID,
                        bullets: [
                            "초고속 RAW 뷰잉",
                            "별점 / 색상 라벨 / Space Pick",
                            "JPG/RAW 자동 매칭",
                            "기본 내보내기",
                            "단일 메모리카드 백업",
                            "워터마크 1개",
                            "비파괴 보정"
                        ]
                    )

                    // Pro 카드 — 추천
                    tierCard(
                        title: "Pro",
                        subtitle: "행사 사진 만장 → 클라이언트 폴더까지",
                        price: billingMode == .monthly ? "₩8,900" : "₩89,000",
                        unit: billingMode == .monthly ? "/ 월" : "/ 년",
                        yearlyHint: billingMode == .yearly ? "월 환산 ₩7,420 · 1개월 무료" : nil,
                        accent: .blue,
                        isRecommended: true,
                        productID: billingMode == .monthly
                            ? SubscriptionManager.proMonthlyID
                            : SubscriptionManager.proYearlyID,
                        bullets: [
                            "Simple 의 모든 기능 포함",
                            "🔥 클라이언트 워크플로우 (G-Select + 웹 뷰어)",
                            "🎨 RAW→JPG 변환 (Stage3 + Lanczos + 화보 느낌)",
                            "📑 배치 처리 + 컨택트시트 PDF",
                            "🎬 LOG 자동 LUT (영상)",
                            "⚡ 적극 캐시 모드",
                            "🔄 Lightroom XMP 양방향",
                            "🤖 AI 자동화 (v9.1+ Pro 우선 공개)"
                        ]
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            Divider()

            // Footer
            HStack {
                Button("구매 복원") {
                    Task { await subscriptionManager.restorePurchases() }
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: subscriptionManager.currentTier.icon)
                        .font(.system(size: 10))
                    Text("현재: \(subscriptionManager.currentTier.displayName)")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundColor(tierColor(subscriptionManager.currentTier))
                .background(tierColor(subscriptionManager.currentTier).opacity(0.12))
                .cornerRadius(5)

                Spacer()

                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 480, height: 720)
    }

    @ViewBuilder
    private func billingButton(_ mode: BillingMode, label: String) -> some View {
        Button {
            withAnimation { billingMode = mode }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: billingMode == mode ? .bold : .medium))
                .foregroundColor(billingMode == mode ? .white : .primary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(billingMode == mode
                    ? AnyShapeStyle(LinearGradient(colors: [.purple, .blue],
                                                   startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Color.clear))
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tierCard(
        title: String,
        subtitle: String,
        price: String,
        unit: String,
        yearlyHint: String?,
        accent: Color,
        isRecommended: Bool = false,
        productID: String,
        bullets: [String]
    ) -> some View {
        let product = subscriptionManager.products.first(where: { $0.id == productID })
        let isPurchased = subscriptionManager.purchasedProductIDs.contains(productID)

        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 17, weight: .bold))
                        if isRecommended {
                            Text("추천")
                                .font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(LinearGradient(colors: [.purple, .blue],
                                                           startPoint: .leading, endPoint: .trailing))
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(price)
                            .font(.system(size: 22, weight: .bold))
                        Text(unit)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let hint = yearlyHint {
                        Text(hint)
                            .font(.system(size: 9))
                            .foregroundColor(.green)
                    }
                }
            }

            Divider()

            // Bullets
            VStack(alignment: .leading, spacing: 6) {
                ForEach(bullets, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(accent)
                            .frame(width: 12, height: 12)
                            .padding(.top, 3)
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // CTA
            Button(action: {
                guard let product else { return }
                Task { await subscriptionManager.purchase(product) }
            }) {
                HStack {
                    if isPurchased {
                        Image(systemName: "checkmark.circle.fill")
                        Text("구독 중")
                    } else if product == nil {
                        Image(systemName: "hourglass")
                        Text("App Store 연결 대기")
                    } else if isRecommended {
                        Text("Pro 7일 무료 체험")
                    } else {
                        Text("Simple 시작")
                    }
                }
                .frame(maxWidth: .infinity)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 11)
                .background(
                    isPurchased
                        ? AnyShapeStyle(Color.green)
                        : (isRecommended
                            ? AnyShapeStyle(LinearGradient(colors: [.purple, .blue],
                                                           startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.gray.opacity(0.6)))
                )
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(isPurchased || product == nil)
        }
        .padding(16)
        .background(
            isRecommended
                ? AnyShapeStyle(LinearGradient(colors: [
                    Color.purple.opacity(0.06),
                    Color.blue.opacity(0.03)
                ], startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(Color.gray.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isRecommended ? Color.purple.opacity(0.35) : Color.gray.opacity(0.18), lineWidth: isRecommended ? 1.5 : 1)
        )
        .cornerRadius(12)
    }

    private func tierColor(_ tier: SubscriptionTier) -> Color {
        switch tier {
        case .free: return .gray
        case .simple: return .green
        case .pro: return .blue
        }
    }
}
