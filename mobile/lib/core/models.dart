import 'dart:convert';
import 'dart:math';

// The data model. It is the same JSON shape as the web app (store.js, schemaVersion 1), so a
// backup from the web app opens here and the other way round, and the same as the native
// iPhone app. Money is always whole cents (int). Dates are "YYYY-MM-DD"; months are "YYYY-MM".

const kSchemaVersion = 1;

enum EntryKind {
  expense,
  income;

  static EntryKind? parse(Object? s) => s == 'expense'
      ? expense
      : s == 'income'
      ? income
      : null;
}

enum SpaceType {
  personal,
  house;

  static SpaceType? parse(Object? s) => s == 'personal'
      ? personal
      : s == 'house'
      ? house
      : null;
}

class BudgetError implements Exception {
  final String message;
  const BudgetError(this.message);
  @override
  String toString() => message;
}

class Settings {
  String currency;
  String currentUserId;

  /// The household's invite code once syncing is set up (the partner types it to join).
  String? inviteCode;

  /// Other settings the web app keeps (for example its receipt language), kept unchanged.
  Map<String, dynamic> extra;

  Settings({this.currency = 'EUR', required this.currentUserId, this.inviteCode, Map<String, dynamic>? extra}) : extra = extra ?? {};

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
    currency: (j['currency'] as String?) ?? 'EUR',
    currentUserId: (j['currentUserId'] as String?) ?? '',
    inviteCode: j['inviteCode'] as String?,
    extra: Map.of(j)..removeWhere((k, _) => k == 'currency' || k == 'currentUserId' || k == 'inviteCode'),
  );

  Map<String, dynamic> toJson() => {
    ...extra,
    'currency': currency,
    'currentUserId': currentUserId,
    if (inviteCode != null) 'inviteCode': inviteCode,
  };

  Settings copy() => Settings.fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);
}

class User {
  final String id;
  String name;
  User({required this.id, required this.name});
  factory User.fromJson(Map<String, dynamic> j) => User(id: j['id'] as String, name: (j['name'] as String?) ?? '');
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class Space {
  final String id;
  final SpaceType type;
  String name;

  /// The person a personal space belongs to; null for the shared house space.
  final String? ownerId;
  List<String> memberIds;

  Space({required this.id, required this.type, required this.name, this.ownerId, List<String>? memberIds}) : memberIds = memberIds ?? [];

  factory Space.fromJson(Map<String, dynamic> j) => Space(
    id: j['id'] as String,
    type: SpaceType.parse(j['type']) ?? (throw const BudgetError('Not a backup file.')),
    name: (j['name'] as String?) ?? '',
    ownerId: j['ownerId'] as String?,
    memberIds: ((j['memberIds'] as List?) ?? []).cast<String>().toList(),
  );

  // The web app writes "ownerId": null for the house space; keep doing the same.
  Map<String, dynamic> toJson() => {'id': id, 'type': type.name, 'name': name, 'ownerId': ownerId, 'memberIds': memberIds};
}

class Category {
  final String id;
  String spaceId;
  String name;
  EntryKind kind;

  /// Monthly budget in cents; 0 means no budget.
  int budget;
  int order;

  /// Hidden categories keep their past entries but are left out of lists and totals.
  bool archived;

  /// The emoji picked for it; empty = the default for its name (see CategoryIcons).
  String icon;

  /// When a phone last changed it (sync: the newest change wins).
  String? updatedAt;

  Category({
    required this.id,
    required this.spaceId,
    required this.name,
    required this.kind,
    this.budget = 0,
    required this.order,
    this.archived = false,
    this.icon = '',
    this.updatedAt,
  });

  factory Category.fromJson(Map<String, dynamic> j) => Category(
    id: j['id'] as String,
    spaceId: j['spaceId'] as String,
    name: (j['name'] as String?) ?? '',
    kind: EntryKind.parse(j['kind']) ?? (throw const BudgetError('Not a backup file.')),
    budget: _int(j['budget']),
    order: _int(j['order']),
    archived: j['archived'] == true,
    icon: j['icon'] is String ? j['icon'] as String : '',
    updatedAt: j['updatedAt'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'spaceId': spaceId,
    'name': name,
    'kind': kind.name,
    'budget': budget,
    'order': order,
    'archived': archived,
    if (icon.isNotEmpty) 'icon': icon,
    if (updatedAt != null) 'updatedAt': updatedAt,
  };

  Category copy() => Category.fromJson(toJson());

  @override
  bool operator ==(Object other) => other is Category && jsonEncode(toJson()) == jsonEncode(other.toJson());
  @override
  int get hashCode => id.hashCode;
}

class ReceiptItem {
  final String name;

  /// Line total in cents.
  final int price;

  /// How many ("2 x 0,59": 2) or how much ("0,856 kg x 1,49": 0.856 with [unit] "kg"), when
  /// the receipt says so. Never 1.
  final double? qty;

  /// "kg" for things sold by weight, otherwise null (pieces).
  final String? unit;

  /// The printed price of one piece or one kilo, in cents (only when it adds up to [price]).
  final int? unitPrice;

  const ReceiptItem._(this.name, this.price, this.qty, this.unit, this.unitPrice);

  /// Keeps a quantity only when it makes sense (a bad one would spoil the price history).
  /// Same rules as cleanItem in the web app's store.js.
  factory ReceiptItem({required String name, required int price, num? qty, String? unit, int? unitPrice}) {
    final q = qty?.toDouble();
    if (q == null || !q.isFinite || q <= 0 || q > 999 || q == 1) return ReceiptItem._(name, price, null, null, null);
    final rq = (q * 1000).round() / 1000;
    final up = unitPrice != null && unitPrice > 0 && ((rq * unitPrice).round() - price).abs() <= 1 ? unitPrice : null;
    return ReceiptItem._(name, price, rq, unit == 'kg' ? 'kg' : null, up);
  }

  factory ReceiptItem.fromJson(Map<String, dynamic> j) => ReceiptItem(
    name: '${j['name'] ?? ''}',
    price: _int(j['price']),
    qty: j['qty'] is num ? j['qty'] as num : null,
    unit: j['unit'] is String ? j['unit'] as String : null,
    unitPrice: j['unitPrice'] is num ? (j['unitPrice'] as num).toInt() : null,
  );
  Map<String, dynamic> toJson() => {
    'name': name,
    'price': price,
    if (qty != null) 'qty': _jsNumber(qty!),
    if (unit != null) 'unit': unit,
    if (unitPrice != null) 'unitPrice': unitPrice,
  };

  /// Price of one piece, or of one kilo, for comparing prices between shopping trips:
  /// "2 x 0,59 = 1,18" is 0,59, "0,856 kg x 1,49 = 1,28" is 1,49.
  int get perUnit {
    final q = qty;
    if (q == null) return price;
    return unitPrice ?? (price / q).round();
  }

  ReceiptItem copyWith({String? name, int? price}) => ReceiptItem(
    name: name ?? this.name,
    price: price ?? this.price,
    qty: qty,
    unit: unit,
    unitPrice: price == null || price == this.price ? unitPrice : null,
  );

  @override
  bool operator ==(Object other) =>
      other is ReceiptItem &&
      other.name == name &&
      other.price == price &&
      other.qty == qty &&
      other.unit == unit &&
      other.unitPrice == unitPrice;
  @override
  int get hashCode => Object.hash(name, price, qty, unit, unitPrice);
  @override
  String toString() => '$name $price${qty != null ? ' ($qty${unit ?? ''}${unitPrice != null ? ' x $unitPrice' : ''})' : ''}';
}

/// 2.0 as 2, like JavaScript's JSON, so both apps write the same JSON.
num _jsNumber(double d) => d == d.roundToDouble() ? d.toInt() : d;

class Transaction {
  final String id;
  String spaceId;
  String categoryId;
  EntryKind kind;

  /// Always positive, in cents. [kind] says whether it is money in or out.
  int amount;
  String date;
  String note;
  String createdBy;
  String createdAt;
  String updatedAt;

  /// Id of the receipt photo, stored separately (see PhotoStore). `cloud:<path>` for a photo
  /// that is in the cloud (taken on the other phone).
  String? receiptId;

  /// Receipt lines.
  List<ReceiptItem>? items;

  Transaction({
    required this.id,
    required this.spaceId,
    required this.categoryId,
    required this.kind,
    required this.amount,
    required this.date,
    this.note = '',
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.receiptId,
    this.items,
  });

  factory Transaction.fromJson(Map<String, dynamic> j) {
    final created = (j['createdAt'] as String?) ?? '';
    return Transaction(
      id: j['id'] as String,
      spaceId: j['spaceId'] as String,
      categoryId: j['categoryId'] as String,
      kind: EntryKind.parse(j['kind']) ?? (throw const BudgetError('Not a backup file.')),
      amount: _int(j['amount']),
      date: j['date'] as String,
      note: (j['note'] as String?) ?? '',
      createdBy: (j['createdBy'] as String?) ?? '',
      createdAt: created,
      updatedAt: (j['updatedAt'] as String?) ?? created,
      receiptId: j['receiptId'] as String?,
      items: (j['items'] as List?)?.map((e) => ReceiptItem.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'spaceId': spaceId,
    'categoryId': categoryId,
    'kind': kind.name,
    'amount': amount,
    'date': date,
    'note': note,
    'createdBy': createdBy,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    if (receiptId != null) 'receiptId': receiptId,
    if (items != null) 'items': items!.map((e) => e.toJson()).toList(),
  };

  Transaction copy() => Transaction.fromJson(toJson());

  @override
  bool operator ==(Object other) => other is Transaction && jsonEncode(toJson()) == jsonEncode(other.toJson());
  @override
  int get hashCode => id.hashCode;
}

class BudgetData {
  int schemaVersion;
  Settings settings;
  List<User> users;
  List<Space> spaces;
  List<Category> categories;
  List<Transaction> transactions;

  BudgetData({
    this.schemaVersion = 1,
    required this.settings,
    required this.users,
    required this.spaces,
    required this.categories,
    required this.transactions,
  });

  /// Reads a backup (or the saved file) and checks that it looks right. Same messages as the web app.
  static BudgetData decode(String json) {
    Object? any;
    try {
      any = jsonDecode(json);
    } catch (_) {
      throw const BudgetError('Not a backup file.');
    }
    if (any is! Map<String, dynamic>) throw const BudgetError('Not a backup file.');
    final v = any['schemaVersion'];
    if (v != kSchemaVersion) throw BudgetError('Unsupported backup version: ${v ?? 'undefined'}');
    for (final k in ['users', 'spaces', 'categories', 'transactions']) {
      if (any[k] is! List) throw BudgetError('Backup is missing "$k".');
    }
    if (any['settings'] is! Map) throw const BudgetError('Backup is missing settings.');
    try {
      List<Map<String, dynamic>> list(String k) =>
          (any as Map)[k].map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
      return BudgetData(
        settings: Settings.fromJson(Map<String, dynamic>.from(any['settings'] as Map)),
        users: list('users').map(User.fromJson).toList(),
        spaces: list('spaces').map(Space.fromJson).toList(),
        categories: list('categories').map(Category.fromJson).toList(),
        transactions: list('transactions').map(Transaction.fromJson).toList(),
      );
    } on BudgetError {
      rethrow;
    } catch (_) {
      throw const BudgetError('Not a backup file.');
    }
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'settings': settings.toJson(),
    'users': users.map((e) => e.toJson()).toList(),
    'spaces': spaces.map((e) => e.toJson()).toList(),
    'categories': categories.map((e) => e.toJson()).toList(),
    'transactions': transactions.map((e) => e.toJson()).toList(),
  };

  String encode({bool pretty = false}) => pretty ? const JsonEncoder.withIndent('  ').convert(toJson()) : jsonEncode(toJson());

  BudgetData copy() => decode(encode());

  /// A fresh start: Tosve and Milica, a personal space each and the shared house space, with all
  /// default categories. Same ids as the web app for users and spaces.
  static BudgetData initial() {
    final users = [User(id: 'u_tosve', name: 'Tosve'), User(id: 'u_milica', name: 'Milica')];
    final spaces = [
      Space(id: 'sp_personal_tosve', type: SpaceType.personal, name: 'Personal', ownerId: 'u_tosve', memberIds: ['u_tosve']),
      Space(id: 'sp_personal_milica', type: SpaceType.personal, name: 'Personal', ownerId: 'u_milica', memberIds: ['u_milica']),
      Space(id: 'sp_house', type: SpaceType.house, name: 'House', memberIds: ['u_tosve', 'u_milica']),
    ];
    final categories = <Category>[];
    void add(String spaceId, List<String> names, EntryKind kind) {
      for (final n in names) {
        categories.add(Category(id: Ids.make('cat'), spaceId: spaceId, name: n, kind: kind, order: categories.length));
      }
    }

    for (final sp in spaces) {
      if (sp.type == SpaceType.personal) {
        add(sp.id, DefaultCategories.personalExpenses, EntryKind.expense);
        add(sp.id, DefaultCategories.personalIncome, EntryKind.income);
        // Milica receives the partner balance, so on her side it is also an income category.
        if (sp.ownerId == 'u_milica') add(sp.id, [DefaultCategories.partnerBalance], EntryKind.income);
      } else {
        add(sp.id, DefaultCategories.houseExpenses, EntryKind.expense);
        add(sp.id, DefaultCategories.houseIncome, EntryKind.income);
      }
    }
    return BudgetData(
      settings: Settings(currency: 'EUR', currentUserId: 'u_tosve'),
      users: users,
      spaces: spaces,
      categories: categories,
      transactions: [],
    );
  }
}

class DefaultCategories {
  DefaultCategories._();
  static const personalExpenses = [
    'Car', 'Rent', 'Groceries', 'Food & Drinks', 'Lunch at work', 'Nicotine', 'Gym & Sports', //
    'Shopping', 'Gas', 'Traveling', 'Saving', 'Partner balance', 'Investing', //
    'Cash (ATM)', 'Barber', 'Beauty', 'Toiletries',
  ];
  static const personalIncome = ['Salary', 'Other income'];
  static const houseExpenses = ['Groceries', 'Savings', 'Shopping', 'Travel', 'Unexpected expenses'];
  static const houseIncome = ['Contributions'];

  /// The category for the monthly transfer that evens out both personal budgets.
  static const partnerBalance = 'Partner balance';
}

class Ids {
  Ids._();
  static final _rnd = Random.secure();

  /// "cat_1a2b3c4d5e6f7a8b": prefix plus 16 random hex characters, like the web app.
  static String make([String prefix = 'id']) {
    final sb = StringBuffer('${prefix}_');
    for (var i = 0; i < 16; i++) {
      sb.write(_rnd.nextInt(16).toRadixString(16));
    }
    return sb.toString();
  }
}

/// The cloud database refuses rows over these sizes, and one refused row stops the whole upload
/// (and with it all syncing). So the phone keeps every record inside them. Same as the web app.
class Limits {
  Limits._();

  /// Amounts and budgets in cents: below 1,000,000,000 (10 million euros).
  static const maxCents = 999999999;
  static const note = 500;
  static const categoryName = 60;
  static const items = 300;
  static const itemName = 120;
  static const personName = 40;

  /// Characters as the database counts them (Unicode code points).
  static int length(String s) => s.runes.length;

  static String clip(String s, int max) => s.runes.length <= max ? s : String.fromCharCodes(s.runes.take(max));

  static int clamp(int cents) => cents < -maxCents ? -maxCents : (cents > maxCents ? maxCents : cents);

  /// A person's name as the database takes it: 1 to 40 characters.
  static String displayName(String s) {
    final t = clip(s.trim(), personName);
    return t.isEmpty ? 'Me' : t;
  }
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? (double.tryParse(v)?.toInt() ?? 0);
  return 0;
}

int asInt(Object? v) => _int(v);
