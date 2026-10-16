// Экран протокола: состояния из утверждённых макетов, ширины 360/390/430, масштаб текста 1.0 и 1.3,
// светлая и тёмная темы; горизонтальной прокрутки и переполнений нет.
// Шрифты — настоящие (Manrope, Cormorant), как в views_test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/live.dart' show LiveOk;
import 'package:starty/state.dart';
import 'package:starty/protocol_details.dart' show deductionName;
import 'package:starty/protocol_model.dart';
import 'package:starty/protocol_repo.dart';
import 'package:starty/protocol_screen.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync())));
  }
  await l.load();
}

const _pair = 'Анна Павловна Билибина / Дмитрий Владимирович Кашаев';

final _now = DateTime.utc(2026, 10, 15, 19, 0); // 22:00 по Москве

Map<String, dynamic> sample() => jsonDecode(File('test/protocol/sample.json').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _seg(Map<String, dynamic> j) => ((j['categories'] as List).first as Map)['segments'].first as Map<String, dynamic>;

/// Файл с расширенным контрактом: элементы, компоненты, сбавки, оценки судей (с пропуском — null).
Map<String, dynamic> withDetails() {
  final j = sample();
  final r = (_seg(j)['rows'] as List).first as Map<String, dynamic>;
  r['bv'] = 20.30;
  r['start'] = 6;
  r['els'] = [
    {'no': 1, 'n': '3Lz+3T', 'info': '<', 'b': 10.10, 'x': true, 'g': 1.21, 'j': [1, 2, null, 1, 0], 's': 11.31},
    {'no': 2, 'n': 'FCSp4', 'b': 3.20, 'g': -0.40, 'j': [0, -1, -1, 0, 0], 's': 2.80},
  ];
  r['comp'] = [
    {'n': 'Композиция', 'f': 1.33, 'j': [8.25, 8.0, 8.5], 's': 8.36},
  ];
  r['deds'] = [
    {'n': 'Падения', 'v': -1.0},
  ];
  r['ded'] = '-1.00';
  return j;
}

/// Категории файла с длинными названиями элементов и компонентов: худший случай для узкой ширины.
List<dynamic> _longNames(Map<String, dynamic> j) {
  final r = (_seg(j)['rows'] as List).first as Map<String, dynamic>;
  (r['els'] as List).add({'no': 3, 'n': 'FCCoSp4+kombinatsiya', 'info': '< e !', 'b': 100.10, 'x': true, 'g': -12.34, 'j': List.filled(9, 5), 's': 99.99});
  (r['comp'] as List).add({'n': 'Исполнение и интерпретация музыки', 'f': 1.33, 'j': List.filled(9, 8.25), 's': 8.36});
  return j['categories'] as List;
}

/// Файл с итогом вида: латинские подписи колонок и участники без места (статусы из файла).
Map<String, dynamic> withTotal({List<String> cols = const ['SP', 'FS'], String state = 'final', List<String> statuses = const ['WD', 'NQD', 'DQ']}) {
  final j = sample();
  ((j['categories'] as List).first as Map<String, dynamic>)['total'] = {
    'state': state,
    'complete': true,
    'cols': cols,
    'colsKind': 'places',
    'skipped': 0,
    'rows': [
      {
        'i': 1,
        'place': 1,
        'name': 'Анна Павловна БИЛИБИНА / Дмитрий Владимирович КАШАЕВ',
        'nation': '',
        'points': '151.63',
        'parts': [for (var k = 0; k < cols.length; k++) '${k + 1}'],
      },
      for (var k = 0; k < statuses.length; k++)
        {
          'i': k + 2,
          'place': null,
          'status': statuses[k],
          'name': 'Елизавета Андреевна ЛЕБЕДЕВА-ПЕТРОСЯН / Александр ВОЛКОВ ${k + 1}',
          'nation': '',
          'points': null,
          'parts': [for (var c = 0; c < cols.length; c++) null],
        },
    ],
  };
  return j;
}

/// Файл с другим состоянием ритм-танца; [basis] — только для окончательного.
Map<String, dynamic> withState(String state, {String? basis = 'judges'}) {
  final j = sample();
  _seg(j)['state'] = state;
  _seg(j)['basis'] = state == 'final' ? basis : null;
  return j;
}

/// Старт ФФКМ: в расписании есть proto и (если нужно) состав по заявке и отслеживаемые.
Start start({List<String> field = const [], List<String> ours = const [], String? proto = 'ffkm_2026-08-24_pm.json'}) =>
    Start.fromJson({
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
      'field': [for (final n in field) {'name': n, 'time': '15:00'}],
      'ours': [for (final n in ours) {'name': n, 'time': '15:00'}],
    });

/// Клиент: сначала [first], потом [then] (или сеть падает, если [then] == null).
ProtocolRepo repoWith(Object? first, {Object? then}) {
  var n = 0;
  return ProtocolRepo(
    now: () => _now,
    client: MockClient((r) async {
      final body = n++ == 0 ? first : then;
      if (body == null) throw const _NetDown();
      if (body == 'timeout') throw TimeoutException('15 секунд');
      if (body is int) return http.Response('', body); // код ответа без тела: 404, 500
      if (body is String) return http.Response.bytes(utf8.encode(body), 200); // сырое тело: пустое, не JSON
      if (body is! Map) throw StateError('нет фикстуры');
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }),
  );
}

class _NetDown implements Exception {
  const _NetDown();
}

Future<void> pumpScreen(
  WidgetTester tester, {
  required Start s,
  required ProtocolRepo repo,
  double width = 390,
  double scale = 1.0,
  Brightness brightness = Brightness.light,
  List<String>? opened,
  AppState? state,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness, fontFamily: 'Manrope'),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: ProtocolScreen(
        start: s,
        repo: repo,
        state: state,
        opener: (url) async => opened?.add(url),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Ни одна прокрутка не идёт по горизонтали; переполнений разметки нет.
void expectNoHorizontalScroll(WidgetTester tester) {
  for (final s in tester.widgetList<Scrollable>(find.byType(Scrollable))) {
    expect(s.axisDirection, isNot(AxisDirection.left), reason: 'горизонтальная прокрутка');
    expect(s.axisDirection, isNot(AxisDirection.right), reason: 'горизонтальная прокрутка');
  }
  expect(tester.takeException(), isNull, reason: 'переполнение разметки или исключение при отрисовке');
}

void main() {
  setUpAll(() async {
    await _font('Manrope', ['Manrope-Light.ttf', 'Manrope-Regular.ttf', 'Manrope-Medium.ttf', 'Manrope-SemiBold.ttf', 'Manrope-Bold.ttf']);
    await _font('Cormorant', ['CormorantGaramond-SemiBold.ttf', 'CormorantGaramond-Bold.ttf']);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
  });

  group('статусы из макетов', () {
    testWidgets('окончательный — строки с местами и баллами, значок «Оригинал протокола» вместо кнопки', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(sample()));
      expect(find.text('Окончательный'), findsOneWidget);
      expect(find.text('Анна Павловна Билибина / Дмитрий Владимирович Кашаев'), findsOneWidget);
      expect(find.text('66.36'), findsOneWidget);
      expect(find.byTooltip('Оригинал протокола'), findsOneWidget);
      expect(find.text('Оригинал протокола'), findsNothing); // большой кнопки внизу нет
      // шапки, дублирующей выбор, нет
      expect(find.text('рит-танец'), findsNothing);
      expect(find.text('Танцы · Юниоры'), findsNothing);
      expectNoHorizontalScroll(tester);
    });

    testWidgets('значок «Оригинал протокола» открывает страницу сегмента', (tester) async {
      final opened = <String>[];
      await pumpScreen(tester, s: start(), repo: repoWith(sample()), opened: opened);
      await tester.tap(find.byTooltip('Оригинал протокола'));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
    });

    testWidgets('идёт — «Идёт» и время обновления файла по Москве, слова «промежуточный» нет', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withState('in_progress')));
      expect(find.text('Идёт · Обновлено 21:56'), findsOneWidget);
      expect(find.textContaining('ромежуточ'), findsNothing);
      expectNoHorizontalScroll(tester);
    });

    testWidgets('идёт при известном составе — «N из M»', (tester) async {
      final field = ['Анна Билибина / Дмитрий Кашаев', 'Полина Жарова / Алексей Столяров', 'Третья Пара / Партнёр', 'Четвёртая Пара / Партнёр', 'Пятая Пара / Партнёр'];
      await pumpScreen(tester, s: start(field: field), repo: repoWith(withState('in_progress')));
      final n = ((_seg(withState('in_progress'))['rows']) as List).length;
      expect(find.text('Идёт · $n из 5 · Обновлено 21:56'), findsOneWidget);
    });

    testWidgets('сегмент прошёл, оценок нет — без пометки статуса, только время обновления', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withState('provisional', basis: null)));
      expect(find.text('Обновлено 21:56'), findsOneWidget);
      expect(find.textContaining('ромежуточ'), findsNothing);
    });

    testWidgets('протокола нет, есть заявка — состав по заявке без мест', (tester) async {
      await pumpScreen(
        tester,
        s: start(field: ['Анна Билибина / Дмитрий Кашаев', 'Полина Жарова / Алексей Столяров'], ours: ['Анна Билибина / Дмитрий Кашаев']),
        repo: repoWith(withState('not_published')),
      );
      expect(find.text('Протокола пока нет · состав по заявке'), findsOneWidget);
      expect(find.text('Полина Жарова / Алексей Столяров'), findsOneWidget);
      expect(find.textContaining('отслеживаем'), findsNothing); // отслеживаемые только выделены, без слов
      expectNoHorizontalScroll(tester);
    });

    testWidgets('в файле строк нет, на табло есть — строки с табло и подпись «По табло»', (tester) async {
      final state = AppState()
        ..adoptLive(
          start().id,
          LiveOk(
            podium: [Placing(1, 'Анна Билибина / Дмитрий Кашаев', 'RUS', '70.10')],
            provisional: true,
            rows: [
              Placing(1, 'Анна Билибина / Дмитрий Кашаев', 'RUS', '70.10'),
              Placing(2, 'Полина Жарова / Алексей Столяров', 'RUS', '65.00'),
            ],
          ),
        );
      await pumpScreen(
        tester,
        s: start(field: ['Анна Билибина / Дмитрий Кашаев', 'Полина Жарова / Алексей Столяров', 'Третья Пара / Партнёр']),
        repo: repoWith(withState('not_published')),
        state: state,
      );
      expect(find.text('По табло · 2 из 3 · элементов и оценок судей пока нет'), findsOneWidget);
      expect(find.text('70.10'), findsOneWidget);
      expect(find.text('65.00'), findsOneWidget);
      expect(find.textContaining('Протокола пока нет'), findsNothing);
      expectNoHorizontalScroll(tester);
    });

    testWidgets('в файле строк нет и живых итогов нет — как раньше', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withState('not_published')), state: AppState());
      expect(find.text('Протокола и заявки пока нет'), findsOneWidget);
      expect(find.textContaining('По табло'), findsNothing);
    });

    testWidgets('в файле строки есть — табло не подменяет файл', (tester) async {
      final state = AppState()
        ..adoptLive(start().id, LiveOk(podium: [], provisional: true, rows: [Placing(1, 'Кто-то Другой', 'RUS', '1.00')]));
      await pumpScreen(tester, s: start(), repo: repoWith(sample()), state: state);
      expect(find.text('Кто-то Другой'), findsNothing);
      expect(find.text('66.36'), findsOneWidget);
    });

    testWidgets('сверка с оригиналом не сошлась — только статус и оригинал', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withState('judges_mismatch', basis: null)));
      expect(find.text('Итоги не подтверждены'), findsOneWidget);
      expect(find.text('66.36'), findsNothing);
      expect(find.byTooltip('Оригинал протокола'), findsOneWidget);
    });

    testWidgets('сегмент с неизвестным состоянием — «Экран недоступен» только для него', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withState('что-то новое')));
      expect(find.text('Экран для этого протокола недоступен'), findsOneWidget);
    });

    testWidgets('нет связи с сохранённой версией — время сохранения, строки из кэша', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(sample(), then: null));
      // первая загрузка — в кэш; перезагружаем: сети нет
      await tester.tap(find.byTooltip('Обновить'));
      await tester.pumpAndSettle();
      expect(find.text('Нет связи · сохранено 15.10, 22:00'), findsOneWidget);
      expect(find.text('66.36'), findsOneWidget);
      expect(find.text('Повторить'), findsOneWidget);
    });

    testWidgets('итог вида не опубликован — честный текст, а не пустая таблица', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(sample()));
      await tester.tap(find.text('Итог'));
      await tester.pumpAndSettle();
      expect(find.text('Итог вида ещё не опубликован'), findsOneWidget);
    });

  });

  group('итог вида: подписи колонок и статусы по-русски', () {
    testWidgets('SP/FS, RD/FD, PT показываются как КП/ПП, РТ/ПТ', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withTotal(cols: ['SP', 'FS', 'RD', 'FD', 'PT', 'XYZ'])));
      await tester.tap(find.text('Итог'));
      await tester.pumpAndSettle();
      expect(find.textContaining('КП 1 · ПП 2 · РТ 3 · ПТ 4 · РТ 5 · XYZ 6'), findsOneWidget);
      expect(find.textContaining('SP'), findsNothing);
    });

    testWidgets('статусы WD, NQD, DQ — словами, а не сырыми кодами', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withTotal()));
      await tester.tap(find.text('Итог'));
      await tester.pumpAndSettle();
      expect(find.textContaining('снят'), findsOneWidget);
      expect(find.textContaining('не прошёл'), findsOneWidget);
      expect(find.textContaining('дисквалифицирован'), findsOneWidget);
      expect(find.text('WD'), findsNothing);
    });

    testWidgets('английские сбавки из файла — по-русски, неизвестная как в файле', (tester) async {
      final j = withDetails();
      final r = (_seg(j)['rows'] as List).first as Map<String, dynamic>;
      r['deds'] = [
        {'n': 'Music tempo', 'v': -1.0},
        {'n': 'Extra element', 'v': -2.0},
        {'n': 'Zebra rule', 'v': -1.0},
      ];
      await pumpScreen(tester, s: start(), repo: repoWith(j));
      await tester.tap(find.text(_pair));
      await tester.pumpAndSettle();
      expect(find.text('Темп музыки'), findsOneWidget);
      expect(find.text('Лишний элемент'), findsOneWidget);
      expect(find.text('Zebra rule'), findsOneWidget);
      expect(find.text('Music tempo'), findsNothing);
      expect(deductionName('Falls'), 'Падения');
    });

    test('незнакомый статус и колонка остаются как в файле', () {
      expect(statusLabel('ZZ'), 'ZZ');
      expect(colLabel('Блок'), 'Блок');
      expect(statusLabel('DNS'), 'не вышел');
      expect(colLabel('KП'), 'КП');
    });
  });

  group('строки: раскрытие по тапу, прочерк вместо выдуманного', () {
    testWidgets('раскрытие показывает TES, PCS и снижение', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(sample()));
      expect(find.text('37.77'), findsNothing);
      await tester.tap(find.text('Анна Павловна Билибина / Дмитрий Владимирович Кашаев'));
      await tester.pumpAndSettle();
      expect(find.text('37.77'), findsOneWidget);
      expect(find.text('28.59'), findsOneWidget);
      expect(find.text('ТЕХ'), findsOneWidget);
      expect(find.text('КОМП'), findsOneWidget);
      expectNoHorizontalScroll(tester);
    });

    testWidgets('строки без оценок не раскрываются', (tester) async {
      final j = sample();
      final r = (_seg(j)['rows'] as List).first as Map<String, dynamic>;
      r..remove('tes')..remove('pcs')..remove('ded');
      await pumpScreen(tester, s: start(), repo: repoWith(j));
      await tester.tap(find.text('Анна Павловна Билибина / Дмитрий Владимирович Кашаев'));
      await tester.pumpAndSettle();
      expect(find.text('ТЕХ'), findsNothing);
    });

    testWidgets('элементы, компоненты, сбавки и итоги из контракта', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withDetails()));
      await tester.tap(find.text(_pair));
      await tester.pumpAndSettle();
      expect(find.text('Элементы'), findsOneWidget);
      expect(find.text('сумма баз 20.30'), findsOneWidget);
      expect(find.textContaining('3Lz+3T'), findsOneWidget);
      expect(find.text('10.10x'), findsOneWidget);
      expect(find.text('+1.21'), findsOneWidget);
      expect(find.text('11.31'), findsOneWidget);
      expect(find.text('< — недокрут'), findsOneWidget);
      expect(find.text('Компоненты'), findsOneWidget);
      expect(find.text('Композиция'), findsOneWidget);
      expect(find.text('×1.33'), findsOneWidget);
      expect(find.text('Сбавки'), findsWidgets);
      expect(find.text('Падения'), findsOneWidget);
      expect(find.text('-1.00'), findsWidgets);
      expect(find.text('Сумма'), findsOneWidget);
      expectNoHorizontalScroll(tester);
    });

    testWidgets('оценки судей по тапу на элемент; null — прочерк на своём месте', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withDetails()));
      await tester.tap(find.text(_pair));
      await tester.pumpAndSettle();
      expect(find.text('С3'), findsNothing);
      await tester.tap(find.textContaining('3Lz+3T'));
      await tester.pumpAndSettle();
      expect(find.text('С1'), findsOneWidget);
      expect(find.text('С3'), findsOneWidget);
      expect(find.text('—'), findsWidgets);
      await tester.tap(find.textContaining('3Lz+3T'));
      await tester.pumpAndSettle();
      expect(find.text('С3'), findsNothing);
    });

    testWidgets('нет полей — нет блоков и нет нулей: ни «Элементы», ни «Сбавки»', (tester) async {
      final j = sample();
      final r = (_seg(j)['rows'] as List).first as Map<String, dynamic>;
      r..remove('ded')..remove('pcs');
      await pumpScreen(tester, s: start(), repo: repoWith(j));
      await tester.tap(find.text(_pair));
      await tester.pumpAndSettle();
      expect(find.text('Элементы'), findsNothing);
      expect(find.text('Компоненты'), findsNothing);
      expect(find.text('Сбавки'), findsNothing);
      expect(find.text('КОМП'), findsNothing);
      expect(find.text('ТЕХ'), findsOneWidget);
      expect(find.text('0.00'), findsNothing);
    });

    testWidgets('элемент без базы, GOE и оценки — прочерки, не нули', (tester) async {
      final j = sample();
      final r = (_seg(j)['rows'] as List).first as Map<String, dynamic>;
      r['els'] = [
        {'no': 1, 'n': 'StSq'},
      ];
      r.remove('ded');
      await pumpScreen(tester, s: start(), repo: repoWith(j));
      await tester.tap(find.text(_pair));
      await tester.pumpAndSettle();
      expect(find.text('StSq'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(3));
      expect(find.text('0.00'), findsNothing);
    });
  });

  group('судьи сегмента — свёрнутый блок в конце', () {
    testWidgets('есть список — блок свёрнут, по тапу показывает судей', (tester) async {
      final j = withDetails();
      _seg(j)['panel'] = [
        {'no': 'J1', 'name': 'Мария Ивановна ПЕТРОВА', 'nation': 'RUS'},
        {'no': 'J2', 'name': 'Иван Сергеевич СИДОРОВ'},
      ];
      await pumpScreen(tester, s: start(), repo: repoWith(j));
      expect(find.text('Судьи · 2'), findsOneWidget);
      expect(find.textContaining('Петрова', skipOffstage: false), findsNothing);
      await tester.ensureVisible(find.text('Судьи · 2'));
      await tester.tap(find.text('Судьи · 2'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Петрова'), findsOneWidget);
      expect(find.text('RUS'), findsOneWidget);
      expectNoHorizontalScroll(tester);
    });

    testWidgets('списка нет — блока нет', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(sample()));
      expect(find.textContaining('Судьи ·'), findsNothing);
    });
  });

  group('сбой файла: оригинал во внешнем браузере, без экрана ошибки', () {
    final src = start().src;
    final cases = <(String, Object?)>[
      ('404', 404),
      ('сеть недоступна', null),
      ('таймаут', 'timeout'),
      ('сервер 500', 500),
      ('битый JSON', '{"v":1,'),
      ('пустой файл', ''),
      ('JSON не объект', '[1,2]'),
      ('неизвестная версия', {'v': 2, 'tid': 'x', 'tournament': 'x', 'src': 'x', 'categories': []}),
      ('нет обязательных полей', {'v': 1}),
    ];
    for (final c in cases) {
      testWidgets('${c.$1} без сохранённой версии — открывается оригинал', (tester) async {
        final opened = <String>[];
        await pumpScreen(tester, s: start(), repo: repoWith(c.$2), opened: opened);
        expect(opened, [src]);
        expect(find.text('Нет связи с сервером'), findsNothing);
        expect(find.text('Экран для этого протокола недоступен'), findsNothing);
      });
      testWidgets('${c.$1} при сохранённой версии — показываем её, оригинал не открываем', (tester) async {
        final opened = <String>[];
        await pumpScreen(tester, s: start(), repo: repoWith(sample(), then: c.$2), opened: opened);
        expect(opened, isEmpty);
        await tester.tap(find.byTooltip('Обновить'));
        await tester.pumpAndSettle();
        expect(opened, isEmpty);
        final net = c.$2 == null || c.$2 == 'timeout' || c.$2 == 500;
        expect(find.text(net ? 'Нет связи · сохранено 15.10, 22:00' : 'Показана сохранённая версия · 15.10, 22:00'), findsOneWidget);
        expect(find.textContaining(net ? 'Показана' : 'Нет связи'), findsNothing, reason: 'связь упоминается только при сетевом сбое');
        expect(find.text('66.36'), findsOneWidget);
        expect(find.text('Повторить'), findsOneWidget);
        expectNoHorizontalScroll(tester);
      });
    }

    testWidgets('раскрытая строка остаётся за тем же человеком после обновления файла', (tester) async {
      final j = sample();
      final first = _seg(j)['rows'] as List;
      final swapped = jsonDecode(jsonEncode(j)) as Map<String, dynamic>;
      // в новом файле порядок строк другой: Жарова стала первой, i поменялись
      final rows = (_seg(swapped)['rows'] as List).reversed.toList();
      for (var i = 0; i < rows.length; i++) {
        (rows[i] as Map)['i'] = i + 1;
      }
      _seg(swapped)['rows'] = rows;
      expect(first, hasLength(2));
      await pumpScreen(tester, s: start(), repo: repoWith(j, then: swapped));
      await tester.tap(find.text(_pair));
      await tester.pumpAndSettle();
      expect(find.text('ТЕХ'), findsOneWidget);
      await tester.tap(find.byTooltip('Обновить'));
      await tester.pumpAndSettle();
      expect(find.text('ТЕХ'), findsOneWidget);
      // раскрыт по-прежнему Билибин/Кашаев (37.77), а не новая первая строка
      expect(find.text('37.77'), findsOneWidget);
      expect(find.text('37.02'), findsNothing);
    });

    testWidgets('старт без proto — открывается оригинал', (tester) async {
      final opened = <String>[];
      await pumpScreen(tester, s: start(proto: null), repo: repoWith(404), opened: opened);
      expect(opened, [src]);
    });

    testWidgets('экран закрывается после открытия оригинала', (tester) async {
      final opened = <String>[];
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () => Navigator.of(c).push(
                MaterialPageRoute<void>(
                  builder: (_) => ProtocolScreen(start: start(), repo: repoWith(404), opener: (u) async => opened.add(u)),
                ),
              ),
              child: const Text('открыть'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('открыть'));
      await tester.pumpAndSettle();
      expect(opened, [start().src]);
      expect(find.byType(ProtocolScreen), findsNothing);
      expect(find.text('открыть'), findsOneWidget);
    });

    testWidgets('окончательный файл удался — оригинал не открывается', (tester) async {
      final opened = <String>[];
      await pumpScreen(tester, s: start(), repo: repoWith(sample()), opened: opened);
      expect(opened, isEmpty);
    });
  });

  group('ширины, масштаб, темы: без переполнений и горизонтальной прокрутки', () {
    for (final width in [360.0, 390.0, 430.0]) {
      for (final scale in [1.0, 1.3]) {
        for (final b in [Brightness.light, Brightness.dark]) {
          testWidgets('окончательный, ширина $width, масштаб $scale, ${b.name}', (tester) async {
            await pumpScreen(
              tester,
              s: start(ours: ['Анна Билибина / Дмитрий Кашаев']),
              repo: repoWith(withDetails()..['categories'] = _longNames(withDetails())),
              width: width,
              scale: scale,
              brightness: b,
            );
            await tester.tap(find.text(_pair));
            await tester.pumpAndSettle();
            expectNoHorizontalScroll(tester);
            // оценки судей по элементу и компоненту раскрыты — тоже без переполнений
            await tester.tap(find.textContaining('3Lz+3T'));
            await tester.tap(find.text('Композиция'));
            await tester.pumpAndSettle();
            expect(find.text('С1'), findsNWidgets(2));
            expectNoHorizontalScroll(tester);
          });
        }
      }
    }

    for (final width in [360.0, 390.0, 430.0]) {
      for (final scale in [1.0, 1.3]) {
        for (final b in [Brightness.light, Brightness.dark]) {
          testWidgets('вкладка «Итог», ширина $width, масштаб $scale, ${b.name}', (tester) async {
            await pumpScreen(
              tester,
              s: start(ours: ['Анна Билибина / Дмитрий Кашаев']),
              repo: repoWith(withTotal(cols: ['SP', 'FS', 'RD', 'FD', 'PT'], statuses: ['WD', 'NQD', 'DQ', 'DNS', 'RET'])),
              width: width,
              scale: scale,
              brightness: b,
            );
            await tester.tap(find.text('Итог'));
            await tester.pumpAndSettle();
            expect(find.textContaining('дисквалифицирован'), findsOneWidget);
            expectNoHorizontalScroll(tester);
          });
        }
      }
    }

    for (final c in <(String, Object, Object?)>[
      ('промежуточный', 'in_progress', null),
      ('несверено', 'judges_mismatch', null),
      ('формат', 'format', null),
    ]) {
      testWidgets('состояние «${c.$1}» при 360 и масштабе 1.3', (tester) async {
        await pumpScreen(tester, s: start(), repo: repoWith(withState(c.$2 as String, basis: null)), width: 360, scale: 1.3);
        expectNoHorizontalScroll(tester);
      });
    }

    testWidgets('длинные имена пар переносятся, не выходят за экран', (tester) async {
      final j = sample();
      final r = (_seg(j)['rows'] as List).first as Map<String, dynamic>;
      r['name'] = 'Елизавета Андреевна ЛЕБЕДЕВА-ПЕТРОСЯН / Александр Владимирович ВОЛКОВ-ЧЕРНЫШЁВ-МАКСИМОВ';
      await pumpScreen(tester, s: start(), repo: repoWith(j), width: 360, scale: 1.3);
      expectNoHorizontalScroll(tester);
    });

    testWidgets('три категории — лист выбора, а не прокрутка страницы', (tester) async {
      final j = sample();
      final cats = j['categories'] as List;
      cats.add({'kind': 'women', 'level': 'junior', 'name': 'Одиночное катание, девушки', 'segments': [], 'total': null});
      cats.add({'kind': 'men', 'level': 'junior', 'name': 'Одиночное катание, юноши', 'segments': [], 'total': null});
      await pumpScreen(tester, s: start(), repo: repoWith(j));
      await tester.tap(find.text('Танцы · Юниоры'));
      await tester.pumpAndSettle();
      expect(find.text('Девушки · Юниоры'), findsOneWidget);
      expect(find.text('Юноши · Юниоры'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
    });
  });

  group('подписи категорий и вкладок', () {
    test('подпись категории — вид и уровень', () {
      final c = ProtocolDoc.fromJson(sample()).categories.first;
      expect(categoryLabel(c), 'Танцы · Юниоры');
    });
    test('адрес оригинала: страница сегмента, иначе оглавление, иначе старт', () {
      final d = ProtocolDoc.fromJson(sample());
      final s = start();
      expect(originalUrl(d, d.categories.first.segments.first, s), endsWith('SEG007.HTM'));
      expect(originalUrl(d, null, s), d.src);
      expect(originalUrl(null, null, s), s.src);
    });
    test('состояния «Нет связи» и «Экран недоступен» — тексты макетов', () {
      expect(protocolView(const ProtocolFormatError('x'), category: null, tab: 'РТ', hasField: false).status,
          'Экран для этого протокола недоступен');
      expect(protocolView(const ProtocolMissing(), category: null, tab: 'РТ', hasField: true).status,
          'Протокола пока нет · состав по заявке');
      expect(protocolView(const ProtocolMissing(), category: null, tab: 'РТ', hasField: false).status,
          'Протокола и заявки пока нет');
      expect(protocolView(const ProtocolNetError(), category: null, tab: 'РТ', hasField: false).status, 'Нет связи с сервером');
    });
  });
}
