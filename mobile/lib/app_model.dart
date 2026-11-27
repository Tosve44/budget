import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'core/models.dart';
import 'core/money.dart';
import 'core/premium.dart';
import 'core/store.dart';
import 'core/supabase.dart';
import 'core/sync.dart';
import 'platform/photo_picker.dart';
import 'platform/purchases.dart';
import 'platform/receipt_reader.dart';

class AppConfig {
  AppConfig._();

  /// While Tosve and Milica are testing, everyone has Premium. Store builds are made with
  /// --dart-define=PREMIUM_REQUIRED=true, and then Premium is bought in the app.
  static const everyoneHasFullVersion = !bool.fromEnvironment('PREMIUM_REQUIRED');

  /// The Supabase project both phones sync through (the same one the web app uses). Both values
  /// are public by design; privacy comes from the database's row level security rules.
  /// Leave empty to use the app on one phone only, without syncing.
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://ybhtnizbppamcaqavfrx.supabase.co');
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_3zWG5W1GqObHytHGgBFzEg_Xv0N5s9H',
  );
}

/// Light, dark, or whatever the phone is set to (the default). Kept on this phone only.
enum Appearance {
  system('Automatic', ThemeMode.system),
  light('Light', ThemeMode.light),
  dark('Dark', ThemeMode.dark);

  final String title;
  final ThemeMode mode;
  const Appearance(this.title, this.mode);
}

/// Small per-phone preferences (not synced, not in backups).
abstract class Prefs {
  String? get(String key);
  void set(String key, String? value);
}

class MemoryPrefs implements Prefs {
  final Map<String, String> values = {};
  @override
  String? get(String key) => values[key];
  @override
  void set(String key, String? value) => value == null ? values.remove(key) : values[key] = value;
}

class FilePrefs implements Prefs {
  final File file;
  Map<String, dynamic> _values = {};
  FilePrefs(this.file) {
    try {
      if (file.existsSync()) _values = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {}
  }
  @override
  String? get(String key) => _values[key] as String?;
  @override
  void set(String key, String? value) {
    value == null ? _values.remove(key) : _values[key] = value;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(_values));
    } catch (_) {}
  }
}

/// Remembers the sign-in in the phone's secure storage (Keychain on iPhone, Keystore on Android).
class SecureSessionKeeper implements SessionKeeper {
  static const _key = 'supabase.session';
  final FlutterSecureStorage storage;
  AuthSession? _session;
  SecureSessionKeeper(this.storage, this._session);

  static Future<SecureSessionKeeper> open() async {
    const storage = FlutterSecureStorage();
    AuthSession? s;
    try {
      final raw = await storage.read(key: _key);
      if (raw != null) s = AuthSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {}
    return SecureSessionKeeper(storage, s);
  }

  @override
  AuthSession? load() => _session;

  @override
  Future<void> save(AuthSession? session) async {
    _session = session;
    try {
      if (session == null) {
        await storage.delete(key: _key);
      } else {
        await storage.write(key: _key, value: jsonEncode(session.toJson()));
      }
    } catch (_) {}
  }
}

/// Holds the data for the screens and redraws them whenever it changes.
class AppModel extends ChangeNotifier {
  final BudgetStore store;
  final PhotoStore photos;
  final Prefs prefs;
  final ReceiptReader reader;
  final PhotoPicker picker;
  final Purchases purchases;
  SyncEngine? sync;

  /// Everyone has Premium (test builds).
  final bool everyoneHasPremium;
  String? saveProblem;
  Timer? _tick;

  AppModel({
    required this.store,
    required this.photos,
    required this.prefs,
    required this.reader,
    required this.picker,
    Purchases? purchases,
    this.everyoneHasPremium = true,
    DateTime Function()? now,
  }) : purchases = purchases ?? FakePurchases(),
       now = now ?? DateTime.now {
    store.listeners.add(_storeChanged);
  }

  void _storeChanged() {
    saveProblem = store.lastSaveError == null
        ? null
        : 'Could not save on this phone. Is the storage full? Your changes are kept until the app is closed.';
    notifyListeners();
  }

  void attachSync(SyncEngine engine) {
    sync = engine;
    engine.listeners.add(notifyListeners);
    // Every 30 seconds while the app is open (like the web app).
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => syncIfConnected());
  }

  /// Sync now if syncing is set up (app opened, pulled to refresh, every 30 seconds).
  Future<void> syncIfConnected() async {
    final s = sync;
    if (s == null || !s.isConnected) return;
    try {
      await s.syncNow();
    } catch (_) {}
  }

  @override
  void dispose() {
    _tick?.cancel();
    sync?.dispose();
    super.dispose();
  }

  // ---- Premium ----

  final DateTime Function() now;

  /// The store account on this phone has Premium (remembered, so it also works offline).
  bool get premiumFromStore => prefs.get('premiumFromStore') == 'yes';
  set premiumFromStore(bool v) {
    if (v == premiumFromStore) return;
    prefs.set('premiumFromStore', v ? 'yes' : null);
    notifyListeners();
  }

  PremiumStatus get premium =>
      PremiumStatus(everyone: everyoneHasPremium, fromStore: premiumFromStore, householdUntil: sync?.householdPremiumUntil);

  Plan get plan => premium.plan(now());

  /// Asks the store at start and when the app comes back. If this phone pays for Premium, the
  /// household gets it too, so the partner does not have to pay as well.
  Future<void> refreshPremium() async {
    if (!everyoneHasPremium) {
      try {
        // When the store cannot be asked (offline), Premium stays as it was.
        final owns = await purchases.ownsPremium();
        if (owns != null) premiumFromStore = owns;
      } catch (_) {}
    }
    await shareHouseholdPremium();
  }

  /// Keeps the household's Premium going while this phone's store account has it (once a day).
  Future<void> shareHouseholdPremium() async {
    final s = sync;
    if (!premiumFromStore || s == null || !s.isConnected) return;
    final today = DateKey.day(now());
    if (prefs.get('premiumSharedOn') == today) return;
    try {
      await s.extendHouseholdPremium();
      prefs.set('premiumSharedOn', today);
      notifyListeners();
    } catch (_) {}
  }

  Future<PurchaseOutcome> buyPremium(PremiumProduct p) async {
    final o = await purchases.buy(p);
    if (o == PurchaseOutcome.bought) {
      premiumFromStore = true;
      prefs.set('premiumSharedOn', null);
      await shareHouseholdPremium();
    }
    return o;
  }

  /// "Restore purchases". True when Premium was found, null when the store could not be asked.
  Future<bool?> restorePremium() async {
    final owned = await purchases.restore();
    if (owned == null) return null;
    premiumFromStore = owned;
    if (owned) {
      prefs.set('premiumSharedOn', null);
      await shareHouseholdPremium();
    }
    return plan == Plan.full;
  }

  String get currency => store.data.settings.currency;
  String money(int cents) => Money.format(cents, currency: currency);

  Appearance get appearance => Appearance.values.where((a) => a.name == prefs.get('appearance')).firstOrNull ?? Appearance.system;
  set appearance(Appearance a) {
    prefs.set('appearance', a == Appearance.system ? null : a.name);
    notifyListeners();
  }

  /// A receipt photo: on this phone, or downloaded once from the cloud if the partner took it.
  Future<Uint8List?> photoData(String id) async => photos.load(id) ?? await sync?.photo(id);

  static Future<AppModel> live() async {
    final base = await getApplicationSupportDirectory();
    final folder = Directory('${base.path}/Budget');
    final store = BudgetStore(storage: FileStorage(File('${folder.path}/budget.json')));
    final photos = PhotoStore(Directory('${folder.path}/receipts'));
    final model = AppModel(
      store: store,
      photos: photos,
      prefs: FilePrefs(File('${folder.path}/prefs.json')),
      reader: const DeviceReceiptReader(),
      picker: const DevicePhotoPicker(),
      purchases: AppConfig.everyoneHasFullVersion ? FakePurchases() : StorePurchases(),
      everyoneHasPremium: AppConfig.everyoneHasFullVersion,
    );
    if (AppConfig.supabaseUrl.isNotEmpty && AppConfig.supabaseAnonKey.isNotEmpty) {
      final metaFile = File('${folder.path}/sync.json');
      final meta = SyncEngine.decodeMeta(metaFile.existsSync() ? metaFile.readAsStringSync() : null);
      final client = SupabaseClient(
        url: Uri.parse(AppConfig.supabaseUrl),
        anonKey: AppConfig.supabaseAnonKey,
        keeper: await SecureSessionKeeper.open(),
      );
      model.attachSync(
        SyncEngine(
          store: store,
          client: client,
          photos: photos,
          meta: meta,
          saveMeta: (m) {
            try {
              final tmp = File('${metaFile.path}.tmp');
              tmp.writeAsStringSync(jsonEncode(m.toJson()));
              tmp.renameSync(metaFile.path);
            } catch (e) {
              debugPrint('sync meta not saved: $e');
            }
          },
        ),
      );
    }
    return model;
  }

  /// For tests and screenshots: a fresh start in memory, optionally with sample entries.
  static AppModel forTests({
    bool demo = false,
    bool asMilica = false,
    Plan plan = Plan.full,
    ReceiptReader? reader,
    FakePurchases? purchases,
  }) {
    final store = BudgetStore(storage: MemoryStorage());
    if (asMilica) store.setCurrentUser('u_milica');
    if (demo) DemoData.fill(store);
    return AppModel(
      store: store,
      photos: PhotoStore(Directory.systemTemp.createTempSync('budget-test-photos-')),
      prefs: MemoryPrefs(),
      reader: reader ?? const SampleReceiptReader(),
      picker: const SamplePhotoPicker(),
      purchases: purchases ?? FakePurchases(),
      everyoneHasPremium: plan == Plan.full,
    );
  }
}

/// A few entries so screens can be tried out (UI tests and screenshots).
class DemoData {
  DemoData._();
  static void fill(BudgetStore s) {
    final month = DateKey.month();
    String cat(String sp, String name, [EntryKind kind = EntryKind.expense]) =>
        s.categories(sp, kind: kind).firstWhere((c) => c.name == name).id;
    final p = s.personalSpace()!.id, h = s.houseSpace!.id;
    s.updateCategory(cat(p, 'Groceries'), budget: 30000);
    s.updateCategory(cat(p, 'Rent'), budget: 50000);
    s.updateCategory(cat(h, 'Groceries'), budget: 40000);
    s.addTransaction(spaceId: p, categoryId: cat(p, 'Salary', EntryKind.income), kind: EntryKind.income, amount: 200000, date: '$month-01');
    s.addTransaction(spaceId: p, categoryId: cat(p, 'Rent'), kind: EntryKind.expense, amount: 50000, date: '$month-01', note: 'Rent');
    s.addTransaction(
      spaceId: p,
      categoryId: cat(p, 'Groceries'),
      kind: EntryKind.expense,
      amount: 4550,
      date: '$month-01',
      items: const [
        ReceiptItem(name: 'MLEKO ALPSKO 3,5% 1L', price: 119),
        ReceiptItem(name: 'KRUH BELI 500G', price: 149),
      ],
    );
    s.addTransaction(spaceId: h, categoryId: cat(h, 'Groceries'), kind: EntryKind.expense, amount: 2300, date: '$month-01');
  }
}
