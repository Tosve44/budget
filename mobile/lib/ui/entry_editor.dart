import 'package:flutter/material.dart';

import '../core/category_icons.dart';
import '../core/entry_draft.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/premium.dart';
import '../core/prices.dart';
import '../core/store.dart';
import 'home.dart';
import 'premium_screen.dart';
import 'settings_screen.dart';
import 'widgets.dart';

/// Add or change an entry. A receipt photo fills in the items and the total.
/// Returns (via Navigator.pop) the saved entry's date, or null when nothing was saved.
class EntryEditor extends StatefulWidget {
  final String draftSpaceId;
  final Transaction? editing;
  final EntryKind kind;
  final String defaultDate;
  const EntryEditor({super.key, required this.draftSpaceId, this.editing, this.kind = EntryKind.expense, required this.defaultDate});
  @override
  State<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<EntryEditor> {
  late final EntryDraft draft;
  final amount = TextEditingController();
  final note = TextEditingController();
  final shop = TextEditingController();
  final List<(TextEditingController, TextEditingController)> lineFields = [];
  String? problem;
  bool reading = false;
  String? readNote;
  bool saving = false;
  final amountFocus = FocusNode();
  final scroll = ScrollController();

  bool get isNew => widget.editing == null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    draft = e != null ? EntryDraft.editing(e) : EntryDraft(spaceId: widget.draftSpaceId, kind: widget.kind, date: widget.defaultDate);
    amount.text = draft.amountText;
    note.text = draft.note;
    shop.text = draft.store;
    _syncLineFields();
    if (isNew) WidgetsBinding.instance.addPostFrameCallback((_) => amountFocus.requestFocus());
  }

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    shop.dispose();
    amountFocus.dispose();
    scroll.dispose();
    for (final (a, b) in lineFields) {
      a.dispose();
      b.dispose();
    }
    super.dispose();
  }

  void _syncLineFields() {
    for (final (a, b) in lineFields) {
      a.dispose();
      b.dispose();
    }
    lineFields
      ..clear()
      ..addAll(draft.lines.map((l) => (TextEditingController(text: l.name), TextEditingController(text: l.priceText))));
  }

  List<Category> categories() {
    final model = ModelScope.read(context);
    final list = model.store.pickableCategories(draft.spaceId, draft.kind, model.plan);
    // When editing, keep showing the entry's category even if it is hidden now.
    final id = draft.categoryId;
    if (id != null && !list.any((c) => c.id == id)) {
      final c = model.store.category(id);
      if (c != null && c.kind == draft.kind) list.insert(0, c);
    }
    return list;
  }

  Future<void> pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: DateKey.parseDay(draft.date) ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (d != null) setState(() => draft.date = DateKey.day(d));
  }

  Future<void> addPhoto({required bool camera}) async {
    final model = ModelScope.read(context);
    final jpeg = await model.picker.pick(camera: camera);
    if (jpeg == null || !mounted) return;
    setState(() {
      reading = true;
      readNote = null;
    });
    final old = draft.receiptId;
    final id = model.photos.save(jpeg);
    if (old != null && !old.startsWith('cloud:') && old != widget.editing?.receiptId) model.photos.delete(old);
    draft.receiptId = id;
    try {
      final text = await model.reader.read(model.photos.file(id)!.path);
      if (!mounted) return;
      _readLines();
      final n = draft.applyReceiptText(text);
      amount.text = draft.amountText;
      shop.text = draft.store;
      _syncLineFields();
      if (draft.categoryId == null) {
        final g = categories().where((c) => c.name == 'Groceries').firstOrNull;
        if (g != null) draft.categoryId = g.id;
      }
      final mm = draft.mismatch;
      readNote = n == 0
          ? 'No items found. Try a straighter photo with good light, or type them in.'
          : mm != null
          ? '⚠️ Found $n item${n == 1 ? '' : 's'}. They add up to ${model.money(mm.$1)}, but the receipt total is ${model.money(mm.$2)}: a price may be misread (or there is a discount). Check the prices.'
          : 'Found $n item${n == 1 ? '' : 's'}. Check them; tap to fix a name or price.';
    } catch (e) {
      readNote = 'Could not read the text. You can still type the items, and the photo is kept.';
    }
    if (mounted) setState(() => reading = false);
  }

  /// Copies what is typed in the fields into the draft.
  void _readLines() {
    draft.amountText = amount.text;
    draft.note = note.text;
    draft.store = shop.text;
    for (var i = 0; i < lineFields.length && i < draft.lines.length; i++) {
      draft.lines[i]
        ..name = lineFields[i].$1.text
        ..priceText = lineFields[i].$2.text;
    }
  }

  void save() {
    if (saving) return; // a double tap must not save twice
    final model = ModelScope.read(context);
    _readLines();
    try {
      final deletedMeanwhile = draft.wasDeletedMeanwhile(model.store);
      saving = true;
      final t = draft.save(model.store);
      if (deletedMeanwhile) {
        showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            scrollable: true,
            title: const Text('Saved as a new entry'),
            content: const Text('This entry was deleted on the other phone while you were changing it, so your version was added again.'),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
          ),
        ).then((_) {
          if (mounted) Navigator.pop(context, t.date);
        });
      } else {
        Navigator.pop(context, t.date);
      }
    } on DraftProblem catch (e) {
      saving = false;
      setState(() => problem = e.message);
      // The message sits under the amount; on a small phone the bottom Save button is far below it.
      if (scroll.hasClients && scroll.offset > 0) {
        scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    }
  }

  Future<void> delete() async {
    final model = ModelScope.read(context);
    if (!await confirm(context, 'Delete this entry?', 'It is removed on both phones.', 'Delete')) return;
    final id = draft.existingId;
    // Without syncing nothing else needs the photo; with syncing it is removed after the upload.
    final rid = widget.editing?.receiptId;
    if (rid != null && !rid.startsWith('cloud:') && !(model.sync?.isConnected ?? false)) model.photos.delete(rid);
    if (id != null) model.store.deleteTransaction(id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> newCategory() async {
    final model = ModelScope.read(context);
    _readLines();
    // Categories of your own are part of Premium.
    if (!PlanRules.canAddCustomCategory(model.plan)) return openPremium(context, because: PremiumFeature.categories);
    final id = await showCategoryEditor(context, spaceId: draft.spaceId, kind: draft.kind, pickExisting: true);
    if (id == null || !mounted) return;
    setState(() {
      draft.categoryId = id;
      problem = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final pal = Palette.of(context);
    final cats = categories();
    final space = model.store.space(draft.spaceId);
    final spaceName = space?.type == SpaceType.house ? 'House' : 'Personal';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Cancel', onPressed: () => Navigator.pop(context)),
        title: Text(isNew ? (draft.kind == EntryKind.income ? 'New income · $spaceName' : 'New expense · $spaceName') : 'Edit entry'),
        actions: [
          TextButton(
            key: const Key('saveEntry'),
            onPressed: save,
            child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('editorList'),
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            SegmentedButton<EntryKind>(
              key: const Key('kindPicker'),
              segments: const [
                ButtonSegment(value: EntryKind.expense, label: Text('Expense')),
                ButtonSegment(value: EntryKind.income, label: Text('Income')),
              ],
              selected: {draft.kind},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() {
                _readLines();
                if (draft.kind != s.first) {
                  draft.kind = s.first;
                  draft.categoryId = null;
                }
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('amountField'),
              controller: amount,
              focusNode: amountFocus,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textInputAction: TextInputAction.done,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
              decoration: InputDecoration(hintText: '0,00', suffixText: model.currency, border: InputBorder.none),
              onChanged: (_) {
                if (problem != null) setState(() => problem = null);
              },
            ),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  problem!,
                  key: const Key('formProblem'),
                  style: TextStyle(color: pal.over, fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: 4),
            Text('Category', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              key: const Key('categoryChips'),
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in cats)
                  ChoiceChip(
                    key: Key('chip.${c.name}'),
                    avatar: Text(CategoryIcons.of(c), key: Key('chipIcon.${c.name}')),
                    label: Text(c.name),
                    selected: draft.categoryId == c.id,
                    onSelected: (_) => setState(() {
                      draft.categoryId = c.id;
                      problem = null;
                    }),
                  ),
                // A new category made right here; what was typed so far stays, and it is picked.
                ActionChip(
                  key: const Key('chip.new'),
                  avatar: Icon(PlanRules.canAddCustomCategory(model.plan) ? Icons.add : Icons.lock_outline, size: 18),
                  label: const Text('New category'),
                  onPressed: newCategory,
                ),
              ],
            ),
            const SizedBox(height: 12),
            ListTile(
              key: const Key('dateField'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: const Text('Date'),
              trailing: Text(dayLabel(draft.date)),
              onTap: pickDate,
            ),
            TextField(
              key: const Key('noteField'),
              controller: note,
              maxLength: Limits.note,
              decoration: const InputDecoration(labelText: 'Note (optional)', counterText: ''),
            ),
            if (draft.kind == EntryKind.expense) ...[const SizedBox(height: 16), _receiptSection(context, model)],
            const SizedBox(height: 16),
            FilledButton(key: const Key('saveEntry2'), onPressed: save, child: const Text('Save')),
            if (!isNew) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('deleteEntry'),
                onPressed: delete,
                style: OutlinedButton.styleFrom(foregroundColor: pal.over),
                child: const Text('Delete entry'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _receiptSection(BuildContext context, dynamic model) {
    final store = ModelScope.of(context).store;
    final pal = Palette.of(context);
    final scanning = PlanRules.can(PremiumFeature.receipts, ModelScope.of(context).plan);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Receipt', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (reading)
              const Row(
                children: [
                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('Reading the receipt…'),
                ],
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const Key('scanReceipt'),
                    onPressed: () => scanning ? addPhoto(camera: true) : openPremium(context, because: PremiumFeature.receipts),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: Text(draft.receiptId == null ? 'Take photo' : 'New photo'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('photoFromLibrary'),
                    onPressed: () => scanning ? addPhoto(camera: false) : openPremium(context, because: PremiumFeature.receipts),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('From photos'),
                  ),
                ],
              ),
            if (draft.receiptId != null) ...[const SizedBox(height: 8), ReceiptThumbnail(receiptId: draft.receiptId!)],
            if (readNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Muted(readNote!, key: const Key('readNote')),
              ),
            if (lineFields.isNotEmpty || draft.receiptId != null || shop.text.isNotEmpty) _shopField(context, store),
            for (var i = 0; i < lineFields.length; i++) _lineRow(context, i, store, pal),
            if (lineFields.isNotEmpty || draft.receiptId != null)
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    key: const Key('addItem'),
                    onPressed: () => setState(() {
                      _readLines();
                      draft.lines.add(DraftLine());
                      lineFields.add((TextEditingController(), TextEditingController()));
                    }),
                    icon: const Icon(Icons.add),
                    label: const Text('Add item'),
                  ),
                  if (lineFields.isNotEmpty)
                    TextButton(
                      key: const Key('useTotal'),
                      onPressed: () => setState(() {
                        _readLines();
                        amount.text = Money.inputText(draft.linesTotal);
                      }),
                      child: const Text('Use items total'),
                    ),
                ],
              ),
            if (lineFields.isNotEmpty)
              Builder(
                builder: (context) {
                  _readLines();
                  return Row(
                    children: [
                      const Expanded(child: Muted('Items add up to')),
                      Muted(ModelScope.of(context).money(draft.linesTotal), key: const Key('itemsTotal')),
                    ],
                  );
                },
              ),
            const SizedBox(height: 6),
            const Muted(
              'The receipt is read on this phone; nothing is sent anywhere to read it. Each item is compared with the last time you bought it.',
            ),
          ],
        ),
      ),
    );
  }

  /// The shop: read from the receipt, or typed / picked. Prices are compared at the same shop.
  Widget _shopField(BuildContext context, BudgetStore store) {
    final known = <String>{'Mercator', 'Spar', 'Lidl', 'Hofer', 'Tuš', 'Eurospin', 'Jager'};
    for (final t in store.data.transactions) {
      if (t.store.isNotEmpty && !known.any((k) => PriceHistory.sameStore(k, t.store))) known.add(t.store);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: TextField(
        key: const Key('shopField'),
        controller: shop,
        maxLength: Limits.store,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: 'Shop',
          hintText: 'Read from the receipt, or type it',
          counterText: '',
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: PopupMenuButton<String>(
            key: const Key('shopPick'),
            tooltip: 'Pick a shop',
            icon: const Icon(Icons.storefront_outlined),
            onSelected: (v) => setState(() {
              shop.text = v;
              _readLines();
            }),
            itemBuilder: (_) => [for (final k in known) PopupMenuItem(value: k, child: Text(k))],
          ),
        ),
        onChanged: (_) => setState(_readLines),
      ),
    );
  }

  Widget _lineRow(BuildContext context, int i, dynamic store, Palette pal) {
    final (nameField, priceField) = lineFields[i];
    final line = DraftLine(name: nameField.text, priceText: priceField.text, read: i < draft.lines.length ? draft.lines[i].read : null);
    final cmp = draft.comparison(line, ModelScope.of(context).store);
    final money0 = ModelScope.of(context).money;
    String money(int c) => '${money0(c)}${cmp?.perKg == true ? '/kg' : ''}';
    final it = line.item();
    final q = it?.qty;
    // "2 × 0,59 €" or "0,856 kg × 1,49 €/kg": what the comparison is about.
    final amount = it == null || q == null ? '' : (it.unit == 'kg' ? '${q.toString().replaceAll('.', ',')} kg ×' : '${q.round()} ×');
    final perKg = it?.unit == 'kg' ? '/kg' : '';
    final qtyText = it == null || q == null || it.perUnit == null ? '' : '$amount ${money0(it.perUnit!)}$perKg · ';
    // The last price is from another shop when it was never bought at this one.
    final at = cmp == null || cmp.elsewhere.isEmpty ? '' : ' at ${cmp.elsewhere}';
    final (String text0, Color color) = switch (cmp?.kind) {
      null => ('', pal.muted),
      // Quantity × price of one is not the line total: something is misread; say so it can be fixed.
      'misread' => (
        '⚠️ $amount ${money0(it!.unitPrice ?? 0)}$perKg is not ${money0(it.price)}. Check this price; until it adds up, this line is left out of the price history.',
        pal.over,
      ),
      'new' => ('First time', pal.muted),
      'same' => ('Same as ${shortDay(cmp!.date)}$at (${money(cmp.before)})', pal.muted),
      'up' => ('▲ +${pct(cmp!.percent)}% since ${shortDay(cmp.date)}$at (was ${money(cmp.before)})', pal.over),
      _ => ('▼ ${pct(cmp!.percent)}% since ${shortDay(cmp.date)}$at (was ${money(cmp.before)})', pal.income),
    };
    final text = text0.isEmpty ? '' : '$qtyText$text0';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: Key('itemName.$i'),
                  controller: nameField,
                  maxLength: Limits.itemName,
                  decoration: const InputDecoration(hintText: 'Item', isDense: true, counterText: ''),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 84,
                child: TextField(
                  key: Key('itemPrice.$i'),
                  controller: priceField,
                  textAlign: TextAlign.end,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(hintText: '0,00', isDense: true),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              IconButton(
                key: Key('removeItem.$i'),
                tooltip: 'Remove item',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() {
                  _readLines();
                  draft.lines.removeAt(i);
                  final (a, b) = lineFields.removeAt(i);
                  a.dispose();
                  b.dispose();
                }),
              ),
            ],
          ),
          if (text.isNotEmpty) Text(text, style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }
}

class ReceiptThumbnail extends StatefulWidget {
  final String receiptId;
  const ReceiptThumbnail({super.key, required this.receiptId});
  @override
  State<ReceiptThumbnail> createState() => _ReceiptThumbnailState();
}

class _ReceiptThumbnailState extends State<ReceiptThumbnail> {
  Future? _load;
  String? _for;

  @override
  Widget build(BuildContext context) {
    if (_for != widget.receiptId) {
      _for = widget.receiptId;
      _load = ModelScope.read(context).photoData(widget.receiptId);
    }
    return FutureBuilder(
      future: _load,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null) {
          return Row(
            children: [
              const Icon(Icons.receipt_long_outlined),
              const SizedBox(width: 8),
              Flexible(
                child: Muted(snap.connectionState == ConnectionState.done ? 'Receipt photo (not on this phone yet)' : 'Receipt photo'),
              ),
            ],
          );
        }
        final image = Image.memory(
          data,
          height: 140,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
        );
        return Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            key: const Key('receiptThumb'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Receipt')),
                  body: InteractiveViewer(
                    maxScale: 6,
                    child: Center(child: Image.memory(data, errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined))),
                  ),
                ),
              ),
            ),
            child: ClipRRect(borderRadius: BorderRadius.circular(8), child: image),
          ),
        );
      },
    );
  }
}
