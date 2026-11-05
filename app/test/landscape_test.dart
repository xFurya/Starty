// Телефон боком и окно компьютера: где панель разделов, шапки в строку, месяц рядом с днём,
// листы без переполнений. Шрифты настоящие — с тестовым замеры ничего не значат.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/main.dart';
import 'package:starty/profile.dart';
import 'package:starty/settings.dart';
import 'package:starty/sheets.dart';
import 'package:starty/state.dart';
import 'package:starty/ui.dart';
import 'package:starty/views.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync())));
  }
  await l.load();
}

void main() {
  late Schedule data;

  setUpAll(() async {
    await _font('Manrope', [
      'Manrope-Light.ttf',
      'Manrope-Regular.ttf',
      'Manrope-Medium.ttf',
      'Manrope-SemiBold.ttf',
      'Manrope-Bold.ttf',
    ]);
    await _font('Cormorant', ['CormorantGaramond-SemiBold.ttf', 'CormorantGaramond-Bold.ttf']);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
    data = Schedule.parse(File('test/podium_sample.json').readAsStringSync());
    homeTab.value = 0;
    profileLoader = (_) async => null;
  });

  AppState stateWith(Schedule d) => AppState()
    ..data = d
    ..loading = false;

  // как в приложении: рамка с панелью разделов вокруг навигатора
  Widget app(Widget child, Brightness b, double scale) => MaterialApp(
    key: UniqueKey(),
    theme: ThemeData(brightness: b, fontFamily: 'Manrope'),
    builder: (c, nav) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: AppFrame(nav: GlobalKey<NavigatorState>(), settingsDot: true, child: nav!),
      ),
    ),
    home: Scaffold(body: child),
  );

  void size(WidgetTester t, double w, double h, {double cutout = 0}) {
    t.view.physicalSize = Size(w * 3, h * 3);
    t.view.devicePixelRatio = 3;
    // вырез камеры слева и строка состояния — как у телефона боком
    t.view.padding = FakeViewPadding(left: cutout * 3, top: cutout > 0 ? 24 * 3 : 0);
    addTearDown(t.view.reset);
  }

  testWidgets('где панель разделов: снизу стоя, узкая слева боком, широкая на компьютере', (t) async {
    final got = <String, NavPlace>{};
    for (final (w, h) in [(390.0, 844.0), (780.0, 360.0), (915.0, 412.0), (1280.0, 800.0), (800.0, 600.0), (1180.0, 820.0)]) {
      size(t, w, h);
      await t.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        got['${w.toInt()}x${h.toInt()}'] = navPlace(c);
        return const SizedBox();
      })));
    }
    expect(got, {
      '390x844': NavPlace.bottom,
      '780x360': NavPlace.rail,
      '915x412': NavPlace.rail,
      '1280x800': NavPlace.side,
      '800x600': NavPlace.bottom,
      '1180x820': NavPlace.side,
    });
  });

  for (final (w, h, cut) in [(780.0, 360.0, 0.0), (915.0, 412.0, 0.0), (844.0, 390.0, 44.0)]) {
    for (final b in Brightness.values) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('боком ${w.toInt()}×${h.toInt()}${cut > 0 ? ' с вырезом' : ''}, $b, шрифт $scale', (t) async {
          size(t, w, h, cutout: cut);
          final s = stateWith(data);
          for (final view in [FeedView(state: s), MonthView(state: s), SettingsView(state: s)]) {
            await t.pumpWidget(app(view, b, scale));
            await t.pump(const Duration(milliseconds: 300));
            expect(t.takeException(), isNull);
            expect(find.byType(RailNav), findsOneWidget);
            expect(find.byType(IceNav), findsNothing);
            // панель обходит вырез: её ширина — свои 84 и вырез
            expect(t.getSize(find.byType(RailNav)).width, RailNav.width + cut);
            // шапка в одну строку — не выше 100, сколько бы ни было кнопок
            final hero = t.getRect(find.byType(IceHero).first);
            expect(hero.height, lessThan(scale > 1 ? 110 : 100));
            // содержимое — правее панели, под вырез не заходит
            expect(hero.left, greaterThanOrEqualTo(RailNav.width + cut));
            for (final sc in find.byType(Scrollable).evaluate().toList()) {
              for (var i = 0; i < 6; i++) {
                await t.drag(find.byWidget(sc.widget), const Offset(0, -400), warnIfMissed: false);
                await t.pump(const Duration(milliseconds: 100));
              }
            }
            expect(t.takeException(), isNull);
          }

          // лист старта (время в шапке справа) и профиль (фото слева от имени)
          final t0 = now();
          final starts = [
            ...data.starts.where((x) => x.pastAt(t0) && x.podium.isNotEmpty).take(1),
            ...data.starts.where((x) => x.t0.isAfter(t0) && x.ours.any((o) => o.time != null)).take(1),
          ];
          expect(starts, isNotEmpty);
          for (final st in starts) {
            await t.pumpWidget(app(
              Builder(builder: (c) => Center(child: TextButton(onPressed: () => showStart(c, st, s), child: const Text('open')))),
              b,
              scale,
            ));
            await t.tap(find.text('open'));
            await t.pumpAndSettle();
            expect(t.takeException(), isNull, reason: st.title);
          }
          final who = data.starts.expand((x) => x.ours).map((o) => o.name).firstWhere((n) => !n.contains(' / '));
          await t.pumpWidget(app(
            Builder(builder: (c) => Center(child: TextButton(onPressed: () => showProfile(c, who, data), child: const Text('open')))),
            b,
            scale,
          ));
          await t.tap(find.text('open'));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          final avatar = t.getRect(find.descendant(of: find.byType(ProfileSheet), matching: find.byType(Avatar)).first);
          final name = t.getRect(find.descendant(of: find.byType(ProfileSheet), matching: find.text(displayName(who))).first);
          expect(name.left, greaterThan(avatar.right), reason: 'имя справа от фото');
        });
      }
    }
  }

  testWidgets('месяц боком: календарь и старты выбранного дня видны сразу, без прокрутки', (t) async {
    size(t, 780, 360);
    final s = stateWith(data);
    await t.pumpWidget(app(MonthView(state: s), Brightness.dark, 1));
    await t.pump(const Duration(milliseconds: 300));
    final day = t.getRect(find.byType(DayHeader));
    final grid = t.getRect(find.byType(Plate).first);
    expect(day.left, greaterThan(grid.right - 1), reason: 'день справа от месяца');
    expect(day.top, lessThan(360));
  });

  testWidgets('месяц стоя — по-прежнему день под календарём', (t) async {
    size(t, 390, 844);
    final s = stateWith(data);
    await t.pumpWidget(app(MonthView(state: s), Brightness.light, 1));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(RailNav), findsNothing);
    final day = t.getRect(find.byType(DayHeader));
    final grid = t.getRect(find.byType(Plate).first);
    expect(day.top, greaterThan(grid.bottom - 1));
  });

  testWidgets('узкая панель: разделы по нажатию', (t) async {
    size(t, 780, 360);
    final s = stateWith(data);
    await t.pumpWidget(app(FeedView(state: s), Brightness.light, 1));
    await t.pump();
    await t.tap(find.descendant(of: find.byType(RailNav), matching: find.text('Месяц')));
    await t.pump();
    expect(homeTab.value, 1);
    await t.tap(find.descendant(of: find.byType(RailNav), matching: find.text('Настройки')));
    await t.pump();
    expect(homeTab.value, tabSettings);
  });

  testWidgets('поворот телефона не сбрасывает открытый экран и его состояние', (t) async {
    size(t, 390, 844);
    final nav = GlobalKey<NavigatorState>();
    final counter = GlobalKey<_CounterState>();
    await t.pumpWidget(MaterialApp(
      navigatorKey: nav,
      builder: (c, n) => AppFrame(nav: nav, settingsDot: false, child: n!),
      home: const Scaffold(body: Text('главный')),
    ));
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: _Counter(key: counter))));
    await t.pumpAndSettle();
    counter.currentState!.bump();
    for (final (w, h) in [(844.0, 390.0), (390.0, 844.0), (1280.0, 800.0), (780.0, 360.0)]) {
      size(t, w, h);
      await t.pumpAndSettle();
      expect(find.byType(_Counter), findsOneWidget, reason: '${w}x$h');
      expect(counter.currentState!.n, 1, reason: 'состояние экрана осталось при ${w}x$h');
    }
    expect(find.byType(RailNav), findsOneWidget);
  });
}

class _Counter extends StatefulWidget {
  const _Counter({super.key});
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  var n = 0;
  void bump() => setState(() => n++);
  @override
  Widget build(BuildContext context) => Text('$n');
}
