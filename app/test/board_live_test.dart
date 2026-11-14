// Табло ФФККР во время старта (этап Гран-при России, Омск, 14.11.2026, мужчины КП): протокол на
// устройстве по-русски, «Далее: …», разминка, время табло. Страницы — как их отдавало табло.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:starty/data.dart';
import 'package:starty/live.dart';
import 'package:starty/pace.dart';
import 'package:starty/protocol_live.dart';

String page(String f) => utf8.decode(File('test/live/omsk/$f').readAsBytesSync());

Start men() => Start.fromJson({
  'id': 'fsr:omsk:men-senior-kp',
  'tid': 'fsr:omsk',
  'tournament': 'Гран-при России «Сердце Сибири»',
  'kind': 'men',
  'level': 'senior',
  'seg': 'КП',
  'title': 'Гран-при России «Сердце Сибири» — мужчины КП',
  'start': '2026-11-14T14:25:00+03:00',
  'end': '2026-11-14T15:51:00+03:00',
  'venue': 'Омск',
  'intl': false,
  'field': [
    for (final (n, t, no, w) in [
      ('Артемий Маринин', '14:32', 1, 1),
      ('Арсений Димитриев', '14:38', 2, 1),
      ('Михаил Полянский', '14:44', 3, 1),
      ('Александр Мельников', '14:50', 4, 1),
      ('Фёдор Зонов', '14:55', 5, 1),
      ('Илья Мавлянов', '15:01', 6, 1),
      ('Илья Строганов', '15:15', 7, 2),
    ])
      {'name': n, 'nation': 'МОС', 'time': t, 'no': no, 'warmup': w},
  ],
  'live': {'idx': 'https://fsrussia.ru/results/2627/5etap_sen/index.htm', 'seg': 'https://fsrussia.ru/results/2627/5etap_sen/SEG001.htm', 'names': {}},
});

void main() {
  test('«Далее: …» и разминка: пока строка разминки стоит над ним — разминка идёт', () {
    expect(nextInfo(page('SEG001_before.htm')), isNull, reason: 'до начала — просто стартовый порядок');
    expect(nextInfo(page('SEG001_warmup.htm')), (name: 'Артемий МАРИНИН', warmup: true));
    expect(nextInfo(page('SEG001_onice.htm')), (name: 'Артемий МАРИНИН', warmup: false));
  });

  test('время табло — строка «Обновлено» с поясом машины табло', () {
    expect(boardStamp(page('SEG001_warmup.htm')), DateTime.utc(2026, 11, 14, 11, 37));
    expect(boardStamp(page('SEG001_onice.htm')), DateTime.utc(2026, 11, 14, 11, 43));
  });

  test('протокол на устройстве собирается с русского табло: категории и сегменты по-русски', () async {
    var seg = 'SEG001_warmup.htm';
    ProtocolLive.client = MockClient((r) async {
      final p = r.url.path;
      if (p.endsWith('index.htm')) return http.Response.bytes(File('test/live/omsk/index.htm').readAsBytesSync(), 200);
      if (p.endsWith('SEG001.htm')) return http.Response.bytes(File('test/live/omsk/$seg').readAsBytesSync(), 200);
      return http.Response('', 404);
    });
    Future<Map> kp() async {
      final b = await ProtocolLive.build(tid: 'fsr:omsk', tournament: 'Омск', idx: men().live!.idx, starts: [men()], now: DateTime.utc(2026, 11, 14, 11, 41));
      expect(b, isNotNull, reason: 'раньше русские «Мужчины - МС» и «Короткая программа» не узнавались — протокол не собирался');
      final cats = {for (final c in b!.json['categories'] as List) '${c['kind']}|${c['level']}': c};
      expect(cats.keys, containsAll(['men|senior', 'women|senior', 'pairs|senior', 'dance|senior']));
      return (cats['men|senior']['segments'] as List).firstWhere((s) => s['code'] == 'КП') as Map;
    }

    final warm = await kp();
    expect(warm['state'], 'in_progress', reason: 'оценок нет, но табло пишет, кто выходит, — сегмент идёт');
    expect(warm['next'], 'Артемий Маринин', reason: 'имя — как в расписании');
    expect(warm['nextWarmup'], isTrue);
    expect(warm['stamp'], '2026-11-14T11:37:00.000Z');
    seg = 'SEG001_onice.htm';
    final ice = await kp();
    expect(ice['nextWarmup'], isNull);
  });

  test('темп: пока идёт разминка — выход после неё; разминка кончилась — выход с этого момента', () {
    final s = men();
    DateTime m(String hm) => DateTime.parse('2026-11-14T$hm:00+03:00');
    // табло назвало Маринина в 14:37 (разминка началась на 12 минут позже расписания)
    final warm = paceOf(s, onIce: (key: personKey('Артемий Маринин'), since: m('14:37'), warmup: true), now: m('14:40'))!;
    expect(hm(warm.at[personKey('Артемий Маринин')]!), '14:44', reason: 'разминка — семь с половиной минут, как в шаблоне');
    expect(warm.late, isTrue);
    // в 14:43 строка разминки исчезла — он на льду
    final ice = paceOf(s, onIce: (key: personKey('Артемий Маринин'), since: m('14:43'), warmup: false), now: m('14:45'))!;
    expect(hm(ice.at[personKey('Артемий Маринин')]!), '14:43');
    expect(ice.delay.inMinutes, 11);
  });
}
