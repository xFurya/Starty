import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starty/live.dart';

String page(String f) => File('test/live/$f').readAsStringSync();

void main() {
  test('протокол сегмента с табло: места, имена, флаг, баллы', () {
    final rows = segmentResults(page('SEG002.htm'))!;
    expect(rows.length, greaterThanOrEqualTo(3));
    expect(rows[0].place, 1);
    expect(rows[0].name, 'Vladislav DIKIDZHI');
    expect(rows[0].nation, 'AIN2');
    expect(rows[0].points, '205.48');
    expect(rows[1].name, 'Gleb LUTFULLIN');
    expect(rows[2].points, '181.13');
  });

  test('протокол окончательный, когда у сегмента есть судейские оценки', () {
    final url = 'https://www.denistenmemorial.kz/results/SEG002.htm';
    expect(segmentFinal(page('index.htm'), url), isTrue);
    expect(segmentFinal(page('index_partial.htm'), url), isFalse);
    // у короткой программы оценки остались — она окончательная
    expect(segmentFinal(page('index_partial.htm'), 'https://www.denistenmemorial.kz/results/SEG001.htm'), isTrue);
  });

  test('итог вида: тройка и полнота', () {
    final (rows, complete) = categoryResults(page('CAT001RS.htm'));
    expect(complete, isTrue);
    expect(rows.first.name, 'Vladislav DIKIDZHI');
    expect(rows.first.points, '312.79');
  });

  test('стартовый лист — ещё не протокол', () {
    const start = '<table><tr><th>StN.</th><th>Name</th><th>Nation</th></tr>'
        '<tr><td>1</td><td>Ivan IVANOV</td><td>AIN2</td></tr></table>';
    expect(segmentResults(start), isNull);
  });

  group('несколько таблиц на странице во время старта', () {
    const segHead = '<tr><th>Pl.</th><th>Name</th><th>Nation</th><th>TSS</th><th>TES</th><th>PCS</th></tr>';
    const totHead = '<tr><th>Pl.</th><th>Name</th><th>Nation</th><th>Total</th><th>SP</th><th>FS</th></tr>';
    const total = '<table>$totHead'
        '<tr><td>1</td><td>Ivan SEMENOV</td><td>RUS</td><td>178.37</td><td>1</td><td>1</td></tr>'
        '<tr><td>2</td><td>Max GALKIN</td><td>RUS</td><td>169.82</td><td>2</td><td>2</td></tr></table>';
    const segment = '<table>$segHead'
        '<tr><td>1</td><td>Ivan SEMENOV</td><td>RUS</td><td>115.66</td><td>56.56</td><td>59.10</td></tr>'
        '<tr><td>2</td><td>Max GALKIN</td><td>RUS</td><td>114.72</td><td>52.78</td><td>61.94</td></tr></table>';

    test('берётся таблица сегмента, а не общий зачёт, в любом порядке', () {
      for (final page in [total + segment, segment + total]) {
        final rows = segmentResults(page)!;
        expect(rows.map((r) => r.name), ['Ivan SEMENOV', 'Max GALKIN']);
        expect(rows.map((r) => r.points), ['115.66', '114.72']);
      }
    });

    test('один человек — одна строка', () {
      const dup = '<table>$segHead'
          '<tr><td>1</td><td>A B</td><td>RUS</td><td>100.00</td><td>50.00</td><td>50.00</td></tr>'
          '<tr><td>1</td><td>A B</td><td>RUS</td><td>90.00</td><td>45.00</td><td>45.00</td></tr></table>';
      final rows = segmentResults(dup)!;
      expect(rows.length, 1);
      expect(rows.single.points, '100.00');
    });
  });

  test('фамилии капсом приводятся к обычному написанию', () {
    expect(titledName('Vladislav DIKIDZHI'), 'Vladislav Dikidzhi');
    expect(titledName('Даниил ЖОЛОБОВ'), 'Даниил Жолобов');
    expect(titledName('Anna SHCHERBAKOVA / Egor GONCHAROV'), 'Anna Shcherbakova / Egor Goncharov');
    expect(titledName('Ana Maria TORRES-LOPEZ'), 'Ana Maria Torres-Lopez');
  });
}
