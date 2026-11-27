// The Premium screen (what it adds, the three ways to buy it, Restore purchases) and the notice
// shown in place of a Premium part of the app in the free version.
import 'package:flutter/material.dart';

import '../core/premium.dart';
import '../platform/purchases.dart';
import 'home.dart';
import 'widgets.dart';

Future<void> openPremium(BuildContext context, {PremiumFeature? because}) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PremiumScreen(because: because)));

class PremiumScreen extends StatefulWidget {
  final PremiumFeature? because;
  const PremiumScreen({super.key, this.because});
  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  Map<PremiumProduct, String>? prices;
  bool busy = false;
  String? message;

  @override
  void initState() {
    super.initState();
    ModelScope.read(context).purchases.prices().then((p) {
      if (mounted) setState(() => prices = p);
    });
  }

  Future<void> buy(PremiumProduct p) async {
    setState(() {
      busy = true;
      message = null;
    });
    final outcome = await ModelScope.read(context).buyPremium(p);
    if (!mounted) return;
    setState(() {
      busy = false;
      message = switch (outcome) {
        PurchaseOutcome.bought => 'Thank you! You have Premium now.',
        PurchaseOutcome.pending => 'The store is still waiting for the payment. Premium starts once it goes through.',
        PurchaseOutcome.cancelled => null,
        PurchaseOutcome.failed => 'The purchase did not go through. Nothing was charged. Please try again.',
        PurchaseOutcome.unavailable => 'The store cannot be reached right now. Check the internet connection and try again.',
      };
    });
  }

  Future<void> restore() async {
    setState(() {
      busy = true;
      message = null;
    });
    final found = await ModelScope.read(context).restorePremium();
    if (!mounted) return;
    setState(() {
      busy = false;
      message = switch (found) {
        true => 'Premium is back on this phone.',
        false => 'No Premium purchase was found for this store account.',
        null => 'The store cannot be reached right now. Check the internet connection and try again.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final status = model.premium;
    final has = model.plan == Plan.full;
    final pal = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Premium')),
      body: ListView(
        key: const Key('premiumScreen'),
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.because != null && !has)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '${widget.because!.title} is part of Premium.',
                key: const Key('premiumBecause'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          Text(status.describe(model.now()), key: const Key('premiumStatus')),
          if (message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(message!, key: const Key('premiumMessage'), style: Theme.of(context).textTheme.titleSmall),
            ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Premium adds',
            children: [
              for (final f in PremiumFeature.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(has ? Icons.check_circle : Icons.lock_outline, color: has ? Theme.of(context).colorScheme.primary : null),
                  title: Text(f.title),
                  subtitle: Text(f.detail),
                ),
              const Muted('The free version has the main categories and your Personal budget. No ads, ever.'),
            ],
          ),
          if (!has) ...[
            SectionCard(
              title: 'Get Premium',
              children: [
                for (final p in PremiumProduct.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: FilledButton(
                      key: Key('buy.${p.id}'),
                      onPressed: busy || prices == null ? null : () => buy(p),
                      child: Text('${p.label}: ${prices?[p] ?? p.defaultPrice}'),
                    ),
                  ),
                const Muted(
                  'Monthly and yearly renew on their own until you cancel them in your App Store or Google Play subscriptions. '
                  'Lifetime is paid once. When one of you has Premium, your shared household has it too.',
                ),
              ],
            ),
          ],
          if (prices != null && prices!.isEmpty && !has)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'The store cannot be reached right now, so the prices shown may differ in your country.',
                key: const Key('storeUnavailable'),
                style: TextStyle(color: pal.muted),
              ),
            ),
          if (busy)
            const Center(
              child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()),
            ),
          if (!status.everyone)
            TextButton(key: const Key('restorePurchases'), onPressed: busy ? null : restore, child: const Text('Restore purchases')),
        ],
      ),
    );
  }
}

/// Shown instead of a Premium part of the app in the free version.
class PremiumGate extends StatelessWidget {
  final PremiumFeature feature;
  const PremiumGate({super.key, required this.feature});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          key: Key('premiumGate.${feature.name}'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 40),
            const SizedBox(height: 12),
            Text(feature.title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(feature.detail, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              key: Key('seePremium.${feature.name}'),
              onPressed: () => openPremium(context, because: feature),
              child: const Text('See Premium'),
            ),
          ],
        ),
      ),
    );
  }
}
