// Поиск спортсмена: лупа в шапке ленты, строка ведёт в профиль.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/profile.dart';
import 'package:starty/sheets.dart';
import 'package:starty/state.dart';
import 'package:starty/views.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync())));
  }
  await l.load();
}

Map<String, dynamic> _ev(String id, int inHours, List<String> names) {
  final t0 = DateTime.now().add(Duration(hours: inHours));
  return {
    'id': id, 'tid': 't', 'tournament': 'Турнир', 'kind': 'women', 'level': 'senior', 'seg': 'КП',
    'title': 'Турнир — женщины КП', 'start': t0.toUtc().toIso8601String(),
    'end': t0.add(const Duration(hours: 2)).toUtc().toIso8601String(), 'venue': '', 'intl': false, 'ours': [],
    'athletes': names,
  };
}

/// Завтра — Петросян и человек без профиля, послезавтра — Муравьёва и снова Петросян; вчера — Гуменник.
Schedule _data() => Schedule.parse(
  jsonEncode({
    'generated': DateTime.now().toUtc().toIso8601String(),
    'events': [
      _ev('c', 48, ['София Муравьёва', 'Аделия Петросян']),
      _ev('b', 24, ['Аделия Петросян', 'Без Профиля']),
      _ev('a', -24, ['Пётр Гуменник']),
    ],
    'roster': ['Без Профиля'],
    'people': [
      {'n': 'Аделия Петросян', 'c': 'RUS', 'k': 'w', 'p': 'adeliia-petrosian'},
      {'n': 'София Муравьёва', 'c': 'RUS', 'k': 'w'},
      {'n': 'Пётр Гуменник', 'c': 'RUS', 'k': 'm'},
      {'n': 'Анастасия Мишина / Александр Галлямов', 'c': 'RUS', 'k': 'p'},
    ],
  }),
);

void main() {
  late Future<Profile?> Function(String) saved;
  final at = DateTime.now();

  setUpAll(() async {
    await _font('Golos Text', ['GolosText-Regular.ttf', 'GolosText-Medium.ttf', 'GolosText-SemiBold.ttf', 'GolosText-Bold.ttf']);
    await _font('Piazzolla', ['Piazzolla-Medium.ttf', 'Piazzolla-SemiBold.ttf', 'Piazzolla-Bold.ttf']);
  });

  setUp(() async {
    // выбор человека: один с профилем, другого в справочнике нет
    SharedPreferences.setMockInitialValues({
      'follow': ['Пётр Гуменник', 'Нет Такого'],
    });
    await Prefs.init();
    saved = profileLoader;
    profileLoader = (k) async => null;
  });
  tearDown(() => profileLoader = saved);

  test('на ближайших стартах — по порядку стартов, без прошедших, без повторов и только с профилем', () {
    final d = _data();
    expect(nextAthletes(d, at), ['Аделия Петросян', 'София Муравьёва']);
    expect(nextAthletes(d, at, limit: 1), ['Аделия Петросян']);
  });

  test('поиск ведёт только к тем, у кого есть профиль', () {
    final d = _data();
    expect(searchAthletes(d, 'профиля'), ['Без Профиля']);
    expect(searchProfiles(d, 'профиля', at), isEmpty);
    expect(searchProfiles(d, 'петросян', at), ['Аделия Петросян']);
    // пара находится по любому из двоих и на латинице
    expect(searchProfiles(d, 'galliamov', at), ['Анастасия Мишина / Александр Галлямов']);
    // о ком есть справка — выше тех, о ком только имя и страна, хотя те выступают раньше по алфавиту
    expect(searchProfiles(d, 'а', at).first, 'Аделия Петросян');
    expect(searchProfiles(d, 'а', at), contains('Анастасия Мишина / Александр Галлямов'));
  });

  Widget app(AppState s, {Brightness b = Brightness.light, double scale = 1}) => MaterialApp(
    theme: ThemeData(brightness: b, fontFamily: 'Golos Text'),
    builder: (c, nav) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: nav!,
    ),
    home: Scaffold(body: FeedView(state: s)),
  );

  AppState state() => AppState()
    ..data = _data()
    ..loading = false;

  testWidgets('лупа открывает лист: отслеживаемые и ближайшие, запрос — найденные, строка — профиль', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(state()));
    await t.tap(find.byTooltip('Найти спортсмена'));
    await t.pumpAndSettle();
    expect(find.text('Спортсмены'), findsOneWidget);
    // отслеживаемый с профилем — в своём разделе; того, кого в справочнике нет, не показываем
    expect(find.text('ОТСЛЕЖИВАЕМЫЕ'), findsOneWidget);
    expect(find.textContaining('Гуменник', findRichText: true), findsOneWidget);
    expect(find.textContaining('Нет Такого', findRichText: true), findsNothing);
    expect(find.text('НА БЛИЖАЙШИХ СТАРТАХ'), findsOneWidget);
    expect(find.textContaining('Муравьёва', findRichText: true), findsOneWidget);
    expect(find.textContaining('Без Профиля', findRichText: true), findsNothing);

    await t.enterText(find.byType(TextField), 'мишина');
    await t.pumpAndSettle();
    expect(find.text('ОТСЛЕЖИВАЕМЫЕ'), findsNothing);
    expect(find.textContaining('Галлямов', findRichText: true), findsOneWidget);
    expect(find.textContaining('Петросян', findRichText: true), findsNothing);

    await t.tap(find.textContaining('Галлямов', findRichText: true));
    await t.pumpAndSettle();
    expect(find.byType(ProfileSheet), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('никого не нашлось — так и сказано', (t) async {
    await t.pumpWidget(app(state()));
    await t.tap(find.byTooltip('Найти спортсмена'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'щербакова');
    await t.pumpAndSettle();
    expect(find.text('Никого не нашлось. Проверьте фамилию.'), findsOneWidget);
    // человек есть в списках, но профиля у него нет — пустой строки не даём
    await t.enterText(find.byType(TextField), 'профиля');
    await t.pumpAndSettle();
    expect(find.text('Никого не нашлось. Проверьте фамилию.'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('узкий экран, крупный шрифт, $b — без переполнений', (t) async {
      t.view.physicalSize = const Size(320 * 3, 640 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(app(state(), b: b, scale: 1.3));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.byTooltip('Найти спортсмена'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.enterText(find.byType(TextField), 'а');
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }
}
