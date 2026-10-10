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
}
