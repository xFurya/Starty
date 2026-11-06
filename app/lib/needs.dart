// «Сколько нужно» (подписка): что нужно отслеживаемому во втором сегменте вида при нынешних итогах.
// Считается только из протокола: баллы за первый сегмент плюс баллы за второй у тех, кто его уже откатал.
// При равной сумме выше тот, у кого больше за второй сегмент (правило ISU), — отсюда «от» вместо «больше».
// Не известно, выйдет ли человек во второй сегмент (отбор по сумме за первый), — порогов не показываем.
import 'live.dart' show personKey;
import 'protocol_model.dart';
import 'ui.dart' show nb;

/// Порог за второй сегмент: сотые балла и считается ли само значение (равенство суммы выигрывается).
class NeedMark {
  final int hundredths;
  final bool orEqual;
  const NeedMark(this.hundredths, {required this.orEqual});

  /// Хватает любой оценки: сумма за первый сегмент уже выше.
  bool get any => hundredths < 0 || (hundredths == 0 && orEqual);

  /// «больше 140.25», «от 128.10», «при любой оценке».
  String get text => any ? 'при любой оценке' : '${orEqual ? 'от' : 'больше'}$nb${pointsText(hundredths)}';

  @override
  bool operator ==(Object other) => other is NeedMark && other.hundredths == hundredths && other.orEqual == orEqual;
  @override
  int get hashCode => Object.hash(hundredths, orEqual);
  @override
  String toString() => text;
}

/// Один отслеживаемый: место и баллы после первого сегмента и что ему нужно.
class Need {
  /// Имя как в протоколе.
  final String name;

  /// Место и баллы (сотые) после первого сегмента.
  final int place, first;

  /// До второго сегмента: отставание от первого места (сотые); у лидера — null.
  final int? behind;

  /// До второго сегмента, у лидера: отрыв от второго места (сотые); второго нет — null.
  final int? ahead;

  /// По ходу второго сегмента: чтобы выйти на первое место и чтобы войти в тройку.
  /// Тройка — только когда откатали хотя бы трое: до этого в неё входит любой.
  final NeedMark? win, podium;

  const Need({required this.name, required this.place, required this.first, this.behind, this.ahead, this.win, this.podium});

  /// Идёт второй сегмент (пороги), а не перед ним (отставание).
  bool get during => win != null;
}

/// Сотые балла → «140.25».
String pointsText(int hundredths) {
  final h = hundredths.abs();
  return '${hundredths < 0 ? '-' : ''}${h ~/ 100}.${(h % 100).toString().padLeft(2, '0')}';
}

/// Баллы из протокола в сотых; нет числа — null.
int? hundredthsOf(String? s) {
  if (s == null) return null;
  final v = double.tryParse(s);
  return v == null || !v.isFinite ? null : (v * 100).round();
}

/// Что нужно отслеживаемым ([ours] — ключи [personKey]) во втором сегменте.
///
/// [first] — первый сегмент вида: должен быть закончен (предварительный или окончательный).
/// [second] — строки второго сегмента (из файла или с табло); с баллами — откатавшие.
/// [lineup] — ключи тех, кто выходит во второй сегмент (заявка); пусто — неизвестно.
/// Второй сегмент закончен — вызывающий сюда не приходит: всё уже в протоколе.
List<Need> needsOf({
  required ProtocolSegment first,
  required List<ProtocolRow> second,
  required Set<String> lineup,
  required Set<String> ours,
}) {
  if (first.state != SegmentState.provisional && first.state != SegmentState.finalized) return const [];
  // первый сегмент: место и баллы; без места или без баллов (снят, не вышел) — не участвует
  final s1 = <String, (int, int, String)>{};
  for (final r in first.rows) {
    final pts = hundredthsOf(r.points);
    if (r.place == null || pts == null) continue;
    s1[personKey(r.name)] = (r.place!, pts, r.name);
  }
  if (s1.isEmpty) return const [];
  // второй сегмент: кто уже откатал (с баллами) и кто просто в списке (строка без баллов)
  final s2 = <String, int>{};
  final listed = <String>{...lineup};
  for (final r in second) {
    final k = personKey(r.name);
    listed.add(k);
    final pts = hundredthsOf(r.points);
    if (pts != null && r.place != null) s2[k] = pts;
  }
  final during = s2.isNotEmpty;
  // итог тех, кто откатал оба сегмента: сумма, при равенстве выше больший второй сегмент
  final done = [
    for (final e in s2.entries)
      if (s1[e.key] case final a?) (total: a.$2 + e.value, second: e.value),
  ]..sort((a, b) => a.total != b.total ? b.total.compareTo(a.total) : b.second.compareTo(a.second));
  if (during && done.isEmpty) return const [];
  final byPlace = s1.values.toList()..sort((a, b) => a.$1.compareTo(b.$1));

  NeedMark mark(({int total, int second}) over, int mine) {
    final t = over.total - mine;
    // ровно t даёт ту же сумму: выше окажется тот, у кого за второй сегмент больше
    return NeedMark(t, orEqual: t > over.second);
  }

  final out = <Need>[];
  for (final k in ours) {
    final a = s1[k];
    if (a == null || s2.containsKey(k)) continue;
    // в заявке второго сегмента его нет (не прошёл отбор, снялся) — порогов нет
    if (listed.isNotEmpty && !listed.contains(k)) continue;
    final (place, pts, name) = a;
    if (during) {
      // сюда доходит только тот, кто есть в заявке или в списке второго сегмента: строки с баллами
      // есть, значит список не пуст, а кого в нём нет, отсеяно выше
      out.add(
        Need(
          name: name,
          place: place,
          first: pts,
          win: mark(done.first, pts),
          podium: done.length >= 3 ? mark(done[2], pts) : null,
        ),
      );
    } else {
      final leader = byPlace.first;
      final isLeader = personKey(leader.$3) == k;
      out.add(
        Need(
          name: name,
          place: place,
          first: pts,
          behind: isLeader ? null : leader.$2 - pts,
          ahead: isLeader && byPlace.length > 1 ? pts - byPlace[1].$2 : null,
        ),
      );
    }
  }
  out.sort((a, b) => a.place.compareTo(b.place));
  return out;
}
