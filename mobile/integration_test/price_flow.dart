// Six months of weekly grocery receipts (one Saturday shop, 2026-05-30 .. 2026-11-21, at
// Mercator, Lidl, Hofer, Spar and Tuš; 20 items whose prices rise, stay or drop), scanned one by
// one like a person does it, then the Prices screen must show each item's real price trend:
// the price of one piece or one kilo, not the line total. Made by tests/price-history/make-receipts.py.
//  - test/price_history_test.dart: on the computer, with the receipts' text (a perfect reader)
//  - integration_test/app_test.dart: on emulators/simulators, with the photos and the phone's
//    own text reader; misread lines are corrected by typing, as a person would.
import 'dart:convert';

import 'package:budget/app_model.dart';
import 'package:budget/core/money.dart';
import 'package:budget/core/prices.dart';
import 'package:budget/platform/receipt_reader.dart';
import 'package:budget/ui/widgets.dart' show Muted, pct;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'flows.dart';
import 'price_receipts.dart';

final priceData = jsonDecode(priceReceiptsJson) as Map<String, dynamic>;
List<Map<String, dynamic>> get priceReceipts => (priceData['receipts'] as List).cast<Map<String, dynamic>>();

/// Gives the receipts one after another, whatever photo the app passes.
class QueueReader implements ReceiptReader {
  final Future<String> Function(Map<String, dynamic> receipt) readOne;
  var next = 0;
  QueueReader(this.readOne);
  @override
  Future<String> read(String imagePath) => readOne(priceReceipts[next++]);
}

String _norm(String s) => PriceHistory.normalize(s);
String _input(int cents) => Money.inputText(cents, emptyForZero: false);

class PriceRun {
  final AppModel model;
  final List<String> log = [];
  int lines = 0, readRight = 0, totalsRight = 0, misread = 0, warned = 0, skipped = 0, shopsRight = 0;
  PriceRun(this.model);
}

/// Scans all receipts through the add-entry screen, fixes what was misread, saves each one.
Future<PriceRun> scanSixMonths(WidgetTester tester, QueueReader reader, {Future<void> Function(String name)? shot}) async {
  final model = await pumpApp(tester, reader: reader);
  final run = PriceRun(model);
  for (final r in priceReceipts) {
    await tapKey(tester, 'addEntry');
    await setDate(tester, r['date'] as String);
    await scanReceipt(tester, find.byKey(const Key('readNote')));
    final note = tester.widget<Text>(find.descendant(of: find.byKey(const Key('readNote')), matching: find.byType(Text)).first).data ?? '';
    final want = (r['items'] as List).cast<Map<String, dynamic>>();
    final got = <(String, int?)>[];
    // The screen builds only what is on it, so each line is scrolled to first.
    final found = int.tryParse(RegExp(r'Found (\d+) item').firstMatch(note)?[1] ?? '') ?? 0;
    for (var i = 0; i < found; i++) {
      await reveal(tester, find.byKey(Key('itemName.$i')));
      got.add((_field(tester, 'itemName.$i'), Money.cents(_field(tester, 'itemPrice.$i'))));
    }
    run.lines += want.length;
    final fixes = await _correct(tester, want, got);
    run.readRight += want.length - fixes.where((f) => !f.startsWith('removed')).length;
    await reveal(tester, find.byKey(const Key('amountField')));
    final amount = Money.cents(_field(tester, 'amountField'));
    if (amount == r['total']) {
      run.totalsRight++;
    } else {
      await typeInto(tester, 'amountField', _input(r['total'] as int));
    }
    if (fixes.any((f) => f.startsWith('price'))) {
      run.misread++;
      if (note.contains('add up')) run.warned++;
    }
    // The shop, read from the receipt's header; a person picks the right one if it is wrong.
    final shop = shopName(r['store'] as String);
    await reveal(tester, find.byKey(const Key('shopField')));
    final readShop = _field(tester, 'shopField');
    if (readShop == shop) {
      run.shopsRight++;
    } else {
      await typeInto(tester, 'shopField', shop);
    }
    if (shot != null && r['week'] == 25) await shot('receipt-week25');
    run.log.add(
      '${r['file']} ${r['store']}: ${got.length}/${want.length} lines read, total ${amount == r['total'] ? 'ok' : 'read as $amount'}'
      '${readShop == shop ? '' : ', shop read as "$readShop"'}'
      '${fixes.isEmpty ? '' : ', fixed by hand: ${fixes.join('; ')}'}',
    );
    await tapKey(tester, 'saveEntry');
  }
  return run;
}

/// The shop as the app names it (the receipts' file says "Tus").
String shopName(String store) => store == 'Tus' ? 'Tuš' : store;

String _field(WidgetTester tester, String key) => tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

/// Picks a day in the date picker by typing it (the pencil button), like a person can.
Future<void> setDate(WidgetTester tester, String day) async {
  await tapKey(tester, 'dateField');
  final edit = find.byIcon(Icons.edit_outlined).evaluate().isNotEmpty ? find.byIcon(Icons.edit_outlined) : find.byIcon(Icons.edit);
  await tester.tap(edit.first);
  await tester.pumpAndSettle();
  final ctx = tester.element(find.byType(Dialog).first);
  final text = MaterialLocalizations.of(ctx).formatCompactDate(DateTime.parse(day));
  await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)).first, text);
  await tester.pumpAndSettle();
  await tester.tap(find.text(MaterialLocalizations.of(ctx).okButtonLabel).last);
  await tester.pumpAndSettle();
}

/// What a person does after "Check them": fix misread names and prices, remove lines that are
/// not items, type in lines the reader missed. Returns what was changed.
Future<List<String>> _correct(WidgetTester tester, List<Map<String, dynamic>> want, List<(String, int?)> got) async {
  final fixes = <String>[];
  final done = List.filled(got.length, false);
  final todo = <Map<String, dynamic>>[];
  for (final e in want) {
    final i = [for (var k = 0; k < got.length; k++) k]
        .where((k) => !done[k] && _norm(got[k].$1) == _norm(e['name'] as String) && got[k].$2 == e['price'])
        .firstOrNull;
    if (i != null) {
      done[i] = true;
    } else {
      todo.add(e);
    }
  }
  // A person first finds the line by its name, then by its price, and only then takes a line
  // that is left over.
  final pick = <Map<String, dynamic>, int>{};
  final tests = <bool Function(int k, Map<String, dynamic> e)>[
    (k, e) => _norm(got[k].$1) == _norm(e['name'] as String),
    (k, e) => got[k].$2 == e['price'],
    (k, e) => true,
  ];
  for (final test in tests) {
    for (final e in todo) {
      if (pick.containsKey(e)) continue;
      final i = [for (var k = 0; k < got.length; k++) k].where((k) => !done[k] && test(k, e)).firstOrNull;
      if (i != null) {
        done[i] = true;
        pick[e] = i;
      }
    }
  }
  final later = <Map<String, dynamic>>[];
  for (final e in todo) {
    final i = pick[e];
    if (i == null) {
      later.add(e);
      continue;
    }
    if (_norm(got[i].$1) != _norm(e['name'] as String)) await typeInto(tester, 'itemName.$i', e['name'] as String);
    if (got[i].$2 != e['price']) {
      await typeInto(tester, 'itemPrice.$i', _input(e['price'] as int));
      e['fixedByHand'] = 'price';
      fixes.add('price "${got[i].$1}" ${got[i].$2} → "${e['name']}" ${e['price']}');
    } else {
      e['fixedByHand'] = 'name';
      fixes.add('name "${got[i].$1}" → "${e['name']}"');
    }
  }
  for (var k = got.length - 1; k >= 0; k--) {
    if (done[k]) continue;
    await tapKey(tester, 'removeItem.$k');
    fixes.add('removed "${got[k].$1}" ${got[k].$2}');
  }
  for (final e in later) {
    await tapKey(tester, 'addItem');
    var i = 0;
    while (find.byKey(Key('itemName.${i + 1}')).evaluate().isNotEmpty) {
      i++;
    }
    await typeInto(tester, 'itemName.$i', e['name'] as String);
    await typeInto(tester, 'itemPrice.$i', _input(e['price'] as int));
    e['fixedByHand'] = 'added';
    fixes.add('added "${e['name']}" ${e['price']}');
  }
  return fixes;
}

/// Every price on the Prices screen must be the real price of one piece / one kilo on that day.
/// A line whose quantity doesn't add up to its price (something misread that the person can't
/// see), or a weighed item whose weight wasn't read, is left out rather than shown wrong; those
/// are counted in [PriceRun.skipped]. Returns problems.
List<String> checkTrends(PriceRun run) {
  final problems = <String>[];
  final groups = PriceHistory.groups(run.model.store.data.transactions);
  final byName = <String, Map<String, Map<String, dynamic>>>{}; // item -> date -> line
  for (final r in priceReceipts) {
    for (final it in (r['items'] as List).cast<Map<String, dynamic>>()) {
      byName.putIfAbsent(_norm(it['name'] as String), () => {})[r['date'] as String] = {...it, 'store': shopName(r['store'] as String)};
    }
  }
  if (groups.length != byName.length) problems.add('Prices shows ${groups.length} items, want ${byName.length}');
  run.skipped = 0;
  for (final MapEntry(key: k, value: byDate) in byName.entries) {
    final g = groups[k];
    if (g == null) {
      problems.add('$k missing');
      continue;
    }
    // A line typed in by hand has no quantity, so its line total counts.
    for (final p in g.entries) {
      final e = byDate[p.date];
      if (e == null) {
        problems.add('$k: a price on ${p.date}, but it was not bought that day');
        continue;
      }
      final want = e['fixedByHand'] == 'added' ? e['price'] as int : e['unitPrice'] as int;
      final tol = e['fixedByHand'] != null ? 1 : 0;
      if ((p.price - want).abs() > tol) {
        problems.add('$k on ${p.date}: shows ${p.price}, real ${e['unitPrice']} (${e['fixedByHand'] ?? 'read right'})');
      }
      if (p.store != e['store']) problems.add('$k on ${p.date}: at ${p.store}, want ${e['store']}');
      final kg = e['unit'] == 'kg' && e['fixedByHand'] != 'added';
      if ((p.unit == 'kg') != kg) problems.add('$k on ${p.date}: per kg ${p.unit == 'kg'}, want $kg');
    }
    run.skipped += byDate.length - g.entries.length;
  }
  return problems;
}

/// The Prices screen shows each item's newest price (per kg where sold by weight) and the change
/// since the first purchase at the same shop, as worked out from the history checked above. The
/// Lidl chip shows only what was bought at Lidl.
Future<void> checkPricesScreen(WidgetTester tester, AppModel model, {Future<void> Function(String name)? shot}) async {
  await tapKey(tester, 'tab.prices');
  if (shot != null) await shot('prices');
  final groups = PriceHistory.groups(model.store.data.transactions);
  for (final key in ['banane', 'jogurt navadni 180g', 'kava barcaffe 400g', 'alpsko mleko 3 5% 1l', 'paradiznik']) {
    final g = groups[key]!;
    final tr = g.trend();
    final price = '${Money.format(tr.last!.price)}${tr.last!.unit == 'kg' ? '/kg' : ''}';
    final p = tr.change;
    final badge = p == null ? 'new' : (p == 0 ? 'same' : (p > 0 ? '▲ +${pct(p)}%' : '▼ ${pct(p)}%'));
    final row = find.ancestor(of: find.text(g.name), matching: find.byKey(const Key('priceRow')));
    await reveal(tester, row);
    expect(
      find.descendant(of: row, matching: find.text(price)),
      findsOneWidget,
      reason: '${g.name} price',
    );
    expect(
      find.descendant(of: row, matching: find.text(badge)),
      findsOneWidget,
      reason: '${g.name} change',
    );
    final meta = tester.widget<Muted>(find.descendant(of: row, matching: find.byKey(const Key('priceMeta')))).text;
    expect(meta, startsWith('${tr.store} · ${tr.entries.length}×'), reason: '${g.name} shop');
  }
  // Only Lidl.
  await reveal(tester, find.byKey(const Key('shop.Lidl')));
  await tapKey(tester, 'shop.Lidl');
  final atLidl = groups.values.where((g) => g.entries.any((e) => e.store == 'Lidl')).toList();
  expect(atLidl, isNotEmpty);
  for (final g in groups.values) {
    final shown = find.ancestor(of: find.text(g.name), matching: find.byKey(const Key('priceRow')));
    if (!atLidl.contains(g)) {
      expect(shown, findsNothing, reason: '${g.name} was never bought at Lidl');
    }
  }
  for (final g in atLidl.take(3)) {
    final row = find.ancestor(of: find.text(g.name), matching: find.byKey(const Key('priceRow')));
    await reveal(tester, row);
    final meta = tester.widget<Muted>(find.descendant(of: row, matching: find.byKey(const Key('priceMeta')))).text;
    expect(meta, startsWith('Lidl · '), reason: g.name);
  }
  if (shot != null) await shot('prices-lidl');
  await reveal(tester, find.byKey(const Key('shop.')));
  await tapKey(tester, 'shop.');
  final banane = groups['banane']!;
  final bananaRow = find.ancestor(of: find.text(banane.name), matching: find.byKey(const Key('priceRow'))).first;
  await reveal(tester, bananaRow);
  await tester.tap(bananaRow);
  await tester.pumpAndSettle();
  expect(find.text('${Money.format(banane.entries.first.price)}/kg'), findsWidgets, reason: 'first banana price per kg in the history');
  expect(find.textContaining(' · ${banane.entries.first.store}'), findsWidgets, reason: 'the shop of each purchase');
  if (shot != null) await shot('prices-banane');
  await tester.pageBack();
  await tester.pumpAndSettle();
}
