// Six months of weekly receipts scanned through the app (see integration_test/price_flow.dart),
// with each receipt's text as a perfect reader would give it. PRICE_SHOTS=1 also saves
// screenshots of the Prices screen to test/price_shots/ (with real fonts):
//   PRICE_SHOTS=1 flutter test --update-goldens test/price_history_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/price_flow.dart';

final shots = Platform.environment['PRICE_SHOTS'] == '1';

Future<void> loadFonts() async {
  // DejaVu Sans has every letter and sign used (č, €, ▲); Material icons for the buttons.
  for (final (family, files) in [
    ('Roboto', ['/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf']),
    ('MaterialIcons', ['${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']),
  ]) {
    final loader = FontLoader(family);
    for (final f in files) {
      if (File(f).existsSync()) loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await loader.load();
  }
}

void main() {
  testWidgets('six months of weekly receipts: Prices shows each item\'s real price trend', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    if (shots) await tester.runAsync(loadFonts);
    Future<void> shot(String name) async {
      if (!shots) return;
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('price_shots/$name.png'));
    }

    final run = await scanSixMonths(tester, QueueReader((r) async => r['text'] as String), shot: shot);
    // ignore: avoid_print
    print(run.log.join('\n'));
    expect(run.readRight, run.lines, reason: 'every line read from the text');
    expect(run.totalsRight, priceReceipts.length);
    expect(run.model.store.data.transactions.length, 26);
    expect(
      run.model.store.data.transactions.map((t) => t.date).toSet(),
      priceReceipts.map((r) => r['date']).toSet(),
      reason: 'dates picked',
    );
    expect(checkTrends(run), isEmpty);
    await checkPricesScreen(tester, shot: shot);
  });
}
