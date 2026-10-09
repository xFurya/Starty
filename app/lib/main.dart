import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'background.dart';
import 'data.dart';
import 'reminders.dart';
import 'update.dart';
import 'views.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Prefs.init();
  runApp(const StartyApp());
  // уведомления настраиваются после показа экрана: их сбой не должен мешать запуску
  try {
    await Reminders.init();
  } catch (_) {}
  await scheduleBackground();
}

class Palette {
  final Color bg, surface, ink, ink2, ink3, line, accent, live, sheet;
  const Palette(this.bg, this.surface, this.ink, this.ink2, this.ink3, this.line, this.accent, this.live, this.sheet);
  static const light = Palette(
    Color(0xFFF3F6F9),
    Color(0xFFFFFFFF),
    Color(0xFF0D1925),
    Color(0xFF55667A),
    Color(0xFF93A2B1),
    Color(0xFFE2E8EE),
    Color(0xFF1C5C9C),
    Color(0xFFE0353B),
    Color(0xFFFFFFFF),
  );
  static const dark = Palette(
    Color(0xFF09131D),
    Color(0xFF111F2D),
    Color(0xFFE9F0F6),
    Color(0xFF9DAEBC),
    Color(0xFF627588),
    Color(0xFF1B2A39),
    Color(0xFF72B4F2),
    Color(0xFFFF5A5F),
    Color(0xFF142433),
  );
  static Palette of(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? dark : light;
}

ThemeData _theme(Brightness b) {
  final p = b == Brightness.dark ? Palette.dark : Palette.light;
  final base = ThemeData(brightness: b, useMaterial3: true, colorSchemeSeed: p.accent);
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    colorScheme: base.colorScheme.copyWith(primary: p.accent, surface: p.bg, onSurface: p.ink),
    dividerColor: p.line,
    splashFactory: InkSparkle.splashFactory,
    textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.bg,
      indicatorColor: p.accent.withValues(alpha: .14),
      surfaceTintColor: Colors.transparent,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 12.5,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? p.ink : p.ink2,
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.sheet, surfaceTintColor: Colors.transparent, showDragHandle: true),
  );
}

class StartyApp extends StatelessWidget {
  const StartyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Старты',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    locale: const Locale('ru'),
    home: const Home(),
  );
}

/// Общее состояние: расписание, отметки, фильтры.
class AppState extends ChangeNotifier {
  Schedule? data;
  bool loading = true;
  bool offline = false;
  Set<String> watched = Prefs.watched;
  Set<String> followed = Prefs.followed;
  Filters filters = Filters(Prefs.kinds, Prefs.tids, Prefs.athletes);

  Future<void> load() async {
    data ??= await Repo.cached();
    if (data != null) {
      loading = false;
      notifyListeners();
    }
    final fresh = await Repo.fetch();
    if (fresh != null) {
      data = fresh;
      offline = false;
    } else {
      offline = true;
    }
    loading = false;
    notifyListeners();
    Reminders.sync(data, watched, followed);
  }

  Future<void> toggleWatch(String id) async {
    final on = !watched.contains(id);
    watched = {...watched};
    on ? watched.add(id) : watched.remove(id);
    notifyListeners();
    await Prefs.setWatched(watched);
    if (on) await Reminders.ask();
    await Reminders.sync(data, watched, followed);
  }

  bool follows(String name) => followed.contains(name);

  /// Уведомление о выходе спортсмена: за 5 минут, когда время выхода известно.
  Future<void> toggleFollow(String name) async {
    final on = !followed.contains(name);
    followed = {...followed};
    on ? followed.add(name) : followed.remove(name);
    notifyListeners();
    await Prefs.setFollowed(followed);
    if (on) await Reminders.ask();
    await Reminders.sync(data, watched, followed);
  }

  Future<void> setFilters(Filters f) async {
    filters = f;
    notifyListeners();
    await Prefs.setFilters(f.kinds, f.tids, f.athletes);
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final state = AppState();
  int tab = 0;
  Timer? _tick;
  UpdateInfo? update;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state.load();
    // раз в минуту: «идёт сейчас», кто уже откатал
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
    if (!kIsWeb) checkUpdate().then((u) => mounted && u != null ? setState(() => update = u) : null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) state.load();
  }

  @override
  void dispose() {
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    SystemChrome.setSystemUIOverlayStyle(
      Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: p.bg)
          : SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: p.bg),
    );
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              if (update != null) UpdateBar(info: update!, onClose: () => setState(() => update = null)),
              Expanded(
                child: IndexedStack(
                  index: tab,
                  children: [
                    FeedView(state: state),
                    MonthView(state: state),
                    MineView(state: state),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.view_agenda_outlined),
              selectedIcon: Icon(Icons.view_agenda),
              label: 'Лента',
            ),
            const NavigationDestination(
              icon: Icon(Icons.calendar_month_outlined),
              selectedIcon: Icon(Icons.calendar_month),
              label: 'Месяц',
            ),
            NavigationDestination(
              icon: Badge(isLabelVisible: state.watched.isNotEmpty, smallSize: 7, child: const Icon(Icons.notifications_none)),
              selectedIcon: const Icon(Icons.notifications),
              label: 'Мои',
            ),
          ],
        ),
      ),
    );
  }
}
