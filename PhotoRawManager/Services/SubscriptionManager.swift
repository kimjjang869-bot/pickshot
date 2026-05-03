import Foundation
import StoreKit

// MARK: - Subscription Tiers

enum SubscriptionTier: String, Comparable {
    case free = "free"
    case simple = "simple"   // v9.0.2: ₩2,900/월 — 셀렉 도구만
    case pro = "pro"         // v9.0.2: ₩8,900/월 — 클라이언트/AI/고급출력

    var displayName: String {
        switch self {
        case .free: return "Free"
        case .simple: return "Simple"
        case .pro: return "Pro"
        }
    }

    var icon: String {
        switch self {
        case .free: return "person.circle"
        case .simple: return "person.crop.circle.fill"
        case .pro: return "star.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .free: return "gray"
        case .simple: return "green"
        case .pro: return "blue"
        }
    }

    static func < (lhs: SubscriptionTier, rhs: SubscriptionTier) -> Bool {
        let order: [SubscriptionTier] = [.free, .simple, .pro]
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
    // v9.0.2 새 가격 정책:
    //   Simple: ₩2,900/월, ₩29,000/년 (셀렉 도구)
    //   Pro:    ₩8,900/월, ₩89,000/년 (클라이언트 + 고급 출력 + 영상)
    static let simpleMonthlyID = "com.pickshot.simple.monthly"  // ₩2,900
    static let simpleYearlyID  = "com.pickshot.simple.yearly"   // ₩29,000
    static let proMonthlyID    = "com.pickshot.pro.monthly"     // ₩8,900
    static let proYearlyID     = "com.pickshot.pro.yearly"      // ₩89,000

    // Keep legacy IDs for migration (이전 ₩1,900 가격)
    static let legacyProMonthlyID = "com.pickshot.pro.legacy.monthly"
    static let premiumMonthlyID   = "com.pickshot.premium.monthly"
    static let premiumYearlyID    = "com.pickshot.premium.yearly"

    @Published var currentTier: SubscriptionTier = .free
    @Published var products: [Product] = []
    @Published var purchasedProductIDs: Set<String> = []
    @Published var isTrialExpired: Bool = false
    /// 트라이얼 만료 후 Paywall 모달을 띄워야 하는지. ContentView 에서 sheet 로 관찰한다.
    @Published var showTrialExpiredPaywall: Bool = false
    @Published var trialDaysRemaining: Int = 21

    // MARK: - 3주 트라이얼

    // v9.1.4: trialStartDate 를 Keychain 으로 이동 (보안 감사 C-3).
    //   기존 UserDefaults 는 `defaults write` 한 줄로 무기한 연장 가능했음.
    //   Keychain 은 일반 사용자 권한으로 직접 수정 불가.
    private static let trialStartKey = "trialStartDate"           // 레거시 UserDefaults 키
    private static let trialStartKeychainKey = "trial_start_date" // Keychain 키
    private static let trialDuration: TimeInterval = 21 * 24 * 60 * 60  // 21일

    private static func dateFromKeychain() -> Date? {
        guard let s = KeychainService.read(key: trialStartKeychainKey),
              let interval = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    /// v9.1.4: Trial 시작일을 *생성하지 않고* 읽기만 한다 (TierManager.canStartTrial 용).
    ///   `trialStartDate` getter 는 첫 호출 시 부수효과로 시작일을 기록 → 체험 가능 여부 판정에 사용 불가.
    static func peekTrialStartDate() -> Date? {
        if let saved = dateFromKeychain() { return saved }
        if let legacy = UserDefaults.standard.object(forKey: trialStartKey) as? Date {
            return legacy
        }
        return nil
    }

    private static func saveDateToKeychain(_ d: Date) {
        _ = KeychainService.save(key: trialStartKeychainKey, value: String(d.timeIntervalSince1970))
    }

    var trialStartDate: Date {
        // 1) Keychain 우선
        if let saved = Self.dateFromKeychain() { return saved }
        // 2) 레거시 UserDefaults 일회 마이그레이션
        if let legacy = UserDefaults.standard.object(forKey: Self.trialStartKey) as? Date {
            Self.saveDateToKeychain(legacy)
            UserDefaults.standard.removeObject(forKey: Self.trialStartKey)
            return legacy
        }
        // 3) 첫 실행 — 지금 시점 기록 (Keychain 만)
        let now = Date()
        Self.saveDateToKeychain(now)
        return now
    }

    func checkTrialStatus() {
        let start = trialStartDate
        let now = Date()
        // v9.1.4: 시계 조작 방어선 — 현재 시각이 시작일보다 과거면 만료 처리.
        if now < start {
            trialDaysRemaining = 0
            isTrialExpired = true
            return
        }
        let elapsed = now.timeIntervalSince(start)
        let remaining = Self.trialDuration - elapsed
        trialDaysRemaining = max(0, Int(ceil(remaining / (24 * 60 * 60))))
        isTrialExpired = remaining <= 0

        // 테스터 키가 활성 상태면 Pro 로 간주
        if TesterKeyService.isActive() {
            currentTier = .pro
            isTrialExpired = false
            trialDaysRemaining = TesterKeyService.daysRemaining()
            return
        }

        // 구독자는 트라이얼 무시
        if currentTier != .free {
            isTrialExpired = false
            trialDaysRemaining = 999
        }
    }

    /// 트라이얼 만료 시 Paywall 모달 노출 플래그를 켠다.
    /// - ContentView 에서 `$subscriptionManager.showTrialExpiredPaywall` 를 관찰해 sheet 로 띄운다.
    /// - App Store 정책: 앱이 스스로 종료하면 안 되므로 강제 `NSApp.terminate` 은 사용하지 않는다.
    /// - 테스터 키가 활성이면 Paywall 을 띄우지 않는다.
    func enforceTrialIfExpired() {
        checkTrialStatus()
        if TesterKeyService.isActive() { return }
        guard isTrialExpired && currentTier == .free else { return }
        DispatchQueue.main.async {
            self.showTrialExpiredPaywall = true
        }
    }

    /// 테스터 키 활성화. 성공 시 Pro tier 로 즉시 승격.
    @discardableResult
    func activateTesterKey(_ code: String) -> TesterKeyService.ActivationResult {
        let result = TesterKeyService.activate(code: code)
        if case .success = result {
            currentTier = .pro
            isTrialExpired = false
            showTrialExpiredPaywall = false
            trialDaysRemaining = TesterKeyService.daysRemaining()
        }
        return result
    }

    var featureAccess: FeatureAccess {
        FeatureAccess(tier: currentTier)
    }

    private var productIDs: Set<String> {
        [Self.simpleMonthlyID, Self.simpleYearlyID,
         Self.proMonthlyID, Self.proYearlyID,
         Self.legacyProMonthlyID,
         Self.premiumMonthlyID, Self.premiumYearlyID]
    }

    private var transactionListener: Task<Void, Never>?

    init() {
        transactionListener = Task { await listenForTransactions() }
        Task { await checkCurrentEntitlements() }
        Task { await loadProducts() }
        // 2초 후 트라이얼 체크 (구독 상태 확인 후)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.enforceTrialIfExpired()
        }
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

        // v9.0.2: 새 가격 정책 — Simple / Pro / Free 3-tier.
        let isPro = newPurchased.contains(Self.proMonthlyID)
            || newPurchased.contains(Self.proYearlyID)
            || newPurchased.contains(Self.legacyProMonthlyID)
            || newPurchased.contains(Self.premiumMonthlyID)
            || newPurchased.contains(Self.premiumYearlyID)
        let isSimple = newPurchased.contains(Self.simpleMonthlyID)
            || newPurchased.contains(Self.simpleYearlyID)

        if isPro {
            currentTier = .pro
            showTrialExpiredPaywall = false
            isTrialExpired = false
        } else if isSimple {
            currentTier = .simple
            showTrialExpiredPaywall = false
            isTrialExpired = false
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
