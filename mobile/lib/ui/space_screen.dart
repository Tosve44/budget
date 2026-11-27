import 'package:flutter/material.dart';

import '../core/category_icons.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/store.dart';
import '../core/sync.dart';
import 'entry_editor.dart';
import 'home.dart';
import 'widgets.dart';

/// One space (your Personal space, or the shared House space) for one month: what is left of
/// the budget, spending per category and all entries.
class SpaceScreen extends StatefulWidget {
  final SpaceType type;
  const SpaceScreen({super.key, required this.type});
  @override
  State<SpaceScreen> createState() => _SpaceScreenState();
}

class _SpaceScreenState extends State<SpaceScreen> {
  String month = DateKey.month();
  String? filterCategoryId;

  /// New entries get today's date, or the 1st when looking at another month.
  String get defaultDate => month == DateKey.month() ? DateKey.day() : '$month-01';

  Future<void> openEditor(Space space, {Transaction? edit, EntryKind kind = EntryKind.expense}) async {
    final saved = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => EntryEditor(draftSpaceId: space.id, editing: edit, kind: kind, defaultDate: defaultDate),
      ),
    );
    // After saving, show the month the entry is in.
    if (saved != null && mounted) setState(() => month = saved.substring(0, 7));
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final store = model.store;
    final space = widget.type == SpaceType.house ? store.houseSpace : store.personalSpace();
    final title = widget.type == SpaceType.house ? 'House' : 'Personal';
    final sync = model.sync;
    var badge = '';
    if (sync != null && sync.isConnected) {
      badge = sync.state == SyncState.syncing
          ? ' · syncing…'
          : sync.state == SyncState.error
          ? ' · offline'
          : (sync.pendingCount > 0 ? ' · saving…' : ' · synced');
    }
    final who = store.currentUser.name + badge;
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: Muted(who, key: const Key('who'))),
          ),
        ],
      ),
      floatingActionButton: space == null
          ? null
          : FloatingActionButton(
              key: const Key('addEntry'),
              heroTag: 'add-${widget.type.name}',
              tooltip: 'Add entry',
              onPressed: () => openEditor(space),
              child: const Icon(Icons.add),
            ),
      body: space == null
          ? const Center(child: Text('No space'))
          : RefreshIndicator(onRefresh: model.syncIfConnected, child: _content(context, store, space)),
    );
  }

  Widget _content(BuildContext context, BudgetStore store, Space space) {
    final model = ModelScope.of(context);
    final sum = store.monthSummary(space.id, month);
    final expenseCats = store.categories(space.id, kind: EntryKind.expense);
    final incomeCats = store.categories(space.id, kind: EntryKind.income);
    // Only categories with a budget or activity this month, to keep the list short.
    final activeExpense = expenseCats.where((c) => c.budget > 0 || sum.byCategory.containsKey(c.id)).toList();
    final activeIncome = incomeCats.where((c) => sum.byCategory.containsKey(c.id)).toList();
    final filter = filterCategoryId == null ? null : store.category(filterCategoryId!);
    final entries = store.transactions(space.id, month: month).where((t) => filter == null || t.categoryId == filter.id).toList();

    Widget catRow(Category c) {
      final spent = sum.byCategory[c.id] ?? 0;
      final selected = filterCategoryId == c.id;
      return InkWell(
        key: Key('category.${c.name}'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => filterCategoryId = selected ? null : c.id),
        child: Container(
          decoration: BoxDecoration(color: selected ? Palette.of(context).accentSoft : null, borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(CategoryIcons.of(c), key: Key('categoryIcon.${c.name}')),
                  const SizedBox(width: 6),
                  Expanded(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 2,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: model.money(spent)),
                          if (c.kind == EntryKind.expense && c.budget > 0)
                            TextSpan(
                              text: ' / ${model.money(c.budget)}',
                              style: TextStyle(color: Palette.of(context).muted, fontSize: 12),
                            ),
                        ],
                      ),
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
                ],
              ),
              if (c.kind == EntryKind.expense && c.budget > 0) ...[const SizedBox(height: 6), BudgetBar(spent: spent, budget: c.budget)],
            ],
          ),
        ),
      );
    }

    return ListView(
      key: const Key('spaceList'),
      padding: const EdgeInsets.only(bottom: 96),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        MonthSwitcher(
          month: month,
          onChange: (m) => setState(() {
            month = m;
            filterCategoryId = null;
          }),
        ),
        SummaryCard(
          sum: sum,
          onAdd: (kind) => openEditor(space, kind: kind),
        ),
        SectionCard(
          title: 'Spending by category',
          children: [if (activeExpense.isEmpty) const Muted('Nothing spent yet this month.'), ...activeExpense.map(catRow)],
        ),
        if (activeIncome.isNotEmpty) SectionCard(title: 'Income', children: activeIncome.map(catRow).toList()),
        SectionCard(
          title: filter == null ? 'All entries' : 'Entries',
          children: [
            if (filter != null)
              Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  key: const Key('clearFilter'),
                  label: Text(filter.name),
                  onDeleted: () => setState(() => filterCategoryId = null),
                  onPressed: () => setState(() => filterCategoryId = null),
                ),
              ),
            if (entries.isEmpty) const Muted('No entries yet. Tap + to add one.'),
            ...entries.map(
              (t) => EntryRow(
                entry: t,
                showWho: space.type == SpaceType.house,
                onTap: () => openEditor(space, edit: t),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class MonthSwitcher extends StatelessWidget {
  final String month;
  final ValueChanged<String> onChange;
  const MonthSwitcher({super.key, required this.month, required this.onChange});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            key: const Key('prevMonth'),
            tooltip: 'Previous month',
            onPressed: () => onChange(DateKey.shiftMonth(month, -1)),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Text(
              monthLabel(month),
              key: const Key('monthTitle'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            key: const Key('nextMonth'),
            tooltip: 'Next month',
            onPressed: () => onChange(DateKey.shiftMonth(month, 1)),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

class SummaryCard extends StatelessWidget {
  final MonthSummary sum;

  /// Tapping Income or Spent opens the add screen for that kind of entry.
  final ValueChanged<EntryKind> onAdd;
  const SummaryCard({super.key, required this.sum, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final pal = Palette.of(context);
    final big = Theme.of(context).textTheme.headlineMedium
        ?.copyWith(fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]);
    final balance = sum.balance;
    return SectionCard(
      children: [
        if (sum.budget > 0) ...[
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 12,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Muted(sum.left >= 0 ? 'Left this month' : 'Over budget'),
                  Text(
                    model.money(sum.left.abs()),
                    key: const Key('leftAmount'),
                    style: big?.copyWith(color: sum.left < 0 ? pal.over : null),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Muted('${(sum.spent / sum.budget * 100).round()}% of ${model.money(sum.budget)}', key: const Key('budgetUsed')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          BudgetBar(spent: sum.spent, budget: sum.budget),
        ] else ...[
          const Muted('Spent this month'),
          Text(model.money(sum.spent), key: const Key('spentAmount'), style: big),
          const Muted('No monthly budget set yet. Add one per category in Settings.'),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Stat(
                key: const Key('addIncome'),
                label: 'Income',
                value: model.money(sum.income),
                color: pal.income,
                onTap: () => onAdd(EntryKind.income),
                hint: 'Adds income',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Stat(
                key: const Key('addExpense'),
                label: 'Spent',
                value: model.money(sum.spent),
                onTap: () => onAdd(EntryKind.expense),
                hint: 'Adds an expense',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Stat(
                key: const Key('balance'),
                label: 'Balance',
                value:
                    '${balance > 0
                        ? '+'
                        : balance < 0
                        ? '−'
                        : ''}${model.money(balance.abs())}',
                color: balance < 0 ? pal.over : (balance > 0 ? pal.income : null),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value;
  final Color? color;
  final VoidCallback? onTap;
  final String? hint;
  const _Stat({super.key, required this.label, required this.value, this.color, this.onTap, this.hint});
  @override
  Widget build(BuildContext context) {
    final pal = Palette.of(context);
    final content = Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: pal.track.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(child: Muted(label)),
              if (onTap != null) ...[
                const SizedBox(width: 2),
                Icon(Icons.add_circle_outline, size: 14, color: Theme.of(context).colorScheme.primary),
              ],
            ],
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              key: Key('stat.$label'),
              style: TextStyle(fontWeight: FontWeight.w600, color: color, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
    final semantics = Semantics(button: onTap != null, label: label, value: value, hint: hint, excludeSemantics: true, child: content);
    if (onTap == null) return semantics;
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap, child: semantics),
    );
  }
}

class EntryRow extends StatelessWidget {
  final Transaction entry;
  final bool showWho;
  final VoidCallback onTap;
  const EntryRow({super.key, required this.entry, required this.showWho, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final store = model.store;
    final pal = Palette.of(context);
    final items = entry.items;
    final meta = [
      dayLabel(entry.date),
      if (items != null && items.isNotEmpty) '🧾 ${items.length} items' else if (entry.receiptId != null) '🧾',
      if (entry.note.isNotEmpty) entry.note,
      if (showWho && store.user(entry.createdBy) != null) store.user(entry.createdBy)!.name,
    ].join(' · ');
    final income = entry.kind == EntryKind.income;
    return InkWell(
      key: const Key('entry'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                store.category(entry.categoryId) == null ? CategoryIcons.fallback : CategoryIcons.of(store.category(entry.categoryId)!),
                key: const Key('entryIcon'),
                style: const TextStyle(fontSize: 18),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(store.category(entry.categoryId)?.name ?? 'Deleted category', overflow: TextOverflow.ellipsis),
                  Muted(meta),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${income ? '+' : '−'}${model.money(entry.amount)}',
              key: const Key('entryAmount'),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: income ? pal.income : null,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
