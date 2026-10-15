// Опрос на экране по режиму: «моментально» — табло, «с опозданием» — только файл протокола.
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

void main() {
  late List<String> calls;

  /// Старт, который идёт сейчас: табло — SEG007, файл протокола — ffkm_2026-08-24_pm.json.
  Schedule schedule() {
    final now = DateTime.now().toUtc();
    final s = Start.fromJson({
      'id': 'ffkm:2026-08-24_pm:dance-junior-rt',
      'tid': 'ffkm:2026-08-24_pm',
      'tournament': 'Первенство Москвы',
      'kind': 'dance',
      'level': 'junior',
      'seg': 'РТ',
      'title': 'Первенство Москвы — танцы РТ',
      'src': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/index.htm',
      'start': now.subtract(const Duration(hours: 1)).toIso8601String(),
      'end': now.add(const Duration(hours: 1)).toIso8601String(),
      'proto': 'ffkm_2026-08-24_pm.json',
      'live': {
        'idx': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/index.htm',
        'seg': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/SEG007.HTM',
        'names': {},
      },
    });
    return Schedule([s], now, true, false);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
    calls = [];
    Live.client = MockClient((r) async {
      calls.add('табло ${r.url.path.split('/').last}');
      return http.Response.bytes(File('test/golden/ffkm/SEG007.htm').readAsBytesSync(), 200);
    });
    final file = jsonEncode(
      jsonDecode(File('test/protocol/sample.json').readAsStringSync()),
    );
    ProtocolRepo.app = ProtocolRepo(
      client: MockClient((r) async {
        calls.add('файл ${r.url.path.split('/').last}');
        return http.Response.bytes(utf8.encode(file), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
  });

  tearDown(() {
    Live.client = http.Client();
    ProtocolRepo.app = ProtocolRepo();
  });

  // Итоги сами в состояние не применяем (нужна загрузка расписания): проверяем, откуда пошёл опрос.
  test('моментально (по умолчанию): опрос табло, файл не читаем', () async {
    final state = AppState()..data = schedule();
    await state.pollLive();
    expect(calls.where((c) => c.startsWith('табло')), isNotEmpty);
    expect(calls.where((c) => c.startsWith('файл')), isEmpty);
  });

  test('с опозданием: табло не трогаем, файл протокола читаем', () async {
    final state = AppState()..data = schedule();
    // смена режима сама запускает опрос в фоне — дождаться его, а не очищать журнал на ходу
    await state.setLiveMode(liveDelayed);
    await pumpEventQueue();
    expect(calls.where((c) => c.startsWith('табло')), isEmpty, reason: 'табло на телефоне не опрашиваем');
    expect(calls, contains('файл ffkm_2026-08-24_pm.json'));
  });

  test('переопределение старта важнее общего режима', () async {
    final state = AppState()..data = schedule();
    await state.setLiveMode(liveDelayed);
    await pumpEventQueue();
    calls.clear();
    await state.setLiveOverride('ffkm:2026-08-24_pm:dance-junior-rt', liveInstant);
    await pumpEventQueue();
    expect(state.liveModeOf(state.data!.starts.single), liveInstant);
    expect(calls.where((c) => c.startsWith('табло')), isNotEmpty);
    expect(calls.where((c) => c.startsWith('файл')), isEmpty);
  });

  test('переопределение сохраняется в Prefs и снимается «как в настройках»', () async {
    final state = AppState()..data = schedule();
    await state.setLiveOverride('a', liveDelayed);
    await pumpEventQueue();
    expect(Prefs.liveOverrides, {'a': liveDelayed});
    await state.setLiveOverride('a', null);
    await pumpEventQueue();
    expect(Prefs.liveOverrides, isEmpty);
    expect(state.liveOverrides, isEmpty);
  });

  test('смена режима пересчитывает опрос: сначала табло, потом файл', () async {
    final state = AppState()..data = schedule();
    await state.pollLive();
    expect(calls.where((c) => c.startsWith('табло')), isNotEmpty);
    calls.clear();
    await state.setLiveMode(liveDelayed);
    await pumpEventQueue();
    expect(calls.where((c) => c.startsWith('табло')), isEmpty);
    expect(calls, contains('файл ffkm_2026-08-24_pm.json'));
    expect(Prefs.liveMode, liveDelayed);
  });
}
