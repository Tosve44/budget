// Syncing tested end to end against a real database with the real privacy rules
// (tool/start-test-backend.sh), or against the real Supabase project. Skipped unless
// SUPABASE_TEST_URL is set:
//
//   SUPABASE_TEST_URL=http://localhost:54321 flutter test test/sync_test.dart
//
// With WEB_APP_DIR and NODE_MODULES_DIR also set, the last test runs the web app's own sync
// code as Milica's phone, to prove this app and the web app share data correctly.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:budget/app_model.dart';
import 'package:budget/core/models.dart';
import 'package:budget/core/money.dart';
import 'package:budget/core/premium.dart';
import 'package:budget/core/store.dart';
import 'package:budget/core/supabase.dart';
import 'package:budget/core/sync.dart';
import 'package:budget/platform/photo_picker.dart';
import 'package:budget/platform/purchases.dart';
import 'package:budget/platform/receipt_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final env = Platform.environment;
final baseUrl = env['SUPABASE_TEST_URL'];
late String anonKey;
final run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
String email(String n) => '$n-flutter-$run@example.test';

class Phone {
  final store = BudgetStore(storage: MemoryStorage());
  late final SupabaseClient client;
  late final PhotoStore photos;
  late final SyncEngine sync;
  Phone({http.Client? transport}) {
    client = SupabaseClient(url: Uri.parse(baseUrl!), anonKey: anonKey, client: transport);
    photos = PhotoStore(Directory.systemTemp.createTempSync('sync-photos-'));
    sync = SyncEngine(store: store, client: client, photos: photos, saveMeta: (_) {});
  }
  Category cat(Space s, String name, [EntryKind kind = EntryKind.expense]) =>
      store.categories(s.id, includeArchived: true).firstWhere((c) => c.name == name && c.kind == kind);
  Space get house => store.houseSpace!;
  Space get personal => store.personalSpace()!;
  Transaction? entry(String id) => store.data.transactions.where((t) => t.id == id).firstOrNull;
}

/// Fails every request after the first [failAfter] ones, like a dropped connection.
class FlakyClient extends http.BaseClient {
  final real = http.Client();
  int? _failAfter;
  int count = 0;
  set failAfter(int? v) {
    _failAfter = v;
    count = 0;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    count++;
    if (_failAfter != null && count > _failAfter!) throw const SocketException('dropped');
    return real.send(request);
  }
}

Future<void> faults(int failNext) async {
  await http.post(Uri.parse('$baseUrl/__test/faults'), body: jsonEncode({'failNext': failNext}));
}

Future<void> pause() => Future.delayed(const Duration(milliseconds: 30));

Future<Object?> expectThrows(Future<Object?> Function() f) async {
  try {
    await f();
  } catch (e) {
    return e;
  }
  fail('expected an error');
}

void main() {
  final skip = baseUrl == null ? 'Set SUPABASE_TEST_URL to run the sync tests against a test server.' : null;

  setUpAll(() async {
    if (baseUrl == null) return;
    anonKey =
        env['SUPABASE_TEST_ANON_KEY'] ?? (jsonDecode((await http.get(Uri.parse('$baseUrl/__test/anon-key'))).body) as Map)['key'] as String;
    await faults(0);
  });

  test(
    'two phones share the House and keep Personal private',
    () async {
      final t = Phone(), m = Phone();

      // Tosve used the app before syncing: his entries are kept and uploaded.
      t.store.addTransaction(
        spaceId: t.personal.id,
        categoryId: t.cat(t.personal, 'Gas').id,
        kind: EntryKind.expense,
        amount: 6000,
        date: '2026-11-10',
      );
      t.store.addTransaction(
        spaceId: t.house.id,
        categoryId: t.cat(t.house, 'Groceries').id,
        kind: EntryKind.expense,
        amount: 4520,
        date: '2026-11-11',
        items: [const ReceiptItem(name: 'Mleko 1L', price: 129)],
      );
      t.store.updateCategory(t.cat(t.house, 'Groceries').id, budget: 40000);
      expect(await t.sync.signUp(email('tosve'), 'secret123'), isTrue);
      final code = await t.sync.createHousehold('Tosve');
      expect(RegExp(r'^[0-9A-F]{8}$').hasMatch(code), isTrue, reason: code);
      expect(t.sync.pendingCount, 0, reason: 'everything uploaded');
      expect(t.store.currentUser.name, 'Tosve');
      expect(t.store.transactions(t.personal.id).length, 1);
      expect(t.store.transactions(t.house.id).length, 1);
      expect(t.store.data.settings.inviteCode, code);
      expect((await t.client.select('transactions')).length, 2);

      // Milica joins with the code; her House entries merge into the shared categories.
      m.store.setCurrentUser('u_milica');
      m.store.addTransaction(
        spaceId: m.personal.id,
        categoryId: m.cat(m.personal, 'Beauty').id,
        kind: EntryKind.expense,
        amount: 2500,
        date: '2026-11-12',
      );
      m.store.addTransaction(
        spaceId: m.house.id,
        categoryId: m.cat(m.house, 'Groceries').id,
        kind: EntryKind.expense,
        amount: 1800,
        date: '2026-11-12',
      );
      await m.sync.signUp(email('milica'), 'secret456');
      final wrong = await expectThrows(() => m.sync.joinHousehold('NOTACODE', 'Milica'));
      expect('$wrong', 'That invite code was not found.');
      await m.sync.joinHousehold(code.toLowerCase(), 'Milica'); // typed in small letters still works
      final groceries = m.store.categories(m.house.id).where((c) => c.name == 'Groceries').toList();
      expect(groceries.length, 1, reason: 'one Groceries category, not two');
      expect(groceries.first.budget, 40000, reason: "Tosve's budget is used");
      expect(m.store.transactions(m.house.id).length, 2, reason: "both people's House entries");
      expect(m.store.transactions(m.house.id).every((x) => x.categoryId == groceries.first.id), isTrue);
      expect(m.store.transactions(m.personal.id).length, 1, reason: 'her personal entry kept');
      expect(m.store.data.users.map((u) => u.name).toList()..sort(), ['Milica', 'Tosve']);

      // Personal stays private.
      await t.sync.syncNow();
      expect(t.store.data.transactions.length, 3);
      expect(t.store.data.transactions.any((x) => x.amount == 2500), isFalse);
      expect(t.store.data.spaces.length, 2, reason: 'his Personal + House only');
      expect((await t.client.select('transactions', filters: [('space_id', 'eq.${m.personal.id}')])).length, 0);
      expect((await t.client.select('categories', filters: [('space_id', 'eq.${m.personal.id}')])).length, 0);

      // A House entry added on one phone shows up on the other, with its author.
      final bled = t.store.addTransaction(
        spaceId: t.house.id,
        categoryId: t.cat(t.house, 'Travel').id,
        kind: EntryKind.expense,
        amount: 12000,
        date: '2026-11-15',
        note: 'Bled weekend',
      );
      await t.sync.syncNow();
      await m.sync.syncNow();
      final got = m.entry(bled.id)!;
      expect(got.note, 'Bled weekend');
      expect(got.createdBy, t.sync.meta.userId);
      expect(m.store.user(got.createdBy)?.name, 'Tosve');

      // Both phones edit the same entry offline: the later edit wins on both.
      t.store.updateTransaction(bled.id, (x) => x.amount = 13000);
      await pause();
      m.store.updateTransaction(bled.id, (x) {
        x.amount = 14000;
        x.note = 'Bled + parking';
      });
      await m.sync.syncNow();
      await t.sync.syncNow();
      await m.sync.syncNow();
      for (final p in [t, m]) {
        expect(p.entry(bled.id)?.amount, 14000);
        expect(p.entry(bled.id)?.note, 'Bled + parking');
      }
      expect(t.sync.pendingCount, 0);
      t.store.updateTransaction(bled.id, (x) => x.amount = 15000);
      await pause();
      m.store.updateTransaction(bled.id, (x) => x.amount = 16000);
      await t.sync.syncNow();
      await m.sync.syncNow();
      await t.sync.syncNow();
      for (final p in [t, m]) {
        expect(p.entry(bled.id)?.amount, 16000);
      }

      // Deleting removes it on the other phone.
      m.store.deleteTransaction(bled.id);
      await m.sync.syncNow();
      await t.sync.syncNow();
      expect(t.entry(bled.id), isNull);
      expect(m.entry(bled.id), isNull);

      // Delete on one phone vs a later edit on the other: the later edit wins.
      final shop = t.store.addTransaction(
        spaceId: t.house.id,
        categoryId: t.cat(t.house, 'Shopping').id,
        kind: EntryKind.expense,
        amount: 999,
        date: '2026-11-16',
      );
      await t.sync.syncNow();
      await m.sync.syncNow();
      t.store.deleteTransaction(shop.id);
      await pause();
      m.store.updateTransaction(shop.id, (x) => x.amount = 1099);
      await t.sync.syncNow();
      await m.sync.syncNow();
      await t.sync.syncNow();
      for (final p in [t, m]) {
        expect(p.entry(shop.id)?.amount, 1099);
      }

      // No connection: changes wait on the phone and go up once the connection is back.
      final plumber = m.store.addTransaction(
        spaceId: m.house.id,
        categoryId: m.cat(m.house, 'Unexpected expenses').id,
        kind: EntryKind.expense,
        amount: 4200,
        date: '2026-11-17',
        note: 'Plumber',
      );
      await faults(50);
      await expectThrows(() => m.sync.syncNow());
      expect(m.sync.state, SyncState.error);
      expect(m.sync.pendingCount, greaterThanOrEqualTo(1));
      expect(m.entry(plumber.id), isNotNull);
      await faults(0);
      await m.sync.syncNow();
      expect(m.sync.pendingCount, 0);
      expect(m.sync.state, SyncState.idle);
      await t.sync.syncNow();
      expect(t.entry(plumber.id), isNotNull);

      // Category changes sync: rename, budget, new category, hide, order.
      final travel = t.cat(t.house, 'Travel').id;
      t.store.updateCategory(travel, name: 'Holidays', budget: 30000);
      final pets = t.store.addCategory(spaceId: t.house.id, name: 'Pets', kind: EntryKind.expense, budget: 5000);
      t.store.updateCategory(t.cat(t.house, 'Savings').id, archived: true);
      final firstTwo = t.store.categories(t.house.id, includeArchived: true, kind: EntryKind.expense).take(2).map((c) => c.id).toList();
      t.store.moveCategory(firstTwo[1], -1);
      await t.sync.syncNow();
      await m.sync.syncNow();
      expect(m.store.category(travel)?.name, 'Holidays');
      expect(m.store.category(travel)?.budget, 30000);
      expect(m.store.category(pets.id)?.name, 'Pets');
      expect(m.cat(m.house, 'Savings').archived, isTrue);
      expect(m.store.categories(m.house.id, includeArchived: true, kind: EntryKind.expense).take(2).map((c) => c.id).toList(), [
        firstTwo[1],
        firstTwo[0],
      ]);

      // A receipt photo taken on one phone can be opened on the other; deleting removes it.
      final bytes = Uint8List.fromList(List.generate(50000, (i) => (i * 31) % 256));
      final photoId = t.photos.save(bytes);
      final receipt = t.store.addTransaction(
        spaceId: t.house.id,
        categoryId: t.cat(t.house, 'Groceries').id,
        kind: EntryKind.expense,
        amount: 839,
        date: '2026-11-19',
        items: [const ReceiptItem(name: 'Kruh', price: 149)],
        receiptId: photoId,
      );
      await t.sync.syncNow();
      await m.sync.syncNow();
      final there = m.entry(receipt.id)!;
      expect(there.receiptId, 'cloud:${there.spaceId}/${receipt.id}.jpg');
      expect(await m.sync.photo(there.receiptId!), bytes);
      expect(m.photos.load(there.receiptId!), bytes, reason: 'kept on her phone after the first download');
      expect(t.entry(receipt.id)?.receiptId, photoId, reason: 'Tosve keeps his own copy');
      t.store.deleteTransaction(receipt.id);
      await t.sync.syncNow();
      await expectThrows(() => m.client.download('receipts', there.receiptId!.substring(6)));
      expect(t.photos.load(photoId), isNull);

      // Milica cannot read or add photos in Tosve's personal folder, or write his entries.
      final privateId = t.photos.save(Uint8List.fromList(List.filled(100, 1)));
      final barber = t.store.addTransaction(
        spaceId: t.personal.id,
        categoryId: t.cat(t.personal, 'Barber').id,
        kind: EntryKind.expense,
        amount: 1500,
        date: '2026-11-19',
        receiptId: privateId,
      );
      await t.sync.syncNow();
      await expectThrows(() => m.client.download('receipts', '${t.personal.id}/${barber.id}.jpg'));
      await expectThrows(() => m.client.upload('receipts', '${t.personal.id}/evil.jpg', Uint8List.fromList([1])));
      final ts = DateKey.timestamp();
      final evil = CloudRows.transactionRow(
        Transaction(
          id: 'tx_evil_$run',
          spaceId: t.personal.id,
          categoryId: t.cat(t.personal, 'Barber').id,
          kind: EntryKind.expense,
          amount: 1,
          date: '2026-11-19',
          createdBy: m.sync.meta.userId!,
          createdAt: ts,
          updatedAt: ts,
        ),
        null,
      );
      await expectThrows(() => m.client.upsert('transactions', [evil]));

      // Many entries: 2,500 sync both ways (more than one page of 1000).
      final groc = t.cat(t.house, 'Groceries').id;
      for (var i = 0; i < 2500; i++) {
        t.store.addTransaction(
          spaceId: t.house.id,
          categoryId: groc,
          kind: EntryKind.expense,
          amount: 1 + i,
          date: '2026-${(1 + i % 11).toString().padLeft(2, '0')}-0${1 + i % 9}',
        );
      }
      final sw = Stopwatch()..start();
      await t.sync.syncNow();
      final up = sw.elapsedMilliseconds;
      sw.reset();
      await m.sync.syncNow();
      // ignore: avoid_print
      print('    2,500 entries: upload $up ms, download ${sw.elapsedMilliseconds} ms');
      expect(m.store.transactions(m.house.id).length, t.store.transactions(t.house.id).length);
      expect(m.store.transactions(m.house.id).length, greaterThan(2500));

      // Signing in on a new phone brings everything back, with no duplicate categories.
      final n = Phone();
      expect(await n.sync.signIn(email('milica'), 'secret456'), ResumeResult.connected);
      expect(n.sync.isConnected, isTrue);
      expect(n.store.currentUser.name, 'Milica');
      expect(n.store.transactions(n.personal.id).map((x) => x.amount).toList(), [2500]);
      expect(n.store.transactions(n.house.id).length, m.store.transactions(m.house.id).length);
      final names = n.store.categories(n.house.id, includeArchived: true).map((c) => c.name).toList();
      expect(names.length, names.toSet().length, reason: 'no duplicate categories');

      // Clear messages for wrong password, existing account, short password.
      final x = Phone();
      expect('${await expectThrows(() => x.sync.signIn(email('tosve'), 'nope-wrong'))}', 'Wrong email or password.');
      expect(
        '${await expectThrows(() => x.sync.signUp(email('tosve'), 'secret123'))}',
        'This email already has an account. Sign in instead.',
      );
      expect(
        '${await expectThrows(() => x.sync.signUp('short-flutter-$run@example.test', '123'))}',
        'Password is too short (at least 6 characters).',
      );

      // Currency and names sync.
      await t.sync.setCurrency('EUR');
      await m.sync.rename('Milica S.');
      await t.sync.syncNow();
      expect(t.store.user(m.sync.meta.userId!)?.name, 'Milica S.');
      await m.sync.rename('Milica');

      // Syncing again with no changes changes nothing.
      await t.sync.syncNow();
      await m.sync.syncNow();
      final before = m.store.data.encode();
      await m.sync.syncNow();
      expect(m.store.data.encode(), before);
      expect(m.sync.pendingCount, 0);

      // Signing out and back in on the same phone: nothing duplicated, authors kept.
      final count = m.store.data.transactions.length;
      final authors = {for (final e in m.store.data.transactions) e.id: e.createdBy};
      await m.sync.signOut();
      expect(m.sync.isConnected, isFalse);
      expect(await m.sync.signIn(email('milica'), 'secret456'), ResumeResult.connected);
      expect(m.store.data.transactions.length, count);
      expect(m.store.data.transactions.map((e) => e.id).toSet().length, count);
      for (final e in m.store.data.transactions) {
        expect(e.createdBy, authors[e.id]);
      }
      expect(m.sync.pendingCount, 0);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'the connection drops halfway through a sync: nothing lost or doubled',
    () async {
      final flaky = FlakyClient();
      final t = Phone(transport: flaky), m = Phone();
      await t.sync.signUp(email('half-t'), 'secret123');
      final code = await t.sync.createHousehold('Tosve');
      await m.sync.signUp(email('half-m'), 'secret456');
      await m.sync.joinHousehold(code, 'Milica');
      for (final cut in [2, 4, 6, 9]) {
        final ids = [
          for (var i = 0; i < 5; i++)
            t.store
                .addTransaction(
                  spaceId: t.house.id,
                  categoryId: t.cat(t.house, 'Groceries').id,
                  kind: EntryKind.expense,
                  amount: 100 + i,
                  date: '2026-11-18',
                )
                .id,
        ];
        flaky.failAfter = cut;
        try {
          await t.sync.syncNow();
        } catch (_) {}
        flaky.failAfter = null;
        await t.sync.syncNow();
        await m.sync.syncNow();
        for (final p in [t, m]) {
          expect(p.store.data.transactions.where((x) => ids.contains(x.id)).length, 5, reason: 'cut after $cut requests');
        }
        expect(t.sync.pendingCount, 0);
      }
      // A refreshed sign-in (the access token ran out) keeps syncing without asking again.
      t.client.now = () => DateTime.now().add(const Duration(hours: 2));
      await t.sync.syncNow();
      expect(t.sync.isConnected, isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'category icons go to the other phone; a database without the icon column still syncs',
    () async {
      // The database has categories.icon (the migration ran), unless ICON_COLUMN=no.
      final hasColumn = env['ICON_COLUMN'] != 'no';
      final t = Phone(), m = Phone();
      await t.sync.signUp(email('icon-t'), 'secret123');
      final code = await t.sync.createHousehold('Tosve');
      await m.sync.signUp(email('icon-m'), 'secret456');
      await m.sync.joinHousehold(code, 'Milica');

      final groceries = t.cat(t.house, 'Groceries');
      t.store.updateCategory(groceries.id, icon: '🥦', budget: 30000);
      final pets = t.store.addCategory(spaceId: t.house.id, name: 'Pets', kind: EntryKind.expense, budget: 2000, icon: '🐶');
      await t.sync.syncNow();
      expect(t.sync.pendingCount, 0, reason: 'nothing stuck because of the icon');
      expect(t.sync.noIconColumn, !hasColumn);
      await m.sync.syncNow();

      // The rest of the category always arrives; this phone keeps the icon it picked.
      expect(m.cat(m.house, 'Groceries').budget, 30000);
      expect(m.cat(m.house, 'Pets').budget, 2000);
      expect(t.store.category(groceries.id)!.icon, '🥦');
      expect(t.store.category(pets.id)!.icon, '🐶');
      if (hasColumn) {
        expect(m.cat(m.house, 'Groceries').icon, '🥦');
        expect(m.cat(m.house, 'Pets').icon, '🐶');
        // Back to the default icon, on both phones.
        m.store.updateCategory(m.cat(m.house, 'Pets').id, icon: '');
        await m.sync.syncNow();
        await t.sync.syncNow();
        expect(t.store.category(pets.id)!.icon, '');
      } else {
        expect(m.cat(m.house, 'Groceries').icon, '', reason: 'shown with the default icon');
        // A later sync, after another change, still does not lose the icon here.
        t.store.updateCategory(pets.id, budget: 2500);
        await t.sync.syncNow();
        await m.sync.syncNow();
        expect(m.cat(m.house, 'Pets').budget, 2500);
        expect(t.store.category(pets.id)!.icon, '🐶');
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'Premium paid on one phone covers the household; it cannot be set by hand, and it runs out',
    () async {
      final t = Phone(), m = Phone();
      await t.sync.signUp(email('prem-t'), 'secret123');
      final code = await t.sync.createHousehold('Tosve');
      await m.sync.signUp(email('prem-m'), 'secret456');
      await m.sync.joinHousehold(code, 'Milica');
      expect(t.sync.householdPremiumUntil, isNull, reason: 'a new household has no Premium');

      final paid = FakePurchases(owned: true);
      final tosve = AppModel(
        store: t.store,
        photos: t.photos,
        prefs: MemoryPrefs(),
        reader: const SampleReceiptReader(),
        picker: const SamplePhotoPicker(),
        purchases: paid,
        everyoneHasPremium: false,
      )..sync = t.sync;
      final milica = AppModel(
        store: m.store,
        photos: m.photos,
        prefs: MemoryPrefs(),
        reader: const SampleReceiptReader(),
        picker: const SamplePhotoPicker(),
        purchases: FakePurchases(),
        everyoneHasPremium: false,
      )..sync = m.sync;
      expect(milica.plan, Plan.free);

      // Tosve's store account has Premium: the household gets it for 35 days, Milica too.
      await tosve.refreshPremium();
      expect(tosve.plan, Plan.full);
      final until = t.sync.householdPremiumUntil!;
      expect(until.difference(DateTime.now()).inDays, inInclusiveRange(34, 35));
      await m.sync.syncNow();
      expect(m.sync.householdPremiumUntil, until);
      await milica.refreshPremium();
      expect(milica.plan, Plan.full, reason: 'the partner pays');
      // Milica's phone does not pay, so it never extends it.
      expect(milica.prefs.get('premiumSharedOn'), isNull);

      // Nobody can give themselves Premium by writing the column.
      final denied = await expectThrows(() => m.client.update('households', {'premium_until': 'infinity'}, 'id', m.sync.meta.householdId!));
      expect(denied, isA<SupabaseError>());
      await m.sync.syncNow();
      expect(m.sync.householdPremiumUntil, until, reason: 'unchanged');

      // Later: the subscription ended. When the 35 days are over, both are back on the free version.
      paid.owned = false;
      await tosve.refreshPremium();
      expect(tosve.premiumFromStore, isFalse);
      final later = until.add(const Duration(minutes: 1));
      final tosveLater = AppModel(
        store: t.store,
        photos: t.photos,
        prefs: MemoryPrefs(),
        reader: const SampleReceiptReader(),
        picker: const SamplePhotoPicker(),
        purchases: paid,
        everyoneHasPremium: false,
        now: () => later,
      )..sync = t.sync;
      expect(tosveLater.plan, Plan.free);

      // A household that is not signed in cannot extend anything.
      final stranger = Phone();
      await stranger.sync.signUp(email('prem-x'), 'secret789');
      expect(await expectThrows(() => stranger.client.rpc('extend_household_premium', {})), isA<SupabaseError>());

      // The testers' free unlock, given in the SQL editor (here: straight in the test database).
      final sql = "update public.households set premium_until = 'infinity' where id = '${t.sync.meta.householdId}'";
      final r = await Process.run('psql', ['-h', '/tmp', '-p', '54329', '-U', 'postgres', '-d', 'budget_test', '-c', sql]);
      if (r.exitCode != 0) {
        markTestSkipped('psql not available for the tester unlock: ${r.stderr}');
        return;
      }
      await m.sync.syncNow();
      expect(m.sync.householdPremiumUntil!.year, 9999);
      expect(milica.plan, Plan.full);
      expect(milica.premium.describe(DateTime.now()), 'Your household has Premium for free.');
      // A paying phone extending it later keeps the free unlock forever.
      paid.owned = true;
      tosve.prefs.set('premiumSharedOn', null);
      await tosve.refreshPremium();
      expect(t.sync.householdPremiumUntil!.year, 9999);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'this app and the web app share the same data',
    () async {
      final webDir = env['WEB_APP_DIR'], modules = env['NODE_MODULES_DIR'];
      if (webDir == null || modules == null) {
        markTestSkipped('Set WEB_APP_DIR and NODE_MODULES_DIR to test against the web app.');
        return;
      }
      final web = WebPhone(webDir, modules, env['WEBPHONE_SCRIPT'] ?? 'tool/webphone.mjs');
      final t = Phone();

      // This app starts the household; the web app joins with the code.
      t.store.addTransaction(
        spaceId: t.house.id,
        categoryId: t.cat(t.house, 'Groceries').id,
        kind: EntryKind.expense,
        amount: 4520,
        date: '2026-11-11',
        items: [const ReceiptItem(name: 'Čokolada Milka 100g', price: 159)],
      );
      await t.sync.signUp(email('mix-t'), 'secret123');
      final code = await t.sync.createHousehold('Tosve');
      await web.run('signup', {'email': email('mix-m'), 'password': 'secret456'});
      await web.run('join', {'code': code, 'name': 'Milica'});
      var w = await web.run('dump');
      expect(w.house.length, 1);
      expect(w.house.first['amount'], 4520);
      expect((w.house.first['items'] as List).first['name'], 'Čokolada Milka 100g');

      // The web app adds an entry and renames a category; this app sees both.
      final webEntry =
          (await web.run('add', {
                'space': 'house',
                'category': 'Travel',
                'amount': 12000,
                'date': '2026-11-15',
                'note': 'Bled',
                'items': [
                  {'name': 'Parking', 'price': 500},
                ],
              })).raw['id']
              as String;
      await web.run('rename-category', {'space': 'house', 'from': 'Shopping', 'to': 'Home stuff', 'budget': 7000});
      await web.run('sync');
      await t.sync.syncNow();
      expect(t.entry(webEntry)?.note, 'Bled');
      expect(t.entry(webEntry)?.items, [const ReceiptItem(name: 'Parking', price: 500)]);
      expect(t.store.user(t.entry(webEntry)!.createdBy)?.name, 'Milica');
      expect(t.store.categories(t.house.id).firstWhere((c) => c.name == 'Home stuff').budget, 7000);
      expect(t.store.categories(t.house.id).where((c) => c.name == 'Shopping'), isEmpty);

      // Conflict: the web edit is later, so it wins on both.
      t.store.updateTransaction(webEntry, (x) => x.amount = 13000);
      await pause();
      await web.run('update', {
        'id': webEntry,
        'patch': {'amount': 14000},
      });
      await t.sync.syncNow();
      await web.run('sync');
      await t.sync.syncNow();
      w = await web.run('dump');
      expect(t.entry(webEntry)?.amount, 14000);
      expect(w.house.firstWhere((e) => e['id'] == webEntry)['amount'], 14000);

      // This app deletes it; it disappears in the web app.
      t.store.deleteTransaction(webEntry);
      await t.sync.syncNow();
      w = await web.run('sync');
      expect(w.house.where((e) => e['id'] == webEntry), isEmpty);

      // Photos both ways.
      final jpeg = Uint8List.fromList(List.generate(20000, (i) => (i * 7) % 251));
      final rid = t.photos.save(jpeg);
      final withPhoto = t.store.addTransaction(
        spaceId: t.house.id,
        categoryId: t.cat(t.house, 'Groceries').id,
        kind: EntryKind.expense,
        amount: 839,
        date: '2026-11-19',
        receiptId: rid,
      );
      await t.sync.syncNow();
      w = await web.run('sync');
      final path = (w.house.firstWhere((e) => e['id'] == withPhoto.id)['receiptId'] as String).substring(6);
      expect(path, '${t.house.id}/${withPhoto.id}.jpg');
      expect(base64Decode((await web.run('download', {'path': path})).raw['base64'] as String), jpeg);
      final webJpeg = Uint8List.fromList(List.generate(9000, (i) => (i * 13) % 256));
      final webPhotoEntry =
          (await web.run('add-photo-entry', {
                'space': 'house',
                'category': 'Groceries',
                'amount': 455,
                'date': '2026-11-20',
                'photoBase64': base64Encode(webJpeg),
              })).raw['id']
              as String;
      await web.run('sync');
      await t.sync.syncNow();
      expect(await t.sync.photo(t.entry(webPhotoEntry)!.receiptId!), webJpeg);

      // Both now hold exactly the same House data.
      w = await web.run('sync');
      await t.sync.syncNow();
      final appHouse =
          t.store.transactions(t.house.id).map((e) => '${e.id} ${e.amount} ${e.date} ${e.categoryId} ${e.note} ${e.createdBy}').toList()
            ..sort();
      final webHouse =
          w.house.map((e) => '${e['id']} ${e['amount']} ${e['date']} ${e['categoryId']} ${e['note']} ${e['createdBy']}').toList()..sort();
      expect(appHouse, webHouse);
      final appCats = t.store
          .categories(t.house.id, includeArchived: true)
          .map((c) => '${c.id} ${c.name} ${c.budget} ${c.order} ${c.archived}')
          .toList();
      final webCats = w.houseCategories
          .map((c) => '${c['id']} ${c['name']} ${c['budget']} ${c['order']} ${c['archived'] ?? false}')
          .toList();
      expect(appCats, webCats);
      expect(w.raw['pending'], 0);
      expect(t.sync.pendingCount, 0);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class WebResult {
  final Map<String, dynamic> raw;
  WebResult(this.raw);
  Map get data => (raw['data'] as Map?) ?? {};
  String? get houseId => ((data['spaces'] as List?) ?? []).cast<Map>().where((s) => s['type'] == 'house').firstOrNull?['id'] as String?;
  List<Map> get house => ((data['transactions'] as List?) ?? []).cast<Map>().where((t) => t['spaceId'] == houseId).toList();
  List<Map> get houseCategories =>
      ((data['categories'] as List?) ?? []).cast<Map>().where((c) => c['spaceId'] == houseId).toList()
        ..sort((a, b) => (a['order'] as int).compareTo(b['order'] as int));
}

/// Runs tool/webphone.mjs: a phone using the web app's own code.
class WebPhone {
  final String webDir, modules, script;
  final state = '${Directory.systemTemp.path}/webphone-${DateTime.now().microsecondsSinceEpoch}.json';
  WebPhone(this.webDir, this.modules, this.script);

  Future<WebResult> run(String command, [Map<String, dynamic> args = const {}]) async {
    final r = await Process.run(
      'node',
      [script, webDir, state, command, jsonEncode(args)],
      environment: {'SUPABASE_URL': baseUrl!, 'SUPABASE_ANON_KEY': anonKey, 'NODE_MODULES_DIR': modules},
    );
    final lines = (r.stdout as String).trim().split('\n');
    final Map<String, dynamic> obj;
    try {
      obj = jsonDecode(lines.last) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('no output from web phone for $command: ${r.stderr}');
    }
    if (obj['ok'] != true) throw Exception('web phone $command: ${obj['error']}');
    return WebResult(obj);
  }
}
