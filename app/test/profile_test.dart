import 'dart:convert';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/profile.dart';
import 'package:starty/sheets.dart' show SwipeSurface;
import 'package:starty/state.dart';

const _pairKey = 'aaaaaaaaaaaa';
const _soloKey = 'bbbbbbbbbbbb';
const _starKey = 'cccccccccccc';

/// Профиль пары в том виде, в каком его пишет сборщик (scraper/profiles.py).
const _pair = {
  'n': 'Minerva Fabienne Hase / Nikita Volodin',
  'who': [
    {'n': 'Minerva Fabienne Hase', 'born': '1999-06-10', 'place': 'Berlin', 'h': 168, 'since': 2004, 'former': ['Nolan Seegert']},
    {'n': 'Nikita Volodin', 'born': '1999-06-29', 'place': 'St. Petersburg RUS', 'h': 188},
  ],
  'coach': ['Dmitri Savin', 'Knut Schubert'],
  'choreo': ['Mark Pillay & Paul Boll'],
  'music': {
    'season': '2026/27',
    'sp': ['1989 by Laake'],
    'fs': ['The Four Seasons by Antonio Vivaldi'],
  },
  'pb': [
    {'s': 'total', 'pts': '228.33', 'd': '2026-03-26', 'ev': 'Чемпионат мира 2026'},
    {'s': 'sp', 'pts': '80.01', 'd': '2026-02-15', 'ev': 'Олимпийские игры 2026'},
  ],
  'sb': [
    {'s': 'fs', 'pts': '140.10', 'd': '2026-10-04', 'ev': 'CS Nebelhorn Trophy 2026'},
  ],
  'titles': [
    {'ev': 'Олимпийские игры 2026', 'k': 'p', 'pl': 3, 'y': '2025/26'},
    {'ev': 'Чемпионат мира 2026', 'k': 'p', 'pl': 1, 'y': '2025/26'},
    {'ev': 'Чемпионат Европы 2026', 'k': 'p', 'pl': 1, 'y': '2025/26'},
    {'ev': 'Чемпионат Германии 2026', 'k': 'p', 'pl': 1, 'y': '2025/26'},
    {'ev': 'Чемпионат мира 2025', 'k': 'p', 'pl': 2, 'y': '2024/25'},
    {'ev': 'Чемпионат Европы 2025', 'k': 'p', 'pl': 2, 'y': '2024/25'},
    {'ev': 'Финал Гран-при 2024', 'k': 'p', 'pl': 3, 'y': '2024/25'},
    {'ev': 'Чемпионат Германии 2025', 'k': 'p', 'pl': 1, 'y': '2024/25'},
  ],
  'res': [
    {
      'g': 'Олимпийские игры',
      'r': [
        {'ev': 'Олимпийские игры 2026', 'k': 'p', 'pl': 3},
      ],
    },
    {
      'g': 'Национальные чемпионаты',
      'r': [
        {'ev': 'Чемпионат Германии 2026', 'k': 'p', 'pl': 1},
        {'ev': 'Национальный чемпионат среди юниоров 2019', 'k': 'P', 'pl': 'WD'},
      ],
    },
  ],
  'src': ['ISU'],
  'at': '2026-11-05',
};

const _solo = {
  'n': 'Аделия Петросян',
  'who': [
    {'n': 'Аделия Петросян', 'born': '2007-06-05', 'rank': 'МС', 'region': 'Москва', 'club': 'МАФКК', 'h': 152},
  ],
  'team': {'c': 'Россия', 't': 'основной состав', 'y': '2026/27'},
  'coach': ['Гончаренко Инна Валерьевна'],
  'season': [
    {'s': '2025/26', 'ev': 'Чемпионат России', 'pl': '1'},
    {'s': '2025/26', 'ev': 'Гран-при России, этап 2', 'pl': '1 (МС)'},
  ],
  'src': ['ISU', 'ФФККР'],
  'at': '2026-11-05',
};

/// Профиль с «Примечательным»: семь первых в истории (из выверенного списка) и мировой рекорд ISU.
Map<String, Object> _star() => {
  'n': 'Александра Трусова',
  'who': [
    {'n': 'Александра Трусова', 'born': '2004-06-23'},
  ],
  'feats': [
    for (var i = 1; i <= 7; i++)
      {'t': 'Первое №$i', 'ev': 'Турнир $i', 'd': '2018-0$i-10', 'src': 'Википедия', 'u': 'https://ru.wikipedia.org/wiki/$i'},
    {
      't': 'Мировой рекорд в произвольной программе в 2019–2021 годах',
      'ev': 'GP Skate Canada 2019',
      'd': '2019-10-26',
      'pts': '166.62',
      'src': 'ISU',
      'u': 'https://www.isuresults.com/isujsstat/phswfs.htm',
    },
    {'t': '', 'ev': 'пустая строка не показывается'},
  ],
  'src': ['ISU', 'Википедии'],
  'at': '2026-11-05',
};

Schedule _data() => Schedule(
  const [],
  DateTime.utc(2026, 11, 5),
  true,
  false,
  people: const {
    'Minerva Fabienne Hase / Nikita Volodin': Person('Minerva Fabienne Hase / Nikita Volodin', 'GER', 'p', profile: _pairKey),
    'Аделия Петросян': Person('Аделия Петросян', 'AIN2', 'w', profile: _soloKey),
    'Александра Трусова': Person('Александра Трусова', 'RUS', 'w', profile: _starKey),
    'Иван Иванов': Person('Иван Иванов', 'RUS', 'm'),
  },
);

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  late Future<Profile?> Function(String) saved;
  setUp(() => saved = profileLoader);
  tearDown(() => profileLoader = saved);

  group('модель', () {
    test('профиль пары читается целиком', () {
      final p = Profile.fromJson(jsonDecode(jsonEncode(_pair)) as Map);
      expect(p.who.map((w) => w.name), ['Minerva Fabienne Hase', 'Nikita Volodin']);
      expect(p.who.first.height, 168);
      expect(p.who.first.since, 2004);
      expect(p.who.first.former, ['Nolan Seegert']);
      expect(p.who.last.former, isEmpty);
      expect(p.coach, ['Dmitri Savin', 'Knut Schubert']);
      expect(p.musicSeason, '2026/27');
      expect(p.best.first.seg, 'total');
      expect(p.titles.length, 8);
      expect(p.results.last.rows.last.place, 'WD');
      expect(p.results.last.rows.last.placeNumber, isNull);
      expect(p.results.first.rows.first.placeNumber, 3);
      expect(p.sources, ['ISU']);
      expect(p.checked, '2026-11-05');
      expect(p.dance, isFalse);
    });

    test('старты: два раздела — внутренние (национальные) и международные, новые первыми', () {
      final out = twoResultGroups(const [
        ProfileGroup('Гран-при', [ProfileResult('GP Rostelecom Cup 2020', 'm', '6')]),
        ProfileGroup('Юниорский Гран-при', [ProfileResult('JGP Cup of Austria 2017', 'm', '6')]),
        ProfileGroup('Челленджеры', [
          ProfileResult('CS Finlandia Trophy 2021', 'm', '5'),
          ProfileResult('CS 34th Nepela Memorial 2026', 'm', '1'),
        ]),
        ProfileGroup('Международные турниры', [ProfileResult('Minsk Arena Ice Star 2020', 'm', '3')]),
        ProfileGroup('Национальные чемпионаты', [
          ProfileResult('Чемпионат России 2024', 'm', '1'),
          ProfileResult('Чемпионат России 2026', 'm', '2'),
        ]),
      ]);
      expect(out.map((g) => g.name), ['Международные', 'Внутренние']);
      expect(out.first.rows.map((r) => r.event), [
        'CS 34th Nepela Memorial 2026',
        'CS Finlandia Trophy 2021',
        'GP Rostelecom Cup 2020', // при равном годе — как шло: сначала из «Гран-при»
        'Minsk Arena Ice Star 2020',
        'JGP Cup of Austria 2017',
      ]);
      expect(out.last.rows.map((r) => r.event), ['Чемпионат России 2026', 'Чемпионат России 2024']);
    });

    test('старты: только национальные — один раздел «Внутренние»', () {
      final out = twoResultGroups(const [
        ProfileGroup('Национальные чемпионаты', [ProfileResult('Чемпионат России 2026', 'w', '1')]),
      ]);
      expect(out.map((g) => g.name), ['Внутренние']);
      expect(twoResultGroups(const []), isEmpty);
    });

    test('старты: два раздела с сервера остаются как пришли', () {
      const fromServer = [
        ProfileGroup('Международные', [
          ProfileResult('CS 34th Nepela Memorial 2026', 'm', '1'),
          ProfileResult('GP Rostelecom Cup 2020', 'm', '6'),
          ProfileResult('Minsk Arena Ice Star 2020', 'm', '3'),
        ]),
        ProfileGroup('Внутренние', [ProfileResult('Чемпионат России 2026', 'm', '2')]),
      ];
      final out = twoResultGroups(fromServer);
      expect(out.map((g) => g.name), ['Международные', 'Внутренние']);
      expect(out.first.rows.map((r) => r.event), fromServer.first.rows.map((r) => r.event));
      expect(out.last.rows.map((r) => r.event), ['Чемпионат России 2026']);
    });

    test('пустое и чужое не роняет разбор', () {
      final p = Profile.fromJson({
        'n': 'X',
        'who': 'нет',
        'titles': [
          {'ev': 'A', 'pl': 'WD'},
          5,
        ],
        'music': [],
      });
      expect(p.who, isEmpty);
      expect(p.titles, isEmpty); // титул — только с местом числом
      expect(p.musicShort, isEmpty);
    });

    test('танцы: сегменты называются по-танцевальному', () {
      final p = Profile.fromJson({
        'n': 'A / B',
        'res': [
          {
            'g': 'Гран-при',
            'r': [
              {'ev': 'GP', 'k': 'd', 'pl': 1},
            ],
          },
        ],
      });
      expect(p.dance, isTrue);
      expect(segLabel('sp', dance: true), 'Ритм-танец');
      expect(segLabel('fs', dance: false), 'Произвольная программа');
    });
  });

  group('слова', () {
    test('дата, возраст, сезон, место с категорией', () {
      expect(profileDate('2007-06-05'), '5 июня 2007');
      expect(profileDate('июнь'), 'июнь');
      expect(ageOn('2007-06-05', DateTime(2026, 6, 4)), 18);
      expect(ageOn('2007-06-05', DateTime(2026, 6, 5)), 19);
      expect(ageOn('2007', DateTime(2026, 6, 5)), isNull); // год без даты — возраст не угадываем
      expect(seasonOfDate('2026-10-03'), '2026/27');
      expect(seasonOfDate('2026-03-26'), '2025/26');
      expect(splitPlace('8 (МС)'), (8, 'МС'));
      expect(splitPlace('1'), (1, ''));
      expect(splitPlace('сн.'), (null, 'сн.'));
      expect(yearsWord(21), '21 год');
      expect(yearsWord(19), '19 лет');
    });

    test('адрес профиля — рядом с данными', () {
      expect(profileUrl('abc'), 'https://xfurya.github.io/Starty/p/abc.json');
    });
  });

  group('лист', () {
    testWidgets('пара: титулы, первые шесть и «Ещё», справка по партнёру, музыка, результаты', (t) async {
      profileLoader = (k) async => k == _pairKey ? Profile.fromJson(_pair) : null;
      t.view.physicalSize = const Size(390 * 3, 6000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(ProfileSheet(name: 'Minerva Fabienne Hase / Nikita Volodin', data: _data())));
      await t.pumpAndSettle();
      expect(find.text('ТИТУЛЫ'), findsOneWidget);
      expect(find.text('Олимпийские игры 2026'), findsWidgets);
      // восемь титулов: шесть и «Ещё 2»
      expect(find.text('Чемпионат Германии 2025'), findsNothing);
      expect(find.text('Ещё 2'), findsOneWidget);
      await t.tap(find.text('Ещё 2'));
      await t.pumpAndSettle();
      expect(find.text('Чемпионат Германии 2025'), findsOneWidget);
      expect(find.text('Ещё 2'), findsNothing);
      expect(find.text('ЛИЧНЫЕ РЕКОРДЫ'), findsOneWidget);
      expect(find.text('228.33'), findsOneWidget);
      expect(find.text('ЛУЧШЕЕ В СЕЗОНЕ 2026/27'), findsOneWidget);
      expect(find.text('Minerva Fabienne Hase'), findsOneWidget); // имя партнёра над его справкой
      expect(find.text('168 см'), findsOneWidget);
      expect(find.text('Nolan Seegert'), findsOneWidget);
      expect(find.text('Тренеры'), findsOneWidget);
      expect(find.text('МУЗЫКА СЕЗОНА 2026/27'), findsOneWidget);
      expect(find.text('МЕЖДУНАРОДНЫЕ'), findsOneWidget); // Олимпиада — международный раздел
      expect(find.text('ВНУТРЕННИЕ'), findsOneWidget); // национальный чемпионат — внутренний
      expect(find.text('WD'), findsOneWidget);
      expect(find.text('По данным ISU на 5 ноября 2026'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('пара в сборной: строка одна на двоих, над справкой партнёров', (t) async {
      final pair = {
        ..._pair,
        'team': {'c': 'Япония', 't': 'особый состав', 'y': '2026/27'},
        'src': ['ISU', 'федерации Японии'],
      };
      profileLoader = (k) async => k == _pairKey ? Profile.fromJson(pair) : null;
      t.view.physicalSize = const Size(390 * 3, 6000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(ProfileSheet(name: 'Minerva Fabienne Hase / Nikita Volodin', data: _data())));
      await t.pumpAndSettle();
      expect(find.text('Сборная'), findsOneWidget);
      expect(find.text('Япония, особый состав'), findsOneWidget);
      expect(find.text('Сезон 2026/27'), findsOneWidget);
      // над подзаголовком первого партнёра — чтобы не читалась как строка второго
      expect(t.getTopLeft(find.text('Сборная')).dy, lessThan(t.getTopLeft(find.text('Minerva Fabienne Hase').last).dy));
      expect(find.text('Сборная'), findsOneWidget);
      expect(find.text('По данным ISU и федерации Японии на 5\u00a0ноября 2026'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('сборной нет или строка неполная — строки нет', (t) async {
      for (final team in [null, {'c': 'Япония', 'y': '2026/27'}, 'основной состав']) {
        final pr = Profile.fromJson({..._solo, 'team': team});
        expect(pr.team, isNull);
      }
      expect(const ProfileTeam('Канада', 'резерв NextGen', '').line, 'Канада, резерв NextGen');
      expect(const ProfileTeam('Канада', 'резерв NextGen', '').note, '');
      expect(const ProfileTeam('Канада', 'резерв NextGen', '2026/27').note, 'Сезон 2026/27');
      profileLoader = (k) async => k == _soloKey ? Profile.fromJson({..._solo}..remove('team')) : null;
      t.view.physicalSize = const Size(390 * 3, 3000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(ProfileSheet(name: 'Аделия Петросян', data: _data())));
      await t.pumpAndSettle();
      expect(find.text('Звание'), findsOneWidget);
      expect(find.text('Сборная'), findsNothing);
    });

    testWidgets('одиночница: возраст и звание в шапке, старты сезона по картотеке', (t) async {
      profileLoader = (k) async => k == _soloKey ? Profile.fromJson(_solo) : null;
      t.view.physicalSize = const Size(390 * 3, 3000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(ProfileSheet(name: 'Аделия Петросян', data: _data())));
      await t.pumpAndSettle();
      final age = ageOn('2007-06-05', now())!;
      expect(find.text(yearsWord(age)), findsOneWidget);
      expect(find.text('СТАРТЫ СЕЗОНА 2025/26'), findsOneWidget);
      expect(find.text('категория МС'), findsOneWidget);
      expect(find.text('Тренер'), findsOneWidget);
      expect(find.text('Звание'), findsOneWidget);
      expect(find.text('Сборная'), findsOneWidget);
      expect(find.text('Россия, основной состав'), findsOneWidget);
      expect(find.text('Сезон 2026/27'), findsOneWidget);
      // сборная — сразу под званием
      expect(t.getTopLeft(find.text('Сборная')).dy, greaterThan(t.getTopLeft(find.text('Звание')).dy));
      expect(t.getTopLeft(find.text('Сборная')).dy, lessThan(t.getTopLeft(find.text('Регион')).dy));
      expect(find.text('ТИТУЛЫ'), findsNothing); // нет пьедесталов — нет и раздела
      expect(find.text('По данным ISU и ФФККР на 5 ноября 2026'), findsOneWidget);
    });

    testWidgets('примечательное: первые шесть и «Ещё», баллы у рекорда, строка ведёт к источнику', (t) async {
      profileLoader = (k) async => k == _starKey ? Profile.fromJson(_star()) : null;
      t.view.physicalSize = const Size(390 * 3, 3000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(ProfileSheet(name: 'Александра Трусова', data: _data())));
      await t.pumpAndSettle();
      expect(find.text('ПРИМЕЧАТЕЛЬНОЕ'), findsOneWidget);
      expect(find.text('Первое №1'), findsOneWidget);
      expect(find.text('Турнир 1'), findsOneWidget);
      expect(find.text('10\u00a0января 2018'), findsOneWidget);
      expect(find.text('Первое №7'), findsNothing);
      expect(find.text('пустая строка не показывается'), findsNothing);
      await t.tap(find.text('Ещё 2'));
      await t.pumpAndSettle();
      expect(find.text('Первое №7'), findsOneWidget);
      expect(find.text('Мировой рекорд в произвольной программе в 2019–2021 годах'), findsOneWidget);
      expect(find.text('166.62'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.arrow_up_right), findsNWidgets(8));
      bool hint(Widget w, String h) => w is Semantics && w.properties.button == true && w.properties.hint == h;
      expect(find.byWidgetPredicate((w) => hint(w, 'Открыть источник: ISU')), findsOneWidget);
      expect(find.byWidgetPredicate((w) => hint(w, 'Открыть источник: Википедия')), findsNWidgets(7));
      expect(find.text('По данным ISU и Википедии на 5\u00a0ноября 2026'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('рекорды российских стартов: первыми, если выше международных, и в «Примечательном»', (t) async {
      final pr = {
        ..._solo,
        'pb': [
          {'s': 'total', 'pts': '214.53', 'd': '2026-02-19', 'ev': 'Олимпийские игры 2026'},
        ],
        'pbru': [
          {'s': 'total', 'pts': '262.92', 'd': '2024-12-21', 'ev': 'Чемпионат России', 'src': 'ФФККР'},
          {'s': 'sp', 'pts': '86.52', 'd': '2025-12-19', 'ev': 'Чемпионат России', 'src': 'ФФККР'},
        ],
        'pbru_from': '2018/19',
        'feats': [
          {'t': 'Лучшая сумма на российских стартах — выше рекорда ISU', 'ev': 'Чемпионат России', 'd': '2024-12-21', 'pts': '262.92', 'src': 'ФФККР'},
        ],
      };
      profileLoader = (k) async => k == _soloKey ? Profile.fromJson(pr) : null;
      t.view.physicalSize = const Size(390 * 3, 4000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(ProfileSheet(name: 'Аделия Петросян', data: _data())));
      await t.pumpAndSettle();
      expect(find.text('Лучшая сумма на российских стартах — выше рекорда ISU'), findsOneWidget);
      expect(find.text('262.92'), findsNWidgets(2)); // в «Примечательном» и в рекордах
      final ru = find.text('ЛИЧНЫЕ РЕКОРДЫ НА РОССИЙСКИХ СТАРТАХ');
      final isu = find.text('ЛИЧНЫЕ РЕКОРДЫ ISU');
      expect(ru, findsOneWidget);
      expect(isu, findsOneWidget);
      expect(t.getTopLeft(ru).dy, lessThan(t.getTopLeft(isu).dy));
      expect(find.text('По протоколам с сезона 2018/19'), findsOneWidget);
      expect(find.text('214.53'), findsOneWidget);
      // строка без адреса — без стрелки «к источнику» и без нажатия
      expect(find.byIcon(CupertinoIcons.arrow_up_right), findsNothing);
      expect(t.takeException(), isNull);
    });

    test('блоки рекордов: один — просто «Личные рекорды», выше международный — он первый', () {
      ProfileScore tot(String pts) => ProfileScore('total', pts, '', '');
      expect(recordBlocks(Profile(name: 'X', best: [tot('200.00')])).map((b) => b.$1), ['Личные рекорды']);
      expect(recordBlocks(Profile(name: 'X', bestRu: [tot('200.00')])).map((b) => b.$1), ['Личные рекорды на российских стартах']);
      expect(recordBlocks(Profile(name: 'X', best: [tot('240.00')], bestRu: [tot('230.00')])).map((b) => b.$1), [
        'Личные рекорды ISU',
        'Личные рекорды на российских стартах',
      ]);
      expect(recordBlocks(const Profile(name: 'X')), isEmpty);
    });

    testWidgets('файла нет — так и сказано', (t) async {
      profileLoader = (k) async => null;
      await t.pumpWidget(_app(ProfileSheet(name: 'Аделия Петросян', data: _data())));
      await t.pumpAndSettle();
      expect(find.text('Справки о спортсмене пока нет'), findsOneWidget);
    });

    testWidgets('у сборщика справки нет — не грузим и не ждём', (t) async {
      var asked = 0;
      profileLoader = (k) async {
        asked++;
        return null;
      };
      await t.pumpWidget(_app(ProfileSheet(name: 'Иван Иванов', data: _data())));
      await t.pump();
      expect(asked, 0);
      expect(find.text('Справки о спортсмене пока нет'), findsOneWidget);
      expect(find.text('Загружаю справку'), findsNothing);
    });

    testWidgets('нет связи — честно и с повтором', (t) async {
      var calls = 0;
      profileLoader = (k) async {
        calls++;
        if (calls == 1) throw http.ClientException('нет сети');
        return Profile.fromJson(_solo);
      };
      await t.pumpWidget(_app(ProfileSheet(name: 'Аделия Петросян', data: _data())));
      await t.pumpAndSettle();
      expect(find.text('Справка не загрузилась: нет связи с сервером'), findsOneWidget);
      await t.tap(find.text('Повторить'));
      await t.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('Справка не загрузилась: нет связи с сервером'), findsNothing);
      expect(find.text('СТАРТЫ СЕЗОНА 2025/26'), findsOneWidget);
    });
  });

  group('нажатие', () {
    testWidgets('строка открывает профиль, если человек есть в справочнике', (t) async {
      profileLoader = (k) async => Profile.fromJson(_solo);
      await t.pumpWidget(
        _app(
          Column(
            children: [
              ProfileTap(name: 'Аделия Петросян', data: _data(), child: const Text('строка А')),
              ProfileTap(name: 'Неизвестный Человек', data: _data(), child: const Text('строка Б')),
            ],
          ),
        ),
      );
      // незнакомому — ни кнопки, ни пустого нажатия
      expect(find.ancestor(of: find.text('строка Б'), matching: find.byType(InkWell)), findsNothing);
      await t.tap(find.text('строка А'));
      await t.pumpAndSettle();
      expect(find.byType(ProfileSheet), findsOneWidget);
    });

    test('имя ищется и в другом написании', () {
      final d = _data();
      expect(d.personOf('аделия петросян')?.profile, _soloKey);
      expect(hasProfile(d, 'Аделия Петросян'), isTrue);
      expect(hasProfile(null, 'Аделия Петросян'), isFalse);
    });
  });

  group('отслеживать из профиля', () {
    test('нажатие добавляет и убирает; у пары — вместе с партнёром, по которому она считалась', () {
      final f = Follow(['Аделия Петросян', 'Nikita Volodin']);
      expect(followToggled(f, 'Иван Иванов'), {'Аделия Петросян', 'Nikita Volodin', 'Иван Иванов'});
      // написание в списке и в справочнике может разойтись регистром и «ё»
      expect(followToggled(Follow(['аделия петросян']), 'Аделия Петросян'), isEmpty);
      // пара отслеживается по партнёру — снять отметку значит убрать его
      expect(f.has('Minerva Fabienne Hase / Nikita Volodin'), isTrue);
      expect(followToggled(f, 'Minerva Fabienne Hase / Nikita Volodin'), {'Аделия Петросян'});
    });

    testWidgets('пара — «Отслеживаются»: их двое', (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.init();
      final s = AppState()
        ..data = _data()
        ..loading = false;
      await t.pumpWidget(_app(FollowPill(state: s, name: 'Minerva Fabienne Hase / Nikita Volodin')));
      await t.tap(find.text('Отслеживать'));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('Отслеживаются'), findsOneWidget);
      expect(find.text('Отслеживается'), findsNothing);
      await t.pump(const Duration(seconds: 11));
    });

    testWidgets('кнопка в шапке: нажали — отслеживается, ещё раз — снова нет', (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.init();
      final s = AppState()
        ..data = _data()
        ..loading = false;
      profileState = s;
      addTearDown(() => profileState = null);
      profileLoader = (k) async => Profile.fromJson(_solo);
      await t.pumpWidget(_app(ProfileSheet(name: 'аделия петросян', data: _data())));
      await t.pumpAndSettle();
      expect(find.text('Отслеживать'), findsOneWidget);
      await t.tap(find.text('Отслеживать'));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('Отслеживается'), findsOneWidget);
      // в список идёт имя из справочника, а не то, как его написали при открытии
      expect(s.follow.names, {'Аделия Петросян'});
      await t.tap(find.text('Отслеживается'));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('Отслеживать'), findsOneWidget);
      expect(s.follow.names, isEmpty);
      // сохранение ждёт настройки уведомлений до 10 с
      await t.pump(const Duration(seconds: 11));
      expect(t.takeException(), isNull);
    });

    testWidgets('без приложения и у человека не из справочника кнопки нет', (t) async {
      profileLoader = (k) async => null;
      await t.pumpWidget(_app(ProfileSheet(name: 'Аделия Петросян', data: _data())));
      await t.pumpAndSettle();
      expect(find.byType(FollowPill), findsNothing);

      SharedPreferences.setMockInitialValues({});
      await Prefs.init();
      profileState = AppState();
      addTearDown(() => profileState = null);
      await t.pumpWidget(_app(ProfileSheet(key: UniqueKey(), name: 'Неизвестный Человек', data: _data())));
      await t.pumpAndSettle();
      expect(find.byType(FollowPill), findsNothing);
    });
  });

  group('ближайшие старты', () {
    Map<String, dynamic> ev(String id, String tid, String tour, String seg, int inHours, List<String> names) {
      final t0 = DateTime.now().add(Duration(hours: inHours));
      return {
        'id': id, 'tid': tid, 'tournament': tour, 'kind': 'women', 'level': 'senior', 'seg': seg,
        'title': '$tour — женщины $seg', 'start': t0.toUtc().toIso8601String(),
        'end': t0.add(const Duration(hours: 2)).toUtc().toIso8601String(), 'venue': '', 'intl': false, 'ours': [],
        'athletes': names,
      };
    }

    String day(int inDays) => DateTime.now().add(Duration(days: inDays)).toUtc().toIso8601String().split('T').first;

    Schedule sched() => Schedule.parse(
      jsonEncode({
        'generated': DateTime.now().toUtc().toIso8601String(),
        'events': [
          ev('pp', 't1', 'Гран-при, этап 3', 'ПП', 72, ['Аделия Петросян', 'Анна Фролова']),
          ev('kp', 't1', 'Гран-при, этап 3', 'КП', 48, ['Анна Фролова', 'Аделия Петросян']),
          ev('was', 't0', 'Гран-при, этап 2', 'КП', -48, ['Аделия Петросян']),
          ev('other', 't2', 'Чужой турнир', 'КП', 50, ['Анна Фролова']),
        ],
        'upcoming': [
          // у этого турнира старты уже названы — второй раз строкой не идёт
          {'tid': 't1', 'name': 'Гран-при, этап 3', 'start': day(2), 'end': day(4), 'athletes': ['Аделия Петросян']},
          {'tid': 't3', 'name': 'Турнир без расписания', 'start': day(40), 'end': day(44), 'athletes': ['Аделия Петросян']},
          {'tid': 't4', 'name': 'Без неё', 'start': day(50), 'end': day(52), 'athletes': ['Анна Фролова']},
        ],
        'people': [
          {'n': 'Аделия Петросян', 'c': 'RUS', 'k': 'w', 'p': _soloKey},
          {'n': 'Мария Никто', 'c': 'RUS', 'k': 'w'},
        ],
      }),
    );

    test('по времени, без прошедших и чужих; турнир без расписания — отдельно и один раз', () {
      final a = aheadOf(sched(), 'Аделия Петросян', DateTime.now());
      expect(a.starts.map((s) => s.id), ['kp', 'pp']);
      expect(a.tours.map((u) => u.name), ['Турнир без расписания']);
      final none = aheadOf(sched(), 'Мария Никто', DateTime.now());
      expect(none.starts, isEmpty);
      expect(none.tours, isEmpty);
    });

    testWidgets('раздел в профиле: когда, турнир, вид и программа; нигде не заявлен — раздела нет', (t) async {
      profileLoader = (k) async => Profile.fromJson(_solo);
      await t.pumpWidget(_app(ProfileSheet(name: 'Аделия Петросян', data: sched())));
      await t.pumpAndSettle();
      expect(find.text('БЛИЖАЙШИЕ СТАРТЫ'), findsOneWidget);
      expect(find.text('Гран-при, этап 3'), findsNWidgets(2));
      expect(find.text('Женщины, короткая программа'), findsOneWidget);
      expect(find.text('Женщины, произвольная программа'), findsOneWidget);
      expect(find.text('Турнир без расписания'), findsOneWidget);
      expect(find.text('Расписания пока нет'), findsOneWidget);
      expect(find.text('Чужой турнир'), findsNothing);
      // без приложения карточку старта открыть нечем — строка без пустого нажатия
      expect(find.ancestor(of: find.text('Женщины, короткая программа'), matching: find.byType(InkWell)), findsNothing);

      await t.pumpWidget(_app(ProfileSheet(key: UniqueKey(), name: 'Мария Никто', data: sched())));
      await t.pumpAndSettle();
      expect(find.text('БЛИЖАЙШИЕ СТАРТЫ'), findsNothing);
    });

    testWidgets('в приложении строка старта открывает его карточку, турнир без расписания — нет', (t) async {
      t.view.physicalSize = const Size(390 * 3, 844 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      SharedPreferences.setMockInitialValues({});
      await Prefs.init();
      final d = sched();
      profileState = AppState()
        ..data = d
        ..loading = false;
      addTearDown(() => profileState = null);
      profileLoader = (k) async => Profile.fromJson(_solo);
      await t.pumpWidget(_app(ProfileSheet(name: 'Аделия Петросян', data: d)));
      await t.pumpAndSettle();
      expect(find.byType(SwipeSurface), findsNothing);
      expect(find.ancestor(of: find.text('Расписания пока нет'), matching: find.byType(InkWell)), findsNothing);
      await t.tap(find.text('Женщины, короткая программа'));
      await t.pumpAndSettle();
      // карточка старта — лист поверх профиля, из приложения не выходим
      expect(find.byType(SwipeSurface), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    for (final b in Brightness.values) {
      testWidgets('узкий экран, крупный шрифт, $b — без переполнений', (t) async {
        t.view.physicalSize = const Size(320 * 3, 640 * 3);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        profileLoader = (k) async => Profile.fromJson(_solo);
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: b, fontFamily: 'Golos Text'),
            builder: (c, nav) => MediaQuery(
              data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: nav!,
            ),
            home: Scaffold(body: ProfileSheet(name: 'Аделия Петросян', data: sched())),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('БЛИЖАЙШИЕ СТАРТЫ'), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
  });
}
