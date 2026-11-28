// Runs on one Android emulator and one iPhone simulator (see .github/workflows/mobile.yml):
// six months of weekly receipt photos, read by the phone's own text reader (Apple Vision /
// Google ML Kit) and scanned through the app; what the reader got wrong is typed in by hand,
// as a person would. The Prices screen must then show each item's real price trend.
import 'dart:convert';
import 'dart:io';

import 'package:budget/platform/receipt_reader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'app_test.dart' show logged;
import 'price_flow.dart';
import 'price_photos.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The CI scripts wait for this line to know the app started on the simulator (otherwise they
  // restart it after 6 minutes, before the 26 photos are read).
  test('device', () {
    // ignore: avoid_print
    print('DEVICE ${Platform.operatingSystem} ${Platform.operatingSystemVersion} | price tracking');
  });

  testWidgets(
    'six months of weekly receipt photos: price tracking',
    (tester) => logged('six months of receipts', () async {
      final dir = await getTemporaryDirectory();
      final reader = QueueReader((r) async {
        final file = File('${dir.path}/${r['file']}');
        await file.writeAsBytes(base64Decode(pricePhotos[r['file']]!));
        if (const {'week-02.jpg', 'week-05.jpg', 'week-10.jpg'}.contains(r['file'])) {
          // What the phone's reader gave on a few receipts, so a misread can be replayed in a unit test.
          final raw = await const MethodChannel('budget/ocr').invokeListMethod<Map>('read', {'path': file.path, 'rotation': 0});
          // ignore: avoid_print
          print('PIECES ${r['file']}: ${jsonEncode(raw)}');
        }
        return const DeviceReceiptReader().read(file.path).timeout(const Duration(minutes: 2));
      });
      final run = await scanSixMonths(tester, reader);
      for (final l in run.log) {
        // ignore: avoid_print
        print('PRICES $l');
      }
      // ignore: avoid_print
      print(
        'PRICES read ${run.readRight}/${run.lines} lines right, ${run.totalsRight}/${priceReceipts.length} totals; '
        '${run.misread} receipts with a misread price, warning shown on ${run.warned}',
      );
      final problems = checkTrends(run);
      for (final p in problems) {
        // ignore: avoid_print
        print('PRICES PROBLEM $p');
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
      // ignore: avoid_print
      print('PRICES ${run.skipped} purchases left out of Prices because their quantity line did not add up');
      expect(run.skipped, lessThanOrEqualTo(run.lines ~/ 20), reason: 'too many purchases left out');
      expect(run.readRight / run.lines, greaterThanOrEqualTo(0.8), reason: 'the phone read too few lines right');
      // ignore: avoid_print
      print('PRICES shop read from the receipt on ${run.shopsRight}/${priceReceipts.length}');
      expect(run.shopsRight / priceReceipts.length, greaterThanOrEqualTo(0.85), reason: 'the phone read too few shop names');
      // ignore: avoid_print
      print('PRICES date read from the receipt on ${run.datesRight}/${priceReceipts.length}');
      expect(run.datesRight / priceReceipts.length, greaterThanOrEqualTo(0.85), reason: 'the phone read too few dates');
      // (A receipt whose total is misread the same way as an item can't be caught.)
      expect(run.warned, greaterThanOrEqualTo((run.misread * 0.7).floor()), reason: 'misread prices should show the warning');
      await checkPricesScreen(tester, run.model);
    }),
    timeout: const Timeout(Duration(minutes: 40)),
  );
}
