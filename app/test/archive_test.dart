// Архив прошлых сезонов: разбор индекса и месяца, загрузка по запросу, адрес протокола из архива.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:starty/archive.dart';
import 'package:starty/data.dart';

Map<String, dynamic> event(String id, String start, {String? proto}) => {
  'id': id,
  'tid': id.substring(0, id.lastIndexOf(':')),
  'tournament': 'Чемпионат России',
  'kind': 'women',
  'level': 'senior',
  'seg': 'ПП',
  'title': 'Чемпионат России — женщины ПП',
  'start': start,
  'end': start,
  'venue': 'Омск',
  'intl': false,
  'src': 'https://example.org/index.htm',
  'proto': ?proto,
  'podium': [
    {'place': 1, 'name': 'Аделия Петросян', 'nation': 'МОС', 'points': '177.14'},
  ],
  'field': [
    {'name': 'Аделия Петросян', 'nation': 'МОС', 'place': 1, 'points': '177.14', 'final': 1},
  ],
};

String month(List<Map<String, dynamic>> events, {List<Map<String, dynamic>> tournaments = const []}) =>
    jsonEncode({'v': 1, 'month': '2024-12', 'events': events, 'tournaments': tournaments});

void main() {
  test('индекс: месяцы, первый и последний', () {
    final i = PastIndex.parse(jsonEncode({'v': 1, 'months': {'2018-08': 8, '2024-12': 32, 'мусор': 1}}));
    expect(i.first, '2018-08');
    expect(i.last, '2024-12');
    expect(i.has('2024-12'), isTrue);
    expect(i.has('2024-07'), isFalse);
    expect(() => PastIndex.parse('{"v":2,"months":{}}'), throwsFormatException);
  });

  test('месяц: старты по времени, протокол — из архива, битая запись не роняет месяц', () {
    final m = PastMonth.parse(
      '2024-12',
      month([
        event('fsr:x:women-senior-pp', '2024-12-21T11:45:00+03:00', proto: 'fsr_x.json'),
        event('fsr:x:women-senior-kp', '2024-12-20T14:00:00+03:00'),
        {'id': 'битая'},
      ]),
    );
    expect([for (final s in m.starts) s.id], ['fsr:x:women-senior-kp', 'fsr:x:women-senior-pp']);
    final pp = m.starts.last;
    expect(pp.proto, 'past/fsr_x.json');
    expect(protocolUrl(pp.proto), endsWith('/data/past/protocols/fsr_x.json'));
    // прошедший старт архива — завершён и окончателен: табло по нему не опрашивается
    expect(pp.finished, isTrue);
    expect(pp.settled, isTrue);
    expect(pp.pastAt(DateTime.utc(2026, 11, 14)), isTrue);
  });

  test('адрес протокола: нынешний, из архива, путь наружу не проходит', () {
    expect(protocolUrl('isu_x.json'), endsWith('/data/protocols/isu_x.json'));
    expect(protocolUrl('past/isu_x.json'), endsWith('/data/past/protocols/isu_x.json'));
    expect(protocolUrl('past/../x.json'), isNull);
    expect(protocolUrl('../x.json'), isNull);
    expect(protocolUrl(null), isNull);
  });

  test('турнир без времени сегментов: дни, запись для списка дня, старт для протокола', () {
    final m = PastMonth.parse(
      '2024-12',
      month(const [], tournaments: [
        {'tid': 'fsr:z', 'name': 'Жигули', 'start': '2024-12-07', 'end': '2024-12-09', 'venue': 'Тольятти', 'intl': false, 'proto': 'fsr_z.json', 'kinds': ['men', 'women']},
        {'name': 'без tid'},
      ]),
    );
    expect(m.tournaments, hasLength(1));
    final t = m.tournaments.single;
    expect(t.covers('2024-12-08'), isTrue);
    expect(t.covers('2024-12-10'), isFalse);
    expect(t.asUpcoming.name, 'Жигули');
    expect(t.asStart.proto, 'past/fsr_z.json');
    expect(t.asStart.kind, 'men');
  });

  group('загрузка', () {
    late int index, months;
    late bool fail;
    setUp(() {
      index = months = 0;
      fail = false;
      Archive.client = MockClient((r) async {
        if (r.url.path.endsWith('/past/index.json')) {
          index++;
          return fail ? http.Response('', 500) : http.Response.bytes(utf8.encode(jsonEncode({'v': 1, 'months': {'2024-12': 1}})), 200);
        }
        months++;
        if (fail) return http.Response('', 500);
        return http.Response.bytes(utf8.encode(month([event('fsr:x:women-senior-pp', '2024-12-21T11:45:00+03:00')])), 200);
      });
    });

    test('месяц из архива берётся один раз; месяца нет в архиве — запроса нет', () async {
      final a = Archive();
      expect(a.stateOf('2024-12'), PastState.none);
      expect(await a.load('2024-12'), isTrue);
      expect(a.stateOf('2024-12'), PastState.ready);
      expect(a.month('2024-12')!.starts, hasLength(1));
      expect(await a.load('2024-12'), isFalse);
      expect(await a.load('2024-07'), isFalse);
      expect(a.stateOf('2024-07'), PastState.none);
      expect((index, months), (1, 1));
    });

    test('нет связи: месяц «не загрузился», повтор пробует снова', () async {
      final a = Archive();
      fail = true;
      expect(await a.load('2024-12'), isTrue);
      expect(a.stateOf('2024-12'), PastState.failed);
      fail = false;
      expect(await a.load('2024-12'), isTrue);
      expect(a.stateOf('2024-12'), PastState.ready);
    });
  });

  test('фильтр: международный старт архива виден и без россиян, остальные условия действуют', () {
    final s = Start.fromJson({...event('isu:wc2023:women-senior-pp', '2023-03-24T11:20:00+03:00'), 'intl': true, 'field': [
      {'name': 'Kaori Sakamoto', 'nation': 'JPN', 'place': 1},
    ]});
    expect(Filters.none.pass(s), isFalse);
    expect(Filters.none.pass(s, all: true), isTrue);
    expect(const Filters({'men'}, {}, {}).pass(s, all: true), isFalse);
    expect(const Filters({}, {}, {}, scope: {'russian'}).pass(s, all: true), isFalse);
  });
}
