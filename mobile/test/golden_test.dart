// The app must give exactly the same answers as the web app, because both work on the same
// shared data. The files in test/fixtures were made by running the web app's own code
// (tool/make-golden.mjs) on thousands of generated inputs.
import 'dart:convert';
import 'dart:io';

import 'package:budget/core/models.dart';
import 'package:budget/core/money.dart';
import 'package:budget/core/prices.dart';
import 'package:budget/core/receipt_parser.dart';
import 'package:budget/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

String fixture(String name) => File('test/fixtures/$name.json').readAsStringSync();
dynamic json(String name) => jsonDecode(fixture(name));

void main() {
  test('receipt parsing matches the web app on thousands of receipts', () {
    final cases = (json('receipts') as List).cast<Map>();
    expect(cases.length, greaterThan(1000));
    final bad = <String>[];
    for (final c in cases) {
      final text = c['text'] as String;
      final want = (c['items'] as List).map((i) => ReceiptItem(name: i['name'] as String, price: i['price'] as int)).toList();
      final got = ReceiptParser.parse(text);
      if (!_listEq(got, want)) bad.add('ITEMS\n$text\nweb: $want\napp: $got');
      final gotTotal = ReceiptParser.findTotal(text);
      if (gotTotal != c['total']) bad.add('TOTAL\n$text\nweb: ${c['total']} app: $gotTotal');
    }
    expect(bad.length, 0, reason: bad.take(5).join('\n-----\n'));
  });

  test('typing money matches the web app', () {
    final bad = <String>[];
    for (final c in (json('money') as List).cast<Map>()) {
      final got = Money.cents(c['input'] as String);
      if (got != c['cents']) bad.add('"${c['input']}": web ${c['cents']} app $got');
    }
    expect(bad, isEmpty);
  });

  test('item name matching matches the web app', () {
    final bad = <String>[];
    for (final c in (json('normalize') as List).cast<Map>()) {
      final got = PriceHistory.normalize(c['input'] as String);
      if (got != c['key']) bad.add('"${c['input']}": web "${c['key']}" app "$got"');
    }
    expect(bad, isEmpty);
  });

  test('opens web app data and writes it back unchanged', () {
    final raw = fixture('webdata');
    final data = BudgetData.decode(raw);
    expect(data.transactions.length, 600);
    expect(jsonDecode(data.encode()), jsonDecode(raw));
    final initial = BudgetData.decode(fixture('webinitial'));
    final mine = BudgetData.initial();
    expect(
      initial.categories.map((c) => '${c.spaceId}/${c.kind.name}/${c.name}').toList(),
      mine.categories.map((c) => '${c.spaceId}/${c.kind.name}/${c.name}').toList(),
    );
    expect(jsonEncode(initial.spaces.map((s) => s.toJson()).toList()), jsonEncode(mine.spaces.map((s) => s.toJson()).toList()));
    expect(jsonEncode(initial.users.map((s) => s.toJson()).toList()), jsonEncode(mine.users.map((s) => s.toJson()).toList()));
    expect(initial.settings.toJson(), mine.settings.toJson());
  });

  test('totals, entry order, price history and comparisons match the web app', () {
    final store = BudgetStore(initial: BudgetData.decode(fixture('webdata')));
    final answers = json('webanswers') as Map;
    for (final s in (answers['summaries'] as List).cast<Map>()) {
      final got = store.monthSummary(s['spaceId'] as String, s['month'] as String);
      final label = '${s['spaceId']} ${s['month']}';
      expect(got.income, s['income'], reason: label);
      expect(got.spent, s['spent'], reason: label);
      expect(got.budget, s['budget'], reason: label);
      expect(got.count, s['count'], reason: label);
      expect(got.byCategory, Map<String, int>.from(s['byCategory'] as Map), reason: label);
    }
    for (final e in (answers['entryOrder'] as List).cast<Map>()) {
      expect(store.transactions(e['spaceId'] as String, month: e['month'] as String?).map((t) => t.id).toList(), e['ids']);
    }
    final history = store.itemHistory();
    final want = (answers['history'] as List).cast<Map>();
    expect(history.length, want.length);
    for (final h in want) {
      final g = history[h['key']];
      expect(g, isNotNull, reason: 'missing ${h['key']}');
      expect(g!.name, h['name']);
      expect(g.entries.map((e) => e.price).toList(), h['prices']);
      expect(g.entries.map((e) => e.txId).toList(), h['txIds']);
    }
    for (final p in (answers['previous'] as List).cast<Map>()) {
      final got = store.previousPrice(p['name'] as String, p['before'] as String, excluding: p['excluding'] as String?);
      final r = p['result'] as Map?;
      expect(got?.date, r?['date']);
      expect(got?.price, r?['price']);
    }
  });
}

bool _listEq(List a, List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
