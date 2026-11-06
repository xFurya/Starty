// Фоновое обновление (Android раз в 15 минут, iPhone — когда его будит система): подтянуть расписание и
// переставить уведомления — новые старты, сдвиги времени, конец старта и время выхода наших
// появляются, когда приложение может быть закрыто. Часто — только маленький файл состояния
// (now.json); всё расписание — когда по нему что-то поменялось или прошло три часа. Места идущего
// старта (итоги ваших, подписка) — из того же файла, без всего расписания.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'billing.dart';
import 'data.dart';
import 'lineup.dart';
import 'month_widget.dart';
import 'reminders.dart';

/// Расписание для напоминаний: региональные старты — только если показ включён (как в ленте), затем под отслеживаемых.
Schedule remindersSchedule(Schedule raw, {required bool regional, required Follow follow}) {
  final shown = regional ? raw : raw.withStarts([for (final s in raw.starts) if (!s.regional) s]);
  return shown.withFollow(follow);
}

/// Всё расписание — не реже чем раз в столько, даже если файл состояния молчит (время выхода наших,
/// составы, старты дальше двух суток).
const fullEvery = Duration(hours: 3);

/// Файл состояния говорит, что пора тянуть всё расписание: у старта с уведомлением ([planned]:
/// id → [начало, конец] в мс, как в последнем расписании) сдвинулось время или он закончился,
/// либо появился старт, которого в последнем расписании не было ([known]).
bool nowChanged(Map<String, dynamic> now, Map<String, dynamic> planned, Set<String> known) {
  for (final e in now.entries) {
    final v = e.value;
    if (v is! Map) continue;
    if (!known.contains(e.key)) return true;
    final p = planned[e.key];
    if (p is! List || p.length < 2) continue;
    if (v['done'] == true || v['t0'] != p[0] || v['t1'] != p[1]) return true;
  }
  return false;
}

/// Места и баллы идущих стартов с уведомлениями — из файла состояния (r: имя → [место, баллы]),
/// в каноническом виде: изменились — пора поправить итоги ваших. Пусто — мест нет.
String resultsSig(Map<String, dynamic> now, Map<String, dynamic> planned) {
  final out = <String, Object>{};
  for (final id in planned.keys.toList()..sort()) {
    final v = now[id];
    final r = v is Map ? v['r'] : null;
    if (r is! Map || r.isEmpty) continue;
    out[id] = {for (final k in r.keys.map((k) => '$k').toList()..sort()) k: r[k]};
  }
  return out.isEmpty ? '' : jsonEncode(out);
}

/// Расписание с местами и баллами из файла состояния: у идущего старта — те, кто уже выступил.
/// Остальное — как было (файл несёт только места).
Schedule withNowResults(Schedule raw, Map<String, dynamic> now) {
  Start patch(Start s) {
    final v = now[s.id];
    final r = v is Map ? v['r'] : null;
    if (r is! Map || r.isEmpty) return s;
    final places = <String, int>{};
    final points = <String, String>{};
    for (final e in r.entries) {
      final x = e.value;
      if (x is! List || x.isEmpty || x.first is! int) continue;
      final k = norm('${e.key}');
      places[k] = x.first as int;
      if (x.length > 1 && x[1] is String && (x[1] as String).isNotEmpty) points[k] = x[1] as String;
    }
    return s.withResults(podium: s.podium, provisional: s.provisional, places: places, points: points);
  }

  return raw.withStarts([for (final s in raw.starts) patch(s)]);
}

/// Старты последнего расписания от суток назад до трёх суток вперёд — шире окна файла состояния,
/// чтобы старт, въехавший в окно, не считался новым.
List<String> knownIds(Schedule raw, DateTime t) => [
  for (final s in raw.starts)
    if (s.t1.isAfter(t.subtract(const Duration(hours: 24))) && s.t0.isBefore(t.add(const Duration(hours: 72)))) s.id,
];

Map<String, dynamic> _json(String? s) {
  try {
    final j = jsonDecode(s ?? '{}');
    return j is Map ? Map<String, dynamic>.from(j) : {};
  } catch (_) {
    return {};
  }
}

/// Где помним места идущих стартов, по которым уведомления уже переставлены (см. [resultsSig]).
const resultsSeenKey = 'bg.res';

/// Что делать: null — ничего; full — тянуть всё расписание; иначе — переставить уведомления по местам
/// из файла состояния [now] (итоги ваших), не загружая расписание.
Future<({bool full, Map<String, dynamic>? now})?> _due(SharedPreferences p, DateTime t) async {
  if (t.millisecondsSinceEpoch - (p.getInt('bg.full') ?? 0) >= fullEvery.inMilliseconds) return (full: true, now: null);
  final now = await Repo.fetchNow();
  if (now == null) return null;
  final known = {for (final x in (jsonDecode(p.getString('bg.known') ?? '[]') as List)) '$x'};
  final planned = _json(p.getString(Reminders.plannedKey));
  if (nowChanged(now, planned, known)) return (full: true, now: null);
  if (BillingState.resultsFor(p, t) && resultsSig(now, planned) != (p.getString(resultsSeenKey) ?? '')) {
    return (full: false, now: now);
  }
  return null;
}

@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      final p = await SharedPreferences.getInstance();
      // приложение могло записать своё, пока этот движок спал
      await p.reload();
      final t = DateTime.now();
      final due = await _due(p, t);
      if (due == null) return true;
      await Prefs.init();
      await Reminders.init();
      final fresh = due.full ? await Repo.fetch() : null;
      final cached = fresh ?? await Repo.cached();
      final raw = cached == null || due.now == null ? cached : withNowResults(cached, due.now!);
      final follow = Prefs.followOr(raw?.watchlist ?? const []);
      final data = raw == null ? null : remindersSchedule(raw, regional: Prefs.regional, follow: follow);
      // состав сверяется только со свежим расписанием; без него — уже найденное (иначе оно снимется)
      final lineup = await Lineup.update(p, fresh, follow, t, on: BillingState.lineupFor(p, t));
      await Reminders.sync(
        data,
        NotifyPlan(
          NotifyRules.fromJson(Prefs.rulesJson),
          Prefs.forcedOn,
          Prefs.forcedOff,
          digest: BillingState.digestFor(p, t),
          events: [for (final e in lineup) e.planned()],
          results: BillingState.resultsFor(p, t),
          updates: Reminders.updatesShown,
        ),
      );
      // после sync: список стартов с уведомлениями уже новый
      if (due.now != null) await p.setString(resultsSeenKey, resultsSig(due.now!, _json(p.getString(Reminders.plannedKey))));
      if (fresh != null) {
        await p.setInt('bg.full', t.millisecondsSinceEpoch);
        await p.setString('bg.known', jsonEncode(knownIds(fresh, t)));
        // виджет «Месяц» — новые старты и при закрытом приложении
        if (data != null) await widgetFromBackground(p, data, t);
      }
    } catch (_) {}
    return true;
  });
}

Future<void> scheduleBackground() async {
  if (kIsWeb || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS) return;
  try {
    await Workmanager().initialize(backgroundDispatcher);
    if (defaultTargetPlatform == TargetPlatform.android) {
      // update — у уже поставленной задачи сменится частота (раньше было раз в 3 часа), срок не сбрасывается
      await Workmanager().registerPeriodicTask(
        'refresh',
        'refresh',
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      // iOS запускает не чаще, чем сам решит (обычно несколько раз в сутки); идентификатор — как в Info.plist
      await Workmanager().registerPeriodicTask('refresh', 'refresh', initialDelay: const Duration(hours: 3));
    }
  } catch (_) {}
}
