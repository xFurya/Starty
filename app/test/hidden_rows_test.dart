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

  Future<void> open(WidgetTester t, Start st, {double width = 360}) async {
    t.view.physicalSize = Size(width * 3, 3000);
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
    expect(find.byTooltip('Живые места', skipOffstage: false), findsNothing);
  });

  testWidgets('карточка старта с протоколом предлагает «Живые места»', (t) async {
    await open(t, _start(proto: 'x_1.json'));
    expect(find.byTooltip('Живые места', skipOffstage: false), findsOneWidget);
  });

  // Чип режима живых мест — только пока опрашивать есть что: старт не прошёл, идёт или прошёл без
  // окончательного итога. Окончательный итог (Start.settled) — чипа нет совсем.
  Start timedStart({required Duration from, required Duration to, bool withFinal = false, bool judges = true}) {
    // тройка без судейских оценок — промежуточная: provisional, basis не задан
    final now = DateTime.now().toUtc();
    return Start.fromJson({
      'id': 'x:2',
      'tid': 'x',
      'tournament': 'Турнир',
      'kind': 'dance',
      'level': 'junior',
      'seg': 'РТ',
      'title': 'Турнир — танцы РТ',
      'src': 'https://example.org/index.htm',
      'proto': 'x_2.json',
      'start': now.add(from).toIso8601String(),
      'end': now.add(to).toIso8601String(),
      'podium': withFinal ? [{'place': 1, 'name': 'Иванова А.', 'nation': 'RUS', 'points': '90.1'}] : [],
      'provisional': !withFinal || !judges,
      'live': {
        'idx': 'https://example.org/index.htm',
        'seg': 'https://example.org/SEG1.HTM',
        'names': {},
        'basis': withFinal && judges ? 'judges' : null,
      },
    });
  }

  testWidgets('будущий старт: чип есть', (t) async {
    await open(t, timedStart(from: const Duration(days: 1), to: const Duration(days: 1, hours: 2)), width: 430);
    expect(find.byTooltip('Живые места', skipOffstage: false), findsOneWidget);
  });

  testWidgets('идущий старт: чип есть', (t) async {
    await open(t, timedStart(from: const Duration(hours: -1), to: const Duration(hours: 1)), width: 430);
    expect(find.byTooltip('Живые места', skipOffstage: false), findsOneWidget);
  });

  testWidgets('прошедший старт без окончательных результатов: чип есть', (t) async {
    await open(t, timedStart(from: const Duration(hours: -3), to: const Duration(hours: -1)), width: 430);
    expect(find.byTooltip('Живые места', skipOffstage: false), findsOneWidget);
  });

  testWidgets('прошедший старт с промежуточной тройкой (без судейских оценок): чип есть', (t) async {
    await open(t, timedStart(from: const Duration(hours: -3), to: const Duration(hours: -1), withFinal: true, judges: false), width: 430);
    expect(find.byTooltip('Живые места', skipOffstage: false), findsOneWidget);
  });

  testWidgets('завершённый старт с окончательными результатами: чипа нет, и подписи «Живые места» нет', (t) async {
    await open(t, timedStart(from: const Duration(hours: -3), to: const Duration(hours: -1), withFinal: true), width: 430);
    expect(find.byTooltip('Живые места', skipOffstage: false), findsNothing);
    expect(find.text('Живые места', skipOffstage: false), findsNothing);
    expect(find.text('Моментально', skipOffstage: false), findsNothing);
  });
}
