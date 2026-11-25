import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'models.dart';
import 'money.dart';
import 'store.dart';

class PricePoint {
  final String date;
  final int price;
  final String txId;
  final String spaceId;
  final String createdAt;
  const PricePoint({required this.date, required this.price, required this.txId, required this.spaceId, required this.createdAt});
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

  static Map<String, PriceGroup> groups(List<Transaction> transactions) {
    final map = <String, PriceGroup>{};
    for (final t in transactions) {
      for (final it in t.items ?? const <ReceiptItem>[]) {
        final key = normalize(it.name);
        if (key.isEmpty) continue;
        map.putIfAbsent(key, () => PriceGroup(key, it.name, []));
        map[key]!.entries.add(PricePoint(date: t.date, price: it.price, txId: t.id, spaceId: t.spaceId, createdAt: t.createdAt));
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

  /// The most recent earlier price of an item, not counting transaction [excluding].
  static PricePoint? previousPrice(String name, String before, String? excluding, List<Transaction> transactions) {
    final key = normalize(name);
    PricePoint? best;
    for (final t in transactions) {
      if (t.id == excluding || t.date.compareTo(before) > 0) continue;
      for (final it in t.items ?? const <ReceiptItem>[]) {
        if (normalize(it.name) == key && (best == null || t.date.compareTo(best.date) >= 0)) {
          best = PricePoint(date: t.date, price: it.price, txId: t.id, spaceId: t.spaceId, createdAt: t.createdAt);
        }
      }
    }
    return best;
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

/// Prepared for a later store release: a free version with fewer categories and a paid version
/// with all categories plus your own. While testing, everyone has the full version.
enum Plan { free, full }

class PlanRules {
  PlanRules._();
  static const freePersonalExpenses = {'Rent', 'Groceries', 'Food & Drinks', 'Car', 'Shopping', 'Saving', 'Partner balance'};
  static const freeHouseExpenses = {'Groceries', 'Shopping', 'Unexpected expenses'};

  static bool isAvailable(Category c, Space? space, Plan plan) {
    if (plan == Plan.full || c.kind == EntryKind.income) return true;
    final free = space?.type == SpaceType.house ? freeHouseExpenses : freePersonalExpenses;
    return free.contains(c.name);
  }

  static bool canAddCustomCategory(Plan plan) => plan == Plan.full;
  static bool canRenameCategory(Plan plan) => plan == Plan.full;
}

extension StoreExtras on BudgetStore {
  Map<String, PriceGroup> itemHistory() => PriceHistory.groups(data.transactions);

  PricePoint? previousPrice(String name, String before, {String? excluding}) =>
      PriceHistory.previousPrice(name, before, excluding, data.transactions);

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
