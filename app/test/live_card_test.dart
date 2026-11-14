// Живое уведомление (live_card.dart): что видно на табло — во что превращается уведомление.
// Состав — мужская короткая этапа Гран-при России в Омске 14.11.2026 (как в pace_test).
import 'package:flutter_test/flutter_test.dart';
import 'package:starty/data.dart';
import 'package:starty/live.dart';
import 'package:starty/live_card.dart';

const _field = [
  ('Артемий Маринин', '14:32', 1, 1),
  ('Арсений Димитриев', '14:38', 2, 1),
  ('Михаил Полянский', '14:44', 3, 1),
  ('Александр Мельников', '14:50', 4, 1),
  ('Фёдор Зонов', '14:55', 5, 1),
  ('Илья Мавлянов', '15:01', 6, 1),
  ('Илья Строганов', '15:15', 7, 2),
  ('Илья Неретин', '15:20', 8, 2),
  ('Лев Лазарев', '15:32', 10, 2),
  ('Николай Угожаев', '15:38', 11, 2),
  ('Марк Кондратюк', '15:44', 12, 2),
];

DateTime msk(String hm) => DateTime.parse('2026-11-14T$hm:00+03:00');

Start start({List<String> ours = const ['Лев Лазарев']}) => Start.fromJson({
  'id': 'fsr:omsk:men-senior-kp',
  'tid': 'fsr:omsk',
  'tournament': 'Гран-при России «Сердце Сибири»',
  'kind': 'men',
  'level': 'senior',
  'seg': 'КП',
  'title': 'Гран-при России «Сердце Сибири» — мужчины КП',
  'start': '2026-11-14T14:25:00+03:00',
  'end': '2026-11-14T15:51:00+03:00',
  'venue': 'Омск',
  'intl': false,
  'field': [
    for (final f in _field) {'name': f.$1, 'nation': 'МОС', 'time': f.$2, 'no': f.$3, 'warmup': f.$4},
  ],
  'ours': [
    for (final f in _field)
      if (ours.contains(f.$1)) {'name': f.$1, 'nation': 'МОС', 'time': f.$2, 'no': f.$3, 'warmup': f.$4},
  ],
  'live': {'idx': 'https://fsrussia.ru/results/2627/5etap_sen/index.htm', 'seg': 'https://fsrussia.ru/results/2627/5etap_sen/SEG001.htm', 'names': {}},
});

/// Табло: выступили [names] с баллами по убыванию (первый — лидер), далее — [next].
LiveOk board(List<String> names, {String? next, bool warmup = false, String stamp = '14:49'}) {
  final rows = [for (var i = 0; i < names.length; i++) Placing(i + 1, names[i], 'МОС', (90 - i * 3.5).toStringAsFixed(2))];
  return LiveOk(
    podium: rows.take(3).toList(),
    provisional: true,
    rows: rows,
    places: {for (final r in rows) norm(r.name): r.place},
    stamp: msk(stamp),
    next: next,
    warmup: warmup,
  );
}

void main() {
  test('идёт: на льду и далее, тройка с баллами, наш — со временем выхода, полоса по разминкам', () {
    final tr = LiveTrack()
      ..note(board(['Михаил Полянский', 'Артемий Маринин', 'Арсений Димитриев'], next: 'Александр Мельников'), msk('14:49'));
    final now = msk('14:51');
    final c = liveCard(tr.apply(start(), now), track: tr, now: now);
    expect(c['state'], 'live');
    expect(c['title'], 'Мужчины, короткая программа');
    expect(c['count'], '3 из 11');
    // выступили трое, четвёртый на льду, разминки разделены, наш (Лазарев) — заглавной
    expect(c['dots'], 'ddditt|ttTtt');
    final rows = c['rows'] as List;
    expect(rows[0], ['НА ЛЬДУ', 'Александр Мельников', 'с 14:49']);
    expect((rows[1] as List).sublist(0, 2), ['ДАЛЕЕ', 'Фёдор Зонов']);
    expect((rows[1] as List)[2], startsWith('≈'));
    expect(c['top'], [
      ['1', 'Михаил Полянский', '90.00', ''],
      ['2', 'Артемий Маринин', '86.50', ''],
      ['3', 'Арсений Димитриев', '83.00', ''],
    ]);
    final mine = (c['mine'] as List).single as List;
    expect(mine.sublist(0, 2), ['', 'Лев Лазарев']);
    expect(mine[2], startsWith('≈'));
    expect(c['foot'], startsWith('Табло от 14:49'));
    expect(c['line'], 'На льду — Александр Мельников');
  });

  test('разминка до первого выхода: «РАЗМИНКА», кто первым, бледная метка на полосе', () {
    final tr = LiveTrack()..note(const LiveNone(next: 'Артемий Маринин', warmup: true), msk('14:26'));
    final now = msk('14:27');
    final c = liveCard(tr.apply(start(), now), track: tr, now: now);
    final rows = c['rows'] as List;
    expect(rows[0], ['РАЗМИНКА', '1-я группа', 'с 14:26']);
    expect((rows[1] as List).sublist(0, 2), ['ПЕРВЫМ', 'Артемий Маринин']);
    expect(c['dots'], 'wttttt|ttTtt');
    expect(c['line'], 'Разминка 1-й группы');
    expect(c['top'], isEmpty);
    expect(c['count'], '0 из 11');
  });

  test('наш выступил: место и баллы, в тройке — отмечен; снявшийся — «x» и не в счёте', () {
    final names = [for (final f in _field) f.$1]..remove('Илья Неретин');
    final done = names.take(8).toList(); // до Лазарева включительно, Неретин пропущен
    // баллы: Лазарев — лучший
    final order = ['Лев Лазарев', ...done.where((n) => n != 'Лев Лазарев')];
    final tr = LiveTrack()..note(board(order, next: 'Николай Угожаев'), msk('15:35'));
    final now = msk('15:36');
    final c = liveCard(tr.apply(start(), now), track: tr, now: now);
    expect(c['dots'], 'dddddd|dxDit');
    expect(c['count'], '8\u00A0из\u00A010');
    expect((c['top'] as List).first, ['1', 'Лев Лазарев', '90.00', '1']);
    expect(c['mine'], isEmpty, reason: 'наш уже в тройке — второй раз не повторяется');
  });

  test('все выступили — итог: «ИТОГ», первое место в строке, без отставания', () {
    final names = [for (final f in _field) f.$1];
    final tr = LiveTrack()..note(board(names, stamp: '15:50'), msk('15:50'));
    final now = msk('15:52');
    final c = liveCard(tr.apply(start(), now), track: tr, now: now);
    expect(c['state'], 'final');
    expect(c['line'], 'Первое место — Артемий Маринин, 90.00');
    expect(c['rows'], isEmpty);
    expect(c['foot'], 'Табло от 15:50');
  });

  test('табло назвало того же, а разминка кончилась — он на льду с этого момента', () {
    final tr = LiveTrack()
      ..note(const LiveNone(next: 'Артемий Маринин', warmup: true), msk('14:26'))
      ..note(const LiveNone(next: 'Артемий Маринин'), msk('14:32'));
    expect(tr.onIce?.warmup, isFalse);
    final now = msk('14:33');
    final c = liveCard(tr.apply(start(), now), track: tr, now: now);
    expect((c['rows'] as List).first, ['НА ЛЬДУ', 'Артемий Маринин', 'с 14:32']);
  });
}
