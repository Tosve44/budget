// The app must give exactly the same answers as the web app, because both work on the same
// shared data. The files in test/fixtures were made by running the web app's own code
// (tool/make-golden.mjs) on thousands of generated inputs.
import 'dart:convert';
import 'dart:io';

import 'package:budget/core/models.dart';
import 'package:budget/core/money.dart';
import 'package:budget/core/prices.dart';
import 'package:budget/core/entry_draft.dart';
import 'package:budget/core/receipt_parser.dart';
import 'package:budget/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

String fixture(String name) => File('test/fixtures/$name.json').readAsStringSync();
dynamic json(String name) => jsonDecode(fixture(name));

void main() {
  test('receipt parsing matches the web app on thousands of receipts', () {
    final cases = (json('receipts') as List).cast<Map>();
    expect(cases.length, greaterThan(5000));
    expect(cases.where((c) => (c['items'] as List).any((i) => (i as Map)['qty'] != null)).length, greaterThan(1000));
    final bad = <String>[];
    for (final c in cases) {
      final text = c['text'] as String;
      final want = (c['items'] as List).map((i) => ReceiptItem.fromJson((i as Map).cast<String, dynamic>())).toList();
      final got = ReceiptParser.parse(text);
      if (!_listEq(got, want)) bad.add('ITEMS\n$text\nweb: $want\napp: $got');
      final gotTotal = ReceiptParser.findTotal(text);
      if (gotTotal != c['total']) bad.add('TOTAL\n$text\nweb: ${c['total']} app: $gotTotal');
      final gotStore = ReceiptParser.findStore(text);
      if (gotStore != c['store']) bad.add('STORE\n$text\nweb: ${c['store']} app: $gotStore');
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

  test('price history per piece / per kilo matches the web app', () {
    final f = json('quantities') as Map;
    final raw = jsonEncode(f['data']);
    final data = BudgetData.decode(raw);
    expect(jsonDecode(data.encode()), jsonDecode(raw), reason: 'quantities are kept unchanged');
    final store = BudgetStore(initial: data);
    final history = store.itemHistory();
    for (final h in (f['history'] as List).cast<Map>()) {
      final g = history[h['key']]!;
      expect(g.entries.map((e) => e.price).toList(), h['prices'], reason: h['key'] as String);
      expect(g.entries.map((e) => e.unit).toList(), h['units'], reason: h['key'] as String);
    }
    for (final p in (f['previous'] as List).cast<Map>()) {
      final got = store.previousPrice(p['name'] as String, p['before'] as String);
      final r = p['result'] as Map?;
      expect(got?.date, r?['date']);
      expect(got?.price, r?['price']);
      expect(got?.unit, r?['unit']);
    }
  });

  test('the date on a receipt matches the web app', () {
    final texts = ((json('dates') as Map)['texts'] as List).cast<Map>();
    expect(texts.length, greaterThan(1000));
    expect(texts.where((t) => t['date'] == null).length, greaterThan(200));
    expect(texts.where((t) => t['date'] != null).length, greaterThan(500));
    final bad = <String>[];
    for (final t in texts) {
      final got = ReceiptParser.findDate(t['text'] as String, today: DateTime.parse(t['today'] as String));
      if (got != t['date']) bad.add('${t['text']}\ntoday ${t['today']} web: ${t['date']} app: $got');
    }
    expect(bad.length, 0, reason: bad.take(5).join('\n-----\n'));
  });

  test('a receipt sets the date, unless it was picked by hand', () {
    const text = 'MERCATOR d.d.\n21.11.2026 14:05\nMLEKO 1,19\nSKUPAJ EUR 1,19';
    final today = DateTime(2026, 11, 28);
    final d = EntryDraft(spaceId: 's', date: '2026-11-28');
    d.applyReceiptText(text, today: today);
    expect((d.date, d.dateFromReceipt), ('2026-11-21', '2026-11-21'));
    final same = EntryDraft(spaceId: 's', date: '2026-11-21')..applyReceiptText(text, today: today);
    expect((same.date, same.dateFromReceipt), ('2026-11-21', null), reason: 'nothing to say when it is the same day');
    final byHand = EntryDraft(spaceId: 's', date: '2026-11-20')..dateTouched = true;
    byHand.applyReceiptText(text, today: today);
    expect((byHand.date, byHand.dateFromReceipt), ('2026-11-20', null));
    final old = EntryDraft(spaceId: 's', date: '2026-11-28')..applyReceiptText(text, today: DateTime(2028, 1, 10));
    expect(old.date, '2026-11-28', reason: 'a date more than a year back is not taken');
  });

  test('the shop on a receipt, and prices at the same shop, match the web app', () {
    final f = json('stores') as Map;
    final texts = (f['texts'] as List).cast<Map>();
    expect(texts.length, greaterThan(500));
    expect(texts.where((t) => t['store'] == null).length, greaterThan(50));
    expect(texts.where((t) => t['store'] == 'Tuš').length, greaterThan(20));
    final bad = <String>[];
    for (final t in texts) {
      final got = ReceiptParser.findStore(t['text'] as String);
      if (got != t['store']) bad.add('${t['text']}\nweb: ${t['store']} app: $got');
    }
    expect(bad.length, 0, reason: bad.take(5).join('\n-----\n'));

    final raw = jsonEncode(f['data']);
    final data = BudgetData.decode(raw);
    expect(jsonDecode(data.encode()), jsonDecode(raw), reason: 'shops are kept unchanged');
    final store = BudgetStore(initial: data);
    final history = store.itemHistory();
    expect(history.length, (f['history'] as List).length);
    for (final h in (f['history'] as List).cast<Map>()) {
      final g = history[h['key']]!;
      final k = h['key'] as String;
      expect(g.entries.map((e) => e.store).toList(), h['stores'], reason: k);
      for (final (tr, want) in [(g.trend(), h['trend'] as Map), (g.trend('spar'), h['spar'] as Map)]) {
        expect(tr.store, want['store'], reason: k);
        expect(tr.entries.map((e) => e.price).toList(), want['prices'], reason: k);
        expect(tr.change, want['change'], reason: k);
      }
    }
    for (final p in (f['previous'] as List).cast<Map>()) {
      final got = store.previousPrice(p['name'] as String, p['before'] as String, store: p['store'] as String?);
      final r = p['result'] as Map?;
      final why = '${p['name']} before ${p['before']} at ${p['store']}';
      expect(got?.date, r?['date'], reason: why);
      expect(got?.price, r?['price'], reason: why);
      expect(got == null ? null : (got.store.isEmpty ? null : got.store), r?['store'], reason: why);
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
