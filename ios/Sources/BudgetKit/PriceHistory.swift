import Foundation

public enum PriceHistory {
    public struct Point: Equatable, Sendable {
        public var date: String
        public var price: Int
        public var txId: String
        public var spaceId: String
        public var createdAt: String
    }

    public struct Group: Equatable, Sendable, Identifiable {
        public var key: String
        /// The name as it was first written.
        public var name: String
        /// Oldest first.
        public var entries: [Point]
        public var id: String { key }

        public var latest: Point { entries[entries.count - 1] }
        public var previous: Point? { entries.count > 1 ? entries[entries.count - 2] : nil }
        /// Change since the first time it was bought, in percent (nil if bought only once).
        public var changeSinceFirst: Double? {
            entries.count > 1 ? Money.percentChange(now: latest.price, before: entries[0].price) : nil
        }
    }

    /// "Čokolada  MILKA, 100g" and "cokolada milka 100g" are the same item.
    /// Lowercase, accents removed, anything that is not a letter, digit or % becomes one space.
    public static func normalize(_ name: String) -> String {
        let lowered = name.lowercased().decomposedStringWithCompatibilityMapping
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for s in lowered.unicodeScalars {
            if (0x300...0x36F).contains(s.value) { continue }
            let keep = s.properties.isAlphabetic || s.properties.numericType != nil || s == "%"
            if keep {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(s)
            } else {
                pendingSpace = true
            }
        }
        return String(out)
    }

    public static func groups(_ transactions: [Transaction]) -> [String: Group] {
        var map: [String: Group] = [:]
        for t in transactions {
            for it in t.items ?? [] {
                let key = normalize(it.name)
                if key.isEmpty { continue }
                let p = Point(date: t.date, price: it.price, txId: t.id, spaceId: t.spaceId, createdAt: t.createdAt)
                map[key, default: Group(key: key, name: it.name, entries: [])].entries.append(p)
            }
        }
        for k in map.keys {
            map[k]!.entries.sort { ($0.date + $0.createdAt) < ($1.date + $1.createdAt) }
        }
        return map
    }

    /// Items for the Prices screen: most recently bought first, filtered by a search text.
    public static func list(_ transactions: [Transaction], search: String = "") -> [Group] {
        let q = normalize(search)
        return groups(transactions).values
            .filter { q.isEmpty || $0.key.contains(q) }
            .sorted { a, b in
                a.latest.date != b.latest.date ? a.latest.date > b.latest.date : a.key < b.key
            }
    }

    public static func previousPrice(of name: String, before date: String, excluding txId: String?,
                                     in transactions: [Transaction]) -> Point? {
        let key = normalize(name)
        var best: Point?
        for t in transactions where t.id != txId && t.date <= date {
            for it in t.items ?? [] where normalize(it.name) == key {
                if best == nil || t.date >= best!.date {
                    best = Point(date: t.date, price: it.price, txId: t.id, spaceId: t.spaceId, createdAt: t.createdAt)
                }
            }
        }
        return best
    }
}

/// The monthly transfer that gives both people the same personal budget.
public enum PartnerBalance {
    public struct Transfer: Equatable, Sendable {
        public var fromUserId: String
        public var toUserId: String
        public var amount: Int
    }

    /// Half the difference of the two incomes, from the person who earns more.
    /// Odd cents stay with the payer, so the amount is always whole cents.
    public static func transfer(_ a: (userId: String, income: Int), _ b: (userId: String, income: Int)) -> Transfer? {
        let diff = a.income - b.income
        if diff == 0 { return nil }
        let amount = abs(diff) / 2
        if amount == 0 { return nil }
        return diff > 0 ? Transfer(fromUserId: a.userId, toUserId: b.userId, amount: amount)
                        : Transfer(fromUserId: b.userId, toUserId: a.userId, amount: amount)
    }
}

extension BudgetStore {
    /// Personal income of a person in a month, not counting partner balance money received.
    public func personalIncome(userId: String, month: String) -> Int {
        guard let sp = personalSpace(for: userId) else { return 0 }
        return transactions(in: sp.id, month: month)
            .filter { $0.kind == .income && category($0.categoryId)?.name != DefaultCategories.partnerBalance }
            .reduce(0) { $0 + $1.amount }
    }

    /// Suggested partner balance transfer for a month, based on both people's personal income.
    public func suggestedPartnerTransfer(month: String) -> PartnerBalance.Transfer? {
        guard data.users.count >= 2 else { return nil }
        let a = data.users[0].id, b = data.users[1].id
        return PartnerBalance.transfer((a, personalIncome(userId: a, month: month)),
                                       (b, personalIncome(userId: b, month: month)))
    }
}
