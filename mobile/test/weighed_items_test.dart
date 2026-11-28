import 'package:budget/core/models.dart';
import 'package:budget/core/prices.dart';
import 'package:flutter_test/flutter_test.dart';

Transaction tx(String date, ReceiptItem it) => Transaction(
  id: 'tx_$date${it.name}',
  spaceId: 's',
  categoryId: 'c',
  kind: EntryKind.expense,
  amount: it.price,
  date: date,
  createdBy: 'u',
  createdAt: '${date}T10:00:00.000Z',
  updatedAt: '${date}T10:00:00.000Z',
  items: [it],
);

void main() {
  test('an item sold by weight: a purchase without its weight is left out of the history', () {
    final g = PriceHistory.groups([
      tx('2026-06-06', ReceiptItem(name: 'BANANE', price: 155, qty: 1.2, unit: 'kg', unitPrice: 129)),
      tx('2026-06-13', ReceiptItem(name: 'BANANE', price: 168)), // weight line not read
      tx('2026-06-20', ReceiptItem(name: 'BANANE', price: 137, qty: 1.04, unit: 'kg', unitPrice: 132)),
      tx('2026-06-20', ReceiptItem(name: 'JOGURT', price: 69)),
    ]);
    expect(g['banane']!.entries.map((e) => e.price), [129, 132]);
    expect(g['jogurt']!.entries.map((e) => e.price), [69]);
  });
}
