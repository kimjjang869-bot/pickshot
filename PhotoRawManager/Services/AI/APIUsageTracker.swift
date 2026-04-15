//
//  APIUsageTracker.swift
//  PhotoRawManager
//
//  Extracted from AIVisionService.swift split.
//

import Foundation
import AppKit

class APIUsageTracker: ObservableObject {
    static let shared = APIUsageTracker()

    @Published var totalInputTokens: Int = 0
    @Published var totalOutputTokens: Int = 0
    @Published var requestCount: Int = 0
    @Published var budgetUSD: Double = 5.0  // default $5 budget

    private let defaults = UserDefaults.standard

    init() {
        totalInputTokens = defaults.integer(forKey: "aiUsageInput")
        totalOutputTokens = defaults.integer(forKey: "aiUsageOutput")
        requestCount = defaults.integer(forKey: "aiUsageRequests")
        budgetUSD = defaults.double(forKey: "aiUsageBudget")
        if budgetUSD == 0 { budgetUSD = 5.0 }
    }

    // 모델별 가격 (엔진에 따라 다름)
    var estimatedCostUSD: Double {
        let engine = UserDefaults.standard.string(forKey: "aiClassifyEngine") ?? "claudeHaiku"
        let inputPrice: Double
        let outputPrice: Double
        switch engine {
        case "claudeHaiku":
            inputPrice = 0.25; outputPrice = 1.25      // $/M tokens
        case "claudeSonnet":
            inputPrice = 3.0; outputPrice = 15.0
        case "geminiFlash":
            inputPrice = 0.15; outputPrice = 0.60       // Gemini 2.5 Flash
        case "geminiPro":
            inputPrice = 1.25; outputPrice = 10.0       // Gemini 2.5 Pro
        default:
            inputPrice = 0.25; outputPrice = 1.25
        }
        let inputCost = Double(totalInputTokens) / 1_000_000.0 * inputPrice
        let outputCost = Double(totalOutputTokens) / 1_000_000.0 * outputPrice
        return inputCost + outputCost
    }

    var remainingUSD: Double {
        max(0, budgetUSD - estimatedCostUSD)
    }

    var usagePercent: Double {
        guard budgetUSD > 0 else { return 0 }
        return min(estimatedCostUSD / budgetUSD, 1.0)
    }

    func addUsage(inputTokens: Int, outputTokens: Int) {
        totalInputTokens += inputTokens
        totalOutputTokens += outputTokens
        requestCount += 1
        save()
    }

    func setBudget(_ usd: Double) {
        budgetUSD = usd
        defaults.set(usd, forKey: "aiUsageBudget")
    }

    func resetUsage() {
        totalInputTokens = 0
        totalOutputTokens = 0
        requestCount = 0
        save()
    }

    private func save() {
        defaults.set(totalInputTokens, forKey: "aiUsageInput")
        defaults.set(totalOutputTokens, forKey: "aiUsageOutput")
        defaults.set(requestCount, forKey: "aiUsageRequests")
    }
}
