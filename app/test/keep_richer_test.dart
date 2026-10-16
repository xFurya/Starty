// Показанное не пропадает: свежая загрузка с меньшим числом фактов, пустая, сбой сети или более
// бедный источник не отбирают у карточки то, что в ней уже было. Явные поправки сборщика доходят.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/live.dart';
import 'package:starty/protocol_repo.dart';
import 'package:starty/state.dart';

final _day = DateTime.utc(2026, 10, 10, 9, 30);
final _at = DateTime.utc(2026, 10, 16, 12);

Map<String, dynamic> fact(String who, String text, [String kind = 'score']) => {'who': who, 'text': text, 'kind': kind};

/// Двенадцать фактов, как в карточке «CS Denis Ten Memorial — мужчины ПП» до пропажи.
List<Map<String, dynamic>> twelve() => [
  fact('Владислав Дикиджи', 'Лучшая в мире оценка сезона за ПП: 205.48'),
  fact('Владислав Дикиджи', 'Личный рекорд за ПП: 205.48 (был 176.89)'),
  fact('Глеб Лутфуллин', 'Каскад 4T+3A+3A', 'element'),
  fact('Глеб Лутфуллин', '5 четверных в программе: 4F, 4Lo, 4T, 4S, 4S', 'element'),
  fact('Глеб Лутфуллин', 'Личный рекорд за ПП: 181.44 (был 165.76)'),
  fact('Vasil Barakhouski', 'Личный рекорд за ПП: 140.40 (был 129.81)'),
  fact('Alex Labovich', 'Личный рекорд за ПП: 128.11 (был 99.03)'),
  fact('', 'Весь пьедестал — россияне', 'place'),
  fact('Владислав Дикиджи', 'Лучшая в мире сумма сезона: 312.79'),
  fact('Владислав Дикиджи', 'Личный рекорд по сумме: 312.79 (был 265.68)'),
  fact('Глеб Лутфуллин', 'Личный рекорд по сумме: 277.23 (был 251.46)'),
  fact('Владислав Дикиджи', 'Отрыв от второго места — 35.56 балла', 'place'),
];

List<Map<String, dynamic>> four() => [twelve()[2], twelve()[3], twelve()[7], twelve()[11]];

Map<String, dynamic> placing(int n, String name, [String pts = '100.00']) => {'place': n, 'name': name, 'nation': 'RUS', 'points': pts};

Map<String, dynamic> startJson({
  String id = 'isu:denis-ten:men-senior-pp',
  String tid = 'isu:denis-ten',
  DateTime? t0,
  List<Map<String, dynamic>>? facts,
  List<Map<String, dynamic>> podium = const [],
  List<Map<String, dynamic>> total = const [],
  List<Map<String, dynamic>> watch = const [],
  List<String> broadcast = const [],
  List<Map<String, dynamic>> field = const [],
  List<Map<String, dynamic>> ours = const [],
  Map<String, dynamic>? live,
  String? proto,
}) {
  final a = t0 ?? _day;
  return {
    'id': id,
    'tid': tid,
    'tournament': 'CS Denis Ten Memorial',
    'kind': 'men',
    'level': 'senior',
    'seg': 'ПП',
    'title': 'CS Denis Ten Memorial — мужчины ПП',
    'venue': 'Almaty',
    'start': a.toIso8601String(),
    'end': a.add(const Duration(hours: 2)).toIso8601String(),
    'intl': true,
    'broadcast': broadcast,
    'watch': watch,
    'athletes': <String>[],
    'ours': ours,
    'field': field,
    'podium': podium,
    'total': total,
    'facts': facts ?? <Map<String, dynamic>>[],
    'live': ?live,
    'proto': ?proto,
    'src': 'https://example.org/results',
  };
}

Start start(Map<String, dynamic> j) => Start.fromJson(j);
Start merge(Map<String, dynamic> old, Map<String, dynamic> fresh, {bool faulty = false, bool freshFacts = false}) =>
    Start.mergeKeepingRicher(start(old), start(fresh), faulty: faulty, freshFacts: freshFacts);

Schedule sched(
  List<Map<String, dynamic>> events, {
  DateTime? generated,
  bool complete = true,
  Map<String, String> photos = const {},
  List<Map<String, dynamic>> upcoming = const [],
}) => Schedule.parse(
  jsonEncode({
    'generated': (generated ?? _at).toIso8601String(),
    'complete': complete,
    'events': events,
    'photos': photos,
    'upcoming': upcoming,
  }),
);

void main() {
  group('Start.mergeKeepingRicher: факты', () {
    test('до — 12 фактов, после — 4: показывается 12, порядок прежний', () {
      final m = merge(startJson(facts: twelve()), startJson(facts: four()));
      expect(m.facts.map((f) => f.text).toList(), twelve().map((f) => f['text']).toList());
    });

    test('после — пусто: остаются все 12', () {
      expect(merge(startJson(facts: twelve()), startJson(facts: [])).facts, hasLength(12));
    });

    test('после — больше: берутся все, ничего не задваивается', () {
      final more = [...twelve(), fact('Alex Labovich', 'Личный рекорд по сумме: 189.37 (был 158.44)')];
      final m = merge(startJson(facts: four()), startJson(facts: more));
      expect(m.facts, hasLength(13));
      expect(m.facts.map((f) => f.text), orderedEquals(more.map((f) => f['text'])));
    });

    test('текст факта обновился (то же достижение, другое число) — берётся новый', () {
      final fresh = twelve();
      fresh[4] = fact('Глеб Лутфуллин', 'Личный рекорд за ПП: 182.00 (был 165.76)');
      final m = merge(startJson(facts: twelve()), startJson(facts: fresh));
      final texts = m.facts.map((f) => f.text).toList();
      expect(m.facts, hasLength(12));
      expect(texts, contains('Личный рекорд за ПП: 182.00 (был 165.76)'));
      expect(texts, isNot(contains('Личный рекорд за ПП: 181.44 (был 165.76)')));
    });

    test('отрыв от второго места пересчитан — старое число уходит', () {
      final fresh = four();
      fresh[3] = fact('Владислав Дикиджи', 'Отрыв от второго места — 30.00 балла', 'place');
      final m = merge(startJson(facts: twelve()), startJson(facts: fresh));
      expect(m.facts.map((f) => f.text), contains('Отрыв от второго места — 30.00 балла'));
      expect(m.facts.map((f) => f.text), isNot(contains('Отрыв от второго места — 35.56 балла')));
      expect(m.facts, hasLength(12));
    });

    test('другой каскад у того же спортсмена — отдельный факт, прежний не теряется', () {
      final m = merge(
        startJson(facts: [fact('Глеб Лутфуллин', 'Каскад 4T+3A+3A', 'element')]),
        startJson(facts: [fact('Глеб Лутфуллин', 'Каскад 4T+3T', 'element')]),
      );
      expect(m.facts.map((f) => f.text), unorderedEquals(['Каскад 4T+3T', 'Каскад 4T+3A+3A']));
    });

    test('сборщик переписал слово («Связка» → «Каскад», «наши» → «россияне») — не задваивается', () {
      final m = merge(
        startJson(facts: [
          fact('Глеб Лутфуллин', 'Связка 4T+3A+3A', 'element'),
          fact('', 'Весь пьедестал — наши', 'place'),
        ]),
        startJson(facts: [
          fact('Глеб Лутфуллин', 'Каскад 4T+3A+3A', 'element'),
          fact('', 'Весь пьедестал — россияне', 'place'),
        ]),
      );
      expect(m.facts.map((f) => f.text), ['Каскад 4T+3A+3A', 'Весь пьедестал — россияне']);
    });

    test('старт перенесён (новое время) — свежее целиком', () {
      final m = merge(startJson(facts: twelve()), startJson(facts: four(), t0: _day.add(const Duration(hours: 5))));
      expect(m.facts, hasLength(4));
    });

    test('сменился id — свежее целиком', () {
      final m = merge(startJson(facts: twelve()), startJson(id: 'isu:denis-ten:men-senior-kp', facts: four()));
      expect(m.facts, hasLength(4));
    });
  });

  group('Start.mergeKeepingRicher: тройка, итог, ссылки, состав', () {
    final three = [placing(1, 'Владислав Дикиджи', '205.48'), placing(2, 'Глеб Лутфуллин', '181.44'), placing(3, 'Пётр Гуменник', '181.13')];

    test('тройка: свежая пустая — остаётся прежняя; при сбое и короче — тоже', () {
      expect(merge(startJson(podium: three), startJson()).podium, hasLength(3));
      expect(merge(startJson(podium: three), startJson(podium: three.take(1).toList()), faulty: true).podium, hasLength(3));
    });

    test('тройка: непустая свежая при чистом сборе побеждает, даже короче', () {
      expect(merge(startJson(podium: three), startJson(podium: three.take(1).toList())).podium, hasLength(1));
    });

    test('тройка: свежая такой же длины — берётся свежая (поправка баллов)', () {
      final fresh = [placing(1, 'Владислав Дикиджи', '206.00'), three[1], three[2]];
      expect(merge(startJson(podium: three), startJson(podium: fresh)).podium.first.points, '206.00');
    });

    test('итог турнира: пустой не стирает, тот же по длине заменяет', () {
      expect(merge(startJson(total: three), startJson()).total, hasLength(3));
      expect(merge(startJson(total: three), startJson(total: three.take(2).toList()), faulty: true).total, hasLength(3));
      final fresh = [three[1], three[0], three[2]];
      expect(merge(startJson(total: three), startJson(total: fresh)).total.first.name, 'Глеб Лутфуллин');
    });

    test('где смотреть: ссылка пропала — остаётся, ссылка изменилась — новая', () {
      final old = [
        {'name': 'Okko', 'url': 'https://okko.example/a'},
        {'name': 'VK', 'url': 'https://vk.example/a'},
      ];
      final m = merge(startJson(watch: old), startJson(watch: [{'name': 'Okko', 'url': 'https://okko.example/b'}]));
      expect(m.watch.map((w) => '${w.name} ${w.url}'), ['Okko https://okko.example/b', 'VK https://vk.example/a']);
      expect(merge(startJson(watch: old), startJson()).watch, hasLength(2));
    });

    test('названия трансляций: объединяются', () {
      final m = merge(startJson(broadcast: ['Матч ТВ', 'Okko']), startJson(broadcast: ['Okko']));
      expect(m.broadcast, unorderedEquals(['Okko', 'Матч ТВ']));
    });

    test('состав: при чистом сборе снятый уходит; пустой свежий состав не стирает', () {
      final old = [{'name': 'А Б', 'no': 1}, {'name': 'В Г', 'no': 2}];
      final m = merge(startJson(field: old, ours: old), startJson(field: [old[1]], ours: [old[1]]));
      expect(m.field.map((f) => f.name), ['В Г']);
      expect(m.ours.map((f) => f.name), ['В Г']);
      expect(merge(startJson(field: old), startJson()).field, hasLength(2));
    });

    test('состав при сбое: пропавший остаётся, места и время из прежнего, если свежее их не знает', () {
      final old = [
        {'name': 'Глеб Лутфуллин', 'time': '13:45', 'no': 2, 'place': 2},
        {'name': 'Alex Labovich', 'time': '13:00', 'no': 1, 'place': 4},
      ];
      final fresh = [
        {'name': 'Глеб Лутфуллин', 'time': '13:50', 'no': 2},
      ];
      final m = merge(startJson(field: old), startJson(field: fresh), faulty: true);
      expect(m.field.map((f) => f.name), ['Глеб Лутфуллин', 'Alex Labovich'], reason: 'пропавший встаёт после того, за кем шёл');
      final gleb = m.field.first;
      expect(gleb.time, '13:50', reason: 'свежее время побеждает');
      expect(gleb.place, 2, reason: 'место осталось из прежнего');
    });

    test('состав: то же имя, записанное иначе, не задваивается (по стартовому номеру)', () {
      final m = merge(
        startJson(field: [{'name': 'Vasil Barakhouski', 'no': 5, 'time': '13:10'}]),
        startJson(field: [{'name': 'Василий Бараховский', 'no': 5, 'time': '13:10'}]),
        faulty: true,
      );
      expect(m.field.map((f) => f.name), ['Василий Бараховский']);
    });

    test('свои люди: список ours не теряет прежних', () {
      final m = merge(
        startJson(ours: [{'name': 'А Б', 'no': 1}, {'name': 'В Г', 'no': 2}]),
        startJson(ours: [{'name': 'В Г', 'no': 2}]),
        faulty: true,
      );
      expect(m.ours.map((o) => o.name), ['А Б', 'В Г']);
    });

    test('табло и файл протокола: адрес не пропадает, окончательность (basis) не понижается', () {
      final oldLive = {'idx': 'i', 'seg': 's', 'cat': 'c', 'basis': 'judges', 'names': {'A': 'А'}};
      final m = merge(startJson(live: oldLive, proto: 'f.json'), startJson(live: {'idx': 'i', 'seg': 's', 'names': {'B': 'Б'}}));
      expect(m.live!.basis, 'judges');
      expect(m.live!.cat, 'c');
      expect(m.live!.names, {'A': 'А', 'B': 'Б'});
      expect(m.proto, 'f.json');
      expect(merge(startJson(live: oldLive), startJson()).live, isNotNull);
    });

    test('перенесённый старт: тройка и ссылки — свежие целиком', () {
      final m = merge(
        startJson(podium: three, watch: [{'name': 'Okko', 'url': 'https://okko.example/a'}]),
        startJson(t0: _day.add(const Duration(days: 1))),
      );
      expect(m.podium, isEmpty);
      expect(m.watch, isEmpty);
    });

    test('toJson и fromJson: ничего не теряется по дороге в кэш', () {
      final s = start(startJson(
        facts: twelve(),
        podium: three,
        total: three,
        watch: [{'name': 'Okko', 'url': 'https://okko.example/a'}],
        field: [{'name': 'А Б', 'time': '13:00', 'no': 1, 'place': 3, 'final': 2, 'nation': 'RUS'}],
        live: {'idx': 'i', 'seg': 's', 'cat': 'c', 'first': 'f', 'basis': 'judges', 'names': {'A': 'А'}},
        proto: 'f.json',
      ));
      final back = start(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(jsonEncode(back.toJson()), jsonEncode(s.toJson()));
      expect(back.facts, hasLength(12));
      expect(back.t0, s.t0);
    });
  });

  group('Schedule.mergeKeepingRicher', () {
    test('фото: пропавшие остаются, изменённое — новое', () {
      final m = Schedule.mergeKeepingRicher(
        sched([], photos: {'А Б': 'photos/a.jpg', 'В Г': 'photos/v.jpg'}),
        sched([], photos: {'А Б': 'photos/a2.jpg'}),
        now: _at,
      );
      expect(m.photos, {'А Б': 'photos/a2.jpg', 'В Г': 'photos/v.jpg'});
    });

    test('справочник и состав для поиска только прибавляются', () {
      final old = Schedule.parse(jsonEncode({
        'generated': _at.toIso8601String(),
        'events': [],
        'roster': ['А Б', 'В Г'],
        'people': [{'n': 'А Б', 'c': 'RUS', 'k': 'm'}],
        'watchlist': ['А Б'],
      }));
      final fresh = Schedule.parse(jsonEncode({
        'generated': _at.toIso8601String(),
        'events': [],
        'roster': ['В Г'],
        'people': [],
        'watchlist': [],
      }));
      final m = Schedule.mergeKeepingRicher(old, fresh, now: _at);
      expect(m.roster, containsAll(['А Б', 'В Г']));
      expect(m.people.keys, ['А Б']);
      expect(m.watchlist, ['А Б']);
    });

    test('турнир пропал целиком (источник не ответил) — его старты остаются', () {
      final old = sched([
        startJson(facts: twelve()),
        startJson(id: 'isu:budapest:men-senior-pp', tid: 'isu:budapest', facts: four()),
      ]);
      final fresh = sched([startJson(facts: four())]);
      final m = Schedule.mergeKeepingRicher(old, fresh, now: _at);
      expect(m.starts.map((s) => s.id), containsAll(['isu:denis-ten:men-senior-pp', 'isu:budapest:men-senior-pp']));
      expect(m.byId('isu:denis-ten:men-senior-pp')!.facts, hasLength(12));
    });

    test('пустой ответ не стирает расписание', () {
      final old = sched([startJson(facts: twelve())]);
      final m = Schedule.mergeKeepingRicher(old, sched([]), now: _at);
      expect(m.starts, hasLength(1));
      expect(m.starts.single.facts, hasLength(12));
    });

    test('сегмент отменён при живом турнире — убирается', () {
      final old = sched([
        startJson(facts: twelve()),
        startJson(id: 'isu:denis-ten:men-senior-kp', facts: four()),
      ]);
      final fresh = sched([startJson(facts: twelve())]);
      expect(Schedule.mergeKeepingRicher(old, fresh, now: _at).starts.map((s) => s.id), ['isu:denis-ten:men-senior-pp']);
    });

    test('неполный сбор (complete: false) — отсутствующие остаются и при живом турнире', () {
      final old = sched([
        startJson(facts: twelve()),
        startJson(id: 'isu:denis-ten:men-senior-kp', facts: four()),
      ]);
      final fresh = sched([startJson(facts: twelve())], complete: false);
      expect(Schedule.mergeKeepingRicher(old, fresh, now: _at).starts, hasLength(2));
    });

    test('общий id у разных стартов (баг сборщика): каждый сливается со своим по времени', () {
      final a = startJson(facts: twelve());
      final b = startJson(t0: _day.add(const Duration(days: 1)), facts: four());
      final m = Schedule.mergeKeepingRicher(
        sched([a, b]),
        sched([startJson(facts: four()), startJson(t0: _day.add(const Duration(days: 1)), facts: [])]),
        now: _at,
      );
      expect(m.starts.map((s) => s.facts.length), [12, 4]);
    });

    test('сборщик поднял epoch (сознательно убрал ложное) — берётся свежее целиком', () {
      final old = sched([startJson(facts: twelve())]);
      final fresh = Schedule.parse(jsonEncode({
        'generated': _at.add(const Duration(minutes: 5)).toIso8601String(),
        'epoch': 1,
        'events': [startJson(facts: four())],
      }));
      final m = Schedule.mergeKeepingRicher(old, fresh, now: _at);
      expect(m.starts.single.facts, hasLength(4));
      expect(m.epoch, 1);
      // и дальше при том же epoch снова только прибавляется
      final next = Schedule.parse(jsonEncode({
        'generated': _at.add(const Duration(minutes: 9)).toIso8601String(),
        'epoch': 1,
        'events': [startJson(facts: [])],
      }));
      expect(Schedule.mergeKeepingRicher(m, next, now: _at).starts.single.facts, hasLength(4));
    });

    Schedule withMeta(List<Map<String, dynamic>> events, {String? version, bool complete = true, Map<String, String>? sources, int min = 0}) =>
        Schedule.parse(jsonEncode({
          'generated': _at.add(Duration(minutes: min)).toIso8601String(),
          'complete': complete,
          'sources': ?sources,
          'facts_version': ?version,
          'events': events,
        }));

    test('снятый спортсмен при чистом сборе исчезает, при сбойном или пустом ответе остаётся', () {
      final both = [{'name': 'А Б', 'no': 1}, {'name': 'В Г', 'no': 2}];
      final one = [{'name': 'В Г', 'no': 2}];
      final old = withMeta([startJson(field: both, ours: both)], sources: {'ISU': 'ok'});
      final clean = Schedule.mergeKeepingRicher(old, withMeta([startJson(field: one, ours: one)], sources: {'ISU': 'ok'}, min: 5), now: _at);
      expect(clean.starts.single.field.map((f) => f.name), ['В Г']);
      for (final bad in [
        withMeta([startJson(field: one, ours: one)], complete: false, min: 5),
        withMeta([startJson(field: one, ours: one)], sources: {'ISU': 'fail'}, min: 5),
        withMeta([startJson(field: [], ours: [])], sources: {'ISU': 'ok'}, min: 5),
      ]) {
        final m = Schedule.mergeKeepingRicher(old, bad, now: _at);
        expect(m.starts.single.field, hasLength(2));
        expect(m.starts.single.ours, hasLength(2));
      }
    });

    test('смена facts_version — факты свежие целиком; та же версия и потеря 12→4 — остаётся 12', () {
      final old = withMeta([startJson(facts: twelve())], version: '6');
      final changed = Schedule.mergeKeepingRicher(old, withMeta([startJson(facts: four())], version: '7', min: 5), now: _at);
      expect(changed.starts.single.facts, hasLength(4));
      expect(changed.factsVersion, '7');
      final same = Schedule.mergeKeepingRicher(old, withMeta([startJson(facts: four())], version: '6', min: 5), now: _at);
      expect(same.starts.single.facts, hasLength(12));
      // без версии в прежнем кэше — осторожно: сливаем
      final unknown = Schedule.mergeKeepingRicher(
        withMeta([startJson(facts: twelve())]),
        withMeta([startJson(facts: four())], version: '6', min: 5),
        now: _at,
      );
      expect(unknown.starts.single.facts, hasLength(12));
    });

    test('фото: тот же ключ с другим файлом — свежий', () {
      final m = Schedule.mergeKeepingRicher(sched([], photos: {'А Б': 'photos/a.jpg'}), sched([], photos: {'А Б': 'photos/b.jpg'}), now: _at);
      expect(m.photos['А Б'], 'photos/b.jpg');
    });

    test('архив старше срока не копится', () {
      final old = sched([startJson(t0: _day.subtract(const Duration(days: 100)), facts: four())]);
      expect(Schedule.mergeKeepingRicher(old, sched([]), now: _at).starts, isEmpty);
    });

    test('«свежий» ответ старше прежнего (кэш CDN) — побеждает собранный позже', () {
      final newer = sched([startJson(facts: twelve())], generated: _at);
      final older = sched([startJson(facts: four())], generated: _at.subtract(const Duration(hours: 3)));
      final m = Schedule.mergeKeepingRicher(newer, older, now: _at);
      expect(m.generated, _at);
      expect(m.starts.single.facts, hasLength(12));
    });

    test('турнир «скоро» уходит, когда у него появились сегменты, а пропавший остаётся', () {
      Map<String, dynamic> up(String tid) => {'tid': tid, 'name': tid, 'start': '2026-10-20', 'end': '2026-10-22', 'intl': true};
      final old = sched([], upcoming: [up('isu:denis-ten'), up('isu:other')]);
      final fresh = sched([startJson()]);
      final m = Schedule.mergeKeepingRicher(old, fresh, now: _at);
      expect(m.upcoming.map((u) => u.tid), ['isu:other']);
    });

    test('toJson и parse: расписание переживает кэш', () {
      final s = sched([startJson(facts: twelve())], photos: {'А Б': 'photos/a.jpg'});
      final back = Schedule.parse(jsonEncode(s.toJson()));
      expect(back.starts.single.facts, hasLength(12));
      expect(back.photos, {'А Б': 'photos/a.jpg'});
      expect(back.generated, s.generated);
    });
  });

  group('Repo.fetch: кэш хранит последнюю хорошую версию', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() => Repo.client = http.Client());

    Future<Schedule?> fetchWith(Object body, {int code = 200}) {
      Repo.client = MockClient((_) async => body is Exception ? throw body : http.Response.bytes(utf8.encode('$body'), code));
      return Repo.fetch();
    }

    String json(List<Map<String, dynamic>> events, {String? generated}) =>
        jsonEncode({'generated': generated ?? _at.toIso8601String(), 'complete': true, 'events': events});

    test('12 фактов, потом 4: на экране и в кэше остаётся 12', () async {
      await fetchWith(json([startJson(facts: twelve(), podium: [placing(1, 'А Б')])]));
      final second = await fetchWith(json([startJson(facts: four())], generated: _at.add(const Duration(minutes: 4)).toIso8601String()));
      expect(second!.starts.single.facts, hasLength(12));
      expect(second.starts.single.podium, hasLength(1));
      final cached = await Repo.cached();
      expect(cached!.starts.single.facts, hasLength(12));
      expect(cached.starts.single.podium, hasLength(1));
    });

    test('сбой сети и мусор в ответе кэш не трогают', () async {
      await fetchWith(json([startJson(facts: twelve())]));
      expect(await fetchWith(const SocketException('нет сети')), isNull);
      expect(await fetchWith('', code: 503), isNull);
      expect(await fetchWith('<html>captive portal</html>'), isNull);
      expect(await fetchWith('{"events": 5}'), isNull);
      expect((await Repo.cached())!.starts.single.facts, hasLength(12));
    });

    test('пустой список событий не стирает кэш', () async {
      await fetchWith(json([startJson(facts: twelve())]));
      final r = await fetchWith(json([], generated: _at.add(const Duration(minutes: 4)).toIso8601String()));
      expect(r!.starts, hasLength(1));
      expect((await Repo.cached())!.starts.single.facts, hasLength(12));
    });

    test('поправка сборщика доходит и в кэш', () async {
      await fetchWith(json([startJson(facts: twelve())]));
      final fresh = twelve();
      fresh[4] = fact('Глеб Лутфуллин', 'Личный рекорд за ПП: 182.00 (был 165.76)');
      await fetchWith(json([startJson(facts: fresh)], generated: _at.add(const Duration(minutes: 4)).toIso8601String()));
      final texts = (await Repo.cached())!.starts.single.facts.map((f) => f.text);
      expect(texts, contains('Личный рекорд за ПП: 182.00 (был 165.76)'));
      expect(texts, isNot(contains('Личный рекорд за ПП: 181.44 (был 165.76)')));
    });

    test('первая загрузка кладётся в кэш как есть', () async {
      final body = json([startJson(facts: four())]);
      await fetchWith(body);
      final p = await SharedPreferences.getInstance();
      expect(p.getString('schedule.json'), body);
    });
  });

  group('AppState', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.init();
    });
    tearDown(() => Repo.client = http.Client());

    test('load: ответ беднее — показанное остаётся (и при пустом ответе)', () async {
      final s = AppState();
      s.adoptSchedule(sched([startJson(facts: twelve())]));
      for (final body in [
        jsonEncode({'generated': _at.add(const Duration(minutes: 5)).toIso8601String(), 'events': [startJson(facts: four())]}),
        jsonEncode({'generated': _at.add(const Duration(minutes: 9)).toIso8601String(), 'events': []}),
      ]) {
        Repo.client = MockClient((_) async => http.Response.bytes(utf8.encode(body), 200));
        await s.load();
        expect(s.data!.byId('isu:denis-ten:men-senior-pp')!.facts, hasLength(12));
      }
      s.sync.dispose();
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('итоги с табло: тройка короче прежней её не заменяет', () {
      final three = [placing(1, 'А'), placing(2, 'Б'), placing(3, 'В')];
      final s = AppState();
      s.adoptSchedule(sched([startJson(podium: three)..['provisional'] = true]));
      s.adoptLive('isu:denis-ten:men-senior-pp', LiveOk(podium: [Placing(1, 'А', 'RUS', '1.00')], provisional: true));
      expect(s.data!.byId('isu:denis-ten:men-senior-pp')!.podium, hasLength(3));
      s.adoptLive(
        'isu:denis-ten:men-senior-pp',
        LiveOk(podium: [for (final p in three) Placing(p['place'] as int, p['name'] as String, 'RUS', '2.00')], provisional: true),
      );
      expect(s.data!.byId('isu:denis-ten:men-senior-pp')!.podium.first.points, '2.00');
      s.sync.dispose();
    });

    test('LiveOk переживает запись на диск', () {
      final l = LiveOk(
        podium: [Placing(1, 'А', 'RUS', '1.00')],
        provisional: false,
        rows: [Placing(1, 'А', 'RUS', '1.00'), Placing(2, 'Б', 'BLR', '0.50')],
        places: {'а': 1},
        total: [Placing(1, 'А', 'RUS', '2.00')],
        finals: {'а': 1},
      );
      final back = LiveOk.tryFromJson(jsonDecode(jsonEncode(l.toJson())))!;
      expect(back.rows, hasLength(2));
      expect(back.total, hasLength(1));
      expect(back.places, {'а': 1});
      expect(back.provisional, isFalse);
      expect(LiveOk.tryFromJson('мусор'), isNull);
    });
  });

  group('файл протокола: беднее не затирает', () {
    final now = DateTime.utc(2026, 10, 15, 19);
    Map<String, dynamic> sample() => jsonDecode(File('test/protocol/sample.json').readAsStringSync()) as Map<String, dynamic>;
    http.Response ok(Object body) =>
        http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    ProtocolRepo repo(http.Client c) => ProtocolRepo(client: c, now: () => now);

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('пропал сегмент и итог — остаются из прежнего файла, и в кэше тоже', () async {
      final rich = sample();
      ((rich['categories'] as List).first as Map<String, dynamic>)['total'] = {
        'state': 'provisional',
        'complete': false,
        'cols': <String>[],
        'colsKind': 'unknown',
        'rows': <Object?>[],
        'skipped': 0,
      };
      await repo(MockClient((_) async => ok(rich))).load('a.json');
      final poor = sample();
      final cat = (poor['categories'] as List).first as Map<String, dynamic>;
      cat['segments'] = <Object?>[];
      cat['total'] = null;
      final r = await repo(MockClient((_) async => ok(poor))).load('a.json') as ProtocolOk;
      final c = r.doc.categories.first;
      expect(c.segments, isNotEmpty);
      expect(c.total, isNotNull);
      final net = await repo(MockClient((_) async => throw const SocketException('нет сети'))).load('a.json') as ProtocolNetError;
      expect(net.cached!.categories.first.segments, isNotEmpty);
      expect(net.cached!.categories.first.total, isNotNull);
    });

    test('сегмент с меньшим числом строк того же состояния не заменяет полный', () async {
      final rich = sample();
      final seg = ((rich['categories'] as List).first as Map)['segments'].first as Map<String, dynamic>;
      seg['state'] = 'provisional';
      seg['basis'] = null;
      await repo(MockClient((_) async => ok(rich))).load('b.json');
      final poor = jsonDecode(jsonEncode(rich)) as Map<String, dynamic>;
      final pseg = ((poor['categories'] as List).first as Map)['segments'].first as Map<String, dynamic>;
      final rows = pseg['rows'] as List;
      expect(rows.length, greaterThan(1));
      pseg['rows'] = rows.take(1).toList();
      final r = await repo(MockClient((_) async => ok(poor))).load('b.json') as ProtocolOk;
      expect(r.doc.categories.first.segments.first.rows.length, rows.length);
    });

    test('поправка: то же состояние и столько же строк — берётся свежий файл', () async {
      await repo(MockClient((_) async => ok(sample()))).load('c.json');
      final fixed = sample();
      final seg = ((fixed['categories'] as List).first as Map)['segments'].first as Map<String, dynamic>;
      seg['name'] = 'Исправленное название';
      final r = await repo(MockClient((_) async => ok(fixed))).load('c.json') as ProtocolOk;
      expect(r.doc.categories.first.segments.first.name, 'Исправленное название');
    });
  });
}
