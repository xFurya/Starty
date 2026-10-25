import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starty/data.dart';
import 'package:starty/reminders.dart';

void main() {
  final data = Schedule.parse(File('test/events_sample.json').readAsStringSync());
  final now = DateTime.parse('2026-10-09T15:40:00+03:00');
  NotifyPlan plan([NotifyRules r = const NotifyRules(), Set<String> on = const {}, Set<String> off = const {}]) =>
      NotifyPlan(r, on, off);
  Start byTitle(String t) => data.starts.firstWhere((e) => e.title == t);
  final womenFs = byTitle('CS Denis Ten Memorial — женщины ПП');

  test('по умолчанию — каждый будущий старт, за 15 минут', () {
    final p = Reminders.plan(data, plan(), now);
    final future = data.starts.where((s) => s.t1.isAfter(now)).length;
    expect(p.length, future > 60 ? 60 : future);
    final x = p.firstWhere((x) => x.startId == womenFs.id);
    expect(x.at, womenFs.t0.subtract(const Duration(minutes: 15)));
    expect(x.title, '17:30 — Женщины, произвольная программа');
    expect(x.lines.first, 'CS Denis Ten Memorial');
    expect(x.lines, contains('20:32 — Александра Трусова'));
    expect(x.group, womenFs.tid);
    expect(x.reminder, isFalse);
  });

  test('только одиночники', () {
    final r = const NotifyRules().copyWith(kinds: {'women', 'men'});
    final p = Reminders.plan(data, plan(r), now);
    expect(p, isNotEmpty);
    for (final x in p) {
      expect(['women', 'men'], contains(data.byId(x.startId)!.kind));
    }
  });

  test('уровень, турниры и программы', () {
    final r = const NotifyRules().copyWith(levels: {'senior'}, russian: false, segs: {'free'});
    for (final x in Reminders.plan(data, plan(r), now)) {
      final s = data.byId(x.startId)!;
      expect(s.level, 'senior');
      expect(s.intl, isTrue);
      expect(['ПП', 'ПТ'], contains(s.seg));
    }
  });

  test('без ночных стартов — ничего до 08:00 МСК', () {
    final all = Reminders.plan(data, plan(), now);
    final r = const NotifyRules().copyWith(night: false);
    final day = Reminders.plan(data, plan(r), now);
    for (final x in day) {
      expect(msk(data.byId(x.startId)!.t0).hour, greaterThanOrEqualTo(8));
    }
    final nights = all.where((x) => msk(data.byId(x.startId)!.t0).hour < 8).length;
    expect(day.length, all.length - nights);
  });

  test('за час до начала', () {
    final r = const NotifyRules().copyWith(lead: 60);
    final x = Reminders.plan(data, plan(r), now).firstWhere((x) => x.startId == womenFs.id);
    expect(msk(x.at).hour, 16);
    expect(msk(x.at).minute, 30);
  });

  test('исключения: выключенный старт молчит, включённый звучит вопреки правилам', () {
    final off = Reminders.plan(data, plan(const NotifyRules(), {}, {womenFs.id}), now);
    expect(off.any((x) => x.startId == womenFs.id), isFalse);
    final r = const NotifyRules().copyWith(kinds: {'pairs'});
    final on = Reminders.plan(data, plan(r, {womenFs.id}), now);
    expect(on.any((x) => x.startId == womenFs.id), isTrue);
  });

  test('общий выключатель гасит всё, включая исключения', () {
    final r = const NotifyRules().copyWith(on: false);
    expect(Reminders.plan(data, plan(r, {womenFs.id}), now), isEmpty);
  });

  test('выход наших — только если включено, за то же время до выхода', () {
    expect(Reminders.plan(data, plan(), now).any((x) => x.key.startsWith('k:')), isFalse);
    final r = const NotifyRules().copyWith(skaters: true);
    final x = Reminders.plan(data, plan(r), now).firstWhere((x) => x.title == 'В 20:32 выходит Александра Трусова');
    expect(msk(x.at).hour, 20);
    expect(msk(x.at).minute, 17);
    expect(x.lines, ['CS Denis Ten Memorial, женщины, произвольная программа']);
    expect(x.collapsed, x.lines.single);
    expect(x.reminder, isTrue);
  });

  test('выход спортсмена: закреплено, пока не откатал, потом смахивается и убирается само', () {
    final r = const NotifyRules().copyWith(skaters: true);
    final x = Reminders.plan(data, plan(r), now).firstWhere((x) => x.title == 'В 20:32 выходит Александра Трусова');
    final skate = x.at.add(const Duration(minutes: 15));
    expect(x.hold, skate.add(Reminders.skated));
    // последняя в разминке: убрать через 15 мин — позже конца старта, значит в конце старта
    expect(x.end, womenFs.t1);
    expect(skate.add(const Duration(minutes: 15)).isAfter(womenFs.t1), isTrue);
    final start = Reminders.plan(data, plan(r), now).firstWhere((x) => x.key == 's:${womenFs.id}');
    expect(start.hold, womenFs.t1);
    // не закреплять — смахиваются сразу; не убирать — висят до конца старта
    final loose = Reminders.plan(data, plan(r.copyWith(pin: false, clear: false)), now)
        .firstWhere((x) => x.title == 'В 20:32 выходит Александра Трусова');
    expect(loose.hold, loose.at);
    expect(loose.end, womenFs.t1);
  });

  test('без дубликатов: у кого своё уведомление о выходе, того нет в уведомлении о старте', () {
    final r = const NotifyRules().copyWith(skaters: true);
    final p = Reminders.plan(data, plan(r), now);
    final start = p.firstWhere((x) => x.key == 's:${womenFs.id}');
    expect(start.lines.any((l) => l.contains('Трусова')), isFalse);
    expect(start.collapsed.contains('Трусова'), isFalse);
    expect(p.where((x) => x.title.contains('Трусова') || x.lines.any((l) => l.contains('Трусова'))).length, 1);
    // ни одно уведомление не повторяет другое
    final seen = <String>{};
    for (final x in p) {
      expect(seen.add('${x.title}|${x.lines.join('/')}'), isTrue, reason: x.title);
    }
  });

  group('тексты уведомлений', () {
    Start start({String title = 'CS Budapest Trophy — танцы РТ', String level = 'senior', List<Map<String, Object>> ours = const []}) =>
        Start.fromJson({
          'id': 'b', 'tid': 'budapest', 'tournament': 'CS Budapest Trophy', 'kind': 'dance', 'level': level, 'seg': 'РТ',
          'title': title, 'start': '2026-10-17T17:45:00+03:00', 'end': '2026-10-17T21:30:00+03:00',
          'venue': '', 'intl': true, 'ours': ours,
        });
    const two = [
      {'name': 'Василиса Кузьмина / Андрей Студеникин', 'time': '19:04'},
      {'name': 'Софья Григорьева / Андрей Артющенко', 'time': '20:48'},
    ];

    test('старт: вид полностью и время в заголовке, турнир, по строке на отслеживаемого', () {
      final t = Reminders.startText(start(ours: two));
      expect(t.title, '17:45 — Танцы, ритм-танец');
      expect(t.lines, ['CS Budapest Trophy', '19:04 — Кузьмина / Студеникин', '20:48 — Григорьева / Артющенко']);
      expect(t.collapsed, 'Кузьмина / Студеникин в 19:04 и ещё 1');
    });

    test('старт: один отслеживаемый — без «и ещё»', () {
      final t = Reminders.startText(start(ours: [two.first]));
      expect(t.collapsed, 'Кузьмина / Студеникин в 19:04');
      expect(t.lines, ['CS Budapest Trophy', '19:04 — Кузьмина / Студеникин']);
    });

    test('старт идёт: вместо времени начала — статус, как метка на карточке', () {
      final t = Reminders.startText(start(ours: two));
      expect(Reminders.liveMark, '🔴\u00A0ИДЁТ');
      expect(t.live, '🔴\u00A0ИДЁТ — Танцы, ритм-танец');
      expect(t.live, isNot(matches(r'\d{1,2}:\d\d')));
      // строки и свёрнутый вид — те же
      expect(t.lines, ['CS Budapest Trophy', '19:04 — Кузьмина / Студеникин', '20:48 — Григорьева / Артющенко']);
      expect(t.collapsed, 'Кузьмина / Студеникин в 19:04 и ещё 1');
      final j = Reminders.startText(start(title: 'CS Budapest Trophy — юниорские танцы РТ', level: 'junior'));
      expect(j.live, '🔴\u00A0ИДЁТ — Юниорские танцы, ритм-танец');
    });

    test('старт без отслеживаемых: строка — турнир', () {
      final t = Reminders.startText(start());
      expect(t.title, '17:45 — Танцы, ритм-танец');
      expect(t.lines, ['CS Budapest Trophy']);
      expect(t.collapsed, 'CS Budapest Trophy');
    });

    test('время выхода ещё неизвестно — имя без времени', () {
      final t = Reminders.startText(start(ours: [{'name': 'Василиса Кузьмина / Андрей Студеникин'}]));
      expect(t.lines.last, 'Кузьмина / Студеникин');
      expect(t.collapsed, 'Кузьмина / Студеникин');
    });

    test('юниоры: уровень в названии вида', () {
      final t = Reminders.startText(start(title: 'CS Budapest Trophy — юниорские танцы РТ', level: 'junior'));
      expect(t.title, '17:45 — Юниорские танцы, ритм-танец');
      final girls = Reminders.startText(start(title: 'CS Budapest Trophy — девушки КП', level: 'junior'));
      expect(girls.title, '17:45 — Девушки, короткая программа');
    });

    test('длинные пары не режутся и не склеиваются', () {
      const long = {'name': 'Елизавета Худайбердиева-Лебедева / Егор Базин-Ахметов', 'time': '21:07'};
      final s = start(ours: [long, ...two]);
      final t = Reminders.startText(s);
      expect(t.lines[1], '21:07 — Худайбердиева-Лебедева / Базин-Ахметов');
      expect(t.collapsed, 'Худайбердиева-Лебедева / Базин-Ахметов в 21:07 и ещё 2');
      final k = Reminders.skaterText(s, s.ours.first);
      expect(k.title, 'В 21:07 выходят Худайбердиева-Лебедева / Базин-Ахметов');
    });

    test('выход спортсмена: кто и когда в заголовке, строка — турнир, вид, программа', () {
      final s = start(ours: two);
      final t = Reminders.skaterText(s, s.ours.first);
      expect(t.title, 'В 19:04 выходят Кузьмина / Студеникин');
      expect(t.lines, ['CS Budapest Trophy, танцы, ритм-танец']);
      final j = start(title: 'CS Budapest Trophy — юниорские танцы РТ', level: 'junior', ours: two);
      expect(Reminders.skaterText(j, j.ours.last).lines, ['CS Budapest Trophy, юниорские танцы, ритм-танец']);
    });

    test('iPhone и Mac: подзаголовок — турнир, текст построчно', () {
      final s = start(ours: two);
      final t = Reminders.startText(s);
      final p = Planned(
        key: 's:b', at: s.t0, hold: s.t1, end: s.t1, title: t.title, lines: t.lines, collapsed: t.collapsed,
        startId: s.id, group: s.tid, groupTitle: s.tournament, reminder: false,
      );
      expect(p.subtitle, 'CS Budapest Trophy');
      expect(p.body, '19:04 — Кузьмина / Студеникин\n20:48 — Григорьева / Артющенко');
      final none = Reminders.startText(start());
      final q = Planned(
        key: 's:b', at: s.t0, hold: s.t1, end: s.t1, title: none.title, lines: none.lines, collapsed: none.collapsed,
        startId: s.id, group: s.tid, groupTitle: s.tournament, reminder: false,
      );
      // без отслеживаемых текст не пустой: турнир в нём, а не в подзаголовке
      expect(q.subtitle, '');
      expect(q.body, 'CS Budapest Trophy');
    });

    test('ни в одном тексте нет « · »', () {
      final r = const NotifyRules().copyWith(skaters: true);
      final all = Reminders.plan(data, plan(r), now);
      expect(all.any((x) => x.key.startsWith('k:')), isTrue);
      for (final x in all) {
        for (final t in [x.title, x.liveTitle, x.collapsed, x.subtitle, x.body, x.text, ...x.lines]) {
          expect(t, isNot(contains('·')), reason: t);
        }
      }
    });
  });

  test('прошедшее не планируется', () {
    final past = data.starts.firstWhere((e) => e.t1.isBefore(now));
    expect(Reminders.plan(data, plan(const NotifyRules(), {past.id}), now).any((x) => x.startId == past.id), isFalse);
  });

  test('правила сохраняются и читаются, мусор — правила по умолчанию', () {
    final r = const NotifyRules().copyWith(lead: 30, kinds: {'dance'}, night: false, skaters: true, pin: false, onlyFollowed: true, gone: 30);
    final back = NotifyRules.fromJson(r.toJson());
    expect(back.lead, 30);
    expect(back.kinds, {'dance'});
    expect(back.night, isFalse);
    expect(back.skaters, isTrue);
    expect(back.pin, isFalse);
    expect(back.clear, isTrue);
    expect(back.onlyFollowed, isTrue);
    expect(back.gone, 30);
    expect(NotifyRules.fromJson('{oops').isDefault, isTrue);
    expect(NotifyRules.fromJson('{"lead": 7}').lead, 15);
    expect(NotifyRules.fromJson(null).on, isTrue);
  });

  test('идущий старт остаётся в плане с концом — показанное уведомление не снимается', () {
    final live = data.starts.firstWhere((e) => e.t0.isBefore(now) && e.t1.isAfter(now));
    final x = Reminders.plan(data, plan(), now).firstWhere((x) => x.startId == live.id);
    expect(x.at.isBefore(now), isTrue);
    expect(x.end, live.t1);
  });

  test('заголовок о старте: до начала — время начала, во время старта — статус без времени', () {
    final x = Reminders.plan(data, plan(), now).firstWhere((x) => x.startId == womenFs.id);
    expect(x.liveAt, womenFs.t0);
    for (final t in [x.at, womenFs.t0.subtract(const Duration(seconds: 1))]) {
      expect(x.titleAt(t), '17:30 — Женщины, произвольная программа');
    }
    for (final t in [womenFs.t0, womenFs.t0.add(const Duration(hours: 1)), womenFs.t1.subtract(const Duration(minutes: 1))]) {
      final title = x.titleAt(t);
      expect(title, '${Reminders.liveMark} — Женщины, произвольная программа');
      expect(title, isNot(matches(r'\d{1,2}:\d\d')));
      expect(title, contains('🔴'));
      expect(title, contains('ИДЁТ'));
    }
    // уже идущий старт — тоже со статусом
    final live = data.starts.firstWhere((e) => e.t0.isBefore(now) && e.t1.isAfter(now));
    final y = Reminders.plan(data, plan(), now).firstWhere((x) => x.startId == live.id);
    expect(y.titleAt(now), startsWith(Reminders.liveMark));
    // выход спортсмена не меняется
    final r = const NotifyRules().copyWith(skaters: true);
    final k = Reminders.plan(data, plan(r), now).firstWhere((x) => x.title == 'В 20:32 выходит Александра Трусова');
    expect(k.liveTitle, isEmpty);
    expect(k.titleAt(womenFs.t0.add(const Duration(hours: 1))), k.title);
  });

  test('место без многоточия у города', () {
    final json = File('test/events_sample.json').readAsStringSync().replaceAll('"Almaty, Kazakhstan"', '"Almaty..., Kazakhstan"');
    final d = Schedule.parse(json);
    expect(d.starts.any((e) => e.venue.contains('...')), isFalse);
  });

  test('«только с отслеживаемыми»: старт с неопубликованным составом остаётся, с известным без них — нет', () {
    Start start(Map<String, dynamic> extra) => Start.fromJson({
      'id': 'x', 'tid': 't', 'tournament': 'T', 'kind': 'women', 'level': 'senior', 'seg': 'КП',
      'title': 'T — женщины КП', 'start': '2026-10-20T10:00:00+03:00', 'end': '2026-10-20T13:00:00+03:00',
      'venue': '', 'intl': false, 'ours': [], ...extra,
    }).withFollow(Follow(const []));
    final rules = const NotifyRules().copyWith(onlyFollowed: true);
    // состав неизвестен (расписание есть, стартового листа нет) — напомнить на всякий случай
    expect(rules.matches(start({})), isTrue);
    expect(start({}).compositionKnown, isFalse);
    // состав известен, отслеживаемых нет — не напоминать
    final known = start({'field': [{'name': 'Алиса Заикина', 'nation': 'СПБ'}], 'athletes': ['Алиса Заикина']});
    expect(rules.matches(known), isFalse);
    // состав известен, отслеживаемый есть
    final has = Start.fromJson({
      'id': 'y', 'tid': 't', 'tournament': 'T', 'kind': 'women', 'level': 'senior', 'seg': 'КП',
      'title': 'T — женщины КП', 'start': '2026-10-20T10:00:00+03:00', 'end': '2026-10-20T13:00:00+03:00',
      'venue': '', 'intl': false, 'ours': [],
      'field': [{'name': 'Алиса Заикина', 'nation': 'СПБ'}], 'athletes': ['Алиса Заикина'],
    }).withFollow(Follow(['Алиса Заикина']));
    expect(rules.matches(has), isTrue);
  });

  group('mergeJson: испорченный документ не меняет местные правила', () {
    final local = const NotifyRules(on: false, lead: 30).toJson();
    test('строка не разбирается — местные правила', () {
      expect(NotifyRules.mergeJson(local, '{"on": tr'), local);
    });
    test('не объект — местные правила', () {
      expect(NotifyRules.mergeJson(local, '[1, 2]'), local);
    });
    test('поля нет — остаётся местное, остальное берём из документа', () {
      final m = NotifyRules.fromJson(NotifyRules.mergeJson(local, '{"lead": 60}'));
      expect(m.on, isFalse);
      expect(m.lead, 60);
    });
    test('поле другого вида — местное', () {
      expect(NotifyRules.fromJson(NotifyRules.mergeJson(local, '{"on": "нет"}')).on, isFalse);
    });
    test('значение вне допустимых — местное', () {
      expect(NotifyRules.fromJson(NotifyRules.mergeJson(local, '{"lead": 7}')).lead, 30);
    });
    test('полный документ — берём его целиком', () {
      final remote = const NotifyRules(on: true, lead: 5, kinds: {'men'}).toJson();
      final m = NotifyRules.fromJson(NotifyRules.mergeJson(local, remote));
      expect(m.on, isTrue);
      expect(m.lead, 5);
      expect(m.kinds, {'men'});
    });
  });
}
