// Трансляции: разбор поля watch и строки ресурсов в «Трансляция» карточки старта.
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/sheets.dart';
import 'package:starty/state.dart';
import 'package:starty/views.dart';

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

  Future<void> open(WidgetTester t, Start st, {double width = 390, double scale = 1.0, Brightness brightness = Brightness.light}) async {
    t.view.physicalSize = Size(width * 3, 3000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final s = AppState()..loading = false;
    await t.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: brightness),
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

  testWidgets('без watch — только названия, значков нет', (t) async {
    await open(t, _start(broadcast: ['Первый канал']));
    expect(find.text('ТРАНСЛЯЦИЯ', skipOffstage: false), findsOneWidget);
    expect(find.text('Первый канал', skipOffstage: false), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.arrow_up_right, skipOffstage: false), findsNothing);
  });

  testWidgets('один ресурс — та же строка с значком', (t) async {
    final opened = <String>[];
    watchOpener = (c, u, t) async => opened.add(u);
    addTearDown(() => watchOpener = (c, u, t) async {});
    await open(t, _start(broadcast: ['Первый канал'], watch: [
      {'name': 'Первый канал', 'url': 'https://www.1tv.ru/live'},
    ]));
    expect(find.byIcon(CupertinoIcons.arrow_up_right, skipOffstage: false), findsOneWidget);
    await t.tap(find.text('Первый канал', skipOffstage: false));
    expect(opened, ['https://www.1tv.ru/live']);
  });

  testWidgets('нажатие на строку открывает именно этот ресурс', (t) async {
    final opened = <String>[];
    watchOpener = (c, u, t) async => opened.add(u);
    addTearDown(() => watchOpener = (c, u, t) async {});
    await open(t, _start(broadcast: ['Первый канал', 'YouTube'], watch: [
      {'name': 'Первый канал', 'url': 'https://www.1tv.ru/live'},
      {'name': 'YouTube', 'url': 'https://www.youtube.com/watch?v=abc'},
    ]));
    expect(find.byIcon(CupertinoIcons.arrow_up_right, skipOffstage: false), findsNWidgets(2));
    await t.tap(find.byKey(const ValueKey('watch:YouTube'), skipOffstage: false));
    await t.tap(find.byIcon(CupertinoIcons.arrow_up_right, skipOffstage: false).first);
    await t.tap(find.byKey(const ValueKey('watch:Первый канал'), skipOffstage: false));
    expect(opened, ['https://www.youtube.com/watch?v=abc', 'https://www.1tv.ru/live', 'https://www.1tv.ru/live']);
  });

  testWidgets('строка ресурса не ниже 44 pt и названа для читалок', (t) async {
    await open(t, _start(broadcast: ['YouTube'], watch: [
      {'name': 'YouTube', 'url': 'https://www.youtube.com/watch?v=abc'},
    ]));
    final row = find.byKey(const ValueKey('watch:YouTube'), skipOffstage: false);
    expect(t.getSize(row).height, greaterThanOrEqualTo(44));
    expect(
      find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Открыть трансляцию: YouTube', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('длинное название переносится, а не обрезается', (t) async {
    const long = 'Очень длинное название трансляции для проверки переноса строк в узкой плашке карточки старта';
    await open(t, _start(broadcast: [long], watch: [
      {'name': long, 'url': 'https://example.org/long'},
    ]), width: 360, scale: 1.3);
    expect(t.takeException(), isNull);
    final text = find.text(long, skipOffstage: false);
    final rp = t.renderObject<RenderParagraph>(text);
    expect(rp.didExceedMaxLines, isFalse);
    expect(rp.size.height, greaterThan(30), reason: 'название должно занять несколько строк');
  });

  for (final w in [360.0, 390.0, 430.0]) {
    for (final sc in [1.0, 1.3]) {
      for (final b in [Brightness.light, Brightness.dark]) {
        testWidgets('без переполнения: ширина $w, масштаб $sc, ${b.name}', (t) async {
          await open(t, _start(broadcast: ['Первый канал', 'Okko', 'VK Видео'], watch: [
            {'name': 'Первый канал', 'url': 'https://www.1tv.ru/live'},
            {'name': 'Okko', 'url': 'https://okko.tv/', 'note': 'Россия, Беларусь, Казахстан'},
            {'name': 'VK Видео', 'url': 'https://vk.com/video'},
            {'name': 'YouTube ISU', 'url': 'https://www.youtube.com/@SkatingISU/live', 'note': 'Кроме России, Беларуси и Казахстана'},
          ]), width: w, scale: sc, brightness: b);
          expect(t.takeException(), isNull);
          expect(find.byIcon(CupertinoIcons.arrow_up_right, skipOffstage: false), findsNWidgets(4));
        });
      }
    }
  }

  test('где доступна площадка — из данных; пустое и не строка не выдумываются', () {
    final w = WatchLink.parseAll([
      {'name': 'Okko', 'url': 'https://okko.tv/', 'note': ' Россия '},
      {'name': 'YouTube ISU', 'url': 'https://www.youtube.com/@SkatingISU/live', 'note': ''},
      {'name': 'VK Видео', 'url': 'https://vk.com/video', 'note': 5},
    ]);
    expect(w.map((e) => e.note), ['Россия', null, null]);
    expect(w.first.toJson(), {'name': 'Okko', 'url': 'https://okko.tv/', 'note': 'Россия'});
    expect(w[1].toJson().containsKey('note'), isFalse);
  });

  testWidgets('подпись «где доступна» — под названием и в имени для читалок', (t) async {
    await open(t, _start(broadcast: ['Okko', 'YouTube ISU'], watch: [
      {'name': 'Okko', 'url': 'https://okko.tv/', 'note': 'Россия'},
      {'name': 'YouTube ISU', 'url': 'https://www.youtube.com/@SkatingISU/live', 'note': 'Кроме России'},
      {'name': 'Первый канал', 'url': 'https://www.1tv.ru/live'},
    ]));
    expect(find.text('Россия', skipOffstage: false), findsOneWidget);
    expect(find.text('Кроме России', skipOffstage: false), findsOneWidget);
    final name = t.getRect(find.text('Okko', skipOffstage: false));
    final note = t.getRect(find.text('Россия', skipOffstage: false));
    expect(note.top, greaterThanOrEqualTo(name.bottom), reason: 'подпись — под названием');
    expect(note.left, name.left);
    expect(
      find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Открыть трансляцию: Okko, Россия', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Открыть трансляцию: Первый канал', skipOffstage: false),
      findsOneWidget,
    );
  });

  group('турнир без расписания', () {
    Upcoming up({Object? watch}) => Upcoming.fromJson({
      'tid': 'isu:t',
      'name': 'CS Tallinn Trophy',
      'start': '2026-11-16',
      'end': '2026-11-22',
      'venue': 'Tallinn, Estonia',
      'intl': true,
      'broadcast': ['Ice-Stars.TV'],
      'watch': ?watch,
    });

    Future<void> plate(WidgetTester t, Upcoming u, {double width = 390, double scale = 1.0, Brightness brightness = Brightness.light}) async {
      t.view.physicalSize = Size(width * 3, 2400);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final s = AppState()..loading = false;
      await t.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: ListView(children: [UnscheduledPlate(list: [u], state: s, dates: true)])),
      ));
      await t.pumpAndSettle();
    }

    test('watch и broadcast читаются и сохраняются, слияние не теряет найденную площадку', () {
      final u = up(watch: [
        {'name': 'Ice-Stars.TV', 'url': 'https://ice-stars.tv/tallinntrophy', 'note': 'Платно'},
      ]);
      expect(u.watch.single.note, 'Платно');
      final again = Upcoming.fromJson(u.toJson());
      expect(again.watch.single.url, 'https://ice-stars.tv/tallinntrophy');
      expect(again.broadcast, ['Ice-Stars.TV']);
      final merged = Upcoming.mergeKeepingRicher(u, up());
      expect(merged.watch.single.name, 'Ice-Stars.TV');
    });

    testWidgets('площадки нажимаются и открывают свою ссылку', (t) async {
      final opened = <String>[];
      watchOpener = (c, u, t) async => opened.add(u);
      addTearDown(() => watchOpener = (c, u, t) async {});
      await plate(t, up(watch: [
        {'name': 'Ice-Stars.TV', 'url': 'https://ice-stars.tv/tallinntrophy', 'note': 'Платно'},
      ]));
      expect(find.text('ТРАНСЛЯЦИЯ'), findsOneWidget);
      expect(find.text('Платно'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('watch:Ice-Stars.TV')));
      expect(opened, ['https://ice-stars.tv/tallinntrophy']);
      expect(t.getSize(find.byKey(const ValueKey('watch:Ice-Stars.TV'))).height, greaterThanOrEqualTo(44));
    });

    testWidgets('площадок нет — строки «Трансляция» нет', (t) async {
      await plate(t, up());
      expect(find.text('ТРАНСЛЯЦИЯ'), findsNothing);
      expect(find.byIcon(CupertinoIcons.arrow_up_right), findsNothing);
    });

    for (final b in [Brightness.light, Brightness.dark]) {
      testWidgets('без переполнения: 360, масштаб 1.3, ${b.name}', (t) async {
        await plate(t, up(watch: [
          {'name': 'Первый канал', 'url': 'https://www.1tv.ru/live'},
          {'name': 'YouTube ISU', 'url': 'https://www.youtube.com/@SkatingISU/live', 'note': 'Кроме России, Беларуси и Казахстана'},
        ]), width: 360, scale: 1.3, brightness: b);
        expect(t.takeException(), isNull);
        expect(find.byIcon(CupertinoIcons.arrow_up_right), findsNWidgets(2));
      });
    }
  });
}
