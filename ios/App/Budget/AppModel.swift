import Foundation
import Observation
import Security
import BudgetKit

// Short names for the app's own types where SwiftUI or StoreKit use the same word.
typealias Entry = BudgetKit.Transaction
typealias EntryCategory = BudgetKit.Category

enum AppConfig {
    /// While Tosve and Milica are testing, everyone has the full version.
    /// Set to false (and add the product in App Store Connect) for the App Store release.
    static let everyoneHasFullVersion = true
    /// The in-app purchase id for the full version (only used once purchases are switched on).
    static let fullVersionProductId = "budget.full"

    /// The Supabase project both phones sync through (the same one the web app uses).
    /// Both values are public by design; privacy comes from the database's row level security.
    /// Leave empty to use the app on one phone only, without syncing.
    static let supabaseURL = "https://ybhtnizbppamcaqavfrx.supabase.co"
    static let supabaseAnonKey = "sb_publishable_3zWG5W1GqObHytHGgBFzEg_Xv0N5s9H"

    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-ui-testing") }
    static func flag(_ name: String) -> Bool { ProcessInfo.processInfo.arguments.contains(name) }
}

/// Holds the data for the screens and redraws them whenever it changes.
@MainActor
@Observable
final class AppModel {
    /// Bumped on every change; screens that read `store` through `s` redraw when it changes.
    private(set) var revision = 0
    @ObservationIgnored let store: BudgetStore
    @ObservationIgnored let photos: PhotoStore
    var plan: Plan
    var saveProblem: String?
    @ObservationIgnored private(set) var sync: SyncEngine?
    var syncState: SyncEngine.State = .off

    init(store: BudgetStore, photos: PhotoStore, plan: Plan) {
        self.store = store
        self.photos = photos
        self.plan = plan
        attachObservers()
    }

    @MainActor
    func attachSync(_ engine: SyncEngine) {
        sync = engine
        syncState = engine.state
        engine.onStateChange = { [weak self] st in self?.syncState = st; self?.revision &+= 1 }
    }

    /// A receipt photo: on this phone, or downloaded once from the cloud if the partner took it.
    @MainActor
    func photoData(_ id: String) async -> Data? {
        if let local = photos.load(id) { return local }
        return await sync?.photo(for: id)
    }

    /// Sync now if syncing is set up (app opened, pulled to refresh, every 30 seconds).
    @MainActor
    func syncIfConnected() {
        guard let sync, sync.isConnected else { return }
        Task { try? await sync.syncNow() }
    }

    private func attachObservers() {
        store.onChange = { [weak self] _ in
            guard let self else { return }
            self.revision &+= 1
            self.saveProblem = store.lastSaveError == nil ? nil
                : "Could not save on this phone. Is the storage full? Your changes are kept until the app is closed."
        }
    }

    /// The store, read in a way that makes the screen redraw when data changes.
    var s: BudgetStore { _ = revision; return store }

    var currency: String { s.data.settings.currency }
    func money(_ cents: Int) -> String { Money.format(cents, currency: currency) }

    static func live() -> AppModel {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let folder = base.appendingPathComponent("Budget", isDirectory: true)
        // Application Support is private to the app and included in the phone's normal backup.
        let dataURL = folder.appendingPathComponent("budget.json")
        let store = BudgetStore(storage: FileStorage(url: dataURL))
        let photos = PhotoStore(folder: folder.appendingPathComponent("receipts", isDirectory: true))
        let model = AppModel(store: store, photos: photos, plan: AppConfig.everyoneHasFullVersion ? .full : .free)
        if let url = URL(string: AppConfig.supabaseURL), !AppConfig.supabaseAnonKey.isEmpty {
            let metaURL = folder.appendingPathComponent("sync.json")
            let meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(SyncMeta.self, from: $0) }
            let client = SupabaseClient(url: url, anonKey: AppConfig.supabaseAnonKey, keeper: KeychainSessionKeeper())
            model.attachSync(SyncEngine(store: store, client: client, photos: photos, meta: meta) { m in
                if let d = try? JSONEncoder().encode(m) { try? d.write(to: metaURL, options: .atomic) }
            })
        }
        return model
    }

    /// For UI tests: a fresh start in memory every launch, optionally with sample entries.
    static func forUITests() -> AppModel {
        let store = BudgetStore(storage: MemoryStorage())
        // Each UI test starts with the default look, unless it is testing that the choice is remembered.
        if !AppConfig.flag("-keep-appearance") { UserDefaults.standard.removeObject(forKey: "appearance") }
        if AppConfig.flag("-as-milica") { store.setCurrentUser("u_milica") }
        if AppConfig.flag("-demo-data") { DemoData.fill(store) }
        let photos = PhotoStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("ui-test-receipts-\(UUID().uuidString)"))
        return AppModel(store: store, photos: photos, plan: AppConfig.flag("-free-plan") ? .free : .full)
    }
}

/// Remembers the sign-in in the iPhone's Keychain (encrypted, never in backups of other apps).
final class KeychainSessionKeeper: SessionKeeper {
    let account = "supabase.session"
    let service = Bundle.main.bundleIdentifier ?? "budget"

    func load() -> AuthSession? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    func save(_ session: AuthSession?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// A few entries so screens can be tried out (UI tests and screenshots).
enum DemoData {
    static func fill(_ s: BudgetStore) {
        let month = DateKey.month()
        func cat(_ sp: String, _ name: String, _ kind: EntryKind = .expense) -> String {
            s.categories(in: sp, kind: kind).first { $0.name == name }!.id
        }
        let P = s.personalSpace()!.id, H = s.houseSpace!.id
        s.updateCategory(cat(P, "Groceries"), budget: 30000)
        s.updateCategory(cat(P, "Rent"), budget: 50000)
        s.updateCategory(cat(H, "Groceries"), budget: 40000)
        s.addTransaction(spaceId: P, categoryId: cat(P, "Salary", .income), kind: .income, amount: 200000, date: "\(month)-01")
        s.addTransaction(spaceId: P, categoryId: cat(P, "Rent"), kind: .expense, amount: 50000, date: "\(month)-01", note: "Rent")
        s.addTransaction(spaceId: P, categoryId: cat(P, "Groceries"), kind: .expense, amount: 4550, date: "\(month)-01",
                         items: [ReceiptItem(name: "MLEKO ALPSKO 3,5% 1L", price: 119), ReceiptItem(name: "KRUH BELI 500G", price: 149)])
        s.addTransaction(spaceId: H, categoryId: cat(H, "Groceries"), kind: .expense, amount: 2300, date: "\(month)-01")
    }
}
