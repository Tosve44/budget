import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_model.dart';
import '../core/category_icons.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/prices.dart';
import '../core/sync.dart';
import 'home.dart';
import 'sharing_screen.dart';
import 'widgets.dart';

const currencies = ['EUR', 'RSD', 'BAM', 'USD', 'CHF', 'GBP'];

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  String syncStatus(AppModel model) {
    final s = model.sync;
    if (s == null) return 'Not set up';
    if (!s.isConnected) return 'Off';
    return switch (s.state) {
      SyncState.syncing => 'Syncing…',
      SyncState.error => 'Offline',
      _ => s.pendingCount > 0 ? 'Waiting' : 'On',
    };
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final store = model.store;
    final connected = model.sync?.isConnected == true;
    final personal = store.personalSpace();
    final house = store.houseSpace;
    final transfer = store.suggestedPartnerTransfer(DateKey.month());
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        key: const Key('settingsList'),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SectionCard(
            title: connected ? 'Signed in as ${store.currentUser.name}' : 'Who is using this phone',
            children: [
              if (!connected)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final u in store.data.users)
                      ChoiceChip(
                        key: Key('user.${u.name}'),
                        label: Text(u.name),
                        selected: u.id == store.currentUser.id,
                        onSelected: (_) {
                          store.setCurrentUser(u.id);
                          toast(context, 'Switched to ${u.name}');
                        },
                      ),
                  ],
                ),
              Muted(
                connected
                    ? 'Your Personal space is private. The House space is shared.'
                    : 'Each person has their own Personal space. The House space is shared once you set up sharing below.',
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Names'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => push(const NamesScreen()),
              ),
            ],
          ),
          SectionCard(
            title: 'Share with partner',
            children: [
              ListTile(
                key: const Key('sharing'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Sharing'),
                subtitle: Text(syncStatus(model)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => push(const SharingScreen()),
              ),
            ],
          ),
          SectionCard(
            title: 'Appearance',
            children: [
              SegmentedButton<Appearance>(
                key: const Key('appearancePicker'),
                segments: [for (final a in Appearance.values) ButtonSegment(value: a, label: Text(a.title))],
                selected: {model.appearance},
                showSelectedIcon: false,
                onSelectionChanged: (s) => model.appearance = s.first,
              ),
              const SizedBox(height: 6),
              const Muted("Automatic follows the phone's light or dark setting. This choice is kept on this phone only."),
            ],
          ),
          SectionCard(
            title: 'Categories and monthly budgets',
            children: [
              if (personal != null)
                ListTile(
                  key: const Key('editPersonalCategories'),
                  contentPadding: EdgeInsets.zero,
                  title: Text("${store.currentUser.name}'s personal categories"),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => push(CategoriesScreen(spaceId: personal.id)),
                ),
              if (house != null)
                ListTile(
                  key: const Key('editHouseCategories'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('House categories'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => push(CategoriesScreen(spaceId: house.id)),
                ),
            ],
          ),
          SectionCard(
            title: 'Partner balance',
            children: [
              if (transfer != null && store.user(transfer.fromUserId) != null && store.user(transfer.toUserId) != null)
                Text(
                  '${store.user(transfer.fromUserId)!.name} sends ${store.user(transfer.toUserId)!.name} ${model.money(transfer.amount)} this month, so both have the same personal money.',
                  key: const Key('partnerBalanceText'),
                )
              else
                const Muted("Add both people's income (Salary) in their Personal space to see how much to send."),
              const SizedBox(height: 4),
              const Muted('Based on this month\'s personal income on this phone. Record the transfer as a "Partner balance" expense.'),
            ],
          ),
          SectionCard(
            title: 'Currency',
            children: [
              DropdownButton<String>(
                key: const Key('currency'),
                value: currencies.contains(model.currency) ? model.currency : null,
                isExpanded: true,
                items: [for (final c in currencies) DropdownMenuItem(value: c, child: Text(c))],
                onChanged: (c) async {
                  if (c == null) return;
                  store.setCurrency(c);
                  final s = model.sync;
                  if (s != null && s.isConnected) {
                    try {
                      await s.setCurrency(c);
                    } catch (e) {
                      if (context.mounted) toast(context, '$e');
                    }
                  }
                },
              ),
            ],
          ),
          SectionCard(
            title: 'Backup',
            children: [
              OutlinedButton(
                key: const Key('exportBackup'),
                onPressed: () => exportBackup(context),
                child: const Text('Save a backup file'),
              ),
              const SizedBox(height: 6),
              OutlinedButton(
                key: const Key('importBackup'),
                onPressed: () => importBackup(context),
                child: const Text('Restore from a backup file'),
              ),
              const SizedBox(height: 6),
              const Muted('The backup file works with the web app and the iPhone app too. Receipt photos are not included.'),
            ],
          ),
          SectionCard(
            title: 'Version',
            children: [
              Text(model.plan == Plan.full ? 'Full version' : 'Free version'),
              if (model.plan == Plan.free)
                Muted(
                  'The free version has ${PlanRules.freePersonalExpenses.length} personal and ${PlanRules.freeHouseExpenses.length} house categories. The full version has all categories and your own.',
                ),
              if (AppConfig.everyoneHasFullVersion) const Muted('While testing, everyone has the full version for free.'),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: OutlinedButton(
              key: const Key('resetAll'),
              style: OutlinedButton.styleFrom(foregroundColor: Palette.of(context).over),
              onPressed: () async {
                final s = model.sync;
                final ok = await confirm(
                  context,
                  'Erase everything?',
                  s?.isConnected == true
                      ? 'This signs you out and erases the data on this phone. Your data in your account stays, and comes back when you sign in again.'
                      : 'All entries and category changes on this phone will be deleted. Save a backup first if you want to keep them.',
                  'Erase',
                );
                if (!ok) return;
                if (s != null && s.isConnected) await s.signOut();
                store.reset();
                if (context.mounted) toast(context, 'Erased');
              },
              child: const Text('Erase everything on this phone'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> exportBackup(BuildContext context) async {
    final model = ModelScope.read(context);
    // Where the share sheet points from on an iPad.
    final box = context.findRenderObject() as RenderBox?;
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/budget-backup-${DateKey.day()}.json');
      await f.writeAsString(model.store.exportJson());
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(f.path, mimeType: 'application/json')],
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (context.mounted) toast(context, 'Could not make the backup: $e');
    }
  }

  Future<void> importBackup(BuildContext context) async {
    final model = ModelScope.read(context);
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isEmpty || !context.mounted) return;
      final bytes = await files.first.readAsBytes();
      if (!context.mounted) return;
      final ok = await confirm(context, 'Restore this backup?', 'Everything on this phone is replaced with the backup.', 'Replace');
      if (!ok) return;
      model.store.importJson(utf8.decode(bytes, allowMalformed: true));
      if (context.mounted) toast(context, 'Backup restored');
    } catch (e) {
      if (context.mounted) toast(context, e is BudgetError ? e.message : 'Could not read that file');
    }
  }
}

class NamesScreen extends StatefulWidget {
  const NamesScreen({super.key});
  @override
  State<NamesScreen> createState() => _NamesScreenState();
}

class _NamesScreenState extends State<NamesScreen> {
  final fields = <String, TextEditingController>{};

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void save(AppModel model, String id) {
    final n = fields[id]!.text.trim();
    if (n.isEmpty || n == model.store.user(id)?.name) return;
    model.store.renameUser(id, n);
    final s = model.sync;
    if (id == model.store.currentUser.id && s != null && s.isConnected) s.rename(n).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.read(context);
    final users = model.store.data.users;
    final connected = model.sync?.isConnected == true;
    return PopScope(
      onPopInvokedWithResult: (_, _) {
        for (final id in fields.keys) {
          save(model, id);
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Names')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final u in users)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  key: Key('name.${u.id}'),
                  controller: fields.putIfAbsent(u.id, () => TextEditingController(text: u.name)),
                  // When sharing, each person changes only their own name.
                  enabled: !connected || u.id == model.store.currentUser.id,
                  maxLength: Limits.personName,
                  decoration: InputDecoration(labelText: u.id == model.store.currentUser.id ? 'Your name' : 'Partner'),
                  onSubmitted: (_) => save(model, u.id),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class CategoriesScreen extends StatelessWidget {
  final String spaceId;
  const CategoriesScreen({super.key, required this.spaceId});

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final store = model.store;
    final space = store.space(spaceId);
    return Scaffold(
      appBar: AppBar(title: Text(space?.type == SpaceType.house ? 'House categories' : 'Personal categories')),
      body: CustomScrollView(
        slivers: [
          for (final kind in EntryKind.values) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(kind == EntryKind.expense ? 'Expenses' : 'Income', style: Theme.of(context).textTheme.titleSmall)),
                    const Flexible(child: Muted('Hold and drag to reorder', align: TextAlign.end)),
                  ],
                ),
              ),
            ),
            SliverReorderableList(
              itemCount: store.categories(spaceId, includeArchived: true, kind: kind).length,
              onReorderItem: (from, to) {
                final ids = store.categories(spaceId, includeArchived: true, kind: kind).map((c) => c.id).toList();
                final id = ids.removeAt(from);
                ids.insert(to, id);
                store.reorderCategories(spaceId, kind, ids);
              },
              itemBuilder: (context, i) {
                final c = store.categories(spaceId, includeArchived: true, kind: kind)[i];
                final locked = !PlanRules.isAvailable(c, space, model.plan);
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(c.id),
                  index: i,
                  child: Material(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: ListTile(
                      key: Key('categoryRow.${c.name}'),
                      leading: Text(CategoryIcons.of(c), style: const TextStyle(fontSize: 22)),
                      title: Text(c.name, style: TextStyle(color: c.archived ? Palette.of(context).muted : null)),
                      subtitle: Text(
                        c.archived
                            ? 'Hidden'
                            : kind == EntryKind.expense
                            ? (c.budget > 0 ? 'Budget ${model.money(c.budget)} / month' : 'No budget')
                            : 'Income',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (locked) const Icon(Icons.lock_outline, size: 16),
                          ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                        ],
                      ),
                      onTap: () => showCategoryEditor(context, spaceId: spaceId, kind: kind, category: c),
                    ),
                  ),
                );
              },
            ),
            if (PlanRules.canAddCustomCategory(model.plan))
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: Key('addCategory.${kind.name}'),
                      onPressed: () => showCategoryEditor(context, spaceId: spaceId, kind: kind),
                      icon: const Icon(Icons.add),
                      label: Text('Add ${kind.name} category'),
                    ),
                  ),
                ),
              ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

Future<void> showCategoryEditor(BuildContext context, {required String spaceId, required EntryKind kind, Category? category}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: CategoryEditor(spaceId: spaceId, kind: kind, category: category),
    ),
  );
}

class CategoryEditor extends StatefulWidget {
  final String spaceId;
  final EntryKind kind;
  final Category? category;
  const CategoryEditor({super.key, required this.spaceId, required this.kind, this.category});
  @override
  State<CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends State<CategoryEditor> {
  late final name = TextEditingController(text: widget.category?.name ?? '');
  late final budget = TextEditingController(text: Money.inputText(widget.category?.budget ?? 0));
  String? problem;

  /// The picked icon; empty means the default icon for the name.
  late String icon = widget.category?.icon.trim() ?? '';
  bool pickingIcon = false;

  @override
  void dispose() {
    name.dispose();
    budget.dispose();
    super.dispose();
  }

  void save() {
    final model = ModelScope.read(context);
    final n = name.text.trim();
    if (n.isEmpty) return setState(() => problem = 'Enter a name.');
    if (model.store.categoryNameTaken(n, widget.spaceId, widget.kind, excluding: widget.category?.id)) {
      return setState(() => problem = 'There is already a category called "$n".');
    }
    if (Limits.length(n) > Limits.categoryName) {
      return setState(() => problem = 'The name is too long (at most ${Limits.categoryName} characters).');
    }
    final t = budget.text.trim();
    final b = t.isEmpty ? 0 : Money.cents(t);
    if (b == null || b < 0) return setState(() => problem = 'The budget must be a number.');
    if (b > Limits.maxCents) return setState(() => problem = 'That budget is too big.');
    final c = widget.category;
    if (c != null) {
      model.store.updateCategory(c.id, name: n, budget: widget.kind == EntryKind.expense ? b : null, icon: icon);
    } else {
      model.store.addCategory(
        spaceId: widget.spaceId,
        name: n,
        kind: widget.kind,
        budget: widget.kind == EntryKind.expense ? b : 0,
        icon: icon,
      );
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.read(context);
    final c = widget.category;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(c == null ? 'New category' : 'Edit category', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            key: const Key('categoryName'),
            controller: name,
            autofocus: c == null,
            enabled: c == null || PlanRules.canRenameCategory(model.plan),
            decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Pets'),
          ),
          if (widget.kind == EntryKind.expense)
            TextField(
              key: const Key('categoryBudget'),
              controller: budget,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Monthly budget (leave empty for none)'),
            ),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: name,
            builder: (context, _) => ListTile(
              key: const Key('iconField'),
              contentPadding: EdgeInsets.zero,
              leading: Text(
                icon.isNotEmpty ? icon : CategoryIcons.forName(name.text),
                key: const Key('iconShown'),
                style: const TextStyle(fontSize: 26),
              ),
              title: const Text('Icon'),
              subtitle: Text(icon.isEmpty ? 'Default for this name' : 'Picked'),
              trailing: Text(pickingIcon ? 'Done' : 'Change'),
              onTap: () => setState(() => pickingIcon = !pickingIcon),
            ),
          ),
          if (pickingIcon)
            Wrap(
              key: const Key('iconChoices'),
              spacing: 4,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  key: const Key('iconDefault'),
                  label: const Text('Default'),
                  selected: icon.isEmpty,
                  onSelected: (_) => setState(() => icon = ''),
                ),
                for (final e in CategoryIcons.choices)
                  ChoiceChip(
                    key: Key('iconChoice.$e'),
                    label: Text(e, style: const TextStyle(fontSize: 20)),
                    showCheckmark: false,
                    selected: icon == e,
                    onSelected: (_) => setState(() => icon = e),
                  ),
              ],
            ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                problem!,
                key: const Key('categoryProblem'),
                style: TextStyle(color: Palette.of(context).over),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(key: const Key('saveCategory'), onPressed: save, child: const Text('Save')),
          TextButton(key: const Key('cancelCategory'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          if (c != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('toggleHidden'),
              onPressed: () {
                model.store.updateCategory(c.id, archived: !c.archived);
                Navigator.pop(context);
              },
              child: Text(c.archived ? 'Show again' : 'Hide category'),
            ),
            const SizedBox(height: 4),
            const Muted('Hiding keeps past entries but removes the category from lists and the add screen.'),
          ],
        ],
      ),
    );
  }
}
