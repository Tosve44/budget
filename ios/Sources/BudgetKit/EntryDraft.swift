import Foundation

/// What the "add / edit entry" screen holds while you type. Kept here (not in the screen)
/// so the rules can be tested without a phone.
public struct EntryDraft: Equatable, Sendable {
    public struct Line: Equatable, Identifiable, Sendable {
        public var id = UUID()
        public var name: String
        public var priceText: String
        public init(name: String, priceText: String) { self.name = name; self.priceText = priceText }
        public init(_ item: ReceiptItem) { name = item.name; priceText = Money.inputText(item.price, emptyForZero: false) }
    }

    public var existingId: String?
    public var spaceId: String
    public var kind: EntryKind
    public var categoryId: String?
    public var amountText: String
    public var date: String
    public var note: String
    public var lines: [Line]
    public var receiptId: String?

    public init(spaceId: String, kind: EntryKind = .expense, categoryId: String? = nil, date: String) {
        self.spaceId = spaceId; self.kind = kind; self.categoryId = categoryId
        amountText = ""; self.date = date; note = ""; lines = []
    }

    public init(editing t: Transaction) {
        existingId = t.id; spaceId = t.spaceId; kind = t.kind; categoryId = t.categoryId
        amountText = Money.inputText(t.amount, emptyForZero: false); date = t.date; note = t.note
        lines = (t.items ?? []).map(Line.init); receiptId = t.receiptId
    }

    public enum Problem: Error, Equatable, LocalizedError {
        case amount, category, date, itemPrice(String)
        public var errorDescription: String? {
            switch self {
            case .amount: return "Enter an amount bigger than 0."
            case .category: return "Pick a category."
            case .date: return "Pick a date."
            case .itemPrice(let n): return "Check the price of \"\(n)\"."
            }
        }
    }

    /// Receipt lines that have a name; a line with a name but no readable price is a problem.
    public func items() throws -> [ReceiptItem] {
        try lines.compactMap { l in
            let name = l.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return nil }
            guard let p = Money.cents(l.priceText), p >= 0 else { throw Problem.itemPrice(name) }
            return ReceiptItem(name: name, price: p)
        }
    }

    public struct Checked: Equatable, Sendable {
        public var amount: Int, categoryId: String, items: [ReceiptItem]
    }

    public func check() throws -> Checked {
        guard let a = Money.cents(amountText), a > 0 else { throw Problem.amount }
        guard let c = categoryId, !c.isEmpty else { throw Problem.category }
        guard DateKey.isValidDay(date) else { throw Problem.date }
        return Checked(amount: a, categoryId: c, items: try items())
    }

    /// Saves the draft as a new entry or over the one being edited. Returns the entry.
    @discardableResult
    public func save(to store: BudgetStore) throws -> Transaction {
        let ok = try check()
        if let id = existingId, store.data.transactions.contains(where: { $0.id == id }) {
            store.updateTransaction(id) { t in
                t.kind = kind; t.categoryId = ok.categoryId; t.amount = ok.amount; t.date = date
                t.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                t.items = ok.items; t.receiptId = receiptId
            }
            return store.data.transactions.first { $0.id == id }!
        }
        return store.addTransaction(spaceId: spaceId, categoryId: ok.categoryId, kind: kind, amount: ok.amount, date: date,
                                    note: note.trimmingCharacters(in: .whitespacesAndNewlines), items: ok.items, receiptId: receiptId)
    }

    /// Fills in the receipt lines from the text read off a photo, and the amount from the printed
    /// total (SKUPAJ / ZA PLAČILO), or the sum of the lines when no total was found.
    /// Returns how many lines were found.
    @discardableResult
    public mutating func applyReceiptText(_ text: String) -> Int {
        let found = ReceiptParser.parse(text)
        lines = found.map(Line.init)
        if let total = ReceiptParser.findTotal(text) {
            amountText = Money.inputText(total, emptyForZero: false)
        } else if !found.isEmpty, Money.cents(amountText) == nil {
            amountText = Money.inputText(found.reduce(0) { $0 + $1.price }, emptyForZero: false)
        }
        return found.count
    }

    public var linesTotal: Int { lines.compactMap { Money.cents($0.priceText) }.reduce(0, +) }

    /// How a receipt line compares with the last time the same item was bought.
    public enum Comparison: Equatable, Sendable {
        case new
        case same(before: Int, date: String)
        case up(percent: Double, before: Int, date: String)
        case down(percent: Double, before: Int, date: String)
    }

    public func comparison(for line: Line, in store: BudgetStore) -> Comparison? {
        guard let price = Money.cents(line.priceText), !line.name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let prev = store.previousPrice(of: line.name, before: date, excluding: existingId) else { return .new }
        guard let pct = Money.percentChange(now: price, before: prev.price), pct != 0 else {
            return .same(before: prev.price, date: prev.date)
        }
        return pct > 0 ? .up(percent: pct, before: prev.price, date: prev.date) : .down(percent: pct, before: prev.price, date: prev.date)
    }
}
