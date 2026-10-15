// Разбор файла протокола по контракту v=1: окончательность, битые поля, версия, адреса.
// Фикстура test/protocol/sample.json — пример из контракта (реальные значения ФФКМ, две строки).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starty/data.dart';
import 'package:starty/protocol_model.dart';

Map<String, dynamic> sample() => jsonDecode(File('test/protocol/sample.json').readAsStringSync()) as Map<String, dynamic>;

/// Сегмент ритм-танца из фикстуры — для подмены полей в тестах.
Map<String, dynamic> seg(Map<String, dynamic> doc) =>
    ((doc['categories'] as List).first as Map)['segments'].first as Map<String, dynamic>;

void main() {
  group('контракт v=1: файл турнира', () {
    test('пример из контракта разбирается целиком', () {
      final d = ProtocolDoc.fromJsonString(File('test/protocol/sample.json').readAsStringSync());
      expect(d.v, 1);
      expect(d.tid, 'ffkm:2026-08-24_pm');
      expect(d.tournament, 'Первенство Москвы');
      expect(d.marks, isTrue);
      expect(d.built, DateTime.parse('2026-10-15T21:56:43+03:00'));
      expect(d.categories, hasLength(1));
    });

    test('категория и сегмент по виду, уровню и коду', () {
      final d = ProtocolDoc.fromJson(sample());
      final c = d.categoryFor('dance', 'junior')!;
      expect(c.name, 'Танцы на льду, КМС, Юниорки, Юниоры');
      expect(d.categoryFor('dance', 'senior'), isNull);
      expect(c.segmentOf('РТ')!.name, 'Ритм-танец');
      expect(c.segmentOf('ПТ'), isNull);
      expect(c.total, isNull, reason: 'total: null — итог не опубликован');
    });

    test('сегмент окончателен по судейским оценкам, строки с оценками', () {
      final s = ProtocolDoc.fromJson(sample()).categories.first.segments.first;
      expect(s.state, SegmentState.finalized);
      expect(s.basis, 'judges');
      expect(s.judges, endsWith('TaaCopop_PT_Scores.pdf'));
      expect(s.rows, hasLength(2));
      final r = s.rows.first;
      expect(r.i, 1);
      expect(r.place, 1);
      expect(r.no, 6);
      expect(r.points, '66.36');
      expect(r.tes, '37.77');
      expect(r.pcs, '28.59');
      expect(r.ded, '0.00');
      expect(r.nation, '', reason: 'колонка страны на ФФКМ пуста — пустая строка, не выдуманная страна');
      expect(r.parts, isNull);
    });

    test('версия не 1 — файл целиком не разбирается', () {
      for (final v in [2, 0, '1', null]) {
        final j = sample()..['v'] = v;
        expect(() => ProtocolDoc.fromJson(j), throwsA(isA<ProtocolFormatException>()), reason: 'v=$v');
      }
    });

    test('не JSON, не объект, нет categories или адреса — файл целиком не разбирается', () {
      expect(() => ProtocolDoc.fromJsonString('<html>'), throwsA(isA<ProtocolFormatException>()));
      expect(() => ProtocolDoc.fromJsonString('[1,2]'), throwsA(isA<ProtocolFormatException>()));
      expect(() => ProtocolDoc.fromJson(sample()..remove('categories')), throwsA(isA<ProtocolFormatException>()));
      expect(() => ProtocolDoc.fromJson(sample()..remove('tid')), throwsA(isA<ProtocolFormatException>()));
    });

    test('неизвестные ключи игнорируются, новое необязательное поле версию не меняет', () {
      final j = sample()..['будущее'] = {'x': 1};
      seg(j)['новое'] = true;
      final d = ProtocolDoc.fromJson(j);
      expect(d.categories.first.segments.first.rows, hasLength(2));
    });

    test('дата файла не читается — built пусто, файл разбирается', () {
      final d = ProtocolDoc.fromJson(sample()..['built'] = 'вчера');
      expect(d.built, isNull);
    });

    test('категория без обязательных полей пропускается, остальные читаются', () {
      final j = sample();
      (j['categories'] as List).insert(0, {'kind': 'men'});
      final d = ProtocolDoc.fromJson(j);
      expect(d.categories.map((c) => c.kind), ['dance']);
    });
  });

  group('битый сегмент — только его состояние format', () {
    test('неизвестное состояние', () {
      final j = sample();
      seg(j)['state'] = 'почти-окончательный';
      final s = ProtocolDoc.fromJson(j).categories.first.segments.first;
      expect(s.state, SegmentState.format);
      expect(s.rows, isEmpty);
    });
    test('окончательный без basis judges — не окончательный, а format', () {
      final j = sample();
      seg(j)['basis'] = null;
      expect(ProtocolDoc.fromJson(j).categories.first.segments.first.state, SegmentState.format);
    });
    test('неизвестная таблица', () {
      final j = sample();
      seg(j)['table'] = 'картинка';
      expect(ProtocolDoc.fromJson(j).categories.first.segments.first.state, SegmentState.format);
    });
    test('строка без имени — весь сегмент format', () {
      final j = sample();
      ((seg(j)['rows'] as List).first as Map).remove('name');
      final s = ProtocolDoc.fromJson(j).categories.first.segments.first;
      expect(s.state, SegmentState.format);
      expect(s.rows, isEmpty);
    });
    test('соседние сегменты при этом читаются', () {
      final j = sample();
      final c = (j['categories'] as List).first as Map<String, dynamic>;
      (c['segments'] as List).add({'code': 'ПТ', 'name': 'Произвольный танец', 'page': '', 'table': 'results', 'state': 'в пути'});
      final segs = ProtocolDoc.fromJson(j).categories.first.segments;
      expect(segs.map((s) => s.state), [SegmentState.finalized, SegmentState.format]);
      expect(segs.first.rows, hasLength(2));
    });
  });

  group('мягкие поля строки: прочерк вместо выдуманного числа', () {
    ProtocolRow row(Map<String, Object?> fields) {
      final j = sample();
      final r = (seg(j)['rows'] as List).first as Map<String, dynamic>;
      r.addAll(fields);
      return ProtocolDoc.fromJson(j).categories.first.segments.first.rows.first;
    }

    test('баллы с запятой — null, не число', () {
      expect(row({'points': '115,66'}).points, isNull);
    });
    test('баллы числом читаются в две цифры после точки', () {
      expect(row({'points': 66.4}).points, '66.40');
    });
    test('место вне 1..999 или не число — null, статус остаётся', () {
      expect(row({'place': 0}).place, isNull);
      expect(row({'place': 1000}).place, isNull);
      final r = row({'place': null, 'status': 'WD'});
      expect(r.place, isNull);
      expect(r.status, 'WD');
    });
    test('снижение может быть отрицательным', () {
      expect(row({'ded': '-1.00'}).ded, '-1.00');
    });
    test('элементы и компоненты: необязательные поля (не в контракте 2.3, см. protocol_screen)', () {
      final r = row({
        'els': [
          {'n': '3Lz', 'b': '6.00', 'g': '+1.10'},
          {'n': 'FCSp4', 'b': '3.20', 'g': 'большой'},
          'мусор',
        ],
        'comp': ['7.25', '6.75', '7.00'],
      });
      expect(r.elements.map((e) => e.name), ['3Lz', 'FCSp4']);
      expect(r.elements.first.base, '6.00');
      expect(r.elements.first.goe, '+1.10');
      expect(r.elements.last.goe, isNull, reason: 'GOE не число — прочерк');
      expect(r.components, ['7.25', '6.75', '7.00']);
    });
  });

  group('итог вида', () {
    Map<String, dynamic> withTotal(Map<String, dynamic> rows, {List<String>? cols}) {
      final j = sample();
      ((j['categories'] as List).first as Map<String, dynamic>)['total'] = {
        'state': 'final',
        'complete': true,
        'cols': cols ?? ['KП', 'ПП'],
        'colsKind': 'places',
        'rows': rows['rows'],
        'skipped': 0,
      };
      return j;
    }

    test('колонки и части строки, как на табло', () {
      final j = withTotal({
        'rows': [
          {'i': 1, 'place': 1, 'name': 'Анна БИЛИБИНА / Дмитрий КАШАЕВ', 'nation': '', 'points': '151.63', 'parts': ['3', '1']},
        ],
      });
      final t = ProtocolDoc.fromJson(j).categories.first.total!;
      expect(t.state, TotalState.finalized);
      expect(t.cols, ['KП', 'ПП']);
      expect(t.colsKind, 'places');
      expect(t.rows.single.parts, ['3', '1']);
    });

    test('длина parts не совпадает с cols — весь итог format', () {
      final j = withTotal({
        'rows': [
          {'i': 1, 'place': 1, 'name': 'А Б', 'points': '1.00', 'parts': ['3']},
        ],
      });
      final t = ProtocolDoc.fromJson(j).categories.first.total!;
      expect(t.state, TotalState.format);
      expect(t.rows, isEmpty);
    });

    test('неизвестный вид колонок — unknown', () {
      final j = withTotal({'rows': []});
      ((j['categories'] as List).first as Map<String, dynamic>)['total']!['colsKind'] = 'дробь';
      expect(ProtocolDoc.fromJson(j).categories.first.total!.colsKind, 'unknown');
    });
  });

  group('адрес файла на сайте', () {
    test('рядом с events.json, в protocols/', () {
      expect(protocolUrl('ffkm_2026-08-24_pm.json'), 'https://xfurya.github.io/Starty/data/protocols/ffkm_2026-08-24_pm.json');
    });
    test('путь и не-json отбрасываются', () {
      expect(protocolUrl('../events.json'), isNull);
      expect(protocolUrl('a/b.json'), isNull);
      expect(protocolUrl('x.html'), isNull);
      expect(protocolUrl(null), isNull);
    });
    test('старт: proto из events.json, пустая строка — нет файла', () {
      Start s(Object? proto) => Start.fromJson({
        'id': 'x',
        'tid': 't',
        'tournament': 'T',
        'kind': 'dance',
        'level': 'junior',
        'seg': 'РТ',
        'title': 'T — танцы РТ',
        'src': 'https://ffkm.ru/i.htm',
        'start': '2026-08-24T15:00:00+03:00',
        'end': '2026-08-24T18:35:00+03:00',
        'proto': proto,
      });
      expect(s('ffkm_2026-08-24_pm.json').proto, 'ffkm_2026-08-24_pm.json');
      expect(s(null).proto, isNull);
      expect(s('').proto, isNull);
    });
  });

  group('окончательность в расписании: basis из events.json', () {
    Start base({String? basis, bool total = false, bool hasCat = false, bool podium = true}) => Start.fromJson({
      'id': 'x',
      'tid': 't',
      'tournament': 'T',
      'kind': 'dance',
      'level': 'junior',
      'seg': 'РТ',
      'title': 'T — танцы РТ',
      'src': 'https://ffkm.ru/i.htm',
      'start': '2026-08-24T15:00:00+03:00',
      'end': '2026-08-24T18:35:00+03:00',
      'podium': podium ? [{'place': 1, 'name': 'А Б', 'nation': '', 'points': '1.00'}] : [],
      'total': total ? [{'place': 1, 'name': 'А Б', 'nation': '', 'points': '1.00'}] : [],
      'live': {'idx': '', 'seg': 'https://ffkm.ru/x.HTM', 'cat': hasCat ? 'https://ffkm.ru/c.HTM' : null, 'basis': ?basis},
    });

    test('basis judges — окончателен', () => expect(base(basis: 'judges').settled, isTrue));
    test('basis time — окончателен (только при включённом флаге сборщика)', () => expect(base(basis: 'time').settled, isTrue));
    test('basis null — прежнее правило: не окончателен, если провизорий не сняли', () {
      expect(base().settled, isTrue, reason: 'без basis и без provisional — как раньше');
    });
    test('basis null с категорией без итога — не окончателен', () {
      expect(base(hasCat: true).settled, isFalse);
    });
    test('basis judges, категория без итога — не окончателен, пока нет итога', () {
      expect(base(basis: 'judges', hasCat: true).settled, isFalse);
      expect(base(basis: 'judges', hasCat: true, total: true).settled, isTrue);
    });
    test('без тройки окончательности нет', () => expect(base(basis: 'judges', podium: false).settled, isFalse));
  });
}
