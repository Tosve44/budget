import Foundation

public enum SyncTable: String, Codable, CaseIterable, Sendable { case categories, transactions }

/// What sync remembers between launches (kept next to the data file).
public struct SyncMeta: Codable, Equatable, Sendable {
    public var userId: String?
    public var householdId: String?
    /// Per table: the newest server time seen in the last download.
    public var lastPull: [String: String] = [:]
    /// Ids changed on this phone that still need uploading.
    public var dirtyCategories: Set<String> = []
    public var dirtyTransactions: Set<String> = []
    /// Entries deleted on this phone, kept until the deletion is uploaded.
    public var tombstones: [String: Transaction] = [:]
    /// Receipt photo id on this phone -> path in the cloud, once uploaded.
    public var uploaded: [String: String] = [:]
    public var lastSyncAt: String?
    public var lastError: String?

    public init() {}

    func isDirty(_ t: SyncTable, _ id: String) -> Bool {
        t == .categories ? dirtyCategories.contains(id) : dirtyTransactions.contains(id)
    }
    mutating func setDirty(_ t: SyncTable, _ id: String, _ on: Bool) {
        if t == .categories {
            if on { dirtyCategories.insert(id) } else { dirtyCategories.remove(id) }
        } else {
            if on { dirtyTransactions.insert(id) } else { dirtyTransactions.remove(id) }
        }
    }
}

/// Postgres times look like "2026-11-25T11:30:00.123456+00:00" or "2026-11-25 11:30:00+00".
/// Returns milliseconds since 1970 (0 if unreadable), like the web app's parseTs.
public enum Timestamps {
    public static func millis(_ value: Any?) -> Double {
        guard let raw = value as? String, !raw.isEmpty else { return 0 }
        var s = raw.replacingOccurrences(of: " ", with: "T")
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let frac = String(s[r].dropFirst().prefix(3))
            s.replaceSubrange(r, with: "." + frac.padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        if let r = s.range(of: #"[+-]\d\d$"#, options: .regularExpression) { s.replaceSubrange(r, with: s[r] + ":00") }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return (d.timeIntervalSince1970 * 1000).rounded() }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return (d.timeIntervalSince1970 * 1000).rounded() }
        return 0
    }

    /// "2026-11-25T11:30:00.123Z"
    public static func iso(_ value: Any?) -> String {
        DateKey.timestamp(Date(timeIntervalSince1970: millis(value) / 1000))
    }

    public static func newer(_ a: Any?, than b: Any?) -> Bool { millis(a) > millis(b) }
}

/// Converts between the phone's records and the cloud tables (see the web app's SYNC.md).
public enum CloudRows {
    public static func row(_ c: Category, deleted: Bool = false) -> Row {
        ["id": c.id, "space_id": c.spaceId, "name": c.name, "kind": c.kind.rawValue, "budget": c.budget,
         "sort_order": c.order, "archived": c.archived, "deleted": deleted,
         "updated_at": c.updatedAt ?? "2000-01-01T00:00:00.000Z"]
    }

    public static func category(_ r: Row) -> Category? {
        guard let id = r["id"] as? String, let sp = r["space_id"] as? String, let name = r["name"] as? String,
              let kind = EntryKind(rawValue: r["kind"] as? String ?? "") else { return nil }
        return Category(id: id, spaceId: sp, name: name, kind: kind, budget: int(r["budget"]), order: int(r["sort_order"]),
                        archived: r["archived"] as? Bool ?? false, updatedAt: Timestamps.iso(r["updated_at"]))
    }

    public static func row(_ t: Transaction, receiptPath: String?, deleted: Bool = false) -> Row {
        ["id": t.id, "space_id": t.spaceId, "category_id": t.categoryId, "kind": t.kind.rawValue, "amount": t.amount,
         "date": t.date, "note": t.note, "items": (t.items ?? []).map { ["name": $0.name, "price": $0.price] },
         "receipt_path": receiptPath as Any? ?? NSNull(), "created_by": t.createdBy, "created_at": t.createdAt,
         "updated_at": t.updatedAt, "deleted": deleted]
    }

    public static func transaction(_ r: Row) -> Transaction? {
        guard let id = r["id"] as? String, let sp = r["space_id"] as? String, let cat = r["category_id"] as? String,
              let kind = EntryKind(rawValue: r["kind"] as? String ?? ""), let date = r["date"] as? String else { return nil }
        let items = (r["items"] as? [[String: Any]] ?? []).compactMap { i -> ReceiptItem? in
            guard let n = i["name"] as? String else { return nil }
            return ReceiptItem(name: n, price: int(i["price"]))
        }
        let path = r["receipt_path"] as? String
        return Transaction(id: id, spaceId: sp, categoryId: cat, kind: kind, amount: int(r["amount"]), date: String(date.prefix(10)),
                           note: r["note"] as? String ?? "", createdBy: r["created_by"] as? String ?? "",
                           createdAt: Timestamps.iso(r["created_at"]), updatedAt: Timestamps.iso(r["updated_at"]),
                           receiptId: path.map { "cloud:\($0)" }, items: items.isEmpty ? nil : items)
    }

    static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }
}

/// Keeps this phone's data in step with the cloud so both phones share the House space.
/// Works like the web app's sync.js, so a web app and an iPhone can be used side by side:
/// the phone always works from its own copy (works offline), uploads its changes and downloads
/// the partner's, and when the same thing was changed on both phones, the newest change wins.
@MainActor
public final class SyncEngine {
    public enum State: Equatable, Sendable { case off, idle, syncing, error(String) }

    public let store: BudgetStore
    public let client: SupabaseClient
    public let photos: PhotoStore?
    let saveMeta: (SyncMeta) -> Void
    public private(set) var meta: SyncMeta
    public private(set) var state: State
    public var onStateChange: ((State) -> Void)?
    private var running: Task<Void, Error>?
    private var again = false
    private var debounce: Task<Void, Never>?

    static let page = 1000
    static let pullOverlapMs = 15_000.0
    static let bucket = "receipts"

    public init(store: BudgetStore, client: SupabaseClient, photos: PhotoStore?, meta: SyncMeta?, saveMeta: @escaping (SyncMeta) -> Void) {
        self.store = store
        self.client = client
        self.photos = photos
        self.saveMeta = saveMeta
        self.meta = meta ?? SyncMeta()
        self.state = .off
        state = isConnected ? .idle : .off
        store.onLocalChange = { [weak self] table, id, dead in
            MainActor.assumeIsolated { self?.markDirty(table, id, deleted: dead) }
        }
    }

    public var isConnected: Bool { meta.userId != nil && meta.householdId != nil && client.session != nil }
    public var pendingCount: Int { meta.dirtyCategories.count + meta.dirtyTransactions.count + meta.tombstones.count }

    func setState(_ s: State) { state = s; onStateChange?(s) }
    func persist() { saveMeta(meta) }

    func markDirty(_ table: SyncTable, _ id: String, deleted: Transaction?) {
        guard isConnected else { return }
        if let deleted {
            meta.setDirty(table, id, false)
            meta.tombstones[id] = deleted
        } else {
            meta.setDirty(table, id, true)
        }
        persist()
        schedule()
    }

    /// Sync a moment after the last change (typing several entries in a row sends them together).
    public func schedule(after seconds: Double = 1.2) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            try? await self?.syncNow()
        }
    }

    // MARK: account

    public func signUp(email: String, password: String) async throws -> Bool {
        try await client.signUp(email: email, password: password)
    }

    public enum ResumeResult: Equatable, Sendable { case signedOut, needsHousehold, connected }

    public func signIn(email: String, password: String) async throws -> ResumeResult {
        try await client.signIn(email: email, password: password)
        return try await resume()
    }

    public func signOut() async {
        await client.signOut()
        meta = SyncMeta()
        persist()
        setState(.off)
    }

    /// After sign-in: if this account already belongs to a household, connect to it.
    public func resume() async throws -> ResumeResult {
        guard let uid = client.userId else { return .signedOut }
        let rows = try await client.select("members", filters: [("user_id", "eq.\(uid)")])
        guard let hid = rows.first?["household_id"] as? String else { return .needsHousehold }
        if meta.householdId != hid || meta.userId != uid { try await adopt(userId: uid, householdId: hid) }
        try await syncNow()
        return .connected
    }

    /// Starts a new household (the first person). Returns the invite code for the partner.
    @discardableResult
    public func createHousehold(displayName: String) async throws -> String {
        guard let uid = client.userId else { throw SupabaseError.notSignedIn }
        let h = try await client.rpc("create_household", ["display_name": displayName, "house_space_id": IDs.make("sp_house"),
                                                          "personal_space_id": IDs.make("sp_personal")])
        guard let row = h as? Row, let hid = row["id"] as? String else { throw SupabaseError.badResponse }
        try await adopt(userId: uid, householdId: hid)
        try await syncNow()
        return row["invite_code"] as? String ?? ""
    }

    /// Joins the partner's household with their invite code.
    public func joinHousehold(code: String, displayName: String) async throws {
        guard let uid = client.userId else { throw SupabaseError.notSignedIn }
        let h = try await client.rpc("join_household", ["code": code, "display_name": displayName, "personal_space_id": IDs.make("sp_personal")])
        guard let row = h as? Row, let hid = row["id"] as? String else { throw SupabaseError.badResponse }
        try await adopt(userId: uid, householdId: hid)
        try await syncNow()
    }

    func fetchAll(_ table: String, since: String? = nil) async throws -> [Row] {
        var out: [Row] = []
        var offset = 0
        while true {
            var filters: [(String, String)] = []
            if let since { filters.append(("server_updated_at", "gt.\(since)")) }
            let page = try await client.select(table, filters: filters,
                                               order: "server_updated_at.asc,\(table == "members" ? "user_id" : "id").asc",
                                               limit: Self.page, offset: offset)
            out += page
            if page.count < Self.page { return out }
            offset += Self.page
        }
    }

    /// Moves what is on this phone into the cloud household: this phone's Personal space becomes
    /// the person's cloud Personal space and its House space is merged into the cloud House.
    /// Categories with the same name and kind are merged into one.
    func adopt(userId uid: String, householdId hid: String) async throws {
        let households = try await fetchAll("households")
        let members = try await fetchAll("members")
        let spaces = try await fetchAll("spaces")
        guard let cloudPersonal = spaces.first(where: { $0["type"] as? String == "personal" && $0["owner_id"] as? String == uid }),
              let cloudHouse = spaces.first(where: { $0["type"] as? String == "house" }),
              let cpId = cloudPersonal["id"] as? String, let chId = cloudHouse["id"] as? String else {
            throw SupabaseError.server(status: 0, code: nil, message: "Household spaces are missing.")
        }
        let cloudCats = try await fetchAll("categories")
        let cloudTx = try await fetchAll("transactions")

        let d = store.data
        var spaceMap: [String: String] = [:]
        if let p = store.personalSpace() { spaceMap[p.id] = cpId }
        if let h = store.houseSpace { spaceMap[h.id] = chId }
        var catMap: [String: String] = [:]
        var keep: [Category] = []
        let cloudCatById = Dictionary(cloudCats.compactMap { r in (r["id"] as? String).map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let cloudTxById = Dictionary(cloudTx.compactMap { r in (r["id"] as? String).map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let nowTs = DateKey.timestamp()
        for c in d.categories {
            guard let target = spaceMap[c.spaceId] else { continue } // another person's local space: not uploaded
            if let known = cloudCatById[c.id] {
                catMap[c.id] = c.id
                if let u = c.updatedAt, Timestamps.newer(u, than: known["updated_at"]) { var x = c; x.spaceId = target; keep.append(x) }
                continue
            }
            let key = c.name.trimmingCharacters(in: .whitespaces).lowercased()
            if let same = cloudCats.first(where: {
                $0["space_id"] as? String == target && ($0["deleted"] as? Bool) != true && $0["kind"] as? String == c.kind.rawValue
                    && ($0["name"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased() == key
            }), let sid = same["id"] as? String {
                catMap[c.id] = sid
            } else {
                catMap[c.id] = c.id
                var x = c; x.spaceId = target; x.updatedAt = c.updatedAt ?? nowTs
                keep.append(x)
            }
        }
        var txs: [Transaction] = []
        for t in d.transactions {
            guard let target = spaceMap[t.spaceId], let cat = catMap[t.categoryId] else { continue }
            if let known = cloudTxById[t.id], !Timestamps.newer(t.updatedAt, than: known["updated_at"]) { continue }
            var x = t
            x.spaceId = target
            x.categoryId = cat
            // Entries made before signing in carry a placeholder author ("u_tosve"): they are yours.
            if t.createdBy.isEmpty || t.createdBy.hasPrefix("u_") { x.createdBy = uid }
            txs.append(x)
        }

        var m = SyncMeta()
        m.userId = uid
        m.householdId = hid
        m.dirtyCategories = Set(keep.map(\.id))
        m.dirtyTransactions = Set(txs.map(\.id))
        meta = m

        let memberIds = members.compactMap { $0["user_id"] as? String }
        var next = BudgetData.initial()
        next.settings = d.settings
        next.settings.currentUserId = uid
        next.users = members.compactMap { r in
            guard let id = r["user_id"] as? String else { return nil }
            return User(id: id, name: r["display_name"] as? String ?? "")
        }
        next.spaces = spaces.compactMap { r in
            guard let id = r["id"] as? String, let type = SpaceType(rawValue: r["type"] as? String ?? "") else { return nil }
            let owner = r["owner_id"] as? String
            return Space(id: id, type: type, name: r["name"] as? String ?? "", ownerId: owner,
                         memberIds: type == .house ? memberIds : [owner].compactMap { $0 })
        }
        if let hh = households.first(where: { $0["id"] as? String == hid }) {
            if let cur = hh["currency"] as? String { next.settings.currency = cur }
            next.settings.inviteCode = hh["invite_code"] as? String
        }
        let keepIds = Set(keep.map(\.id)), txIds = Set(txs.map(\.id))
        next.categories = cloudCats.filter { ($0["deleted"] as? Bool) != true && !keepIds.contains($0["id"] as? String ?? "") }
            .compactMap(CloudRows.category) + keep
        next.transactions = cloudTx.filter { ($0["deleted"] as? Bool) != true && !txIds.contains($0["id"] as? String ?? "") }
            .compactMap(CloudRows.transaction) + txs
        // Keep photos that are already on this phone.
        let oldById = Dictionary(d.transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in next.transactions.indices {
            let t = next.transactions[i]
            if let old = oldById[t.id]?.receiptId, t.receiptId?.hasPrefix("cloud:") == true, !old.hasPrefix("cloud:") {
                next.transactions[i].receiptId = old
            }
        }
        store.replaceAll(next)
        persist()
    }

    // MARK: syncing

    /// Uploads this phone's changes, then downloads the partner's. Safe to call any time;
    /// calls that come in while a sync is running make it run once more.
    public func syncNow() async throws {
        guard isConnected else { return }
        if let running {
            again = true
            return try await running.value
        }
        let task = Task { @MainActor in
            setState(.syncing)
            defer { self.running = nil }
            do {
                repeat {
                    again = false
                    try await push()
                    try await pull()
                } while again
                meta.lastSyncAt = DateKey.timestamp()
                meta.lastError = nil
                persist()
                setState(.idle)
            } catch {
                meta.lastError = error.localizedDescription
                persist()
                setState(.error(error.localizedDescription))
                throw error
            }
        }
        running = task
        try await task.value
    }

    func push() async throws {
        let d = store.data
        let txById = Dictionary(d.transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let catById = Dictionary(d.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 1. Receipt photos first, so the entry can point at them.
        var photoPaths: [String: String] = [:]
        for id in meta.dirtyTransactions {
            guard let t = txById[id], let rid = t.receiptId else { continue }
            if rid.hasPrefix("cloud:") { photoPaths[id] = String(rid.dropFirst(6)); continue }
            let path = "\(t.spaceId)/\(t.id).jpg"
            if meta.uploaded[rid] != path, let jpeg = photos?.load(rid) {
                try await client.upload(bucket: Self.bucket, path: path, jpeg: jpeg)
                meta.uploaded[rid] = path
                persist()
            }
            if meta.uploaded[rid] == path { photoPaths[id] = path }
        }

        // 2. Categories before entries (entries point at categories).
        for table in SyncTable.allCases {
            var rows: [Row] = []
            var sent: [String: String] = [:]
            let dirty = table == .categories ? meta.dirtyCategories : meta.dirtyTransactions
            for id in dirty.sorted() {
                if table == .categories {
                    guard let c = catById[id] else { meta.setDirty(table, id, false); continue }
                    rows.append(CloudRows.row(c)); sent[id] = c.updatedAt ?? ""
                } else {
                    guard let t = txById[id] else { meta.setDirty(table, id, false); continue }
                    rows.append(CloudRows.row(t, receiptPath: photoPaths[id])); sent[id] = t.updatedAt
                }
            }
            if table == .transactions {
                for (id, dead) in meta.tombstones.sorted(by: { $0.key < $1.key }) {
                    let path = dead.receiptId.flatMap { $0.hasPrefix("cloud:") ? String($0.dropFirst(6)) : nil }
                    rows.append(CloudRows.row(dead, receiptPath: path, deleted: true)); sent[id] = dead.updatedAt
                }
            }
            if rows.isEmpty { continue }
            for start in stride(from: 0, to: rows.count, by: 200) {
                let chunk = Array(rows[start..<min(start + 200, rows.count)])
                let accepted = Set(try await client.upsert(table.rawValue, rows: chunk))
                // The server ignores an edit older than its own copy (the partner changed it later).
                // Fetch the winning version of those rows so this phone shows it.
                let lost = chunk.compactMap { $0["id"] as? String }.filter { !accepted.contains($0) }
                if !lost.isEmpty {
                    let winners = try await client.select(table.rawValue, filters: [("id", SupabaseClient.inList(lost))])
                    _ = apply(table, winners, force: true)
                }
            }
            // Forget what was sent, unless it changed again meanwhile.
            let now = store.data
            let nowCats = Dictionary(now.categories.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
            let nowTx = Dictionary(now.transactions.map { ($0.id, $0.updatedAt as String?) }, uniquingKeysWith: { a, _ in a })
            for (id, at) in sent {
                if table == .transactions, let dead = meta.tombstones[id], dead.updatedAt == at {
                    meta.tombstones[id] = nil
                    if dead.receiptId != nil { await removePhoto(dead) }
                }
                let local = table == .categories ? nowCats[id] : nowTx[id]
                let exists = local != nil
                if meta.isDirty(table, id) && (!exists || local! == at) { meta.setDirty(table, id, false) }
            }
            persist()
        }
    }

    func removePhoto(_ dead: Transaction) async {
        guard let rid = dead.receiptId else { return }
        let path = rid.hasPrefix("cloud:") ? String(rid.dropFirst(6)) : meta.uploaded[rid]
        if let path { try? await client.remove(bucket: Self.bucket, paths: [path]) }
        photos?.delete(rid)
        meta.uploaded[rid] = nil
    }

    func pull() async throws {
        func since(_ table: String) -> String? {
            guard let t = meta.lastPull[table] else { return nil }
            return DateKey.timestamp(Date(timeIntervalSince1970: (Timestamps.millis(t) - Self.pullOverlapMs) / 1000))
        }
        var results: [String: [Row]] = [:]
        for table in ["households", "members", "spaces", "categories", "transactions"] {
            let rows = try await fetchAll(table, since: since(table))
            results[table] = rows
            if let first = rows.first {
                let latest = rows.reduce(first["server_updated_at"]) { Timestamps.newer($1["server_updated_at"], than: $0) ? $1["server_updated_at"] : $0 }
                meta.lastPull[table] = Timestamps.iso(latest)
            }
        }
        var d = store.data
        var changed = false
        for h in results["households"] ?? [] where h["id"] as? String == meta.householdId {
            let cur = h["currency"] as? String ?? d.settings.currency
            let code = h["invite_code"] as? String
            if d.settings.currency != cur || d.settings.inviteCode != code {
                d.settings.currency = cur; d.settings.inviteCode = code; changed = true
            }
        }
        for m in results["members"] ?? [] {
            guard let uid = m["user_id"] as? String else { continue }
            let name = m["display_name"] as? String ?? ""
            if let i = d.users.firstIndex(where: { $0.id == uid }) {
                if d.users[i].name != name { d.users[i].name = name; changed = true }
            } else {
                d.users.append(User(id: uid, name: name)); changed = true
            }
            if let hi = d.spaces.firstIndex(where: { $0.type == .house }), !d.spaces[hi].memberIds.contains(uid) {
                d.spaces[hi].memberIds.append(uid); changed = true
            }
        }
        for s in results["spaces"] ?? [] {
            guard let id = s["id"] as? String, !d.spaces.contains(where: { $0.id == id }),
                  let type = SpaceType(rawValue: s["type"] as? String ?? "") else { continue }
            d.spaces.append(Space(id: id, type: type, name: s["name"] as? String ?? "", ownerId: s["owner_id"] as? String, memberIds: []))
            changed = true
        }
        if merge(.categories, results["categories"] ?? [], into: &d, force: false) { changed = true }
        if merge(.transactions, results["transactions"] ?? [], into: &d, force: false) { changed = true }
        persist()
        if changed { store.replaceAll(d) }
    }

    @discardableResult
    func apply(_ table: SyncTable, _ rows: [Row], force: Bool) -> Bool {
        var d = store.data
        let changed = merge(table, rows, into: &d, force: force)
        if changed { store.replaceAll(d) }
        return changed
    }

    /// Merges rows from the cloud into the phone's copy. A row this phone changed more recently
    /// (and has not uploaded yet) is kept; otherwise the cloud version wins.
    func merge(_ table: SyncTable, _ rows: [Row], into d: inout BudgetData, force: Bool) -> Bool {
        var changed = false
        // Look-ups by id (thousands of rows), removals applied at the end.
        var catIndex = Dictionary(d.categories.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var txIndex = Dictionary(d.transactions.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var removed = Set<String>()
        for r in rows {
            guard let id = r["id"] as? String else { continue }
            let deleted = r["deleted"] as? Bool ?? false
            if table == .categories {
                let i = removed.contains(id) ? nil : catIndex[id]
                if !force, let i, meta.isDirty(table, id), !Timestamps.newer(r["updated_at"], than: d.categories[i].updatedAt) { continue }
                meta.setDirty(table, id, false)
                if deleted { if i != nil { removed.insert(id); changed = true }; continue }
                guard let next = CloudRows.category(r) else { continue }
                if let i {
                    if d.categories[i] != next { d.categories[i] = next; changed = true }
                } else {
                    removed.remove(id)
                    catIndex[id] = d.categories.count
                    d.categories.append(next); changed = true
                }
            } else {
                let i = removed.contains(id) ? nil : txIndex[id]
                let dead = meta.tombstones[id]
                if !force {
                    if let i, meta.isDirty(table, id), !Timestamps.newer(r["updated_at"], than: d.transactions[i].updatedAt) { continue }
                    if let dead, !Timestamps.newer(r["updated_at"], than: dead.updatedAt) { continue }
                }
                if dead != nil { meta.tombstones[id] = nil }
                meta.setDirty(table, id, false)
                if deleted { if i != nil { removed.insert(id); changed = true }; continue }
                guard var next = CloudRows.transaction(r) else { continue }
                if let i {
                    let local = d.transactions[i]
                    if let lr = local.receiptId {
                        // Keep using the photo already on this phone.
                        if next.receiptId == nil || meta.uploaded[lr] == (r["receipt_path"] as? String) { next.receiptId = lr }
                    }
                    if local != next { d.transactions[i] = next; changed = true }
                } else {
                    removed.remove(id)
                    txIndex[id] = d.transactions.count
                    d.transactions.append(next); changed = true
                }
            }
        }
        if !removed.isEmpty {
            if table == .categories { d.categories.removeAll { removed.contains($0.id) } }
            else { d.transactions.removeAll { removed.contains($0.id) } }
        }
        return changed
    }

    // MARK: household settings

    public func setCurrency(_ code: String) async throws {
        guard let hid = meta.householdId else { return }
        try await client.update("households", values: ["currency": code], whereColumn: "id", equals: hid)
        store.setCurrency(code)
    }

    public func rename(to displayName: String) async throws {
        guard let uid = meta.userId else { return }
        try await client.update("members", values: ["display_name": displayName], whereColumn: "user_id", equals: uid)
        try await syncNow()
    }

    /// A receipt photo the partner took: downloaded once and kept on this phone.
    public func photo(for receiptId: String) async -> Data? {
        if let local = photos?.load(receiptId) { return local }
        guard receiptId.hasPrefix("cloud:") else { return nil }
        guard let data = try? await client.download(bucket: Self.bucket, path: String(receiptId.dropFirst(6))) else { return nil }
        _ = try? photos?.save(data, id: receiptId)
        return data
    }
}
