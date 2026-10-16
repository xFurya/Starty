// Трансляции: разбор поля watch и кнопка ▶ в строке «Трансляция» карточки старта.
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/sheets.dart';
import 'package:starty/state.dart';

Start _start({List<String> broadcast = const [], Object? watch}) {
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
    'broadcast': broadcast,
    'watch': ?watch,
  });
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
  });

  test('разбор watch мягкий: битое и не http(s) пропускается', () {
    final w = WatchLink.parseAll([
      {'name': 'Первый канал', 'url': 'https://www.1tv.ru/live'},
      {'name': 'Окно', 'url': 'javascript:alert(1)'},
      {'name': 'Файл', 'url': 'file:///etc/passwd'},
      {'name': '', 'url': 'https://a.ru/'},
      {'name': 'Без ссылки'},
      'строка',
      {'name': 'Первый канал', 'url': 'https://dup.ru/'},
      {'name': 'Okko', 'url': ' https://okko.tv/ '},
    ]);
    expect(w.map((e) => e.name), ['Первый канал', 'Okko']);
    expect(w.last.url, 'https://okko.tv/');
    expect(WatchLink.parseAll(null), isEmpty);
    expect(WatchLink.parseAll('x'), isEmpty);
    expect(_start(watch: 5).watch, isEmpty);
  });

  Future<void> open(WidgetTester t, Start st, {double width = 390, double scale = 1.0}) async {
    t.view.physicalSize = Size(width * 3, 3000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final s = AppState()..loading = false;
    await t.pumpWidget(MaterialApp(
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(builder: (c) => TextButton(onPressed: () => showStart(c, st, s), child: const Text('open'))),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('без watch — только названия, кнопок нет', (t) async {
    await open(t, _start(broadcast: ['Первый канал']));
    expect(find.text('ТРАНСЛЯЦИЯ', skipOffstage: false), findsOneWidget);
    expect(find.text('Первый канал', skipOffstage: false), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.play_fill, skipOffstage: false), findsNothing);
  });

  testWidgets('нажатие ▶ открывает именно эту трансляцию', (t) async {
    final opened = <String>[];
    watchOpener = (u) async => opened.add(u);
    addTearDown(() => watchOpener = (u) async {});
    await open(t, _start(broadcast: ['Первый канал', 'YouTube'], watch: [
      {'name': 'Первый канал', 'url': 'https://www.1tv.ru/live'},
      {'name': 'YouTube', 'url': 'https://www.youtube.com/watch?v=abc'},
    ]));
    expect(find.byIcon(CupertinoIcons.play_fill, skipOffstage: false), findsNWidgets(2));
    await t.tap(find.byKey(const ValueKey('watch:YouTube'), skipOffstage: false));
    await t.tap(find.byKey(const ValueKey('watch:Первый канал'), skipOffstage: false));
    expect(opened, ['https://www.youtube.com/watch?v=abc', 'https://www.1tv.ru/live']);
  });

  for (final w in [360.0, 390.0, 430.0]) {
    for (final sc in [1.0, 1.3]) {
      testWidgets('без переполнения: ширина $w, масштаб $sc', (t) async {
        await open(t, _start(broadcast: ['Первый канал', 'Okko', 'VK Видео'], watch: [
          {'name': 'Первый канал', 'url': 'https://www.1tv.ru/live'},
          {'name': 'Okko', 'url': 'https://okko.tv/'},
          {'name': 'VK Видео', 'url': 'https://vk.com/video'},
        ]), width: w, scale: sc);
        expect(t.takeException(), isNull);
        expect(find.byIcon(CupertinoIcons.play_fill, skipOffstage: false), findsNWidgets(3));
      });
    }
  }
}
