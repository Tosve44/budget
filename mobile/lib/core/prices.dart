import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'models.dart';
import 'money.dart';
import 'premium.dart';
import 'store.dart';

export 'premium.dart' show Plan, PlanRules;

class PricePoint {
  final String date;

  /// Price of one piece or one kilo (see [ReceiptItem.perUnit]), so buying two, or a bigger
  /// bunch of bananas, does not look like a price rise.
  final int price;

  /// "kg" when [price] is per kilo.
  final String? unit;

  /// The shop it was bought at ('' when not known).
  final String store;
  final String txId;
  final String spaceId;
  final String createdAt;
  const PricePoint({
    required this.date,
    required this.price,
    this.unit,
    this.store = '',
    required this.txId,
    required this.spaceId,
    required this.createdAt,
  });
}

class PriceGroup {
  final String key;

  /// The name as it was first written.
  final String name;

  /// Oldest first.
  final List<PricePoint> entries;
  PriceGroup(this.key, this.name, this.entries);

  PricePoint get latest => entries.last;
  PricePoint? get previous => entries.length > 1 ? entries[entries.length - 2] : null;

  /// Change since the first time it was bought, in percent (null if bought only once).
  double? get changeSinceFirst => entries.length > 1 ? Money.percentChange(latest.price, entries.first.price) : null;

  /// The trend at one shop (by default the shop of the newest purchase), see [StoreTrend].
  StoreTrend trend([String? store]) => StoreTrend.of(entries, store);
}

/// An item's price trend at one shop: prices change from shop to shop, so the change is worked out
/// between purchases at the same shop. A purchase without a shop (typed by hand, or saved before
/// shops were kept) could be from any shop, so it counts for every shop; with no shop at all,
/// every purchase counts. Same as storeTrend in the web app's store.js.
class StoreTrend {
  final String store;

  /// Purchases at [store], oldest first.
  final List<PricePoint> entries;
  StoreTrend(this.store, this.entries);

  factory StoreTrend.of(List<PricePoint> all, [String? store]) {
    final shop = store ?? (all.isEmpty ? '' : all.last.store);
    return StoreTrend(shop, all.where((e) => shop.isEmpty || e.store.isEmpty || PriceHistory.sameStore(e.store, shop)).toList());
  }

  PricePoint? get first => entries.firstOrNull;
  PricePoint? get last => entries.lastOrNull;

  /// Change between the first and the newest purchase at this shop, in percent; null if bought
  /// there only once.
  double? get change => entries.length > 1 ? Money.percentChange(last!.price, first!.price) : null;
}

class PriceHistory {
  PriceHistory._();

  static final _marks = RegExp(r'[̀-ͯ]');
  static final _other = RegExp(r'[^\p{L}\p{N}%]+', unicode: true);

  /// "Čokolada  MILKA, 100g" and "cokolada milka 100g" are the same item. Exactly the web app's
  /// normalizeItem: lowercase, NFKD, accents removed, anything not a letter, digit or % is a space.
  static String normalize(String name) {
    final s = unorm.nfkd(name.toLowerCase()).replaceAll(_marks, '').replaceAll(_other, ' ');
    return s.replaceAll(RegExp(r'^\s+|\s+$'), '');
  }

  /// True when two shop names are the same shop ("SPAR" and "Spar").
  static bool sameStore(String? a, String? b) => normalize(a ?? '') == normalize(b ?? '');

  /// Shops in the price history, A to Z (as in the web app's Prices screen).
  static List<String> stores(Iterable<PriceGroup> groups) {
    final name = <String, String>{};
    for (final g in groups) {
      for (final e in g.entries) {
        if (e.store.isNotEmpty) name.putIfAbsent(normalize(e.store), () => e.store);
      }
    }
    return name.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  static Map<String, PriceGroup> groups(List<Transaction> transactions) {
    final map = <String, PriceGroup>{};
    for (final t in transactions) {
      for (final it in t.items ?? const <ReceiptItem>[]) {
        final key = normalize(it.name);
        final each = it.perUnit;
        if (key.isEmpty || each == null) continue;
        map.putIfAbsent(key, () => PriceGroup(key, it.name, []));
        map[key]!.entries.add(
          PricePoint(date: t.date, price: each, unit: it.unit, store: t.store, txId: t.id, spaceId: t.spaceId, createdAt: t.createdAt),
        );
      }
    }
    for (final g in map.values) {
      _stable(g.entries, (a, b) => (a.date + a.createdAt).compareTo(b.date + b.createdAt));
    }
    return map;
  }

  /// Items for the Prices screen: most recently bought first, filtered by a search text.
  static List<PriceGroup> list(List<Transaction> transactions, {String search = ''}) {
    final q = normalize(search);
    final out = groups(transactions).values.where((g) => q.isEmpty || g.key.contains(q)).toList();
    out.sort((a, b) => a.latest.date != b.latest.date ? b.latest.date.compareTo(a.latest.date) : a.key.compareTo(b.key));
    return out;
  }

  /// The most recent earlier price of an item, not counting transaction [excluding]. With
  /// [store]: the latest earlier price at that shop, or at any shop when it was never bought there
  /// (then the result's [PricePoint.store] says where).
  static PricePoint? previousPrice(String name, String before, String? excluding, List<Transaction> transactions, {String? store}) {
    final key = normalize(name);
    PricePoint? best, here;
    final atShop = store != null && store.isNotEmpty;
    for (final t in transactions) {
      if (t.id == excluding || t.date.compareTo(before) > 0) continue;
      for (final it in t.items ?? const <ReceiptItem>[]) {
        final each = it.perUnit;
        if (normalize(it.name) != key || each == null) continue;
        final p = PricePoint(
          date: t.date,
          price: each,
          unit: it.unit,
          store: t.store,
          txId: t.id,
          spaceId: t.spaceId,
          createdAt: t.createdAt,
        );
        if (best == null || t.date.compareTo(best.date) >= 0) best = p;
        if (atShop && sameStore(t.store, store) && (here == null || t.date.compareTo(here.date) >= 0)) here = p;
      }
    }
    return here ?? best;
  }

  static void _stable<T>(List<T> list, int Function(T, T) cmp) {
    final idx = [for (var i = 0; i < list.length; i++) (i, list[i])];
    idx.sort((a, b) {
      final c = cmp(a.$2, b.$2);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    for (var i = 0; i < list.length; i++) {
      list[i] = idx[i].$2;
    }
  }
}

/// The monthly transfer that gives both people the same personal budget.
class PartnerTransfer {
  final String fromUserId;
  final String toUserId;
  final int amount;
  const PartnerTransfer(this.fromUserId, this.toUserId, this.amount);
}

class PartnerBalance {
  PartnerBalance._();

  /// Half the difference of the two incomes, from the person who earns more.
  static PartnerTransfer? transfer(String a, int incomeA, String b, int incomeB) {
    final diff = incomeA - incomeB;
    final amount = diff.abs() ~/ 2;
    if (amount == 0) return null;
    return diff > 0 ? PartnerTransfer(a, b, amount) : PartnerTransfer(b, a, amount);
  }
}

extension StoreExtras on BudgetStore {
  Map<String, PriceGroup> itemHistory() => PriceHistory.groups(data.transactions);

  PricePoint? previousPrice(String name, String before, {String? excluding, String? store}) =>
      PriceHistory.previousPrice(name, before, excluding, data.transactions, store: store);

  /// Categories offered when adding an entry: visible and included in the plan.
  List<Category> pickableCategories(String spaceId, EntryKind kind, Plan plan) {
    final sp = space(spaceId);
    return categories(spaceId, kind: kind).where((c) => PlanRules.isAvailable(c, sp, plan)).toList();
  }

  /// Personal income of a person in a month, not counting partner balance money received.
  int personalIncome(String userId, String month) {
    final sp = personalSpace(userId);
    if (sp == null) return 0;
    return transactions(sp.id, month: month)
        .where((t) => t.kind == EntryKind.income && category(t.categoryId)?.name != DefaultCategories.partnerBalance)
        .fold(0, (s, t) => s + t.amount);
  }

  PartnerTransfer? suggestedPartnerTransfer(String month) {
    if (data.users.length < 2) return null;
    final a = data.users[0].id, b = data.users[1].id;
    return PartnerBalance.transfer(a, personalIncome(a, month), b, personalIncome(b, month));
  }
}
