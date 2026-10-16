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

  for (final width in [320.0, 360.0, 390.0, 430.0]) {
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

          // фильтр со спортсменом: строки найденных с фото и флажком;
          // без фильтра — кнопка в две строки: старты и турниры без расписания
          for (final f in [
            Filters({'pairs'}, {}, {...data.watchlist.where((n) => n.contains(' / ')).take(1)}),
            Filters.none,
          ]) {
            s.filters = f;
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
          }
        });
      }
    }
  }

  test('фильтр: «Все» и пункты в один тап', () {
    const all = {'women', 'men', 'pairs', 'dance'};
    // были все — остаётся только нажатый
    expect(pickChoice(all, all, 'pairs', many: true), {'pairs'});
    expect(pickChoice({'pairs'}, all, 'women', many: true), {'pairs', 'women'});
    // снят последний — снова все; отмечены все — тоже «все»
    expect(pickChoice({'pairs'}, all, 'pairs', many: true), all);
    expect(pickChoice({'women', 'men', 'pairs'}, all, 'dance', many: true), all);
    // из двух — один или оба
    const scope = {'russian', 'intl'};
    expect(pickChoice(scope, scope, 'intl', many: false), {'intl'});
    expect(pickChoice({'intl'}, scope, 'russian', many: false), {'russian'});
    expect(pickChoice({'intl'}, scope, 'intl', many: false), scope);
  });

  testWidgets('фильтр: один вид в один тап, «Сбросить» — только когда есть что сбрасывать', (t) async {
    final s = stateWith(data);
    await t.pumpWidget(app(
      Builder(builder: (c) => Center(child: TextButton(onPressed: () => showFilters(c, s), child: const Text('open')))),
      Brightness.dark,
      1,
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Сбросить'), findsNothing);
    await t.tap(find.text('Пары'));
    await t.pumpAndSettle();
    expect(find.text('Сбросить'), findsOneWidget);
    await t.tap(find.text('Сбросить'));
    await t.pumpAndSettle();
    expect(find.text('Сбросить'), findsNothing);
  });

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
    expect(filterTags(Filters.none), isEmpty);
    expect(filterTags(const Filters({'women', 'men'}, {'x'}, {})), ['2 вида', '1 турнир']);
    expect(filterTags(const Filters({'women', 'men'}, {'x'}, {'Мария Захарова'})), ['2 вида', '1 турнир', '1 спортсмен']);
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

  test('код страны для показа: AIN2 → RUS, AIN1 → BLR, остальное как есть', () {
    expect(nationCode('AIN2'), 'RUS');
    expect(nationCode(' ain1 '), 'BLR');
    expect(nationCode('AIN'), 'AIN');
    expect(nationCode('ISR'), 'ISR');
    expect(nationCode('RUS'), 'RUS');
    expect(nationCode('МОС'), 'МОС');
  });

  test('россиянин или белорус: RUS, AIN2, BLR, AIN1, регион; простой AIN — нет', () {
    Placing x(String n) => Placing(1, 'A B', n, '');
    expect(x('RUS').ours, isTrue);
    expect(x('AIN2').ours, isTrue);
    expect(x('МОС').ours, isTrue);
    expect(x('AIN').ours, isFalse);
    expect(x('AIN1').ours, isTrue);
    expect(x('BLR').ours, isTrue);
    expect(PlacingName.codeOf(x('AIN'), true), 'AIN');
    expect(PlacingName.codeOf(x('RUS'), true), 'RUS');
    expect(PlacingName.codeOf(x('AIN2'), true), 'RUS');
    expect(PlacingName.codeOf(x('BLR'), true), 'BLR');
    expect(PlacingName.codeOf(x('AIN1'), true), 'BLR');
  });

  test('подписи групп участников различают россиян и белорусов', () {
    Skater sk(String nation) => Skater('A B', null, null, null, null, null, nation);
    expect(oursLabel([sk('RUS')]), 'Россияне');
    expect(oursLabel([sk('AIN2')]), 'Россияне');
    expect(oursLabel([sk('BLR')]), 'Белорусы');
    expect(oursLabel([sk('AIN1')]), 'Белорусы');
    expect(oursLabel([sk('RUS'), sk('BLR')]), 'Россияне и белорусы');
    // «выход на лёд» — подписью над колонкой времени, а не через точку
    expect(oursLabel([sk('RUS'), sk('BLR')], exitTimes: true), 'Россияне и белорусы');
    expect(oursLabel([sk('МОС')]), 'Россияне');
    expect(oursLabel([sk('RUS')], intl: false), '');
    expect(oursLabel([sk('RUS'), sk('МОС')], exitTimes: true, intl: false), 'Выход на лёд');
  });

  testWidgets('карточка закрывается намеренным свайпом, а вся поверхность движется вместе', (t) async {
    final s = stateWith(data);
    final st = data.starts.first;
    await t.pumpWidget(app(
      Builder(
        builder: (c) => Center(
          child: TextButton(onPressed: () => showStart(c, st, s), child: const Text('open sheet')),
        ),
      ),
      Brightness.light,
      1,
    ));
    await t.tap(find.text('open sheet'));
    await t.pumpAndSettle();
    final sheet = find.byType(SheetScroll);
    expect(sheet, findsOneWidget);

    // Короткое движение не должно закрывать окно.
    var rect = t.getRect(sheet);
    await t.dragFrom(Offset(rect.center.dx, rect.top + 24), const Offset(0, 48));
    await t.pumpAndSettle();
    expect(sheet, findsOneWidget);

    // Длинный вертикальный жест: окно следует за пальцем до самого низа,
    // но закрывается только после отпускания.
    rect = t.getRect(sheet);
    final g = await t.startGesture(Offset(rect.center.dx, rect.top + 24));
    await g.moveBy(const Offset(0, 240));
    await t.pump();
    expect(sheet, findsOneWidget);
    await g.moveBy(const Offset(0, 480));
    await t.pump();
    expect(sheet, findsOneWidget); // уже у низа, но палец ещё не отпущен
    await g.up();
    await t.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('быстрый свайп вниз закрывает карточку целиком — без оставшегося затемнения', (t) async {
    final s = stateWith(data);
    final st = data.starts.first;
    await t.pumpWidget(app(
      Builder(
        builder: (c) => Center(
          child: TextButton(onPressed: () => showStart(c, st, s), child: const Text('open sheet')),
        ),
      ),
      Brightness.light,
      1,
    ));
    await t.tap(find.text('open sheet'));
    await t.pumpAndSettle();
    final sheet = find.byType(SheetScroll);
    final rect = t.getRect(sheet);
    // короткий, но резкий жест
    await t.flingFrom(Offset(rect.center.dx, rect.top + 24), const Offset(0, 160), 3000);
    await t.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(find.byType(ModalBarrier), findsNWidgets(1)); // только у самого приложения
    expect(find.text('open sheet'), findsOneWidget);
    await t.tap(find.text('open sheet'));
    await t.pumpAndSettle();
    expect(sheet, findsOneWidget); // экран не заблокирован
    expect(t.takeException(), isNull);
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

  test('лист фильтра: спортсмен только в заявке турнира без расписания — кнопка его считает', () {
    final t = now();
    String day(int d) => dayKey(t.add(Duration(days: d)));
    final u = Upcoming.fromJson({
      'tid': 'u',
      'name': 'U',
      'start': day(6),
      'end': day(9),
      'ours': ['Алина Горбачёва'],
    });
    final s = stateWith(Schedule(data.starts, t, true, false, upcoming: [u]));
    const f = Filters({}, {}, {'Алина Горбачёва'});
    // лента с этим выбором: стартов нет, турнир — в «Без расписания»
    expect(feedPool(s, f, t), isEmpty);
    expect(upcomingAhead(s, t, f).map((x) => x.tid), ['u']);
    // действующий фильтр ни при чём: лист считает свой выбор
    s.filters = const Filters({}, {}, {'Мария Захарова'});
    expect(upcomingAhead(s, t), isEmpty);
    expect(upcomingAhead(s, t, f), hasLength(1));
    expect(filterAction(0, 1), ('Показать 1 старт', null));
    expect(filterAction(0, 0), ('Впереди стартов нет', null));
    expect(filterAction(3, 0), ('Показать 3 старта', null));
    expect(filterAction(21, 15), ('Показать 36 стартов', null));
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
    expect(freshness(off).text, startsWith('Нет связи\nобновлено '));
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
