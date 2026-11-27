import 'package:flutter/material.dart';

import '../core/prices.dart';
import 'home.dart';
import 'widgets.dart';

/// Every item from your receipts with its price over time (grocery price inflation).
class PricesScreen extends StatefulWidget {
  const PricesScreen({super.key});
  @override
  State<PricesScreen> createState() => _PricesScreenState();
}

class _PricesScreenState extends State<PricesScreen> {
  String search = '';

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final groups = PriceHistory.list(model.store.data.transactions, search: search);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prices', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              key: const Key('priceSearch'),
              decoration: InputDecoration(
                hintText: 'Search items',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                isDense: true,
              ),
              onChanged: (v) => setState(() => search = v),
            ),
          ),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Muted(
                search.isEmpty
                    ? 'No items yet. Take a receipt photo when adding an expense, and its items show up here.'
                    : 'No matches. Try another word.',
                align: TextAlign.center,
              ),
            )
          else
            SectionCard(
              title: 'Grocery prices over time',
              children: [
                const Muted('Newest first. The % is the change since the first time you bought it, per piece or per kg.'),
                const SizedBox(height: 6),
                for (final g in groups) _row(context, g),
              ],
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, PriceGroup g) {
    final model = ModelScope.of(context);
    final prev = g.previous;
    return KeyedSubtree(
      key: ValueKey(g.key),
      child: InkWell(
        key: const Key('priceRow'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PriceDetail(group: g))),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.name, overflow: TextOverflow.ellipsis),
                    Muted(
                      '${g.entries.length}× · last ${shortDay(g.latest.date)}${prev != null ? ' · before ${model.money(prev.price)}${prev.unit == 'kg' ? '/kg' : ''}' : ''}',
                    ),
                  ],
                ),
              ),
              if (g.entries.length > 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Sparkline(values: g.entries.map((e) => e.price).toList()),
                ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${model.money(g.latest.price)}${g.latest.unit == 'kg' ? '/kg' : ''}',
                    key: const Key('priceLatest'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  ChangeBadge(percent: g.changeSinceFirst, single: g.entries.length == 1),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChangeBadge extends StatelessWidget {
  final double? percent;
  final bool single;
  const ChangeBadge({super.key, required this.percent, required this.single});
  @override
  Widget build(BuildContext context) {
    final pal = Palette.of(context);
    final p = percent;
    final (String text, Color color) = single || p == null
        ? ('new', pal.muted)
        : p == 0
        ? ('same', pal.muted)
        : p > 0
        ? ('▲ +${pct(p)}%', pal.over)
        : ('▼ ${pct(p)}%', pal.income);
    return Text(
      text,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
    );
  }
}

class PriceDetail extends StatelessWidget {
  final PriceGroup group;
  const PriceDetail({super.key, required this.group});
  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final change = group.changeSinceFirst;
    return Scaffold(
      appBar: AppBar(title: Text(group.name, overflow: TextOverflow.ellipsis)),
      body: ListView(
        children: [
          if (group.entries.length > 1)
            SectionCard(
              children: [
                LayoutBuilder(
                  builder: (context, c) =>
                      Sparkline(values: group.entries.map((e) => e.price).toList(), width: c.maxWidth, height: 160, dots: true),
                ),
                if (change != null) ...[
                  const SizedBox(height: 8),
                  Text('Since the first purchase: ${change > 0 ? '+' : ''}${pct(change)}%'),
                ],
              ],
            ),
          SectionCard(
            title: 'History',
            children: [
              for (final e in group.entries.reversed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(child: Text(dayLabel(e.date))),
                      Text('${model.money(e.price)}${e.unit == 'kg' ? '/kg' : ''}'),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
