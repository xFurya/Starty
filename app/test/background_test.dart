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
}
