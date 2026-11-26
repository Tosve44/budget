// Category icons: every default category has its own icon, a picked icon wins, and the icon
// survives saving and loading.
import 'dart:convert';

import 'package:budget/core/category_icons.dart';
import 'package:budget/core/models.dart';
import 'package:budget/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final defaults = {
    ...DefaultCategories.personalExpenses,
    ...DefaultCategories.personalIncome,
    ...DefaultCategories.houseExpenses,
    ...DefaultCategories.houseIncome,
  };

  test('every default category has a fitting icon of its own', () {
    for (final name in defaults) {
      expect(CategoryIcons.byName.containsKey(name.toLowerCase()), isTrue, reason: name);
      expect(CategoryIcons.forName(name), isNot(CategoryIcons.fallback), reason: name);
    }
    expect(CategoryIcons.forName('  RENT '), '🏠', reason: 'case and spaces do not matter');
    expect(CategoryIcons.forName('Pets'), CategoryIcons.fallback);
  });

  test('the icons to pick from are all different and short enough to save', () {
    expect(CategoryIcons.choices.toSet().length, CategoryIcons.choices.length);
    for (final e in [...CategoryIcons.choices, ...CategoryIcons.byName.values, CategoryIcons.fallback]) {
      expect(e.runes.length, lessThanOrEqualTo(CategoryIcons.maxLength), reason: e);
    }
  });

  test('a picked icon wins; empty or spaces means the default for the name', () {
    final store = BudgetStore(storage: MemoryStorage());
    final space = store.personalSpace()!;
    final rent = store.categories(space.id).firstWhere((c) => c.name == 'Rent');
    expect(CategoryIcons.of(rent), '🏠');
    store.updateCategory(rent.id, icon: ' 🏨 ');
    expect(store.category(rent.id)!.icon, '🏨');
    expect(CategoryIcons.of(store.category(rent.id)!), '🏨');
    store.updateCategory(rent.id, icon: '   ');
    expect(CategoryIcons.of(store.category(rent.id)!), '🏠');
    final pets = store.addCategory(spaceId: space.id, name: 'Pets', kind: EntryKind.expense, icon: '🐶');
    expect(CategoryIcons.of(pets), '🐶');
    store.updateCategory(pets.id, icon: 'x' * 40);
    expect(store.category(pets.id)!.icon.length, CategoryIcons.maxLength, reason: 'cut to what the cloud allows');
  });

  test('the icon is kept when the data is saved and opened again; old data without one still opens', () {
    final c = Category.fromJson({
      'id': 'c1',
      'spaceId': 's1',
      'name': 'Pets',
      'kind': 'expense',
      'budget': 0,
      'archived': false,
      'icon': '🐶',
    });
    final back = Category.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
    expect(back.icon, '🐶');
    expect(back, c);
    final old = Category.fromJson({'id': 'c2', 'spaceId': 's1', 'name': 'Rent', 'kind': 'expense', 'budget': 0, 'archived': false});
    expect(old.icon, '');
    expect(old.toJson().containsKey('icon'), isFalse, reason: 'written back unchanged');
    expect(CategoryIcons.of(old), '🏠');
  });
}
