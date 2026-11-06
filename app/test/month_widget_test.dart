// Виджет «Месяц» (подписка): какие дни он отмечает, что ему уходит, цвета — те же, что в приложении,
// и нажатие открывает вкладку «Месяц» на нужном дне.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/billing.dart';
import 'package:starty/data.dart';
import 'package:starty/month_widget.dart';
import 'package:starty/palette.dart';
import 'package:starty/state.dart';
import 'package:starty/ui.dart';
import 'package:starty/views.dart';

Start _start(String id, String kind, String day, {bool intl = false, String tid = 't', String level = 'senior'}) =>
    Start.fromJson({
      'id': id, 'tid': tid, 'tournament': 'Кубок $tid', 'kind': kind, 'level': level, 'seg': 'КП',
      'title': 'Кубок $tid — $kind КП', 'start': '${day}T10:00:00+03:00', 'end': '${day}T13:00:00+03:00',
      'venue': '', 'intl': intl, 'ours': [],
    });

Upcoming _upcoming(String tid, String start, String end, {bool intl = false}) =>
    Upcoming.fromJson({'tid': tid, 'name': 'Турнир $tid', 'start': start, 'end': end, 'intl': intl});

Schedule _schedule({bool complete = true, Map<String, String> sources = const {}}) => Schedule(
  [
    _start('a', 'women', '2026-11-12'),
    _start('b', 'men', '2026-11-12'),
    _start('c', 'pairs', '2026-11-13', tid: 'r'),
    _start('d', 'dance', '2026-11-14'),
    _start('e', 'synchro', '2026-11-15'),
    // международный без наших — не показан и в месяце приложения
    _start('f', 'women', '2026-11-16', intl: true),
  ],
  DateTime.utc(2026, 11, 6, 6, 19),
  complete,
  false,
  upcoming: [_upcoming('u', '2026-11-29', '2026-12-02'), _upcoming('x', '2026-11-20', '2026-11-21', intl: true)],
  sources: sources,
);

Entitlement _ent(DateTime until, {bool autoRenew = false, Duration skew = Duration.zero}) =>
    Entitlement(checkedAt: DateTime.utc(2026, 11, 6), paidUntil: until, autoRenew: autoRenew, skew: skew);

void main() {
  final t = DateTime.utc(2026, 11, 6, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
    billingForce = true;
  });
  tearDown(() => billingForce = false);

  test('дни: точка вида у каждого старта под фильтром, полая — каждый день турнира без расписания', () {
    final d = widgetDays(_schedule(), Filters.none);
    expect(d['2026-11-12'], widgetWomen | widgetMen);
    expect(d['2026-11-13'], widgetPairs);
    expect(d['2026-11-14'], widgetDance);
    expect(d['2026-11-15'], widgetOther);
    // как вкладка «Месяц»: международного без наших нет
    expect(d.containsKey('2026-11-16'), isFalse);
    expect(d.containsKey('2026-11-20'), isFalse);
    // турнир через границу месяца — все четыре дня
    for (final k in ['2026-11-29', '2026-11-30', '2026-12-01', '2026-12-02']) {
      expect(d[k], widgetHollow, reason: k);
    }
    expect(d.containsKey('2026-12-03'), isFalse);
  });

  test('дни: тот же фильтр, что у ленты и месяца', () {
    final d = widgetDays(_schedule(), const Filters({'men'}, {}, {}));
    expect(d['2026-11-12'], widgetMen);
    expect(d.containsKey('2026-11-13'), isFalse);
    // турнир без расписания виды не отсекают — как в приложении
    expect(d['2026-11-29'], widgetHollow);
    final byTournament = widgetDays(_schedule(), const Filters({}, {'r'}, {}));
    expect(byTournament.keys, ['2026-11-13']);
  });

  test('данные: месяц, когда обновлено, честная строка о сбое, фильтр, срок подписки по часам телефона', () {
    final until = DateTime.utc(2026, 12, 5, 9);
    final j = jsonDecode(widgetJson(
      data: _schedule(complete: false, sources: {'ФФККР': 'fail', 'ISU': 'ok'}),
      filters: const Filters({'women'}, {}, {}),
      ent: _ent(until, skew: const Duration(minutes: 2)),
      now: t,
    )) as Map;
    expect(j['mode'], 'on');
    // часы сервера на 2 минуты впереди: на телефоне подписка кончится на 2 минуты раньше
    expect(j['until'], until.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch);
    expect(j['generated'], DateTime.utc(2026, 11, 6, 6, 19).millisecondsSinceEpoch);
    expect(j['trouble'], 'ФФККР не отвечает');
    expect(j['filter'], 'Женщины (девушки)');
    expect((j['days'] as Map)['2026-11-12'], widgetWomen);
    // кончится без приложения — закроется с понятной причиной и откроет подписку
    expect(j['lockTitle'], 'Виджет «Месяц» входит в\u00a0подписку');
    expect(j['lockText'], 'Подписка закончилась 5 декабря');
    expect(j['lockOpen'], 'billing');
    expect(j['lockAction'], 'Открыть подписку');
  });

  test('данные: всё в порядке — ни сбоя, ни фильтра; продление — виджет не утверждает, что кончилась', () {
    final j = jsonDecode(widgetJson(data: _schedule(), filters: Filters.none, ent: _ent(DateTime.utc(2026, 12, 5), autoRenew: true), now: t)) as Map;
    expect(j['trouble'], '');
    expect(j['filter'], '');
    expect(j['lockText'], 'Оплачено до 5 декабря. Откройте приложение, чтобы проверить продление');
    final two = jsonDecode(widgetJson(
      data: _schedule(complete: false, sources: {'ФФККР': 'fail', 'ISU': 'fail'}),
      filters: Filters.none,
      ent: _ent(DateTime.utc(2026, 12, 5)),
      now: t,
    )) as Map;
    expect(two['trouble'], 'Источники не отвечают');
  });

  test('без подписки: виджет закрыт и говорит почему; дней ему не уходит', () {
    final none = jsonDecode(widgetJson(data: _schedule(), filters: Filters.none, ent: null, now: t)) as Map;
    expect(none['mode'], 'locked');
    expect(none.containsKey('days'), isFalse);
    expect(none['lockText'], 'Подписки нет');
    expect(none['lockOpen'], 'billing');
    final ended = jsonDecode(widgetJson(data: _schedule(), filters: Filters.none, ent: _ent(DateTime.utc(2026, 11, 1)), now: t)) as Map;
    expect(ended['mode'], 'locked');
    expect(ended['lockText'], 'Подписка закончилась 1 ноября');
    // сборка без подписки: открывать нечего
    billingForce = false;
    final off = jsonDecode(widgetJson(data: _schedule(), filters: Filters.none, ent: _ent(DateTime.utc(2026, 12, 5)), now: t)) as Map;
    expect(off['mode'], 'locked');
    expect(off['lockTitle'], 'Виджет «Месяц» недоступен');
    expect(off['lockOpen'], '');
    expect(off['lockAction'], '');
  });

  test('цвета виджета — палитра приложения, светлая и тёмная', () {
    const res = 'packages/starty_widget/android/src/main/res';
    for (final (dir, p) in [('values', Palette.light), ('values-night', Palette.dark)]) {
      final xml = File('$res/$dir/colors.xml').readAsStringSync();
      final colors = {
        for (final m in RegExp(r'<color name="widget_(\w+)">#([0-9A-Fa-f]{8})</color>').allMatches(xml))
          m.group(1)!: int.parse(m.group(2)!, radix: 16),
      };
      final want = {
        'plate': p.plate,
        'plate_line': p.plateLine,
        'frost': p.frost,
        'ink': p.ink,
        'ink2': p.ink2,
        'ink3': p.ink3,
        'accent': p.accent,
        'live': p.live,
        'women': p.women,
        'men': p.men,
        'pairs': p.pairs,
        'dance': p.dance,
      };
      expect(colors.keys.toSet(), want.keys.toSet(), reason: dir);
      for (final e in want.entries) {
        expect(colors[e.key]!.toRadixString(16), e.value.toARGB32().toRadixString(16), reason: '$dir ${e.key}');
      }
    }
  });

  testWidgets('нажатие на день виджета: вкладка «Месяц» на этом месяце и дне', (tester) async {
    final st = AppState()
      ..data = _schedule()
      ..loading = false;
    monthOpen.value = '2027-01-15';
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MonthView(state: st))));
    await tester.pump();
    expect(find.text('Январь'), findsOneWidget);
    expect(monthOpen.value, isNull);
    // уже открытая вкладка — тоже переходит
    monthOpen.value = '2026-11';
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Ноябрь'), findsOneWidget);
    expect(monthOpen.value, isNull);
  });
}
