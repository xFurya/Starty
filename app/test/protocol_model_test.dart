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
    test('полный контракт строки: элементы, компоненты, сбавки, суммы', () {
      final r = row({
        'bv': 20.30,
        'start': 6,
        'els': [
          {'no': 1, 'n': '3Lz+3T', 'info': '<', 'b': 10.10, 'x': true, 'g': 1.21, 'j': [1, 2, null, 1], 's': 11.31},
          {'no': 2, 'n': 'FCSp4', 'b': '3.20', 'g': -0.4, 's': 2.8},
        ],
        'comp': [
          {'n': 'Композиция', 'f': 1.33, 'j': [8.25, 8.0, null], 's': 8.36},
        ],
        'deds': [
          {'n': 'Падения', 'v': -1.0},
        ],
      });
      expect(r.bv, '20.30');
      expect(r.start, '6');
      final e = r.elements.first;
      expect((e.no, e.name, e.info, e.base, e.x, e.goe, e.score), (1, '3Lz+3T', '<', '10.10', true, '1.21', '11.31'));
      expect(e.judges, [1, 2, null, 1], reason: 'null судьи сохраняется на своём месте');
      expect(r.elements.last.goe, '-0.40');
      expect(r.elements.last.x, isFalse);
      expect(r.elements.last.judges, isEmpty);
      final c = r.components.single;
      expect((c.name, c.factor, c.score), ('Композиция', '1.33', '8.36'));
      expect(c.judges, [8.25, 8.0, null]);
      expect(r.deductions.single.name, 'Падения');
      expect(r.deductions.single.value, '-1.00');
    });

    test('нет необязательных полей — null и пустые списки, а не нули', () {
      final r = row({});
      expect(r.bv, isNull);
      expect(r.start, isNull);
      expect(r.elements, isEmpty);
      expect(r.components, isEmpty);
      expect(r.deductions, isEmpty);
      final e = row({
        'els': [
          {'n': 'StSq'},
        ],
        'comp': [
          {'n': 'Композиция'},
        ],
        'deds': [
          {'n': 'Падения'},
        ],
      });
      expect((e.elements.single.base, e.elements.single.goe, e.elements.single.score), (null, null, null));
      expect(e.elements.single.x, isFalse);
      expect(e.elements.single.info, '');
      expect(e.elements.single.judges, isEmpty);
      expect((e.components.single.factor, e.components.single.score), (null, null));
      expect(e.deductions.single.value, isNull);
    });

    test('мусор в j — null, не ноль; не список — пусто', () {
      final r = row({
        'els': [
          {'n': 'A', 'j': [1, 'x', null, double.nan.toString(), 2.5]},
          {'n': 'B', 'j': 'нет'},
          {'n': 'C', 'j': null},
        ],
      });
      expect(r.elements[0].judges, [1, null, null, null, 2.5]);
      expect(r.elements[1].judges, isEmpty);
      expect(r.elements[2].judges, isEmpty);
    });

    test('негодные элементы, компоненты и сбавки пропускаются, остальные читаются', () {
      final r = row({
        'els': [
          'мусор',
          {'no': 1},
          {'n': '  '},
          {'n': '3Lo', 'b': 'много', 'g': 'большой', 's': '1,5'},
        ],
        'comp': ['7.25', 5, {'f': 1.0}, {'n': 'Скольжение', 'f': -1, 's': 'x'}],
        'deds': [null, {'v': -1.0}, {'n': 'Время', 'v': 'минус'}],
      });
      expect(r.elements.map((e) => e.name), ['3Lo']);
      expect((r.elements.single.base, r.elements.single.goe, r.elements.single.score), (null, null, null));
      expect(r.components.single.name, 'Скольжение');
      expect((r.components.single.factor, r.components.single.score), (null, null));
      expect(r.deductions.single.value, isNull);
    });

    test('поля els/comp/deds не списком — пусто, строка цела', () {
      final r = row({'els': 5, 'comp': 'x', 'deds': {'n': 'a'}});
      expect(r.name, isNotEmpty);
      expect(r.elements, isEmpty);
      expect(r.components, isEmpty);
      expect(r.deductions, isEmpty);
    });

    test('коэффициент без хвостовых нулей: 2 — «2», 1.5 — «1.5»', () {
      final r = row({
        'comp': [
          {'n': 'a', 'f': 2.0},
          {'n': 'b', 'f': 1.5},
          {'n': 'c', 'f': 1.33},
        ],
      });
      expect(r.components.map((c) => c.factor), ['2', '1.5', '1.33']);
    });
  });

  group('судьи сегмента', () {
    List<ProtocolJudge> panel(Object? judges) {
      final j = sample();
      seg(j)['judges'] = judges;
      return ProtocolDoc.fromJson(j).categories.first.segments.first.panel;
    }

    test('список судей читается', () {
      final p = panel([
        {'no': 'J1', 'name': 'Мария ПЕТРОВА', 'nation': 'RUS'},
        {'no': 'J2', 'name': 'Иван СИДОРОВ'},
      ]);
      expect(p.map((j) => (j.no, j.name, j.nation)), [('J1', 'Мария ПЕТРОВА', 'RUS'), ('J2', 'Иван СИДОРОВ', '')]);
    });

    test('поля нет, null, пусто или мусор — судей нет, сегмент цел', () {
      expect(panel(null), isEmpty);
      expect(panel([]), isEmpty);
      expect(panel(['a', 1, {}, {'nation': 'RUS'}]), isEmpty);
      final j = sample();
      seg(j)['judges'] = {'no': 'J1'};
      expect(ProtocolDoc.fromJson(j).categories.first.segments.first.state, SegmentState.finalized);
    });

    test('ссылка на оценки (строка в judges) по-прежнему читается как адрес, судей нет', () {
      final s = ProtocolDoc.fromJson(sample()).categories.first.segments.first;
      expect(s.judges, endsWith('.pdf'));
      expect(s.panel, isEmpty);
    });

    test('список судей не ломает строки сегмента', () {
      final j = sample();
      seg(j)['judges'] = [
        {'no': 'J1', 'name': 'Мария ПЕТРОВА'},
      ];
      final s = ProtocolDoc.fromJson(j).categories.first.segments.first;
      expect(s.judges, isNull);
      expect(s.rows, hasLength(2));
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
