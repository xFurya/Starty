import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:starty_widget/starty_widget.dart';

import 'background.dart';
import 'data.dart';
import 'month_widget.dart';
import 'platform.dart';
import 'reminders.dart';
import 'settings.dart';
import 'state.dart';
import 'ui.dart';
import 'update.dart';
import 'app_icon.dart';
import 'desktop_updater.dart' show handOffToInstalled;
import 'updater.dart';
import 'palette.dart';
import 'views.dart';

export 'palette.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Windows: старая копия из архива уступает установленной
  if (await handOffToInstalled()) exit(0);
  await Prefs.init();
  runApp(const StartyApp());
  // уведомления настраиваются после показа экрана: их сбой не должен мешать запуску
  try {
    await Reminders.init();
  } catch (_) {}
  await scheduleBackground();
  // компьютер: значок окна и Дока по выбору
  unawaited(AppIcons.applyDesktop());
  // самообновление: состояние с нативной стороны, «обновлено до …» один раз
  await Updates.instance.init();
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
  final _nav = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => MaterialApp(
      navigatorKey: _nav,
      title: 'Фигурное катание',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: state.theme,
      // свайпы и мышью (веб-стенд); на телефоне — пальцем, как обычно
      scrollBehavior: const MaterialScrollBehavior().copyWith(dragDevices: PointerDeviceKind.values.toSet()),
      locale: const Locale('ru'),
      // крупный системный шрифт — до 130 %: дальше разметка теряет смысл
      builder: (context, child) => MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: AppFrame(nav: _nav, settingsDot: state.rules.on && state.allowed == false, child: child!)),
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

  /// Виджет «Месяц» на рабочем столе (Android): расписание, фильтр и подписка — ему.
  final _widget = MonthWidgetSync();
  void _syncWidget() => _widget.update(state.data, state.filters, state.billing.entitlement);

  /// Нажали на виджет: день, месяц или страница подписки.
  void _fromWidget(String? what) {
    if (what == null || !mounted) return;
    openFromWidget(context, what, billing: () => openBilling(context, state));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state.load().then((_) => state.startLive());
    // раз в минуту: «идёт сейчас», кто уже откатал, отсчёт до начала
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
    // компьютер: фоновых задач у системы нет, пока приложение открыто — обновляем сами
    if (isDesktop) _refresh = Timer.periodic(const Duration(hours: 3), (_) => state.load());
    // на Android обновления ставятся сами (updater.dart); строка «Новая версия» — только для iPhone
    if (isIos) checkUpdate().then((u) => mounted && u != null ? setState(() => update = u) : null);
    Updates.instance.addListener(_onUpdates);
    homeTab.addListener(_syncPage);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onUpdates());
    if (isAndroid) {
      state.addListener(_syncWidget);
      _syncWidget();
      MonthWidget.listen(_fromWidget);
      MonthWidget.takeOpen().then(_fromWidget);
    }
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
      state.startLive();
    } else if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      state.stopLive();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    state.stopLive();
    _refresh?.cancel();
    Updates.instance.removeListener(_onUpdates);
    homeTab.removeListener(_syncPage);
    state.removeListener(_syncWidget);
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
                    // компьютер — разделы только панелью: мышь тянет страницу случайно
                    physics: navPlace(context) == NavPlace.side ? const NeverScrollableScrollPhysics() : const _FirmPaging(),
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
          bottomNavigationBar: navPlace(context) != NavPlace.bottom ? null : IceNav(
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

/// Панель разделов слева, когда снизу ей не место: компьютер и планшет — широкая, телефон
/// боком — узкая. Содержимое — колонкой по центру остального места, а не растянутое на всё окно.
/// Дерево одно и то же при любой форме окна: поворот телефона не пересоздаёт навигатор —
/// открытый протокол, лист и прокрутка остаются.
class AppFrame extends StatelessWidget {
  final Widget child;
  final GlobalKey<NavigatorState> nav;
  final bool settingsDot;
  const AppFrame({super.key, required this.child, required this.nav, required this.settingsDot});
  @override
  Widget build(BuildContext context) {
    final place = navPlace(context);
    final framed = place != NavPlace.bottom;
    final p = Palette.of(context);
    void go(int i) {
      nav.currentState?.popUntil((r) => r.isFirst);
      homeTab.value = i;
    }

    return ColoredBox(
      color: p.bg,
      child: Row(
        children: [
          switch (place) {
            NavPlace.rail => RailNav(onTap: go, settingsDot: settingsDot),
            NavPlace.side => SideNav(onTap: go, settingsDot: settingsDot),
            NavPlace.bottom => const SizedBox.shrink(),
          },
          Expanded(
            child: ColoredBox(
              color: !framed ? p.bg : (p.isDark ? p.bgTop : p.line.withValues(alpha: .5)),
              // слева вырез камеры обошла панель; справа его (и кнопки системы) обходит колонка
              child: Padding(
                padding: EdgeInsets.only(right: framed ? MediaQuery.paddingOf(context).right : 0),
                child: MediaQuery.removePadding(
                  context: context,
                  removeLeft: framed,
                  removeRight: framed,
                  // телефон боком — во всю ширину: поля по краям отняли бы место, которого и так мало
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: place == NavPlace.side ? 720 : double.infinity),
                      child: ClipRect(child: child),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
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
