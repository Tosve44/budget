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
  static final _unitPriceLine = RegExp(r'^[\d.,]+\s*(kom|kos|kg|g|pcs|st)\.?\s*[x×*]$', caseSensitive: false);
  static final _quantityOnly = RegExp(r'^[\d.,]+\s*(kom|kg|g|l|pcs|st)?\s*[x×*]\s*[\d.,]+', caseSensitive: false);
  static final _twoLetters = RegExp(r'\p{L}{2,}', unicode: true);
  static final _gramMisread = RegExp(r'\b(\d*[1-9]0{1,2})[69]\b');
  static final _litreDecimal = RegExp(r'\b(\d,\d{1,2})1\b');
  static final _litreAfterPercent = RegExp(r'(%\s?)11\b');
  static final _litreAtEnd = RegExp(r'\b11$');
  // The price of one may be read with a space after the comma ("1, 36").
  static final _quantity = RegExp(
    r'^([\d.,]+)\s*(kom|kos|kg|g|pcs|st)?\.?\s*[x×*]\s*(\d[\d.,]*[.,;:]\s\d{2}(?!\d)|[\d.,]+)',
    caseSensitive: false,
  );

  /// JavaScript's String.prototype.trim.
  static String jsTrim(String s) => s.replaceAll(_trim, '');

  static List<String> _lines(String text) => text.split(_lineBreak).map((l) => jsTrim(l.replaceAll(_spaces, ' '))).toList();

  static int? _cents(String priceText) => Money.cents(priceText.replaceAll(_semi, ',').replaceAll(' ', ''));

  /// Common misreads in product names: "500G" read as "5006", "150g" as "1509", and a small
  /// "l" (litre) read as "1": "1,5l" as "1,51", "0,75l" as "0,751", "3,5% 1l" as "3,5% 11".
  static String fixName(String name) {
    final upper = name == name.toUpperCase();
    var n = name.replaceAllMapped(_gramMisread, (m) => '${m[1]}${upper ? 'G' : 'g'}');
    if (!upper) {
      n = n
          .replaceAllMapped(_litreDecimal, (m) => '${m[1]}l')
          .replaceAllMapped(_litreAfterPercent, (m) => '${m[1]}1l')
          .replaceFirst(_litreAtEnd, '1l');
    }
    return n;
  }

  /// "2 x 0,59", "0,856 kg x 1,49", "350 g x 12,99": how many (or how much) and the price of
  /// one (or of a kilo). null when the line doesn't say.
  static ({double qty, String? unit, int? unitPrice})? readQuantity(String text) {
    final m = _quantity.firstMatch(text);
    if (m == null) return null;
    var qty = double.tryParse(m[1]!.replaceFirst(',', '.'));
    if (qty == null) return null;
    final unitWord = (m[2] ?? '').toLowerCase();
    if (unitWord == 'g') qty /= 1000;
    if (!(qty > 0) || qty > 999 || qty == 1) return null;
    final byWeight = unitWord == 'kg' || unitWord == 'g' || qty != qty.roundToDouble();
    final each = Money.cents(m[3]!.replaceAll(_semi, ',').replaceAll(_spaces, ''));
    return (qty: (qty * 1000).round() / 1000, unit: byWeight ? 'kg' : null, unitPrice: each != null && each > 0 ? each : null);
  }

  static ReceiptItem _withQuantity(ReceiptItem it, ({double qty, String? unit, int? unitPrice}) a) =>
      ReceiptItem(name: it.name, price: it.price, qty: a.qty, unit: a.unit, unitPrice: a.unitPrice);

  // Each name stands alone: not part of a longer word ("tuševa" is not Tuš), and letters like Š
  // count as letters.
  static final _stores = [
    ('Mercator', 'merc[a@]t[o0]r'),
    ('Spar', '(inter)?spar'),
    ('Lidl', 'lid[l1i]'),
    ('Hofer', 'h[o0]fer'),
    ('Tuš', '(engro)?tu[sš]'),
    ('Eurospin', 'eurospin'),
    ('Jager', 'jager'),
    ('E.Leclerc', 'leclerc'),
    ('dm', r'dm[\s-]*drogerie'),
    ('Müller', 'm(ü|ue|u)ller'),
    ('Kaufland', 'kaufland'),
    ('Konzum', 'konzum'),
    ('Maxi', 'maxi'),
    ('Bingo', 'bingo'),
    ('Aldi', 'aldi'),
    ('Billa', 'billa'),
    ('Petrol', 'petrol'),
    ('OMV', 'omv'),
  ].map((s) => (s.$1, RegExp('(?<![\\p{L}\\p{N}])(?:${s.$2})(?![\\p{L}\\p{N}])', caseSensitive: false, unicode: true))).toList();

  /// Which shop a receipt is from, from the name printed on it (usually in the first lines).
  /// Covers the big chains in Slovenia and around; null if none is found. Same as findStore in
  /// the web app's receipt.js.
  static String? findStore(String text) {
    final lines = text.split(_lineBreak).map(jsTrim).where((l) => l.isNotEmpty).toList();
    // The shop's name is at the top; look there first, so a product name lower down (e.g. a
    // "Spar" own brand bought elsewhere) doesn't win.
    for (final part in [lines.take(6), lines]) {
      for (final line in part) {
        for (final (name, re) in _stores) {
          if (re.hasMatch(line)) return name;
        }
      }
    }
    return null;
  }

  static final _dmy = RegExp(r'(?<![\d.,/-])(\d{1,2}) ?[.,/-] ?(\d{1,2}) ?[.,/-] ?(\d{4}|\d{2})(?![\d,]|[.,/-]\d)');
  static final _ymd = RegExp(r'(?<!\d)(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)');
  static final _time = RegExp(r'(?<!\d)([01]?\d|2[0-3])[:.]([0-5]\d)(?![\d,])');
  static final _notPurchase = RegExp(r'(rok|uporab|best|exp|valid|velja|vrijedi|važi|garanc)', caseSensitive: false); // best before...

  /// The day of the purchase, as "YYYY-MM-DD"; null if none is printed (or it can't be right).
  /// Receipts print "21.11.2026 14:05", "21.11.26", "21/11/2026" or "2026-11-21"; the reader may
  /// see a dot as a comma or add spaces. Only real days from about a year ago up to tomorrow
  /// count, so a price isn't taken, and lines like "best before" are skipped. The date next to a
  /// time wins. Same as findDate in the web app's receipt.js.
  static String? findDate(String text, {DateTime? today}) {
    final t = today ?? DateTime.now();
    final latest = DateTime(t.year, t.month, t.day + 1);
    final earliest = DateTime(t.year - 1, t.month, t.day - 7);
    String? ok(int y, int m, int d) {
      final day = DateTime(y, m, d);
      if (day.year != y || day.month != m || day.day != d) return null; // e.g. 31.02.
      if (day.isAfter(latest) || day.isBefore(earliest)) return null;
      return '$y-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
    }

    String? first;
    for (final line in text.split(RegExp(r'\r?\n'))) {
      if (_notPurchase.hasMatch(line)) continue;
      final found = <(String?, RegExpMatch)>[];
      for (final m in _ymd.allMatches(line)) {
        found.add((ok(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)), m));
      }
      for (final m in _dmy.allMatches(line)) {
        final y = m[3]!.length == 2 ? 2000 + int.parse(m[3]!) : int.parse(m[3]!);
        found.add((ok(y, int.parse(m[2]!), int.parse(m[1]!)), m));
      }
      for (final (day, m) in found) {
        if (day == null) continue;
        final rest = '${line.substring(0, m.start)} ${line.substring(m.end)}';
        if (_time.hasMatch(rest)) return day;
        first ??= day;
      }
    }
    return first;
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
    final at = <int>[]; // the line of each item
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
      // "0,620 kg x 1,85": the number at the end is the price of one kilo, not a line total. It is
      // a quantity line (used below), not a product called "kg x".
      if (_unitPriceLine.hasMatch(name)) continue;
      final qtyOnly = _quantityOnly.hasMatch(name);
      if (!qtyOnly && !_twoLetters.hasMatch(name)) continue; // e.g. a date and time "25.11.2026 10:15"
      ({double qty, String? unit, int? unitPrice})? amount;
      if (qtyOnly) {
        final prev = i > 0 ? lines[i - 1] : null;
        final above = prev != null && !_priceAtEnd.hasMatch(prev) && !_skip.hasMatch(prev) ? prev : null;
        if (above != null && _twoLetters.hasMatch(above)) {
          amount = readQuantity(name);
          name = above;
        } else {
          continue;
        }
      }
      name = jsTrim(name.replaceAll(_junk, ' ').replaceAll(_spaces, ' ').replaceFirst(_leadingNumbers, ''));
      if (name.length < 2) continue;
      final item = ReceiptItem(name: fixName(name), price: price);
      items.add(amount == null ? item : _withQuantity(item, amount));
      at.add(i);
    }
    // Other layouts put the quantity on its own line, without the line total: below the product
    // ("Paradižnik 1,15" then "0,620 kg x 1,85 EUR/kg", Lidl) or above it ("2 x 0,89" then
    // "JOGURT 1,78", Mercator). Used when the numbers agree with that product's line total.
    for (var i = 0; i < lines.length; i++) {
      if (at.contains(i) || _skip.hasMatch(lines[i])) continue;
      final a = readQuantity(lines[i]);
      final each = a?.unitPrice;
      if (a == null || each == null) continue;
      for (final j in [i - 1, i + 1]) {
        final k = at.indexOf(j);
        if (k < 0) continue;
        final it = items[k];
        if (it.qty == null && ((a.qty * each).round() - it.price).abs() <= 1) {
          items[k] = _withQuantity(it, a);
          break;
        }
      }
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

  /// The photo's width divided by its height (as read, after turning). 1 if not known.
  final double aspect;

  const TextPiece(this.text, this.minX, this.minY, this.maxX, this.maxY, [this.slope = 0, this.aspect = 1]);

  factory TextPiece.fromMap(Map m) => TextPiece(
    '${m['text'] ?? ''}',
    (m['minX'] as num).toDouble(),
    (m['minY'] as num).toDouble(),
    (m['maxX'] as num).toDouble(),
    (m['maxY'] as num).toDouble(),
    ((m['slope'] ?? 0) as num).toDouble(),
    ((m['aspect'] ?? 1) as num).toDouble(),
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
    // The reader's own slope is the best guess, but some readers give only straight boxes (slope
    // 0) or a slope that is a little off. On a photo taken at an angle each item then lands on
    // another line than its price, so nearby slopes are tried too, closest first, and the one that
    // joins the most pieces into rows wins. Going outwards from the reader's guess matters: a much
    // steeper slope can also join every price, but with the item one row up.
    final guess = slopeFromLeftEdge(ps) ?? estimateSlope(ps);
    var rows = _rows(ps, guess);
    for (var i = 1; i <= 100; i++) {
      for (final s in [guess + i * 0.0025, guess - i * 0.0025]) {
        final r = _rows(ps, s);
        if (r.length < rows.length) rows = r;
      }
    }
    return rows
        .map((row) {
          row.sort((a, b) => a.minX.compareTo(b.minX));
          return row.map((p) => p.text.trim()).join(' ');
        })
        .join('\n');
  }

  static List<List<TextPiece>> _rows(List<TextPiece> pieces, double slope) {
    double y(TextPiece p) => p.midY - slope * ((p.minX + p.maxX) / 2);
    final ps = [...pieces]..sort((a, b) => y(a).compareTo(y(b)));
    final rows = <List<TextPiece>>[];
    final rowY = <double>[];
    final rowH = <double>[];
    for (final p in ps) {
      final last = rows.length - 1;
      // Two pieces above each other in the same column are never one row, whatever the slope:
      // otherwise a wrong slope can stack two item names ("MASLO 250G JAJCA M 10 KOM") into
      // one line, which puts every price below it on the wrong item.
      if (last >= 0 &&
          (y(p) - rowY[last]).abs() < 0.5 * (rowH[last] < p.height ? rowH[last] : p.height) &&
          !rows[last].any((q) => _overlapX(p, q))) {
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
    return rows;
  }

  /// The two pieces share more than a little of their width.
  static bool _overlapX(TextPiece a, TextPiece b) {
    final overlap = (a.maxX < b.maxX ? a.maxX : b.maxX) - (a.minX > b.minX ? a.minX : b.minX);
    final narrow = (a.maxX - a.minX) < (b.maxX - b.minX) ? a.maxX - a.minX : b.maxX - b.minX;
    return overlap > 0.3 * narrow;
  }

  /// The slope of the rows worked out from the left edge of the text: on a photo taken at an
  /// angle the lines start a little further right (or left) the lower they are, and the rows
  /// tilt by the same angle. This is steadier than the slope readers give for each piece.
  /// Null when there are too few lines to tell.
  static double? slopeFromLeftEdge(List<TextPiece> ps) {
    final xs = ps.map((p) => p.minX).toList()..sort();
    final edge = xs[xs.length ~/ 5];
    final left = ps.where((p) => p.minX < edge + 0.06).toList()..sort((a, b) => a.midY.compareTo(b.midY));
    if (left.length < 4 || left.last.midY - left.first.midY < 0.2) return null;
    // The median of the slopes between all pairs, so one indented line does not matter.
    final drifts = <double>[];
    for (var i = 0; i < left.length; i++) {
      for (var j = i + 1; j < left.length; j++) {
        final dy = left[j].midY - left[i].midY;
        if (dy > 0.05) drifts.add((left[j].minX - left[i].minX) / dy);
      }
    }
    if (drifts.isEmpty) return null;
    drifts.sort();
    final drift = drifts[drifts.length ~/ 2];
    // Turning the photo by an angle a moves the left edge by -tan(a) per unit down and tilts the
    // rows by tan(a), in pixels; in 0...1 units the photo's shape scales both.
    final a = left.first.aspect;
    final s = -drift * a * a;
    return s.abs() < 0.3 ? s : null;
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
