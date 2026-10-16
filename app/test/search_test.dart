import 'package:flutter_test/flutter_test.dart';
import 'package:starty/countries.dart';
import 'package:starty/data.dart';
import 'package:starty/ui.dart';

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
    // страна — флагом с кодом у имени, в подписи только виды
    expect(kindsLine('W'), 'девушки');
    expect(kindsLine('w'), 'женщины');
    expect(kindsLine('M'), 'юноши');
    expect(kindsLine('wP'), 'женщины, юниорские пары');
  });

  test('отслеживаемые: россияне на международном и выбранные иностранцы; на российском — только выбранные', () {
    Map<String, dynamic> ev(bool intl) => {
      'id': 'x', 'tid': 't', 'tournament': 'T', 'kind': 'women', 'level': 'junior', 'seg': 'КП',
      'title': 'T — девушки КП', 'start': '2026-10-20T10:00:00+03:00', 'end': '2026-10-20T13:00:00+03:00',
      'venue': '', 'intl': intl, 'ours': [],
      'field': [
        {'name': 'Stefania Gladki', 'nation': 'FRA'},
        {'name': 'Алиса Заикина', 'nation': intl ? 'AIN2' : 'СПБ'},
        {'name': 'Mao Shimada', 'nation': 'JPN'},
      ],
    };
    final f = Follow(['Stefania Gladki']);
    final intl = Start.fromJson(ev(true)).withFollow(f);
    expect(intl.ours.map((o) => o.name), ['Stefania Gladki', 'Алиса Заикина']);
    expect(oursLabel(intl.ours), 'Россияне, отслеживаемые');
    final none = Start.fromJson(ev(true)).withFollow(Follow(const []));
    expect(none.ours.map((o) => o.name), ['Алиса Заикина']);
    final ru = Start.fromJson(ev(false)).withFollow(Follow(['Алиса Заикина']));
    expect(ru.ours.map((o) => o.name), ['Алиса Заикина']);
    // международный без россиян и отслеживаемых в ленту по умолчанию не идёт, но находится фильтром
    final bare = Start.fromJson({...ev(true), 'field': [{'name': 'Mao Shimada', 'nation': 'JPN'}]}).withFollow(Follow(const []));
    expect(bare.shown, isFalse);
    expect(Filters.none.pass(bare), isFalse);
    expect(const Filters({}, {}, {'Mao Shimada'}).pass(bare), isTrue);
  });

  test('вид под уровень: женщины — взрослые, девушки — юниорки', () {
    expect(kindLabel('women', {'junior'}), 'Девушки');
    expect(kindLabel('women', {'senior'}), 'Женщины');
    expect(kindLabel('women', const {}), 'Женщины (девушки)');
    expect(kindLabel('men', {'senior', 'junior'}), 'Мужчины (юноши)');
    expect(kindLabel('pairs', {'junior'}), 'Пары');
  });

  test('отслеживаемые: россиян и белорусов на международных можно выключить по отдельности', () {
    final st = Start.fromJson({
      'id': 'x', 'tid': 't', 'tournament': 'T', 'kind': 'women', 'level': 'senior', 'seg': 'КП',
      'title': 'T — женщины КП', 'start': '2026-10-20T10:00:00+03:00', 'end': '2026-10-20T13:00:00+03:00',
      'venue': '', 'intl': true, 'ours': [],
      'field': [
        {'name': 'Аделия Петросян', 'nation': 'AIN2'},
        {'name': 'Виктория Сафонова', 'nation': 'AIN1'},
      ],
    });
    expect(st.withFollow(Follow(const [], russians: false)).ours.map((o) => o.name), ['Виктория Сафонова']);
    expect(st.withFollow(Follow(const [], belarusians: false)).ours.map((o) => o.name), ['Аделия Петросян']);
    expect(st.withFollow(Follow(const [], russians: false, belarusians: false)).shown, isFalse);
  });
}
