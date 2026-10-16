// Блок «Виды» на экране «Уведомления»: короткие подписи «Женщины», «Мужчины», «Пары», «Танцы»,
// плитки ряда одной высоты (не ниже 48), без переполнений при 360/390/430, масштабе 1.0/1.3, светлой и тёмной.
// Шрифт Manrope — настоящий, чтобы замеры были честными.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/settings.dart';
import 'package:starty/state.dart';
import 'package:starty/ui.dart';

Future<void> _manrope() async {
  final l = FontLoader('Manrope');
  for (final f in Directory('assets/fonts').listSync().whereType<File>().where((f) => f.path.contains('Manrope'))) {
    l.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await l.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_manrope);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
  });

  Future<void> open(WidgetTester t, {double width = 390, double scale = 1.0, Brightness b = Brightness.light}) async {
    t.view.physicalSize = Size(width * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final s = AppState()..loading = false;
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: b, fontFamily: 'Manrope'),
        builder: (c, nav) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: nav!,
        ),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    openNotifySettings(t.element(find.byType(Scaffold)), s);
    await t.pumpAndSettle();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
  }

  // подписи видов — по порядку NotifyRules.allKinds: женщины, мужчины, пары, танцы
  const labels = ['Женщины', 'Мужчины', 'Пары', 'Танцы'];

  testWidgets('подписи видов короткие: скобок и «девушек»/«юношей» на экране уведомлений нет', (t) async {
    await open(t);
    expect(t.takeException(), isNull);
    for (final l in labels) {
      expect(find.widgetWithText(ChoiceTile, l), findsOneWidget, reason: l);
    }
    expect(find.textContaining('(девушки)'), findsNothing);
    expect(find.textContaining('(юноши)'), findsNothing);
    expect(find.text('Девушки'), findsNothing);
    expect(find.text('Юноши'), findsNothing);
  });

  testWidgets('плитки ряда одной высоты, не ниже 48', (t) async {
    await open(t, width: 360, scale: 1.3);
    double h(String l) => t.getSize(find.widgetWithText(ChoiceTile, l)).height;
    // ряды: «Женщины»/«Мужчины» и «Пары»/«Танцы»
    expect(h('Женщины'), h('Мужчины'));
    expect(h('Пары'), h('Танцы'));
    for (final l in labels) {
      expect(h(l), greaterThanOrEqualTo(48), reason: l);
    }
  });

  for (final width in [360.0, 390.0, 430.0]) {
    for (final scale in [1.0, 1.3]) {
      for (final b in Brightness.values) {
        testWidgets('блок «Виды» без переполнений: ${width.toInt()} px, шрифт $scale, $b', (t) async {
          await open(t, width: width, scale: scale, b: b);
          expect(t.takeException(), isNull);
          for (final l in labels) {
            expect(find.widgetWithText(ChoiceTile, l), findsOneWidget, reason: l);
          }
          final h1 = t.getSize(find.widgetWithText(ChoiceTile, 'Женщины')).height;
          final h2 = t.getSize(find.widgetWithText(ChoiceTile, 'Мужчины')).height;
          final h3 = t.getSize(find.widgetWithText(ChoiceTile, 'Пары')).height;
          final h4 = t.getSize(find.widgetWithText(ChoiceTile, 'Танцы')).height;
          expect(h1, h2);
          expect(h3, h4);
        });
      }
    }
  }
}
