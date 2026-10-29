// Порядок опроса табло: идущий старт не должен остаться за бортом из-за длинного дня.
import 'package:flutter_test/flutter_test.dart';
import 'package:starty/data.dart';
import 'package:starty/state.dart';

void main() {
  final t = DateTime.utc(2026, 10, 29, 12, 0);

  Duration hr(int n) => Duration(hours: n);

  Start at(String id, Duration from, Duration to) => Start.fromJson({
        'id': id,
        'tid': 'x',
        'tournament': 'Турнир',
        'kind': 'dance',
        'level': 'junior',
        'seg': 'КП',
        'title': id,
        'start': t.add(from).toIso8601String(),
        'end': t.add(to).toIso8601String(),
      });

  test('идущий первым, потом ближайшие по времени; при равенстве — порядок расписания', () {
    final morning = at('утро', hr(-6), hr(-5));
    final recent = at('недавно', hr(-2), hr(-1));
    final running = at('идёт', const Duration(minutes: -30), hr(1));
    final soon = at('скоро', const Duration(minutes: 20), hr(2));
    final twin = at('двойник', hr(-6), hr(-5));
    final order = AppState.pollOrder([morning, twin, recent, soon, running], t).map((s) => s.id).toList();
    expect(order, ['идёт', 'скоро', 'недавно', 'утро', 'двойник']);
  });

  test('из длинного дня берутся идущие, а не первые по времени', () {
    final day = [for (var i = 0; i < 10; i++) at('утро$i', hr(-12 + i), hr(-11 + i))];
    final running = at('идёт', hr(-1), hr(1));
    final first8 = AppState.pollOrder([...day, running], t).take(8).map((s) => s.id).toList();
    expect(first8.first, 'идёт');
    expect(first8, contains('утро9'));
    expect(first8, isNot(contains('утро0')));
  });
}
