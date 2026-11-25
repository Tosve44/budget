// How the pieces of text that the phone reads are joined into receipt lines.
import 'dart:math';

import 'package:budget/core/receipt_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// A receipt row: the name on the left, the price on the right, turned by [angle] radians
/// (negative = the right side higher, like a photo taken at an angle). Boxes stay straight, and
/// no slope is given, like some readers do.
List<TextPiece> row(String name, String price, double y, double angle) {
  TextPiece piece(String t, double x0, double x1) {
    final mid = (x0 + x1) / 2;
    final dy = tan(angle) * (mid - 0.5);
    final tilt = (tan(angle) * (x1 - x0)).abs();
    return TextPiece(t, x0, y + dy - 0.015 - tilt / 2, x1, y + dy + 0.015 + tilt / 2);
  }

  return [piece(name, 0.1, 0.45), piece(price, 0.78, 0.9)];
}

void main() {
  const lines = [('Banane kg', '1,62 C'), ('Kruh ajdov 400g', '2,35 C'), ('Sir Gauda 250g', '3,19 C'), ('Mineralna 1,5L', '0,99 C')];

  for (final deg in [0.0, -3.0, -6.0, 4.0, 7.0]) {
    test('a photo turned by $deg° still puts each price next to its item', () {
      final pieces = [for (var i = 0; i < lines.length; i++) ...row(lines[i].$1, lines[i].$2, 0.3 + i * 0.06, deg * pi / 180)];
      final text = TextLines.assemble(pieces..shuffle(Random(1)));
      expect(text.split('\n'), [for (final (n, p) in lines) '$n $p']);
    });
  }

  test('a given slope is used as it is', () {
    final pieces = [const TextPiece('Mleko', 0.1, 0.30, 0.4, 0.36, 0.1), const TextPiece('1,29', 0.8, 0.37, 0.9, 0.41, 0.1)];
    expect(TextLines.assemble(pieces), 'Mleko 1,29');
  });
}
