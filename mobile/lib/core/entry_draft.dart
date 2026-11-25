import 'models.dart';
import 'money.dart';
import 'prices.dart';
import 'receipt_parser.dart';
import 'store.dart';

class DraftLine {
  String name;
  String priceText;
  DraftLine({this.name = '', this.priceText = ''});
  DraftLine.of(ReceiptItem it) : name = it.name, priceText = Money.inputText(it.price, emptyForZero: false);
}

class DraftProblem implements Exception {
  final String message;
  const DraftProblem(this.message);
  @override
  String toString() => message;

  static const amount = DraftProblem('Enter an amount bigger than 0.');
  static const amountTooBig = DraftProblem('That amount is too big.');
  static const category = DraftProblem('Pick a category.');
  static const date = DraftProblem('Pick a date.');
  static const noteTooLong = DraftProblem('The note is too long (at most ${Limits.note} characters).');
  static const tooManyItems = DraftProblem('A receipt can have at most ${Limits.items} items.');
  static DraftProblem itemPrice(String name) => DraftProblem('Check the price of "$name".');
}

/// How a receipt line compares with the last time the same item was bought.
class Comparison {
  /// 'new', 'same', 'up' or 'down'.
  final String kind;
  final double percent;
  final int before;
  final String date;
  const Comparison(this.kind, {this.percent = 0, this.before = 0, this.date = ''});
}

class CheckedEntry {
  final int amount;
  final String categoryId;
  final List<ReceiptItem> items;
  const CheckedEntry(this.amount, this.categoryId, this.items);
}

/// What the add / edit entry screen holds while you type. Kept out of the screen so the rules
/// can be tested without a phone. Same rules as the iPhone app (EntryDraft.swift).
class EntryDraft {
  String? existingId;
  String spaceId;
  EntryKind kind;
  String? categoryId;
  String amountText;
  String date;
  String note;
  List<DraftLine> lines;
  String? receiptId;

  EntryDraft({required this.spaceId, this.kind = EntryKind.expense, this.categoryId, required this.date})
    : amountText = '',
      note = '',
      lines = [];

  EntryDraft.editing(Transaction t)
    : existingId = t.id,
      spaceId = t.spaceId,
      kind = t.kind,
      categoryId = t.categoryId,
      amountText = Money.inputText(t.amount, emptyForZero: false),
      date = t.date,
      note = t.note,
      lines = (t.items ?? []).map(DraftLine.of).toList(),
      receiptId = t.receiptId;

  /// Receipt lines that have a name; a named line without a readable price is a problem.
  List<ReceiptItem> items() {
    final out = <ReceiptItem>[];
    for (final l in lines) {
      final name = l.name.trim();
      if (name.isEmpty) continue;
      final p = Money.cents(l.priceText);
      if (p == null || p < 0 || p > Limits.maxCents) throw DraftProblem.itemPrice(name);
      out.add(ReceiptItem(name: Limits.clip(name, Limits.itemName), price: p));
    }
    return out;
  }

  CheckedEntry check() {
    final a = Money.cents(amountText);
    if (a == null || a <= 0) throw DraftProblem.amount;
    if (a > Limits.maxCents) throw DraftProblem.amountTooBig;
    final c = categoryId;
    if (c == null || c.isEmpty) throw DraftProblem.category;
    if (!DateKey.isValidDay(date)) throw DraftProblem.date;
    if (Limits.length(note.trim()) > Limits.note) throw DraftProblem.noteTooLong;
    final its = kind == EntryKind.expense ? items() : <ReceiptItem>[];
    if (its.length > Limits.items) throw DraftProblem.tooManyItems;
    return CheckedEntry(a, c, its);
  }

  /// True when the entry being edited was deleted meanwhile (for example by the partner).
  /// Saving then adds it again as a new entry, and the screen says so.
  bool wasDeletedMeanwhile(BudgetStore store) => existingId != null && !store.data.transactions.any((t) => t.id == existingId);

  /// Saves as a new entry or over the one being edited. Returns the entry.
  Transaction save(BudgetStore store) {
    final ok = check();
    final rid = kind == EntryKind.expense ? receiptId : null;
    final id = existingId;
    if (id != null && store.data.transactions.any((t) => t.id == id)) {
      store.updateTransaction(id, (t) {
        t.kind = kind;
        t.categoryId = ok.categoryId;
        t.amount = ok.amount;
        t.date = date;
        t.note = note.trim();
        t.items = ok.items;
        t.receiptId = rid;
      });
      return store.data.transactions.firstWhere((t) => t.id == id);
    }
    return store.addTransaction(
      spaceId: spaceId,
      categoryId: ok.categoryId,
      kind: kind,
      amount: ok.amount,
      date: date,
      note: note.trim(),
      items: ok.items,
      receiptId: rid,
    );
  }

  /// Fills in the receipt lines from the text read off a photo, and the amount from the printed
  /// total (SKUPAJ / ZA PLAČILO), or the sum of the lines when no total was found.
  /// Returns how many lines were found.
  int applyReceiptText(String text) {
    final found = ReceiptParser.parse(text);
    if (found.isNotEmpty) lines = found.map(DraftLine.of).toList();
    final total = ReceiptParser.findTotal(text);
    if (total != null) {
      amountText = Money.inputText(total, emptyForZero: false);
    } else if (found.isNotEmpty && Money.cents(amountText) == null) {
      amountText = Money.inputText(found.fold(0, (s, it) => s + it.price), emptyForZero: false);
    }
    return found.length;
  }

  int get linesTotal => lines.map((l) => Money.cents(l.priceText) ?? 0).fold(0, (a, b) => a + b);

  Comparison? comparison(DraftLine line, BudgetStore store) {
    final price = Money.cents(line.priceText);
    if (price == null || line.name.trim().isEmpty) return null;
    final prev = store.previousPrice(line.name, date, excluding: existingId);
    if (prev == null) return const Comparison('new');
    final pct = Money.percentChange(price, prev.price);
    if (pct == null || pct == 0) return Comparison('same', before: prev.price, date: prev.date);
    return Comparison(pct > 0 ? 'up' : 'down', percent: pct, before: prev.price, date: prev.date);
  }
}
