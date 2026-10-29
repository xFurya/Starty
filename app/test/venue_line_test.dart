// Место проведения — в плашке турнира, а не только в листе старта.
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/state.dart';
import 'package:starty/views.dart';

void main() {
  late Schedule data;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
    data = Schedule.parse(File('test/podium_sample.json').readAsStringSync());
  });

  Widget app(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

  testWidgets('плашка дня: место стоит под названием турнира один раз на группу', (t) async {
    final tid = data.starts.first.tid;
    final group = data.starts.where((s) => s.tid == tid).take(2).toList();
    expect(group.length, 2);
    final venue = group.first.venue;
    expect(venue, isNotEmpty);
    final state = AppState()
      ..data = data
      ..loading = false;
    await t.pumpWidget(app(DayPlate(starts: group, state: state)));
    expect(find.text(venue), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.location), findsOneWidget);
  });

  testWidgets('отдельная строка старта и прошедший сегмент: место под турниром', (t) async {
    final s = data.starts.first;
    final state = AppState()
      ..data = data
      ..loading = false;
    await t.pumpWidget(app(StartTile(start: s, state: state)));
    expect(find.text(s.venue), findsOneWidget);
    await t.pumpWidget(app(PastTile(start: s, state: state)));
    expect(find.text(s.venue), findsOneWidget);
  });

  testWidgets('места нет в данных — строки нет совсем', (t) async {
    await t.pumpWidget(app(const VenueLine('', color: Colors.grey)));
    expect(find.byType(Text), findsNothing);
    expect(find.byIcon(CupertinoIcons.location), findsNothing);
  });
}
