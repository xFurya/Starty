// Подписи тройки: у завершённого сегмента пометки нет, пока идёт — «идёт» и «N из M».
import 'package:flutter_test/flutter_test.dart';
import 'package:starty/data.dart';
import 'package:starty/views.dart';

Start _start({required Duration from, required Duration to, bool provisional = true, int placed = 2}) {
  final now = DateTime.now().toUtc();
  return Start.fromJson({
    'id': 'x:1',
    'tid': 'x',
    'tournament': 'Турнир',
    'kind': 'men',
    'level': 'junior',
    'seg': 'КП',
    'title': 'Турнир — юноши КП',
    'start': now.add(from).toIso8601String(),
    'end': now.add(to).toIso8601String(),
    'provisional': provisional,
    'podium': [
      {'place': 1, 'name': 'Иван Иванов', 'nation': 'RUS', 'points': '70.00'},
    ],
    'field': [
      for (var i = 0; i < 5; i++) {'name': 'Участник $i', 'time': '10:0$i', if (i < placed) 'place': i + 1},
    ],
  });
}

void main() {
  test('сегмент идёт — «идёт» и сколько выступило', () {
    final s = _start(from: const Duration(minutes: -30), to: const Duration(minutes: 60));
    expect(podiumLabel(s), 'Тройка · КП · идёт · 2 из 5');
    expect(leadersLabel(s), 'Лидеры · идёт · 2 из 5');
  });

  test('сегмент идёт, а выступивших неизвестно — просто «идёт»', () {
    final s = _start(from: const Duration(minutes: -30), to: const Duration(minutes: 60), placed: 0);
    expect(podiumLabel(s), 'Тройка · КП · идёт');
  });

  test('сегмент завершён, судейских оценок нет — пометки нет', () {
    final s = _start(from: const Duration(hours: -3), to: const Duration(hours: -1));
    expect(podiumLabel(s), 'Тройка · КП');
    expect(leadersLabel(s), 'Тройка');
    expect(podiumLabel(s).toLowerCase(), isNot(contains('промежуточ')));
  });

  test('окончательный идущий — без пометки', () {
    final s = _start(from: const Duration(minutes: -30), to: const Duration(minutes: 60), provisional: false);
    expect(podiumLabel(s), 'Тройка · КП');
  });
}
