import Foundation

// The data model. It is the same JSON shape as the web app (store.js, schemaVersion 1),
// so a backup from the web app opens in the iPhone app and the other way round.
//
// Money is always whole cents (Int). Dates are "YYYY-MM-DD" strings; months are "YYYY-MM".

public let schemaVersion = 1

public struct BudgetData: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var settings: Settings
    public var users: [User]
    public var spaces: [Space]
    public var categories: [Category]
    public var transactions: [Transaction]

    public init(schemaVersion: Int = BudgetKit.schemaVersion, settings: Settings, users: [User],
                spaces: [Space], categories: [Category], transactions: [Transaction]) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.users = users
        self.spaces = spaces
        self.categories = categories
        self.transactions = transactions
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var currency: String
    public var currentUserId: String
    /// The household's invite code once syncing is set up (the partner types it to join).
    public var inviteCode: String?

    public init(currency: String = "EUR", currentUserId: String, inviteCode: String? = nil) {
        self.currency = currency
        self.currentUserId = currentUserId
        self.inviteCode = inviteCode
    }
}

public struct User: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum SpaceType: String, Codable, Sendable { case personal, house }

public struct Space: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: SpaceType
    public var name: String
    /// The person a personal space belongs to; nil for the shared house space.
    public var ownerId: String?
    public var memberIds: [String]

    public init(id: String, type: SpaceType, name: String, ownerId: String?, memberIds: [String]) {
        self.id = id; self.type = type; self.name = name; self.ownerId = ownerId; self.memberIds = memberIds
    }

    enum CodingKeys: String, CodingKey { case id, type, name, ownerId, memberIds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(SpaceType.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        ownerId = try c.decodeIfPresent(String.self, forKey: .ownerId)
        memberIds = try c.decodeIfPresent([String].self, forKey: .memberIds) ?? []
    }

    // The web app writes `"ownerId": null` for the house space; keep doing the same.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encode(ownerId, forKey: .ownerId)
        try c.encode(memberIds, forKey: .memberIds)
    }
}

public enum EntryKind: String, Codable, CaseIterable, Sendable { case expense, income }

public struct Category: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var spaceId: String
    public var name: String
    public var kind: EntryKind
    /// Monthly budget in cents; 0 means no budget.
    public var budget: Int
    public var order: Int
    /// Hidden categories keep their past entries but are left out of lists and totals.
    public var archived: Bool
    /// When this phone last changed it (used by sync: the newest change wins).
    public var updatedAt: String?

    public init(id: String, spaceId: String, name: String, kind: EntryKind, budget: Int = 0, order: Int,
                archived: Bool = false, updatedAt: String? = nil) {
        self.id = id; self.spaceId = spaceId; self.name = name; self.kind = kind
        self.budget = budget; self.order = order; self.archived = archived; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case id, spaceId, name, kind, budget, order, archived, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        spaceId = try c.decode(String.self, forKey: .spaceId)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(EntryKind.self, forKey: .kind)
        budget = try c.decodeIfPresent(Int.self, forKey: .budget) ?? 0
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

public struct ReceiptItem: Codable, Equatable, Hashable, Sendable {
    public var name: String
    /// Line total in cents.
    public var price: Int
    public init(name: String, price: Int) { self.name = name; self.price = price }
}

public struct Transaction: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var spaceId: String
    public var categoryId: String
    public var kind: EntryKind
    /// Always positive, in cents. `kind` says whether it is money in or out.
    public var amount: Int
    public var date: String
    public var note: String
    public var createdBy: String
    public var createdAt: String
    public var updatedAt: String
    /// Id of the receipt photo, stored separately (see PhotoStore).
    public var receiptId: String?
    /// Receipt lines.
    public var items: [ReceiptItem]?

    public init(id: String, spaceId: String, categoryId: String, kind: EntryKind, amount: Int, date: String,
                note: String = "", createdBy: String, createdAt: String, updatedAt: String,
                receiptId: String? = nil, items: [ReceiptItem]? = nil) {
        self.id = id; self.spaceId = spaceId; self.categoryId = categoryId; self.kind = kind
        self.amount = amount; self.date = date; self.note = note; self.createdBy = createdBy
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.receiptId = receiptId; self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id, spaceId, categoryId, kind, amount, date, note, createdBy, createdAt, updatedAt, receiptId, items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        spaceId = try c.decode(String.self, forKey: .spaceId)
        categoryId = try c.decode(String.self, forKey: .categoryId)
        kind = try c.decode(EntryKind.self, forKey: .kind)
        amount = try c.decode(Int.self, forKey: .amount)
        date = try c.decode(String.self, forKey: .date)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        receiptId = try c.decodeIfPresent(String.self, forKey: .receiptId)
        items = try c.decodeIfPresent([ReceiptItem].self, forKey: .items)
    }
}

public enum BudgetError: Error, Equatable, LocalizedError {
    case notABackup
    case unsupportedVersion(Int)
    case missing(String)

    public var errorDescription: String? {
        switch self {
        case .notABackup: return "Not a backup file."
        case .unsupportedVersion(let v): return "Unsupported backup version: \(v)"
        case .missing(let k): return "Backup is missing \"\(k)\"."
        }
    }
}
