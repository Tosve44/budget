import Foundation

/// Prepared for a later App Store release: a free version with fewer categories and a paid
/// version with all categories plus your own. While Tosve and Milica are testing, everyone has
/// the full version (see `AppConfig` in the app). Nothing here charges money.
public enum Plan: String, Codable, Sendable {
    case free, full
}

public enum PlanRules {
    /// Expense categories included in the free version. Income categories are always included.
    public static let freePersonalExpenses: Set<String> = [
        "Rent", "Groceries", "Food & Drinks", "Car", "Shopping", "Saving", "Partner balance",
    ]
    public static let freeHouseExpenses: Set<String> = ["Groceries", "Shopping", "Unexpected expenses"]

    /// Whether a category can be used with this plan. Hidden-by-plan categories keep their
    /// entries; they just can't be picked for new ones.
    public static func isAvailable(_ c: Category, in space: Space?, plan: Plan) -> Bool {
        if plan == .full || c.kind == .income { return true }
        let free = space?.type == .house ? freeHouseExpenses : freePersonalExpenses
        return free.contains(c.name)
    }

    /// Adding your own categories is part of the full version.
    public static func canAddCustomCategory(plan: Plan) -> Bool { plan == .full }

    /// Renaming a category would let the free version turn it into any custom category.
    public static func canRenameCategory(plan: Plan) -> Bool { plan == .full }
}

extension BudgetStore {
    /// Categories offered when adding an entry: visible and included in the plan.
    public func pickableCategories(in spaceId: String, kind: EntryKind, plan: Plan) -> [Category] {
        let sp = space(spaceId)
        return categories(in: spaceId, kind: kind).filter { PlanRules.isAvailable($0, in: sp, plan: plan) }
    }
}

/// Receipt photos, one JPEG file per receipt, kept next to the data file.
public final class PhotoStore {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    /// The file for a photo id. Ids are "rc_…" for photos taken on this phone and
    /// "cloud:<space>/<entry>.jpg" for photos downloaded from the partner; every character other
    /// than letters, digits, "-" and "_" becomes "_", so an id can never point outside the folder.
    func url(_ id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        let safe = String(id.unicodeScalars.map { s -> Character in
            let ok = (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || s == "-" || s == "_"
            return ok ? Character(s) : "_"
        })
        return folder.appendingPathComponent(safe + ".jpg")
    }

    @discardableResult
    public func save(_ jpeg: Data, id: String = IDs.make("rc")) throws -> String {
        guard let u = url(id) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg.write(to: u, options: .atomic)
        return id
    }

    public func load(_ id: String) -> Data? { url(id).flatMap { try? Data(contentsOf: $0) } }

    public func delete(_ id: String) { if let u = url(id) { try? FileManager.default.removeItem(at: u) } }

    /// Removes photos no entry points to any more (after entries were deleted).
    @discardableResult
    public func removeUnused(keeping ids: Set<String>) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        let keep = Set(ids.compactMap { url($0)?.lastPathComponent })
        for f in files where f.pathExtension == "jpg" && !keep.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
            removed += 1
        }
        return removed
    }
}
