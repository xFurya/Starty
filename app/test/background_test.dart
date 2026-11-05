import 'package:flutter_test/flutter_test.dart';
import 'package:starty/background.dart';
import 'package:starty/data.dart';

Start _start(String id, {bool regional = false}) => Start.fromJson({
  'id': id,
  'tid': 't$id',
  'tournament': 'Турнир',
  'kind': 'women',
  'level': 'junior',
  'seg': 'short',
  'title': 'Короткая программа',
  'venue': 'Москва',
  'src': 'ФФКМ',
  'start': '2026-08-24T15:00:00+03:00',
  'end': '2026-08-24T18:00:00+03:00',
  'intl': false,
  if (regional) 'tier': 'regional',
  if (regional) 'region': 'Москва',
});

void main() {
  final raw = Schedule([_start('a'), _start('b', regional: true)], DateTime.utc(2026, 8, 1), true, false);

  test('напоминания: региональный старт при выключенном показе не попадает', () {
    final d = remindersSchedule(raw, regional: false, follow: Follow.none);
    expect([for (final s in d.starts) s.id], ['a']);
  });

  test('напоминания: при включённом показе региональный старт попадает', () {
    final d = remindersSchedule(raw, regional: true, follow: Follow.none);
    expect([for (final s in d.starts) s.id], ['a', 'b']);
  });

  group('фоновая проверка по файлу состояния', () {
    const t0 = 1000, t1 = 2000;
    final planned = <String, dynamic>{'a': [t0, t1]};
    final known = {'a', 'b'};

    test('ничего не поменялось — всё расписание не тянем', () {
      expect(nowChanged({'a': {'t0': t0, 't1': t1}, 'b': {'t0': 5, 't1': 6, 'done': true}}, planned, known), isFalse);
    });

    test('у старта с уведомлением сдвинулось время или он закончился — тянем', () {
      expect(nowChanged({'a': {'t0': t0 + 60000, 't1': t1}}, planned, known), isTrue);
      expect(nowChanged({'a': {'t0': t0, 't1': t1 + 60000}}, planned, known), isTrue);
      expect(nowChanged({'a': {'t0': t0, 't1': t1, 'done': true}}, planned, known), isTrue);
    });

    test('появился старт, которого в расписании не было, — тянем', () {
      expect(nowChanged({'c': {'t0': 1, 't1': 2}}, planned, known), isTrue);
    });

    test('известные старты — на сутки назад и трое вперёд от проверки', () {
      final t = DateTime.parse('2026-08-24T12:00:00+03:00');
      expect(knownIds(raw, t), ['a', 'b']);
      expect(knownIds(raw, t.add(const Duration(days: 2))), isEmpty);
      expect(knownIds(raw, t.subtract(const Duration(days: 4))), isEmpty);
    });
  });
}
