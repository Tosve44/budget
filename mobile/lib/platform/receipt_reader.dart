import 'package:flutter/services.dart';

import '../core/receipt_parser.dart';

/// Reads the text on a receipt photo.
abstract class ReceiptReader {
  Future<String> read(String imagePath);
}

/// The phone's own free, offline text reader: Apple's Vision on iPhone, Google's ML Kit (on the
/// phone, no internet) on Android. Native code: ios/Runner/ReceiptOcr.swift and
/// android/app/src/main/kotlin/.../ReceiptOcr.kt. It returns pieces of text with their position,
/// which TextLines puts back into receipt lines.
class DeviceReceiptReader implements ReceiptReader {
  static const _channel = MethodChannel('budget/ocr');
  const DeviceReceiptReader();

  /// Reads the photo as it is; if that finds fewer than 3 items and no total, the photo was
  /// probably taken sideways or upside down, so it is read turned 90°, 270° and 180° too (same
  /// as the web app), and the best reading is kept.
  @override
  Future<String> read(String imagePath) async {
    var best = '';
    var bestScore = -1;
    for (final rotation in const [0, 90, 270, 180]) {
      final raw = await _channel.invokeListMethod<Map>('read', {'path': imagePath, 'rotation': rotation}) ?? const [];
      final text = TextLines.assemble(raw.map(TextPiece.fromMap).toList());
      final items = ReceiptParser.parse(text).length;
      if (items >= 3 || ReceiptParser.findTotal(text) != null) return text;
      final score = items * 2 + (text.isEmpty ? 0 : 1);
      if (score > bestScore) {
        best = text;
        bestScore = score;
      }
    }
    return best;
  }
}

/// Used by the screen tests (simulators and emulators have no camera): a sample Mercator receipt.
class SampleReceiptReader implements ReceiptReader {
  const SampleReceiptReader();
  static const text =
      'MERCATOR d.o.o.\n'
      'MLEKO ALPSKO 3,5% 1L        1,29 C\n'
      'KRUH BELI 500G              1,49 C\n'
      'SKUPAJ EUR                  2,78';
  @override
  Future<String> read(String imagePath) async => text;
}
