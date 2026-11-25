import 'package:flutter/material.dart';

import '../app_model.dart';
import '../core/models.dart';
import 'prices_screen.dart';
import 'settings_screen.dart';
import 'space_screen.dart';

/// Gives every screen the app's data; screens that call [ModelScope.of] redraw on every change.
class ModelScope extends InheritedNotifier<AppModel> {
  const ModelScope({super.key, required AppModel model, required super.child}) : super(notifier: model);
  static AppModel of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ModelScope>()!.notifier!;
  static AppModel read(BuildContext context) => context.getInheritedWidgetOfExactType<ModelScope>()!.notifier!;
}

/// The web app's colours, so both look like the same app.
class Palette extends ThemeExtension<Palette> {
  final Color income, over, warn, muted, track, accentSoft;
  const Palette({
    required this.income,
    required this.over,
    required this.warn,
    required this.muted,
    required this.track,
    required this.accentSoft,
  });

  static const light = Palette(
    income: Color(0xFF23693F),
    over: Color(0xFFC0392B),
    warn: Color(0xFFB7791F),
    muted: Color(0xFF5F5F64),
    track: Color(0xFFE8E6E0),
    accentSoft: Color(0xFFDCEBE5),
  );
  static const dark = Palette(
    income: Color(0xFF6CC38A),
    over: Color(0xFFEF6B5E),
    warn: Color(0xFFE0A84A),
    muted: Color(0xFF9A9AA1),
    track: Color(0xFF2F2F34),
    accentSoft: Color(0xFF23392F),
  );

  static Palette of(BuildContext context) => Theme.of(context).extension<Palette>()!;

  @override
  Palette copyWith() => this;
  @override
  Palette lerp(Palette? other, double t) => t < 0.5 || other == null ? this : other;
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final accent = dark ? const Color(0xFF6CC3A6) : const Color(0xFF2F6F5E);
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2F6F5E), brightness: b).copyWith(
    primary: accent,
    surface: dark ? const Color(0xFF1F1F22) : Colors.white,
    onSurface: dark ? const Color(0xFFF2F2F4) : const Color(0xFF1C1C1E),
    error: dark ? const Color(0xFFEF6B5E) : const Color(0xFFC0392B),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: dark ? const Color(0xFF151517) : const Color(0xFFF6F5F2),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      color: dark ? const Color(0xFF1F1F22) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: dark ? const Color(0xFF2F2F34) : const Color(0xFFE3E1DB)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF151517) : const Color(0xFFF6F5F2),
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    extensions: [dark ? Palette.dark : Palette.light],
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final pages = [
      const SpaceScreen(key: ValueKey('personal'), type: SpaceType.personal),
      const SpaceScreen(key: ValueKey('house'), type: SpaceType.house),
      const PricesScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: Column(
        children: [
          if (model.saveProblem != null)
            SafeArea(
              bottom: false,
              child: Container(
                key: const Key('saveProblem'),
                width: double.infinity,
                color: Palette.of(context).over,
                padding: const EdgeInsets.all(10),
                child: Text(model.saveProblem!, style: const TextStyle(color: Colors.white)),
              ),
            ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Every tab keeps its place (month, search) while another one is shown.
                for (var i = 0; i < pages.length; i++)
                  Offstage(
                    offstage: i != tab,
                    child: TickerMode(enabled: i == tab, child: pages[i]),
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(
            key: Key('tab.personal'),
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Personal',
          ),
          NavigationDestination(key: Key('tab.house'), icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'House'),
          NavigationDestination(key: Key('tab.prices'), icon: Icon(Icons.show_chart), label: 'Prices'),
          NavigationDestination(
            key: Key('tab.settings'),
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
