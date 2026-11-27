// Premium: what the free version has, what Premium adds, and whether this phone has Premium.
// Pure logic without the store, so it is the same in tests and on phones.
import 'models.dart';

/// The free version, or Premium (everything).
enum Plan { free, full }

/// What Premium costs. The stores show their own price in each country; these are the euro
/// prices set up in App Store Connect and the Google Play Console.
enum PremiumProduct {
  monthly('premium_monthly', 'Monthly', '€1.99 / month'),
  yearly('premium_yearly', 'Yearly', '€14.99 / year'),
  lifetime('premium_lifetime', 'Lifetime', '€29.99 once');

  final String id;
  final String label;
  final String defaultPrice;
  const PremiumProduct(this.id, this.label, this.defaultPrice);

  static PremiumProduct? byId(String id) => values.where((p) => p.id == id).firstOrNull;
}

/// Where Premium comes from on this phone.
class PremiumStatus {
  /// Everyone has Premium (test builds, while Tosve and Milica try the app).
  final bool everyone;

  /// The store account on this phone owns a Premium product right now.
  final bool fromStore;

  /// The household's Premium in the cloud (paid by the partner, or given to testers): until then.
  final DateTime? householdUntil;

  const PremiumStatus({this.everyone = false, this.fromStore = false, this.householdUntil});

  bool householdActive(DateTime now) => householdUntil != null && householdUntil!.isAfter(now);

  Plan plan(DateTime now) => everyone || fromStore || householdActive(now) ? Plan.full : Plan.free;

  /// A short line for the Premium screen.
  String describe(DateTime now) {
    if (everyone) return 'While testing, everyone has Premium for free.';
    if (fromStore) return 'You have Premium. Thank you!';
    if (householdActive(now)) {
      return householdUntil!.year >= 9999
          ? 'Your household has Premium for free.'
          : 'Your household has Premium (your partner pays for it).';
    }
    return 'You have the free version.';
  }
}

/// The parts of the app that need Premium.
enum PremiumFeature {
  categories('All categories, and your own', 'Every category, personal and house, plus categories you make yourself.'),
  house('The shared House budget', 'A House budget you share with your partner, synced between both phones.'),
  receipts('Receipt scanning', 'Take a photo of a receipt and the items and total are filled in.'),
  prices('Price tracking', 'See how the prices of the things you buy change over time.');

  final String title;
  final String detail;
  const PremiumFeature(this.title, this.detail);
}

class PlanRules {
  PlanRules._();
  static const freePersonalExpenses = {'Rent', 'Groceries', 'Food & Drinks', 'Car', 'Shopping', 'Saving', 'Partner balance'};
  static const freeHouseExpenses = {'Groceries', 'Shopping', 'Unexpected expenses'};

  static bool isAvailable(Category c, Space? space, Plan plan) {
    if (plan == Plan.full || c.kind == EntryKind.income) return true;
    final free = space?.type == SpaceType.house ? freeHouseExpenses : freePersonalExpenses;
    return free.contains(c.name);
  }

  static bool canAddCustomCategory(Plan plan) => plan == Plan.full;
  static bool canRenameCategory(Plan plan) => plan == Plan.full;
  static bool can(PremiumFeature f, Plan plan) => plan == Plan.full;
}
