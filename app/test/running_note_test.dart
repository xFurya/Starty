// Подписи тройки: у завершённого сегмента пометки нет, пока идёт — «Лидеры» и «выступили N из M».
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
  test('сегмент идёт — «Лидеры» и отдельно сколько выступило', () {
    final s = _start(from: const Duration(minutes: -30), to: const Duration(minutes: 60));
    expect(podiumLabel(s), 'Лидеры');
    expect(runningNote(s), 'выступили 2 из 5');
  });

  test('сегмент идёт, а выступивших неизвестно — без счёта', () {
    final s = _start(from: const Duration(minutes: -30), to: const Duration(minutes: 60), placed: 0);
    expect(podiumLabel(s), 'Лидеры');
    expect(runningNote(s), '');
  });

  test('сегмент завершён, судейских оценок нет — пометки нет', () {
    final s = _start(from: const Duration(hours: -3), to: const Duration(hours: -1), placed: 5);
    expect(s.pastAt(DateTime.now()), isTrue);
    expect(podiumLabel(s), 'Тройка');
    expect(runningNote(s), '');
    expect(podiumLabel(s).toLowerCase(), isNot(contains('промежуточ')));
  });

  test('расписание вышло, а табло оценило не всех — старт идёт, не «завершён»', () {
    final s = _start(from: const Duration(hours: -2), to: const Duration(minutes: -5));
    final t = DateTime.now();
    expect(s.liveAt(t), isTrue);
    expect(s.pastAt(t), isFalse);
    expect(podiumLabel(s), 'Лидеры');
    expect(runningNote(s), 'выступили 2 из 5');
  });

  test('табло застыло: через три часа после расписания старт снова завершён', () {
    final s = _start(from: const Duration(hours: -6), to: const Duration(hours: -4));
    expect(s.liveAt(DateTime.now()), isFalse);
    expect(s.pastAt(DateTime.now()), isTrue);
  });

  test('окончательный идущий — без пометки', () {
    final s = _start(from: const Duration(minutes: -30), to: const Duration(minutes: 60), provisional: false);
    expect(podiumLabel(s), 'Тройка');
    expect(runningNote(s), '');
  });

  test('ни в одной подписи нет разделительной точки', () {
    final s = _start(from: const Duration(minutes: -30), to: const Duration(minutes: 60));
    expect('${podiumLabel(s)}${runningNote(s)}', isNot(contains('·')));
  });
}
