// Строка «Расписание» в настройках: «обновлено» — время сборки на сервере, от нажатия оно не
// меняется, поэтому ниже — когда расписание проверил телефон. Без этого нажатие выглядело пустым.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/settings.dart' show scheduleLine;
import 'package:starty/state.dart';
import 'package:starty/ui.dart' show nb;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
  });
  tearDown(() => Repo.client = http.Client());

  test('после удачной проверки — когда проверено; без связи — не показываем', () async {
    final body = File('test/events_sample.json').readAsStringSync();
    final s = AppState();
    expect(s.fetchedAt, isNull);

    Repo.client = MockClient((_) async => http.Response.bytes(utf8.encode(body), 200));
    await s.load();
    expect(s.fetchedAt, isNotNull);
    final ok = scheduleLine(s).text.split('\n');
    expect(ok.where((l) => l.startsWith('Обновлено ')), hasLength(1), reason: 'время сборки на сервере остаётся');
    expect(ok.last, 'Проверено в$nb${hm(s.fetchedAt!)}');

    // связь пропала: время прошлой проверки не выдаём за свежее — первой строкой «Нет связи»
    Repo.client = MockClient((_) async => http.Response('', 500));
    await s.load();
    final off = scheduleLine(s);
    expect(off.text.split('\n').first, 'Нет связи');
    expect(off.text, isNot(contains('Проверено')));
    expect(off.alarm, isTrue);
    s.sync.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('пока идёт проверка — «Проверка…», а не прежнее время', () {
    final s = AppState()
      ..data = Schedule.parse(File('test/events_sample.json').readAsStringSync())
      ..loading = false
      ..refreshing = true;
    final line = scheduleLine(s);
    expect(line.text.split('\n').last, 'Проверка…');
    expect(line.alarm, isFalse);
    s.sync.dispose();
  });
}
