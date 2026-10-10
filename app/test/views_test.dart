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

  // новый ключ — новое приложение: лист прошлого шага не остаётся открытым поверх кнопки
  Widget app(Widget child, Brightness b, double scale) => MaterialApp(
    key: UniqueKey(),
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

          // фильтр со спортсменом: строки найденных с фото и флажком
          s.filters = Filters({'pairs'}, {}, {...data.watchlist.where((n) => n.contains(' / ')).take(1)});
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

  test('отсчёт до начала — одной строкой, без обычных пробелов', () {
    String plain(String x) => x.replaceAll(nb, ' ');
    expect(plain(countdown(const Duration(minutes: 110))), 'через 1 ч 50 мин');
    expect(plain(countdown(const Duration(minutes: 25))), 'через 25 мин');
    expect(plain(countdown(const Duration(hours: 3))), 'через 3 ч');
    expect(countdown(const Duration(minutes: 110)), isNot(contains(' ')));
  });

  test('фильтр ленты: виды, турниры, спортсмен; сводка в настройках', () {
    expect(filterSummary(Filters.none), 'Все старты');
    expect(filterSummary(const Filters({'women', 'men'}, {'x'}, {})), '2 вида · 1 турнир');
    expect(filterSummary(const Filters({'women', 'men'}, {'x'}, {'Мария Захарова'})), '2 вида · 1 турнир · 1 спортсмен');
    // спортсмен: только старты, где он есть среди наших или в списке участников
    final s = data.starts.firstWhere((x) => x.ours.isNotEmpty);
    final name = s.ours.first.name;
    final f = Filters({}, {}, {name.toUpperCase()});
    expect(f.pass(s), isTrue);
    expect(data.starts.where(f.pass).every((x) => [...x.athletes, ...x.ours.map((o) => o.name)].contains(name)), isTrue);
    expect(data.starts.where((x) => !Filters({}, {}, {name}).pass(x)), isNotEmpty);
    // турнир без расписания — по заявке наших
    final u = Upcoming.fromJson({'tid': 'u', 'name': 'U', 'start': '2026-10-15', 'ours': ['Мария Захарова']});
    expect(const Filters({}, {}, {'Мария Захарова'}).passUpcoming(u), isTrue);
    expect(const Filters({}, {}, {'Алина Горбачёва'}).passUpcoming(u), isFalse);
  });

  test('имя пары: партнёр не теряется ни в одном варианте', () {
    const pair = 'Екатерина Рыбакова / Иван Махноносов';
    final v = nameVariants(pair, lines: 2);
    expect(v.first, ['Екатерина Рыбакова / Иван Махноносов']);
    expect(v, contains(equals(['Екатерина Рыбакова /', 'Иван Махноносов'])));
    expect(v, contains(equals(['Рыбакова / Махноносов'])));
    expect(v.last, ['Рыбакова /', 'Махноносов']);
    for (final x in v) {
      expect(x.join(' '), contains('Махноносов'));
      expect(x.where((l) => l.trim() == '/'), isEmpty);
    }
    expect(nameVariants('Kaori SAKAMOTO', initial: true, full: false), [
      ['K. Sakamoto'],
      ['Sakamoto'],
    ]);
  });

  test('наш: RUS, AIN2, регион; простой AIN и AIN1 — нет', () {
    Placing x(String n) => Placing(1, 'A B', n, '');
    expect(x('RUS').ours, isTrue);
    expect(x('AIN2').ours, isTrue);
    expect(x('МОС').ours, isTrue);
    expect(x('AIN').ours, isFalse);
    expect(x('AIN1').ours, isFalse);
    expect(PlacingName.codeOf(x('AIN'), true), 'AIN');
    expect(PlacingName.codeOf(x('AIN2'), true), '');
  });

  test('турниры без расписания: разбор, дни, лента', () {
    final d = Schedule.parse(File('test/events_sample.json').readAsStringSync());
    final s = stateWith(d);
    if (d.upcoming.isEmpty) return;
    final u = d.upcoming.first;
    expect(u.covers(u.start), isTrue);
    expect(u.covers(u.end), isTrue);
    expect(upcomingOn(s, u.start).map((x) => x.tid), contains(u.tid));
    s.filters = const Filters({}, {'другой'}, {});
    expect(upcomingOn(s, u.start), isEmpty);
  });

  test('свежесть расписания: без предлога перед «сегодня», тревога — по делу', () {
    final s = stateWith(data);
    final f = freshness(s);
    expect(f.text, isNot(contains('от сегодня')));
    final g = Schedule(data.starts, now().subtract(const Duration(hours: 17)), true, false);
    // 17 ч — обычный перерыв между запусками (09:00 и 15:00 МСК): не тревожно
    expect(freshness(stateWith(g)).alarm, isFalse);
    final old = Schedule(data.starts, now().subtract(const Duration(hours: 21)), true, false);
    expect(freshness(stateWith(old)).alarm, isTrue);
    expect(freshness(stateWith(old)).text, startsWith('Расписание устарело'));
    final bad = Schedule(data.starts, now(), false, false, sources: const {'ФФККР': 'ok', 'ISU': 'fail'});
    expect(freshness(stateWith(bad)).text, startsWith('ISU не отвечает'));
    final off = stateWith(data)..offline = true;
    expect(freshness(off).text, startsWith('Нет связи · обновлено '));
  });

  test('исключения: считаются только действующие', () {
    final s = stateWith(data);
    final t = now();
    final past = data.starts.firstWhere((x) => x.pastAt(t));
    final ahead = data.starts.firstWhere((x) => x.t0.subtract(const Duration(hours: 1)).isAfter(t));
    s.forcedOff = {past.id, ahead.id};
    expect(activeExceptions(s), 1);
    // правила сами исключили этот вид — исключение лишнее
    s.rules = s.rules.copyWith(kinds: {...s.rules.kinds}..remove(ahead.kind));
    expect(activeExceptions(s), 0);
  });

  test('палитра: обводка флажков не ниже 3:1 к фону листа', () {
    double lum(Color c) => c.computeLuminance();
    double ratio(Color a, Color b) {
      final x = lum(a), y = lum(b);
      return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
    }

    expect(ratio(Palette.light.control, Palette.light.sheet), greaterThanOrEqualTo(3));
    expect(ratio(Palette.dark.control, Palette.dark.sheet), greaterThanOrEqualTo(3));
    // подписи разделов (ink2) — не ниже 4.5:1 к фону и к плашке
    for (final p in [Palette.light, Palette.dark]) {
      expect(ratio(p.ink2, p.bg), greaterThanOrEqualTo(4.5));
      expect(ratio(p.ink2, p.plate), greaterThanOrEqualTo(4.5));
      // включённый переключатель: белый бегунок на дорожке
      expect(ratio(Colors.white, p.switchOn), greaterThanOrEqualTo(4.5));
      // перечёркнутый колокольчик различим на плашке
      expect(ratio(p.control, p.plate), greaterThanOrEqualTo(3));
    }
  });
}
