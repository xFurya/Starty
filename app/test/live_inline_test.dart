// «Живые места» и «Тема»: строки-меню в настройках и чип-меню в карточке старта.
import 'dart:ui' show Tristate;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/settings.dart';
import 'package:starty/sheets.dart';
import 'package:starty/state.dart';

const _instantCaption = 'Моментально';
const _delayedCaption = 'С опозданием';

Start _start() {
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
    'proto': 'x_1.json',
    'live': {'idx': 'https://example.org/index.htm', 'seg': 'https://example.org/SEG1.HTM', 'names': {}},
  });
}

Widget _app(Widget child, double scale) => MaterialApp(
  builder: (c, nav) => MediaQuery(
    data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
    child: MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: nav!),
  ),
  home: Scaffold(body: child),
);

/// Настройки перестраиваются от состояния, как в оболочке приложения.
Widget _settings(AppState s) => ListenableBuilder(listenable: s, builder: (c, _) => SettingsView(state: s));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
  });

  Future<void> showRow(WidgetTester t, String title) async {
    await t.ensureVisible(find.text(title));
    await t.pump(const Duration(milliseconds: 100));
  }

  testWidgets('настройки: строка «Живые места» открывает меню, выбор меняет Prefs и подпись', (t) async {
    t.view.physicalSize = const Size(390 * 3, 1400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final s = AppState()..loading = false;
    await t.pumpWidget(_app(_settings(s), 1.0));
    await t.pump(const Duration(milliseconds: 300));

    expect(find.text(_instantCaption), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.bolt), findsOneWidget);
    await showRow(t, 'Живые места');
    await t.tap(find.text('Живые места'));
    await t.pumpAndSettle();
    // меню: два пункта, галочка у текущего
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
    expect(t.getSemantics(find.text('Моментально').last).getSemanticsData().flagsCollection.isSelected, Tristate.isTrue);
    expect(t.getSemantics(find.text('С опозданием').last).getSemanticsData().flagsCollection.isSelected, Tristate.isFalse);
    await t.tap(find.text('С опозданием'));
    await t.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.checkmark), findsNothing);
    expect(Prefs.liveMode, liveDelayed);
    expect(s.liveMode, liveDelayed);
    expect(find.text(_delayedCaption), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.timer), findsOneWidget);

    await t.tap(find.text('Живые места'));
    await t.pumpAndSettle();
    await t.tap(find.text('Моментально').last);
    await t.pumpAndSettle();
    expect(Prefs.liveMode, liveInstant);
    expect(find.text(_instantCaption), findsOneWidget);
  });

  testWidgets('настройки: тап вне меню закрывает его, ничего не меняя', (t) async {
    t.view.physicalSize = const Size(390 * 3, 1400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final s = AppState()..loading = false;
    await t.pumpWidget(_app(_settings(s), 1.0));
    await t.pump(const Duration(milliseconds: 300));
    await showRow(t, 'Живые места');
    await t.tap(find.text('Живые места'));
    await t.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.checkmark), findsNothing);
    expect(Prefs.liveMode, liveInstant);
  });

  testWidgets('настройки: «Тема» — значение в строке, меню из трёх пунктов, выбор меняет Prefs', (t) async {
    t.view.physicalSize = const Size(390 * 3, 1400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final s = AppState()..loading = false;
    await t.pumpWidget(_app(_settings(s), 1.0));
    await t.pump(const Duration(milliseconds: 300));
    await showRow(t, 'Тема');
    expect(find.text('Системная'), findsOneWidget);
    await t.tap(find.text('Тема'));
    await t.pumpAndSettle();
    expect(find.text('Светлая'), findsOneWidget);
    expect(find.text('Тёмная'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
    await t.tap(find.text('Тёмная'));
    await t.pumpAndSettle();
    expect(s.theme, ThemeMode.dark);
    expect(Prefs.theme, 'dark');
    expect(find.byIcon(CupertinoIcons.checkmark), findsNothing);
    expect(find.text('Тёмная'), findsOneWidget); // значение в строке
  });

  testWidgets('карточка: «Как в настройках» убирает переопределение старта', (t) async {
    t.view.physicalSize = const Size(390 * 3, 1000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final s = AppState()..loading = false;
    final st = _start();
    await t.pumpWidget(_app(
      Builder(builder: (c) => Center(child: TextButton(onPressed: () => showStart(c, st, s), child: const Text('open')))),
      1.0,
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    await t.tap(find.byTooltip('Живые места'));
    await t.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget); // «Как в настройках»
    await t.tap(find.text('С опозданием').last);
    await t.pumpAndSettle();
    expect(s.liveOverrides[st.id], liveDelayed);
    expect(Prefs.liveOverrides[st.id], liveDelayed);

    await t.tap(find.byTooltip('Живые места'));
    await t.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget); // «С опозданием»
    await t.tap(find.text('Как в настройках').last);
    await t.pumpAndSettle();
    expect(s.liveOverrides.containsKey(st.id), isFalse);
    expect(Prefs.liveOverrides.containsKey(st.id), isFalse);
    // чип показывает действующий режим одним словом, отдельной строки нет
    expect(find.text('Моментально'), findsOneWidget);
    expect(find.text('Живые места'), findsNothing);
  });

  // Ширины 360/390/430, масштаб 1.0/1.3, светлая и тёмная: без переполнения ни в строках,
  // ни в открытом меню, ни в карточке.
  for (final width in [360.0, 390.0, 430.0]) {
    for (final scale in [1.0, 1.3]) {
      for (final dark in [false, true]) {
        testWidgets('меню — ${width.toInt()} px, шрифт $scale, ${dark ? "тёмная" : "светлая"}', (t) async {
          t.view.physicalSize = Size(width * 3, 900 * 3);
          t.view.devicePixelRatio = 3;
          addTearDown(t.view.reset);
          final s = AppState()..loading = false;
          Widget app(Widget w) => Theme(
            data: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
            child: _app(w, scale),
          );

          await t.pumpWidget(app(_settings(s)));
          await t.pump(const Duration(milliseconds: 300));
          for (final title in ['Живые места', 'Тема']) {
            await showRow(t, title);
            expect(t.takeException(), isNull);
            await t.tap(find.text(title));
            await t.pumpAndSettle();
            expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
            expect(t.takeException(), isNull);
            final menu = t.getRect(find.byType(Material).last);
            expect(menu.left, greaterThanOrEqualTo(0));
            expect(menu.right, lessThanOrEqualTo(width));
            await t.tapAt(const Offset(2, 2));
            await t.pumpAndSettle();
          }

          final st = _start();
          await t.pumpWidget(app(
            Builder(builder: (c) => Center(child: TextButton(onPressed: () => showStart(c, st, s), child: const Text('open')))),
          ));
          await t.tap(find.text('open'));
          await t.pumpAndSettle();
          expect(find.byTooltip('Живые места'), findsOneWidget);
          expect(find.text('Живые места'), findsNothing);
          expect(t.takeException(), isNull);
          await t.ensureVisible(find.byTooltip('Живые места'));
          await t.pumpAndSettle();
          expect(t.getSize(find.byTooltip('Живые места')).height, greaterThanOrEqualTo(44));
          await t.tap(find.byTooltip('Живые места'));
          await t.pumpAndSettle();
          expect(find.text('Как в настройках'), findsOneWidget);
          expect(t.takeException(), isNull);
          final menu = t.getRect(find.byType(Material).last);
          expect(menu.left, greaterThanOrEqualTo(0));
          expect(menu.right, lessThanOrEqualTo(width));
        });
      }
    }
  }
}
