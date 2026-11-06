// Состав (подписка): жеребьёвка и перемены в составе у отслеживаемых — сравнением с прошлым разом.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/billing.dart';
import 'package:starty/data.dart';
import 'package:starty/lineup.dart';
import 'package:starty/reminders.dart';
import 'package:starty/ui.dart' show nb;

final now = DateTime.parse('2026-11-10T12:00:00+03:00');
final follow = Follow(['Аделия Петросян', 'Алиса Двоеглазова'], russians: false, belarusians: false);

Map<String, Object?> _p(String name, {String? time, int? no}) => {'name': name, 'time': ?time, 'no': ?no};

/// Кубок России, женщины: короткая 12-го, произвольная 13-го.
Map<String, Object?> _start(String seg, List<Map<String, Object?>> field, {String tid = 'cup', bool regional = false}) {
  final day = seg == 'КП' ? '12' : '13';
  return {
    'id': '$tid-$seg', 'tid': tid, 'tournament': 'Кубок России', 'kind': 'women', 'level': 'senior', 'seg': seg,
    'title': 'Кубок России — женщины $seg', 'start': '2026-11-${day}T15:00:00+03:00', 'end': '2026-11-${day}T18:00:00+03:00',
    'venue': '', 'intl': false, if (regional) 'tier': 'regional', 'field': field,
  };
}

Map<String, Object?> _gp(List<String> athletes) => {
  'tid': 'gp', 'name': 'Гран-при Франции', 'venue': '', 'intl': true,
  'start': '2026-11-14', 'end': '2026-11-16', 'ours': athletes, 'athletes': athletes,
};

Schedule _sched(List<Map<String, Object?>> starts, {List<Map<String, Object?>> upcoming = const []}) =>
    Schedule.parse(jsonEncode({'generated': '2026-11-10T08:00:00+03:00', 'events': starts, 'upcoming': upcoming}));

final _others = [_p('Мария Захарова'), _p('Софья Муравьёва')];

/// Прошлый раз → этот раз: что нового.
List<LineupEvent> _step(Schedule before, Schedule after, {Follow? was, Follow? f, DateTime? at}) {
  final seen = Lineup.diff(null, before, was ?? follow, now).seen;
  return Lineup.diff(seen, after, f ?? follow, at ?? now).fresh;
}

void main() {
  test('первый раз — только запоминаем', () {
    final r = Lineup.diff(null, _sched([_start('КП', [_p('Аделия Петросян', time: '15:40', no: 12), ..._others])]), follow, now);
    expect(r.fresh, isEmpty);
    expect((r.seen['s'] as Map).keys, ['cup-КП']);
    // не отслеживаемых не храним
    expect(((r.seen['s'] as Map)['cup-КП'] as Map)['p'], {
      'аделия петросян': ['Аделия Петросян', '15:40'],
    });
  });

  group('жеребьёвка', () {
    test('появилось время выхода — номер и время, строка — турнир, вид и программа', () {
      final e = _step(
        _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]),
        _sched([_start('КП', [_p('Аделия Петросян', time: '15:40', no: 12), ..._others])]),
      ).single;
      expect(e.title, 'Аделия Петросян — 12-й номер, выход в 15:40');
      expect(e.lines, ['Жеребьёвка: Кубок России, женщины, короткая программа']);
      expect(e.startId, 'cup-КП');
      expect(e.group, 'cup');
      expect(e.at, now);
      // висит сутки (старт позже), показывать пропущенное — столько же
      expect(e.end, now.add(Lineup.keep));
      expect(e.late, e.end);
    });

    test('без номера — только время', () {
      final e = _step(
        _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]),
        _sched([_start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others])]),
      ).single;
      expect(e.title, 'Аделия Петросян — выход в 15:40');
    });

    test('двое в одном старте — одно уведомление, по строке на каждого по времени', () {
      final e = _step(
        _sched([_start('КП', [_p('Аделия Петросян'), _p('Алиса Двоеглазова'), ..._others])]),
        _sched([_start('КП', [_p('Аделия Петросян', time: '17:10', no: 20), _p('Алиса Двоеглазова', time: '15:40', no: 12), ..._others])]),
      ).single;
      expect(e.title, 'Жеребьёвка: Женщины, короткая программа');
      expect(e.lines, ['Кубок России', '15:40 — Алиса Двоеглазова, 12-й номер', '17:10 — Аделия Петросян, 20-й номер']);
      expect(e.collapsed, '15:40 — Алиса Двоеглазова, 12-й номер и ещё 1');
    });

    test('старт скоро — уведомление до его начала', () {
      final soon = DateTime.parse('2026-11-12T10:00:00+03:00');
      final e = _step(
        _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]),
        _sched([_start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others])]),
        at: soon,
      ).single;
      expect(e.end, DateTime.parse('2026-11-12T15:00:00+03:00'));
    });

    test('время было и сменилось — не жеребьёвка; начавшийся старт — молчим', () {
      expect(
        _step(
          _sched([_start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others])]),
          _sched([_start('КП', [_p('Аделия Петросян', time: '15:50'), ..._others])]),
        ),
        isEmpty,
      );
      expect(
        _step(
          _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]),
          _sched([_start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others])]),
          at: DateTime.parse('2026-11-12T15:10:00+03:00'),
        ),
        isEmpty,
      );
    });

    test('вышла в произвольную со временем — это жеребьёвка произвольной, а не «в составе»', () {
      final sp = _start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others]);
      final e = _step(_sched([sp, _start('ПП', [])]), _sched([sp, _start('ПП', [_p('Аделия Петросян', time: '16:20', no: 18)])])).single;
      expect(e.title, 'Аделия Петросян — 18-й номер, выход в 16:20');
      expect(e.lines, ['Жеребьёвка: Кубок России, женщины, произвольная программа']);
      // без времени — ничего: оно придёт следующей жеребьёвкой
      expect(_step(_sched([sp, _start('ПП', [])]), _sched([sp, _start('ПП', [_p('Аделия Петросян')])])), isEmpty);
    });

    test('короткая уже прошла, а произвольную только выложили — всё равно жеребьёвка, не «в составе»', () {
      final sp = _start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others]);
      final seen = Lineup.diff(null, _sched([sp]), follow, now).seen;
      final after = DateTime.parse('2026-11-12T19:00:00+03:00');
      // короткая началась: её только помним
      final mid = Lineup.diff(seen, _sched([sp]), follow, after).seen;
      expect((mid['s'] as Map).keys, ['cup-КП']);
      final e = Lineup.diff(mid, _sched([sp, _start('ПП', [_p('Аделия Петросян', time: '16:20')])]), follow, after).fresh.single;
      expect(e.title, 'Аделия Петросян — выход в 16:20');
    });
  });

  group('в составе', () {
    test('появилась в виде — одно уведомление на вид: турнир, вид, день первого старта', () {
      final e = _step(
        _sched([_start('КП', _others), _start('ПП', _others)]),
        _sched([_start('КП', [_p('Аделия Петросян'), ..._others]), _start('ПП', [_p('Аделия Петросян'), ..._others])]),
      ).single;
      expect(e.title, 'Аделия Петросян — в составе');
      expect(e.lines, ['Кубок России, женщины, 12$nbноября']);
      // старт не один — уведомление ведёт на турнир, а не на старт
      expect(e.startId, '');
      expect(e.group, 'cup');
    });

    test('в одном старте и со временем — программа и время выхода', () {
      final e = _step(
        _sched([_start('КП', _others)]),
        _sched([_start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others])]),
      ).single;
      expect(e.lines, ['Кубок России, женщины, короткая программа, 12$nbноября, выход в 15:40']);
      expect(e.startId, 'cup-КП');
    });

    test('новый турнир с расписанием сразу — тоже в составе', () {
      final e = _step(_sched([]), _sched([_start('КП', [_p('Аделия Петросян'), ..._others])])).single;
      expect(e.title, 'Аделия Петросян — в составе');
    });

    test('двое — одно уведомление со списком', () {
      final e = _step(
        _sched([_start('КП', _others)]),
        _sched([_start('КП', [_p('Аделия Петросян'), _p('Алиса Двоеглазова'), ..._others])]),
      ).single;
      // по алфавиту
      expect(e.title, 'В составе: Аделия Петросян, Алиса Двоеглазова');
    });

    test('только что начали отслеживать — не новость', () {
      expect(
        _step(
          _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]),
          _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]),
          was: Follow(const [], russians: false, belarusians: false),
        ),
        isEmpty,
      );
      expect(
        _step(
          _sched([_start('КП', _others)]),
          _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]),
          was: Follow(['Алиса Двоеглазова']),
        ),
        isEmpty,
      );
    });
  });

  group('больше не в составе', () {
    test('пропала из обоих стартов вида — одно уведомление, без программы и дня', () {
      final e = _step(
        _sched([_start('КП', [_p('Аделия Петросян'), ..._others]), _start('ПП', [_p('Аделия Петросян'), ..._others])]),
        _sched([_start('КП', _others), _start('ПП', _others)]),
      ).single;
      expect(e.title, 'Аделия Петросян — больше не в составе');
      expect(e.lines, ['Кубок России, женщины']);
    });

    test('пропала из одного — с программой', () {
      final e = _step(
        _sched([_start('КП', [_p('Аделия Петросян'), ..._others]), _start('ПП', [_p('Аделия Петросян'), ..._others])]),
        _sched([_start('КП', [_p('Аделия Петросян'), ..._others]), _start('ПП', _others)]),
      ).single;
      expect(e.lines, ['Кубок России, женщины, произвольная программа']);
      expect(e.startId, 'cup-ПП');
    });

    test('состав пропал целиком или старт исчез — сбой, а не снятие: молчим и помним прежнее', () {
      final had = _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]);
      final seen = Lineup.diff(null, had, follow, now).seen;
      for (final glitch in [_sched([_start('КП', [])]), _sched([])]) {
        final r = Lineup.diff(seen, glitch, follow, now);
        expect(r.fresh, isEmpty);
        // вернулся — не «в составе»
        expect(Lineup.diff(r.seen, had, follow, now).fresh, isEmpty);
      }
    });

    test('перестали отслеживать — не новость', () {
      expect(
        _step(
          _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]),
          _sched([_start('КП', _others)]),
          f: Follow(['Алиса Двоеглазова']),
        ),
        isEmpty,
      );
    });
  });

  group('турнир без расписания', () {
    test('появилась в заявке — турнир и день начала; пропала — турнир', () {
      final into = _step(_sched([], upcoming: [_gp(['Мария Захарова'])]), _sched([], upcoming: [_gp(['Мария Захарова', 'Аделия Петросян'])])).single;
      expect(into.title, 'Аделия Петросян — в составе');
      expect(into.lines, ['Гран-при Франции, с 14$nbноября']);
      expect(into.startId, '');
      expect(into.group, 'gp');
      final out = _step(_sched([], upcoming: [_gp(['Мария Захарова', 'Аделия Петросян'])]), _sched([], upcoming: [_gp(['Мария Захарова'])])).single;
      expect(out.title, 'Аделия Петросян — больше не в составе');
      expect(out.lines, ['Гран-при Франции']);
    });

    test('появилось расписание: была в заявке — не «в составе»; со временем выхода — жеребьёвка', () {
      final before = _sched([], upcoming: [_gp(['Аделия Петросян'])]);
      expect(_step(before, _sched([_start('КП', [_p('Аделия Петросян'), ..._others], tid: 'gp')])), isEmpty);
      final e = _step(before, _sched([_start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others], tid: 'gp')])).single;
      expect(e.title, 'Аделия Петросян — выход в 15:40');
      // заявку помним и после ухода турнира из «скоро»: состав вида выложили позже — всё равно не новость
      final seen = Lineup.diff(Lineup.diff(null, before, follow, now).seen, _sched([_start('КП', _others, tid: 'gp')]), follow, now).seen;
      expect(Lineup.diff(seen, _sched([_start('КП', [_p('Аделия Петросян'), ..._others], tid: 'gp')]), follow, now).fresh, isEmpty);
    });
  });

  group('хранение', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('первый раз запоминает, дальше находит; одно и то же не дублируется; истёкшее уходит', () async {
      final p = await SharedPreferences.getInstance();
      final a = _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]);
      final b = _sched([_start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others])]);
      expect(await Lineup.update(p, a, follow, now, on: true), isEmpty);
      final found = await Lineup.update(p, b, follow, now, on: true);
      expect(found.single.title, 'Аделия Петросян — выход в 15:40');
      // расписание не пришло — найденное остаётся (иначе уведомление снялось бы)
      expect((await Lineup.update(p, null, follow, now.add(const Duration(hours: 1)), on: true)).single.key, found.single.key);
      expect((await Lineup.update(p, b, follow, now.add(const Duration(hours: 2)), on: true)).single.at, now);
      expect(await Lineup.update(p, b, follow, now.add(const Duration(hours: 25)), on: true), isEmpty);
    });

    test('выключено — всё забыто: после включения первый раз снова только запоминает', () async {
      final p = await SharedPreferences.getInstance();
      final a = _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]);
      final b = _sched([_start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others])]);
      await Lineup.update(p, a, follow, now, on: true);
      expect(await Lineup.update(p, b, follow, now, on: false), isEmpty);
      expect(p.getKeys().where((k) => k.startsWith('j.')), isEmpty);
      expect(await Lineup.update(p, b, follow, now, on: true), isEmpty);
    });

    test('две сверки подряд без ожидания — найденное не теряется', () async {
      final p = await SharedPreferences.getInstance();
      final a = _sched([_start('КП', [_p('Аделия Петросян'), ..._others])]);
      final b = _sched([_start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others])]);
      await Lineup.update(p, a, follow, now, on: true);
      final r = await Future.wait([Lineup.update(p, b, follow, now, on: true), Lineup.update(p, b, follow, now, on: true)]);
      expect(r.last.length, 1);
      expect(Lineup.stored(p).length, 1);
    });

    test('доступ: нужна сборка с подпиской, право и включённый переключатель', () async {
      SharedPreferences.setMockInitialValues({
        BillingState.entKey: jsonEncode(Entitlement(checkedAt: now, paidUntil: now.add(const Duration(days: 20))).toJson()),
      });
      final p = await SharedPreferences.getInstance();
      expect(BillingState.lineupFor(p, now), isFalse);
      billingForce = true;
      addTearDown(() => billingForce = false);
      expect(BillingState.lineupFor(p, now), isTrue);
      await p.setBool(BillingState.lineupKey, false);
      expect(BillingState.lineupFor(p, now), isFalse);
      expect(BillingState.lineupFor(p, now.add(const Duration(days: 21))), isFalse);
    });
  });

  group('план уведомлений', () {
    final regional = _sched([
      _start('КП', [_p('Аделия Петросян'), ..._others], tid: 'reg', regional: true),
      _start('КП', [_p('Аделия Петросян'), ..._others]),
    ]);
    final events = [
      for (final tid in ['cup', 'reg'])
        _step(
          _sched([_start('КП', [_p('Аделия Петросян'), ..._others], tid: tid)]),
          _sched([_start('КП', [_p('Аделия Петросян', time: '15:40'), ..._others], tid: tid)]),
        ).single.planned(),
    ];

    test('показываются сразу, только по видимым турнирам и при включённых уведомлениях', () {
      // региональные выключены: в показанном расписании их нет — и уведомления о них нет
      final shown = regional.withStarts([for (final s in regional.starts) if (!s.regional) s]);
      final plan = Reminders.plan(shown, NotifyPlan(const NotifyRules(), const {}, const {}, events: events), now);
      final mine = plan.where((x) => x.key.startsWith('j:')).toList();
      expect(mine.map((x) => x.startId), ['cup-КП']);
      expect(mine.single.at, now);
      expect(mine.single.reminder, isFalse);
      final off = const NotifyRules().copyWith(on: false);
      expect(Reminders.plan(shown, NotifyPlan(off, const {}, const {}, events: events), now), isEmpty);
    });
  });
}
