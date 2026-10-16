// Флаги стран: какие коды с флагом, какие — только кодом; файлы на месте во всех разрешениях;
// экраны с флагами укладываются в 360/390/430 при шрифте 100 % и 130 % в обеих темах.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/flags.dart';
import 'package:starty/protocol_repo.dart';
import 'package:starty/protocol_screen.dart';
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

Widget _app(Widget child, {Brightness b = Brightness.light, double scale = 1}) => MaterialApp(
  key: UniqueKey(),
  theme: ThemeData(brightness: b, fontFamily: 'Manrope'),
  builder: (c, nav) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: nav!),
  home: Scaffold(body: child),
);

/// Протокол с международным составом: страны у строк сегмента, итога и заявки.
Map<String, dynamic> _protocol() {
  final j = jsonDecode(File('test/protocol/sample.json').readAsStringSync()) as Map<String, dynamic>;
  final cat = (j['categories'] as List).first as Map<String, dynamic>;
  final seg = (cat['segments'] as List).first as Map<String, dynamic>;
  final rows = seg['rows'] as List;
  const nations = ['AIN2', 'GER', 'SUI', 'МОС'];
  for (var i = 0; i < rows.length; i++) {
    (rows[i] as Map<String, dynamic>)['nation'] = nations[i % nations.length];
  }
  seg['panel'] = [
    {'no': 'J1', 'name': 'Мария ПЕТРОВА', 'nation': 'NED'},
    {'no': 'J2', 'name': 'Jean DUPONT', 'nation': 'FRA'},
  ];
  cat['total'] = {
    'state': 'final',
    'complete': true,
    'cols': ['RD', 'FD'],
    'colsKind': 'places',
    'skipped': 0,
    'rows': [
      for (var i = 0; i < 5; i++)
        {
          'i': i + 1,
          'place': i < 4 ? i + 1 : null,
          if (i == 4) 'status': 'WD',
          'name': 'Елизавета Андреевна ЛЕБЕДЕВА-ПЕТРОСЯН / Александр ВОЛКОВ $i',
          'nation': ['AIN2', 'GER', 'GBR', 'TPE', 'USA'][i],
          'points': i < 4 ? '${150 - i * 7}.63' : null,
          'parts': i < 4 ? ['${i + 1}', '${i + 2}'] : ['7', null],
        },
    ],
  };
  return j;
}

Start _start({List<Map<String, dynamic>> field = const [], String proto = 'p.json'}) => Start.fromJson({
  'id': 'ffkm:2026-08-24_pm:dance-junior-rt',
  'tid': 'ffkm:2026-08-24_pm',
  'tournament': 'Первенство Москвы',
  'kind': 'dance',
  'level': 'junior',
  'seg': 'РТ',
  'title': 'Первенство Москвы — танцы РТ',
  'venue': 'ЛД «Мечта», Москва',
  'src': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/index.htm',
  'start': '2026-08-24T15:00:00+03:00',
  'end': '2026-08-24T18:35:00+03:00',
  'proto': proto,
  'field': field,
});

/// Протокола сегмента ещё нет: экран показывает состав по заявке.
Map<String, dynamic> _unpublished() {
  final j = _protocol();
  final seg = (((j['categories'] as List).first as Map)['segments'] as List).first as Map<String, dynamic>;
  seg['state'] = 'not_published';
  seg['rows'] = [];
  return j;
}

ProtocolRepo _repo(Object body) => ProtocolRepo(
  now: () => DateTime.utc(2026, 10, 15, 19),
  client: MockClient((r) async {
    if (body is int) return http.Response('', body);
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  }),
);

void main() {
  setUpAll(() async {
    await _font('Manrope', ['Manrope-Regular.ttf', 'Manrope-Medium.ttf', 'Manrope-SemiBold.ttf', 'Manrope-Bold.ttf']);
    await _font('Cormorant', ['CormorantGaramond-SemiBold.ttf', 'CormorantGaramond-Bold.ttf']);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
  });

  test('флаг у известных кодов ISU: коды IOC переводятся в ISO', () {
    expect(flagAsset('RUS'), 'assets/flags/ru.png');
    expect(flagAsset('GER'), 'assets/flags/de.png');
    expect(flagAsset('SUI'), 'assets/flags/ch.png');
    expect(flagAsset('NED'), 'assets/flags/nl.png');
    expect(flagAsset('GBR'), 'assets/flags/gb.png');
    expect(flagAsset(' usa '), 'assets/flags/us.png');
  });

  test('нейтральные коды: AIN2 — Россия, AIN1 — Беларусь', () {
    expect(flagAsset('AIN2'), 'assets/flags/ru.png');
    expect(flagAsset('ain2'), 'assets/flags/ru.png');
    expect(flagAsset('AIN1'), 'assets/flags/by.png');
    expect(NationTag.spoken('AIN2'), 'Россия');
  });

  test('флага нет: регионы, простой AIN, Китайский Тайбэй, незнакомые коды', () {
    for (final c in ['МОС', 'СПБ', 'AIN', 'TPE', 'XYZ', '']) {
      expect(flagAsset(c), isNull, reason: c);
    }
  });

  test('у каждого флага есть файлы 1x, 2x и 3x', () {
    for (final iso in flagIso.values.toSet()) {
      for (final dir in ['', '2.0x/', '3.0x/']) {
        expect(File('assets/flags/$dir$iso.png').existsSync(), isTrue, reason: '$dir$iso');
      }
    }
    expect(File('assets/flags/LICENSE-flag-icons.txt').existsSync(), isTrue);
  });

  testWidgets('метка страны: флаг и код; без флага — только код, без пустого прямоугольника', (t) async {
    await t.pumpWidget(
      _app(
        const Column(
          children: [
            NationTag('AIN2', style: TextStyle(fontSize: 12)),
            NationTag('МОС', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
    final flags = t.widgetList<Flag>(find.byType(Flag)).toList();
    expect(flags, hasLength(1));
    expect(flags.single.asset, 'assets/flags/ru.png');
    expect(find.textContaining('RUS', findRichText: true), findsOneWidget);
    expect(find.textContaining('AIN2', findRichText: true), findsNothing);
    expect(find.textContaining('МОС', findRichText: true), findsOneWidget);
    // флаг 3:2, высота — от кегля кода
    final size = t.getSize(find.byType(Flag));
    expect(size.width / size.height, closeTo(1.5, .01));
    expect(size.height, closeTo(12 * 1.05, .01));
  });

  for (final width in [360.0, 390.0, 430.0]) {
    for (final b in Brightness.values) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('протокол со странами — ${width.toInt()} px, $b, шрифт $scale', (t) async {
          t.view.physicalSize = Size(width * 3, 900 * 3);
          t.view.devicePixelRatio = 3;
          addTearDown(t.view.reset);
          // сегмент: строки с флагами и судьи
          await t.pumpWidget(_app(ProtocolScreen(start: _start(), repo: _repo(_protocol()), opener: (_) async {}), b: b, scale: scale));
          await t.pumpAndSettle();
          expect(find.byType(Flag), findsWidgets);
          await t.ensureVisible(find.text('Судьи'));
          await t.tap(find.text('Судьи'));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          // итог: статус меткой, флаги, места по сегментам
          await t.tap(find.text('Итог'));
          await t.pumpAndSettle();
          expect(find.text('снят'), findsOneWidget);
          expect(t.takeException(), isNull);
          // заявка: протокола нет, состав со странами
          await t.pumpWidget(
            _app(
              ProtocolScreen(
                start: _start(
                  field: [
                    {'name': 'Анна Билибина / Дмитрий Кашаев', 'time': '15:00', 'nation': 'AIN2'},
                    {'name': 'Charlène Guignard / Marco Fabbri', 'time': '15:07', 'nation': 'ITA'},
                  ],
                  proto: 'e.json',
                ),
                repo: _repo(_unpublished()),
                opener: (_) async {},
              ),
              b: b,
              scale: scale,
            ),
          );
          await t.pumpAndSettle();
          expect(find.text('СОСТАВ ПО ЗАЯВКЕ'), findsOneWidget);
          expect(find.byType(Flag), findsNWidgets(2));
          expect(t.takeException(), isNull);
        });

        testWidgets('лента и карточки с флагами — ${width.toInt()} px, $b, шрифт $scale', (t) async {
          t.view.physicalSize = Size(width * 3, 900 * 3);
          t.view.devicePixelRatio = 3;
          addTearDown(t.view.reset);
          final data = Schedule.parse(File('test/podium_sample.json').readAsStringSync());
          final s = AppState()
            ..data = data
            ..loading = false;
          final intl = data.starts.where((x) => x.intl && x.podium.isNotEmpty).take(2);
          expect(intl, isNotEmpty);
          for (final st in intl) {
            await t.pumpWidget(_app(SingleChildScrollView(child: PastTile(start: st, state: s)), b: b, scale: scale));
            await t.pump();
            expect(find.byType(Flag), findsWidgets, reason: st.title);
            expect(t.takeException(), isNull);
            await t.pumpWidget(
              _app(
                Builder(
                  builder: (c) => Center(child: TextButton(onPressed: () => showStart(c, st, s), child: const Text('open'))),
                ),
                b: b,
                scale: scale,
              ),
            );
            await t.tap(find.text('open'));
            await t.pumpAndSettle();
            expect(find.byType(Flag), findsWidgets);
            expect(t.takeException(), isNull, reason: st.title);
          }
        });
      }
    }
  }
}
