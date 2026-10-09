// Разметка без переполнений: узкие и обычные экраны, обе темы, шрифт 100 % и 130 %.
// Шрифты — настоящие (Manrope, Cormorant): с тестовым шрифтом замеры ничего не значат.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/main.dart';
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
    // настоящее расписание с тройками и итогом турнира
    data = Schedule.parse(File('test/podium_sample.json').readAsStringSync());
  });

  AppState stateWith(Schedule d) => AppState()
    ..data = d
    ..loading = false;

  Widget app(Widget child, Brightness b, double scale) => MaterialApp(
    theme: ThemeData(brightness: b, fontFamily: 'Manrope'),
    builder: (c, nav) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: nav!),
    ),
    home: Scaffold(body: child),
  );

  Iterable<Start> pick(bool Function(Start) f) => data.starts.where(f).take(1);

  for (final width in [320.0, 360.0, 390.0]) {
    for (final b in Brightness.values) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('лента, месяц, настройки, листы — ${width.toInt()} px, $b, шрифт $scale', (t) async {
          t.view.physicalSize = Size(width * 3, 760 * 3);
          t.view.devicePixelRatio = 3;
          addTearDown(t.view.reset);
          final s = stateWith(data);
          // часть правил выключена — в ленте перечёркнутые колокольчики; при крупном шрифте —
          // ещё и запрет в системе, на узком экране — уведомления выключены совсем
          s.rules = s.rules.copyWith(kinds: {'women', 'men'}, on: width > 320 || b == Brightness.light);
          if (scale > 1) s.allowed = false;

          for (final view in [FeedView(state: s), MonthView(state: s), SettingsView(state: s)]) {
            await t.pumpWidget(app(view, b, scale));
            await t.pump(const Duration(milliseconds: 300));
            expect(t.takeException(), isNull);
            // прокрутить до конца: ленивые части тоже должны уложиться
            for (var i = 0; i < 8; i++) {
              await t.drag(find.byType(Scrollable).first, const Offset(0, -500), warnIfMissed: false);
              await t.pump(const Duration(milliseconds: 100));
            }
            expect(t.takeException(), isNull);
          }

          final t0 = now();
          final starts = [
            ...pick((x) => x.pastAt(t0) && x.podium.isNotEmpty && x.total.isNotEmpty),
            ...pick((x) => x.pastAt(t0) && x.podium.isNotEmpty && x.total.isEmpty),
            ...pick((x) => x.pastAt(t0) && x.podium.isEmpty),
            ...pick((x) => x.liveAt(t0)),
            ...pick((x) => x.t0.isAfter(t0) && x.ours.any((o) => o.time != null)),
            ...pick((x) => x.t0.isAfter(t0) && x.kind == 'dance'),
          ];
          expect(starts, isNotEmpty);
          for (final st in starts) {
            await t.pumpWidget(
              app(
                Builder(
                  builder: (c) => Center(
                    child: TextButton(onPressed: () => showStart(c, st, s), child: const Text('open')),
                  ),
                ),
                b,
                scale,
              ),
            );
            await t.tap(find.text('open'));
            await t.pumpAndSettle();
            expect(t.takeException(), isNull, reason: st.title);
          }

          await t.pumpWidget(
            app(
              Builder(
                builder: (c) => Center(
                  child: TextButton(onPressed: () => showFilters(c, s), child: const Text('open')),
                ),
              ),
              b,
              scale,
            ),
          );
          await t.tap(find.text('open'));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
        });
      }
    }
  }

  test('склонение', () {
    expect([1, 2, 5, 11, 21, 22, 25, 111].map((n) => plural(n, 'старт', 'старта', 'стартов')), [
      'старт',
      'старта',
      'стартов',
      'стартов',
      'старт',
      'старта',
      'стартов',
      'стартов',
    ]);
  });

  test('отсчёт до начала', () {
    expect(countdown(const Duration(minutes: 110)), 'через 1 ч 50 мин');
    expect(countdown(const Duration(minutes: 25)), 'через 25 мин');
    expect(countdown(const Duration(hours: 3)), 'через 3 ч');
  });

  test('сводка фильтра', () {
    expect(filterSummary(const Filters({}, {}, {})), 'Все старты');
    expect(filterSummary(const Filters({'women', 'men'}, {'x'}, {})), '2 вида · 1 турнир');
  });

  test('палитра: обводка флажков не ниже 3:1 к фону листа', () {
    double lum(Color c) => c.computeLuminance();
    double ratio(Color a, Color b) {
      final x = lum(a), y = lum(b);
      return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
    }

    expect(ratio(Palette.light.control, Palette.light.sheet), greaterThanOrEqualTo(3));
    expect(ratio(Palette.dark.control, Palette.dark.sheet), greaterThanOrEqualTo(3));
  });
}
