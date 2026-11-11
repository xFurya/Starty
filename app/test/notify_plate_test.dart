// Строка уведомления в карточке старта: «состав ещё не объявлен» — только когда выключено именно из-за
// «только с отслеживаемыми» при неизвестном составе, а остальным правилам старт подходит.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/reminders.dart';
import 'package:starty/sheets.dart';
import 'package:starty/state.dart';

Start _start({List<Map<String, Object?>> field = const []}) {
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
    // днём по Москве, чтобы правило о ночных стартах не мешало
    'start': DateTime.utc(now.year, now.month, now.day, 9).add(const Duration(days: 2)).toIso8601String(),
    'end': DateTime.utc(now.year, now.month, now.day, 11).add(const Duration(days: 2)).toIso8601String(),
    'field': field,
  });
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
  });

  Future<void> open(WidgetTester t, Start st, NotifyRules rules) async {
    t.view.physicalSize = const Size(390 * 3, 3000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final s = AppState()
      ..loading = false
      ..rules = rules;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) => TextButton(onPressed: () => showStart(c, st, s), child: const Text('open'))),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('состав неизвестен при «только с отслеживаемыми» — выключено и сказано почему', (t) async {
    await open(t, _start(), const NotifyRules(onlyFollowed: true));
    expect(find.text('Без уведомления', skipOffstage: false), findsOneWidget);
    expect(find.text('состав ещё не объявлен', skipOffstage: false), findsOneWidget);
  });

  testWidgets('старт не подходит и по другим правилам — подсказки о составе нет', (t) async {
    await open(t, _start(), const NotifyRules(onlyFollowed: true, kinds: {'women', 'men', 'pairs'}));
    expect(find.text('Без уведомления', skipOffstage: false), findsOneWidget);
    expect(find.text('состав ещё не объявлен', skipOffstage: false), findsNothing);
  });

  testWidgets('состав объявлен, отслеживаемых нет — выключено без подсказки', (t) async {
    await open(
      t,
      _start(field: [
        {'name': 'Иванова Анна / Петров Иван', 'no': 1},
      ]),
      const NotifyRules(onlyFollowed: true),
    );
    expect(find.text('Без уведомления', skipOffstage: false), findsOneWidget);
    expect(find.text('состав ещё не объявлен', skipOffstage: false), findsNothing);
  });

  testWidgets('без «только с отслеживаемыми» — включено', (t) async {
    await open(t, _start(), const NotifyRules());
    expect(find.textContaining('Уведомление в', skipOffstage: false), findsOneWidget);
    expect(find.text('состав ещё не объявлен', skipOffstage: false), findsNothing);
  });
}
