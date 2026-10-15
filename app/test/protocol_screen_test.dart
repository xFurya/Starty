// Экран протокола: состояния из утверждённых макетов, ширины 360/390/430, масштаб текста 1.0 и 1.3,
// светлая и тёмная темы; горизонтальной прокрутки и переполнений нет.
// Шрифты — настоящие (Manrope, Cormorant), как в views_test.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
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

final _now = DateTime.utc(2026, 10, 15, 19, 0); // 22:00 по Москве

Map<String, dynamic> sample() => jsonDecode(File('test/protocol/sample.json').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _seg(Map<String, dynamic> j) => ((j['categories'] as List).first as Map)['segments'].first as Map<String, dynamic>;

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
      if (body == 404) return http.Response('', 404);
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
      home: ProtocolScreen(start: s, repo: repo),
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

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('статусы из макетов', () {
    testWidgets('окончательный — строки с местами и баллами, «Оригинал протокола»', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(sample()));
      expect(find.text('Окончательный · сверено с оригиналом'), findsOneWidget);
      expect(find.text('Анна Павловна Билибина / Дмитрий Владимирович Кашаев'), findsOneWidget);
      expect(find.text('66.36'), findsOneWidget);
      expect(find.text('Оригинал протокола'), findsOneWidget);
      expectNoHorizontalScroll(tester);
    });

    testWidgets('промежуточный (идёт) — время обновления файла по Москве', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withState('in_progress')));
      expect(find.text('Идёт · промежуточный · обновлено 21:56'), findsOneWidget);
      expectNoHorizontalScroll(tester);
    });

    testWidgets('промежуточный (сегмент прошёл, оценок нет)', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withState('provisional', basis: null)));
      expect(find.text('Промежуточный · обновлено 21:56'), findsOneWidget);
    });

    testWidgets('протокола нет, есть заявка — состав по заявке без мест', (tester) async {
      await pumpScreen(
        tester,
        s: start(field: ['Анна Билибина / Дмитрий Кашаев', 'Полина Жарова / Алексей Столяров'], ours: ['Анна Билибина / Дмитрий Кашаев']),
        repo: repoWith(withState('not_published')),
      );
      expect(find.text('Протокола пока нет · состав по заявке'), findsOneWidget);
      expect(find.text('Полина Жарова / Алексей Столяров'), findsOneWidget);
      expect(find.text('отслеживаемая'), findsOneWidget);
      expectNoHorizontalScroll(tester);
    });

    testWidgets('протокола и заявки нет — пусто', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(404));
      expect(find.text('Протокола и заявки пока нет'), findsOneWidget);
      expect(find.text('Оригинал протокола'), findsOneWidget);
    });

    testWidgets('сверка с оригиналом не сошлась — только статус и оригинал', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(withState('judges_mismatch', basis: null)));
      expect(find.text('Сверка с оригиналом не сошлась'), findsOneWidget);
      expect(find.text('66.36'), findsNothing);
      expect(find.text('Оригинал протокола'), findsOneWidget);
    });

    testWidgets('неизвестный формат файла — «Экран недоступен», с оригиналом', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(sample()..['v'] = 2));
      expect(find.text('Экран для этого протокола недоступен'), findsOneWidget);
      expect(find.text('Оригинал протокола'), findsOneWidget);
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

    testWidgets('нет связи без кэша — «Нет связи с сервером» и «Повторить»', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(null));
      expect(find.text('Нет связи с сервером'), findsOneWidget);
      expect(find.text('Повторить'), findsOneWidget);
      expect(find.text('Оригинал протокола'), findsOneWidget);
    });

    testWidgets('итог вида не опубликован — честный текст, а не пустая таблица', (tester) async {
      await pumpScreen(tester, s: start(), repo: repoWith(sample()));
      await tester.tap(find.text('Итог'));
      await tester.pumpAndSettle();
      expect(find.text('Итог вида ещё не опубликован'), findsOneWidget);
    });

    testWidgets('старт без протокола в расписании: экран не открывается по этому пути', (tester) async {
      // proto == null: маршрут открывает оригинал, экран не нужен; сам экран с таким стартом — «нет протокола»
      await pumpScreen(tester, s: start(proto: null), repo: repoWith(404));
      expect(find.text('Протокола и заявки пока нет'), findsOneWidget);
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
      expect(find.text('TES'), findsOneWidget);
      expect(find.text('PCS'), findsOneWidget);
      expectNoHorizontalScroll(tester);
    });

    testWidgets('строки без оценок не раскрываются', (tester) async {
      final j = sample();
      final r = (_seg(j)['rows'] as List).first as Map<String, dynamic>;
      r..remove('tes')..remove('pcs')..remove('ded');
      await pumpScreen(tester, s: start(), repo: repoWith(j));
      await tester.tap(find.text('Анна Павловна Билибина / Дмитрий Владимирович Кашаев'));
      await tester.pumpAndSettle();
      expect(find.text('TES'), findsNothing);
    });

    testWidgets('элементы с базой и GOE — раскрытие', (tester) async {
      final j = sample();
      final r = (_seg(j)['rows'] as List).first as Map<String, dynamic>;
      r['els'] = [
        {'n': '3Lz', 'b': '6.00', 'g': '+1.10'},
        {'n': 'FCSp4', 'b': '3.20', 'g': '-0.40'},
      ];
      r['comp'] = ['7.25', '6.75', '7.00'];
      await pumpScreen(tester, s: start(), repo: repoWith(j));
      await tester.tap(find.text('Анна Павловна Билибина / Дмитрий Владимирович Кашаев'));
      await tester.pumpAndSettle();
      expect(find.text('3Lz'), findsOneWidget);
      expect(find.text('GOE +1.10'), findsOneWidget);
      expect(find.text('Компоненты 7.25 · 6.75 · 7.00'), findsOneWidget);
      expectNoHorizontalScroll(tester);
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
              repo: repoWith(sample()),
              width: width,
              scale: scale,
              brightness: b,
            );
            await tester.tap(find.text('Анна Павловна Билибина / Дмитрий Владимирович Кашаев'));
            await tester.pumpAndSettle();
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
