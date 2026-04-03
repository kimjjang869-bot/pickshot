import Foundation
import StoreKit

// MARK: - Subscription Tiers

enum SubscriptionTier: String, Comparable {
    case free = "free"
    case pro = "pro"

    var displayName: String {
        switch self {
        case .free: return "Free"
        case .pro: return "Pro"
        }
    }

    var icon: String {
        switch self {
        case .free: return "person.circle"
        case .pro: return "star.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .free: return "gray"
        case .pro: return "blue"
        }
    }

    static func < (lhs: SubscriptionTier, rhs: SubscriptionTier) -> Bool {
        let order: [SubscriptionTier] = [.free, .pro]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - Feature Access

struct FeatureAccess {
    let tier: SubscriptionTier

    // Free: everything local
    // Pro: AI features only

    var canUseAI: Bool { tier >= .pro }
    var canUseAIClassification: Bool { tier >= .pro }
    var canUseAICorrection: Bool { tier >= .pro }
    var canUseAIDescription: Bool { tier >= .pro }
    var canUseAIStyle: Bool { tier >= .pro }
    var canUseAIRating: Bool { tier >= .pro }
    var canUseAIBestShot: Bool { tier >= .pro }

    // All these are FREE
    var canAnalyzeUnlimited: Bool { true }
    var analysisLimit: Int { Int.max }
    var canAutoCorrect: Bool { true }     // Local auto correction
    var canExportLightroom: Bool { true }
    var canExportRAW: Bool { true }
    var canClassifyScenes: Bool { true }   // Local Vision
    var canGroupFaces: Bool { true }       // Local Vision
    var canBatchRename: Bool { true }
    var canSlideshow: Bool { true }
}

// MARK: - SubscriptionManager

@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    // Product IDs - match these in App Store Connect
    // Pro: ₩1,900/month, ₩15,000/year
    static let proMonthlyID = "com.pickshot.pro.monthly"    // ₩1,900
    static let proYearlyID = "com.pickshot.pro.yearly"      // ₩15,000

    // Keep legacy IDs for migration
    static let premiumMonthlyID = "com.pickshot.premium.monthly"
    static let premiumYearlyID = "com.pickshot.premium.yearly"

    @Published var currentTier: SubscriptionTier = .free
    @Published var products: [Product] = []
    @Published var purchasedProductIDs: Set<String> = []

    var featureAccess: FeatureAccess {
        FeatureAccess(tier: currentTier)
    }

    private var productIDs: Set<String> {
        [Self.proMonthlyID, Self.proYearlyID,
         Self.premiumMonthlyID, Self.premiumYearlyID]
    }

    private var transactionListener: Task<Void, Never>?

    init() {
        transactionListener = Task { await listenForTransactions() }
        Task { await checkCurrentEntitlements() }
        Task { await loadProducts() }
    }

    deinit { transactionListener?.cancel() }

    // MARK: - Load Products

    func loadProducts() async {
        do {
            products = try await Product.products(for: productIDs)
                .sorted { $0.price < $1.price }
        } catch {
            print("Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async -> Bool {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await updateTier()
                await transaction.finish()
                return true
            case .pending, .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch {
            print("Purchase failed: \(error)")
            return false
        }
    }

    // MARK: - Restore

    func restorePurchases() async {
        try? await AppStore.sync()
        await checkCurrentEntitlements()
    }

    // MARK: - Listen for Transactions

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if let transaction = try? checkVerified(result) {
                await updateTier()
                await transaction.finish()
            }
        }
    }

    // MARK: - Check Entitlements

    func checkCurrentEntitlements() async {
        var newPurchased: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                newPurchased.insert(transaction.productID)
            }
        }
        purchasedProductIDs = newPurchased
        await updateTier()
    }

    private func updateTier() async {
        var newPurchased: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                newPurchased.insert(transaction.productID)
            }
        }
        purchasedProductIDs = newPurchased

        // Any pro or premium purchase = Pro tier
        if newPurchased.contains(Self.proMonthlyID) ||
           newPurchased.contains(Self.proYearlyID) ||
           newPurchased.contains(Self.premiumMonthlyID) ||
           newPurchased.contains(Self.premiumYearlyID) {
            currentTier = .pro
        } else {
            currentTier = .free
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified: throw StoreError.verificationFailed
        }
    }

    enum StoreError: Error { case verificationFailed }

    // MARK: - Product Helpers

    var proProducts: [Product] {
        products.filter { $0.id == Self.proMonthlyID || $0.id == Self.proYearlyID }
    }

    func isYearly(_ product: Product) -> Bool {
        product.id.contains("yearly")
    }
}
