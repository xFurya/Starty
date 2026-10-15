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

  test('по умолчанию — каждый будущий старт, за 15 минут, текст как в 1.0.1', () {
    final p = Reminders.plan(data, plan(), now);
    final future = data.starts.where((s) => s.t1.isAfter(now)).length;
    expect(p.length, future > 60 ? 60 : future);
    final x = p.firstWhere((x) => x.startId == womenFs.id);
    expect(x.at, womenFs.t0.subtract(const Duration(minutes: 15)));
    expect(x.title, '17:30 · женщины ПП');
    expect(x.body, startsWith('CS Denis Ten Memorial · '));
    expect(x.body, contains('20:32 Александра Трусова'));
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
    final x = Reminders.plan(data, plan(r), now).firstWhere((x) => x.title == '20:32 · Александра Трусова');
    expect(msk(x.at).hour, 20);
    expect(msk(x.at).minute, 17);
    expect(x.body, 'женщины ПП · CS Denis Ten Memorial');
  });

  test('выход спортсмена: закреплено, пока не откатал, потом смахивается и убирается само', () {
    final r = const NotifyRules().copyWith(skaters: true);
    final x = Reminders.plan(data, plan(r), now).firstWhere((x) => x.title == '20:32 · Александра Трусова');
    final skate = x.at.add(const Duration(minutes: 15));
    expect(x.hold, skate.add(Reminders.skated));
    // последняя в разминке: убрать через 15 мин — позже конца старта, значит в конце старта
    expect(x.end, womenFs.t1);
    expect(skate.add(const Duration(minutes: 15)).isAfter(womenFs.t1), isTrue);
    final start = Reminders.plan(data, plan(r), now).firstWhere((x) => x.key == 's:${womenFs.id}');
    expect(start.hold, womenFs.t1);
    // не закреплять — смахиваются сразу; не убирать — висят до конца старта
    final loose = Reminders.plan(data, plan(r.copyWith(pin: false, clear: false)), now)
        .firstWhere((x) => x.title == '20:32 · Александра Трусова');
    expect(loose.hold, loose.at);
    expect(loose.end, womenFs.t1);
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
