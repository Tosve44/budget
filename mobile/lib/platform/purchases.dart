// Buying Premium through the App Store (iPhone) or Google Play (Android). The app only asks the
// store; it keeps no payment details. Tests and the computer use FakePurchases instead.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';

import '../core/premium.dart';

enum PurchaseOutcome { bought, cancelled, pending, failed, unavailable }

abstract class Purchases {
  /// Store prices as the store shows them in this country (empty when the store is not reachable).
  Future<Map<PremiumProduct, String>> prices();

  /// Opens the store's buy screen. Ends when the person bought, cancelled, or it failed.
  Future<PurchaseOutcome> buy(PremiumProduct product);

  /// "Restore purchases": asks the store again. True when this store account has Premium, null
  /// when the store could not be asked (no internet, not signed in to the store).
  Future<bool?> restore();

  /// Quietly asks the store whether this store account has Premium right now (null: could not ask).
  Future<bool?> ownsPremium();

  void dispose() {}
}

/// The real stores.
class StorePurchases extends Purchases {
  final _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final _waiting = <String, Completer<PurchaseOutcome>>{};
  final _products = <String, ProductDetails>{};
  bool _owned = false;

  StorePurchases() {
    _sub = _iap.purchaseStream.listen(_onPurchases, onError: (Object e) => debugPrint('purchases: $e'));
  }

  static final _ids = {for (final p in PremiumProduct.values) p.id};

  Future<void> _onPurchases(List<PurchaseDetails> list) async {
    for (final p in list) {
      if (!_ids.contains(p.productID)) continue;
      final outcome = switch (p.status) {
        PurchaseStatus.purchased || PurchaseStatus.restored => PurchaseOutcome.bought,
        PurchaseStatus.pending => PurchaseOutcome.pending,
        PurchaseStatus.canceled => PurchaseOutcome.cancelled,
        PurchaseStatus.error => PurchaseOutcome.failed,
      };
      if (outcome == PurchaseOutcome.bought) _owned = true;
      if (p.pendingCompletePurchase) {
        try {
          await _iap.completePurchase(p);
        } catch (e) {
          debugPrint('completePurchase: $e');
        }
      }
      if (outcome != PurchaseOutcome.pending) _waiting.remove(p.productID)?.complete(outcome);
    }
  }

  Future<bool> _loadProducts() async {
    if (_products.length == PremiumProduct.values.length) return true;
    if (!await _iap.isAvailable()) return false;
    final r = await _iap.queryProductDetails(_ids);
    for (final d in r.productDetails) {
      _products[d.id] = d;
    }
    return _products.isNotEmpty;
  }

  @override
  Future<Map<PremiumProduct, String>> prices() async {
    try {
      await _loadProducts();
    } catch (e) {
      debugPrint('prices: $e');
    }
    return {
      for (final p in PremiumProduct.values)
        if (_products[p.id] != null) p: _products[p.id]!.price,
    };
  }

  @override
  Future<PurchaseOutcome> buy(PremiumProduct product) async {
    try {
      if (!await _loadProducts() || _products[product.id] == null) return PurchaseOutcome.unavailable;
      final done = _waiting.putIfAbsent(product.id, Completer.new);
      // Subscriptions and the lifetime unlock are all bought once and kept (not used up).
      final started = await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: _products[product.id]!));
      if (!started) {
        _waiting.remove(product.id);
        return PurchaseOutcome.failed;
      }
      return await done.future;
    } catch (e) {
      debugPrint('buy: $e');
      _waiting.remove(product.id);
      return PurchaseOutcome.failed;
    }
  }

  @override
  Future<bool?> restore() async {
    try {
      if (!await _iap.isAvailable()) return null;
      await _iap.restorePurchases();
    } catch (e) {
      debugPrint('restore: $e');
      return null;
    }
    final owns = await ownsPremium();
    return owns == null ? null : owns || _owned;
  }

  @override
  Future<bool?> ownsPremium() async {
    try {
      if (!await _iap.isAvailable()) return null;
      if (Platform.isIOS) {
        // Only what the person has right now: running subscriptions and the lifetime unlock.
        final now = await SK2Transaction.currentEntitlements();
        return now.any((t) => _ids.contains(t.productId));
      }
      if (Platform.isAndroid) {
        final android = _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
        final r = await android.queryPastPurchases();
        if (r.error != null) return null;
        return r.pastPurchases.any((p) => _ids.contains(p.productID) && p.status == PurchaseStatus.purchased);
      }
    } catch (e) {
      debugPrint('ownsPremium: $e');
      return null;
    }
    return null;
  }

  @override
  void dispose() => _sub?.cancel();
}

/// For tests and the computer: a pretend store.
class FakePurchases extends Purchases {
  bool owned;
  bool storeReachable;
  PurchaseOutcome nextOutcome;
  final bought = <PremiumProduct>[];
  FakePurchases({this.owned = false, this.storeReachable = true, this.nextOutcome = PurchaseOutcome.bought});

  @override
  Future<Map<PremiumProduct, String>> prices() async => storeReachable ? {for (final p in PremiumProduct.values) p: p.defaultPrice} : {};

  @override
  Future<PurchaseOutcome> buy(PremiumProduct product) async {
    if (!storeReachable) return PurchaseOutcome.unavailable;
    final o = nextOutcome;
    if (o == PurchaseOutcome.bought) {
      owned = true;
      bought.add(product);
    }
    return o;
  }

  @override
  Future<bool?> restore() async => storeReachable ? owned : null;

  @override
  Future<bool?> ownsPremium() async => storeReachable ? owned : null;
}
