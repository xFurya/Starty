// История выступлений и статистика: файл истории, слияние с тем, что знает устройство, счёт
// баллов, прыжков и уровней.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starty/data.dart';
import 'package:starty/history.dart';

String file(Map<String, dynamic> athletes, Map<String, dynamic> tours) => jsonEncode({'v': 1, 't': tours, 'a': athletes});

Map<String, dynamic> skate(String day, String tid, String seg, int place, String pts, {List els = const [], String? tpts, int? tp}) => {
  'd': day,
  't': tid,
  'k': 'women',
  'l': 'senior',
  's': seg,
  'pl': place,
  'of': 18,
  'pts': pts,
  'els': els,
  'tp': ?tp,
  'tpts': ?tpts,
};

void main() {
  test('имя файла — та же контрольная сумма, что в сборщике (scraper/history.py: bucket)', () {
    // zlib.crc32('kaori sakamoto') % 256 == 0x34 — см. scraper/test_history.py
    expect(crc32(utf8.encode('kaori sakamoto')), 1196845108);
    expect(historyFile('Kaori Sakamoto'), '34.json');
    expect(historyFile('Пётр Гуменник'), historyFile('петр гуменник'));
    // и на настоящем файле сайта: человек лежит там, где его ищет приложение
    final f = File('../site/h/${historyFile('Аделия Петросян')}');
    if (f.existsSync()) {
      expect(parseHistory(f.readAsStringSync(), 'Аделия Петросян').skates, isNotEmpty);
    }
  });

  test('файл истории: прокаты одного человека, турнир и его признаки, тёзки', () {
    final body = file(
      {
        'Анна Иванова': {
          'r': [
            skate('2024-12-20', 'fsr:a', 'КП', 2, '70.10', els: [
              ['3Lz!+3T<', '! <', -1.2],
              ['3A', 'F', -4.0],
            ]),
            skate('2024-12-21', 'fsr:a', 'ПП', 1, '140.00', tp: 1, tpts: '210.10'),
            {'d': 'битая'},
          ],
        },
        'Мария Петрова': {'r': [skate('2024-12-20', 'fsr:a', 'КП', 1, '75.00')], 'x': true},
      },
      {
        'fsr:a': ['Чемпионат России', 0, 1],
      },
    );
    final h = parseHistory(body, 'анна иванова');
    expect(h.twins, isFalse);
    expect(h.skates, hasLength(2));
    expect(h.skates.first.tournament, 'Чемпионат России');
    expect((h.skates.first.intl, h.skates.first.archived), (false, true));
    expect(h.skates.first.els.last.fall, isTrue);
    expect(h.skates.last.totalPoints, 210.10);
    expect(h.skates.first.season, '2024/25');
    expect(parseHistory(body, 'Мария Петрова').twins, isTrue);
    expect(parseHistory(body, 'Нет Такой').skates, isEmpty);
  });

  test('то, что знает устройство, добавляется к истории сайта; прокат сайта с элементами главнее', () {
    final data = Schedule.parse(jsonEncode({
      'generated': '2026-11-14T10:00:00+03:00',
      'events': [
        for (final (id, tid, pts) in [('fsr:a:women-senior-kp', 'fsr:a', '71.00'), ('fsr:b:women-senior-kp', 'fsr:b', '80.50')])
          {
            'id': id,
            'tid': tid,
            'tournament': 'Турнир $tid',
            'kind': 'women',
            'level': 'senior',
            'seg': 'КП',
            'title': 'Турнир — женщины КП',
            'start': tid == 'fsr:a' ? '2024-12-20T14:00:00+03:00' : '2026-11-13T14:00:00+03:00',
            'end': tid == 'fsr:a' ? '2024-12-20T16:00:00+03:00' : '2026-11-13T16:00:00+03:00',
            'venue': '',
            'intl': false,
            'podium': [
              {'place': 1, 'name': 'Анна Иванова', 'nation': '', 'points': pts},
            ],
            'field': [
              {'name': 'Анна Иванова', 'nation': 'МОС', 'place': 1, 'points': pts},
              {'name': 'Мария Петрова', 'nation': 'МОС', 'place': 2, 'points': '60.00'},
            ],
          },
      ],
    }));
    final local = skatesFromSchedule(data, 'Анна Иванова');
    expect(local, hasLength(2));
    expect(local.last.of, 2);
    final site = parseHistory(
      file({
        'Анна Иванова': {
          'r': [
            skate('2024-12-20', 'fsr:a', 'КП', 1, '70.10', els: [
              ['3A', '', 1.5],
            ]),
          ],
        },
      }, {'fsr:a': ['Турнир', 0, 1]}),
      'Анна Иванова',
    );
    final all = mergeSkates(site, local);
    expect([for (final s in all.skates) s.tid], ['fsr:a', 'fsr:b']);
    expect(all.skates.first.els, hasLength(1), reason: 'прокат сайта не заменён бедным');
    expect(all.skates.last.points, 80.50, reason: 'свежий старт — из расписания на устройстве');
    // сайт не ответил — остаётся то, что знает устройство
    expect(mergeSkates(null, local).skates, hasLength(2));
  });

  test('ряды баллов: короткая, произвольная, сумма — по разу на турнир', () {
    final skates = [
      const Skate(day: '2024-12-20', tid: 'a', tournament: 'A', kind: 'women', level: 'senior', seg: 'КП', place: 1, of: 9, intl: false, points: 70, totalPoints: 210),
      const Skate(day: '2024-12-21', tid: 'a', tournament: 'A', kind: 'women', level: 'senior', seg: 'ПП', place: 1, of: 9, intl: false, points: 140, totalPoints: 210),
      const Skate(day: '2025-01-10', tid: 'b', tournament: 'B', kind: 'women', level: 'senior', seg: 'КП', place: 3, of: 9, intl: true, points: 65),
    ];
    expect([for (final x in scoreSeries(skates, ScoreKind.short)) x.value], [70, 65]);
    expect([for (final x in scoreSeries(skates, ScoreKind.free)) x.value], [140]);
    expect([for (final x in scoreSeries(skates, ScoreKind.total)) x.value], [210]);
  });

  test('прыжки элемента: каскад, отметки, выброс; подкрутка и ойлер — не прыжки', () {
    expect([for (final j in jumpsOf('3Lz!+3T<')) (j.jump, j.marks)], [('3Lz', '!'), ('3T', '<')]);
    expect([for (final j in jumpsOf('3A+1Eu+3S')) j.jump], ['3A', '3S']);
    expect([for (final j in jumpsOf('3F+2A+SEQ')) j.jump], ['3F', '2A']);
    expect([for (final j in jumpsOf('4Tq')) (j.jump, j.marks)], [('4T', 'q')]);
    expect([for (final j in jumpsOf('3LoTh')) (j.jump, j.thrown)], [('3LoTh', true)]);
    expect(jumpsOf('3Tw4'), isEmpty);
    expect(jumpsOf('CCoSp4'), isEmpty);
    expect(jumpsOf('StSq3'), isEmpty);
  });

  test('статистика прыжков: всего, чисто, недокруты, рёбра, средняя надбавка сольных', () {
    Skate s(List<SkateElement> els) =>
        Skate(day: '2024-12-20', tid: 'a', tournament: 'A', kind: 'women', level: 'senior', seg: 'ПП', place: 1, of: 9, intl: false, els: els);
    final stats = jumpStats([
      s(const [SkateElement('3A', '', 2.0), SkateElement('3Lz!+3T<', '! <', -1.0), SkateElement('2A', '', .5), SkateElement('1Lo', '', 0)]),
      s(const [SkateElement('3A', 'F', -4.0), SkateElement('3Lz+3T', '', 1.2), SkateElement('4T', '', 3.0)]),
    ]);
    final by = {for (final j in stats) j.jump: j};
    expect([for (final j in stats) j.jump], ['4T', '3A', '3Lz', '3T', '2A'], reason: 'сложные раньше; одинарные не считаются');
    expect((by['3A']!.done, by['3A']!.clean), (2, 1));
    expect(by['3A']!.avgGoe, -1.0);
    expect((by['3Lz']!.done, by['3Lz']!.clean, by['3Lz']!.edge), (2, 1, 1));
    expect((by['3T']!.done, by['3T']!.clean, by['3T']!.under), (2, 1, 1));
    expect(by['3Lz']!.avgGoe, isNull, reason: 'в каскаде надбавка общая — сольной нет');
    final f = fallStats([s(const [SkateElement('3A', 'F', -4.0)]), s(const [SkateElement('3A', '', 1.0)]), s(const [])]);
    expect((f.falls, f.skates, f.detailed), (1, 1, 2));
  });

  test('уровни: вращения, дорожки, твизлы, поддержки, подкрутка; хореографические — без уровня', () {
    Skate s(List<String> codes) => Skate(
      day: '2024-12-20',
      tid: 'a',
      tournament: 'A',
      kind: 'pairs',
      level: 'senior',
      seg: 'ПП',
      place: 1,
      of: 9,
      intl: false,
      els: [for (final c in codes) SkateElement(c, '', 0)],
    );
    final by = {for (final l in levelStats([s(['CCoSp4', 'FCSp3', 'StSq4', 'ChSq1', '3Tw4', '5ALi4', 'BoDs3', 'SqTwW4+SqTwM3', '3Lz'])])) l.group: l};
    expect((by['Вращения']!.done, by['Вращения']!.top), (2, 1));
    expect((by['Дорожки шагов']!.done, by['Дорожки шагов']!.top), (1, 1));
    expect((by['Подкрутка']!.done, by['Подкрутка']!.top), (1, 1));
    expect((by['Поддержки']!.done, by['Поддержки']!.top), (1, 1));
    expect((by['Тодесы']!.done, by['Тодесы']!.top), (1, 0));
    expect((by['Твизлы']!.done, by['Твизлы']!.top), (2, 1));
  });
}
