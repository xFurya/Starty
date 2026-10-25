import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:starty/data.dart';
import 'package:starty/live.dart';
import 'package:starty/protocol_model.dart';

String page(String f) => File('test/live/$f').readAsStringSync();

/// Страница ФФКМ из golden-фикстур: cp1251, без заголовка кодировки.
List<int> ffkm(String f) => File('test/golden/ffkm/$f').readAsBytesSync();

/// Старт с табло: адреса страниц как в events.json, окончательность — basis.
Start liveStart({
  String? basis,
  String? cat,
  String seg = 'РТ',
  String kind = 'dance',
  String level = 'junior',
  List<String> field = const [],
}) =>
    Start.fromJson({
      'field': [for (final n in field) {'name': n, 'time': '15:00'}],
      'id': 'ffkm:2026-08-24_pm:dance-junior-rt',
      'tid': 'ffkm:2026-08-24_pm',
      'tournament': 'Первенство Москвы',
      'kind': kind,
      'level': level,
      'seg': seg,
      'title': 'Первенство Москвы — танцы РТ',
      'venue': 'ЛД «Мечта», Москва',
      'src': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/index.htm',
      'start': '2026-08-24T15:00:00+03:00',
      'end': '2026-08-24T18:35:00+03:00',
      'live': {
        'idx': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/index.htm',
        'seg': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/SEG007.HTM',
        'cat': cat,
        'basis': basis,
        'names': {'Анна БИЛИБИНА / Дмитрий КАШАЕВ': 'Анна Билибина / Дмитрий Кашаев'},
      },
    });

/// Клиент табло: страница сегмента и (если нужна) страница итога.
void serve(Map<String, Object> pages) {
  Live.client = MockClient((r) async {
    final body = pages[r.url.path.split('/').last];
    if (body == null) return http.Response('', 404);
    if (body is Exception) throw body;
    return http.Response.bytes(body as List<int>, 200);
  });
}

void main() {
  test('протокол сегмента с табло: места, имена, флаг, баллы', () {
    final rows = segmentResults(page('SEG002.htm'))!;
    expect(rows.length, greaterThanOrEqualTo(3));
    expect(rows[0].place, 1);
    expect(rows[0].name, 'Vladislav DIKIDZHI');
    expect(rows[0].nation, 'AIN2');
    expect(rows[0].points, '205.48');
    expect(rows[1].name, 'Gleb LUTFULLIN');
    expect(rows[2].points, '181.13');
  });

  test('итог вида: тройка и полнота', () {
    final (rows, complete) = categoryResults(page('CAT001RS.htm'));
    expect(complete, isTrue);
    expect(rows.first.name, 'Vladislav DIKIDZHI');
    expect(rows.first.points, '312.79');
  });

  test('стартовый лист — ещё не протокол', () {
    const start = '<table><tr><th>StN.</th><th>Name</th><th>Nation</th></tr>'
        '<tr><td>1</td><td>Ivan IVANOV</td><td>AIN2</td></tr></table>';
    expect(segmentResults(start), isNull);
  });

  test('остаток стартового порядка посреди старта — не места', () {
    const page = '<table><tr><th>Pl.</th><th>Name</th><th>Nation</th><th>TSS</th><th>TES</th><th>PCS</th></tr>'
        '<tr><td>1</td><td>Ivan SEMENOV</td><td>RUS</td><td>99.55</td><td>49.82</td><td>50.73</td></tr>'
        '<tr><td>2</td><td>Max GALKIN</td><td>RUS</td><td>88.23</td><td>39.92</td><td>49.31</td></tr></table>'
        '<table><tr><th>StN.</th><th>Name</th><th>Nation</th><th>Rank</th><th>Points</th></tr>'
        '<tr><td>3</td><td>Petr PETROV</td><td>RUS</td><td>6</td><td>58.37</td></tr>'
        '<tr><td>4</td><td>Oleg OLEGOV</td><td>RUS</td><td>5</td><td>60.85</td></tr></table>';
    final rows = segmentResults(page)!;
    expect(rows.map((r) => (r.place, r.points)), [(1, '99.55'), (2, '88.23')]);
  });

  group('несколько таблиц на странице во время старта', () {
    const segHead = '<tr><th>Pl.</th><th>Name</th><th>Nation</th><th>TSS</th><th>TES</th><th>PCS</th></tr>';
    const totHead = '<tr><th>Pl.</th><th>Name</th><th>Nation</th><th>Total</th><th>SP</th><th>FS</th></tr>';
    const total = '<table>$totHead'
        '<tr><td>1</td><td>Ivan SEMENOV</td><td>RUS</td><td>178.37</td><td>1</td><td>1</td></tr>'
        '<tr><td>2</td><td>Max GALKIN</td><td>RUS</td><td>169.82</td><td>2</td><td>2</td></tr></table>';
    const segment = '<table>$segHead'
        '<tr><td>1</td><td>Ivan SEMENOV</td><td>RUS</td><td>115.66</td><td>56.56</td><td>59.10</td></tr>'
        '<tr><td>2</td><td>Max GALKIN</td><td>RUS</td><td>114.72</td><td>52.78</td><td>61.94</td></tr></table>';

    test('берётся таблица сегмента, а не общий зачёт, в любом порядке', () {
      for (final page in [total + segment, segment + total]) {
        final rows = segmentResults(page)!;
        expect(rows.map((r) => r.name), ['Ivan SEMENOV', 'Max GALKIN']);
        expect(rows.map((r) => r.points), ['115.66', '114.72']);
      }
    });

    test('один человек — одна строка', () {
      const dup = '<table>$segHead'
          '<tr><td>1</td><td>A B</td><td>RUS</td><td>100.00</td><td>50.00</td><td>50.00</td></tr>'
          '<tr><td>1</td><td>A B</td><td>RUS</td><td>90.00</td><td>45.00</td><td>45.00</td></tr></table>';
      final rows = segmentResults(dup)!;
      expect(rows.length, 1);
      expect(rows.single.points, '100.00');
    });
  });

  test('фамилии капсом приводятся к обычному написанию', () {
    expect(titledName('Vladislav DIKIDZHI'), 'Vladislav Dikidzhi');
    expect(titledName('Даниил ЖОЛОБОВ'), 'Даниил Жолобов');
    expect(titledName('Anna SHCHERBAKOVA / Egor GONCHAROV'), 'Anna Shcherbakova / Egor Goncharov');
    expect(titledName('Ana Maria TORRES-LOPEZ'), 'Ana Maria Torres-Lopez');
  });

  group('кодировка cp1251 (ФФКМ отдаёт страницы без заголовка кодировки)', () {
    test('декодер: UTF-8 как есть, cp1251 — кириллица, не искажается', () {
      expect(decodeTablo(utf8.encode('Анна БИЛИБИНА')), 'Анна БИЛИБИНА');
      final cp = decodeTablo(ffkm('SEG007.htm'));
      expect(cp, contains('БИЛИБИНА'));
      expect(cp, isNot(contains('\u0420\u0453')), reason: 'типичный признак неверного декодирования');
    });
    test('танцы РТ: 24 строки, места 1..24, первая тройка с баллами', () {
      final rows = segmentResults(decodeTablo(ffkm('SEG007.htm')))!;
      expect(rows.length, 24);
      expect(rows.map((r) => r.place), List.generate(24, (i) => i + 1));
      expect(rows[0].name, 'Анна Павловна БИЛИБИНА / Дмитрий Владимирович КАШАЕВ');
      expect(rows[0].points, '66.36');
      expect(rows[2].points, '62.45');
    });
    test('пары КП: 8 строк', () {
      expect(segmentResults(decodeTablo(ffkm('SEG005.htm'))), hasLength(8));
    });
    test('стартовый лист и легенда одиночек — не протокол', () {
      expect(segmentResults(decodeTablo(ffkm('SEG001.htm'))), isNull);
      expect(segmentResults(decodeTablo(ffkm('SEG002.htm'))), isNull);
      expect(segmentResults(decodeTablo(ffkm('SEG003.htm'))), isNull);
    });
  });

  group('клуб в ячейке имени, однофамильцы, шапка «М.»', () {
    test('клуб после <br/> не попадает в имя', () {
      final (rows, complete) = categoryResults(decodeTablo(ffkm('CAT001RS.htm')));
      expect(complete, isTrue);
      expect(rows.first.name, 'Дарья Евгеньевна ЛЕБЕДЕВА');
      expect(rows.any((r) => r.name.contains('МАФКК')), isFalse);
    });
    test('шапка «М.» — таблица с местами', () {
      const t = '<table><caption>Детализация</caption><tr><th>М.</th><th>Имя</th><th>Баллы</th></tr>'
          '<tr><td>1</td><td>Ivan IVANOV</td><td>100.00</td></tr>'
          '<tr><td>2</td><td>Ivan IVANOV</td><td>99.00</td></tr></table>';
      final rows = segmentResults(t)!;
      expect(rows.map((r) => r.place), [1, 2], reason: 'однофамильцы на разных местах — оба');
    });
    test('дубль одного места и имени — одна строка', () {
      const t = '<table><tr><th>Pl.</th><th>Name</th><th>TSS</th></tr>'
          '<tr><td>1</td><td>Ivan IVANOV</td><td>100.00</td></tr>'
          '<tr><td>1</td><td>Ivan IVANOV</td><td>100.00</td></tr></table>';
      expect(segmentResults(t), hasLength(1));
    });
  });

  group('опрос табло: типизированный результат, окончательность по basis', () {
    tearDown(() => Live.client = http.Client());

    test('окончательно — только при basis judges (судейские оценки)', () async {
      serve({'SEG007.HTM': ffkm('SEG007.htm')});
      final r = await Live.poll(liveStart(basis: 'judges'));
      expect(r, isA<LiveOk>());
      expect((r as LiveOk).provisional, isFalse);
      expect(r.podium.map((p) => p.place), [1, 2, 3]);
      expect(r.podium.first.points, '66.36');
    });
    test('без basis — промежуточный, даже если в табло есть строки', () async {
      serve({'SEG007.HTM': ffkm('SEG007.htm')});
      final r = await Live.poll(liveStart());
      expect((r as LiveOk).provisional, isTrue);
    });
    test('итог вида тянем только при окончательном сегменте', () async {
      serve({'SEG007.HTM': ffkm('SEG007.htm'), 'CAT004RS.htm': ffkm('CAT004RS.htm')});
      final prov = await Live.poll(liveStart(basis: null, cat: 'https://ffkm.ru/x/CAT004RS.htm')) as LiveOk;
      expect(prov.total, isNull);
      final fin = await Live.poll(liveStart(basis: 'judges', cat: 'https://ffkm.ru/x/CAT004RS.htm')) as LiveOk;
      expect(fin.total, isNotNull);
      expect(fin.total!.first.points, '163.32');
    });
    test('сеть недоступна — LiveNet, не окончательность', () async {
      serve({'SEG007.HTM': Exception('timeout')});
      expect(await Live.poll(liveStart(basis: 'judges')), isA<LiveNet>());
    });
    test('5xx — LiveNet', () async {
      Live.client = MockClient((_) async => http.Response('oops', 503));
      expect(await Live.poll(liveStart(basis: 'judges')), isA<LiveNet>());
    });
    test('страницы нет (404) или стартовый лист — LiveNone', () async {
      serve({'SEG007.HTM': ffkm('SEG001.htm')});
      expect(await Live.poll(liveStart(basis: 'judges')), isA<LiveNone>());
      serve({});
      expect(await Live.poll(liveStart(basis: 'judges')), isA<LiveNone>());
    });
    test('страница без таблиц — LiveFormat', () async {
      serve({'SEG007.HTM': utf8.encode('<html><body>Техработы</body></html>')});
      expect(await Live.poll(liveStart(basis: 'judges')), isA<LiveFormat>());
    });
  });

  group('итоги из файла протокола (режим «с опозданием»)', () {
    ProtocolDoc doc(String state, {String basis = 'judges', List<Map<String, Object?>>? rows}) => ProtocolDoc.fromJson({
      'v': 1,
      'tid': 'ffkm:2026-08-24_pm',
      'tournament': 'Первенство Москвы',
      'src': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/index.htm',
      'built': '2026-08-24T18:40:00+03:00',
      'marks': true,
      'categories': [
        {
          'kind': 'dance',
          'level': 'junior',
          'name': 'Танцы на льду, КМС, Юниорки, Юниоры',
          'segments': [
            {
              'code': 'РТ',
              'name': 'Ритм-танец',
              'page': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/SEG007.HTM',
              'table': 'results',
              'state': state,
              'basis': state == 'final' ? basis : null,
              'skipped': 0,
              'rows': rows ??
                  [
                    {'i': 1, 'place': 1, 'name': 'Анна Павловна БИЛИБИНА / Дмитрий Владимирович КАШАЕВ', 'nation': '', 'points': '66.36'},
                    {'i': 2, 'place': 2, 'name': 'Полина Андреевна ЖАРОВА / Алексей Игоревич СТОЛЯРОВ', 'nation': '', 'points': '65.28'},
                    {'i': 3, 'place': 3, 'name': 'Евдокия Максимовна КРЮЧКОВА / Артем Игоревич МЯКИШЕВ', 'nation': '', 'points': '62.45'},
                  ],
            },
          ],
          'total': null,
        },
      ],
    });

    test('окончательный сегмент: тройка из файла, имена как в расписании', () {
      final field = ['Анна Билибина / Дмитрий Кашаев', 'Полина Жарова / Алексей Столяров'];
      final r = liveFromProtocol(liveStart(basis: 'judges', field: field), doc('final')) as LiveOk;
      expect(r.provisional, isFalse);
      expect(r.podium.first.name, 'Анна Билибина / Дмитрий Кашаев');
      // второй есть в составе — имя как в расписании; третьего в составе нет — имя как в файле
      expect(r.podium[1].name, 'Полина Жарова / Алексей Столяров');
      expect(r.podium[2].name, 'Евдокия Максимовна КРЮЧКОВА / Артем Игоревич МЯКИШЕВ');
      expect(r.places[norm('Анна Билибина / Дмитрий Кашаев')], 1);
      expect(r.podium.map((p) => p.place), [1, 2, 3]);
    });
    test('промежуточный сегмент — provisional, окончательность не выставляем', () {
      final r = liveFromProtocol(liveStart(), doc('in_progress')) as LiveOk;
      expect(r.provisional, isTrue);
    });
    test('сверка не сошлась или формат — ничего не показываем', () {
      expect(liveFromProtocol(liveStart(), doc('judges_mismatch')), isA<LiveFormat>());
      expect(liveFromProtocol(liveStart(), doc('format')), isA<LiveFormat>());
    });
    test('сегмента нет в файле или строк нет — LiveNone', () {
      expect(liveFromProtocol(liveStart(seg: 'КП'), doc('final')), isA<LiveNone>());
      expect(liveFromProtocol(liveStart(), doc('not_published', rows: const [])), isA<LiveNone>());
    });
    test('personKey: имя с отчеством и фамилией капсом совпадает с именем из расписания', () {
      expect(personKey('Анна Павловна БИЛИБИНА / Дмитрий Владимирович КАШАЕВ'), personKey('Анна Билибина / Дмитрий Кашаев'));
      expect(personKey('Даниил ЖОЛОБОВ'), personKey('Даниил Жолобов'));
    });
  });
}
