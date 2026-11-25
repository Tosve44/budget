import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BudgetKit

/// Syncing tested end to end against a real database with the real privacy rules
/// (see scripts/start-test-backend.sh), or against the real Supabase project.
/// Skipped unless SUPABASE_TEST_URL is set:
///
///   SUPABASE_TEST_URL=http://localhost:54321 swift test
///
/// With WEB_APP_DIR and NODE_MODULES_DIR also set, the second test runs the web app's own sync
/// code as Milica's phone, to prove the iPhone app and the web app share data correctly.
@MainActor
final class SyncIntegrationTests: XCTestCase {
    var baseURL: URL!
    var anonKey = ""
    let run = String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)

    override func setUp() async throws {
        guard let u = ProcessInfo.processInfo.environment["SUPABASE_TEST_URL"], let url = URL(string: u) else {
            throw XCTSkip("Set SUPABASE_TEST_URL to run the sync tests against a test server.")
        }
        baseURL = url
        if let k = ProcessInfo.processInfo.environment["SUPABASE_TEST_ANON_KEY"] {
            anonKey = k
        } else {
            let (data, _) = try await URLSessionTransport().send(URLRequest(url: url.appendingPathComponent("__test/anon-key")))
            anonKey = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["key"] as! String
        }
        try await faults(failNext: 0)
    }

    // MARK: helpers

    final class Phone {
        let store: BudgetStore
        let client: SupabaseClient
        let photos: PhotoStore
        let sync: SyncEngine
        let dataStorage = MemoryStorage()
        @MainActor init(url: URL, key: String, transport: HTTPTransport = URLSessionTransport()) {
            store = BudgetStore(storage: dataStorage)
            client = SupabaseClient(url: url, anonKey: key, transport: transport)
            photos = PhotoStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("sync-photos-\(UUID().uuidString)"))
            let box = MetaBox()
            sync = SyncEngine(store: store, client: client, photos: photos, meta: nil) { box.meta = $0 }
            metaBox = box
        }
        var metaBox: MetaBox
        func cat(_ space: Space?, _ name: String, _ kind: EntryKind = .expense) -> EntryCategoryRef {
            EntryCategoryRef(store.categories(in: space!.id, includeArchived: true).first { $0.name == name && $0.kind == kind }!)
        }
        var house: Space { store.houseSpace! }
        var personal: Space { store.personalSpace()! }
        func entry(_ id: String) -> Transaction? { store.data.transactions.first { $0.id == id } }
    }
    final class MetaBox { var meta: SyncMeta? }
    struct EntryCategoryRef { let c: BudgetKit.Category; init(_ c: BudgetKit.Category) { self.c = c }; var id: String { c.id } }

    func phone(transport: HTTPTransport = URLSessionTransport()) -> Phone { Phone(url: baseURL, key: anonKey, transport: transport) }
    func email(_ n: String) -> String { "\(n)-ios-\(run)@example.test" }

    func faults(failNext: Int) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("__test/faults"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["failNext": failNext])
        _ = try await URLSessionTransport().send(req)
    }

    func pause() async { try? await Task.sleep(nanoseconds: 30_000_000) }

    // MARK: two iPhones

    func testTwoIPhonesShareTheHouseAndKeepPersonalPrivate() async throws {
        let T = phone(), M = phone()

        // Tosve used the app before syncing: his entries are kept and uploaded.
        T.store.addTransaction(spaceId: T.personal.id, categoryId: T.cat(T.personal, "Gas").id, kind: .expense, amount: 6000, date: "2026-11-10")
        T.store.addTransaction(spaceId: T.house.id, categoryId: T.cat(T.house, "Groceries").id, kind: .expense, amount: 4520, date: "2026-11-11",
                               items: [ReceiptItem(name: "Mleko 1L", price: 129)])
        T.store.updateCategory(T.cat(T.house, "Groceries").id, budget: 40000)
        let awaited1 = try await T.sync.signUp(email: email("tosve"), password: "secret123")
        XCTAssertTrue(awaited1)
        let code = try await T.sync.createHousehold(displayName: "Tosve")
        XCTAssertNotNil(code.range(of: #"^[0-9A-F]{8}$"#, options: .regularExpression), code)
        XCTAssertEqual(T.sync.pendingCount, 0, "everything uploaded")
        XCTAssertEqual(T.store.currentUser.name, "Tosve")
        XCTAssertEqual(T.store.transactions(in: T.personal.id).count, 1)
        XCTAssertEqual(T.store.transactions(in: T.house.id).count, 1)
        XCTAssertEqual(T.store.data.settings.inviteCode, code)
        let awaited2 = try await T.client.select("transactions").count
        XCTAssertEqual(awaited2, 2)

        // Milica joins with the code; her House entries merge into the shared categories.
        M.store.setCurrentUser("u_milica")
        M.store.addTransaction(spaceId: M.personal.id, categoryId: M.cat(M.personal, "Beauty").id, kind: .expense, amount: 2500, date: "2026-11-12")
        M.store.addTransaction(spaceId: M.house.id, categoryId: M.cat(M.house, "Groceries").id, kind: .expense, amount: 1800, date: "2026-11-12")
        _ = try await M.sync.signUp(email: email("milica"), password: "secret456")
        do {
            try await M.sync.joinHousehold(code: "NOTACODE", displayName: "Milica")
            XCTFail("a wrong code must be refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That invite code was not found.")
        }
        try await M.sync.joinHousehold(code: code, displayName: "Milica")
        let groceries = M.store.categories(in: M.house.id).filter { $0.name == "Groceries" }
        XCTAssertEqual(groceries.count, 1, "one Groceries category, not two")
        XCTAssertEqual(groceries.first?.budget, 40000, "Tosve's budget is used")
        XCTAssertEqual(M.store.transactions(in: M.house.id).count, 2, "both people's House entries")
        XCTAssertTrue(M.store.transactions(in: M.house.id).allSatisfy { $0.categoryId == groceries[0].id })
        XCTAssertEqual(M.store.transactions(in: M.personal.id).count, 1, "her personal entry kept")
        XCTAssertEqual(M.store.data.users.map(\.name).sorted(), ["Milica", "Tosve"])

        // Personal stays private.
        try await T.sync.syncNow()
        XCTAssertEqual(T.store.data.transactions.count, 3, "his personal entry + 2 House entries")
        XCTAssertFalse(T.store.data.transactions.contains { $0.amount == 2500 }, "Milica's Beauty entry is not on Tosve's phone")
        XCTAssertEqual(T.store.data.spaces.count, 2, "his Personal + House only")
        // Even asking the server directly for her personal space gives nothing.
        let awaited3 = try await T.client.select("transactions", filters: [("space_id", "eq.\(M.personal.id)")]).count
        XCTAssertEqual(awaited3, 0)
        let awaited4 = try await T.client.select("categories", filters: [("space_id", "eq.\(M.personal.id)")]).count
        XCTAssertEqual(awaited4, 0)

        // A House entry added on one phone shows up on the other, with its author.
        let bled = T.store.addTransaction(spaceId: T.house.id, categoryId: T.cat(T.house, "Travel").id, kind: .expense, amount: 12000,
                                          date: "2026-11-15", note: "Bled weekend")
        try await T.sync.syncNow()
        try await M.sync.syncNow()
        let got = try XCTUnwrap(M.entry(bled.id), "arrived")
        XCTAssertEqual(got.note, "Bled weekend")
        XCTAssertEqual(got.createdBy, T.sync.meta.userId)
        XCTAssertEqual(M.store.user(got.createdBy)?.name, "Tosve")

        // Both phones edit the same entry offline: the later edit wins on both, whichever syncs first.
        T.store.updateTransaction(bled.id) { $0.amount = 13000 }
        await pause()
        M.store.updateTransaction(bled.id) { $0.amount = 14000; $0.note = "Bled + parking" }
        try await M.sync.syncNow()
        try await T.sync.syncNow()
        try await M.sync.syncNow()
        for p in [T, M] {
            XCTAssertEqual(p.entry(bled.id)?.amount, 14000)
            XCTAssertEqual(p.entry(bled.id)?.note, "Bled + parking")
        }
        XCTAssertEqual(T.sync.pendingCount, 0)
        T.store.updateTransaction(bled.id) { $0.amount = 15000 }
        await pause()
        M.store.updateTransaction(bled.id) { $0.amount = 16000 }
        try await T.sync.syncNow()
        try await M.sync.syncNow()
        try await T.sync.syncNow()
        for p in [T, M] { XCTAssertEqual(p.entry(bled.id)?.amount, 16000) }

        // Deleting removes it on the other phone.
        M.store.deleteTransaction(bled.id)
        try await M.sync.syncNow()
        try await T.sync.syncNow()
        XCTAssertNil(T.entry(bled.id))
        XCTAssertNil(M.entry(bled.id))

        // Delete on one phone vs a later edit on the other: the later edit wins.
        let shop = T.store.addTransaction(spaceId: T.house.id, categoryId: T.cat(T.house, "Shopping").id, kind: .expense, amount: 999, date: "2026-11-16")
        try await T.sync.syncNow(); try await M.sync.syncNow()
        T.store.deleteTransaction(shop.id)
        await pause()
        M.store.updateTransaction(shop.id) { $0.amount = 1099 }
        try await T.sync.syncNow(); try await M.sync.syncNow(); try await T.sync.syncNow()
        for p in [T, M] { XCTAssertEqual(p.entry(shop.id)?.amount, 1099) }

        // No connection: changes wait on the phone and go up once the connection is back.
        let plumber = M.store.addTransaction(spaceId: M.house.id, categoryId: M.cat(M.house, "Unexpected expenses").id, kind: .expense,
                                             amount: 4200, date: "2026-11-17", note: "Plumber")
        try await faults(failNext: 50)
        do { try await M.sync.syncNow(); XCTFail("should fail without a connection") } catch {}
        if case .error = M.sync.state {} else { XCTFail("state should be error, is \(M.sync.state)") }
        XCTAssertGreaterThanOrEqual(M.sync.pendingCount, 1, "still waiting to upload")
        XCTAssertNotNil(M.entry(plumber.id), "still shown on the phone")
        try await faults(failNext: 0)
        try await M.sync.syncNow()
        XCTAssertEqual(M.sync.pendingCount, 0)
        XCTAssertEqual(M.sync.state, .idle)
        try await T.sync.syncNow()
        XCTAssertNotNil(T.entry(plumber.id))

        // Category changes sync: rename, budget, new category, hide.
        let travel = T.cat(T.house, "Travel").id
        T.store.updateCategory(travel, name: "Holidays", budget: 30000)
        let pets = T.store.addCategory(spaceId: T.house.id, name: "Pets", kind: .expense, budget: 5000)
        T.store.updateCategory(T.cat(T.house, "Savings").id, archived: true)
        let firstTwo = T.store.categories(in: T.house.id, includeArchived: true, kind: .expense).prefix(2).map(\.id)
        T.store.moveCategory(firstTwo[1], by: -1)
        try await T.sync.syncNow(); try await M.sync.syncNow()
        XCTAssertEqual(M.store.category(travel)?.name, "Holidays")
        XCTAssertEqual(M.store.category(travel)?.budget, 30000)
        XCTAssertEqual(M.store.category(pets.id)?.name, "Pets")
        XCTAssertEqual(M.cat(M.house, "Savings").c.archived, true)
        XCTAssertEqual(M.store.categories(in: M.house.id, includeArchived: true, kind: .expense).prefix(2).map(\.id), [firstTwo[1], firstTwo[0]], "new order too")

        // A receipt photo taken on one phone can be opened on the other; deleting removes it.
        let bytes = Data((0..<50_000).map { UInt8(($0 * 31) % 256) })
        let photoId = try T.photos.save(bytes)
        let receipt = T.store.addTransaction(spaceId: T.house.id, categoryId: T.cat(T.house, "Groceries").id, kind: .expense, amount: 839,
                                             date: "2026-11-19", items: [ReceiptItem(name: "Kruh", price: 149)], receiptId: photoId)
        try await T.sync.syncNow(); try await M.sync.syncNow()
        let there = try XCTUnwrap(M.entry(receipt.id))
        XCTAssertEqual(there.receiptId, "cloud:\(there.spaceId)/\(receipt.id).jpg")
        let downloaded = await M.sync.photo(for: there.receiptId!)
        XCTAssertEqual(downloaded, bytes)
        XCTAssertEqual(M.photos.load(there.receiptId!), bytes, "kept on her phone after the first download")
        XCTAssertEqual(T.entry(receipt.id)?.receiptId, photoId, "Tosve keeps his own copy")
        T.store.deleteTransaction(receipt.id)
        try await T.sync.syncNow()
        do {
            _ = try await M.client.download(bucket: "receipts", path: String(there.receiptId!.dropFirst(6)))
            XCTFail("photo should be gone from the cloud")
        } catch {}
        XCTAssertNil(T.photos.load(photoId), "and from his phone")

        // Milica cannot read or add photos in Tosve's personal folder.
        let privateId = try T.photos.save(Data(repeating: 1, count: 100))
        let barber = T.store.addTransaction(spaceId: T.personal.id, categoryId: T.cat(T.personal, "Barber").id, kind: .expense, amount: 1500,
                                            date: "2026-11-19", receiptId: privateId)
        try await T.sync.syncNow()
        do { _ = try await M.client.download(bucket: "receipts", path: "\(T.personal.id)/\(barber.id).jpg"); XCTFail("private photo readable") } catch {}
        do { try await M.client.upload(bucket: "receipts", path: "\(T.personal.id)/evil.jpg", jpeg: Data([1])); XCTFail("upload into his folder allowed") } catch {}
        // ...and cannot write entries into his personal space either.
        let evil = CloudRows.row(Transaction(id: "tx_evil_\(run)", spaceId: T.personal.id, categoryId: T.cat(T.personal, "Barber").id,
                                             kind: .expense, amount: 1, date: "2026-11-19", createdBy: M.sync.meta.userId!,
                                             createdAt: DateKey.timestamp(), updatedAt: DateKey.timestamp()), receiptPath: nil)
        do { _ = try await M.client.upsert("transactions", rows: [evil]); XCTFail("write into his personal space allowed") } catch {}

        // Many entries: 2,500 sync both ways (more than one page of 1000).
        let groc = T.cat(T.house, "Groceries").id
        for i in 0..<2500 {
            T.store.addTransaction(spaceId: T.house.id, categoryId: groc, kind: .expense, amount: 1 + i,
                                   date: String(format: "2026-%02d-0%d", 1 + i % 11, 1 + i % 9))
        }
        let t0 = Date()
        try await T.sync.syncNow()
        let up = Date().timeIntervalSince(t0)
        let t1 = Date()
        try await M.sync.syncNow()
        let down = Date().timeIntervalSince(t1)
        XCTAssertEqual(M.store.transactions(in: M.house.id).count, T.store.transactions(in: T.house.id).count)
        XCTAssertGreaterThan(M.store.transactions(in: M.house.id).count, 2500)
        print("    2,500 entries: upload \(Int(up * 1000)) ms, download \(Int(down * 1000)) ms")

        // Signing in on a new phone brings everything back, with no duplicate categories.
        let N = phone()
        let awaited5 = try await N.sync.signIn(email: email("milica"), password: "secret456")
        XCTAssertEqual(awaited5, .connected)
        XCTAssertTrue(N.sync.isConnected)
        XCTAssertEqual(N.store.currentUser.name, "Milica")
        XCTAssertEqual(N.store.transactions(in: N.personal.id).map(\.amount), [2500])
        XCTAssertEqual(N.store.transactions(in: N.house.id).count, M.store.transactions(in: M.house.id).count)
        let names = N.store.categories(in: N.house.id, includeArchived: true).map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "no duplicate categories")

        // Clear messages for wrong password, existing account, short password.
        let X = phone()
        do { _ = try await X.sync.signIn(email: email("tosve"), password: "nope-wrong"); XCTFail() } catch {
            XCTAssertEqual(error.localizedDescription, "Wrong email or password.")
        }
        do { _ = try await X.sync.signUp(email: email("tosve"), password: "secret123"); XCTFail() } catch {
            XCTAssertEqual(error.localizedDescription, "This email already has an account. Sign in instead.")
        }
        do { _ = try await X.sync.signUp(email: "short-ios-\(run)@example.test", password: "123"); XCTFail() } catch {
            XCTAssertEqual(error.localizedDescription, "Password is too short (at least 6 characters).")
        }

        // Currency and names sync.
        try await T.sync.setCurrency("EUR")
        try await M.sync.rename(to: "Milica S.")
        try await T.sync.syncNow()
        XCTAssertEqual(T.store.user(M.sync.meta.userId!)?.name, "Milica S.")
        try await M.sync.rename(to: "Milica")

        // Syncing again with no changes changes nothing.
        try await T.sync.syncNow(); try await M.sync.syncNow()
        let before = M.store.data
        try await M.sync.syncNow()
        XCTAssertEqual(M.store.data, before)
        XCTAssertEqual(M.sync.pendingCount, 0)

        // Signing out and back in on the same phone: nothing duplicated, authors kept.
        let count = M.store.data.transactions.count
        let authors = Dictionary(uniqueKeysWithValues: M.store.data.transactions.map { ($0.id, $0.createdBy) })
        await M.sync.signOut()
        XCTAssertFalse(M.sync.isConnected)
        let awaited6 = try await M.sync.signIn(email: email("milica"), password: "secret456")
        XCTAssertEqual(awaited6, .connected)
        XCTAssertEqual(M.store.data.transactions.count, count)
        XCTAssertEqual(Set(M.store.data.transactions.map(\.id)).count, count)
        for t in M.store.data.transactions { XCTAssertEqual(t.createdBy, authors[t.id]) }
        XCTAssertEqual(M.sync.pendingCount, 0)
    }

    /// The connection drops in the middle of a sync, after the upload went through but before the
    /// download finished. Nothing may be lost or doubled.
    func testConnectionDropsHalfwayThroughASync() async throws {
        let flaky = FlakyTransport()
        let T = phone(transport: flaky), M = phone()
        _ = try await T.sync.signUp(email: email("half-t"), password: "secret123")
        let code = try await T.sync.createHousehold(displayName: "Tosve")
        _ = try await M.sync.signUp(email: email("half-m"), password: "secret456")
        try await M.sync.joinHousehold(code: code, displayName: "Milica")

        for cut in [2, 4, 6, 9] {
            let ids = (0..<5).map { i in
                T.store.addTransaction(spaceId: T.house.id, categoryId: T.cat(T.house, "Groceries").id, kind: .expense,
                                       amount: 100 + i, date: "2026-11-18").id
            }
            flaky.failAfter = cut
            do { try await T.sync.syncNow() } catch {}
            flaky.failAfter = nil
            try await T.sync.syncNow()
            try await M.sync.syncNow()
            for p in [T, M] {
                XCTAssertEqual(p.store.data.transactions.filter { ids.contains($0.id) }.count, 5, "cut after \(cut) requests: each entry exactly once")
            }
            XCTAssertEqual(T.sync.pendingCount, 0)
        }
        // A refreshed sign-in (the access token ran out) keeps syncing without asking again.
        T.client.now = { Date().addingTimeInterval(3600 * 2) }
        try await T.sync.syncNow()
        XCTAssertTrue(T.sync.isConnected)
    }

    // MARK: iPhone + web app

    /// Tosve uses the iPhone app, Milica uses the web app (its own store.js + sync.js code).
    func testIPhoneAndWebAppShareTheSameData() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let webDir = env["WEB_APP_DIR"], let modules = env["NODE_MODULES_DIR"] else {
            throw XCTSkip("Set WEB_APP_DIR and NODE_MODULES_DIR to test against the web app's sync code.")
        }
        let web = WebPhone(webDir: webDir, modules: modules, url: baseURL, key: anonKey,
                           script: env["WEBPHONE_SCRIPT"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                               .appendingPathComponent("../../scripts/webphone.mjs").standardized.path)
        let T = phone()

        // iPhone starts the household; the web app joins with the code.
        T.store.addTransaction(spaceId: T.house.id, categoryId: T.cat(T.house, "Groceries").id, kind: .expense, amount: 4520, date: "2026-11-11",
                               items: [ReceiptItem(name: "Čokolada Milka 100g", price: 159)])
        _ = try await T.sync.signUp(email: email("mix-t"), password: "secret123")
        let code = try await T.sync.createHousehold(displayName: "Tosve")
        try web.run("signup", ["email": email("mix-m"), "password": "secret456"])
        try web.run("join", ["code": code, "name": "Milica"])
        var w = try web.run("dump")
        XCTAssertEqual(w.house.count, 1, "the iPhone's House entry is in the web app")
        XCTAssertEqual(w.house.first?["amount"] as? Int, 4520)
        XCTAssertEqual(((w.house.first?["items"] as? [[String: Any]])?.first?["name"]) as? String, "Čokolada Milka 100g")

        // The web app adds an entry and renames a category; the iPhone sees both.
        let webEntry = try web.run("add", ["space": "house", "category": "Travel", "amount": 12000, "date": "2026-11-15", "note": "Bled",
                                           "items": [["name": "Parking", "price": 500]]]).id!
        try web.run("rename-category", ["space": "house", "from": "Shopping", "to": "Home stuff", "budget": 7000])
        try web.run("sync")
        try await T.sync.syncNow()
        XCTAssertEqual(T.entry(webEntry)?.note, "Bled")
        XCTAssertEqual(T.entry(webEntry)?.items, [ReceiptItem(name: "Parking", price: 500)])
        XCTAssertEqual(T.store.user(T.entry(webEntry)!.createdBy)?.name, "Milica")
        XCTAssertEqual(T.store.categories(in: T.house.id).first { $0.name == "Home stuff" }?.budget, 7000)
        XCTAssertNil(T.store.categories(in: T.house.id).first { $0.name == "Shopping" })

        // Conflict: the web edit is later, so it wins on both.
        T.store.updateTransaction(webEntry) { $0.amount = 13000 }
        await pause()
        try web.run("update", ["id": webEntry, "patch": ["amount": 14000]])
        try await T.sync.syncNow()
        try web.run("sync")
        try await T.sync.syncNow()
        w = try web.run("dump")
        XCTAssertEqual(T.entry(webEntry)?.amount, 14000)
        XCTAssertEqual(w.house.first { $0["id"] as? String == webEntry }?["amount"] as? Int, 14000)

        // The iPhone deletes it; it disappears in the web app.
        T.store.deleteTransaction(webEntry)
        try await T.sync.syncNow()
        w = try web.run("sync")
        XCTAssertNil(w.house.first { $0["id"] as? String == webEntry })

        // Photos both ways.
        let jpeg = Data((0..<20_000).map { UInt8(($0 * 7) % 251) })
        let rid = try T.photos.save(jpeg)
        let withPhoto = T.store.addTransaction(spaceId: T.house.id, categoryId: T.cat(T.house, "Groceries").id, kind: .expense,
                                               amount: 839, date: "2026-11-19", receiptId: rid)
        try await T.sync.syncNow()
        w = try web.run("sync")
        let path = (w.house.first { $0["id"] as? String == withPhoto.id }?["receiptId"] as? String).map { String($0.dropFirst(6)) }
        XCTAssertEqual(path, "\(T.house.id)/\(withPhoto.id).jpg")
        XCTAssertEqual(try web.run("download", ["path": path ?? ""]).base64.flatMap { Data(base64Encoded: $0) }, jpeg)
        let webJpeg = Data((0..<9_000).map { UInt8(($0 * 13) % 256) })
        let webPhotoEntry = try web.run("add-photo-entry", ["space": "house", "category": "Groceries", "amount": 455, "date": "2026-11-20",
                                                            "photoBase64": webJpeg.base64EncodedString()]).id!
        try web.run("sync")
        try await T.sync.syncNow()
        let fromWeb = try XCTUnwrap(T.entry(webPhotoEntry)?.receiptId)
        let gotPhoto = await T.sync.photo(for: fromWeb)
        XCTAssertEqual(gotPhoto, webJpeg)

        // Both now hold exactly the same House data.
        w = try web.run("sync")
        try await T.sync.syncNow()
        let iosHouse = T.store.transactions(in: T.house.id).map { "\($0.id) \($0.amount) \($0.date) \($0.categoryId) \($0.note) \($0.createdBy)" }.sorted()
        let webHouse = w.house.map { "\($0["id"]!) \($0["amount"]!) \($0["date"]!) \($0["categoryId"]!) \($0["note"]!) \($0["createdBy"]!)" }.sorted()
        XCTAssertEqual(iosHouse, webHouse)
        let iosCats = T.store.categories(in: T.house.id, includeArchived: true).map { "\($0.id) \($0.name) \($0.budget) \($0.order) \($0.archived)" }
        let webCats = w.houseCategories.map { "\($0["id"]!) \($0["name"]!) \($0["budget"]!) \($0["order"]!) \($0["archived"] as? Bool ?? false)" }
        XCTAssertEqual(iosCats, webCats)
        XCTAssertEqual(w.pending, 0)
        XCTAssertEqual(T.sync.pendingCount, 0)
    }
}

/// Fails every request after the first `failAfter` ones, like a dropped connection.
final class FlakyTransport: HTTPTransport, @unchecked Sendable {
    var failAfter: Int? { didSet { count = 0 } }
    var count = 0
    let real = URLSessionTransport()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        if let f = failAfter, count > f { throw SupabaseError.network("dropped") }
        return try await real.send(request)
    }
}

/// Runs scripts/webphone.mjs: a phone using the web app.
struct WebPhone {
    let webDir: String, modules: String, url: URL, key: String, script: String
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("webphone-\(UUID().uuidString).json").path

    struct Result {
        let raw: [String: Any]
        var id: String? { raw["id"] as? String }
        var base64: String? { raw["base64"] as? String }
        var pending: Int { raw["pending"] as? Int ?? -1 }
        var data: [String: Any] { raw["data"] as? [String: Any] ?? [:] }
        var houseId: String? { (data["spaces"] as? [[String: Any]])?.first { $0["type"] as? String == "house" }?["id"] as? String }
        var house: [[String: Any]] { (data["transactions"] as? [[String: Any]] ?? []).filter { $0["spaceId"] as? String == houseId } }
        var houseCategories: [[String: Any]] {
            (data["categories"] as? [[String: Any]] ?? []).filter { $0["spaceId"] as? String == houseId }
                .sorted { ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0) }
        }
    }

    @discardableResult
    func run(_ command: String, _ args: [String: Any] = [:]) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NODE_BIN"] ?? "/usr/bin/node")
        p.arguments = [script, webDir, state, command, String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!]
        var env = ProcessInfo.processInfo.environment
        env["SUPABASE_URL"] = url.absoluteString
        env["SUPABASE_ANON_KEY"] = key
        env["NODE_MODULES_DIR"] = modules
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last,
              let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw WebPhoneError(message: "no output from web phone for \(command): \(errText.replacingOccurrences(of: "\n", with: " | ").prefix(1500))")
        }
        guard obj["ok"] as? Bool == true else {
            throw WebPhoneError(message: "web phone \(command): \(obj["error"] ?? "?")")
        }
        return Result(raw: obj)
    }
}

struct WebPhoneError: Error, CustomStringConvertible { let message: String; var description: String { message } }
