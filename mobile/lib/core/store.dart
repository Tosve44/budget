import 'dart:io';

import 'category_icons.dart';
import 'models.dart';
import 'money.dart';

/// Where the data is saved. The app uses a file on the phone; tests use memory.
abstract class DataStorage {
  String? load();
  void save(String data);
}

class MemoryStorage implements DataStorage {
  String? stored;
  bool failSaves = false;
  MemoryStorage([this.stored]);
  @override
  String? load() => stored;
  @override
  void save(String data) {
    if (failSaves) throw const FileSystemException('No space left on device');
    stored = data;
  }
}

/// Saves to one JSON file, replacing it in one step so a crash can't leave half a file.
class FileStorage implements DataStorage {
  final File file;
  FileStorage(this.file);
  @override
  String? load() {
    try {
      return file.existsSync() ? file.readAsStringSync() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void save(String data) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(data, flush: true);
    tmp.renameSync(file.path);
  }
}

enum SyncTable { categories, transactions }

class MonthSummary {
  final int income;
  final int spent;

  /// Sum of the monthly budgets of the visible expense categories.
  final int budget;
  final Map<String, int> byCategory;
  final int count;
  const MonthSummary({required this.income, required this.spent, required this.budget, required this.byCategory, required this.count});

  int get left => budget - spent;
  int get balance => income - spent;
  bool get isOverBudget => budget > 0 && spent > budget;
  double get usedFraction => budget > 0 ? (spent / budget).clamp(0, 1).toDouble() : 0;
}

typedef LocalChange = void Function(SyncTable table, String id, Object? deleted);

/// The app's data and every change to it. Mirrors `Store` in the web app's store.js.
class BudgetStore {
  BudgetData data;
  final DataStorage? storage;

  /// Called after every change (the screens redraw).
  final List<void Function()> listeners = [];

  /// Called when this phone changes a category or entry, so sync knows what to upload. For a
  /// deleted entry the last copy is passed along (with a fresh updatedAt). Changes that come
  /// from the cloud (replaceAll) do not call it.
  LocalChange? onLocalChange;

  /// The last save error, if saving failed (for example, the phone is full).
  Object? lastSaveError;

  /// Clock, replaceable in tests.
  DateTime Function() now = DateTime.now;

  BudgetStore({this.storage, BudgetData? initial}) : data = initial ?? _load(storage);

  static BudgetData _load(DataStorage? storage) {
    final raw = storage?.load();
    if (raw != null) {
      try {
        return BudgetData.decode(raw);
      } catch (_) {
        // Damaged file: start fresh instead of crashing.
      }
    }
    return BudgetData.initial();
  }

  String _ts() => DateKey.timestamp(now());

  void _changed(SyncTable table, String id, [Object? deleted]) => onLocalChange?.call(table, id, deleted);

  void save() {
    try {
      storage?.save(data.encode());
      lastSaveError = null;
    } catch (e) {
      lastSaveError = e;
    }
    for (final l in List.of(listeners)) {
      l();
    }
  }

  /// Replaces all data without marking anything as changed (used by sync), then saves.
  void replaceAll(BudgetData next) {
    data = next;
    save();
  }

  // ---- reads ----

  User get currentUser => data.users.firstWhere((u) => u.id == data.settings.currentUserId, orElse: () => data.users.first);
  User? user(String id) => _first(data.users, (u) => u.id == id);
  Space? personalSpace([String? userId]) {
    final uid = userId ?? currentUser.id;
    return _first(data.spaces, (s) => s.type == SpaceType.personal && s.ownerId == uid);
  }

  Space? get houseSpace => _first(data.spaces, (s) => s.type == SpaceType.house);
  Space? space(String id) => _first(data.spaces, (s) => s.id == id);

  List<Category> categories(String spaceId, {bool includeArchived = false, EntryKind? kind}) {
    final list = data.categories
        .where((c) => c.spaceId == spaceId && (includeArchived || !c.archived) && (kind == null || c.kind == kind))
        .toList();
    _stableSort(list, (a, b) => a.order.compareTo(b.order));
    return list;
  }

  Category? category(String id) => _first(data.categories, (c) => c.id == id);

  /// Entries of a space, newest first; only one month when [month] ("YYYY-MM") is given.
  List<Transaction> transactions(String spaceId, {String? month}) {
    final list = data.transactions.where((t) => t.spaceId == spaceId && (month == null || t.date.startsWith(month))).toList();
    _stableSort(list, (a, b) => (b.date + b.createdAt).compareTo(a.date + a.createdAt));
    return list;
  }

  MonthSummary monthSummary(String spaceId, String month) {
    final txs = transactions(spaceId, month: month);
    final by = <String, int>{};
    var income = 0, spent = 0;
    for (final t in txs) {
      if (t.kind == EntryKind.income) {
        income += t.amount;
      } else {
        spent += t.amount;
      }
      by[t.categoryId] = (by[t.categoryId] ?? 0) + t.amount;
    }
    final budget = categories(spaceId, kind: EntryKind.expense).fold<int>(0, (s, c) => s + c.budget);
    return MonthSummary(income: income, spent: spent, budget: budget, byCategory: by, count: txs.length);
  }

  // ---- writes ----

  void setCurrentUser(String id) {
    if (user(id) == null) return;
    data.settings.currentUserId = id;
    save();
  }

  void setCurrency(String code) {
    data.settings.currency = code;
    save();
  }

  void renameUser(String id, String name) {
    final t = name.trim();
    final u = user(id);
    if (t.isEmpty || u == null) return;
    u.name = Limits.clip(t, Limits.personName);
    save();
  }

  Transaction addTransaction({
    required String spaceId,
    required String categoryId,
    required EntryKind kind,
    required int amount,
    required String date,
    String note = '',
    List<ReceiptItem>? items,
    String? receiptId,
  }) {
    final ts = _ts();
    final t = Transaction(
      id: Ids.make('tx'),
      spaceId: spaceId,
      categoryId: categoryId,
      kind: kind,
      amount: amount,
      date: date,
      note: Limits.clip(note, Limits.note),
      createdBy: currentUser.id,
      createdAt: ts,
      updatedAt: ts,
      receiptId: receiptId,
      items: (items == null || items.isEmpty) ? null : _cleanItems(items),
    );
    data.transactions.add(t);
    _changed(SyncTable.transactions, t.id);
    save();
    return t;
  }

  /// Changes an entry. Returns false when it no longer exists (deleted on the other phone).
  bool updateTransaction(String id, void Function(Transaction t) change) {
    final i = data.transactions.indexWhere((t) => t.id == id);
    if (i < 0) return false;
    final t = data.transactions[i];
    change(t);
    if (t.items != null) t.items = t.items!.isEmpty ? null : _cleanItems(t.items!);
    t.note = Limits.clip(t.note, Limits.note);
    t.updatedAt = _ts();
    _changed(SyncTable.transactions, id);
    save();
    return true;
  }

  void deleteTransaction(String id) {
    final i = data.transactions.indexWhere((t) => t.id == id);
    if (i < 0) return;
    final dead = data.transactions.removeAt(i);
    dead.updatedAt = _ts();
    _changed(SyncTable.transactions, id, dead);
    save();
  }

  /// True when a visible category of that kind in that space already has this name (ignoring
  /// case and spaces at the ends). Such a name is refused, like in the web app.
  bool categoryNameTaken(String name, String spaceId, EntryKind kind, {String? excluding}) {
    final key = name.trim().toLowerCase();
    return data.categories.any(
      (c) => c.id != excluding && !c.archived && c.spaceId == spaceId && c.kind == kind && c.name.trim().toLowerCase() == key,
    );
  }

  Category addCategory({required String spaceId, required String name, required EntryKind kind, int budget = 0, String icon = ''}) {
    final order = data.categories.fold<int>(-1, (m, c) => c.order > m ? c.order : m) + 1;
    final c = Category(
      id: Ids.make('cat'),
      spaceId: spaceId,
      name: Limits.clip(name.trim(), Limits.categoryName),
      kind: kind,
      budget: budget.clamp(0, Limits.maxCents),
      order: order,
      icon: _icon(icon),
      updatedAt: _ts(),
    );
    data.categories.add(c);
    _changed(SyncTable.categories, c.id);
    save();
    return c;
  }

  /// An icon as stored: trimmed, at most [CategoryIcons.maxLength] characters ('' = by name).
  static String _icon(String icon) => Limits.clip(icon.trim(), CategoryIcons.maxLength);

  void updateCategory(String id, {String? name, int? budget, bool? archived, String? icon}) {
    final c = category(id);
    if (c == null) return;
    if (icon != null) c.icon = _icon(icon);
    if (name != null) c.name = Limits.clip(name.trim(), Limits.categoryName);
    if (budget != null) c.budget = budget.clamp(0, Limits.maxCents);
    if (archived != null) c.archived = archived;
    c.updatedAt = _ts();
    _changed(SyncTable.categories, id);
    save();
  }

  /// Moves a category one place up (-1) or down (+1) among categories of the same kind.
  void moveCategory(String id, int dir) {
    final c = category(id);
    if (c == null) return;
    final list = categories(c.spaceId, includeArchived: true, kind: c.kind);
    final i = list.indexWhere((x) => x.id == id);
    final j = i + dir;
    if (i < 0 || j < 0 || j >= list.length) return;
    final tmp = list[i].order;
    list[i].order = list[j].order;
    list[j].order = tmp;
    final ts = _ts();
    for (final x in [list[i], list[j]]) {
      x.updatedAt = ts;
      _changed(SyncTable.categories, x.id);
    }
    save();
  }

  /// Puts the categories of one kind in a new order (drag and drop). Ids not in the list keep
  /// their place at the end.
  void reorderCategories(String spaceId, EntryKind kind, List<String> ids) {
    final current = categories(spaceId, includeArchived: true, kind: kind);
    final byId = {for (final c in current) c.id: c};
    final seen = <String>{};
    final wanted = ids.where((id) => byId.containsKey(id) && seen.add(id)).toList();
    final newOrder = [...wanted, ...current.map((c) => c.id).where((id) => !seen.contains(id))];
    final slots = current.map((c) => c.order).toList()..sort();
    final ts = _ts();
    for (var k = 0; k < newOrder.length && k < slots.length; k++) {
      final c = byId[newOrder[k]]!;
      if (c.order != slots[k]) {
        c.order = slots[k];
        c.updatedAt = ts;
        _changed(SyncTable.categories, c.id);
      }
    }
    save();
  }

  // ---- backup ----

  String exportJson() => data.encode(pretty: true);

  /// Restores a backup. If the file is not a valid backup, nothing changes and the error is thrown.
  void importJson(String json) {
    data = BudgetData.decode(json);
    for (final c in data.categories) {
      _changed(SyncTable.categories, c.id);
    }
    for (final t in data.transactions) {
      _changed(SyncTable.transactions, t.id);
    }
    save();
  }

  void reset() {
    data = BudgetData.initial();
    save();
  }
}

List<ReceiptItem> _cleanItems(List<ReceiptItem> items) =>
    items.take(Limits.items).map((it) => ReceiptItem(name: Limits.clip(it.name, Limits.itemName), price: Limits.clamp(it.price))).toList();

T? _first<T>(Iterable<T> list, bool Function(T) test) {
  for (final x in list) {
    if (test(x)) return x;
  }
  return null;
}

/// JavaScript's Array.sort is stable; Dart's List.sort is not guaranteed to be. Ties keep their order.
void _stableSort<T>(List<T> list, int Function(T, T) compare) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}
