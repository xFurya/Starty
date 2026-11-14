// Поправка расписания по темпу: когда на самом деле выйдут те, кто ещё не выступил.
//
// Расписание сегмента (PDF «Start List with Times») — шаблон: время выхода каждого, разминки, длина
// слота. Жизнь от него отходит: прокат затянулся, разминка началась позже, кто-то снялся. Поэтому
// время оставшихся считается от последнего факта, а не от бумаги:
//  • якорь — момент, когда табло опубликовало оценку последнего выступившего (его время на табло или
//    момент, когда устройство её увидело): следующий начинает почти сразу после неё;
//  • длина слота — по шаблону (медиана промежутков внутри разминки, с поправкой на номера снявшихся)
//    или, когда устройство видело хотя бы две оценки подряд, по факту;
//  • между разминками — перерыв из шаблона (разминка, подготовка льда), а не слот;
//  • затянулось: выступающий должен был закончить, а оценки всё нет — все следующие сдвигаются от
//    «сейчас», а не стоят на месте;
//  • снявшиеся (их номер пропущен, а кто-то после них уже выступил) из очереди выпадают и время не занимают.
//  • табло во время старта пишет «Далее: …» — кто выступает следующим; пока в оставшемся порядке над
//    ним стоит строка его разминки, разминка идёт (его выход — после неё), а когда табло её убрало —
//    он выходит на лёд. Это факт, а не оценка: от него и считаются следующие (а не выступившие без
//    оценки — их оценка ещё в пути).
// Это оценка, и интерфейс так её и показывает: «≈15:22», «идёт с отставанием ≈7 мин».
import 'data.dart';
import 'live.dart' show personKey;

/// Длина слота по умолчанию (минуты), когда в шаблоне времени нет: как у сборщика (build.SLOT).
const _slotDefault = {'КП': 6.6, 'РТ': 6.4, 'ПП': 7.6, 'ПТ': 7.4};

/// Разминка с выходом на лёд, когда шаблон о ней молчит.
const _breakDefault = Duration(minutes: 7);

/// Оценка задерживается дольше слота на столько — значит, прокат или пауза затянулись.
const _grace = Duration(seconds: 90);

class Pace {
  /// Ключ человека (personKey) → когда он, по оценке, выйдет. Только те, кто ещё не выступил.
  final Map<String, DateTime> at;

  /// Насколько старт сейчас отстаёт от расписания (+) или опережает его (−); без шаблона — ноль.
  final Duration delay;

  /// Когда, по оценке, закончится сегмент (последний выйдет и получит оценку).
  final DateTime? end;

  /// Кто выступает сейчас или выйдет следующим (personKey).
  final String? next;

  /// Длина слота, по которой считали, и посчитана ли она по факту (а не по шаблону).
  final Duration slot;
  final bool measured;
  const Pace({required this.at, required this.delay, required this.end, required this.next, required this.slot, required this.measured});

  /// Насколько поправка заметна: меньше двух минут — «по расписанию».
  bool get late => delay >= const Duration(minutes: 2);
  bool get early => delay <= const Duration(minutes: -2);
}

Duration _median(List<Duration> xs) {
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

/// Поправка для сегмента [s] на момент [now]. [posted] — когда табло опубликовало оценку каждого
/// выступившего (personKey → момент); [boardAt] — время самого табло (запас, если по человеку
/// момента нет). null — считать не из чего: нет состава, нет шаблона и не видно ни одной оценки.
Pace? paceOf(
  Start s, {
  Map<String, DateTime> posted = const {},
  DateTime? boardAt,
  ({String key, DateTime since, bool warmup})? onIce,
  required DateTime now,
}) {
  final field = s.field;
  if (field.length < 2) return null;
  // очередь — по стартовым номерам (они и есть порядок выхода); без номеров — как в составе
  final order = [...field];
  if (order.every((o) => o.no != null)) order.sort((a, b) => a.no!.compareTo(b.no!));
  // шаблон: время по расписанию; выбившееся из порядка (раньше предыдущего или позже следующего) —
  // ошибка расписания, а не порядок выхода: такое время не берём
  final raw = [for (final o in order) s.skateAt(o, planned: true)];
  final planAt = <Skater, DateTime?>{};
  for (var i = 0; i < order.length; i++) {
    final t = raw[i];
    final before = raw.take(i).whereType<DateTime>().fold<DateTime?>(null, (m, x) => m == null || x.isAfter(m) ? x : m);
    final after = raw.skip(i + 1).whereType<DateTime>().fold<DateTime?>(null, (m, x) => m == null || x.isBefore(m) ? x : m);
    planAt[order[i]] = t == null || (before != null && t.isBefore(before)) || (after != null && t.isAfter(after)) ? null : t;
  }
  DateTime? planned(Skater o) => planAt[o];
  final hasPlan = order.where((o) => planned(o) != null).length >= 2;
  bool done(Skater o) => o.place != null;

  // слот по шаблону: промежутки соседей внутри одной разминки, на один номер
  final gaps = <Duration>[];
  for (var i = 1; i < order.length; i++) {
    final a = order[i - 1], b = order[i];
    final ta = planned(a), tb = planned(b);
    if (ta == null || tb == null || (a.warmup != null && a.warmup != b.warmup)) continue;
    final steps = a.no != null && b.no != null && b.no! > a.no! ? b.no! - a.no! : 1;
    final per = tb.difference(ta) ~/ steps;
    if (per >= const Duration(minutes: 2) && per <= const Duration(minutes: 12)) gaps.add(per);
  }
  final minutes = (_slotDefault[s.seg] ?? 7.0) + (s.kind == 'pairs' ? .5 : 0);
  final planSlot = gaps.isEmpty ? Duration(seconds: (minutes * 60).round()) : _median(gaps);

  // выброшенное (или пропущенное) время — по соседу из той же разминки и слоту на каждый номер
  for (var i = 0; i < order.length; i++) {
    if (planAt[order[i]] != null) continue;
    final o = order[i];
    for (var j = i - 1; j >= 0; j--) {
      final a = order[j], t = planAt[a];
      if (a.warmup != o.warmup) break;
      if (t == null) continue;
      final steps = a.no != null && o.no != null && o.no! > a.no! ? o.no! - a.no! : i - j;
      planAt[o] = t.add(planSlot * steps);
      break;
    }
    if (planAt[o] != null) continue;
    for (var j = i + 1; j < order.length; j++) {
      final b = order[j], t = planAt[b];
      if (b.warmup != o.warmup) break;
      if (t == null) continue;
      final steps = o.no != null && b.no != null && b.no! > o.no! ? b.no! - o.no! : j - i;
      planAt[o] = t.subtract(planSlot * steps);
      break;
    }
  }

  // слот по факту: оценки соседей одной разминки, которые устройство видело по отдельности
  final seen = <Duration>[];
  for (var i = 1; i < order.length; i++) {
    final a = order[i - 1], b = order[i];
    if (!done(a) || !done(b) || (a.warmup != null && a.warmup != b.warmup)) continue;
    final pa = posted[personKey(a.name)], pb = posted[personKey(b.name)];
    if (pa == null || pb == null) continue;
    final g = pb.difference(pa);
    if (g >= planSlot * .6 && g <= planSlot * 1.8) seen.add(g);
  }
  final measured = seen.length >= 2;
  if (!hasPlan && !measured && posted.isEmpty) return null;
  final slot = measured ? _median(seen) : planSlot;

  // перерыв между разминками: по шаблону (промежуток минус слот), иначе — обычная разминка
  Duration breakBetween(Skater a, Skater b) {
    if (a.warmup == null || b.warmup == null || a.warmup == b.warmup) return Duration.zero;
    final ta = planned(a), tb = planned(b);
    if (ta == null || tb == null) return _breakDefault;
    final steps = a.no != null && b.no != null && b.no! > a.no! ? b.no! - a.no! : 1;
    final br = tb.difference(ta) - planSlot * steps;
    return br.isNegative ? Duration.zero : (br > const Duration(minutes: 40) ? const Duration(minutes: 40) : br);
  }

  final lastDone = order.lastIndexWhere(done);
  // кто ещё выступит: после последнего выступившего; пропущенные до него — снялись
  var rest = [for (var i = lastDone + 1; i < order.length; i++) if (!done(order[i])) order[i]];
  // табло говорит, кто выходит: кто стоял в очереди раньше него — уже откатал (оценка в пути) или снялся
  final ice = onIce == null ? -1 : rest.indexWhere((o) => personKey(o.name) == onIce.key);
  if (ice > 0) rest = rest.sublist(ice);
  if (rest.isEmpty) {
    final a = lastDone < 0 ? null : posted[personKey(order[lastDone].name)] ?? boardAt;
    return Pace(at: const {}, delay: Duration.zero, end: a, next: null, slot: slot, measured: measured);
  }

  // начало следующего: от оценки последнего выступившего (плюс разминка, если он открывает новую)
  DateTime cursor;
  if (lastDone >= 0) {
    final d = order[lastDone];
    final anchor = posted[personKey(d.name)] ?? boardAt ?? planned(d)?.add(slot);
    if (anchor == null) return null;
    cursor = anchor.add(breakBetween(d, rest.first));
  } else {
    final first = planned(rest.first);
    // до первого выступления: по шаблону, а без него — начало сегмента и разминка
    cursor = first ?? s.t0.add(_breakDefault);
  }
  // выход того, кого табло назвало, — не раньше, чем назвало; пока идёт его разминка — после неё
  if (ice >= 0) {
    final first = planned(rest.first);
    // длина разминки: у первой — от начала сегмента до первого выхода по шаблону, иначе обычная
    final warmLen = lastDone < 0 && first != null && first.difference(s.t0) >= const Duration(minutes: 3) && first.difference(s.t0) <= const Duration(minutes: 12)
        ? first.difference(s.t0)
        : _breakDefault;
    final from = onIce!.warmup ? onIce.since.add(warmLen) : onIce.since;
    if (from.isAfter(cursor)) cursor = from;
  }

  final at = <String, DateTime>{};
  // выступающий должен был получить оценку, а её нет: прокат или пауза затянулись
  final overdue = now.isAfter(cursor.add(slot).add(_grace));
  for (var i = 0; i < rest.length; i++) {
    final o = rest[i];
    at[personKey(o.name)] = cursor;
    if (i == rest.length - 1) break;
    // следующий — не раньше чем через полминуты после «сейчас»
    final next = i == 0 && overdue ? now.add(const Duration(seconds: 30)) : cursor.add(slot);
    cursor = next.add(breakBetween(o, rest[i + 1]));
  }
  final end = rest.length == 1 && overdue ? now.add(const Duration(seconds: 30)) : cursor.add(slot);
  // отставание — по тому, кто выйдет следующим после выступающего, если прокат затянулся: по самому
  // выступающему его не видно (он уже на льду, время его выхода в прошлом)
  final probe = overdue && rest.length > 1 ? rest[1] : rest.first;
  final plan = planned(probe);
  final lag = plan == null ? Duration.zero : at[personKey(probe.name)]!.difference(plan);
  return Pace(at: at, delay: lag, end: end, next: personKey(rest.first.name), slot: slot, measured: measured);
}

/// Строка о темпе для людей: «Идёт с отставанием ≈7 мин», «…с опережением ≈3 мин»; в пределах
/// двух минут — ничего (это и есть расписание). Время выхода ниже — с этой поправкой.
String? paceLine(Pace? p) {
  if (p == null || p.at.isEmpty) return null;
  final m = p.delay.inMinutes.abs();
  if (p.late) return 'Отставание от расписания ≈$m\u00A0мин: время выхода поправлено';
  if (p.early) return 'Опережение расписания ≈$m\u00A0мин: время выхода поправлено';
  return null;
}

/// Коротко — для карточки старта под временем: «отставание ≈7 мин»; по расписанию — ничего.
String? paceShort(Pace? p) {
  if (p == null || p.at.isEmpty) return null;
  final m = p.delay.inMinutes.abs();
  if (p.late) return 'отставание ≈$m\u00A0мин';
  if (p.early) return 'опережение ≈$m\u00A0мин';
  return null;
}
