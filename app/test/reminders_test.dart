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
    final future = data.starts.where((s) => s.t0.subtract(const Duration(minutes: 15)).isAfter(now)).length;
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

  test('прошедшее не планируется', () {
    final past = data.starts.firstWhere((e) => e.t1.isBefore(now));
    expect(Reminders.plan(data, plan(const NotifyRules(), {past.id}), now).any((x) => x.startId == past.id), isFalse);
  });

  test('правила сохраняются и читаются, мусор — правила по умолчанию', () {
    final r = const NotifyRules().copyWith(lead: 30, kinds: {'dance'}, night: false, skaters: true);
    final back = NotifyRules.fromJson(r.toJson());
    expect(back.lead, 30);
    expect(back.kinds, {'dance'});
    expect(back.night, isFalse);
    expect(back.skaters, isTrue);
    expect(NotifyRules.fromJson('{oops').isDefault, isTrue);
    expect(NotifyRules.fromJson('{"lead": 7}').lead, 15);
    expect(NotifyRules.fromJson(null).on, isTrue);
  });
}
