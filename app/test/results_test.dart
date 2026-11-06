// Итоги ваших (подписка): место и баллы отслеживаемого в уведомлении, когда он выступил.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/background.dart';
import 'package:starty/billing.dart';
import 'package:starty/data.dart';
import 'package:starty/reminders.dart';

/// Старт идёт: 15:00–18:00 по Москве, сейчас 16:30.
final now = DateTime.parse('2026-11-12T16:30:00+03:00');
final follow = Follow(['Аделия Петросян', 'Алиса Двоеглазова'], russians: false, belarusians: false);

Map<String, Object?> _p(String name, {int? place, String? points, int? overall, String? time}) =>
    {'name': name, 'time': ?time, 'place': ?place, 'points': ?points, 'final': ?overall};

Map<String, Object?> _start(List<Map<String, Object?>> field, {bool provisional = true, String start = '15:00'}) => {
  'id': 'cup-КП', 'tid': 'cup', 'tournament': 'Кубок России', 'kind': 'women', 'level': 'senior', 'seg': 'КП',
  'title': 'Кубок России — женщины КП', 'start': '2026-11-12T$start:00+03:00', 'end': '2026-11-12T18:00:00+03:00',
  'venue': '', 'intl': false, 'field': field, 'provisional': provisional,
  'podium': [
    for (final o in field)
      if (o['place'] case final int pl when pl <= 3) {'place': pl, 'name': o['name'], 'nation': '', 'points': o['points'] ?? ''},
  ],
};

Schedule _sched(List<Map<String, Object?>> starts) =>
    Schedule.parse(jsonEncode({'generated': '2026-11-12T08:00:00+03:00', 'events': starts})).withFollow(follow);

/// Петросян выступила (1-е, 72.45), Двоеглазова ещё нет, чужая Захарова — 2-я.
final running = _sched([
  _start([
    _p('Аделия Петросян', place: 1, points: '72.45', time: '16:25'),
    _p('Мария Захарова', place: 2, points: '70.10'),
    _p('Алиса Двоеглазова', time: '17:10'),
  ]),
]);

/// Все выступили, итог вида известен.
final finished = _sched([
  _start([
    _p('Мария Захарова', place: 1, points: '74.00'),
    _p('Аделия Петросян', place: 2, points: '72.45', overall: 1),
    _p('Алиса Двоеглазова', place: 3, points: '69.30'),
  ]),
]);

NotifyPlan _plan({bool results = true, bool updates = true, NotifyRules rules = const NotifyRules(), Set<String> off = const {}}) =>
    NotifyPlan(rules, const {}, off, results: results, updates: updates);

List<Planned> _results(Schedule d, NotifyPlan p, [DateTime? at]) =>
    Reminders.plan(d, p, at ?? now).where((x) => x.key.startsWith('r:')).toList();

void main() {
  group('баллы у спортсмена', () {
    test('читаются и пишутся; без места баллов нет', () {
      final o = Skater.fromJson({'name': 'А', 'place': 2, 'points': '70.10'});
      expect(o.points, '70.10');
      expect(o.toJson()['points'], '70.10');
      expect(Skater.fromJson({'name': 'А', 'points': '70.10'}).points, isNull);
      expect(Skater.fromJson({'name': 'А', 'place': 2, 'points': ''}).points, isNull);
    });

    test('свежее место без баллов не берёт чужие прежние баллы', () {
      final old = Skater('А', null, null, null, 2, null, '', '70.10');
      expect(old.filledBy(Skater('А', null, null, null)).points, '70.10');
      expect(old.filledBy(Skater('А', null, null, null, 2)).points, '70.10');
      expect(old.filledBy(Skater('А', null, null, null, 1)).points, isNull);
      expect(old.filledBy(Skater('А', null, null, null, 1, null, '', '75.00')).points, '75.00');
    });

    test('места с табло приходят со своими баллами', () {
      final s = running.starts.single.withResults(
        podium: running.starts.single.podium,
        provisional: true,
        places: {norm('Аделия Петросян'): 2, norm('Алиса Двоеглазова'): 1},
        points: {norm('Алиса Двоеглазова'): '75.20'},
      );
      final by = {for (final o in s.field) o.name: o};
      expect((by['Алиса Двоеглазова']!.place, by['Алиса Двоеглазова']!.points), (1, '75.20'));
      // место новое, баллов к нему табло не дало — прежние (к 1-му месту) не остаются
      expect((by['Аделия Петросян']!.place, by['Аделия Петросян']!.points), (2, null));
      // не пришло ничего — всё как было
      expect((by['Мария Захарова']!.place, by['Мария Захарова']!.points), (2, '70.10'));
    });
  });

  group('текст', () {
    test('пока идёт: место, баллы и честное «выступили ещё не все»', () {
      final x = _results(running, _plan()).single;
      expect(x.title, 'Аделия Петросян — 1-е место');
      expect(x.lines, [
        'Кубок России, женщины, короткая программа',
        '72.45 балла',
        'Выступили ещё не все — место может измениться',
      ]);
      expect(x.collapsed, '72.45 балла, выступили ещё не все');
    });

    test('закончился: окончательное место и итог вида', () {
      final xs = _results(finished, _plan());
      final x = xs.firstWhere((x) => x.key.endsWith('Аделия Петросян'));
      expect(x.title, 'Аделия Петросян — 2-е место');
      expect(x.lines, ['Кубок России, женщины, короткая программа', '72.45 балла', 'По сумме — 1-е место']);
      expect(x.collapsed, '72.45 балла, по сумме — 1-е место');
      final y = xs.firstWhere((x) => x.key.endsWith('Алиса Двоеглазова'));
      expect(y.lines, ['Кубок России, женщины, короткая программа', '69.30 балла']);
      expect(y.collapsed, '69.30 балла');
    });

    test('без баллов — без строки баллов', () {
      final d = _sched([_start([_p('Аделия Петросян', place: 1), _p('Мария Захарова')])]);
      final x = _results(d, _plan()).single;
      expect(x.lines, ['Кубок России, женщины, короткая программа', 'Выступили ещё не все — место может измениться']);
      expect(x.collapsed, 'Выступили ещё не все');
    });
  });

  group('план', () {
    test('по уведомлению на выступившего отслеживаемого, сразу, в стопке турнира', () {
      final x = _results(running, _plan()).single;
      expect(x.key, 'r:cup-КП:Аделия Петросян');
      expect(x.at, now);
      expect(x.hold, now);
      expect(x.end, DateTime.parse('2026-11-12T18:00:00+03:00').add(Reminders.resultKeep));
      expect(x.late, x.end);
      expect(x.startId, 'cup-КП');
      expect(x.group, 'cup');
      expect(x.result, isTrue);
      expect(x.reminder, isFalse);
    });

    test('без подписки, при выключенных уведомлениях или старте — ничего', () {
      expect(_results(running, _plan(results: false)), isEmpty);
      expect(_results(running, _plan(rules: const NotifyRules().copyWith(on: false))), isEmpty);
      expect(_results(running, _plan(off: {'cup-КП'})), isEmpty);
    });

    test('место до начала по расписанию — чужое, итога нет', () {
      final early = _sched([_start([_p('Аделия Петросян', place: 1, points: '72.45'), _p('Мария Захарова')], start: '17:00')]);
      expect(_results(early, _plan()), isEmpty);
    });

    test('где показанное не поправить — только когда сегмент закончился', () {
      expect(_results(running, _plan(updates: false)), isEmpty);
      // Захарову не отслеживают — о ней молчим
      expect(_results(finished, _plan(updates: false)).length, 2);
    });

    test('висит после конца старта столько, сколько положено, потом уходит', () {
      final end = DateTime.parse('2026-11-12T18:00:00+03:00').add(Reminders.resultKeep);
      expect(_results(finished, _plan(), end.subtract(const Duration(minutes: 1))).length, 2);
      expect(_results(finished, _plan(), end), isEmpty);
    });

    test('итог пришёл — «выходит в 16:25» вместо него не висит', () {
      final rules = const NotifyRules().copyWith(skaters: true);
      final keys = Reminders.plan(running, _plan(rules: rules), now).map((x) => x.key).toList();
      expect(keys, contains('r:cup-КП:Аделия Петросян'));
      expect(keys, isNot(contains('k:cup-КП:Аделия Петросян')));
      // кто ещё не выступил — напоминание о выходе на месте
      expect(keys, contains('k:cup-КП:Алиса Двоеглазова'));
      // без итогов — как раньше
      final plain = Reminders.plan(running, _plan(rules: rules, results: false), now).map((x) => x.key);
      expect(plain, contains('k:cup-КП:Аделия Петросян'));
    });
  });

  group('фон: места из файла состояния', () {
    final planned = {'cup-КП': [0, 0]};

    test('подпись мест не зависит от порядка и пуста без мест', () {
      final a = {'cup-КП': {'t0': 1, 'r': {'А': [1, '70'], 'Б': [2, '']}}, 'x': {'r': {'В': [1, '']}}};
      final b = {'cup-КП': {'t0': 1, 'r': {'Б': [2, ''], 'А': [1, '70']}}};
      expect(resultsSig(a, planned), resultsSig(b, planned));
      expect(resultsSig(a, planned), isNotEmpty);
      expect(resultsSig({'cup-КП': {'t0': 1}}, planned), '');
      // старт без уведомлений не в счёт
      expect(resultsSig({'x': {'r': {'В': [1, '']}}}, planned), '');
    });

    test('места и баллы ложатся на расписание без его загрузки', () {
      final before = _sched([
        _start([_p('Аделия Петросян', time: '15:40'), _p('Мария Захарова'), _p('Алиса Двоеглазова', time: '17:10')]),
      ]);
      final after = withNowResults(before, {
        'cup-КП': {
          'r': {
            'Аделия Петросян': [1, '72.45'],
            'Мария Захарова': [2, ''],
          },
        },
      }).withFollow(follow);
      final by = {for (final o in after.starts.single.field) o.name: o};
      expect((by['Аделия Петросян']!.place, by['Аделия Петросян']!.points), (1, '72.45'));
      expect((by['Мария Захарова']!.place, by['Мария Захарова']!.points), (2, null));
      expect(by['Алиса Двоеглазова']!.place, isNull);
      final x = _results(after, _plan()).single;
      expect(x.title, 'Аделия Петросян — 1-е место');
    });
  });

  test('доступ: нужна сборка с подпиской, право и включённый переключатель', () async {
    SharedPreferences.setMockInitialValues({
      BillingState.entKey: jsonEncode(Entitlement(checkedAt: now, paidUntil: now.add(const Duration(days: 20))).toJson()),
    });
    final p = await SharedPreferences.getInstance();
    expect(BillingState.resultsFor(p, now), isFalse);
    billingForce = true;
    addTearDown(() => billingForce = false);
    expect(BillingState.resultsFor(p, now), isTrue);
    await p.setBool(BillingState.resultsKey, false);
    expect(BillingState.resultsFor(p, now), isFalse);
    await p.setBool(BillingState.resultsKey, true);
    expect(BillingState.resultsFor(p, now.add(const Duration(days: 21))), isFalse);
  });
}
