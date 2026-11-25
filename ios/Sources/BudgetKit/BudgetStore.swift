import Foundation

/// Where the data is saved. The app uses a file on the phone; tests use memory.
public protocol DataStorage: AnyObject {
    func load() -> Data?
    func save(_ data: Data) throws
}

public final class MemoryStorage: DataStorage {
    public var stored: Data?
    public var failSaves = false
    public init(_ stored: Data? = nil) { self.stored = stored }
    public func load() -> Data? { stored }
    public func save(_ data: Data) throws {
        if failSaves { throw CocoaError(.fileWriteOutOfSpace) }
        stored = data
    }
}

/// Saves to one JSON file, replacing it in one step so a crash can't leave half a file.
public final class FileStorage: DataStorage {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> Data? { try? Data(contentsOf: url) }
    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}

public struct MonthSummary: Equatable, Sendable {
    public var income: Int
    public var spent: Int
    /// Sum of the monthly budgets of the visible expense categories.
    public var budget: Int
    public var byCategory: [String: Int]
    public var count: Int

    public var left: Int { budget - spent }
    public var isOverBudget: Bool { budget > 0 && spent > budget }
    /// 0...1 for the progress bar.
    public var usedFraction: Double { budget > 0 ? min(1, Double(spent) / Double(budget)) : 0 }
}

/// The app's data and every change to it. Mirrors `Store` in the web app's store.js.
public final class BudgetStore {
    public private(set) var data: BudgetData
    public let storage: DataStorage?
    /// Called after every change (the app uses it to redraw).
    public var onChange: ((BudgetData) -> Void)?
    /// Called when this phone changes a category or entry, so sync knows what to upload.
    /// For a deleted entry, the last copy is passed along (with a fresh updatedAt).
    /// Changes that come from the cloud (replaceAll) do not call it.
    public var onLocalChange: ((SyncTable, String, Transaction?) -> Void)?
    /// The last save error, if saving failed (for example, the phone is full).
    public private(set) var lastSaveError: Error?
    /// Clock, replaceable in tests.
    public var now: () -> Date = Date.init

    public init(storage: DataStorage?) {
        self.storage = storage
        if let raw = storage?.load(), let d = try? BudgetData.decode(raw) {
            data = d
        } else {
            // Nothing saved yet, or the saved file is damaged: start fresh instead of crashing.
            data = .initial()
        }
    }

    public init(data: BudgetData, storage: DataStorage? = nil) {
        self.data = data
        self.storage = storage
    }

    private func changed(_ table: SyncTable, _ id: String, deleted: Transaction? = nil) {
        onLocalChange?(table, id, deleted)
    }

    private func save() {
        do { try storage?.save(try data.encoded(pretty: false)); lastSaveError = nil } catch { lastSaveError = error }
        onChange?(data)
    }

    /// Replaces all data at once without marking anything as changed (used by sync), then saves.
    public func replaceAll(_ newData: BudgetData) {
        data = newData
        save()
    }

    // MARK: reads

    public var currentUser: User {
        data.users.first { $0.id == data.settings.currentUserId } ?? data.users[0]
    }
    public func user(_ id: String) -> User? { data.users.first { $0.id == id } }
    public func personalSpace(for userId: String? = nil) -> Space? {
        let uid = userId ?? currentUser.id
        return data.spaces.first { $0.type == .personal && $0.ownerId == uid }
    }
    public var houseSpace: Space? { data.spaces.first { $0.type == .house } }
    public func space(_ id: String) -> Space? { data.spaces.first { $0.id == id } }

    public func categories(in spaceId: String, includeArchived: Bool = false, kind: EntryKind? = nil) -> [Category] {
        data.categories
            .filter { $0.spaceId == spaceId && (includeArchived || !$0.archived) && (kind == nil || $0.kind == kind) }
            .sorted { $0.order < $1.order }
    }
    public func category(_ id: String) -> Category? { data.categories.first { $0.id == id } }

    /// Entries of a space, newest first; only one month when `month` ("YYYY-MM") is given.
    public func transactions(in spaceId: String, month: String? = nil) -> [Transaction] {
        data.transactions
            .filter { $0.spaceId == spaceId && (month == nil || $0.date.hasPrefix(month!)) }
            .sorted { ($0.date + $0.createdAt) > ($1.date + $1.createdAt) }
    }

    public func monthSummary(spaceId: String, month: String) -> MonthSummary {
        let txs = transactions(in: spaceId, month: month)
        var by: [String: Int] = [:]
        var income = 0, spent = 0
        for t in txs {
            if t.kind == .income { income += t.amount } else { spent += t.amount }
            by[t.categoryId, default: 0] += t.amount
        }
        let budget = categories(in: spaceId, kind: .expense).reduce(0) { $0 + $1.budget }
        return MonthSummary(income: income, spent: spent, budget: budget, byCategory: by, count: txs.count)
    }

    // MARK: writes

    public func setCurrentUser(_ id: String) {
        guard user(id) != nil else { return }
        data.settings.currentUserId = id
        save()
    }

    public func setCurrency(_ code: String) {
        data.settings.currency = code
        save()
    }

    public func renameUser(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = data.users.firstIndex(where: { $0.id == id }) else { return }
        data.users[i].name = trimmed
        save()
    }

    @discardableResult
    public func addTransaction(spaceId: String, categoryId: String, kind: EntryKind, amount: Int, date: String,
                               note: String = "", items: [ReceiptItem]? = nil, receiptId: String? = nil) -> Transaction {
        let ts = DateKey.timestamp(now())
        let t = Transaction(id: IDs.make("tx"), spaceId: spaceId, categoryId: categoryId, kind: kind, amount: amount,
                            date: date, note: note, createdBy: currentUser.id, createdAt: ts, updatedAt: ts,
                            receiptId: receiptId, items: (items?.isEmpty ?? true) ? nil : items)
        data.transactions.append(t)
        changed(.transactions, t.id)
        save()
        return t
    }

    public func updateTransaction(_ id: String, _ change: (inout Transaction) -> Void) {
        guard let i = data.transactions.firstIndex(where: { $0.id == id }) else { return }
        var t = data.transactions[i]
        change(&t)
        t.id = id
        if t.items?.isEmpty == true { t.items = nil }
        t.updatedAt = DateKey.timestamp(now())
        data.transactions[i] = t
        changed(.transactions, id)
        save()
    }

    public func deleteTransaction(_ id: String) {
        guard let i = data.transactions.firstIndex(where: { $0.id == id }) else { return }
        var dead = data.transactions.remove(at: i)
        dead.updatedAt = DateKey.timestamp(now())
        changed(.transactions, id, deleted: dead)
        save()
    }

    @discardableResult
    public func addCategory(spaceId: String, name: String, kind: EntryKind, budget: Int = 0) -> Category {
        let order = (data.categories.map(\.order).max() ?? -1) + 1
        let c = Category(id: IDs.make("cat"), spaceId: spaceId, name: name, kind: kind, budget: budget, order: order,
                         updatedAt: DateKey.timestamp(now()))
        data.categories.append(c)
        changed(.categories, c.id)
        save()
        return c
    }

    public func updateCategory(_ id: String, name: String? = nil, budget: Int? = nil, archived: Bool? = nil) {
        guard let i = data.categories.firstIndex(where: { $0.id == id }) else { return }
        if let name { data.categories[i].name = name }
        if let budget { data.categories[i].budget = budget }
        if let archived { data.categories[i].archived = archived }
        data.categories[i].updatedAt = DateKey.timestamp(now())
        changed(.categories, id)
        save()
    }

    /// Moves a category one place up (-1) or down (+1) among categories of the same kind.
    public func moveCategory(_ id: String, by dir: Int) {
        guard let c = category(id) else { return }
        let list = categories(in: c.spaceId, includeArchived: true, kind: c.kind)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let j = i + dir
        guard j >= 0, j < list.count else { return }
        guard let a = data.categories.firstIndex(where: { $0.id == list[i].id }),
              let b = data.categories.firstIndex(where: { $0.id == list[j].id }) else { return }
        let tmp = data.categories[a].order
        data.categories[a].order = data.categories[b].order
        data.categories[b].order = tmp
        let ts = DateKey.timestamp(now())
        for k in [a, b] { data.categories[k].updatedAt = ts; changed(.categories, data.categories[k].id) }
        save()
    }

    /// Puts the categories of one kind in a new order (from drag and drop). Ids not in the list keep their place at the end.
    public func reorderCategories(in spaceId: String, kind: EntryKind, ids: [String]) {
        let current = categories(in: spaceId, includeArchived: true, kind: kind)
        let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var seen = Set<String>()
        let wanted = ids.filter { byId[$0] != nil && seen.insert($0).inserted }
        let newOrder = wanted + current.map(\.id).filter { !seen.contains($0) }
        let slots = current.map(\.order).sorted()
        let ts = DateKey.timestamp(now())
        for (slot, id) in zip(slots, newOrder) {
            if let i = data.categories.firstIndex(where: { $0.id == id }), data.categories[i].order != slot {
                data.categories[i].order = slot
                data.categories[i].updatedAt = ts
                changed(.categories, id)
            }
        }
        save()
    }

    // MARK: receipt items / price tracking

    /// Every receipt line ever saved, grouped by item name, oldest first.
    public func itemHistory() -> [String: PriceHistory.Group] { PriceHistory.groups(data.transactions) }

    /// The most recent earlier price of an item, not counting transaction `excluding`.
    public func previousPrice(of name: String, before date: String, excluding txId: String? = nil) -> PriceHistory.Point? {
        PriceHistory.previousPrice(of: name, before: date, excluding: txId, in: data.transactions)
    }

    // MARK: backup

    public func exportJSON() throws -> Data { try data.encoded(pretty: true) }

    /// Restores a backup. If the file is not a valid backup, nothing changes and the error is thrown.
    public func importJSON(_ json: Data) throws {
        data = try BudgetData.decode(json)
        for c in data.categories { changed(.categories, c.id) }
        for t in data.transactions { changed(.transactions, t.id) }
        save()
    }

    public func reset() {
        data = .initial()
        save()
    }
}
