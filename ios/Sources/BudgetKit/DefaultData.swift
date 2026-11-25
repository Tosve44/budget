import Foundation

public enum DefaultCategories {
    public static let personalExpenses = [
        "Car", "Rent", "Groceries", "Food & Drinks", "Lunch at work", "Nicotine", "Gym & Sports",
        "Shopping", "Gas", "Traveling", "Saving", "Partner balance", "Investing",
        "Cash (ATM)", "Barber", "Beauty", "Toiletries",
    ]
    public static let personalIncome = ["Salary", "Other income"]
    public static let houseExpenses = ["Groceries", "Savings", "Shopping", "Travel", "Unexpected expenses"]
    public static let houseIncome = ["Contributions"]
    /// The category used for the monthly transfer that evens out both personal budgets.
    public static let partnerBalance = "Partner balance"
}

public enum IDs {
    /// "cat_1a2b3c4d5e6f7a8b": prefix plus 16 random hex characters, like the web app.
    public static func make(_ prefix: String = "id") -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(prefix)_\(hex.prefix(16))"
    }
}

extension BudgetData {
    /// A fresh start: Tosve and Milica, a personal space each and the shared house space,
    /// with all default categories. Same ids as the web app for users and spaces.
    public static func initial() -> BudgetData {
        let users = [User(id: "u_tosve", name: "Tosve"), User(id: "u_milica", name: "Milica")]
        let spaces = [
            Space(id: "sp_personal_tosve", type: .personal, name: "Personal", ownerId: "u_tosve", memberIds: ["u_tosve"]),
            Space(id: "sp_personal_milica", type: .personal, name: "Personal", ownerId: "u_milica", memberIds: ["u_milica"]),
            Space(id: "sp_house", type: .house, name: "House", ownerId: nil, memberIds: ["u_tosve", "u_milica"]),
        ]
        var categories: [Category] = []
        func add(_ spaceId: String, _ names: [String], _ kind: EntryKind) {
            for name in names {
                categories.append(Category(id: IDs.make("cat"), spaceId: spaceId, name: name, kind: kind, order: categories.count))
            }
        }
        for sp in spaces {
            if sp.type == .personal {
                add(sp.id, DefaultCategories.personalExpenses, .expense)
                add(sp.id, DefaultCategories.personalIncome, .income)
                // Milica receives the partner balance, so on her side it is also an income category.
                if sp.ownerId == "u_milica" { add(sp.id, [DefaultCategories.partnerBalance], .income) }
            } else {
                add(sp.id, DefaultCategories.houseExpenses, .expense)
                add(sp.id, DefaultCategories.houseIncome, .income)
            }
        }
        return BudgetData(settings: Settings(currency: "EUR", currentUserId: "u_tosve"),
                          users: users, spaces: spaces, categories: categories, transactions: [])
    }

    /// Reads a backup (or the saved file) and checks that it looks right.
    public static func decode(_ json: Data) throws -> BudgetData {
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: json) } catch { throw BudgetError.notABackup }
        guard let obj = any as? [String: Any] else { throw BudgetError.notABackup }
        let version = obj["schemaVersion"] as? Int
        guard version == BudgetKit.schemaVersion else { throw BudgetError.unsupportedVersion(version ?? 0) }
        for key in ["users", "spaces", "categories", "transactions"] where !(obj[key] is [Any]) {
            throw BudgetError.missing(key)
        }
        guard obj["settings"] is [String: Any] else { throw BudgetError.missing("settings") }
        do { return try JSONDecoder().decode(BudgetData.self, from: json) } catch { throw BudgetError.notABackup }
    }

    public func encoded(pretty: Bool = true) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return try e.encode(self)
    }
}
