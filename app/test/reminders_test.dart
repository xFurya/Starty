import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starty/data.dart';
import 'package:starty/reminders.dart';

void main() {
  final data = Schedule.parse(File('test/events_sample.json').readAsStringSync());
  final now = DateTime.parse('2026-10-09T15:40:00+03:00');

  test('отмеченный сегмент — за 15 минут до начала', () {
    final s = data.starts.firstWhere((e) => e.title == 'CS Denis Ten Memorial — женщины ПП');
    final p = Reminders.plan(data, {s.id}, {}, now);
    expect(p.length, 1);
    expect(p.first.at, s.t0.subtract(const Duration(minutes: 15)));
    expect(p.first.title, '17:30 · Женщины ПП');
  });

  test('отслеживаемая спортсменка — за 5 минут до выхода, по каждому старту', () {
    final p = Reminders.plan(data, {}, {'Александра Трусова'}, now);
    expect(p, isNotEmpty);
    final fs = p.firstWhere((x) => x.title.startsWith('20:32'));
    expect(fs.title, '20:32 · Александра Трусова');
    expect(msk(fs.at).hour, 20);
    expect(msk(fs.at).minute, 27);
  });

  test('пара отслеживается по одному партнёру', () {
    final p = Reminders.plan(data, {}, {'Ирина Хавронина'}, now);
    expect(p.any((x) => x.title.contains('Хавронина / Девид Нарижный')), isTrue);
  });

  test('прошедшее не планируется', () {
    final past = data.starts.firstWhere((e) => e.t1.isBefore(now));
    expect(Reminders.plan(data, {past.id}, {}, now), isEmpty);
  });
}
