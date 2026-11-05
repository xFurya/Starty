// Протокол, собранный на устройстве с табло: те же места и баллы, что в файле сборщика; детали оценок не теряются.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/protocol_live.dart';
import 'package:starty/protocol_model.dart';
import 'package:starty/protocol_repo.dart';

void main() {
  const base = 'https://results.isu.org/results/season2627/gpfra2026/';
  final now = DateTime.utc(2026, 11, 1, 12);

  setUp(() {
    ProtocolLive.client = MockClient((r) async {
      final f = File('test/fixtures/gpfra/${r.url.pathSegments.last}');
      if (!f.existsSync()) return http.Response('', 404);
      return http.Response.bytes(f.readAsBytesSync(), 200);
    });
  });

  group('кнопка обновления: протокол собирается на устройстве', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    final s = Start.fromJson({
      'id': 'isu:x:pairs-senior-ПП',
      'tid': 'isu:x',
      'tournament': 'GP de France',
      'kind': 'pairs',
      'level': 'senior',
      'seg': 'ПП',
      'title': 'GP de France — пары ПП',
      'src': '${base}index.htm',
      'start': '2026-11-01T13:00:00+01:00',
      'end': '2026-11-01T15:00:00+01:00',
      'proto': 'isu_x.json',
      'live': {'idx': '${base}index.htm', 'seg': 'SEG002.htm'},
    });
    // файла на сервере ещё нет — всё, что есть, собрано с табло
    ProtocolRepo noFile() => ProtocolRepo(client: MockClient((_) async => http.Response('', 404)), now: () => now);

    test('табло ответило — протокол с табло, источник помечен', () async {
      final r = await noFile().load('isu_x.json', start: s, starts: [s], device: true);
      expect(r, isA<ProtocolOk>());
      expect((r as ProtocolOk).board, isTrue);
      expect(r.doc.categories.any((c) => c.kind == 'pairs'), isTrue);
    });

    test('без кнопки табло не трогаем — источник не помечен', () async {
      var asked = 0;
      ProtocolLive.client = MockClient((_) async {
        asked++;
        return http.Response('', 500);
      });
      final r = await noFile().load('isu_x.json', start: s, starts: [s]);
      expect(asked, 0);
      expect(r, isNot(isA<ProtocolOk>()));
    });

    test('табло не ответило — файл сервера с пометкой «табло не ответило»', () async {
      ProtocolLive.client = MockClient((_) async => http.Response('', 500));
      final file = File('test/protocol/sample.json').readAsBytesSync();
      final repo = ProtocolRepo(client: MockClient((_) async => http.Response.bytes(file, 200)), now: () => now);
      final r = await repo.load('isu_x.json', start: s, starts: [s], device: true);
      expect(r, isA<ProtocolOk>());
      expect((r as ProtocolOk).board, isFalse);
    });
  });

  Map seg(Map<String, dynamic> doc, String kind, String code) =>
      ((doc['categories'] as List).firstWhere((c) => c['kind'] == kind)['segments'] as List).firstWhere((s) => s['code'] == code);

  test('пары, произвольная: окончательная, места и баллы с табло, фамилии не капсом', () async {
    final p = await ProtocolLive.build(tid: 'isu:x', tournament: 'GP de France', idx: '${base}index.htm', starts: const [], now: now);
    expect(p, isNotNull);
    final s = seg(p!.json, 'pairs', 'ПП');
    expect(s['state'], 'final');
    expect(s['basis'], 'judges');
    final rows = s['rows'] as List;
    expect(rows.length, 8);
    expect(rows.first['place'], 1);
    expect(rows.first['points'], '127.31');
    expect(rows.first['tes'], '59.95');
    expect(rows.first['name'], 'Anastasiia Metelkina / Luka Berulava');
    ProtocolDoc.fromJson(p.json); // файл разбирается приложением
  });

  test('итог вида: места по сегментам', () async {
    final p = await ProtocolLive.build(tid: 'isu:x', tournament: 'GP de France', idx: '${base}index.htm', starts: const [], now: now);
    final cat = (p!.json['categories'] as List).firstWhere((c) => c['kind'] == 'pairs');
    final t = cat['total'] as Map;
    expect(t['state'], 'final');
    expect(t['cols'], ['КП', 'ПП']);
    expect((t['rows'] as List).first['points'], '204.65');
  });

  test('детали оценок прежнего файла переносятся в свежий сегмент', () async {
    final cached = jsonDecode(jsonEncode({
      'v': 1,
      'tid': 'isu:x',
      'categories': [
        {
          'kind': 'pairs',
          'level': 'senior',
          'segments': [
            {
              'code': 'ПП',
              'state': 'provisional',
              'rows': [
                {'place': 1, 'name': 'Anastasiia Metelkina / Luka Berulava', 'els': [{'n': '3Tw'}], 'bv': 40.0, 'comp': []},
              ],
            },
          ],
        },
      ],
    })) as Map<String, dynamic>;
    final p = await ProtocolLive.build(tid: 'isu:x', tournament: 'GP de France', idx: '${base}index.htm', starts: const [], cached: cached, now: now);
    final rows = seg(p!.json, 'pairs', 'ПП')['rows'] as List;
    expect(rows.first['els'], isNotNull);
    expect(rows[1]['els'], isNull);
  });

  test('оглавление не прочиталось — null, а не пустой файл', () async {
    ProtocolLive.client = MockClient((_) async => http.Response('', 500));
    expect(await ProtocolLive.build(tid: 'isu:x', tournament: 't', idx: '${base}index.htm', starts: const [], now: now), isNull);
  });
}
