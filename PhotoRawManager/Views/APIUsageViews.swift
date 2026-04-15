//
//  APIUsageViews.swift
//  PhotoRawManager
//
//  Extracted from ContentView+SupportingViews.swift split.
//

import SwiftUI
import AppKit

// MARK: - API Usage Gauge

struct APIUsageGauge: View {
    @ObservedObject private var tracker = APIUsageTracker.shared
    @State private var showDetail = false

    var body: some View {
        if ClaudeVisionService.hasAPIKey {
            Button(action: { showDetail.toggle() }) {
                HStack(spacing: 5) {
                    // Mini gauge bar
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 40, height: 6)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(gaugeColor)
                            .frame(width: 40 * tracker.usagePercent, height: 6)
                    }

                    Text("$\(String(format: "%.2f", tracker.estimatedCostUSD))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("AI 사용량: $\(String(format: "%.2f", tracker.estimatedCostUSD)) / $\(String(format: "%.2f", tracker.budgetUSD))")
            .popover(isPresented: $showDetail) {
                APIUsageDetailView()
            }
        }
    }

    private var gaugeColor: Color {
        if tracker.usagePercent > 0.9 { return .red }
        if tracker.usagePercent > 0.7 { return .orange }
        return .green
    }
}

struct APIUsageDetailView: View {
    @ObservedObject private var tracker = APIUsageTracker.shared
    @State private var budgetInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 사용량")
                .font(.system(size: 14, weight: .bold))

            // Gauge
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 10)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [.green, tracker.usagePercent > 0.7 ? .orange : .green, tracker.usagePercent > 0.9 ? .red : .green],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * tracker.usagePercent, height: 10)
                    }
                }
                .frame(height: 10)

                HStack {
                    Text("$\(String(format: "%.3f", tracker.estimatedCostUSD)) 사용")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("$\(String(format: "%.2f", tracker.remainingUSD)) 남음")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(tracker.remainingUSD < 1 ? .red : .green)
                }
            }

            Divider()

            // Stats
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("요청 횟수")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(tracker.requestCount)회")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("입력 토큰")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(tracker.totalInputTokens)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("출력 토큰")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(tracker.totalOutputTokens)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
            }

            Divider()

            // Budget setting
            HStack {
                Text("예산 설정")
                    .font(.system(size: AppTheme.iconSmall))
                HStack(spacing: 4) {
                    Text("$")
                        .font(.system(size: AppTheme.iconSmall))
                    TextField("5.00", text: $budgetInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .font(.system(size: AppTheme.iconSmall))
                        .onAppear { budgetInput = String(format: "%.2f", tracker.budgetUSD) }
                    Button("적용") {
                        if let val = Double(budgetInput) {
                            tracker.setBudget(val)
                        }
                    }
                    .font(.system(size: 10))
                    .controlSize(.small)
                    .help("예산 적용")
                }

                Spacer()

                Button("초기화") {
                    tracker.resetUsage()
                }
                .font(.system(size: 10))
                .foregroundColor(.red)
                .help("사용량 초기화")
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Subscription Badge

struct SubscriptionBadge: View {
    @ObservedObject private var sub = SubscriptionManager.shared
    @State private var showPaywall = false

    var body: some View {
        Button(action: { showPaywall = true }) {
            HStack(spacing: 4) {
                Image(systemName: sub.currentTier.icon)
                    .font(.system(size: 10))
                Text(sub.currentTier.displayName)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(badgeColor)
            .background(badgeColor.opacity(0.12))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help("구독 플랜 보기")
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    private var badgeColor: Color {
        switch sub.currentTier {
        case .free: return .gray
        case .pro: return .blue
        }
    }
}
