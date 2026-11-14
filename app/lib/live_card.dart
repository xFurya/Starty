// Живое уведомление идущего старта (Android): уведомление о старте само меняется по ходу —
// полоса выступлений (выступили, на льду, кто ваш), кто на льду и кто далее со временем выхода по
// темпу, тройка лидеров с баллами, ваши — с местом или временем выхода, и время табло.
//
// Пока старт с уведомлением идёт, своя часть приложения (starty_alerts, LiveService) держит службу
// переднего плана и запускает здесь [runLiveCards]: тот же разбор табло (live.dart) и та же поправка
// по темпу (pace.dart), что в приложении, — без приложения на экране. Телефон сам читает табло
// турнира, а не ждёт сервер. Рисует уведомление Kotlin (Alerts.liveViews) по данным [liveCard].
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data.dart';
import 'live.dart';
import 'pace.dart';
import 'reminders.dart';
import 'ui.dart' show cap, displayName, nb;

/// Как часто служба спрашивает табло, если в настройках не реже: чаще не нужно — оценка за прокат
/// появляется раз в несколько минут, а «на льду» меняется раз в прокат.
const liveCardEveryMin = Duration(seconds: 20);

/// Расписание целиком — не чаще: из него окончательность сегмента (basis) и составы.
const liveCardScheduleEvery = Duration(minutes: 10);

/// Что устройство видело на табло одного старта: когда опубликована оценка каждого, время табло,
/// кто на льду. Те же правила, что у приложения (AppState.notePosted / noteOnIce).
class LiveTrack {
  final Map<String, DateTime> posted = {};
  DateTime? boardAt;
  ({String key, DateTime since, bool warmup})? onIce;
  LiveOk? last;
  DateTime polledAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Время табло — если правдоподобно (не из будущего и не слишком давнее), иначе момент, когда увидели.
  static DateTime _when(DateTime? stamp, DateTime at, Duration back) =>
      stamp != null && !stamp.isAfter(at.add(const Duration(minutes: 1))) && stamp.isAfter(at.subtract(back))
      ? (stamp.isAfter(at) ? at : stamp)
      : at;

  void note(LiveResult r, DateTime at) {
    final (next, stamp, warmup) = switch (r) {
      LiveOk o => (o.next, o.stamp, o.warmup),
      LiveNone n => (n.next, n.stamp, n.warmup),
      _ => (null, null, false),
    };
    if (r is LiveOk) {
      last = r;
      final when = _when(stamp, at, const Duration(hours: 6));
      for (final p in r.rows) {
        final k = personKey(p.name);
        if (k.isNotEmpty) posted.putIfAbsent(k, () => when);
      }
    }
    if (stamp != null) boardAt = stamp;
    if (next != null && next.isNotEmpty) {
      final k = personKey(next);
      final was = onIce;
      if (was == null || was.key != k || (was.warmup && !warmup)) {
        var since = _when(stamp, at, const Duration(hours: 1));
        if (was != null && since.isBefore(was.since)) since = at;
        onIce = (key: k, since: since, warmup: warmup);
      }
    }
  }

  /// Старт с тем, что видно на табло: места и баллы, время выхода оставшихся по темпу.
  Start apply(Start s, DateTime now) {
    final l = last;
    var out = l == null
        ? s
        : s.withResults(
            podium: l.podium,
            provisional: l.provisional,
            places: l.places,
            points: {for (final r in l.rows) if (r.points.isNotEmpty) norm(r.name): r.points},
            total: l.total,
            finals: l.finals,
          );
    if (out.field.length >= 2) {
      final p = paceOf(out, posted: posted, boardAt: boardAt ?? l?.stamp, onIce: onIce, now: now);
      if (p != null) out = out.withPace(p);
    }
    return out;
  }
}

String _name(String n) => displayName(n);

/// Данные живого уведомления. Строки — готовые: Kotlin только раскладывает их.
///  title, tour — вид с программой и турнир; count — «5 из 12»;
///  dots — полоса: по знаку на выступающего в порядке выхода, «|» между разминками: d — выступил,
///    i — на льду, w — его разминка идёт, t — ещё не выступал, x — снялся; заглавная — ваш;
///  rows — до двух строк [метка, имя, справа]: «НА ЛЬДУ», «РАЗМИНКА», «ДАЛЕЕ», «ЗАТЕМ»;
///  top — до трёх [место, имя, баллы, ваш ли («1»/«»)]; mine — ваши вне тройки [место или «», имя, баллы
///    или время выхода]; foot — «Табло от 16:15 · отставание ≈7 мин»; line — одна строка свёрнутого вида;
///  state — live или final.
Map<String, Object> liveCard(Start s, {LiveTrack? track, required DateTime now}) {
  final (disc, seg) = Reminders.discipline(s);
  final order = [...s.field];
  if (order.every((o) => o.no != null)) order.sort((a, b) => a.no!.compareTo(b.no!));
  final mine = {for (final o in s.ours) personKey(o.name)};
  bool own(String name) => mine.contains(personKey(name));
  final ice = track?.onIce;
  bool done(Skater o) => o.place != null;
  final lastDone = order.lastIndexWhere(done);
  // снялся: не выступил, а кто-то после него уже выступил, и табло не называет его следующим
  bool gone(int i) => !done(order[i]) && i < lastDone && personKey(order[i].name) != ice?.key;
  final onIceIdx = ice == null ? -1 : order.indexWhere((o) => personKey(o.name) == ice.key && !done(o));

  final dots = StringBuffer();
  for (var i = 0; i < order.length; i++) {
    final o = order[i];
    if (i > 0 && o.warmup != null && order[i - 1].warmup != null && o.warmup != order[i - 1].warmup) dots.write('|');
    final c = done(o)
        ? 'd'
        : gone(i)
        ? 'x'
        : i == onIceIdx
        ? (ice!.warmup ? 'w' : 'i')
        : 't';
    dots.write(own(o.name) ? c.toUpperCase() : c);
  }
  final doneN = order.where(done).length;
  final goneN = [for (var i = 0; i < order.length; i++) if (gone(i)) i].length;
  final total = order.length - goneN;

  String at(Skater o) {
    final t = s.skateAt(o);
    if (t == null) return '';
    return t.isAfter(now) ? '≈${hm(t)}' : 'скоро';
  }

  // кто дальше по очереди, после [from] (по порядку выхода)
  List<Skater> restAfter(int from) => [
    for (var i = from + 1; i < order.length; i++)
      if (!done(order[i]) && !gone(i)) order[i],
  ];
  final rows = <List<String>>[];
  if (onIceIdx >= 0 && !ice!.warmup) {
    final o = order[onIceIdx];
    rows.add(['НА ЛЬДУ', _name(o.name), 'с ${hm(ice.since)}']);
    final after = restAfter(onIceIdx);
    if (after.isNotEmpty) rows.add(['ДАЛЕЕ', _name(after.first.name), at(after.first)]);
  } else if (onIceIdx >= 0) {
    final o = order[onIceIdx];
    rows.add(['РАЗМИНКА', o.warmup == null ? 'идёт' : '${o.warmup}-я группа', 'с ${hm(ice!.since)}']);
    rows.add([doneN == 0 ? 'ПЕРВЫМ' : 'ДАЛЕЕ', _name(o.name), at(o)]);
  } else {
    final rest = restAfter(lastDone);
    if (rest.isNotEmpty) rows.add([doneN == 0 ? 'ПЕРВЫМ' : 'ДАЛЕЕ', _name(rest.first.name), at(rest.first)]);
    if (rest.length > 1) rows.add(['ЗАТЕМ', _name(rest[1].name), at(rest[1])]);
  }

  // тройка — по табло (там страна и баллы), без табло — по составу из расписания
  final placed = track?.last?.rows ??
      [
        for (final o in order)
          if (o.place != null) Placing(o.place!, o.name, o.nation, o.points ?? ''),
      ];
  final board = [...placed]..sort((a, b) => a.place.compareTo(b.place));
  final top = [
    for (final p in board.take(3)) ['${p.place}', _name(p.name), p.points, own(p.name) ? '1' : ''],
  ];
  final inTop = {for (final p in board.take(3)) personKey(p.name)};
  final ours = <List<String>>[];
  for (final o in order) {
    if (!own(o.name) || inTop.contains(personKey(o.name))) continue;
    final i = order.indexOf(o);
    if (done(o)) {
      ours.add(['${o.place}', _name(o.name), o.points ?? '']);
    } else if (gone(i)) {
      ours.add(['', _name(o.name), 'снялся']);
    } else if (i == onIceIdx) {
      ours.add(['', _name(o.name), ice!.warmup ? 'разминка' : 'на льду']);
    } else {
      ours.add(['', _name(o.name), at(o)]);
    }
  }

  final finished = lastDone >= 0 && restAfter(lastDone).isEmpty && onIceIdx < 0;
  final stamp = track?.boardAt ?? track?.last?.stamp;
  final lag = finished ? null : paceShort(s.pace);
  final foot = [if (stamp != null) 'Табло от ${hm(stamp)}', ?lag].join(' · ');

  final String line;
  if (finished && board.isNotEmpty) {
    line = 'Первое место — ${_name(board.first.name)}${board.first.points.isEmpty ? '' : ', ${board.first.points}'}';
  } else if (rows.isNotEmpty && rows.first.first == 'НА ЛЬДУ') {
    line = 'На льду — ${rows.first[1]}';
  } else if (rows.isNotEmpty && rows.first.first == 'РАЗМИНКА') {
    line = onIceIdx >= 0 && order[onIceIdx].warmup != null ? 'Разминка ${order[onIceIdx].warmup}-й группы' : 'Разминка';
  } else if (board.isNotEmpty) {
    line = 'Лидирует — ${_name(board.first.name)}${board.first.points.isEmpty ? '' : ', ${board.first.points}'}';
  } else if (rows.isNotEmpty) {
    line = '${cap(rows.first.first.toLowerCase())} — ${rows.first[1]}';
  } else {
    line = 'Старт идёт';
  }

  return {
    'v': 1,
    'state': finished ? 'final' : 'live',
    'title': [cap(disc), if (seg.isNotEmpty) seg].join(', '),
    'tour': s.tournament,
    'count': total > 0 ? '$doneN$nbиз$nb$total' : '',
    'dots': dots.toString(),
    'rows': rows,
    'top': top,
    'mine': ours.take(3).toList(),
    'more': ours.length > 3 ? ours.length - 3 : 0,
    'foot': foot,
    'line': line,
  };
}

/// Фоновый движок службы живого уведомления: спрашивает у своей части приложения, какие старты
/// сейчас с живым уведомлением, читает их табло и отдаёт данные карточки, пока такие старты есть.
/// Ошибка одного опроса не останавливает остальное: уведомление остаётся с прошлыми данными и
/// честным «Табло от …».
Future<void> runLiveCards({MethodChannel channel = const MethodChannel('starty/live')}) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final tracks = <String, LiveTrack>{};
  Schedule? raw;
  var fetched = DateTime.fromMillisecondsSinceEpoch(0);
  try {
    await Prefs.init();
    while (true) {
      final want = await channel.invokeMethod<List<Object?>>('starts') ?? const [];
      if (want.isEmpty) break;
      final p = await SharedPreferences.getInstance();
      await p.reload();
      final t = DateTime.now();
      if (raw == null || t.difference(fetched) >= liveCardScheduleEvery) {
        raw = await Repo.fetch() ?? raw ?? await Repo.cached();
        fetched = t;
      }
      final data = raw?.withFollow(Prefs.followOr(raw.watchlist));
      var every = Duration(seconds: Prefs.liveEvery);
      for (final w in want) {
        if (w is! Map) continue;
        final key = '${w['key']}', id = '${w['start']}';
        final s0 = data?.byId(id);
        if (s0 == null || s0.live == null) continue;
        final tr = tracks.putIfAbsent(id, LiveTrack.new);
        // «с сервера» (экономнее) — и здесь реже: раз в две минуты
        var mine = Duration(seconds: effectiveLiveEvery(Prefs.liveEvery, Prefs.liveEveryOver, id));
        if (effectiveLiveMode(Prefs.liveMode, Prefs.liveOverrides, id) == liveDelayed && mine < const Duration(minutes: 2)) {
          mine = const Duration(minutes: 2);
        }
        if (mine < every) every = mine;
        final now = DateTime.now();
        if (now.difference(tr.polledAt) >= mine - const Duration(seconds: 2)) {
          tr.note(await Live.poll(s0), now);
          tr.polledAt = now;
        }
        final s = tr.apply(s0, DateTime.now());
        await channel.invokeMethod('update', {'key': key, 'card': jsonEncode(liveCard(s, track: tr, now: DateTime.now()))});
      }
      await Future<void>.delayed(every < liveCardEveryMin ? liveCardEveryMin : every);
    }
  } catch (_) {}
  try {
    await channel.invokeMethod('idle');
  } catch (_) {}
}
