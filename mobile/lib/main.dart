import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'app_model.dart';
import 'core/money.dart';
import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setUpLocale();
  final model = await AppModel.live();
  runApp(BudgetApp(model: model));
  model.syncIfConnected().whenComplete(model.refreshPremium);
}

/// Money and dates are shown the way the phone is set up (for example "1.234,50 €" in Slovenia).
Future<void> setUpLocale([ui.Locale? locale]) async {
  final l = locale ?? ui.PlatformDispatcher.instance.locale;
  final tag = l.countryCode == null ? l.languageCode : '${l.languageCode}_${l.countryCode}';
  Money.locale = Intl.verifiedLocale(tag, NumberFormat.localeExists, onFailure: (_) => 'en') ?? 'en';
  try {
    await initializeDateFormatting(Money.locale);
  } catch (_) {
    Money.locale = 'en';
    await initializeDateFormatting('en');
  }
}

class BudgetApp extends StatefulWidget {
  final AppModel model;
  const BudgetApp({super.key, required this.model});
  @override
  State<BudgetApp> createState() => _BudgetAppState();
}

class _BudgetAppState extends State<BudgetApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Sync when the app comes back to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.model.syncIfConnected().whenComplete(widget.model.refreshPremium);
  }

  @override
  Widget build(BuildContext context) {
    return ModelScope(
      model: widget.model,
      child: ListenableBuilder(
        listenable: widget.model,
        builder: (context, _) => MaterialApp(
          title: 'Budget',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: widget.model.appearance.mode,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('en'), Locale('sl'), Locale('sr'), Locale('hr'), Locale('bs'), Locale('de')],
          home: const HomeScreen(),
        ),
      ),
    );
  }
}
