import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'background.dart';
import 'data.dart';
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
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.onAccent : (p.isDark ? p.ink2 : Colors.white),
      ),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.frost),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.control),
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
      locale: const Locale('ru'),
      // крупный системный шрифт — до 130 %: дальше разметка теряет смысл
      builder: (context, child) => MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: child!),
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
  AppState get state => widget.state;
  Timer? _tick;
  UpdateInfo? update;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state.load();
    // раз в минуту: «идёт сейчас», кто уже откатал, отсчёт до начала
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
    // на Android обновления ставятся сами (updater.dart); строка «Новая версия» — только для iPhone
    if (!kIsWeb && !Updates.native) checkUpdate().then((u) => mounted && u != null ? setState(() => update = u) : null);
    Updates.instance.addListener(_onUpdates);
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
      final hand = u.state?.needsHand == true;
      _say(ready, action: hand ? 'Установить' : 'Сейчас', onAction: () {
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
    Updates.instance.removeListener(_onUpdates);
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
              if (update != null)
                SafeArea(
                  bottom: false,
                  child: UpdateBar(info: update!, onClose: () => setState(() => update = null)),
                ),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: update != null,
                  child: IndexedStack(
                    index: tab,
                    children: [
                      FeedView(state: state),
                      MonthView(state: state),
                      SettingsView(state: state),
                    ],
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: IceNav(
            index: tab,
            onTap: (i) => homeTab.value = i,
            // в системе уведомления запрещены, а правила их ждут — точка у «Настроек»
            settingsDot: state.rules.on && state.allowed == false,
          ),
        ),
      ),
    );
  }
}
