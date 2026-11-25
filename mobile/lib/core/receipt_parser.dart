import 'models.dart';
import 'money.dart';

/// Finds the product lines and the total in the text read from a receipt photo.
///
/// A line-by-line port of `parseReceipt` and `findTotal` in the web app's receipt.js. Dart's
/// regular expressions follow JavaScript's rules, so the patterns are copied unchanged; a golden
/// test feeds thousands of generated receipts to both versions and checks they agree.
class ReceiptParser {
  ReceiptParser._();

  // Words that mark lines which are not products (totals, tax, payment, etc.).
  // Includes common English, Slovenian, Serbian/Croatian/Bosnian and German receipt words.
  static final _skip = RegExp(
    r'\b(skupaj|za pla[čc]ilo|ddv|vrnjeno|vra[čc]ilo|zoi|eor|davčna|davcna|blagajnik|total|subtotal|sub-total|sum|summe|ukupno|ukupan|za uplatu|uplata|plaćeno|placeno|povra[ćc]aj|kusur|pdv|vat|tax|mwst|ust|gotovina|cash|kartica|card|visa|mastercard|maestro|change|rabat|popust|discount|osnovica|stopa|iznos|račun|racun|receipt|fiskalni|pib|datum|date|vreme|time|kasir|cashier|bon|tel|www|hvala|thank)\b',
    caseSensitive: false,
  );

  // A price at the end of a line: 129.99, 1.299,00, 89,50, optionally followed by a tax letter
  // (A, B, C...) or €. A little junk between the price and the end of the line is allowed
  // ("1,29/:C", "2,15.€", "1;28").
  static final _priceAtEnd = RegExp(
    r'(?<=^|[\s€:])(-?\d{1,3}(?:\.\d{3})+,\d{2}|-?\d+[.,;:] ?\d{2})[\s\W_]*(?:[A-ZĐŠČĆŽ€$]{1,3}|[a-e])?[\s\W_]*$',
    unicode: true,
  );

  static final _totalWords = RegExp(r'\b(skupaj|za pla[čc]ilo|total|ukupno|za uplatu|summe)\b', caseSensitive: false);
  static final _taxWords = RegExp(r'\b(ddv|pdv|vat|osnova)\b', caseSensitive: false);
  static final _lineBreak = RegExp(r'\r?\n');
  static final _spaces = RegExp(r'\s+');
  static final _trim = RegExp(r'^\s+|\s+$');
  static final _currencyBeforePrice = RegExp(r'(\s+(€|EUR|e|E))+\s*$', unicode: true);
  static final _euroAtEnd = RegExp(r'€\s*$', unicode: true);
  static final _semi = RegExp(r'[;:]');
  static final _junk = RegExp(r'[|_~*#"]+');
  static final _leadingNumbers = RegExp(r'^[\d.,\s]+(?=\p{L})', unicode: true);
  static final _quantityOnly = RegExp(r'^[\d.,]+\s*(kom|kg|g|l|pcs|st)?\s*[x×*]\s*[\d.,]+', caseSensitive: false);
  static final _twoLetters = RegExp(r'\p{L}{2,}', unicode: true);
  static final _gramMisread = RegExp(r'\b(\d*[1-9]0{1,2})[69]\b');

  /// JavaScript's String.prototype.trim.
  static String jsTrim(String s) => s.replaceAll(_trim, '');

  static List<String> _lines(String text) => text.split(_lineBreak).map((l) => jsTrim(l.replaceAll(_spaces, ' '))).toList();

  static int? _cents(String priceText) => Money.cents(priceText.replaceAll(_semi, ',').replaceAll(' ', ''));

  /// Common misreads in product names: "500G" read as "5006", "150g" as "1509".
  static String fixName(String name) {
    final upper = name == name.toUpperCase();
    return name.replaceAllMapped(_gramMisread, (m) => '${m[1]}${upper ? 'G' : 'g'}');
  }

  /// The receipt's grand total ("SKUPAJ", "ZA PLAČILO", "TOTAL"...), which already includes
  /// discounts. When several lines qualify, the largest amount wins. null if none is printed.
  static int? findTotal(String text) {
    int? total;
    for (final line in _lines(text)) {
      if (!_totalWords.hasMatch(line) || _taxWords.hasMatch(line)) continue;
      final m = _priceAtEnd.firstMatch(line);
      if (m == null) continue;
      final c = _cents(m[1]!);
      if (c != null && c > 0) total = total == null || c > total ? c : total;
    }
    return total;
  }

  /// Product lines with their prices, in the order they are printed.
  static List<ReceiptItem> parse(String text) {
    final items = <ReceiptItem>[];
    final lines = _lines(text).where((l) => l.isNotEmpty).toList();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_skip.hasMatch(line)) continue;
      final m = _priceAtEnd.firstMatch(line);
      if (m == null) continue;
      // Drop a currency sign before the price (the reader often sees € as "e" or "E").
      var name = jsTrim(line.substring(0, m.start).replaceFirst(_currencyBeforePrice, '').replaceFirst(_euroAtEnd, ''));
      final price = _cents(m[1]!);
      if (price == null || price <= 0) continue;
      // Quantity lines like "2 x 1,29" or "0,750 kg x 199,99": the product name is usually on the line above.
      final qtyOnly = _quantityOnly.hasMatch(name);
      if (!qtyOnly && !_twoLetters.hasMatch(name)) continue; // e.g. a date and time "25.11.2026 10:15"
      if (qtyOnly) {
        final prev = i > 0 ? lines[i - 1] : null;
        final above = prev != null && !_priceAtEnd.hasMatch(prev) && !_skip.hasMatch(prev) ? prev : null;
        if (above != null && _twoLetters.hasMatch(above)) {
          name = above;
        } else {
          continue;
        }
      }
      name = jsTrim(name.replaceAll(_junk, ' ').replaceAll(_spaces, ' ').replaceFirst(_leadingNumbers, ''));
      if (name.length < 2) continue;
      items.add(ReceiptItem(name: fixName(name), price: price));
    }
    return items;
  }
}

/// The phone's text reader returns separate pieces of text with their position on the photo.
/// On a receipt the product name and its price are often two pieces far apart on the same row.
/// This puts pieces on the same row back together, left to right, so the parser sees
/// "MLEKO 1L    1,29 C" as one line, like the web app's reader gives it.
class TextPiece {
  final String text;

  /// Position on the photo, 0...1, measured from the top-left corner.
  final double minX, minY, maxX, maxY;

  /// How much the piece's text line slopes (down is positive, dy/dx).
  final double slope;

  const TextPiece(this.text, this.minX, this.minY, this.maxX, this.maxY, [this.slope = 0]);

  factory TextPiece.fromMap(Map m) => TextPiece(
    '${m['text'] ?? ''}',
    (m['minX'] as num).toDouble(),
    (m['minY'] as num).toDouble(),
    (m['maxX'] as num).toDouble(),
    (m['maxY'] as num).toDouble(),
    ((m['slope'] ?? 0) as num).toDouble(),
  );

  double get midY => (minY + maxY) / 2;

  /// Height of the letters themselves: a tilted piece's straight box is taller than its text.
  double get height {
    final box = maxY - minY;
    final h = box - slope.abs() * (maxX - minX);
    return h > box * 0.3 ? h : box * 0.3;
  }
}

class TextLines {
  TextLines._();

  /// Joins pieces into text lines, top to bottom. Two pieces are on the same row when their
  /// vertical middles are closer than about half a text height. Rows may slope a little; the
  /// slope is measured from the pieces themselves.
  static String assemble(List<TextPiece> pieces) {
    final ps = pieces.where((p) => p.text.trim().isNotEmpty && p.maxY > p.minY).toList();
    if (ps.isEmpty) return '';
    final slope = estimateSlope(ps);
    double y(TextPiece p) => p.midY - slope * ((p.minX + p.maxX) / 2);
    ps.sort((a, b) => y(a).compareTo(y(b)));
    final rows = <List<TextPiece>>[];
    final rowY = <double>[];
    final rowH = <double>[];
    for (final p in ps) {
      final last = rows.length - 1;
      if (last >= 0 && (y(p) - rowY[last]).abs() < 0.5 * (rowH[last] < p.height ? rowH[last] : p.height)) {
        rows[last].add(p);
        final n = rows[last].length;
        rowY[last] = (rowY[last] * (n - 1) + y(p)) / n;
        if (p.height > rowH[last]) rowH[last] = p.height;
      } else {
        rows.add([p]);
        rowY.add(y(p));
        rowH.add(p.height);
      }
    }
    return rows
        .map((row) {
          row.sort((a, b) => a.minX.compareTo(b.minX));
          return row.map((p) => p.text.trim()).join(' ');
        })
        .join('\n');
  }

  /// The typical slope of the rows: the median slope of the (wide) pieces. 0 if unsure.
  static double estimateSlope(List<TextPiece> ps) {
    final wide = ps.where((p) => p.maxX - p.minX > 0.1).toList();
    final slopes = (wide.length >= 3 ? wide : ps).map((p) => p.slope).where((s) => s.isFinite).toList();
    if (slopes.isEmpty) return 0;
    slopes.sort();
    final s = slopes[slopes.length ~/ 2];
    return s.abs() < 0.2 ? s : 0;
  }
}
