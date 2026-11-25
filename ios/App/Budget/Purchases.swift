import StoreKit
import BudgetKit

// Prepared for the App Store: the full version as a one-time in-app purchase (StoreKit 2).
// Switched off while testing (AppConfig.everyoneHasFullVersion = true), so nothing is sold and
// no Apple developer account is needed yet. To switch on later:
//   1. Join the Apple Developer Program and create the app in App Store Connect.
//   2. Add a non-consumable in-app purchase with the id in AppConfig.fullVersionProductId.
//   3. Set AppConfig.everyoneHasFullVersion = false and show `PurchaseButton` in Settings.
extension AppModel {
    /// Checks with the App Store whether this Apple ID already bought the full version.
    func refreshPurchases() async {
        guard !AppConfig.everyoneHasFullVersion, !AppConfig.isUITesting else { return }
        var owned = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == AppConfig.fullVersionProductId, t.revocationDate == nil { owned = true }
        }
        plan = owned ? .full : .free
    }

    /// Buys the full version. Returns true when it was bought.
    func buyFullVersion() async throws -> Bool {
        guard let product = try await Product.products(for: [AppConfig.fullVersionProductId]).first else { return false }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let t) = verification else { return false }
            await t.finish()
            plan = .full
            return true
        default:
            return false
        }
    }
}
