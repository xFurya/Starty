// «Живые места» без окна: переключатель в настройках и строка-меню в карточке старта.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/settings.dart';
import 'package:starty/sheets.dart';
import 'package:starty/state.dart';

const _instantCaption = 'Табло опрашивается раз в минуту';
const _delayedCaption = 'Файл протокола, задержка до 10 минут, меньше расход батареи';

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

  testWidgets('настройки: смена сегмента меняет Prefs.liveMode и подпись', (t) async {
    t.view.physicalSize = const Size(390 * 3, 1400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final s = AppState()..loading = false;
    await t.pumpWidget(_app(_settings(s), 1.0));
    await t.pump(const Duration(milliseconds: 300));

    expect(find.text(_instantCaption), findsOneWidget);
    await t.ensureVisible(find.text('С опозданием'));
    await t.tap(find.text('С опозданием'));
    await t.pump(const Duration(milliseconds: 300));
    expect(Prefs.liveMode, liveDelayed);
    expect(s.liveMode, liveDelayed);
    expect(find.text(_delayedCaption), findsOneWidget);

    await t.tap(find.text('Моментально'));
    await t.pump(const Duration(milliseconds: 300));
    expect(Prefs.liveMode, liveInstant);
    expect(find.text(_instantCaption), findsOneWidget);
    expect(find.text(_delayedCaption), findsNothing);
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

    await t.tap(find.text('Живые места'));
    await t.pumpAndSettle();
    await t.tap(find.text('С опозданием').last);
    await t.pumpAndSettle();
    expect(s.liveOverrides[st.id], liveDelayed);
    expect(Prefs.liveOverrides[st.id], liveDelayed);

    await t.tap(find.text('Живые места'));
    await t.pumpAndSettle();
    await t.tap(find.text('Как в настройках').last);
    await t.pumpAndSettle();
    expect(s.liveOverrides.containsKey(st.id), isFalse);
    expect(Prefs.liveOverrides.containsKey(st.id), isFalse);
    expect(find.textContaining('как в настройках'), findsOneWidget);
  });

  // Ширины 360/390/430 и масштаб 1.0/1.3: без переполнения ни в настройках, ни в карточке.
  for (final width in [360.0, 390.0, 430.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('живые места — ${width.toInt()} px, шрифт $scale', (t) async {
        t.view.physicalSize = Size(width * 3, 900 * 3);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        final s = AppState()..loading = false;

        await t.pumpWidget(_app(_settings(s), scale));
        await t.pump(const Duration(milliseconds: 300));
        await t.ensureVisible(find.text('С опозданием'));
        await t.pump(const Duration(milliseconds: 100));
        expect(t.takeException(), isNull);

        final st = _start();
        await t.pumpWidget(_app(
          Builder(builder: (c) => Center(child: TextButton(onPressed: () => showStart(c, st, s), child: const Text('open')))),
          scale,
        ));
        await t.tap(find.text('open'));
        await t.pumpAndSettle();
        expect(find.text('Живые места'), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
  }
}
