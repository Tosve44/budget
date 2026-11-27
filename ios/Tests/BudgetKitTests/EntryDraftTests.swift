import XCTest
@testable import BudgetKit

/// The rules behind the "add / edit entry" screen.
final class EntryDraftTests: XCTestCase {
    let P = "sp_personal_tosve"

    func cat(_ s: BudgetStore, _ name: String, _ kind: EntryKind = .expense) -> String {
        s.categories(in: P, kind: kind).first { $0.name == name }!.id
    }

    func testRefusesBadInputWithClearMessages() {
        let s = BudgetStore(storage: nil)
        var d = EntryDraft(spaceId: P, date: "2026-11-25")
        XCTAssertThrowsError(try d.save(to: s)) { XCTAssertEqual($0.localizedDescription, "Enter an amount bigger than 0.") }
        for bad in ["", "0", "-5", "abc", "0,00"] {
            d.amountText = bad
            XCTAssertThrowsError(try d.check(), bad)
        }
        d.amountText = "12,50"
        XCTAssertThrowsError(try d.save(to: s)) { XCTAssertEqual($0.localizedDescription, "Pick a category.") }
        d.categoryId = cat(s, "Gas")
        d.date = "2026-02-30"
        XCTAssertThrowsError(try d.save(to: s)) { XCTAssertEqual($0.localizedDescription, "Pick a date.") }
        d.date = "2026-11-25"
        d.lines = [.init(name: "Kruh", priceText: "zz")]
        XCTAssertThrowsError(try d.save(to: s)) { XCTAssertEqual($0.localizedDescription, "Check the price of \"Kruh\".") }
        XCTAssertEqual(s.data.transactions.count, 0, "nothing saved while something is wrong")
        d.lines = [.init(name: "  ", priceText: "zz"), .init(name: " Kruh ", priceText: "1,49")]
        let t = try! d.save(to: s)
        XCTAssertEqual(t.amount, 1250)
        XCTAssertEqual(t.items, [ReceiptItem(name: "Kruh", price: 149)], "empty lines dropped, names trimmed")
    }

    func testEditingKeepsIdAndAuthorAndUpdatesFields() throws {
        let s = BudgetStore(storage: nil)
        let t = s.addTransaction(spaceId: P, categoryId: cat(s, "Gas"), kind: .expense, amount: 1000, date: "2026-11-01", note: "OMV")
        var d = EntryDraft(editing: t)
        XCTAssertEqual(d.amountText, "10")
        XCTAssertEqual(d.note, "OMV")
        d.amountText = "45,90"
        d.note = "  Petrol  "
        d.kind = .income
        d.categoryId = cat(s, "Salary", .income)
        let saved = try d.save(to: s)
        XCTAssertEqual(saved.id, t.id)
        XCTAssertEqual(s.data.transactions.count, 1)
        XCTAssertEqual(saved.amount, 4590)
        XCTAssertEqual(saved.note, "Petrol")
        XCTAssertEqual(saved.kind, .income)
        XCTAssertEqual(saved.createdBy, t.createdBy)
        // Edited entry was deleted meanwhile (e.g. by sync): saving adds it again instead of losing it.
        s.deleteTransaction(t.id)
        _ = try d.save(to: s)
        XCTAssertEqual(s.data.transactions.count, 1)
    }

    func testReceiptFillsItemsAndTotal() {
        var d = EntryDraft(spaceId: P, date: "2026-11-25")
        XCTAssertEqual(d.applyReceiptText(ReceiptTests.mercator), 5)
        XCTAssertEqual(d.amountText, "7,13", "printed total, with the discount")
        XCTAssertEqual(d.lines.map(\.name).first, "MLEKO ALPSKO 3,5% 1L")
        XCTAssertEqual(d.linesTotal, 743)
        // No total printed: the items are added up, but a typed amount is never overwritten.
        var e = EntryDraft(spaceId: P, date: "2026-11-25")
        e.applyReceiptText("Kruh 1,49\nMleko 1,29")
        XCTAssertEqual(e.amountText, "2,78")
        var f = EntryDraft(spaceId: P, date: "2026-11-25")
        f.amountText = "3"
        f.applyReceiptText("Kruh 1,49\nMleko 1,29")
        XCTAssertEqual(f.amountText, "3")
        var g = EntryDraft(spaceId: P, date: "2026-11-25")
        XCTAssertEqual(g.applyReceiptText("blurry nothing"), 0)
        XCTAssertEqual(g.amountText, "")
    }

    func testPriceComparisonPerLine() throws {
        let s = BudgetStore(storage: nil)
        let old = s.addTransaction(spaceId: P, categoryId: cat(s, "Groceries"), kind: .expense, amount: 1, date: "2026-10-01",
                                   items: [ReceiptItem(name: "MLEKO 1L", price: 119), ReceiptItem(name: "Kruh", price: 149)])
        var d = EntryDraft(spaceId: P, date: "2026-11-25")
        XCTAssertEqual(d.comparison(for: .init(name: "Mleko 1l", priceText: "1,29"), in: s), .up(percent: 8.4, before: 119, date: "2026-10-01"))
        XCTAssertEqual(d.comparison(for: .init(name: "kruh", priceText: "1,49"), in: s), .same(before: 149, date: "2026-10-01"))
        XCTAssertEqual(d.comparison(for: .init(name: "Kruh", priceText: "0,99"), in: s), .down(percent: -33.6, before: 149, date: "2026-10-01"))
        XCTAssertEqual(d.comparison(for: .init(name: "Jajca", priceText: "2,49"), in: s), .new)
        XCTAssertNil(d.comparison(for: .init(name: "Jajca", priceText: ""), in: s))
        // Editing the old receipt does not compare it with itself.
        d = EntryDraft(editing: old)
        XCTAssertEqual(d.comparison(for: d.lines[0], in: s), .new)
    }
}
