// Олимпиада-2022 из архива: командный турнир отдельными стартами, дисквалификация (места перешли к
// следующим, у дисквалифицированной — «DSQ», а не прочерк), флаги у наших, тёзки из разных видов.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/flags.dart';
import 'package:starty/history.dart' show Skate;
import 'package:starty/profile.dart';
import 'package:starty/protocol_model.dart';
import 'package:starty/protocol_screen.dart' show statusLast, statusLabel;
import 'package:starty/sheets.dart';
import 'package:starty/state.dart';
import 'package:starty/views.dart';

/// Старты Олимпиады-2022 из архива сайта (site/data/past/2022-02.json) и справочник с тёзкой.
Schedule _olympics() {
  final month = jsonDecode(File('../site/data/past/2022-02.json').readAsStringSync()) as Map<String, dynamic>;
  final events = [
    for (final e in month['events'] as List)
      if ((e as Map)['tid'] == 'isu:owg2022') e,
  ];
  return Schedule.parse(
    jsonEncode({
      'generated': '2026-11-14T12:00:00+03:00',
      'events': events,
      'people': [
        {
          'n': 'Анна Щербакова',
          'c': 'RUS',
          'k': 'd',
          'p': 'dancer',
          'alt': [
            {'was': 'w', 'p': 'single'},
          ],
        },
        {'n': 'Камила Валиева', 'c': 'RUS', 'k': '', 'was': 'w', 'y': '2021/22', 'p': 'kamila'},
      ],
    }),
  ).withFollow(Follow(const [], russians: true, belarusians: true));
}

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData(fontFamily: 'Golos Text'),
  home: Scaffold(body: child),
);

Future<void> _open(WidgetTester t, Start st, AppState s) async {
  await t.pumpWidget(
    _app(Builder(builder: (c) => Center(child: TextButton(onPressed: () => showStart(c, st, s), child: const Text('open'))))),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
  });

  test('командный турнир — отдельные старты; итог у него — командный зачёт стран', () {
    final d = _olympics();
    final team = d.starts.where((s) => s.team).toList();
    expect(team, hasLength(8));
    final women = d.byId('isu:owg2022:women-senior-kp')!;
    expect(women.team, isFalse);
    final wTeam = d.byId('isu:owg2022:women-senior-kp-team')!;
    expect(wTeam.segmentPlain, 'женщины КП');
    expect(wTeam.kind, 'women');
    final last = team.firstWhere((s) => s.total.isNotEmpty);
    expect(totalLabel(last), 'Командный зачёт');
    expect([for (final p in last.total) (p.place, p.name, p.points)], [(1, 'США', '65'), (2, 'Япония', '63'), (3, 'Россия', '54')]);
    expect(totalLabel(d.byId('isu:owg2022:women-senior-pp')!), 'Итог турнира');
  });

  test('протокол: у командного турнира свои категории с тем же видом', () {
    final doc = ProtocolDoc.fromJsonString(File('../site/data/past/protocols/isu_owg2022.json').readAsStringSync());
    expect(doc.categoryFor('women', 'senior')!.name, 'Women Single Skating');
    expect(doc.categoryFor('women', 'senior', team: true)!.name, 'Team Event - Women Single Skating');
  });

  test('тёзки: из старта одиночниц — одиночница, из танцев и вне старта — танцовщица', () {
    final d = _olympics();
    expect(d.personFor('Анна Щербакова', 'women')!.profile, 'single');
    expect(d.personFor('Анна Щербакова', 'dance')!.profile, 'dancer');
    expect(d.personFor('Анна Щербакова', null)!.profile, 'dancer');
    expect(d.personOf('Анна Щербакова')!.profile, 'dancer');
  });

  testWidgets('женщины КП: места перешли к следующим, у Валиевой — DSQ, у наших — флаги', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final d = _olympics();
    final s = AppState()
      ..data = d
      ..loading = false;
    final st = d.byId('isu:owg2022:women-senior-kp')!;
    expect([for (final p in st.podium) (p.place, p.name)].first, (1, 'Анна Щербакова'));
    await _open(t, st, s);
    expect(find.text('DSQ'), findsOneWidget);
    expect(find.text('дисквалификация, результат аннулирован'), findsOneWidget);
    // у наших вне тройки — флаг страны под именем
    expect(find.byType(NationTag), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('карточка командного: «командный турнир» в надзаголовке, зачёт стран', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final d = _olympics();
    final s = AppState()
      ..data = d
      ..loading = false;
    final last = d.starts.firstWhere((x) => x.team && x.total.isNotEmpty);
    await _open(t, last, s);
    expect(find.text('ОЛИМПИЙСКИЕ ИГРЫ 2022 · КОМАНДНЫЙ ТУРНИР'), findsOneWidget);
    expect(find.text('КОМАНДНЫЙ ЗАЧЁТ'), findsOneWidget);
    expect(find.textContaining('США', findRichText: true), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('имя в карточке одиночниц открывает одиночницу, а не тёзку-танцовщицу', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final asked = <String>[];
    final saved = profileLoader;
    profileLoader = (k) async {
      asked.add(k);
      return null;
    };
    addTearDown(() => profileLoader = saved);
    final d = _olympics();
    final s = AppState()
      ..data = d
      ..loading = false;
    await _open(t, d.byId('isu:owg2022:women-senior-pp')!, s);
    await t.tap(find.text('Щербакова').first);
    await t.pumpAndSettle();
    expect(asked, ['single']);
  });

  test('протокол: дисквалифицированная — после всех с местами, с элементами без оценок', () {
    final doc = ProtocolDoc.fromJsonString(File('../site/data/past/protocols/isu_owg2022.json').readAsStringSync());
    final rows = doc.categoryFor('women', 'senior')!.segmentOf('КП')!.rows;
    expect(rows.first.status, 'DSQ', reason: 'в файле — как на табло');
    final shown = statusLast(rows);
    expect((shown.first.place, shown.first.name), (1, 'Анна Щербакова'));
    expect((shown.last.status, shown.last.name), ('DSQ', 'Камила Валиева'));
    expect(shown.last.elements.first.name, '3A');
    expect(shown.last.elements.first.goe, isNull);
    expect(statusLabel('DSQ'), 'дисквалифицирован');
  });

  test('фото тёзки: у одиночницы своё (или буква), у танцовщицы — по имени', () {
    final d = Schedule.parse(
      jsonEncode({
        'generated': '2026-11-14T12:00:00+03:00',
        'events': [],
        'photos': {'Анна Щербакова': 'photos/dancer.jpg', 'Анна Щербакова (w)': 'photos/single.jpg'},
        'people': [
          {
            'n': 'Анна Щербакова',
            'c': 'RUS',
            'k': 'd',
            'alt': [
              {'was': 'w', 'p': 'single', 'ph': 'Анна Щербакова (w)'},
            ],
          },
          {
            'n': 'Алёна Косторная',
            'c': 'RUS',
            'k': '',
            'alt': [
              {'was': 'm', 'p': 'x', 'ph': 'Алёна Косторная (m)'},  // фото не нашлось — не чужое, а буква
            ],
          },
        ],
      }),
    );
    expect(d.photoFor('Анна Щербакова', 'women'), endsWith('photos/single.jpg'));
    expect(d.photoFor('Анна Щербакова', 'dance'), endsWith('photos/dancer.jpg'));
    expect(d.photoFor('Анна Щербакова', null), endsWith('photos/dancer.jpg'));
    expect(d.photoFor('Алёна Косторная', 'men'), isNull);
  });

  test('Командный чемпионат мира — командный турнир целиком, id прежние, зачёт команд в итоге', () {
    final month = jsonDecode(File('../site/data/past/2023-04.json').readAsStringSync()) as Map<String, dynamic>;
    final d = Schedule.parse(
      jsonEncode({
        'generated': '2026-11-14T12:00:00+03:00',
        'events': [for (final e in month['events'] as List) if ((e as Map)['tid'] == 'isu:wtt2023') e],
        'people': [],
      }),
    );
    expect(d.starts, hasLength(8));
    expect(d.starts.every((s) => s.team && !s.teamSub), isTrue);
    expect(d.starts.every((s) => !s.id.endsWith('-team')), isTrue);
    final last = d.starts.firstWhere((s) => s.total.isNotEmpty);
    expect(totalLabel(last), 'Командный зачёт');
    expect([for (final p in last.total) (p.place, p.name, p.points)], [(1, 'США', '120'), (2, 'Корея', '95'), (3, 'Япония', '94')]);
    expect(last.segmentPlain, last.segment, reason: 'у целиком командного пометка «командный» не дописывается');
  });

  test('история: командный прокат — свой, ключ не совпадает с личным', () {
    const a = Skate(day: '2022-02-15', tid: 't', tournament: 'T', kind: 'men', level: 'senior', seg: 'КП', place: 1, of: 30, intl: true);
    const b = Skate(day: '2022-02-04', tid: 't', tournament: 'T', kind: 'men', level: 'senior', seg: 'КП', place: 1, of: 9, intl: true, team: true);
    expect(a.key, isNot(b.key));
  });

  test('давно прошедший старт без итогов — «Итогов нет», без «пока»', () {
    final d = _olympics();
    expect(noResultsText(d.byId('isu:owg2022:women-senior-kp')!), 'Итогов нет');
  });
}
