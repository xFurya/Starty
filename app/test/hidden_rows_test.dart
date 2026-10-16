// Строки, которых не должно быть, когда им нечего показывать: аккаунт без сервера, «Живые места» без протокола.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/settings.dart';
import 'package:starty/sheets.dart';
import 'package:starty/state.dart';

Start _start({String? proto}) {
  final now = DateTime.now().toUtc();
  return Start.fromJson({
    'id': 'x:1',
    'tid': 'x',
    'tournament': 'Турнир',
    'kind': 'dance',
    'level': 'junior',
    'seg': 'РТ',
    'title': 'Турнир — танцы РТ',
    'src': 'https://example.org/index.htm',
    'start': now.add(const Duration(days: 1)).toIso8601String(),
    'end': now.add(const Duration(days: 1, hours: 2)).toIso8601String(),
    'proto': ?proto,
    'live': {'idx': 'https://example.org/index.htm', 'seg': 'https://example.org/SEG1.HTM', 'names': {}},
  });
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
  });

  testWidgets('без адреса сервера раздела «Аккаунт» в настройках нет', (t) async {
    t.view.physicalSize = const Size(1080, 4000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final s = AppState()..loading = false;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: SettingsView(state: s))));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Аккаунт', skipOffstage: false), findsNothing);
  });

  Future<void> open(WidgetTester t, Start st) async {
    t.view.physicalSize = const Size(1080, 3000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final s = AppState()..loading = false;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) => TextButton(onPressed: () => showStart(c, st, s), child: const Text('open'))),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('карточка старта без протокола не предлагает «Живые места»', (t) async {
    await open(t, _start());
    expect(find.textContaining('Живые места', skipOffstage: false), findsNothing);
  });

  testWidgets('карточка старта с протоколом предлагает «Живые места»', (t) async {
    await open(t, _start(proto: 'x_1.json'));
    expect(find.textContaining('Живые места', skipOffstage: false), findsOneWidget);
  });
}
