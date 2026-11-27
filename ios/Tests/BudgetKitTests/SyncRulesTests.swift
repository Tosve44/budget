import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BudgetKit

/// Rules that keep syncing from getting stuck (found by testing the web app; the iPhone follows them too).
final class LimitsTests: XCTestCase {
    let P = "sp_personal_tosve"

    func testEntriesStayInsideTheDatabaseLimits() {
        let s = BudgetStore(storage: nil)
        let gas = s.categories(in: P, kind: .expense).first { $0.name == "Gas" }!.id
        var d = EntryDraft(spaceId: P, categoryId: gas, date: "2026-11-25")
        d.amountText = "10000000" // 10 million euros = 1,000,000,000 cents
        XCTAssertThrowsError(try d.check()) { XCTAssertEqual($0.localizedDescription, "That amount is too big.") }
        d.amountText = "9999999,99"
        XCTAssertNoThrow(try d.check())
        d.note = String(repeating: "a", count: 501)
        XCTAssertThrowsError(try d.check()) { XCTAssertEqual($0 as? EntryDraft.Problem, .noteTooLong) }
        d.note = String(repeating: "č", count: 500)
        XCTAssertNoThrow(try d.check(), "500 characters is fine, even with letters like č")
        d.note = ""
        d.lines = (0..<301).map { .init(name: "Item \($0)", priceText: "1") }
        XCTAssertThrowsError(try d.check()) { XCTAssertEqual($0 as? EntryDraft.Problem, .tooManyItems) }
        d.lines = [.init(name: String(repeating: "x", count: 200), priceText: "1")]
        XCTAssertEqual(try d.check().items.first?.name.count, Limits.itemName, "long item names are shortened")
    }

    func testCategoriesStayInsideTheLimits() {
        let s = BudgetStore(storage: nil)
        let c = s.addCategory(spaceId: P, name: String(repeating: "N", count: 100), kind: .expense, budget: 5_000_000_000)
        XCTAssertEqual(c.name.count, Limits.categoryName)
        XCTAssertEqual(c.budget, Limits.maxCents)
        s.updateCategory(c.id, name: String(repeating: "M", count: 61), budget: -5)
        let now = s.category(c.id)!
        XCTAssertEqual(now.name.count, 60)
        XCTAssertEqual(now.budget, 0)
    }

    func testSameCategoryNameTwiceIsRefused() {
        let s = BudgetStore(storage: nil)
        XCTAssertTrue(s.categoryNameTaken(" groceries ", spaceId: P, kind: .expense))
        XCTAssertFalse(s.categoryNameTaken("Groceries", spaceId: P, kind: .income), "other kind is fine")
        XCTAssertFalse(s.categoryNameTaken("Pets", spaceId: P, kind: .expense))
        let g = s.categories(in: P, kind: .expense).first { $0.name == "Groceries" }!
        XCTAssertFalse(s.categoryNameTaken("GROCERIES", spaceId: P, kind: .expense, excluding: g.id), "renaming itself")
        s.updateCategory(g.id, archived: true)
        XCTAssertFalse(s.categoryNameTaken("Groceries", spaceId: P, kind: .expense), "hidden ones don't count")
    }

    func testUploadedRowsAreAlwaysInsideTheLimits() {
        // An old record or an imported backup over the limits must never block the whole upload.
        let t = Transaction(id: "tx_1", spaceId: P, categoryId: "c", kind: .expense, amount: 5_000_000_000, date: "2026-11-25",
                            note: String(repeating: "n", count: 900), createdBy: "u", createdAt: "x", updatedAt: "x",
                            items: (0..<400).map { _ in ReceiptItem(name: String(repeating: "i", count: 300), price: 1) })
        let r = CloudRows.row(t, receiptPath: nil)
        XCTAssertEqual(r["amount"] as? Int, Limits.maxCents)
        XCTAssertEqual((r["note"] as? String)?.count, 500)
        let items = r["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 300)
        XCTAssertEqual((items[0]["name"] as? String)?.count, 120)
        let c = Category(id: "c", spaceId: P, name: String(repeating: "c", count: 99), kind: .expense, budget: -1, order: 0)
        XCTAssertEqual((CloudRows.row(c)["name"] as? String)?.count, 60)
    }

    func testEditingAnEntryThePartnerDeletedSavesItAsNew() throws {
        let s = BudgetStore(storage: nil)
        let gas = s.categories(in: P, kind: .expense).first { $0.name == "Gas" }!.id
        let t = s.addTransaction(spaceId: P, categoryId: gas, kind: .expense, amount: 1000, date: "2026-11-01")
        var d = EntryDraft(editing: t)
        XCTAssertFalse(d.wasDeletedMeanwhile(in: s))
        s.deleteTransaction(t.id) // the partner's deletion arrives by sync
        XCTAssertTrue(d.wasDeletedMeanwhile(in: s), "the screen tells the person")
        d.amountText = "12"
        _ = try d.save(to: s)
        XCTAssertEqual(s.data.transactions.map(\.amount), [1200], "not lost")
    }

    func testOldSyncStateStillLoads() throws {
        // Saved by the first version of the app, before categoryTombstones existed.
        let old = #"{"userId":"u1","householdId":"h1","lastPull":{},"dirtyCategories":["c1"],"dirtyTransactions":[],"tombstones":{},"uploaded":{}}"#
        let meta = try JSONDecoder().decode(SyncMeta.self, from: Data(old.utf8))
        XCTAssertEqual(meta.householdId, "h1")
        XCTAssertEqual(meta.dirtyCategories, ["c1"])
        XCTAssertTrue(meta.categoryTombstones.isEmpty)
        let again = try JSONDecoder().decode(SyncMeta.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(again, meta)
    }
}

/// A connection that never answers.
struct HangingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        while true { try await Task.sleep(nanoseconds: 50_000_000) } // stops only when cancelled
    }
}

final class TimeoutTests: XCTestCase {
    func testAHungConnectionGivesUpInsteadOfFreezingSync() async throws {
        let client = SupabaseClient(url: URL(string: "https://example.test")!, anonKey: "sb_publishable_x", transport: HangingTransport())
        client.requestTimeout = 0.3
        let start = Date()
        do {
            try await client.signIn(email: "a@b.c", password: "x")
            XCTFail("must give up")
        } catch {
            XCTAssertEqual(error as? SupabaseError, .network("Timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "gave up quickly")
        XCTAssertEqual(client.requestTimeout, 0.3)
        XCTAssertEqual(client.uploadTimeout, 90, "photos get longer")
        XCTAssertEqual(SupabaseClient(url: URL(string: "https://x.test")!, anonKey: "k").requestTimeout, 20)
    }
}

extension SyncIntegrationTests {
    /// Both phones add "Pets" while offline. After syncing they agree on one Pets category
    /// (the lowest id) that holds both entries, and the database has only one visible Pets.
    func testSameCategoryAddedOnBothPhonesOfflineIsMergedIntoOne() async throws {
        let T = phone(), M = phone()
        _ = try await T.sync.signUp(email: email("dup-t"), password: "secret123")
        let code = try await T.sync.createHousehold(displayName: "Tosve")
        M.store.setCurrentUser("u_milica")
        _ = try await M.sync.signUp(email: email("dup-m"), password: "secret456")
        try await M.sync.joinHousehold(code: code, displayName: "Milica")

        // Offline on both phones (nothing synced in between).
        let tp = T.store.addCategory(spaceId: T.house.id, name: "Pets", kind: .expense, budget: 5000)
        let mp = M.store.addCategory(spaceId: M.house.id, name: " pets", kind: .expense)
        let te = T.store.addTransaction(spaceId: T.house.id, categoryId: tp.id, kind: .expense, amount: 1500, date: "2026-11-20", note: "food")
        let me = M.store.addTransaction(spaceId: M.house.id, categoryId: mp.id, kind: .expense, amount: 900, date: "2026-11-21", note: "toy")
        // A hidden duplicate is left alone.
        let hidden = M.store.addCategory(spaceId: M.house.id, name: "PETS", kind: .expense)
        M.store.updateCategory(hidden.id, archived: true)
        let winner = min(tp.id, mp.id)

        try await T.sync.syncNow()
        try await M.sync.syncNow()
        try await T.sync.syncNow()
        try await M.sync.syncNow()

        for (who, p) in [("Tosve", T), ("Milica", M)] {
            let pets = p.store.categories(in: p.house.id, kind: .expense).filter { $0.name.lowercased().contains("pets") }
            XCTAssertEqual(pets.map(\.id), [winner], "\(who) has one Pets")
            XCTAssertEqual(p.entry(te.id)?.categoryId, winner, "\(who): Tosve's entry moved")
            XCTAssertEqual(p.entry(me.id)?.categoryId, winner, "\(who): Milica's entry moved")
            XCTAssertEqual(p.sync.pendingCount, 0, "\(who): all uploaded")
        }
        XCTAssertTrue(M.store.categories(in: M.house.id, includeArchived: true, kind: .expense).contains { $0.id == hidden.id },
                      "hidden category kept")
        let cloud = try await T.client.select("categories", filters: [("space_id", "eq.\(T.house.id)"), ("deleted", "eq.false"), ("archived", "eq.false")])
        XCTAssertEqual(cloud.filter { ($0["name"] as? String)?.lowercased().contains("pets") == true }.count, 1, "one Pets in the cloud")
        let tx = try await T.client.select("transactions", filters: [("id", SupabaseClient.inList([te.id, me.id]))])
        XCTAssertEqual(Set(tx.compactMap { $0["category_id"] as? String }), [winner])
    }
}
