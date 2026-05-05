//
//  ProLockModal.swift
//  PickShot v9.1+ — Pro 잠금 모달 (재사용)
//
//  사용:
//    .sheet(item: $lockedFeature) { feature in
//        ProLockModal(feature: feature)
//    }
//

import SwiftUI

/// Pro 잠금 모달 — 사용자가 Pro 전용 기능을 사용하려 할 때 표시.
struct ProLockModal: View {
    let feature: AppFeature
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tier = TierManager.shared

    private var isComingSoon: Bool { feature.releaseStatus == .comingSoon }

    var body: some View {
        VStack(spacing: 0) {
            // 헤더 — 그라데이션 + 잠금/시계 아이콘
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: isComingSoon ? [.orange, .pink] : [.purple, .blue],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 72, height: 72)
                        .blur(radius: 16)
                        .opacity(0.6)
                    Image(systemName: isComingSoon ? "hourglass.circle.fill" : "sparkles")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: isComingSoon ? [.orange, .pink] : [.purple, .blue],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .padding(.top, 8)

                Text(feature.displayName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)

                if isComingSoon {
                    Text("v9.1+ 공개 예정")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                } else {
                    Text("Pro 에서만 사용 가능")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Color.purple.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: isComingSoon
                    ? [Color.orange.opacity(0.08), Color.pink.opacity(0.04)]
                    : [Color.purple.opacity(0.08), Color.blue.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom)
            )

            Divider().opacity(0.4)

            // 본문 — 기능 설명
            VStack(spacing: 18) {
                Text(feature.blurb)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 8)

                if isComingSoon {
                    // 추후 공개 안내
                    VStack(alignment: .leading, spacing: 10) {
                        proPoint(icon: "hammer.fill", text: "현재 개발 중 — 안정성 미흡으로 잠금 처리", color: .orange)
                        proPoint(icon: "envelope.badge.fill", text: "공개 시 인앱 알림 + 이메일 안내", color: .orange)
                        proPoint(icon: "checkmark.seal.fill", text: "Pro 구독자에게 우선 공개", color: .orange)
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.06))
                    .cornerRadius(8)
                } else {
                    // Pro 가치 강조
                    VStack(alignment: .leading, spacing: 10) {
                        proPoint(icon: "person.2.fill", text: "클라이언트 워크플로우 (G-Select + 웹 뷰어)", color: .purple)
                        proPoint(icon: "photo.stack", text: "고급 출력 (RAW→JPG + 화보 느낌 + 배치)", color: .purple)
                        proPoint(icon: "camera.aperture", text: "테더링 + 연속 백업 + LOG LUT", color: .purple)
                        proPoint(icon: "arrow.triangle.2.circlepath", text: "Lightroom XMP 양방향", color: .purple)
                    }
                    .padding(14)
                    .background(Color.gray.opacity(0.07))
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)

            Divider().opacity(0.4)

            // CTA
            VStack(spacing: 10) {
                if isComingSoon {
                    // 추후 공개: 닫기만
                    Button("확인") { dismiss() }
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(LinearGradient(colors: [.orange, .pink],
                                                   startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(8)
                } else {
                    if tier.canStartTrial {
                        Button(action: {
                            tier.startProTrial()
                            dismiss()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                Text("7일 무료로 Pro 사용해보기")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(LinearGradient(colors: [.purple, .blue],
                                                       startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Text("카드 등록 없이 7일 무료. 끝나면 자동으로 Simple 로 강등 — 돈 안 빠짐.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    // v9.1.4: Simple ₩2,900 옵션도 함께 노출 — 가격 진입장벽 완화.
                    HStack(spacing: 8) {
                        Button(action: {
                            if let url = URL(string: "https://kimjjang869-bot.github.io/pickshot/#pricing") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            VStack(spacing: 2) {
                                Text("Simple").font(.system(size: 12, weight: .medium))
                                Text("월 ₩2,900").font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.gray.opacity(0.12))
                            .foregroundColor(.primary)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        Button(action: {
                            if let url = URL(string: "https://kimjjang869-bot.github.io/pickshot/#pricing") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            VStack(spacing: 2) {
                                Text("Pro").font(.system(size: 12, weight: .semibold))
                                Text("월 ₩8,900").font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.purple.opacity(0.15))
                            .foregroundColor(.primary)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }

                    Button("닫기") { dismiss() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .frame(width: 460)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func proPoint(icon: String, text: String, color: Color = .purple) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(2)
        }
    }
}

// MARK: - View modifier — 한 줄로 게이트 적용

extension View {
    /// Pro 잠금 sheet — 바인딩으로 표시.
    func proLockSheet(item: Binding<AppFeature?>) -> some View {
        self.sheet(item: item) { feature in
            ProLockModal(feature: feature)
        }
    }
}
