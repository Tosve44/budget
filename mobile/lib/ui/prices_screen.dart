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

  /// The shop picked with the chips (null = all shops).
  String? shop;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final all = PriceHistory.list(model.store.data.transactions, search: search);
    // Shops seen on receipts. Prices differ from shop to shop, so each % is worked out between
    // purchases at the same shop; a chip shows one shop only.
    final shops = PriceHistory.stores(PriceHistory.groups(model.store.data.transactions).values);
    if (shop != null && !shops.any((s) => PriceHistory.sameStore(s, shop))) shop = null;
    final pick = shop;
    final groups = pick == null
        ? all
        : ([
            for (final g in all)
              if (g.entries.any((e) => PriceHistory.sameStore(e.store, pick)))
                PriceGroup(g.key, g.name, g.entries.where((e) => PriceHistory.sameStore(e.store, pick)).toList()),
          ]..sort((a, b) => a.latest.date != b.latest.date ? b.latest.date.compareTo(a.latest.date) : a.key.compareTo(b.key)));
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
          if (shops.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Row(
                children: [
                  for (final s in [null, ...shops])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        key: Key('shop.${s ?? ''}'),
                        label: Text(s ?? 'All shops'),
                        selected: s == null ? pick == null : (pick != null && PriceHistory.sameStore(s, pick)),
                        onSelected: (_) => setState(() => shop = s),
                      ),
                    ),
                ],
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
                const Muted('Newest first. The % is the change since the first time you bought it at the same shop, per piece or per kg.'),
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
    final tr = g.trend(); // at the shop of the newest purchase
    final last = tr.last!;
    final prev = tr.entries.length > 1 ? tr.entries[tr.entries.length - 2] : null;
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
                      '${tr.store.isNotEmpty ? '${tr.store} · ' : ''}${tr.entries.length}× · last ${shortDay(last.date)}'
                      '${prev != null ? ' · before ${model.money(prev.price)}${prev.unit == 'kg' ? '/kg' : ''}' : ''}',
                      key: const Key('priceMeta'),
                    ),
                  ],
                ),
              ),
              if (tr.entries.length > 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Sparkline(values: tr.entries.map((e) => e.price).toList()),
                ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${model.money(last.price)}${last.unit == 'kg' ? '/kg' : ''}',
                    key: const Key('priceLatest'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  ChangeBadge(percent: tr.change, single: g.entries.length == 1),
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
    final tr = group.trend();
    final change = tr.change;
    return Scaffold(
      appBar: AppBar(title: Text(group.name, overflow: TextOverflow.ellipsis)),
      body: ListView(
        children: [
          if (tr.entries.length > 1)
            SectionCard(
              title: tr.store.isNotEmpty ? 'At ${tr.store}' : null,
              children: [
                LayoutBuilder(
                  builder: (context, c) =>
                      Sparkline(values: tr.entries.map((e) => e.price).toList(), width: c.maxWidth, height: 160, dots: true),
                ),
                if (change != null) ...[
                  const SizedBox(height: 8),
                  Text('Since the first purchase${tr.store.isNotEmpty ? ' at ${tr.store}' : ''}: ${change > 0 ? '+' : ''}${pct(change)}%'),
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
                      Expanded(child: Text('${dayLabel(e.date)}${e.store.isNotEmpty ? ' · ${e.store}' : ''}')),
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
