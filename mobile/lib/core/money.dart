import 'dart:math' as math;

import 'package:intl/intl.dart';

/// Money is always whole cents (int). These rules are the web app's (`toCents` in store.js),
/// checked against the web app's own answers by the golden tests.
class Money {
  Money._();

  static final _spaces = RegExp(r"[\s  ']");
  static final _currency = RegExp(r'€|eur$', caseSensitive: false);
  static final _shape = RegExp(r'^\d[\d.,]*$|^[.,]\d+$');

  /// Turns typed or printed money into cents. Accepts "12,50", "12.50", "1.299,00", "1,299.00",
  /// "7", "12,50 €". The last "," or "." is the decimal point, except a dot followed by exactly
  /// three digits, which is the Slovenian thousands separator ("1.000" is one thousand euros).
  /// Anything else (minus signs, "1e5", letters) gives null.
  static int? cents(String input) {
    var s = input.trim().replaceAll(_spaces, '').replaceFirst(_currency, '');
    if (!_shape.hasMatch(s)) return null;
    final lastSep = math.max(s.lastIndexOf(','), s.lastIndexOf('.'));
    String normalized;
    if (lastSep == -1) {
      normalized = s;
    } else {
      final intPart = s.substring(0, lastSep).replaceAll(RegExp(r'[.,]'), '');
      final frac = s.substring(lastSep + 1);
      final mixed = s.contains(',') && s.contains('.');
      if (s[lastSep] == '.' && frac.length == 3 && !mixed && intPart.isNotEmpty && intPart.contains(RegExp(r'[1-9]'))) {
        normalized = intPart + frac;
      } else {
        normalized = '${intPart.isEmpty ? '0' : intPart}.${frac.isEmpty ? '0' : frac}';
      }
    }
    final n = double.tryParse(normalized);
    // Absurdly long numbers are refused instead of overflowing (the limits refuse them anyway).
    if (n == null || !n.isFinite || n >= 1e15) return null;
    return fromEuros(n);
  }

  /// Euros to cents, rounding half up like JavaScript's Math.round.
  static int fromEuros(double euros) => (euros * 100 + 0.5).floor();

  /// "12,50" style text for an input field ("" for 0 when [emptyForZero]).
  static String inputText(int cents, {bool emptyForZero = true}) {
    if (cents == 0 && emptyForZero) return '';
    final sign = cents < 0 ? '-' : '';
    final a = cents.abs();
    final rest = a % 100;
    return rest == 0 ? '$sign${a ~/ 100}' : '$sign${a ~/ 100},${rest < 10 ? '0' : ''}$rest';
  }

  /// The locale used for showing money and dates (set once from the phone's settings).
  static String locale = 'en';

  /// Formatted for display, e.g. "1.234,50 €" in Slovenia. Whole amounts drop the cents.
  static String format(int cents, {String currency = 'EUR'}) {
    final digits = cents % 100 == 0 ? 0 : 2;
    try {
      final f = NumberFormat.simpleCurrency(locale: locale, name: currency, decimalDigits: digits);
      return f.format(cents / 100);
    } catch (_) {
      return '${(cents / 100).toStringAsFixed(2)} $currency';
    }
  }

  /// Percent change from [before] to [now], one decimal place. null when there is nothing to compare with.
  static double? percentChange(int now, int before) {
    if (before == 0) return null;
    return ((now - before) / before * 1000 + 0.5).floorToDouble() / 10;
  }
}

/// "YYYY-MM" months and "YYYY-MM-DD" days, in the phone's time zone.
class DateKey {
  DateKey._();

  static String _p2(int n) => n.toString().padLeft(2, '0');
  static String _p4(int n) => n.toString().padLeft(4, '0');

  static String month([DateTime? d]) {
    final x = d ?? DateTime.now();
    return '${_p4(x.year)}-${_p2(x.month)}';
  }

  static String day([DateTime? d]) {
    final x = d ?? DateTime.now();
    return '${_p4(x.year)}-${_p2(x.month)}-${_p2(x.day)}';
  }

  /// Moves a "YYYY-MM" month forward or back, across years.
  static String shiftMonth(String month, int delta) {
    final p = month.split('-').map(int.tryParse).toList();
    if (p.length != 2 || p.contains(null)) return month;
    final total = p[0]! * 12 + (p[1]! - 1) + delta;
    final y = (total / 12).floor();
    final m = total - y * 12 + 1;
    return '${_p4(y)}-${_p2(m)}';
  }

  /// The DateTime for a "YYYY-MM-DD" key (noon, so time zone changes can't move it to another day).
  static DateTime? parseDay(String key) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(key)) return null;
    final p = key.split('-').map(int.parse).toList();
    final d = DateTime(p[0], p[1], p[2], 12);
    return day(d) == key ? d : null;
  }

  static bool isValidDay(String key) => parseDay(key) != null;

  /// ISO 8601 with milliseconds in UTC, exactly like JavaScript's toISOString().
  static String timestamp([DateTime? d]) {
    final u = (d ?? DateTime.now()).toUtc();
    String p3(int n) => n.toString().padLeft(3, '0');
    return '${_p4(u.year)}-${_p2(u.month)}-${_p2(u.day)}T${_p2(u.hour)}:${_p2(u.minute)}:${_p2(u.second)}.${p3(u.millisecond)}Z';
  }
}

/// Postgres times look like "2026-11-25T11:30:00.123456+00:00" or "2026-11-25 11:30:00+00".
class Timestamps {
  Timestamps._();

  /// Milliseconds since 1970 (0 if unreadable), like the web app's parseTs (extra decimals are cut).
  static int millis(Object? value) {
    if (value is! String || value.isEmpty) return 0;
    var s = value.replaceFirst(' ', 'T');
    s = s.replaceFirstMapped(RegExp(r'\.(\d+)'), (m) => '.${(m[1]!.length > 3 ? m[1]!.substring(0, 3) : m[1]!.padRight(3, '0'))}');
    s = s.replaceFirstMapped(RegExp(r'([+-]\d\d)$'), (m) => '${m[1]}:00');
    final d = DateTime.tryParse(s);
    return d?.millisecondsSinceEpoch ?? 0;
  }

  /// "2026-11-25T11:30:00.123Z"
  static String iso(Object? value) => DateKey.timestamp(DateTime.fromMillisecondsSinceEpoch(millis(value), isUtc: true));

  static bool newer(Object? a, Object? b) => millis(a) > millis(b);
}
