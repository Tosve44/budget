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
  int lines = 0, readRight = 0, totalsRight = 0, misread = 0, warned = 0;
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
    if (shot != null && r['week'] == 25) await shot('receipt-week25');
    run.log.add(
      '${r['file']} ${r['store']}: ${got.length}/${want.length} lines read, total ${amount == r['total'] ? 'ok' : 'read as $amount'}'
      '${fixes.isEmpty ? '' : ', fixed by hand: ${fixes.join('; ')}'}',
    );
    await tapKey(tester, 'saveEntry');
  }
  return run;
}

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
  final later = <Map<String, dynamic>>[];
  for (final e in todo) {
    final open = [for (var k = 0; k < got.length; k++) k].where((k) => !done[k]).toList();
    final i =
        open.where((k) => _norm(got[k].$1) == _norm(e['name'] as String)).firstOrNull ??
        open.where((k) => got[k].$2 == e['price']).firstOrNull ??
        open.firstOrNull;
    if (i == null) {
      later.add(e);
      continue;
    }
    done[i] = true;
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

/// Each item's price history must follow the real price of one piece / one kilo. Returns problems.
List<String> checkTrends(PriceRun run) {
  final problems = <String>[];
  final groups = PriceHistory.groups(run.model.store.data.transactions);
  final byName = <String, List<Map<String, dynamic>>>{};
  for (final r in priceReceipts) {
    for (final it in (r['items'] as List).cast<Map<String, dynamic>>()) {
      byName.putIfAbsent(_norm(it['name'] as String), () => []).add(it);
    }
  }
  if (groups.length != byName.length) problems.add('Prices shows ${groups.length} items, want ${byName.length}');
  for (final MapEntry(key: k, value: list) in byName.entries) {
    final g = groups[k];
    if (g == null) {
      problems.add('$k missing');
      continue;
    }
    // A line typed in by hand has no quantity (its line total counts); a corrected price is
    // divided by the quantity (can be a cent off the printed price of one).
    int want(Map<String, dynamic> e) => e['fixedByHand'] == 'added' ? e['price'] as int : e['unitPrice'] as int;
    final tol = list.any((e) => e['fixedByHand'] != null) ? 1 : 0;
    final got = g.entries.map((e) => e.price).toList();
    final exp = list.map(want).toList();
    final bad = got.length != exp.length || [for (var i = 0; i < got.length; i++) (got[i] - exp[i]).abs() > tol].any((b) => b);
    if (bad) problems.add('$k: prices $got, want $exp');
    final kg = list.last['unit'] == 'kg' && list.last['fixedByHand'] != 'added';
    if ((g.latest.unit == 'kg') != kg) problems.add('$k: per kg ${g.latest.unit}, want $kg');
    final first = want(list.first), last = want(list.last);
    final wantPct = list.length > 1 ? Money.percentChange(last, first) : null;
    final gotPct = g.changeSinceFirst;
    if (wantPct == null ? gotPct != null : (gotPct == null || (gotPct - wantPct).abs() > (tol == 0 ? 0 : 0.3))) {
      problems.add('$k: change $gotPct%, want $wantPct%');
    }
  }
  return problems;
}

/// The Prices screen shows the price per kg and the change for a few items.
Future<void> checkPricesScreen(WidgetTester tester, {Future<void> Function(String name)? shot}) async {
  await tapKey(tester, 'tab.prices');
  if (shot != null) await shot('prices');
  for (final (name, price, badge) in [
    ('BANANE', '${Money.format(129)}/kg', '▼ -13.4%'),
    ('JOGURT NAVADNI 180G', Money.format(69), '▲ +16.9%'),
    ('KAVA BARCAFFE 400G', Money.format(703), '▲ +28.1%'),
    ('ALPSKO MLEKO 3,5% 1L', Money.format(119), 'same'),
  ]) {
    final row = find.ancestor(of: find.text(name), matching: find.byKey(const Key('priceRow')));
    await reveal(tester, row);
    expect(
      find.descendant(of: row, matching: find.text(price)),
      findsOneWidget,
      reason: '$name price',
    );
    expect(
      find.descendant(of: row, matching: find.text(badge)),
      findsOneWidget,
      reason: '$name change',
    );
  }
  final banane = find.ancestor(of: find.text('BANANE'), matching: find.byKey(const Key('priceRow')));
  await tester.tap(banane.first);
  await tester.pumpAndSettle();
  expect(find.text('${Money.format(149)}/kg'), findsWidgets, reason: 'first banana price per kg in the history');
  if (shot != null) await shot('prices-banane');
  await tester.pageBack();
  await tester.pumpAndSettle();
}
