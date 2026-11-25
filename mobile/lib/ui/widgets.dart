import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/money.dart';
import 'home.dart';

String monthLabel(String month) {
  final d = DateKey.parseDay('$month-01');
  if (d == null) return month;
  final s = DateFormat.yMMMM(Money.locale).format(d);
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// "Wed 25 Nov"
String dayLabel(String day) {
  final d = DateKey.parseDay(day);
  return d == null ? day : DateFormat('EEE d MMM', Money.locale).format(d);
}

/// "25 Nov"
String shortDay(String day) {
  final d = DateKey.parseDay(day);
  return d == null ? day : DateFormat('d MMM', Money.locale).format(d);
}

String pct(double p) => p == p.roundToDouble() ? p.toStringAsFixed(0) : p.toStringAsFixed(1);

/// The budget bar: green, orange above 85 %, red when over.
class BudgetBar extends StatelessWidget {
  final int spent, budget;
  const BudgetBar({super.key, required this.spent, required this.budget});
  @override
  Widget build(BuildContext context) {
    final pal = Palette.of(context);
    final f = budget > 0 ? (spent / budget).clamp(0.0, 1.0) : 0.0;
    final color = spent > budget ? pal.over : (f > 0.85 ? pal.warn : Theme.of(context).colorScheme.primary);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(value: f, minHeight: 6, color: color, backgroundColor: pal.track),
    );
  }
}

class SectionCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  final EdgeInsets padding;
  const SectionCard({super.key, this.title, required this.children, this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 14)});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(title!, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ...children,
          ],
        ),
      ),
    );
  }
}

class Muted extends StatelessWidget {
  final String text;
  final TextAlign? align;
  const Muted(this.text, {super.key, this.align});
  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: align,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Palette.of(context).muted),
  );
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2), behavior: SnackBarBehavior.floating));
}

Future<bool> confirm(BuildContext context, String title, String body, String action) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(
          key: const Key('confirmYes'),
          onPressed: () => Navigator.pop(c, true),
          style: TextButton.styleFrom(foregroundColor: Palette.of(c).over),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// A small line chart of prices over time (no chart library needed).
class Sparkline extends StatelessWidget {
  final List<int> values;
  final double width, height;
  final bool dots;
  const Sparkline({super.key, required this.values, this.width = 56, this.height = 24, this.dots = false});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(width, height), painter: _SparkPainter(values, Theme.of(context).colorScheme.primary, dots));
}

class _SparkPainter extends CustomPainter {
  final List<int> values;
  final Color color;
  final bool dots;
  _SparkPainter(this.values, this.color, this.dots);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce((a, b) => a < b ? a : b), hi = values.reduce((a, b) => a > b ? a : b);
    Offset at(int i) {
      final x = i / (values.length - 1) * (size.width - 4) + 2;
      final y = hi == lo ? size.height / 2 : size.height - 3 - (values[i] - lo) / (hi - lo) * (size.height - 6);
      return Offset(x, y);
    }

    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    if (dots) {
      for (var i = 0; i < values.length; i++) {
        canvas.drawCircle(at(i), 3, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.values != values || old.color != color;
}
