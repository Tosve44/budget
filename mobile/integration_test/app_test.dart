// Runs on real Android emulators and iPhone simulators (see .github/workflows/mobile.yml):
//   flutter test integration_test -d <device>
// 1. The screen flows from flows.dart, tapping through the app like a person.
// 2. The phone's own text reader (Apple Vision / Google ML Kit) on real receipt photos.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:budget/core/receipt_parser.dart';
import 'package:budget/platform/receipt_reader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'flows.dart';
import 'receipt_photos.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('device', () {
    final v = PlatformDispatcher.instance.views.first;
    final size = v.physicalSize / v.devicePixelRatio;
    // ignore: avoid_print
    print(
      'DEVICE ${Platform.operatingSystem} ${Platform.operatingSystemVersion} | screen ${size.width.round()}x${size.height.round()} '
      '@${v.devicePixelRatio}x | text x${PlatformDispatcher.instance.textScaleFactor} | ${PlatformDispatcher.instance.platformBrightness.name}',
    );
  });

  for (final f in flows.entries) {
    testWidgets(f.key, (tester) => logged(f.key, () => f.value(tester)));
  }

  group('receipt photos read by the phone', () {
    for (final photo in receiptPhotos.entries) {
      test(
        photo.key,
        () => logged('photo ${photo.key}', () async {
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/${photo.key}');
          await file.writeAsBytes(base64Decode(photo.value));
          final text = await const DeviceReceiptReader().read(file.path).timeout(const Duration(minutes: 2));
          final items = ReceiptParser.parse(text);
          final total = ReceiptParser.findTotal(text);
          // ignore: avoid_print
          print('OCR ${photo.key}: ${items.length} items, total $total | ${items.take(4).map((i) => '${i.name} ${i.price}').join('; ')}');
          if (items.isEmpty || const {'engrotus.jpg', 'mercator2.jpg'}.contains(photo.key)) {
            // What the phone's reader gave, so a failure can be replayed in a unit test.
            final raw = await const MethodChannel('budget/ocr').invokeListMethod<Map>('read', {'path': file.path, 'rotation': 0});
            // ignore: avoid_print
            print('PIECES ${photo.key}: ${jsonEncode(raw)}');
          }
          expect(text, isNotEmpty, reason: 'no text found at all');
          expect(items.isNotEmpty || total != null, isTrue, reason: 'found neither items nor a total in:\n$text');
          if (photo.key == 'mercator.jpg') {
            // The web app's own test checks the same two things on this photo.
            expect(total, 839, reason: text);
            expect(items.any((i) => i.name.startsWith('MLEKO')), isTrue, reason: text);
          }
          // Photos taken at an angle: each price must stay with its own item, not the one above.
          if (photo.key == 'engrotus.jpg') {
            expect(items.where((i) => i.name.startsWith('Banane')).map((i) => i.price), [162], reason: text);
          }
          if (photo.key == 'mercator2.jpg') {
            expect(items.where((i) => i.name.startsWith('Jogurt')).map((i) => i.price), [69], reason: text);
          }
        }),
      );
    }
  });
}

/// Prints one line per test (PASS / FAIL and why), so the device logs show every result.
Future<void> logged(String name, Future<void> Function() body) async {
  try {
    await body();
    // ignore: avoid_print
    print('RESULT PASS | $name');
  } catch (e) {
    // ignore: avoid_print
    print('RESULT FAIL | $name | ${'$e'.split('\n').where((l) => l.trim().isNotEmpty).take(4).join(' / ')}');
    rethrow;
  }
}
