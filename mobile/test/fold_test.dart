// Folding and unfolding a foldable phone (iPhone Duo, Galaxy Z Fold and Flip) while the app is
// open: the screen size changes under the app. Nothing may break, overflow or be lost.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/flows.dart';

// Outer (folded) and inner (open) screens, in points.
const phones = <String, List<Size>>{
  'iPhone Duo': [Size(670, 475), Size(668, 942), Size(475, 670), Size(942, 668)],
  'Galaxy Z Fold': [Size(344, 882), Size(673, 841)],
  'Galaxy Z Flip': [Size(320, 330), Size(360, 880)],
};

Future<void> foldAndUnfold(WidgetTester tester, List<Size> sizes) async {
  for (var round = 0; round < 2; round++) {
    for (final s in sizes) {
      tester.view.physicalSize = s * 3;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'at $s');
    }
  }
}

void main() {
  for (final p in phones.entries) {
    group(p.key, () {
      Future<void> start(WidgetTester tester) async {
        tester.view.devicePixelRatio = 3;
        tester.view.physicalSize = p.value.first * 3;
        addTearDown(tester.view.reset);
      }

      testWidgets('month screen, then House, while folding', (tester) async {
        await start(tester);
        await pumpApp(tester, demo: true);
        await foldAndUnfold(tester, p.value);
        await tapKey(tester, 'tab.house');
        await foldAndUnfold(tester, p.value);
        expect(find.text('House'), findsWidgets);
      });

      testWidgets('a half-typed entry is kept while folding, then saves', (tester) async {
        await start(tester);
        final model = await pumpApp(tester, demo: true);
        final before = model.store.data.transactions.length;
        await tapKey(tester, 'addExpense');
        await typeInto(tester, 'amountField', '12,50');
        await pickChip(tester, 'Groceries');
        await foldAndUnfold(tester, p.value);
        await reveal(tester, find.byKey(const Key('amountField')));
        final amount = tester.widget<TextField>(find.byKey(const Key('amountField'))).controller!.text;
        expect(amount, '12,50');
        await tapKey(tester, 'saveEntry');
        expect(model.store.data.transactions.length, before + 1);
        expect(model.store.data.transactions.any((t) => t.amount == 1250), isTrue);
      });

      testWidgets('picking a category icon while folding', (tester) async {
        await start(tester);
        await pumpApp(tester);
        await tapKey(tester, 'tab.settings');
        await tapKey(tester, 'editPersonalCategories');
        await tapKey(tester, 'categoryRow.Rent');
        await tapKey(tester, 'iconField');
        await foldAndUnfold(tester, p.value);
        await tapKey(tester, 'iconChoice.🏨');
        await foldAndUnfold(tester, p.value);
        expect(tester.widget<Text>(find.byKey(const Key('iconShown'))).data, '🏨');
      });
    });
  }

  testWidgets('the category screen survives a keyboard height below zero (iOS, while it closes)', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(402, 874) * 3;
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    await tapKey(tester, 'tab.settings');
    await tapKey(tester, 'editPersonalCategories');
    await tapKey(tester, 'categoryRow.Rent');
    await tapKey(tester, 'iconField');
    for (final bottom in [-90.0, 300.0 * 3, -3.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: bottom);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'keyboard $bottom');
    }
    await tapKey(tester, 'iconChoice.🏨');
    await tapKey(tester, 'saveCategory');
  });
}
