import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'background.dart';
import 'data.dart';
import 'platform.dart';
import 'reminders.dart';
import 'settings.dart';
import 'state.dart';
import 'ui.dart';
import 'update.dart';
import 'updater.dart';
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
  // самообновление: состояние с нативной стороны, «обновлено до …» один раз
  await Updates.instance.init();
}

/// Цвета «Лёд»: светлая тема — главная, тёмная — ночной каток.
/// Акцент — синий из иконки (#2B78C2 → #0A2342).
class Palette {
  final bool isDark;
  final Color bg, bgTop, plate, plateLine, ink, ink2, ink3, line, accent, onAccent, live, sheet, frost, nav;

  /// Обводка флажков и переключателей: не ниже 3:1 к фону листа.
  final Color control;

  /// Виды: приглушённые ледяные оттенки — женщины, мужчины, пары, танцы.
  final Color women, men, pairs, dance;

  const Palette({
    required this.isDark,
    required this.bg,
    required this.bgTop,
    required this.plate,
    required this.plateLine,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.line,
    required this.accent,
    required this.onAccent,
    required this.live,
    required this.sheet,
    required this.frost,
    required this.nav,
    required this.control,
    required this.women,
    required this.men,
    required this.pairs,
    required this.dance,
  });

  /// Синий из иконки: верх и низ градиента.
  static const iceBlue = Color(0xFF2B78C2);
  static const deepBlue = Color(0xFF0A2342);

  static const light = Palette(
    isDark: false,
    bg: Color(0xFFF1F6FB),
    bgTop: Color(0xFFE2EEF9),
    plate: Color(0xFFFFFFFF),
    plateLine: Color(0xFFD6E3EF),
    ink: Color(0xFF0B1A2A),
    ink2: Color(0xFF4A6077),
    ink3: Color(0xFF8396AA),
    line: Color(0xFFE4ECF4),
    accent: Color(0xFF1D63AD),
    onAccent: Color(0xFFFFFFFF),
    live: Color(0xFFD5304A),
    sheet: Color(0xFFF7FAFD),
    frost: Color(0xFFE6F0FA),
    nav: Color(0xFFFBFDFF),
    control: Color(0xFF6F8399),
    women: Color(0xFFB9668A),
    men: Color(0xFF3D7CC0),
    pairs: Color(0xFF3A9294),
    dance: Color(0xFF8576C0),
  );
  static const dark = Palette(
    isDark: true,
    bg: Color(0xFF06101B),
    bgTop: Color(0xFF0B2036),
    plate: Color(0xFF0C1B2B),
    plateLine: Color(0xFF1A2F46),
    ink: Color(0xFFE8F1FA),
    ink2: Color(0xFF9CB1C6),
    ink3: Color(0xFF627990),
    line: Color(0xFF15283C),
    accent: Color(0xFF80BBF2),
    onAccent: Color(0xFF06101B),
    live: Color(0xFFFF6B78),
    sheet: Color(0xFF0A1726),
    frost: Color(0xFF132A42),
    nav: Color(0xFF081422),
    control: Color(0xFF6E86A0),
    women: Color(0xFFE59AB5),
    men: Color(0xFF7FB2E8),
    pairs: Color(0xFF6FCBC8),
    dance: Color(0xFFB3A6EC),
  );
  static Palette of(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? dark : light;

  /// Дорожка включённого переключателя: под белым бегунком не ниже 4.5:1.
  Color get switchOn => isDark ? iceBlue : accent;

  Color kind(String k) => switch (k) {
    'women' => women,
    'men' => men,
    'pairs' => pairs,
    'dance' => dance,
    _ => ink3,
  };
}

ThemeData _theme(Brightness b) {
  final p = b == Brightness.dark ? Palette.dark : Palette.light;
  final base = ThemeData(brightness: b, useMaterial3: true, colorSchemeSeed: Palette.iceBlue, fontFamily: 'Manrope');
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: p.accent,
      onPrimary: p.onAccent,
      surface: p.bg,
      onSurface: p.ink,
      outline: p.plateLine,
    ),
    dividerColor: p.line,
    splashFactory: InkRipple.splashFactory,
    highlightColor: p.accent.withValues(alpha: .06),
    splashColor: p.accent.withValues(alpha: .08),
    textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink, fontFamily: 'Manrope'),
    textSelectionTheme: TextSelectionThemeData(cursorColor: p.accent),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.sheet,
      surfaceTintColor: Colors.transparent,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      clipBehavior: Clip.antiAlias,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.ink,
      elevation: 0,
      titleTextStyle: TextStyle(fontFamily: 'Manrope', fontSize: 17, fontWeight: FontWeight.w600, color: p.ink),
    ),
    // включённый — белый бегунок на синем в обеих темах; в тёмной дорожка — синий из иконки
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : (p.isDark ? p.ink2 : Colors.white),
      ),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.switchOn : p.frost),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.switchOn : p.control),
      thumbIcon: const WidgetStatePropertyAll(null),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: p.ink.withValues(alpha: .92), borderRadius: BorderRadius.circular(8)),
      textStyle: TextStyle(fontFamily: 'Manrope', fontSize: 13, color: p.bg),
    ),
  );
}

class StartyApp extends StatefulWidget {
  const StartyApp({super.key});
  @override
  State<StartyApp> createState() => _StartyAppState();
}

class _StartyAppState extends State<StartyApp> {
  final state = AppState();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => MaterialApp(
      title: 'Фигурное катание',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: state.theme,
      // свайпы и мышью (веб-стенд); на телефоне — пальцем, как обычно
      scrollBehavior: const MaterialScrollBehavior().copyWith(dragDevices: PointerDeviceKind.values.toSet()),
      locale: const Locale('ru'),
      // крупный системный шрифт — до 130 %: дальше разметка теряет смысл
      builder: (context, child) => MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: _Wide(child: child!)),
      home: Home(state: state),
    ),
  );
}

class Home extends StatefulWidget {
  final AppState state;
  const Home({super.key, required this.state});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final _pages = PageController(initialPage: homeTab.value);

  /// homeTab меняют и снаружи (из листа старта — в «Настройки»): страницы догоняют.
  void _syncPage() {
    if (_pages.hasClients && (_pages.page ?? 0).round() != homeTab.value) {
      _pages.animateToPage(homeTab.value, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    }
  }

  AppState get state => widget.state;
  Timer? _tick, _refresh;
  UpdateInfo? update;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state.load();
    // раз в минуту: «идёт сейчас», кто уже откатал, отсчёт до начала
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
    // компьютер: фоновых задач у системы нет, пока приложение открыто — обновляем сами
    if (isDesktop) _refresh = Timer.periodic(const Duration(hours: 3), (_) => state.load());
    // на Android обновления ставятся сами (updater.dart); строка «Новая версия» — только для iPhone
    if (isIos) checkUpdate().then((u) => mounted && u != null ? setState(() => update = u) : null);
    Updates.instance.addListener(_onUpdates);
    homeTab.addListener(_syncPage);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onUpdates());
  }

  /// Однократные сообщения: «обновлено до …» и «вышла версия …».
  void _onUpdates() {
    if (!mounted) return;
    final u = Updates.instance;
    final done = u.takeUpdatedMessage();
    if (done != null) _say(done);
    final ready = u.takeReadyNotice();
    if (ready != null) {
      final s = u.state;
      // подпись — по действию: без разрешения кнопка ведёт к разрешению, а не к установке
      final action = s?.canInstall == false ? 'Разрешить' : (s?.needsHand == true ? 'Установить' : 'Сейчас');
      _say(ready, action: action, onAction: () {
        if (u.state?.canInstall == false) {
          u.allowInstall();
        } else {
          u.installNow();
        }
      });
    }
  }

  void _say(String text, {String? action, VoidCallback? onAction}) {
    final p = Palette.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text, style: TextStyle(fontFamily: 'Manrope', fontSize: 14.5, color: p.bg, height: 1.3)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        duration: const Duration(seconds: 6),
        action: action == null
            ? null
            : SnackBarAction(label: action, textColor: p.isDark ? Palette.light.accent : Palette.dark.accent, onPressed: onAction ?? () {}),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      state.load();
      state.refreshPermission();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _refresh?.cancel();
    Updates.instance.removeListener(_onUpdates);
    homeTab.removeListener(_syncPage);
    _pages.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    SystemChrome.setSystemUIOverlayStyle(
      p.isDark
          ? SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: p.nav)
          : SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: p.nav),
    );
    return ValueListenableBuilder<int>(
      valueListenable: homeTab,
      builder: (context, tab, _) => ListenableBuilder(
        listenable: state,
        builder: (context, _) => Scaffold(
          body: Column(
            children: [
              // область строки состояния — неподвижная и однотонная: содержимое под неё не заезжает,
              // значки системы всегда на ровном фоне
              Container(height: MediaQuery.paddingOf(context).top, color: Palette.of(context).bg),
              if (update != null) UpdateBar(info: update!, onClose: () => setState(() => update = null)),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  // вкладки листаются свайпом; в «Месяце» свайп по самому календарю листает месяцы
                  child: PageView(
                    controller: _pages,
                    physics: const _FirmPaging(),
                    onPageChanged: (i) => homeTab.value = i,
                    children: [
                      _Keep(FeedView(state: state)),
                      _Keep(MonthView(state: state)),
                      _Keep(SettingsView(state: state)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: IceNav(
            index: tab,
            onTap: (i) {
              homeTab.value = i;
              if (_pages.hasClients && (_pages.page ?? 0).round() != i) _pages.jumpToPage(i);
            },
            // в системе уведомления запрещены, а правила их ждут — точка у «Настроек»
            settingsDot: state.rules.on && state.allowed == false,
          ),
        ),
      ),
    );
  }
}

/// Широкое окно (компьютер): содержимое — колонкой по центру, как на телефоне, а не растянутое на весь экран.
class _Wide extends StatelessWidget {
  final Widget child;
  const _Wide({required this.child});
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w <= 760) return child;
    final p = Palette.of(context);
    return ColoredBox(
      color: p.isDark ? p.bgTop : p.line.withValues(alpha: .5),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ClipRect(child: child),
        ),
      ),
    );
  }
}

/// Вкладка не пересобирается при перелистывании: прокрутка и состояние остаются.
class _Keep extends StatefulWidget {
  final Widget child;
  const _Keep(this.child);
  @override
  State<_Keep> createState() => _KeepState();
}

class _KeepState extends State<_Keep> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Листание вкладок только намеренное: жест начинается после заметного сдвига, а страница
/// меняется, если протянули больше половины экрана или смахнули резко. Случайные касания
/// и диагональная прокрутка вкладки не переключают.
class _FirmPaging extends PageScrollPhysics {
  const _FirmPaging({super.parent});

  @override
  _FirmPaging applyTo(ScrollPhysics? ancestor) => _FirmPaging(parent: buildParent(ancestor));

  @override
  double? get dragStartDistanceMotionThreshold => 36;

  @override
  double get minFlingVelocity => 1400;

  @override
  double get minFlingDistance => 90;

  @override
  Tolerance toleranceFor(ScrollMetrics metrics) =>
      Tolerance(velocity: 1400, distance: 0.5, time: 0.001);
}
