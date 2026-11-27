// How the pieces of text that the phone reads are joined into receipt lines.
import 'dart:convert';
import 'dart:io';
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

  for (final deg in [0.0, -3.0, -6.0, -9.0, 4.0, 7.0]) {
    test('a photo turned by $deg° still puts each price next to its item', () {
      final pieces = [for (var i = 0; i < lines.length; i++) ...row(lines[i].$1, lines[i].$2, 0.3 + i * 0.06, deg * pi / 180)];
      final text = TextLines.assemble(pieces..shuffle(Random(1)));
      expect(text.split('\n'), [for (final (n, p) in lines) '$n $p']);
    });
  }

  test('a slope that the reader got wrong does not split items from their prices', () {
    final pieces = [
      for (var i = 0; i < lines.length; i++)
        for (final p in row(lines[i].$1, lines[i].$2, 0.3 + i * 0.06, -8 * pi / 180))
          TextPiece(p.text, p.minX, p.minY, p.maxX, p.maxY, 0.05),
    ];
    expect(TextLines.assemble(pieces).split('\n'), [for (final (n, p) in lines) '$n $p']);
  });

  test('a steep photo with close rows keeps each price with its own item when the reader gives a rough slope', () {
    // Like engrotus.jpg on iPhone: rows close together, so a nearly flat slope would join each
    // price with the item one row up. The reader's slope is only roughly right.
    final angle = -8 * pi / 180;
    final pieces = [
      for (var i = 0; i < lines.length; i++)
        for (final p in row(lines[i].$1, lines[i].$2, 0.3 + i * 0.045, angle))
          TextPiece(p.text, p.minX, p.minY, p.maxX, p.maxY, tan(angle) * 0.8),
    ];
    expect(TextLines.assemble(pieces).split('\n'), [for (final (n, p) in lines) '$n $p']);
  });

  test('a given slope is used as it is', () {
    final pieces = [const TextPiece('Mleko', 0.1, 0.30, 0.4, 0.36, 0.1), const TextPiece('1,29', 0.8, 0.37, 0.9, 0.41, 0.1)];
    expect(TextLines.assemble(pieces), 'Mleko 1,29');
  });

  // What Apple's reader really gave for the two photos taken at an angle (iPhone 16 Pro Max
  // simulator, iOS 18). Its slopes are noisy: some pieces even tilt the wrong way.
  for (final (photo, first, second) in [
    ('engrotus', 'Banane kg 1,62 C', 'Kruh ajdov 400g 2,35 C'),
    ('mercator2', 'Jogurt Ego 150g 0,69 C', 'Kava Loka 200g 3,79 c'),
  ]) {
    test('the iPhone reading of $photo.jpg keeps each price with its own item', () {
      final raw = jsonDecode(File('test/fixtures/pieces/ios-$photo.json').readAsStringSync()) as List;
      final lines = TextLines.assemble(raw.map((m) => TextPiece.fromMap(m as Map)).toList()).split('\n');
      expect(lines, containsAllInOrder([first, second]), reason: lines.join('\n'));
    });
  }
}
