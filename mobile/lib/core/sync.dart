import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';
import 'money.dart';
import 'store.dart';
import 'supabase.dart';

/// What sync remembers between launches (kept next to the data file). Same fields as the
/// iPhone app's SyncMeta.
class SyncMeta {
  String? userId;
  String? householdId;

  /// Per table: the newest server time seen in the last download.
  Map<String, String> lastPull = {};

  /// Ids changed on this phone that still need uploading.
  Set<String> dirtyCategories = {};
  Set<String> dirtyTransactions = {};

  /// Entries deleted on this phone, kept until the deletion is uploaded.
  Map<String, Transaction> tombstones = {};

  /// Duplicate categories removed on this phone, kept until the removal is uploaded.
  Map<String, Category> categoryTombstones = {};

  /// Receipt photo id on this phone -> path in the cloud, once uploaded.
  Map<String, String> uploaded = {};
  String? lastSyncAt;
  String? lastError;

  SyncMeta();

  factory SyncMeta.fromJson(Map<String, dynamic> j) {
    final m = SyncMeta()
      ..userId = j['userId'] as String?
      ..householdId = j['householdId'] as String?
      ..lastPull = Map<String, String>.from((j['lastPull'] as Map?) ?? {})
      ..dirtyCategories = ((j['dirtyCategories'] as List?) ?? []).cast<String>().toSet()
      ..dirtyTransactions = ((j['dirtyTransactions'] as List?) ?? []).cast<String>().toSet()
      ..uploaded = Map<String, String>.from((j['uploaded'] as Map?) ?? {})
      ..lastSyncAt = j['lastSyncAt'] as String?
      ..lastError = j['lastError'] as String?;
    ((j['tombstones'] as Map?) ?? {}).forEach((k, v) => m.tombstones['$k'] = Transaction.fromJson(Map<String, dynamic>.from(v as Map)));
    ((j['categoryTombstones'] as Map?) ?? {}).forEach(
      (k, v) => m.categoryTombstones['$k'] = Category.fromJson(Map<String, dynamic>.from(v as Map)),
    );
    return m;
  }

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'householdId': householdId,
    'lastPull': lastPull,
    'dirtyCategories': dirtyCategories.toList(),
    'dirtyTransactions': dirtyTransactions.toList(),
    'tombstones': tombstones.map((k, v) => MapEntry(k, v.toJson())),
    'categoryTombstones': categoryTombstones.map((k, v) => MapEntry(k, v.toJson())),
    'uploaded': uploaded,
    'lastSyncAt': lastSyncAt,
    'lastError': lastError,
  };

  bool isDirty(SyncTable t, String id) => t == SyncTable.categories ? dirtyCategories.contains(id) : dirtyTransactions.contains(id);
  void setDirty(SyncTable t, String id, bool on) {
    final set = t == SyncTable.categories ? dirtyCategories : dirtyTransactions;
    on ? set.add(id) : set.remove(id);
  }
}

/// Converts between the phone's records and the cloud tables (see the web app's SYNC.md).
class CloudRows {
  CloudRows._();

  static Row categoryRow(Category c, {bool deleted = false}) => {
    'id': c.id,
    'space_id': c.spaceId,
    'name': Limits.clip(c.name, Limits.categoryName),
    'kind': c.kind.name,
    'budget': Limits.clamp(c.budget),
    'sort_order': c.order,
    'archived': c.archived,
    'deleted': deleted,
    'updated_at': c.updatedAt ?? '2000-01-01T00:00:00.000Z',
  };

  static Category? category(Row r) {
    final id = r['id'], sp = r['space_id'], name = r['name'], kind = EntryKind.parse(r['kind']);
    if (id is! String || sp is! String || name is! String || kind == null) return null;
    return Category(
      id: id,
      spaceId: sp,
      name: name,
      kind: kind,
      budget: asInt(r['budget']),
      order: asInt(r['sort_order']),
      archived: r['archived'] == true,
      updatedAt: Timestamps.iso(r['updated_at']),
    );
  }

  static Row transactionRow(Transaction t, String? receiptPath, {bool deleted = false}) => {
    'id': t.id,
    'space_id': t.spaceId,
    'category_id': t.categoryId,
    'kind': t.kind.name,
    'amount': t.amount.clamp(1, Limits.maxCents),
    'date': t.date,
    'note': Limits.clip(t.note, Limits.note),
    'items': (t.items ?? [])
        .take(Limits.items)
        .map((i) => {'name': Limits.clip(i.name, Limits.itemName), 'price': Limits.clamp(i.price)})
        .toList(),
    'receipt_path': receiptPath,
    'created_by': t.createdBy,
    'created_at': t.createdAt,
    'updated_at': t.updatedAt,
    'deleted': deleted,
  };

  static Transaction? transaction(Row r) {
    final id = r['id'], sp = r['space_id'], cat = r['category_id'], kind = EntryKind.parse(r['kind']), date = r['date'];
    if (id is! String || sp is! String || cat is! String || kind == null || date is! String) return null;
    final items = <ReceiptItem>[];
    for (final i in (r['items'] is List ? r['items'] as List : const [])) {
      if (i is Map && i['name'] is String) items.add(ReceiptItem(name: i['name'] as String, price: asInt(i['price'])));
    }
    final path = r['receipt_path'];
    return Transaction(
      id: id,
      spaceId: sp,
      categoryId: cat,
      kind: kind,
      amount: asInt(r['amount']),
      date: date.length > 10 ? date.substring(0, 10) : date,
      note: (r['note'] as String?) ?? '',
      createdBy: (r['created_by'] as String?) ?? '',
      createdAt: Timestamps.iso(r['created_at']),
      updatedAt: Timestamps.iso(r['updated_at']),
      receiptId: path is String ? 'cloud:$path' : null,
      items: items.isEmpty ? null : items,
    );
  }
}

/// Receipt photos, one JPEG file per receipt, kept next to the data file.
class PhotoStore {
  final Directory folder;
  PhotoStore(this.folder);

  /// Ids are "rc_…" for photos taken on this phone and `cloud:<space>/<entry>.jpg` for photos
  /// downloaded from the partner; anything but letters, digits, "-" and "_" becomes "_", so an
  /// id can never point outside the folder.
  File? file(String id) {
    if (id.isEmpty) return null;
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${folder.path}/$safe.jpg');
  }

  String save(Uint8List jpeg, {String? id}) {
    final pid = id ?? Ids.make('rc');
    final f = file(pid)!;
    folder.createSync(recursive: true);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsBytesSync(jpeg, flush: true);
    tmp.renameSync(f.path);
    return pid;
  }

  Uint8List? load(String id) {
    final f = file(id);
    try {
      return f != null && f.existsSync() ? f.readAsBytesSync() : null;
    } catch (_) {
      return null;
    }
  }

  void delete(String id) {
    try {
      file(id)?.deleteSync();
    } catch (_) {}
  }
}

enum SyncState { off, idle, syncing, error }

enum ResumeResult { signedOut, needsHousehold, connected }

/// Keeps this phone's data in step with the cloud so both phones share the House space. A port
/// of the iPhone app's SyncEngine (which follows the web app's sync.js): the phone always works
/// from its own copy (offline first), uploads its changes and downloads the partner's, and when
/// the same thing was changed on both phones, the newest change wins.
class SyncEngine {
  final BudgetStore store;
  final SupabaseClient client;
  final PhotoStore? photos;
  final void Function(SyncMeta meta) saveMeta;
  SyncMeta meta;
  SyncState state = SyncState.off;
  String? errorText;
  final List<void Function()> listeners = [];
  Future<void>? _running;
  bool _again = false;
  Timer? _debounce;

  static const page = 1000;
  static const pullOverlapMs = 15000;
  static const bucket = 'receipts';

  SyncEngine({required this.store, required this.client, this.photos, SyncMeta? meta, required this.saveMeta}) : meta = meta ?? SyncMeta() {
    state = isConnected ? SyncState.idle : SyncState.off;
    store.onLocalChange = (table, id, dead) => markDirty(table, id, dead);
  }

  bool get isConnected => meta.userId != null && meta.householdId != null && client.session != null;
  int get pendingCount =>
      meta.dirtyCategories.length + meta.dirtyTransactions.length + meta.tombstones.length + meta.categoryTombstones.length;

  void _setState(SyncState s, [String? error]) {
    state = s;
    errorText = error;
    for (final l in List.of(listeners)) {
      l();
    }
  }

  void _persist() => saveMeta(meta);

  void markDirty(SyncTable table, String id, Object? deleted) {
    if (!isConnected) return;
    if (deleted is Transaction) {
      meta.setDirty(table, id, false);
      meta.tombstones[id] = deleted.copy();
    } else {
      meta.setDirty(table, id, true);
    }
    _persist();
    schedule();
  }

  /// Sync a moment after the last change (typing several entries in a row sends them together).
  void schedule([Duration after = const Duration(milliseconds: 1200)]) {
    _debounce?.cancel();
    _debounce = Timer(after, () => syncNow().catchError((_) {}));
  }

  void dispose() => _debounce?.cancel();

  // ---- account ----

  Future<bool> signUp(String email, String password) => _friendly(() => client.signUp(email, password));

  Future<ResumeResult> signIn(String email, String password) async {
    await _friendly(() => client.signIn(email, password));
    return resume();
  }

  Future<void> signOut() async {
    await client.signOut();
    meta = SyncMeta();
    _persist();
    _setState(SyncState.off);
  }

  /// After sign-in: if this account already belongs to a household, connect to it.
  Future<ResumeResult> resume() async {
    final uid = client.userId;
    if (uid == null) return ResumeResult.signedOut;
    final rows = await _friendly(() => client.select('members', filters: [('user_id', 'eq.$uid')]));
    if (rows.isEmpty || rows.first['household_id'] is! String) return ResumeResult.needsHousehold;
    final hid = rows.first['household_id'] as String;
    if (meta.householdId != hid || meta.userId != uid) await adopt(uid, hid);
    await syncNow();
    return ResumeResult.connected;
  }

  /// Starts a new household (the first person). Returns the invite code for the partner.
  Future<String> createHousehold(String displayName) async {
    final uid = client.userId;
    if (uid == null) throw SupabaseError.notSignedIn;
    final h = await _friendly(
      () => client.rpc('create_household', {
        'display_name': Limits.displayName(displayName),
        'house_space_id': Ids.make('sp_house'),
        'personal_space_id': Ids.make('sp_personal'),
      }),
    );
    if (h is! Map || h['id'] is! String) throw SupabaseError.badResponse;
    await adopt(uid, h['id'] as String);
    await syncNow();
    return (h['invite_code'] as String?) ?? '';
  }

  /// Joins the partner's household with their invite code.
  Future<void> joinHousehold(String code, String displayName) async {
    final uid = client.userId;
    if (uid == null) throw SupabaseError.notSignedIn;
    final h = await _friendly(
      () => client.rpc('join_household', {
        'code': code.trim().toUpperCase(),
        'display_name': Limits.displayName(displayName),
        'personal_space_id': Ids.make('sp_personal'),
      }),
    );
    if (h is! Map || h['id'] is! String) throw SupabaseError.badResponse;
    await adopt(uid, h['id'] as String);
    await syncNow();
  }

  Future<T> _friendly<T>(Future<T> Function() f) => f();

  Future<List<Row>> fetchAll(String table, {String? since}) async {
    final out = <Row>[];
    var offset = 0;
    while (true) {
      final rows = await client.select(
        table,
        filters: [if (since != null) ('server_updated_at', 'gt.$since')],
        order: 'server_updated_at.asc,${table == 'members' ? 'user_id' : 'id'}.asc',
        limit: page,
        offset: offset,
      );
      out.addAll(rows);
      if (rows.length < page) return out;
      offset += page;
    }
  }

  /// Moves what is on this phone into the cloud household: this phone's Personal space becomes
  /// the person's cloud Personal space and its House space is merged into the cloud House.
  /// Categories with the same name and kind are merged into one.
  Future<void> adopt(String uid, String hid) async {
    final households = await fetchAll('households');
    final members = await fetchAll('members');
    final spaces = await fetchAll('spaces');
    Row? firstWhere(List<Row> l, bool Function(Row) t) {
      for (final r in l) {
        if (t(r)) return r;
      }
      return null;
    }

    final cloudPersonal = firstWhere(spaces, (s) => s['type'] == 'personal' && s['owner_id'] == uid);
    final cloudHouse = firstWhere(spaces, (s) => s['type'] == 'house');
    if (cloudPersonal == null || cloudHouse == null) {
      throw const SupabaseError('server', message: 'Household spaces are missing.');
    }
    final cpId = cloudPersonal['id'] as String, chId = cloudHouse['id'] as String;
    final cloudCats = await fetchAll('categories');
    final cloudTx = await fetchAll('transactions');

    final d = store.data;
    final spaceMap = <String, String>{};
    final p = store.personalSpace();
    if (p != null) spaceMap[p.id] = cpId;
    final h = store.houseSpace;
    if (h != null) spaceMap[h.id] = chId;
    final catMap = <String, String>{};
    final keep = <Category>[];
    final cloudCatById = {for (final r in cloudCats.reversed) r['id']: r};
    final cloudTxById = {for (final r in cloudTx.reversed) r['id']: r};
    final nowTs = DateKey.timestamp();
    for (final c in d.categories) {
      final target = spaceMap[c.spaceId];
      if (target == null) continue; // another person's local space: not uploaded
      final known = cloudCatById[c.id];
      if (known != null) {
        catMap[c.id] = c.id;
        if (c.updatedAt != null && Timestamps.newer(c.updatedAt, known['updated_at'])) keep.add(c.copy()..spaceId = target);
        continue;
      }
      final key = c.name.trim().toLowerCase();
      final same = firstWhere(
        cloudCats,
        (r) =>
            r['space_id'] == target && r['deleted'] != true && r['kind'] == c.kind.name && '${r['name'] ?? ''}'.trim().toLowerCase() == key,
      );
      if (same != null && same['id'] is String) {
        catMap[c.id] = same['id'] as String;
      } else {
        catMap[c.id] = c.id;
        keep.add(
          c.copy()
            ..spaceId = target
            ..updatedAt = c.updatedAt ?? nowTs,
        );
      }
    }
    final txs = <Transaction>[];
    for (final t in d.transactions) {
      final target = spaceMap[t.spaceId], cat = catMap[t.categoryId];
      if (target == null || cat == null) continue;
      final known = cloudTxById[t.id];
      if (known != null && !Timestamps.newer(t.updatedAt, known['updated_at'])) continue;
      final x = t.copy()
        ..spaceId = target
        ..categoryId = cat;
      // Entries made before signing in carry a placeholder author ("u_tosve"): they are yours.
      if (t.createdBy.isEmpty || t.createdBy.startsWith('u_')) x.createdBy = uid;
      txs.add(x);
    }

    final m = SyncMeta()
      ..userId = uid
      ..householdId = hid
      ..dirtyCategories = keep.map((c) => c.id).toSet()
      ..dirtyTransactions = txs.map((t) => t.id).toSet();
    meta = m;

    final memberIds = [
      for (final r in members)
        if (r['user_id'] is String) r['user_id'] as String,
    ];
    final next = BudgetData.initial();
    next.settings = d.settings.copy()..currentUserId = uid;
    next.users = [
      for (final r in members)
        if (r['user_id'] is String) User(id: r['user_id'] as String, name: (r['display_name'] as String?) ?? ''),
    ];
    next.spaces = [
      for (final r in spaces)
        if (r['id'] is String && SpaceType.parse(r['type']) != null)
          Space(
            id: r['id'] as String,
            type: SpaceType.parse(r['type'])!,
            name: (r['name'] as String?) ?? '',
            ownerId: r['owner_id'] as String?,
            memberIds: SpaceType.parse(r['type']) == SpaceType.house
                ? List.of(memberIds)
                : [if (r['owner_id'] is String) r['owner_id'] as String],
          ),
    ];
    final hh = firstWhere(households, (r) => r['id'] == hid);
    if (hh != null) {
      if (hh['currency'] is String) next.settings.currency = hh['currency'] as String;
      next.settings.inviteCode = hh['invite_code'] as String?;
    }
    final keepIds = keep.map((c) => c.id).toSet(), txIds = txs.map((t) => t.id).toSet();
    next.categories = [
      ...cloudCats.where((r) => r['deleted'] != true && !keepIds.contains(r['id'])).map(CloudRows.category).whereType<Category>(),
      ...keep,
    ];
    next.transactions = [
      ...cloudTx.where((r) => r['deleted'] != true && !txIds.contains(r['id'])).map(CloudRows.transaction).whereType<Transaction>(),
      ...txs,
    ];
    // Keep photos that are already on this phone.
    final oldById = {for (final t in d.transactions) t.id: t};
    for (final t in next.transactions) {
      final old = oldById[t.id]?.receiptId;
      if (old != null && (t.receiptId?.startsWith('cloud:') ?? false) && !old.startsWith('cloud:')) t.receiptId = old;
    }
    store.replaceAll(next);
    _persist();
  }

  // ---- syncing ----

  /// Uploads this phone's changes, then downloads the partner's. Safe to call any time; calls
  /// that come in while a sync is running make it run once more.
  Future<void> syncNow() {
    if (!isConnected) return Future.value();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final f = _run();
    _running = f;
    return f.whenComplete(() => _running = null);
  }

  Future<void> _run() async {
    _setState(SyncState.syncing);
    try {
      var rounds = 0;
      do {
        _again = false;
        rounds++;
        await _push();
        await _pull();
      } while (_again && rounds < 4);
      meta.lastSyncAt = DateKey.timestamp();
      meta.lastError = null;
      _persist();
      _setState(SyncState.idle);
    } catch (e) {
      final msg = e is SupabaseError ? e.friendly : '$e';
      meta.lastError = msg;
      _persist();
      _setState(SyncState.error, msg);
      rethrow;
    }
  }

  Future<void> _push() async {
    final d = store.data;
    final txById = {for (final t in d.transactions) t.id: t};
    final catById = {for (final c in d.categories) c.id: c};
    // 1. Receipt photos first, so the entry can point at them.
    final photoPaths = <String, String>{};
    for (final id in meta.dirtyTransactions.toList()) {
      final t = txById[id];
      final rid = t?.receiptId;
      if (t == null || rid == null) continue;
      if (rid.startsWith('cloud:')) {
        photoPaths[id] = rid.substring(6);
        continue;
      }
      final path = '${t.spaceId}/${t.id}.jpg';
      if (meta.uploaded[rid] != path) {
        final jpeg = photos?.load(rid);
        if (jpeg != null) {
          await client.upload(bucket, path, jpeg);
          meta.uploaded[rid] = path;
          _persist();
        }
      }
      if (meta.uploaded[rid] == path) photoPaths[id] = path;
    }

    // 2. Categories before entries (entries point at categories).
    for (final table in SyncTable.values) {
      final rows = <Row>[];
      final sent = <String, String>{};
      final dirty = (table == SyncTable.categories ? meta.dirtyCategories : meta.dirtyTransactions).toList()..sort();
      for (final id in dirty) {
        if (table == SyncTable.categories) {
          final c = catById[id];
          if (c == null) {
            meta.setDirty(table, id, false);
            continue;
          }
          rows.add(CloudRows.categoryRow(c));
          sent[id] = c.updatedAt ?? '';
        } else {
          final t = txById[id];
          if (t == null) {
            meta.setDirty(table, id, false);
            continue;
          }
          rows.add(CloudRows.transactionRow(t, photoPaths[id]));
          sent[id] = t.updatedAt;
        }
      }
      if (table == SyncTable.categories) {
        for (final id in meta.categoryTombstones.keys.toList()..sort()) {
          final dead = meta.categoryTombstones[id]!;
          rows.add(CloudRows.categoryRow(dead, deleted: true));
          sent[id] = dead.updatedAt ?? '';
        }
      } else {
        for (final id in meta.tombstones.keys.toList()..sort()) {
          final dead = meta.tombstones[id]!;
          final rid = dead.receiptId;
          rows.add(CloudRows.transactionRow(dead, rid != null && rid.startsWith('cloud:') ? rid.substring(6) : null, deleted: true));
          sent[id] = dead.updatedAt;
        }
      }
      if (rows.isEmpty) continue;
      for (var start = 0; start < rows.length; start += 200) {
        final chunk = rows.sublist(start, start + 200 > rows.length ? rows.length : start + 200);
        final accepted = (await client.upsert(table.name, chunk)).toSet();
        // The server ignores an edit older than its own copy (the partner changed it later).
        // Fetch the winning version of those rows so this phone shows it.
        final lost = [
          for (final r in chunk)
            if (!accepted.contains(r['id'])) r['id'] as String,
        ];
        if (lost.isNotEmpty) {
          final winners = await client.select(table.name, filters: [('id', SupabaseClient.inList(lost))]);
          _apply(table, winners, force: true);
        }
      }
      // Forget what was sent, unless it changed again meanwhile.
      final now = store.data;
      final nowAt = table == SyncTable.categories
          ? {for (final c in now.categories) c.id: c.updatedAt ?? ''}
          : {for (final t in now.transactions) t.id: t.updatedAt};
      for (final e in sent.entries) {
        final id = e.key, at = e.value;
        if (table == SyncTable.categories) {
          final dead = meta.categoryTombstones[id];
          if (dead != null && (dead.updatedAt ?? '') == at) meta.categoryTombstones.remove(id);
        } else {
          final dead = meta.tombstones[id];
          if (dead != null && dead.updatedAt == at) {
            meta.tombstones.remove(id);
            if (dead.receiptId != null) await _removePhoto(dead);
          }
        }
        final local = nowAt[id];
        if (meta.isDirty(table, id) && (local == null || local == at)) meta.setDirty(table, id, false);
      }
      _persist();
    }
  }

  Future<void> _removePhoto(Transaction dead) async {
    final rid = dead.receiptId;
    if (rid == null) return;
    final path = rid.startsWith('cloud:') ? rid.substring(6) : meta.uploaded[rid];
    if (path != null) {
      try {
        await client.remove(bucket, [path]);
      } catch (_) {}
    }
    photos?.delete(rid);
    meta.uploaded.remove(rid);
  }

  Future<void> _pull() async {
    String? since(String table) {
      final t = meta.lastPull[table];
      if (t == null) return null;
      return DateKey.timestamp(DateTime.fromMillisecondsSinceEpoch(Timestamps.millis(t) - pullOverlapMs, isUtc: true));
    }

    final results = <String, List<Row>>{};
    for (final table in ['households', 'members', 'spaces', 'categories', 'transactions']) {
      final rows = await fetchAll(table, since: since(table));
      results[table] = rows;
      if (rows.isNotEmpty) {
        Object? latest = rows.first['server_updated_at'];
        for (final r in rows) {
          if (Timestamps.newer(r['server_updated_at'], latest)) latest = r['server_updated_at'];
        }
        meta.lastPull[table] = Timestamps.iso(latest);
      }
    }
    final d = store.data;
    var changed = false;
    for (final h in results['households']!) {
      if (h['id'] != meta.householdId) continue;
      final cur = (h['currency'] as String?) ?? d.settings.currency;
      final code = h['invite_code'] as String?;
      if (d.settings.currency != cur || d.settings.inviteCode != code) {
        d.settings.currency = cur;
        d.settings.inviteCode = code;
        changed = true;
      }
    }
    for (final m in results['members']!) {
      final uid = m['user_id'];
      if (uid is! String) continue;
      final name = (m['display_name'] as String?) ?? '';
      final u = d.users.where((x) => x.id == uid).firstOrNull;
      if (u != null) {
        if (u.name != name) {
          u.name = name;
          changed = true;
        }
      } else {
        d.users.add(User(id: uid, name: name));
        changed = true;
      }
      final house = d.spaces.where((s) => s.type == SpaceType.house).firstOrNull;
      if (house != null && !house.memberIds.contains(uid)) {
        house.memberIds.add(uid);
        changed = true;
      }
    }
    for (final s in results['spaces']!) {
      final id = s['id'], type = SpaceType.parse(s['type']);
      if (id is! String || type == null || d.spaces.any((x) => x.id == id)) continue;
      d.spaces.add(Space(id: id, type: type, name: (s['name'] as String?) ?? '', ownerId: s['owner_id'] as String?));
      changed = true;
    }
    if (_merge(SyncTable.categories, results['categories']!, d, force: false)) changed = true;
    if (_merge(SyncTable.transactions, results['transactions']!, d, force: false)) changed = true;
    if (_mergeDuplicateCategories(d)) {
      changed = true;
      _again = true; // upload the merge right away
    }
    _persist();
    if (changed) store.replaceAll(d);
  }

  /// Two phones that each added "Pets" offline end up with two "Pets" categories. After each
  /// download, visible categories with the same space, kind and name (ignoring case) are merged:
  /// the lowest id stays, entries move to it and the others are removed. Both phones (and the
  /// web app) pick the same one, so they end up the same.
  bool _mergeDuplicateCategories(BudgetData d) {
    final groups = <String, List<Category>>{};
    for (final c in d.categories.where((c) => !c.archived)) {
      groups.putIfAbsent('${c.spaceId}|${c.kind.name}|${c.name.trim().toLowerCase()}', () => []).add(c);
    }
    final loserToWinner = <String, String>{};
    for (final cats in groups.values) {
      if (cats.length < 2) continue;
      final winner = cats.map((c) => c.id).reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
      for (final c in cats) {
        if (c.id != winner) loserToWinner[c.id] = winner;
      }
    }
    if (loserToWinner.isEmpty) return false;
    final ts = DateKey.timestamp(store.now());
    for (final t in d.transactions) {
      final w = loserToWinner[t.categoryId];
      if (w != null) {
        t.categoryId = w;
        t.updatedAt = ts;
        meta.setDirty(SyncTable.transactions, t.id, true);
      }
    }
    for (final c in d.categories.where((c) => loserToWinner.containsKey(c.id))) {
      meta.categoryTombstones[c.id] = c.copy()..updatedAt = ts;
      meta.setDirty(SyncTable.categories, c.id, false);
    }
    d.categories.removeWhere((c) => loserToWinner.containsKey(c.id));
    return true;
  }

  bool _apply(SyncTable table, List<Row> rows, {required bool force}) {
    final d = store.data;
    final changed = _merge(table, rows, d, force: force);
    if (changed) store.replaceAll(d);
    return changed;
  }

  /// Merges rows from the cloud into the phone's copy. A row this phone changed more recently
  /// (and has not uploaded yet) is kept; otherwise the cloud version wins.
  bool _merge(SyncTable table, List<Row> rows, BudgetData d, {required bool force}) {
    var changed = false;
    final catIndex = <String, int>{};
    for (var i = d.categories.length - 1; i >= 0; i--) {
      catIndex[d.categories[i].id] = i;
    }
    final txIndex = <String, int>{};
    for (var i = d.transactions.length - 1; i >= 0; i--) {
      txIndex[d.transactions[i].id] = i;
    }
    final removed = <String>{};
    for (final r in rows) {
      final id = r['id'];
      if (id is! String) continue;
      final deleted = r['deleted'] == true;
      if (table == SyncTable.categories) {
        final i = removed.contains(id) ? null : catIndex[id];
        if (!force && i != null && meta.isDirty(table, id) && !Timestamps.newer(r['updated_at'], d.categories[i].updatedAt)) continue;
        final dead = meta.categoryTombstones[id];
        if (dead != null) {
          if (!force && !Timestamps.newer(r['updated_at'], dead.updatedAt)) continue;
          meta.categoryTombstones.remove(id);
        }
        meta.setDirty(table, id, false);
        if (deleted) {
          if (i != null) {
            removed.add(id);
            changed = true;
          }
          continue;
        }
        final next = CloudRows.category(r);
        if (next == null) continue;
        if (i != null) {
          if (d.categories[i] != next) {
            d.categories[i] = next;
            changed = true;
          }
        } else {
          removed.remove(id);
          catIndex[id] = d.categories.length;
          d.categories.add(next);
          changed = true;
        }
      } else {
        final i = removed.contains(id) ? null : txIndex[id];
        final dead = meta.tombstones[id];
        if (!force) {
          if (i != null && meta.isDirty(table, id) && !Timestamps.newer(r['updated_at'], d.transactions[i].updatedAt)) continue;
          if (dead != null && !Timestamps.newer(r['updated_at'], dead.updatedAt)) continue;
        }
        if (dead != null) meta.tombstones.remove(id);
        meta.setDirty(table, id, false);
        if (deleted) {
          if (i != null) {
            removed.add(id);
            changed = true;
          }
          continue;
        }
        final next = CloudRows.transaction(r);
        if (next == null) continue;
        if (i != null) {
          final local = d.transactions[i];
          final lr = local.receiptId;
          // Keep using the photo already on this phone.
          if (lr != null && (next.receiptId == null || meta.uploaded[lr] == r['receipt_path'])) next.receiptId = lr;
          if (local != next) {
            d.transactions[i] = next;
            changed = true;
          }
        } else {
          removed.remove(id);
          txIndex[id] = d.transactions.length;
          d.transactions.add(next);
          changed = true;
        }
      }
    }
    if (removed.isNotEmpty) {
      if (table == SyncTable.categories) {
        d.categories.removeWhere((c) => removed.contains(c.id));
      } else {
        d.transactions.removeWhere((t) => removed.contains(t.id));
      }
    }
    return changed;
  }

  // ---- household settings ----

  Future<void> setCurrency(String code) async {
    final hid = meta.householdId;
    if (hid == null) return;
    await client.update('households', {'currency': code}, 'id', hid);
    store.setCurrency(code);
  }

  Future<void> rename(String displayName) async {
    final uid = meta.userId;
    if (uid == null) return;
    await client.update('members', {'display_name': Limits.displayName(displayName)}, 'user_id', uid);
    await syncNow();
  }

  /// A receipt photo the partner took: downloaded once and kept on this phone.
  Future<Uint8List?> photo(String receiptId) async {
    final local = photos?.load(receiptId);
    if (local != null) return local;
    if (!receiptId.startsWith('cloud:')) return null;
    try {
      final data = await client.download(bucket, receiptId.substring(6));
      photos?.save(data, id: receiptId);
      return data;
    } catch (_) {
      return null;
    }
  }

  static SyncMeta? decodeMeta(String? raw) {
    if (raw == null) return null;
    try {
      return SyncMeta.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
