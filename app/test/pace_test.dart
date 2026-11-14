// Поправка расписания по темпу (pace.dart) на составе мужской короткой программы этапа Гран-при
// России в Омске 14.11.2026: время по Москве, слот 5:50, вторая разминка, №9 снялся.
import 'package:flutter_test/flutter_test.dart';
import 'package:starty/data.dart';
import 'package:starty/live.dart';
import 'package:starty/pace.dart';
import 'package:starty/protocol_model.dart';
import 'package:starty/protocol_screen.dart' show waitingOf, timeLabel, asOf;

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

/// Сегмент; [done] — сколько первых по порядку уже с местом.
Start start({int done = 0, Set<String> skip = const {}}) {
  final field = [
    for (var i = 0; i < _field.length; i++)
      {
        'name': _field[i].$1,
        'nation': 'МОС',
        'time': _field[i].$2,
        'no': _field[i].$3,
        'warmup': _field[i].$4,
        if (i < done && !skip.contains(_field[i].$1)) 'place': i + 1,
        if (i < done && !skip.contains(_field[i].$1)) 'points': '80.00',
      },
  ];
  return Start.fromJson({
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
    'field': field,
    'podium': done > 0 ? [{'place': 1, 'name': _field[0].$1, 'nation': 'МОС', 'points': '80.00'}] : [],
    'provisional': done > 0,
    'live': {'idx': 'https://fsrussia.ru/results/2627/5etap_sen/index.htm', 'seg': 'https://fsrussia.ru/results/2627/5etap_sen/SEG001.htm', 'names': {}},
  });
}

String key(int i) => personKey(_field[i].$1);
String at(Pace p, int i) => hm(p.at[key(i)]!);

void main() {
  test('до начала: время — по расписанию, слот — по шаблону, вторая разминка — с перерывом', () {
    final p = paceOf(start(), now: msk('14:20'))!;
    expect(p.measured, isFalse);
    expect(p.slot.inSeconds, inInclusiveRange(5 * 60, 6 * 60));
    expect(at(p, 0), '14:32');
    expect(p.delay, Duration.zero);
    expect(p.late || p.early, isFalse);
    // первый второй разминки — по шаблону: перерыв из шаблона, а не слот
    expect(p.at[key(6)]!.difference(msk('15:15')).inMinutes.abs(), lessThanOrEqualTo(1));
    // поправка в пределах минуты — это и есть расписание: время не помечено как поправленное
    final s = start().withPace(p);
    expect(s.field.first.planned, isNull);
    expect(paceLine(p), isNull);
  });

  test('отстают на 7 минут: оставшиеся — от оценки последнего выступившего', () {
    // трое выступили; оценка третьего (Полянский, по расписанию выход 14:44) опубликована в 14:57
    final s = start(done: 3);
    final posted = {key(0): msk('14:45'), key(1): msk('14:51'), key(2): msk('14:57')};
    final p = paceOf(s, posted: posted, now: msk('14:58'))!;
    expect(p.next, key(3));
    expect(at(p, 3), '14:57');
    expect(p.late, isTrue);
    expect(p.delay.inMinutes, inInclusiveRange(6, 8));
    // по факту слот видно по двум промежуткам подряд (по шесть минут)
    expect(p.measured, isTrue);
    expect(p.slot, const Duration(minutes: 6));
    final paced = s.withPace(p);
    final mel = paced.field[3];
    expect(mel.planned, '14:50');
    expect(mel.time, '14:57');
    expect(paced.skateAt(mel, planned: true), msk('14:50'));
    // конец затягивается — карточка покажет «до ≈…»
    expect(paced.endPaced, isTrue);
    expect(paced.t1.isAfter(s.t1), isTrue);
    expect(paceLine(p), contains('Отставание от расписания ≈'));
    expect(paceShort(p), startsWith('отставание ≈'));
  });

  test('прокат затянулся: оценки всё нет — следующие сдвигаются от «сейчас»', () {
    // Мельников (№4) начал в 14:57, слот 6 минут — оценка ждалась к 15:03, а в 15:09 её всё нет
    final s = start(done: 3);
    final posted = {key(0): msk('14:45'), key(1): msk('14:51'), key(2): msk('14:57')};
    final p = paceOf(s, posted: posted, now: msk('15:09'))!;
    expect(at(p, 3), '14:57', reason: 'сам выступающий — уже на льду');
    expect(p.at[key(4)]!.isAfter(msk('15:09')), isTrue, reason: 'следующий — не раньше «сейчас»');
    expect(p.delay.inMinutes, greaterThanOrEqualTo(14), reason: 'отставание — по следующему, а не по выступающему');
    // экран протокола: выступающий — «сейчас», остальные — «≈»
    final paced = s.withPace(p);
    final left = waitingOf(paced, const []).where((o) => o.place == null).toList();
    expect(timeLabel(paced, left.firstWhere((o) => o.no == 4), t: msk('15:09')), 'сейчас');
    expect(timeLabel(paced, left.firstWhere((o) => o.no == 5), t: msk('15:09')), startsWith('≈'));
  });

  test('конец первой разминки: следующий — после перерыва на разминку, а не сразу', () {
    final s = start(done: 6);
    final posted = {for (var i = 0; i < 6; i++) key(i): msk('14:38').add(Duration(minutes: 6 * i))};
    final p = paceOf(s, posted: posted, now: msk('15:09'))!;
    // оценка Мавлянова в 15:08; перерыв между разминками по шаблону — около восьми минут
    final gap = p.at[key(6)]!.difference(msk('15:08')).inMinutes;
    expect(gap, inInclusiveRange(6, 10));
  });

  test('снялся раньше последнего выступившего — из очереди выпадает', () {
    // Димитриев (№2) без места, а Полянский (№3) уже выступил: Димитриев снялся
    final s = start(done: 3, skip: {'Арсений Димитриев'});
    final posted = {key(0): msk('14:38'), key(2): msk('14:44')};
    final p = paceOf(s, posted: posted, now: msk('14:45'))!;
    expect(p.at.containsKey(key(1)), isFalse);
    expect(p.next, key(3));
    final left = waitingOf(s, [
      const ProtocolRow(i: 1, place: 1, name: 'Артемий Маринин'),
      const ProtocolRow(i: 2, place: 2, name: 'Михаил Полянский'),
    ]);
    expect(left.map((o) => o.no), [4, 5, 6, 7, 8, 10, 11, 12]);
  });

  test('начало затянулось: первому давно пора получить оценку, а её нет — все сдвигаются', () {
    final p = paceOf(start(), posted: const {}, now: msk('14:50'))!;
    expect(at(p, 0), '14:32', reason: 'первый — «сейчас»: время его выхода по расписанию прошло');
    expect(p.at[key(1)]!.isAfter(msk('14:50')), isTrue);
    expect(p.late, isTrue);
  });

  test('все выступили — поправлять нечего, конец — оценка последнего', () {
    final s = start(done: _field.length);
    final p = paceOf(s, posted: {key(10): msk('15:58')}, now: msk('16:00'))!;
    expect(p.at, isEmpty);
    expect(p.end, msk('15:58'));
    expect(paceLine(p), isNull);
  });

  test('без шаблона и без оценок — оценки нет', () {
    final s = Start.fromJson({
      ...start().toJson(),
      'field': [
        for (final f in _field) {'name': f.$1, 'no': f.$3},
      ],
    });
    expect(paceOf(s, now: msk('14:20')), isNull);
  });

  test('время из расписания, выбившееся из порядка, — ошибка шаблона: его не берём', () {
    // Омск: «2 -я РАЗМИНКА» в PDF дала второму по счёту 15:07 вместо 14:38
    final s = Start.fromJson({
      ...start().toJson(),
      'field': [
        for (final f in _field) {'name': f.$1, 'no': f.$3, 'warmup': f.$4, 'time': f.$3 == 2 ? '15:07' : f.$2},
      ],
    });
    final p = paceOf(s, posted: const {}, now: msk('14:20'))!;
    expect(p.at[key(1)]!.isBefore(msk('14:44')), isTrue, reason: 'второй — между первым и третьим, а не в 15:07');
    expect(p.delay, Duration.zero);
    // отставание по нему видно и так: его время восстановлено по соседу и слоту
    final bad = Start.fromJson({
      ...start(done: 1).toJson(),
      'field': [
        for (final f in _field)
          {'name': f.$1, 'no': f.$3, 'warmup': f.$4, 'time': f.$3 == 2 ? '15:07' : f.$2, if (f.$3 == 1) 'place': 1, if (f.$3 == 1) 'points': '75.71'},
      ],
    });
    final late = paceOf(bad, posted: {key(0): msk('14:49')}, now: msk('14:50'))!;
    expect(late.next, key(1));
    expect(late.delay.inMinutes, inInclusiveRange(10, 12));
  });

  group('время табло', () {
    test('Last-Modified главнее, строка внизу страницы — с поясом машины табло', () {
      expect(boardStamp('x', lastModified: 'Sun, 08 Nov 2026 06:47:52 GMT'), DateTime.utc(2026, 11, 8, 6, 47, 52));
      expect(
        boardStamp('<p>Created by Swiss Timing, Ltd. &nbsp; Обновлено: 14.11.2026 19:07 (UTC &#x2B;08:00) &copy;</p>'),
        DateTime.utc(2026, 11, 14, 11, 7),
      );
      expect(boardStamp('<td>Last Update: 08.11.2026 14:48 (UTC -05:00)</td>'), DateTime.utc(2026, 11, 8, 19, 48));
      expect(boardStamp('<td>без времени</td>'), isNull);
    });

    test('на экране — «Табло от 14:52», без рассказа о сбоях; другой день — с датой', () {
      final t = now();
      expect(asOf(t, null), 'Табло от ${hm(t)}');
      expect(asOf(null, t), 'Обновлено ${hm(t)}');
      expect(asOf(t.subtract(const Duration(days: 3)), null), contains(', '));
      expect(asOf(null, null), '');
    });
  });
}
