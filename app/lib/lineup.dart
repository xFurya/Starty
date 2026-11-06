// Состав (подписка): жеребьёвка и перемены в составе у отслеживаемых — отдельными уведомлениями.
//  - жеребьёвка: у отслеживаемого появилось время выхода — «Аделия Петросян — 12-й номер, выход в 19:40»;
//  - в составе: отслеживаемый появился в заявке вида или турнира — «Аделия Петросян — в составе»;
//  - больше не в составе: был в заявке и пропал из неё (снялся, не прошёл в произвольную).
// Новое ищется сравнением с тем, что видели в прошлый раз (хранится на устройстве). Первый раз —
// только запоминаем: всё, что уже было, новостью не считается.
// Только отслеживаемые по имени: «все россияне на международных» дали бы десятки уведомлений.
// Сравнивается всё расписание с сервера, а не показанное: включённые региональные старты — не
// «появился в составе». Показываются уведомления только по турнирам, которые человек видит.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'data.dart';
import 'reminders.dart';
import 'ui.dart' show cap, displayName, nb;

/// Одно уведомление о составе: как [Planned], но хранится между запусками, пока не истечёт.
class LineupEvent {
  final String key;

  /// Когда замечено (показ сразу), до какого момента показывать пропущенное и когда убрать.
  final DateTime at, late, end;
  final String title;
  final List<String> lines;
  final String collapsed;

  /// Старт, к которому относится; у турнира без расписания — пусто.
  final String startId;

  /// Турнир: id и название.
  final String group, groupTitle;

  const LineupEvent({
    required this.key,
    required this.at,
    required this.late,
    required this.end,
    required this.title,
    required this.lines,
    required this.collapsed,
    required this.startId,
    required this.group,
    required this.groupTitle,
  });

  Planned planned() => Planned(
    key: key,
    at: at,
    hold: at,
    end: end,
    late: late,
    title: title,
    lines: lines,
    collapsed: collapsed,
    startId: startId,
    group: group,
    groupTitle: groupTitle,
    reminder: false,
  );

  Map<String, dynamic> toJson() => {
    'k': key,
    'at': at.millisecondsSinceEpoch,
    'late': late.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
    't': title,
    'l': lines,
    'c': collapsed,
    's': startId,
    'g': group,
    'gt': groupTitle,
  };

  static LineupEvent? tryFromJson(Object? raw) {
    try {
      final j = Map<String, dynamic>.from(raw as Map);
      DateTime ms(Object? v) => DateTime.fromMillisecondsSinceEpoch(v as int, isUtc: true);
      final lines = [for (final l in j['l'] as List) '$l'];
      if (lines.isEmpty) return null;
      return LineupEvent(
        key: j['k'] as String,
        at: ms(j['at']),
        late: ms(j['late']),
        end: ms(j['end']),
        title: j['t'] as String,
        lines: lines,
        collapsed: j['c'] as String? ?? lines.first,
        startId: j['s'] as String,
        group: j['g'] as String,
        groupTitle: j['gt'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}

class Lineup {
  /// Что видели в прошлый раз: отслеживаемые, по стартам и по турнирам без расписания — кто в заявке.
  static const seenKey = 'j.seen';

  /// Уведомления о составе, которые ещё не истекли.
  static const eventsKey = 'j.events';

  /// Уведомление висит не дольше суток: «в составе» через неделю — уже не новость.
  static const keep = Duration(hours: 24);

  /// Начавшиеся старты помним неделю: по ним видно, кто уже был в виде (вышел в произвольную —
  /// не «появился в составе»).
  static const remember = Duration(days: 7);

  /// Ключ человека: регистр, ё и пробелы не важны.
  static String key(String name) => norm(name).trim().replaceAll(RegExp(r'\s*/\s*'), ' / ').replaceAll(RegExp(r'\s+'), ' ');

  /// Вид турнира: турнир, дисциплина, разряд.
  static String _cat(Start s) => '${s.tid}|${s.kind}|${s.level}';

  static Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  /// Сравнить расписание с прошлым разом. [seen] — прошлое состояние; null — первый раз (только запоминаем).
  /// Возвращает новое состояние и новые уведомления.
  static ({Map<String, dynamic> seen, List<LineupEvent> fresh}) diff(
    Map<String, dynamic>? seen,
    Schedule raw,
    Follow follow,
    DateTime now,
  ) {
    final first = seen == null;
    // отслеживаемые прошлого раза: кого человек только что добавил, тот «в составе» не появляется
    final before = Follow([for (final x in (seen?['f'] is List ? seen!['f'] as List : const [])) '$x'], russians: false, belarusians: false);
    final prevStarts = _map(seen?['s']);
    final prevUp = _map(seen?['u']);
    // кого в прошлый раз видели в виде (по любому его старту) и в заявке турнира без расписания
    final knew = <String, Set<String>>{};
    for (final v in prevStarts.values) {
      final e = _map(v);
      knew.putIfAbsent('${e['c']}', () => {}).addAll(_map(e['p']).keys);
    }
    for (final e in prevUp.entries) {
      knew.putIfAbsent(e.key, () => {}).addAll(_map(_map(e.value)['p']).keys);
    }
    bool known(Start s, String k) => (knew[_cat(s)]?.contains(k) ?? false) || (knew[s.tid]?.contains(k) ?? false);

    final next = <String, dynamic>{}, nextUp = <String, dynamic>{};
    final fresh = <LineupEvent>[];
    // жеребьёвка — по старту, появления и исчезновения — по виду: снялся с турнира — одно уведомление
    final draws = <String, List<Skater>>{};
    final ins = <String, Map<String, (String, List<(Start, Skater)>)>>{};
    final outs = <String, Map<String, (String, List<Start>)>>{};
    final byId = <String, Start>{};
    final recent = now.subtract(remember);
    for (final s in raw.starts) {
      if (!s.t0.isAfter(recent)) continue;
      byId[s.id] = s;
      final prev = prevStarts.containsKey(s.id) ? _map(prevStarts[s.id]) : null;
      // состав пропал из файла целиком — сбой, а не снятие всех: помним прежний
      if (s.field.isEmpty) {
        if (prev != null) next[s.id] = prev;
        continue;
      }
      final cur = {for (final o in s.field) if (follow.has(o.name)) key(o.name): o};
      if (cur.isNotEmpty) {
        next[s.id] = {
          't': s.t0.millisecondsSinceEpoch,
          'c': _cat(s),
          'p': {for (final e in cur.entries) e.key: [e.value.name, e.value.time ?? '']},
        };
      }
      // начавшийся старт только помним
      if (first || !s.t0.isAfter(now)) continue;
      final had = prev == null ? const <String, dynamic>{} : _map(prev['p']);
      for (final e in cur.entries) {
        final o = e.value;
        final p = had[e.key];
        if (p is List && p.length >= 2) {
          // был без времени выхода, теперь с ним
          if (p[1] == '' && o.time != null) draws.putIfAbsent(s.id, () => []).add(o);
        } else if (known(s, e.key)) {
          // уже был в виде (вышел в произвольную) или в заявке турнира: новость — только время выхода
          if (o.time != null) draws.putIfAbsent(s.id, () => []).add(o);
        } else if (before.has(o.name)) {
          final c = ins.putIfAbsent(_cat(s), () => {});
          (c[e.key] ??= (o.name, [])).$2.add((s, o));
        }
      }
      for (final e in had.entries) {
        final v = e.value;
        if (cur.containsKey(e.key) || v is! List || v.isEmpty) continue;
        // перестал отслеживать — это его выбор, а не новость
        if (!follow.has('${v[0]}')) continue;
        final c = outs.putIfAbsent(_cat(s), () => {});
        (c[e.key] ??= ('${v[0]}', [])).$2.add(s);
      }
    }
    // старт пропал из расписания (сбой или переименование) — помним прежний состав: вернётся — не новость
    for (final e in prevStarts.entries) {
      if (byId.containsKey(e.key) || next.containsKey(e.key)) continue;
      final t = _map(e.value)['t'];
      if (t is int && t > recent.millisecondsSinceEpoch) next[e.key] = e.value;
    }

    // турниры без расписания: заявка целиком, без дисциплин
    final today = dayKey(now);
    final upNow = <String>{};
    for (final u in raw.upcoming) {
      if (u.end.compareTo(today) < 0) continue;
      upNow.add(u.tid);
      final prev = prevUp.containsKey(u.tid) ? _map(prevUp[u.tid]) : null;
      final all = [...u.ours, ...u.athletes];
      if (all.isEmpty) {
        if (prev != null) nextUp[u.tid] = prev;
        continue;
      }
      final cur = {for (final n in all) if (follow.has(n)) key(n): n};
      if (cur.isNotEmpty) nextUp[u.tid] = {'e': u.end, 'p': cur};
      // начавшийся турнир только помним
      if (first || u.start.compareTo(today) <= 0) continue;
      final had = prev == null ? const <String, dynamic>{} : _map(prev['p']);
      final joined = [for (final e in cur.entries) if (!had.containsKey(e.key) && before.has(e.value)) e.value];
      final left = [for (final e in had.entries) if (!cur.containsKey(e.key) && follow.has('${e.value}')) '${e.value}'];
      if (joined.isNotEmpty) fresh.add(_upcoming(u, joined, now, joined: true));
      if (left.isNotEmpty) fresh.add(_upcoming(u, left, now, joined: false));
    }
    // турнир ушёл из «скоро» (появилось расписание) — его заявку помним до конца турнира
    for (final e in prevUp.entries) {
      if (upNow.contains(e.key)) continue;
      final end = _map(e.value)['e'];
      if (end is String && end.compareTo(today) >= 0) nextUp[e.key] = e.value;
    }

    for (final e in draws.entries) {
      fresh.add(_draw(byId[e.key]!, e.value, now));
    }
    for (final e in ins.entries) {
      fresh.add(_change(e.key, e.value, now, joined: true));
    }
    for (final e in outs.entries) {
      fresh.add(_change(e.key, {for (final p in e.value.entries) p.key: (p.value.$1, [for (final s in p.value.$2) (s, null)])}, now, joined: false));
    }
    return (seen: {'f': follow.names.toList()..sort(), 's': next, 'u': nextUp}, fresh: fresh);
  }

  static String _short(String name) =>
      displayName(name.contains(' / ') ? name.split(' / ').map((p) => p.trim().split(' ').last).join(' / ') : name);

  /// «Женщины, короткая программа».
  static String _what(Start s) {
    final (disc, seg) = Reminders.discipline(s);
    return seg.isEmpty ? cap(disc) : '${cap(disc)}, $seg';
  }

  /// «Кубок России, женщины, короткая программа».
  static String _where(Start s, {bool seg = true}) {
    final (disc, sg) = Reminders.discipline(s);
    return [s.tournament, disc, if (seg && sg.isNotEmpty) sg].join(', ');
  }

  /// «14 ноября».
  static String _day(DateTime t) {
    final m = msk(t);
    return '${m.day}$nb${months[m.month - 1]}';
  }

  /// До какого момента уведомление показывать (и пропущенное тоже) и когда убрать: до [until] — начала старта
  /// или турнира (дальше «выход в 19:40» и «в составе» — уже не новость), но не дольше [keep].
  static DateTime _until(DateTime until, DateTime now) {
    final cap = now.add(keep);
    return until.isBefore(cap) ? until : cap;
  }

  /// Жеребьёвка. Один: «Аделия Петросян — 12-й номер, выход в 19:40», строка — «Жеребьёвка: турнир, вид, программа».
  /// Несколько: «Жеребьёвка: Женщины, короткая программа», строки — турнир и «19:40 — Аделия Петросян, 12-й номер».
  static LineupEvent _draw(Start s, List<Skater> list, DateTime now) {
    final until = _until(s.t0, now);
    final ppl = [...list]..sort((a, b) => (a.time ?? '').compareTo(b.time ?? ''));
    String no(Skater o) => o.no == null ? '' : '${o.no}-й номер';
    final String title;
    final List<String> lines;
    if (ppl.length == 1) {
      final o = ppl.single;
      title = '${_short(o.name)} — ${[no(o), 'выход в ${o.time}'].where((x) => x.isNotEmpty).join(', ')}';
      lines = ['Жеребьёвка: ${_where(s)}'];
    } else {
      title = 'Жеребьёвка: ${_what(s)}';
      lines = [s.tournament, for (final o in ppl) [('${o.time} — ${_short(o.name)}'), no(o)].where((x) => x.isNotEmpty).join(', ')];
    }
    return LineupEvent(
      key: 'j:draw:${s.id}:${[for (final o in ppl) key(o.name)].join(';')}',
      at: now,
      late: until,
      end: until,
      title: title,
      lines: lines,
      collapsed: ppl.length == 1 ? lines.first : '${lines[1]} и ещё ${ppl.length - 1}',
      startId: s.id,
      group: s.tid,
      groupTitle: s.tournament,
    );
  }

  /// «Аделия Петросян — в составе» / «Аделия Петросян — больше не в составе»; несколько — «В составе: Петросян, Трусова».
  /// Строка — турнир и вид; программа — если перемена в одном старте; у появления — день первого старта
  /// и время выхода, если оно одно и известно.
  static LineupEvent _change(
    String cat,
    Map<String, (String, List<(Start, Skater?)>)> people,
    DateTime now, {
    required bool joined,
  }) {
    final keys = people.keys.toList()..sort();
    final starts = {for (final p in people.values) for (final x in p.$2) x.$1.id: x.$1}.values.toList()
      ..sort((a, b) => a.t0.compareTo(b.t0));
    final s = starts.first;
    final names = [for (final k in keys) _short(people[k]!.$1)];
    final single = starts.length == 1;
    final only = people.length == 1 && single ? people[keys.single]!.$2.single.$2 : null;
    final where = [
      _where(s, seg: single),
      if (joined) _day(s.t0),
      if (joined && only?.time != null) 'выход в ${only!.time}',
    ].join(', ');
    final title = names.length == 1
        ? '${names.single} — ${joined ? 'в составе' : 'больше не в составе'}'
        : '${joined ? 'В составе' : 'Больше не в составе'}: ${names.join(', ')}';
    final until = _until(s.t0, now);
    return LineupEvent(
      key: 'j:${joined ? 'in' : 'out'}:$cat:${keys.join(';')}',
      at: now,
      late: until,
      end: until,
      title: title,
      lines: [where],
      collapsed: where,
      startId: single ? s.id : '',
      group: s.tid,
      groupTitle: s.tournament,
    );
  }

  /// Перемена в заявке турнира без расписания: строка — турнир и (у появления) день начала.
  static LineupEvent _upcoming(Upcoming u, List<String> people, DateTime now, {required bool joined}) {
    final names = [for (final n in people) _short(n)]..sort();
    final d = DateTime.tryParse(u.start);
    // полночь по Москве дня начала
    final starts = d == null ? null : DateTime.utc(d.year, d.month, d.day).subtract(const Duration(hours: 3));
    final until = _until(starts ?? now.add(keep), now);
    final where = [u.name, if (joined && starts != null) 'с ${_day(starts)}'].join(', ');
    return LineupEvent(
      key: 'j:${joined ? 'in' : 'out'}:${u.tid}:${([for (final n in people) key(n)]..sort()).join(';')}',
      at: now,
      late: until,
      end: until,
      title: names.length == 1
          ? '${names.single} — ${joined ? 'в составе' : 'больше не в составе'}'
          : '${joined ? 'В составе' : 'Больше не в составе'}: ${names.join(', ')}',
      lines: [where],
      collapsed: where,
      startId: '',
      group: u.tid,
      groupTitle: u.name,
    );
  }

  static Map<String, dynamic>? _seen(SharedPreferences p) {
    try {
      final s = p.getString(seenKey);
      if (s == null) return null;
      final j = jsonDecode(s);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }

  static List<LineupEvent> stored(SharedPreferences p) {
    try {
      final j = jsonDecode(p.getString(eventsKey) ?? '[]');
      return [if (j is List) for (final e in j) ?LineupEvent.tryFromJson(e)];
    } catch (_) {
      return const [];
    }
  }

  /// Сверить свежее расписание [raw] с прошлым разом и вернуть уведомления о составе, которые ещё не истекли.
  /// [raw] == null (расписание не пришло) — только сохранённые. Выключено ([on] == false: нет подписки или
  /// человек выключил) — всё забывается: после включения первый раз опять только запоминает.
  static Future<List<LineupEvent>> update(SharedPreferences p, Schedule? raw, Follow follow, DateTime now, {required bool on}) async {
    if (!on) {
      if (p.containsKey(seenKey)) await p.remove(seenKey);
      if (p.containsKey(eventsKey)) await p.remove(eventsKey);
      return const [];
    }
    var events = [for (final e in stored(p)) if (e.end.isAfter(now)) e];
    final r = raw == null ? null : diff(_seen(p), raw, follow, now);
    if (r != null) {
      final have = {for (final e in events) e.key};
      events = [...events, for (final e in r.fresh) if (!have.contains(e.key)) e];
    }
    // оба значения — разом, без ожидания между ними: параллельная сверка не должна прочитать новое
    // «видели» со старым списком уведомлений (найденное потерялось бы)
    await Future.wait([
      p.setString(eventsKey, jsonEncode([for (final e in events) e.toJson()])),
      if (r != null) p.setString(seenKey, jsonEncode(r.seen)),
    ]);
    return events;
  }
}
