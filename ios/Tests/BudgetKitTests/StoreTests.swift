import XCTest
@testable import BudgetKit

/// The same checks as the web app's tests/logic.test.mjs, plus more.
final class StoreTests: XCTestCase {
    let P = "sp_personal_tosve", M = "sp_personal_milica", H = "sp_house"

    func fresh() -> BudgetStore { BudgetStore(storage: MemoryStorage()) }
    func cat(_ s: BudgetStore, _ space: String, _ name: String, _ kind: EntryKind = .expense) -> String {
        s.categories(in: space, includeArchived: true).first { $0.name == name && $0.kind == kind }!.id
    }

    func testMoneyTyping() {
        let cases: [String: Int?] = ["12": 1200, "12,5": 1250, "12.50": 1250, "0,99": 99, "1.299,00": 129900,
                                     "1,299.00": 129900, " 7 ": 700, "": nil, "abc": nil, "1e3": nil, "0x10": nil,
                                     "−5": nil, "-5": nil, "12,50 €": 1250, "\u{00A0}3,20\u{2003}": 320,
                                     "1.000": 100000, "1.000.000": 100000000, "12.500,50": 1250050, "0.500": 50, "1.0000": 100]
        for (input, want) in cases { XCTAssertEqual(Money.cents(input), want, input) }
        XCTAssertEqual(Money.cents("0.1")! + Money.cents("0.2")!, 30) // no floating point drift
        XCTAssertEqual(Money.cents("1,15"), 115)
        XCTAssertEqual(Money.cents("2,675"), 268)
    }

    func testMoneyDisplay() {
        let sl = Locale(identifier: "sl_SI")
        // Slovenian groups thousands from 10.000 up (Apple writes 1234,50 €, older systems 1.234,50 €).
        XCTAssertEqual(Money.format(1234550, locale: sl).replacingOccurrences(of: "\u{00A0}", with: " "), "12.345,50 €")
        XCTAssertTrue(["1234,50 €", "1.234,50 €"].contains(Money.format(123450, locale: sl).replacingOccurrences(of: "\u{00A0}", with: " ")))
        XCTAssertEqual(Money.format(500, locale: sl).replacingOccurrences(of: "\u{00A0}", with: " "), "5 €")
        XCTAssertEqual(Money.inputText(1250), "12,50")
        XCTAssertEqual(Money.inputText(1205), "12,05")
        XCTAssertEqual(Money.inputText(1200), "12")
        XCTAssertEqual(Money.inputText(0), "")
        XCTAssertEqual(Money.inputText(-30), "-0,30")
        for c in [1, 99, 100, 1234, 99999, 123456789] { XCTAssertEqual(Money.cents(Money.inputText(c)), c) }
        XCTAssertEqual(Money.percentChange(now: 139, before: 109), 27.5)
        XCTAssertEqual(Money.percentChange(now: 100, before: 120), -16.7)
        XCTAssertNil(Money.percentChange(now: 1, before: 0))
    }

    func testMonthsAndDays() {
        XCTAssertEqual(DateKey.shift(month: "2026-12", by: 1), "2027-01")
        XCTAssertEqual(DateKey.shift(month: "2026-01", by: -1), "2025-12")
        XCTAssertEqual(DateKey.shift(month: "2026-01", by: -25), "2023-12")
        XCTAssertEqual(DateKey.shift(month: "2026-05", by: 0), "2026-05")
        XCTAssertTrue(DateKey.isValidDay("2028-02-29"))
        XCTAssertFalse(DateKey.isValidDay("2026-02-29"))
        XCTAssertFalse(DateKey.isValidDay("2026-13-01"))
        XCTAssertFalse(DateKey.isValidDay("26-1-1"))
        let d = DateKey.date(fromDay: "2026-11-25")!
        XCTAssertEqual(DateKey.day(d), "2026-11-25")
        XCTAssertEqual(DateKey.month(d), "2026-11")
        XCTAssertEqual(DateKey.timestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
    }

    func testInitialDataHasAllCategoriesInTheRightSpaces() {
        let d = BudgetData.initial()
        func names(_ sp: String, _ k: EntryKind) -> [String] { d.categories.filter { $0.spaceId == sp && $0.kind == k }.map(\.name) }
        for sp in [P, M] {
            for n in ["Car", "Rent", "Groceries", "Food & Drinks", "Lunch at work", "Nicotine", "Gym & Sports", "Shopping", "Gas",
                      "Traveling", "Saving", "Partner balance", "Investing", "Cash (ATM)", "Barber", "Beauty", "Toiletries"] {
                XCTAssertTrue(names(sp, .expense).contains(n), "\(sp) missing \(n)")
            }
        }
        XCTAssertEqual(names(H, .expense), ["Groceries", "Savings", "Shopping", "Travel", "Unexpected expenses"])
        XCTAssertTrue(names(M, .income).contains("Partner balance"))
        XCTAssertFalse(names(P, .income).contains("Partner balance"))
        XCTAssertEqual(Set(d.categories.map(\.id)).count, d.categories.count, "category ids unique")
        XCTAssertTrue(d.categories.allSatisfy { $0.id.range(of: #"^cat_[0-9a-f]{16}$"#, options: .regularExpression) != nil })
    }

    func testMonthlySummaryOnlyCountsThatMonthAndSpace() {
        let s = fresh()
        s.updateCategory(cat(s, P, "Groceries"), budget: 30000)
        s.updateCategory(cat(s, P, "Rent"), budget: 50000)
        s.addTransaction(spaceId: P, categoryId: cat(s, P, "Groceries"), kind: .expense, amount: 4550, date: "2026-11-03")
        s.addTransaction(spaceId: P, categoryId: cat(s, P, "Groceries"), kind: .expense, amount: 1000, date: "2026-11-30")
        s.addTransaction(spaceId: P, categoryId: cat(s, P, "Groceries"), kind: .expense, amount: 9999, date: "2026-10-31")
        s.addTransaction(spaceId: P, categoryId: cat(s, P, "Salary", .income), kind: .income, amount: 200000, date: "2026-11-01")
        s.addTransaction(spaceId: H, categoryId: cat(s, H, "Groceries"), kind: .expense, amount: 777, date: "2026-11-05")
        let sum = s.monthSummary(spaceId: P, month: "2026-11")
        XCTAssertEqual(sum.spent, 5550)
        XCTAssertEqual(sum.income, 200000)
        XCTAssertEqual(sum.budget, 80000)
        XCTAssertEqual(sum.left, 74450)
        XCTAssertFalse(sum.isOverBudget)
        XCTAssertEqual(sum.byCategory[cat(s, P, "Groceries")], 5550)
        XCTAssertEqual(s.monthSummary(spaceId: H, month: "2026-11").spent, 777)
        XCTAssertEqual(s.monthSummary(spaceId: M, month: "2026-11").count, 0)
        // "2026-1" must not match "2026-11".
        XCTAssertEqual(s.monthSummary(spaceId: P, month: "2026-10").spent, 9999)
    }

    func testOverBudget() {
        let s = fresh()
        s.updateCategory(cat(s, P, "Gas"), budget: 1000)
        s.addTransaction(spaceId: P, categoryId: cat(s, P, "Gas"), kind: .expense, amount: 1500, date: "2026-11-03")
        let sum = s.monthSummary(spaceId: P, month: "2026-11")
        XCTAssertTrue(sum.isOverBudget)
        XCTAssertEqual(sum.left, -500)
        XCTAssertEqual(sum.usedFraction, 1)
    }

    func testHiddenCategoriesDropOutOfBudgetButKeepEntries() {
        let s = fresh()
        let car = cat(s, P, "Car")
        s.updateCategory(car, budget: 10000)
        s.addTransaction(spaceId: P, categoryId: car, kind: .expense, amount: 500, date: "2026-11-02")
        s.updateCategory(car, archived: true)
        XCTAssertEqual(s.monthSummary(spaceId: P, month: "2026-11").budget, 0)
        XCTAssertEqual(s.transactions(in: P, month: "2026-11").count, 1)
        XCTAssertFalse(s.categories(in: P).contains { $0.id == car })
        XCTAssertTrue(s.categories(in: P, includeArchived: true).contains { $0.id == car })
    }

    func testPersonalSpacesAreSeparatePerPerson() {
        let s = fresh()
        XCTAssertEqual(s.personalSpace()?.id, P)
        s.setCurrentUser("u_milica")
        XCTAssertEqual(s.personalSpace()?.id, M)
        let t = s.addTransaction(spaceId: H, categoryId: cat(s, H, "Travel"), kind: .expense, amount: 100, date: "2026-11-01")
        XCTAssertEqual(t.createdBy, "u_milica")
        s.setCurrentUser("u_nobody") // ignored
        XCTAssertEqual(s.currentUser.id, "u_milica")
    }

    func testEditDeleteReorderAddCategory() {
        let s = fresh()
        var tick = 0.0
        s.now = { tick += 1; return Date(timeIntervalSince1970: 1_800_000_000 + tick) }
        let t = s.addTransaction(spaceId: P, categoryId: cat(s, P, "Gas"), kind: .expense, amount: 100, date: "2026-11-01")
        s.updateTransaction(t.id) { $0.amount = 250; $0.id = "hacked"; $0.items = [] }
        let edited = s.transactions(in: P)[0]
        XCTAssertEqual(edited.amount, 250)
        XCTAssertEqual(edited.id, t.id, "id can't change")
        XCTAssertNil(edited.items, "empty item list is not saved")
        XCTAssertGreaterThan(edited.updatedAt, edited.createdAt)
        s.deleteTransaction(t.id)
        XCTAssertEqual(s.transactions(in: P).count, 0)
        s.deleteTransaction("nope") // no crash

        let first = s.categories(in: P, kind: .expense)
        s.moveCategory(first[1].id, by: -1)
        let after = s.categories(in: P, kind: .expense)
        XCTAssertEqual(after[0].id, first[1].id)
        XCTAssertEqual(after[1].id, first[0].id)
        s.moveCategory(after[0].id, by: -1) // already first
        s.moveCategory(after.last!.id, by: 1) // already last
        XCTAssertEqual(s.categories(in: P, kind: .expense).map(\.id), after.map(\.id))
        let pets = s.addCategory(spaceId: P, name: "Pets", kind: .expense, budget: 2000)
        XCTAssertEqual(s.categories(in: P, kind: .expense).last?.id, pets.id)
        XCTAssertEqual(Set(s.data.categories.map(\.order)).count, s.data.categories.count, "orders stay unique")
    }

    func testDragAndDropReorder() {
        let s = fresh()
        let before = s.categories(in: H, kind: .expense).map(\.id)
        let income = s.categories(in: H, kind: .income).map(\.id)
        s.reorderCategories(in: H, kind: .expense, ids: [before[4], before[0], "unknown", before[4]])
        XCTAssertEqual(s.categories(in: H, kind: .expense).map(\.id), [before[4], before[0], before[1], before[2], before[3]])
        XCTAssertEqual(s.categories(in: H, kind: .income).map(\.id), income, "other kind untouched")
        XCTAssertEqual(Set(s.data.categories.map(\.order)).count, s.data.categories.count)
    }

    func testDataSurvivesReloadAndBackupRoundTrips() throws {
        let mem = MemoryStorage()
        let s = BudgetStore(storage: mem)
        s.addTransaction(spaceId: P, categoryId: cat(s, P, "Barber"), kind: .expense, amount: 1500, date: "2026-11-01",
                         items: [ReceiptItem(name: "Cut", price: 1500)], receiptId: "rc_1")
        let s2 = BudgetStore(storage: mem)
        XCTAssertEqual(s2.transactions(in: P).count, 1)
        XCTAssertEqual(s2.transactions(in: P)[0].items?[0].name, "Cut")
        let backup = try s2.exportJSON()
        let s3 = fresh()
        try s3.importJSON(backup)
        XCTAssertEqual(s3.data, s2.data)
        XCTAssertThrowsError(try s3.importJSON(Data(#"{"hello":1}"#.utf8))) { XCTAssertEqual($0 as? BudgetError, .unsupportedVersion(0)) }
        XCTAssertThrowsError(try s3.importJSON(Data("not json".utf8))) { XCTAssertEqual($0 as? BudgetError, .notABackup) }
        XCTAssertThrowsError(try s3.importJSON(Data(#"{"schemaVersion":1,"settings":{},"users":[],"spaces":[],"categories":[]}"#.utf8))) {
            XCTAssertEqual($0 as? BudgetError, .missing("transactions"))
        }
        XCTAssertThrowsError(try s3.importJSON(Data(#"{"schemaVersion":2}"#.utf8))) { XCTAssertEqual($0 as? BudgetError, .unsupportedVersion(2)) }
        // Right shape, wrong contents (amount is text): refused, not half-loaded.
        var bad = try JSONSerialization.jsonObject(with: backup) as! [String: Any]
        var txs = bad["transactions"] as! [[String: Any]]
        txs[0]["amount"] = "lots"
        bad["transactions"] = txs
        XCTAssertThrowsError(try s3.importJSON(try JSONSerialization.data(withJSONObject: bad)))
        XCTAssertEqual(s3.transactions(in: P).count, 1, "failed import keeps old data")
    }

    func testDamagedSavedFileStartsFreshInsteadOfCrashing() {
        for junk in ["{broken", "", "[]", "null", #"{"schemaVersion":1}"#] {
            let s = BudgetStore(storage: MemoryStorage(Data(junk.utf8)))
            XCTAssertEqual(s.data.transactions.count, 0, junk)
            XCTAssertEqual(s.data.spaces.count, 3, junk)
        }
    }

    func testFullPhoneDoesNotLoseTheChangeInMemory() {
        let mem = MemoryStorage()
        let s = BudgetStore(storage: mem)
        mem.failSaves = true
        s.addTransaction(spaceId: P, categoryId: cat(s, P, "Gas"), kind: .expense, amount: 100, date: "2026-11-01")
        XCTAssertNotNil(s.lastSaveError)
        XCTAssertEqual(s.transactions(in: P).count, 1)
        mem.failSaves = false
        s.renameUser("u_tosve", to: "Tosve")
        XCTAssertNil(s.lastSaveError)
        XCTAssertEqual(BudgetStore(storage: mem).transactions(in: P).count, 1, "saved on the next successful save")
    }

    func testFileStorageSavesAndReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString)/sub")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let fs = FileStorage(url: dir.appendingPathComponent("budget.json"))
        let s = BudgetStore(storage: fs)
        s.renameUser("u_milica", to: "  Mili  ")
        s.renameUser("u_milica", to: "   ") // ignored
        XCTAssertEqual(BudgetStore(storage: fs).user("u_milica")?.name, "Mili")
    }

    func testChangesAreAnnounced() {
        let s = fresh()
        var calls = 0
        s.onChange = { _ in calls += 1 }
        s.setCurrency("EUR")
        s.addCategory(spaceId: H, name: "Pets", kind: .expense)
        XCTAssertEqual(calls, 2)
    }

    func testPriceComparisonFindsLatestEarlierPurchase() {
        let s = fresh()
        let G = cat(s, P, "Groceries")
        s.addTransaction(spaceId: P, categoryId: G, kind: .expense, amount: 1, date: "2026-09-01", items: [ReceiptItem(name: "MLEKO 3,5% 1L", price: 109)])
        let oct = s.addTransaction(spaceId: H, categoryId: cat(s, H, "Groceries"), kind: .expense, amount: 1, date: "2026-10-01", items: [ReceiptItem(name: "Mleko 3,5%  1L", price: 119)])
        s.addTransaction(spaceId: P, categoryId: G, kind: .expense, amount: 1, date: "2026-12-01", items: [ReceiptItem(name: "mleko 3,5% 1l", price: 139)])
        let prev = s.previousPrice(of: "Mleko 3,5% 1L", before: "2026-11-15")
        XCTAssertEqual(prev?.date, "2026-10-01")
        XCTAssertEqual(prev?.price, 119)
        XCTAssertEqual(s.previousPrice(of: "Mleko 3,5% 1L", before: "2026-11-15", excluding: oct.id)?.price, 109)
        XCTAssertNil(s.previousPrice(of: "Kruh", before: "2026-11-15"))
        let hist = s.itemHistory()[PriceHistory.normalize("MLEKO 3,5% 1L")]!
        XCTAssertEqual(hist.entries.map(\.price), [109, 119, 139])
        XCTAssertEqual(hist.previous?.price, 119)
        XCTAssertEqual(hist.changeSinceFirst, 27.5)
        XCTAssertEqual(PriceHistory.list(s.data.transactions, search: "mle").count, 1)
        XCTAssertEqual(PriceHistory.list(s.data.transactions, search: "kruh").count, 0)
    }

    func testItemNamesMatchDespiteCaseAccentsAndPunctuation() {
        XCTAssertEqual(PriceHistory.normalize("Čokolada  MILKA, 100g"), PriceHistory.normalize("cokolada milka 100g"))
        XCTAssertNotEqual(PriceHistory.normalize("Mleko 1L"), PriceHistory.normalize("Mleko 0,5L"))
        XCTAssertEqual(PriceHistory.normalize("  --  "), "")
    }

    func testPartnerBalanceEvensOutPersonalIncome() {
        XCTAssertEqual(PartnerBalance.transfer(("a", 300000), ("b", 200000)), .init(fromUserId: "a", toUserId: "b", amount: 50000))
        XCTAssertEqual(PartnerBalance.transfer(("a", 100000), ("b", 200001)), .init(fromUserId: "b", toUserId: "a", amount: 50000))
        XCTAssertNil(PartnerBalance.transfer(("a", 5), ("b", 5)))
        XCTAssertNil(PartnerBalance.transfer(("a", 1), ("b", 0)))
        let s = fresh()
        s.addTransaction(spaceId: P, categoryId: cat(s, P, "Salary", .income), kind: .income, amount: 250000, date: "2026-11-01")
        s.addTransaction(spaceId: M, categoryId: cat(s, M, "Salary", .income), kind: .income, amount: 150000, date: "2026-11-01")
        // Money already received as partner balance does not count as her own income.
        s.addTransaction(spaceId: M, categoryId: cat(s, M, "Partner balance", .income), kind: .income, amount: 50000, date: "2026-11-02")
        XCTAssertEqual(s.suggestedPartnerTransfer(month: "2026-11"), .init(fromUserId: "u_tosve", toUserId: "u_milica", amount: 50000))
        XCTAssertNil(s.suggestedPartnerTransfer(month: "2026-10"))
    }

    /// Random edits never break the basic rules: totals add up, every entry is counted once,
    /// and saving + reloading gives the same data.
    func testRandomEditsKeepTotalsConsistent() throws {
        var rng = SeededRandom(seed: 42)
        let mem = MemoryStorage()
        let s = BudgetStore(storage: mem)
        let months = ["2026-10", "2026-11", "2026-12"]
        for _ in 0..<2000 {
            let sp = [P, M, H].randomElement(using: &rng)!
            let cats = s.categories(in: sp, includeArchived: true)
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...4:
                let c = cats.randomElement(using: &rng)!
                s.addTransaction(spaceId: sp, categoryId: c.id, kind: c.kind, amount: Int.random(in: 1...500000, using: &rng),
                                 date: "\(months.randomElement(using: &rng)!)-\(String(format: "%02d", Int.random(in: 1...28, using: &rng)))")
            case 5:
                if let t = s.data.transactions.randomElement(using: &rng) { s.deleteTransaction(t.id) }
            case 6:
                if let t = s.data.transactions.randomElement(using: &rng) { s.updateTransaction(t.id) { $0.amount = Int.random(in: 1...9999, using: &rng) } }
            case 7: s.updateCategory(cats.randomElement(using: &rng)!.id, budget: Int.random(in: 0...100000, using: &rng))
            case 8: s.updateCategory(cats.randomElement(using: &rng)!.id, archived: Bool.random(using: &rng))
            default: s.moveCategory(cats.randomElement(using: &rng)!.id, by: Bool.random(using: &rng) ? 1 : -1)
            }
        }
        for sp in [P, M, H] {
            var seen = 0
            for m in months {
                let sum = s.monthSummary(spaceId: sp, month: m)
                XCTAssertEqual(sum.income + sum.spent, sum.byCategory.values.reduce(0, +))
                XCTAssertEqual(sum.budget, s.categories(in: sp, kind: .expense).reduce(0) { $0 + $1.budget })
                seen += sum.count
            }
            XCTAssertEqual(seen, s.transactions(in: sp).count)
        }
        XCTAssertEqual(Set(s.data.categories.map(\.order)).count, s.data.categories.count)
        XCTAssertEqual(BudgetStore(storage: mem).data, s.data)
    }
}

/// Repeatable random numbers for tests.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
