// Premium: who has it, what the free version has, and buying and restoring with a pretend store.
import 'package:budget/app_model.dart';
import 'package:budget/core/models.dart';
import 'package:budget/core/premium.dart';
import 'package:budget/core/prices.dart';
import 'package:budget/core/sync.dart';
import 'package:budget/platform/purchases.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 27, 12);

  test('where Premium comes from', () {
    expect(const PremiumStatus().plan(now), Plan.free);
    expect(const PremiumStatus(everyone: true).plan(now), Plan.full);
    expect(const PremiumStatus(fromStore: true).plan(now), Plan.full);
    expect(PremiumStatus(householdUntil: now.add(const Duration(days: 3))).plan(now), Plan.full, reason: 'the partner pays');
    expect(PremiumStatus(householdUntil: now.subtract(const Duration(minutes: 1))).plan(now), Plan.free, reason: 'ran out');
    expect(PremiumStatus(householdUntil: SyncEngine.parsePremiumUntil('infinity')).plan(now), Plan.full, reason: 'testers');
    expect(PremiumStatus(householdUntil: SyncEngine.parsePremiumUntil('infinity')).describe(now), 'Your household has Premium for free.');
  });

  test('the cloud date of the household Premium is read safely', () {
    expect(SyncEngine.parsePremiumUntil(null), isNull);
    expect(SyncEngine.parsePremiumUntil(''), isNull);
    expect(SyncEngine.parsePremiumUntil('-infinity'), isNull);
    expect(SyncEngine.parsePremiumUntil('not a date'), isNull);
    expect(SyncEngine.parsePremiumUntil('2027-01-01T10:00:00+00:00'), DateTime.utc(2027, 1, 1, 10));
    expect(SyncEngine.parsePremiumUntil('infinity')!.year, 9999);
  });

  test('the free version: main categories, no House, no receipts, no prices; Premium: everything', () {
    final model = AppModel.forTests(plan: Plan.free);
    final s = model.store;
    final personal = s.personalSpace()!, house = s.houseSpace!;
    final free = s.pickableCategories(personal.id, EntryKind.expense, Plan.free).map((c) => c.name).toSet();
    expect(free, PlanRules.freePersonalExpenses);
    expect(s.pickableCategories(personal.id, EntryKind.income, Plan.free), isNotEmpty, reason: 'income is always there');
    expect(s.pickableCategories(personal.id, EntryKind.expense, Plan.full).length, DefaultCategories.personalExpenses.length);
    expect(s.pickableCategories(house.id, EntryKind.expense, Plan.full).length, DefaultCategories.houseExpenses.length);
    for (final f in PremiumFeature.values) {
      expect(PlanRules.can(f, Plan.free), isFalse, reason: f.name);
      expect(PlanRules.can(f, Plan.full), isTrue, reason: f.name);
    }
    expect(PlanRules.canAddCustomCategory(Plan.free), isFalse);
    expect(PlanRules.canAddCustomCategory(Plan.full), isTrue);
  });

  test('buying: bought unlocks, cancelled, failed, pending and no store leave the free version', () async {
    for (final o in [PurchaseOutcome.cancelled, PurchaseOutcome.failed, PurchaseOutcome.pending, PurchaseOutcome.unavailable]) {
      final store = FakePurchases(nextOutcome: o, storeReachable: o != PurchaseOutcome.unavailable);
      final model = AppModel.forTests(plan: Plan.free, purchases: store);
      expect(await model.buyPremium(PremiumProduct.monthly), o);
      expect(model.plan, Plan.free, reason: o.name);
    }
    for (final p in PremiumProduct.values) {
      final store = FakePurchases();
      final model = AppModel.forTests(plan: Plan.free, purchases: store);
      expect(await model.buyPremium(p), PurchaseOutcome.bought);
      expect(model.plan, Plan.full, reason: p.name);
      expect(store.bought, [p]);
    }
  });

  test('Premium is remembered offline, and goes away when the store says it ended', () async {
    final store = FakePurchases(owned: true);
    final model = AppModel.forTests(plan: Plan.free, purchases: store);
    await model.refreshPremium();
    expect(model.plan, Plan.full);
    // No internet: the store cannot be asked, and Premium stays as it was.
    store.storeReachable = false;
    await model.refreshPremium();
    expect(model.plan, Plan.full);
    expect(await model.restorePremium(), isNull);
    expect(model.plan, Plan.full);
    // The subscription ended.
    store
      ..storeReachable = true
      ..owned = false;
    await model.refreshPremium();
    expect(model.plan, Plan.free);
    expect(await model.restorePremium(), isFalse);
  });

  test('test builds: everyone has Premium and the store is never asked', () async {
    final store = FakePurchases();
    final model = AppModel.forTests(purchases: store);
    await model.refreshPremium();
    expect(model.plan, Plan.full);
    expect(model.premium.describe(now), 'While testing, everyone has Premium for free.');
  });

  test('product ids match the ones to set up in the stores', () {
    expect(PremiumProduct.values.map((p) => p.id), ['premium_monthly', 'premium_yearly', 'premium_lifetime']);
    expect(PremiumProduct.byId('premium_yearly'), PremiumProduct.yearly);
    expect(PremiumProduct.byId('nope'), isNull);
  });
}
