// «Сколько нужно» (подписка): пороги за второй сегмент по нынешним итогам и блок на экране протокола.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/billing.dart';
import 'package:starty/data.dart';
import 'package:starty/needs.dart';
import 'package:starty/protocol_model.dart';
import 'package:starty/protocol_repo.dart';
import 'package:starty/protocol_screen.dart';
import 'package:starty/state.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync())));
  }
  await l.load();
}

ProtocolRow _row(int i, String name, String? points, {int? place, String? status}) =>
    ProtocolRow(i: i, place: points == null ? null : (place ?? i), status: status, name: name, points: points);

ProtocolSegment _seg(String code, List<ProtocolRow> rows, {SegmentState state = SegmentState.finalized}) => ProtocolSegment(
  code: code,
  name: code,
  page: '',
  table: 'results',
  state: state,
  basis: state == SegmentState.finalized ? 'judges' : null,
  rows: rows,
);

/// Короткая: шестеро, у пятого и шестого — свои места.
final _sp = _seg('КП', [
  _row(1, 'Анна ЛИДЕРОВА', '80.00'),
  _row(2, 'Белла ВТОРОВА', '78.50'),
  _row(3, 'Вера ТРЕТЬЯКОВА', '75.00'),
  _row(4, 'Галина ЧЕТВЕРИКОВА', '70.00'),
  _row(5, 'Дарья ПЯТОВА', '65.00'),
  _row(6, 'Ева ШЕСТОВА', '60.00'),
  _row(7, 'Жанна СНЯТОВА', null, status: 'WD'),
]);

void main() {
  group('пороги', () {
    test('идёт произвольная: первое место и тройка по тем, кто откатал оба сегмента', () {
      // откатали трое снизу: суммы 60+140=200, 65+130=195, 70+120=190
      final n = needsOf(
        first: _sp,
        second: [_row(1, 'Ева Шестова', '140.00'), _row(2, 'Дарья Пятова', '130.00'), _row(3, 'Галина Четверикова', '120.00')],
        lineup: {'анна лидерова', 'белла второва', 'вера третьякова', 'галина четверикова', 'дарья пятова', 'ева шестова'},
        ours: {'вера третьякова'},
      );
      expect(n, hasLength(1));
      final v = n.single;
      expect(v.place, 3);
      expect(v.first, 7500);
      expect(v.during, isTrue);
      // первое место: 200 - 75 = 125; ровно 125 даёт ту же сумму, а за произвольную 125 < 140 — проиграет
      expect(v.win!.text, 'больше 125.00');
      // тройка: третий — 190 (120 за произвольную); ровно 115 < 120 — тоже «больше»
      expect(v.podium!.text, 'больше 115.00');
    });

    test('равная сумма выигрывается произвольной — тогда «от»', () {
      final n = needsOf(
        first: _seg('КП', [_row(1, 'А ОДИН', '80.00'), _row(2, 'Б ДВА', '50.00')]),
        second: [_row(1, 'А Один', '30.00')],
        lineup: {'а один', 'б два'},
        ours: {'б два'},
      );
      // сумма лидера 110 при 30 за произвольную; Б нужно 60, а 60 > 30 — равенство выигрывает
      expect(n.single.win!.text, 'от 60.00');
      expect(n.single.win, const NeedMark(6000, orEqual: true));
      // откатал один — про тройку молчим: в неё входит любой
      expect(n.single.podium, isNull);
    });

    test('сумма за первый сегмент уже выше — «при любой оценке»', () {
      final n = needsOf(
        first: _seg('КП', [_row(1, 'А ОДИН', '90.00'), _row(2, 'Б ДВА', '10.00')]),
        second: [_row(1, 'Б Два', '50.00')],
        lineup: const {},
        ours: {'а один'},
      );
      // в списке второго сегмента только откатавший — выйдет ли А, неизвестно: порогов нет
      expect(n, isEmpty);
      final m = needsOf(
        first: _seg('КП', [_row(1, 'А ОДИН', '90.00'), _row(2, 'Б ДВА', '10.00')]),
        second: [_row(1, 'Б Два', '50.00')],
        lineup: {'а один', 'б два'},
        ours: {'а один'},
      );
      expect(m.single.win!.any, isTrue);
      expect(m.single.win!.text, 'при любой оценке');
    });

    test('нет в заявке второго сегмента (не прошёл отбор) — ничего', () {
      final n = needsOf(
        first: _sp,
        second: [_row(1, 'Ева Шестова', '140.00')],
        lineup: {'анна лидерова', 'ева шестова'},
        ours: {'дарья пятова'},
      );
      expect(n, isEmpty);
    });

    test('уже откатал, снят в короткой или первый сегмент не закончен — ничего', () {
      final second = [_row(1, 'Ева Шестова', '140.00')];
      final lineup = {'ева шестова', 'жанна снятова', 'анна лидерова'};
      expect(needsOf(first: _sp, second: second, lineup: lineup, ours: {'ева шестова'}), isEmpty);
      expect(needsOf(first: _sp, second: second, lineup: lineup, ours: {'жанна снятова'}), isEmpty);
      final going = _seg('КП', _sp.rows, state: SegmentState.inProgress);
      expect(needsOf(first: going, second: const [], lineup: lineup, ours: {'анна лидерова'}), isEmpty);
    });

    test('до произвольной: отставание от первого места, у лидера — отрыв от второго', () {
      final n = needsOf(
        first: _sp,
        second: const [],
        lineup: const {},
        ours: {'анна лидерова', 'вера третьякова'},
      );
      expect(n.map((x) => x.name), ['Анна ЛИДЕРОВА', 'Вера ТРЕТЬЯКОВА']);
      expect(n[0].during, isFalse);
      expect(n[0].behind, isNull);
      expect(n[0].ahead, 150);
      expect(n[1].behind, 500);
      expect(n[1].ahead, isNull);
    });

    test('стартовый лист второго сегмента без баллов — это ещё «до»', () {
      final n = needsOf(
        first: _sp,
        second: [ProtocolRow(i: 1, name: 'Вера Третьякова', no: 5)],
        lineup: const {},
        ours: {'вера третьякова', 'дарья пятова'},
      );
      // Дарьи в стартовом листе нет — её не показываем
      expect(n.map((x) => x.name), ['Вера ТРЕТЬЯКОВА']);
      expect(n.single.behind, 500);
    });

    test('баллы в сотых без потерь на дробях', () {
      expect(hundredthsOf('74.29'), 7429);
      expect(hundredthsOf('0.10'), 10);
      expect(hundredthsOf(null), isNull);
      expect(pointsText(12507), '125.07');
      expect(pointsText(5), '0.05');
    });
  });

  group('экран протокола', () {
    setUpAll(() async {
      await _font('Golos Text', ['GolosText-Regular.ttf', 'GolosText-Medium.ttf', 'GolosText-SemiBold.ttf', 'GolosText-Bold.ttf']);
      await _font('Piazzolla', ['Piazzolla-Medium.ttf', 'Piazzolla-SemiBold.ttf', 'Piazzolla-Bold.ttf']);
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.init();
      billingForce = true;
    });
    tearDown(() => billingForce = false);

    Map<String, dynamic> doc({String fsState = 'in_progress'}) => {
      'v': 1,
      'tid': 'isu:gp',
      'tournament': 'Гран-при',
      'src': 'https://example.org/index.htm',
      'built': '2026-11-06T18:00:00Z',
      'marks': true,
      'categories': [
        {
          'kind': 'women',
          'level': 'senior',
          'name': 'Женщины',
          'segments': [
            {
              'code': 'КП',
              'name': 'Короткая',
              'page': '',
              'table': 'results',
              'state': 'final',
              'basis': 'judges',
              'rows': [
                {'i': 1, 'place': 1, 'name': 'Анна ЛИДЕРОВА', 'points': '80.00'},
                {'i': 2, 'place': 2, 'name': 'Вера ТРЕТЬЯКОВА', 'points': '75.00'},
                {'i': 3, 'place': 3, 'name': 'Ева ШЕСТОВА', 'points': '60.00'},
              ],
            },
            {
              'code': 'ПП',
              'name': 'Произвольная',
              'page': '',
              'table': 'results',
              'state': fsState,
              'basis': fsState == 'final' ? 'judges' : null,
              'rows': [
                {'i': 1, 'place': 1, 'name': 'Ева ШЕСТОВА', 'points': '140.00'},
              ],
            },
          ],
        },
      ],
    };

    Start fs() => Start.fromJson({
      'id': 'isu:gp:women-senior-pp',
      'tid': 'isu:gp',
      'tournament': 'Гран-при',
      'kind': 'women',
      'level': 'senior',
      'seg': 'ПП',
      'title': 'Гран-при — женщины ПП',
      'venue': '',
      'src': 'https://example.org/index.htm',
      'start': '2026-11-06T18:00:00+03:00',
      'end': '2026-11-06T21:00:00+03:00',
      'proto': 'gp.json',
      'field': [
        for (final n in ['Ева Шестова', 'Вера Третьякова', 'Анна Лидерова']) {'name': n, 'time': '18:00'},
      ],
      'ours': [
        {'name': 'Вера Третьякова', 'time': '18:07'},
      ],
    });

    ProtocolRepo repo(Map<String, dynamic> j) => ProtocolRepo(
      now: () => DateTime.utc(2026, 11, 6, 16),
      client: MockClient(
        (r) async => http.Response.bytes(utf8.encode(jsonEncode(j)), 200, headers: {'content-type': 'application/json; charset=utf-8'}),
      ),
    );

    Future<AppState> pump(WidgetTester t, Map<String, dynamic> j, {required bool paid}) async {
      t.view.physicalSize = const Size(390, 1000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final s = fs();
      final st = AppState()..data = Schedule([s], DateTime.utc(2026, 11, 6, 16), true, false);
      if (paid) {
        st.billing.entitlement = Entitlement(checkedAt: DateTime.now(), paidUntil: DateTime.now().toUtc().add(const Duration(days: 20)));
      }
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Golos Text'),
          home: ProtocolScreen(start: s, repo: repo(j), state: st, opener: (_) async {}),
        ),
      );
      await t.pumpAndSettle();
      return st;
    }

    testWidgets('подписка действует — пороги над таблицей произвольной', (t) async {
      await pump(t, doc(), paid: true);
      expect(find.text('СКОЛЬКО НУЖНО ЗА ПРОИЗВОЛЬНУЮ'), findsOneWidget);
      expect(find.text('2-е место после короткой, 75.00'), findsOneWidget);
      // лидер после двух сегментов: 60 + 140 = 200; нужно больше 125.00 (ровно 125 < 140 проигрывает)
      expect(find.text('Первое место'), findsOneWidget);
      expect(find.text('больше 125.00'), findsOneWidget);
      // откатала одна — про тройку не говорим
      expect(find.text('Пьедестал'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('без подписки блока нет', (t) async {
      await pump(t, doc(), paid: false);
      expect(find.textContaining('СКОЛЬКО НУЖНО'), findsNothing);
      expect(find.text('Первое место'), findsNothing);
    });

    testWidgets('подписка не в этой сборке — блока нет, даже с сохранённым правом', (t) async {
      billingForce = false;
      await pump(t, doc(), paid: true);
      expect(find.textContaining('СКОЛЬКО НУЖНО'), findsNothing);
    });

    testWidgets('произвольная закончена — блока нет: всё уже в протоколе', (t) async {
      await pump(t, doc(fsState: 'final'), paid: true);
      expect(find.textContaining('СКОЛЬКО НУЖНО'), findsNothing);
      expect(find.text('Первое место'), findsNothing);
    });

    testWidgets('на вкладке короткой блока нет', (t) async {
      await pump(t, doc(), paid: true);
      await t.tap(find.text('Короткая'));
      await t.pumpAndSettle();
      expect(find.textContaining('СКОЛЬКО НУЖНО'), findsNothing);
    });
  });
}
