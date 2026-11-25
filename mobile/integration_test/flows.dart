// Screen tests that tap through the app like a person. The same tests run in two places:
//  - test/screens_test.dart: on the computer (fast, many screen sizes and text sizes)
//  - integration_test/app_test.dart: on real Android emulators and iPhone simulators (CI)
import 'package:budget/app_model.dart';
import 'package:budget/core/models.dart';
import 'package:budget/core/money.dart';
import 'package:budget/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<AppModel> pumpApp(WidgetTester tester, {bool demo = false, bool asMilica = false}) async {
  final model = AppModel.forTests(demo: demo, asMilica: asMilica);
  await tester.pumpWidget(BudgetApp(model: model));
  await tester.pumpAndSettle();
  return model;
}

String eur(int cents) => Money.format(cents);

/// Scrolls the screen until [f] is built (long lists build only what is on screen).
Future<void> reveal(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    // Start from the top, then scroll down until it shows up.
    final list = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(list).position;
    if (position.pixels != 0) position.jumpTo(0);
    await tester.pumpAndSettle();
  }
  for (var i = 0; i < 80 && f.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -150));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(f.first);
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  // On a real phone the keyboard can open or close meanwhile and move things around, so the
  // widget is looked up again right before the tap.
  for (var attempt = 0; ; attempt++) {
    await reveal(tester, f);
    await tester.pumpAndSettle();
    if (f.evaluate().isNotEmpty || attempt == 2) break;
  }
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

Future<void> typeInto(WidgetTester tester, String key, String text) async {
  final f = find.byKey(Key(key));
  await reveal(tester, f);
  await tester.enterText(f.first, text);
  await tester.pumpAndSettle();
  await reveal(tester, f);
  final typed = tester.widget<TextField>(find.descendant(of: f.first, matching: find.byType(TextField), matchRoot: true).first).controller?.text;
  expect(typed, text, reason: 'typing into $key');
}

Future<void> tapText(WidgetTester tester, String text) async {
  final f = find.text(text);
  await reveal(tester, f);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

Future<void> pickChip(WidgetTester tester, String name) => tapKey(tester, 'chip.$name');

String statText(WidgetTester tester, String label) {
  final t = tester.widget<Text>(find.byKey(Key('stat.$label')).first);
  return t.data!;
}

/// Every flow, with a short name. Each one starts the app fresh.
final flows = <String, Future<void> Function(WidgetTester)>{
  'tap Income opens the add form for income, and saving shows it': (tester) async {
    final model = await pumpApp(tester);
    await tapKey(tester, 'addIncome');
    expect(find.textContaining('New income'), findsOneWidget);
    await typeInto(tester, 'amountField', '2000');
    await pickChip(tester, 'Salary');
    await tapKey(tester, 'saveEntry');
    expect(find.textContaining('New income'), findsNothing);
    expect(statText(tester, 'Income'), eur(200000));
    expect(tester.widget<Text>(find.byKey(const Key('stat.Balance'))).data, '+${eur(200000)}');
    expect(model.store.data.transactions.single.kind, EntryKind.income);
  },
  'tap Spent opens the add form for an expense; 5 spent shows as −5': (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'addExpense');
    expect(find.textContaining('New expense'), findsOneWidget);
    await typeInto(tester, 'amountField', '5');
    await pickChip(tester, 'Groceries');
    await tapKey(tester, 'saveEntry');
    expect(statText(tester, 'Spent'), eur(500));
    expect(find.text('−${eur(500)}'), findsWidgets);
    expect(tester.widget<Text>(find.byKey(const Key('stat.Balance'))).data, '−${eur(500)}');
  },
  '"1.000" is one thousand euros, "12,50" is twelve fifty': (tester) async {
    final model = await pumpApp(tester);
    await tapKey(tester, 'addEntry');
    await typeInto(tester, 'amountField', '1.000');
    await pickChip(tester, 'Rent');
    await tapKey(tester, 'saveEntry');
    await tapKey(tester, 'addEntry');
    await typeInto(tester, 'amountField', '12,50');
    await pickChip(tester, 'Gas');
    await tapKey(tester, 'saveEntry');
    expect(model.store.data.transactions.map((t) => t.amount).toList()..sort(), [1250, 100000]);
  },
  'wrong input is explained and nothing is saved': (tester) async {
    final model = await pumpApp(tester);
    await tapKey(tester, 'addEntry');
    await tapKey(tester, 'saveEntry');
    expect(find.text('Enter an amount bigger than 0.'), findsOneWidget);
    await typeInto(tester, 'amountField', 'abc');
    await tapKey(tester, 'saveEntry2');
    expect(find.text('Enter an amount bigger than 0.'), findsOneWidget);
    await typeInto(tester, 'amountField', '12');
    await tapKey(tester, 'saveEntry2');
    expect(find.text('Pick a category.'), findsOneWidget);
    await typeInto(tester, 'amountField', '99999999');
    await pickChip(tester, 'Car');
    await tapKey(tester, 'saveEntry2');
    expect(find.text('That amount is too big.'), findsOneWidget);
    expect(model.store.data.transactions, isEmpty);
  },
  'a receipt photo fills in the items and the total, and Prices shows them': (tester) async {
    final model = await pumpApp(tester);
    await tapKey(tester, 'addEntry');
    await tapKey(tester, 'scanReceipt');
    expect(find.byKey(const Key('readNote')), findsOneWidget);
    expect(find.textContaining('Found 2 items'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('amountField')));
    expect(tester.widget<TextField>(find.byKey(const Key('amountField'))).controller!.text, '2,78');
    await tapKey(tester, 'saveEntry');
    final t = model.store.data.transactions.single;
    expect(t.amount, 278);
    expect(model.store.category(t.categoryId)!.name, 'Groceries');
    expect(t.items!.map((i) => i.name).toList(), ['MLEKO ALPSKO 3,5% 1L', 'KRUH BELI 500G']);
    expect(t.receiptId, isNotNull);
    await tapKey(tester, 'tab.prices');
    expect(find.text('MLEKO ALPSKO 3,5% 1L'), findsOneWidget);
    expect(find.text('KRUH BELI 500G'), findsOneWidget);
    // The second time, each item is compared with the first.
    await tapKey(tester, 'tab.personal');
    await tapKey(tester, 'addEntry');
    await tapKey(tester, 'scanReceipt');
    await typeInto(tester, 'itemPrice.0', '1,39');
    expect(find.textContaining('▲ +7.8%'), findsOneWidget);
    expect(find.textContaining('Same as'), findsOneWidget);
  },
  'edit and delete an entry': (tester) async {
    final model = await pumpApp(tester, demo: true);
    final before = model.store.data.transactions.length;
    await tapKey(tester, 'entry');
    expect(find.text('Edit entry'), findsOneWidget);
    await typeInto(tester, 'noteField', 'changed note');
    await tapKey(tester, 'saveEntry');
    expect(
      model.store.data.transactions.where((t) => t.note == 'changed note').length,
      1,
      reason:
          'still editing: ${find.text('Edit entry').evaluate().isNotEmpty}, '
          'problem: ${find.byKey(const Key('formProblem')).evaluate().map((e) => (e.widget as Text).data).join()}, '
          'notes: ${model.store.data.transactions.map((t) => t.note).toList()}',
    );
    await tapKey(tester, 'entry');
    await tapKey(tester, 'deleteEntry');
    await tapKey(tester, 'confirmYes');
    expect(model.store.data.transactions.length, before - 1);
  },
  'tapping a category shows only its entries': (tester) async {
    await pumpApp(tester, demo: true);
    await reveal(tester, find.byKey(const Key('entry')));
    expect(find.byKey(const Key('entry')), findsNWidgets(3));
    await tapKey(tester, 'category.Rent');
    await reveal(tester, find.byKey(const Key('entry')));
    expect(find.byKey(const Key('entry')), findsOneWidget);
    await reveal(tester, find.byKey(const Key('clearFilter')));
    await tapKey(tester, 'clearFilter');
    await reveal(tester, find.byKey(const Key('entry')));
    expect(find.byKey(const Key('entry')), findsNWidgets(3));
  },
  'months switch, also across the year': (tester) async {
    await pumpApp(tester, demo: true);
    final now = DateKey.month();
    await tapKey(tester, 'prevMonth');
    expect(find.byKey(const Key('entry')), findsNothing);
    for (var i = 0; i < 12; i++) {
      await tapKey(tester, 'nextMonth');
    }
    expect(tester.widget<Text>(find.byKey(const Key('monthTitle')).first).data, contains(DateKey.shiftMonth(now, 11).substring(0, 4)));
  },
  'budget left, over budget and the House space': (tester) async {
    final model = await pumpApp(tester, demo: true);
    // Demo: budgets 300 + 500, spent 45,50 + 500.
    expect(tester.widget<Text>(find.byKey(const Key('leftAmount')).first).data, eur(80000 - 54550));
    await tapKey(tester, 'tab.house');
    expect(find.text('House'), findsWidgets);
    expect(find.textContaining('Tosve'), findsWidgets, reason: 'House entries show who added them');
    final h = model.store.houseSpace!.id;
    final g = model.store.categories(h).firstWhere((c) => c.name == 'Groceries').id;
    model.store.addTransaction(spaceId: h, categoryId: g, kind: EntryKind.expense, amount: 50000, date: DateKey.day());
    await tester.pumpAndSettle();
    expect(find.text('Over budget'), findsOneWidget);
  },
  'Light, Dark and Automatic appearance': (tester) async {
    final model = await pumpApp(tester);
    await tapKey(tester, 'tab.settings');
    await tapText(tester, 'Dark');
    expect(model.appearance, Appearance.dark);
    expect(Theme.of(tester.element(find.byKey(const Key('settingsList')))).brightness, Brightness.dark);
    await tapText(tester, 'Light');
    expect(Theme.of(tester.element(find.byKey(const Key('settingsList')))).brightness, Brightness.light);
    await tapText(tester, 'Automatic');
    expect(model.appearance, Appearance.system);
  },
  'categories: add with a budget, refuse a duplicate name, hide': (tester) async {
    final model = await pumpApp(tester);
    await tapKey(tester, 'tab.settings');
    await tapKey(tester, 'editPersonalCategories');
    await tapKey(tester, 'addCategory.expense');
    await typeInto(tester, 'categoryName', 'Pets');
    await typeInto(tester, 'categoryBudget', '50');
    await tapKey(tester, 'saveCategory');
    final pets = model.store.data.categories.where((c) => c.name == 'Pets').single;
    expect(pets.budget, 5000);
    await tapKey(tester, 'addCategory.expense');
    await typeInto(tester, 'categoryName', ' pets ');
    await tapKey(tester, 'saveCategory');
    expect(find.byKey(const Key('categoryProblem')), findsOneWidget);
    await tapKey(tester, 'cancelCategory');
    await tapKey(tester, 'categoryRow.Pets');
    await tapKey(tester, 'toggleHidden');
    expect(model.store.category(pets.id)!.archived, isTrue);
  },
  'who uses the phone, and the partner balance': (tester) async {
    final model = await pumpApp(tester);
    final s = model.store;
    final month = DateKey.month();
    s.addTransaction(
      spaceId: s.personalSpace('u_tosve')!.id,
      categoryId: s.categories(s.personalSpace('u_tosve')!.id).firstWhere((c) => c.name == 'Salary').id,
      kind: EntryKind.income,
      amount: 300000,
      date: '$month-02',
    );
    s.addTransaction(
      spaceId: s.personalSpace('u_milica')!.id,
      categoryId: s.categories(s.personalSpace('u_milica')!.id).firstWhere((c) => c.name == 'Salary').id,
      kind: EntryKind.income,
      amount: 200000,
      date: '$month-02',
    );
    await tapKey(tester, 'tab.settings');
    await reveal(tester, find.byKey(const Key('partnerBalanceText')));
    expect(tester.widget<Text>(find.byKey(const Key('partnerBalanceText'))).data, contains('Tosve sends Milica ${eur(50000)}'));
    await tapKey(tester, 'user.Milica');
    expect(s.currentUser.name, 'Milica');
    await tapKey(tester, 'tab.personal');
    expect(statText(tester, 'Income'), eur(200000));
  },
};
