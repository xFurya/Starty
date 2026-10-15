import 'package:flutter_test/flutter_test.dart';
import 'package:starty/countries.dart';
import 'package:starty/data.dart';

void main() {
  test('поиск на любом алфавите', () {
    expect(nameMatches('Stefania Gladki', 'Гладки'), isTrue);
    expect(nameMatches('Stefania Gladki', 'глад'), isTrue);
    expect(nameMatches('Stefania Gladki', 'стефания гладки'), isTrue);
    expect(nameMatches('Mao Shimada', 'Шимада'), isTrue);
    expect(nameMatches('Илья Малинин', 'malinin'), isTrue);
    expect(nameMatches('Ilia Malinin', 'Илья'), isTrue);
    expect(nameMatches('Анастасия Метелкина / Лука Берулава', 'берулава'), isTrue);
    expect(nameMatches('Stefania Gladki', 'ладки'), isFalse);
    expect(nameMatches('Камила Валиева', 'Петрова'), isFalse);
  });

  test('один из пары находит старт пары', () {
    const starts = ['Анастасия Метелкина / Лука Берулава', 'Kaori Sakamoto'];
    expect(namesInclude(starts, 'Лука Берулава'), isTrue);
    expect(namesInclude(starts, 'kaori sakamoto'), isTrue);
    expect(namesInclude(starts, 'Лука'), isFalse);
  });

  test('юниоры — девушки и юноши, взрослые — женщины и мужчины', () {
    expect(personLine('FRA', 'W'), 'Франция · девушки');
    expect(personLine('RUS', 'w'), 'Россия · женщины');
    expect(personLine('JPN', 'M'), 'Япония · юноши');
    expect(personLine('RUS', 'P'), 'Россия · юниорские пары');
  });
}
