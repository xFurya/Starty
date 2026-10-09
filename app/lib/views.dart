// Лента и месяц: старты по дням, идущий старт, итоги завершённых сегментов.
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'data.dart';
import 'main.dart';
import 'sheets.dart';
import 'state.dart';
import 'ui.dart';

String dayTitle(String key) {
  final t = now();
  if (key == dayKey(t)) return 'Сегодня';
  if (key == dayKey(t.add(const Duration(days: 1)))) return 'Завтра';
  if (key == dayKey(t.subtract(const Duration(days: 1)))) return 'Вчера';
  final d = DateTime.parse(key);
  return '${cap(weekdays[d.weekday - 1])}, ${d.day}$nb${months[d.month - 1]}';
}

/// Короткий заголовок дня, когда полный не помещается: «Пн, 12 октября».
String dayTitleShort(String key) {
  final full = dayTitle(key);
  if (!full.contains(',')) return full;
  final d = DateTime.parse(key);
  return '${cap(weekdaysShort[d.weekday - 1])}, ${d.day}$nb${months[d.month - 1]}';
}

String daySub(String key) {
  final t = now();
  final d = DateTime.parse(key);
  if (key == dayKey(t) || key == dayKey(t.add(const Duration(days: 1))) || key == dayKey(t.subtract(const Duration(days: 1)))) {
    return '${weekdaysShort[d.weekday - 1]}, ${d.day}$nb${months[d.month - 1]}';
  }
  return '';
}

/// «Сезон 2026/27»: сезон начинается летом.
String season(DateTime t) {
  final m = msk(t);
  final y = m.month >= 7 ? m.year : m.year - 1;
  return 'Сезон $y/${two((y + 1) % 100)}';
}

/// О будущем старте уведомления не будет — по правилам или выключено вручную.
/// Старты, до которых меньше «заранее», не считаются: уведомлять уже поздно, и правила тут ни при чём.
bool silent(AppState st, Start s, DateTime t) =>
    st.rules.on && s.t0.subtract(Duration(minutes: st.rules.lead)).isAfter(t) && !st.notifies(s);

/// Старты, которые лента показала бы с этим фильтром: идущие, сегодняшние завершённые
/// (если их показывать) и будущие на 60 дней вперёд.
List<Start> feedPool(AppState st, Filters f, DateTime t) {
  final data = st.data;
  if (data == null) return const [];
  final today = dayKey(t);
  final horizon = t.add(const Duration(days: 60));
  return data.starts
      .where((s) => f.pass(s) && s.t0.isBefore(horizon) && (!s.pastAt(t) || (st.showDone && s.day == today)))
      .toList();
}

/// Турниры без расписания, которые идут в этот день.
List<Upcoming> upcomingOn(AppState st, String day) => [
  for (final u in st.data?.upcoming ?? const <Upcoming>[])
    if (u.covers(day) && st.filters.passUpcoming(u)) u,
];

/// Турниры без расписания на ленту: ещё не закончились и начнутся в ближайшие 60 дней.
List<Upcoming> upcomingAhead(AppState st, DateTime t) {
  final today = dayKey(t), horizon = dayKey(t.add(const Duration(days: 60)));
  return [
    for (final u in st.data?.upcoming ?? const <Upcoming>[])
      if (u.end.compareTo(today) >= 0 && u.start.compareTo(horizon) < 0 && st.filters.passUpcoming(u)) u,
  ];
}

/// «15–18 октября», «30 октября – 2 ноября».
String dateRange(String from, String to) {
  final a = DateTime.parse(from), b = DateTime.parse(to);
  if (from == to) return '${a.day}$nb${months[a.month - 1]}';
  if (a.month == b.month) return '${a.day}–${b.day}$nb${months[b.month - 1]}';
  return '${a.day}$nb${months[a.month - 1]} – ${b.day}$nb${months[b.month - 1]}';
}

/// Свежесть расписания: что написать и тревожно ли. Сборщик ходит в 09:00 и 15:00 МСК,
/// перерыв между запусками — до 18 ч; старше 20 ч — запуск не состоялся.
({String text, bool alarm}) freshness(AppState st, {bool short = false}) {
  final d = st.data!;
  final g = d.generated;
  final failed = [
    for (final e in d.sources.entries)
      if (e.value != 'ok') e.key,
  ];
  final String trouble;
  if (st.offline) {
    trouble = 'нет связи';
  } else if (!d.complete) {
    trouble = failed.length == 1 ? '${failed.first} не отвечает' : 'источники не отвечают';
  } else if (now().difference(g) > const Duration(hours: 20)) {
    trouble = 'расписание устарело';
  } else {
    trouble = '';
  }
  // «обновлено сегодня в 14:02», «обновлено 8 октября в 23:39» — без предлога перед наречием
  final day = dayKey(g) == dayKey(now()) ? 'сегодня' : '${msk(g).day}$nb${months[msk(g).month - 1]}';
  final when = short ? 'обновлено ${dateTime(g).replaceAll(' ', nb).replaceFirst(',$nb', ', ')}' : 'обновлено $day в$nb${hm(g)}';
  if (trouble.isEmpty) return (text: short ? when : '${cap(when)} · время московское', alarm: false);
  return (text: '${short ? trouble : cap(trouble)} · $when', alarm: true);
}

// ------------------------------------------------------------------ лента

class FeedView extends StatelessWidget {
  final AppState state;
  const FeedView({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final data = state.data;
    final sections = data == null ? <Widget>[] : _sections(context);
    return RefreshIndicator(
      onRefresh: state.load,
      edgeOffset: MediaQuery.paddingOf(context).top,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: IceHero(
              eyebrow: season(now()),
              title: 'Фигурное катание',
              figure: true,
              actions: [if (data != null) FilterButton(state: state)],
            ),
          ),
          if (data != null) SliverToBoxAdapter(child: NoticeLine(state: state)),
          if (state.filters.any) SliverToBoxAdapter(child: FilterLine(state: state)),
          if (data == null && state.loading)
            const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          else if (data == null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(text: 'Нет связи', action: 'Повторить', onAction: state.load),
            )
          else if (sections.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(text: state.filters.any ? 'По фильтру стартов нет' : 'Стартов нет'),
            )
          else
            for (final w in sections) SliverToBoxAdapter(child: w),
          if (data != null) SliverToBoxAdapter(child: _Freshness(state: state)),
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  List<Widget> _sections(BuildContext context) {
    final t = now();
    final today = dayKey(t);
    final pool = feedPool(state, state.filters, t);
    final unscheduled = upcomingAhead(state, t);
    final live = pool.where((s) => s.liveAt(t)).toList();
    final done = pool.where((s) => s.pastAt(t)).toList();
    final next = pool.where((s) => !s.pastAt(t) && !s.liveAt(t)).toList();
    final todayNext = next.where((s) => s.day == today).toList();
    // отсчёт — у ближайшего предстоящего, если он сегодня
    final soon = todayNext.isEmpty ? null : todayNext.first.id;
    final out = <Widget>[];
    if (live.isNotEmpty || todayNext.isNotEmpty || done.isNotEmpty) {
      out.add(const DayHeader(day: null, top: 10));
      for (final s in live) {
        out.add(LiveCard(start: s, state: state));
      }
      if (todayNext.isNotEmpty) out.add(DayPlate(starts: todayNext, state: state, soon: soon));
      if (done.isNotEmpty) {
        out.add(const Eyebrow('Завершено', padding: EdgeInsets.fromLTRB(20, 22, 20, 10)));
        out.add(DayPlate(starts: done, state: state));
      }
    }
    String? day;
    var rows = <Start>[];
    void flush() {
      final d = day;
      if (d == null || rows.isEmpty) return;
      out.add(DayHeader(day: d, top: out.isEmpty ? 10 : 26));
      out.add(DayPlate(starts: rows, state: state));
    }

    for (final s in next.where((s) => s.day != today)) {
      if (s.day != day) {
        flush();
        day = s.day;
        rows = [];
      }
      rows.add(s);
    }
    flush();
    // турниры, у которых ещё нет расписания по сегментам: даты, место, наши в заявке
    if (unscheduled.isNotEmpty) {
      out.add(DayHeader(day: null, title: 'Без расписания', top: out.isEmpty ? 10 : 26));
      out.add(UnscheduledPlate(list: unscheduled, state: state, dates: true));
    }
    return out;
  }
}

class FilterButton extends StatelessWidget {
  final AppState state;
  const FilterButton({super.key, required this.state});
  @override
  Widget build(BuildContext context) => RoundButton(
    icon: CupertinoIcons.slider_horizontal_3,
    tooltip: 'Фильтр',
    badge: state.filters.count,
    onTap: () => showFilters(context, state),
  );
}

/// Ледяная строка под шапкой: значок, текст, кнопка справа.
class FrostLine extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String text;
  final String action;
  final VoidCallback onAction;
  const FrostLine({
    super.key,
    required this.icon,
    required this.text,
    required this.action,
    required this.onAction,
    this.iconColor,
  });
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.only(left: 14),
      decoration: BoxDecoration(
        color: p.frost,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.plateLine),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: iconColor ?? p.accent),
          const SizedBox(width: 10),
          // главная строка о неполадке читается целиком: до двух строк
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.ink, fontSize: 14, fontWeight: FontWeight.w500, height: 1.25),
              ),
            ),
          ),
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: p.accent,
              minimumSize: const Size(44, 44),
              textStyle: const TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w700, fontSize: 14),
            ),
            child: Text(action, maxLines: 1, softWrap: false),
          ),
        ],
      ),
    );
  }
}

/// Уведомления выключены или запрещены — в ленте об этом одна строка.
class NoticeLine extends StatelessWidget {
  final AppState state;
  const NoticeLine({super.key, required this.state});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final String text;
    if (!state.rules.on) {
      text = 'Уведомления выключены';
    } else if (state.allowed == false) {
      text = 'Уведомления запрещены в системе';
    } else {
      return const SizedBox.shrink();
    }
    return FrostLine(
      icon: CupertinoIcons.bell_slash,
      iconColor: state.rules.on ? p.live : p.ink2,
      text: text,
      action: 'Настройки',
      onAction: () => homeTab.value = tabSettings,
    );
  }
}

class FilterLine extends StatelessWidget {
  final AppState state;
  const FilterLine({super.key, required this.state});
  @override
  Widget build(BuildContext context) {
    final f = state.filters;
    final names = <String>[
      ...f.kinds.map((k) => kindNames[k] ?? k),
      if (f.tids.isNotEmpty)
        f.tids.length == 1
            ? tournamentName(state, f.tids.first)
            : '${f.tids.length} ${plural(f.tids.length, 'турнир', 'турнира', 'турниров')}',
    ];
    return FrostLine(
      icon: CupertinoIcons.slider_horizontal_3,
      text: names.join(' · '),
      action: 'Сбросить',
      onAction: () => state.setFilters(const Filters({}, {})),
    );
  }
}

String tournamentName(AppState s, String tid) {
  for (final x in s.data?.starts ?? const <Start>[]) {
    if (x.tid == tid) return x.tournament;
  }
  return tid;
}

/// Ширина колонки времени в строках; на узком экране — уже.
double timeColOf(BuildContext context) => MediaQuery.sizeOf(context).width < 360 ? 74 : 88;

/// Заголовок дня: «Сегодня  пт, 9 октября ———». Дата не обрезается: не помещается —
/// сначала без черты, затем короткий день недели («Пн, 12 октября»), затем мельче.
class DayHeader extends StatelessWidget {
  /// null — сегодня.
  final String? day;
  final double top;

  /// Свой заголовок вместо дня: «Без расписания».
  final String? title;
  const DayHeader({super.key, required this.day, this.top = 26, this.title});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final key = day ?? dayKey(now());
    final sub = title != null ? '' : daySub(key);
    final big = display(p, 29, italic: true);
    final small = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: p.ink2, height: 1);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, top, 20, 10),
      child: MeasuredLayout(
        builder: (context, c) {
          double widthOf(String t) =>
              textWidth(context, t, big) + (sub.isEmpty ? 0 : textWidth(context, '   $sub', small)) + 1;
          final full = title ?? dayTitle(key);
          final short = title ?? dayTitleShort(key);
          const rule = 36.0;
          var (text, line, shrink) = (short, false, true);
          for (final (t, l) in [(full, true), (full, false), (short, true), (short, false)]) {
            if (widthOf(t) + (l ? rule : 0) <= c.maxWidth) {
              (text, line, shrink) = (t, l, false);
              break;
            }
          }
          Widget label = Text.rich(
            TextSpan(
              children: [
                TextSpan(text: text, style: big),
                if (sub.isNotEmpty) TextSpan(text: '   $sub', style: small),
              ],
            ),
            maxLines: 1,
            softWrap: false,
          );
          if (shrink) {
            label = Flexible(
              child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: label),
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              label,
              if (line) ...[
                const SizedBox(width: 12),
                Expanded(child: Container(height: 1, color: p.plateLine)),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Плашка дня: старты через тонкие линии, подряд идущие старты одного турнира — под общей подписью.
class DayPlate extends StatelessWidget {
  final List<Start> starts;
  final AppState state;

  /// Старт, у которого показать отсчёт до начала.
  final String? soon;
  const DayPlate({super.key, required this.starts, required this.state, this.soon});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final children = <Widget>[];
    // колонка времени выхода и место под аватар пары — одни на всю плашку: имена в столбик ровно
    final t = now();
    final shown = starts.expand((s) => oursShown(s, t)).toList();
    final times = shown.any(hasSlotTime);
    final slot = shown.any(isPair);
    String? tid;
    for (final s in starts) {
      if (s.tid != tid) {
        if (children.isNotEmpty) children.add(const Hairline(indent: 0));
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Eyebrow(s.tournament, color: p.accent, maxLines: 2),
          ),
        );
        tid = s.tid;
      } else {
        children.add(const Hairline());
      }
      children.add(
        StartTile(start: s, state: state, showTournament: false, countdown: s.id == soon, times: times, slot: slot),
      );
    }
    return Plate(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

/// «Женщины ПП»: дисциплина и сегмент акцентом.
class SegTitle extends StatelessWidget {
  final Start start;
  final double size;
  final Color? color;
  const SegTitle({super.key, required this.start, this.size = 16.5, this.color});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (disc, seg) = splitSegment(start.segment);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: disc),
          if (seg.isNotEmpty)
            TextSpan(
              text: '  $seg',
              style: TextStyle(fontSize: size * .8, letterSpacing: .8, color: color ?? p.accent),
            ),
        ],
      ),
      style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, height: 1.2, color: color ?? p.ink),
    );
  }
}

String metaLine(Start s, {bool tournament = true}) =>
    [if (tournament) s.tournament, if (s.broadcast.isNotEmpty) s.broadcast.join(' / ')].join(' · ');

/// Наши, которые ещё не выходили (для идущего старта).
List<Skater> notYetSkated(Start s, DateTime t) => s.ours.where((o) {
  final at = s.skateAt(o);
  return o.place == null && (at == null || at.add(const Duration(minutes: 4)).isAfter(t));
}).toList();

/// Наши в строке старта: у идущего — кто ещё не выходил, у прошедшего — никого.
List<Skater> oursAll(Start s, DateTime t) => s.pastAt(t) ? const [] : (s.liveAt(t) ? notYetSkated(s, t) : s.ours);
List<Skater> oursShown(Start s, DateTime t) => oursAll(s, t).take(3).toList();

/// Строка старта в плашке: время, сегмент, турнир, наши со временем выхода.
/// Тесно (узкий экран, крупный шрифт) — наши под временем, на всю ширину плашки.
class StartTile extends StatelessWidget {
  final Start start;
  final AppState state;
  final bool showTournament;
  final bool countdown;

  /// Колонка времени выхода и место под пару — по всей плашке; null — по своему списку.
  final bool? times, slot;
  const StartTile({
    super.key,
    required this.start,
    required this.state,
    this.showTournament = true,
    this.countdown = false,
    this.times,
    this.slot,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = start;
    final t = now();
    if (s.pastAt(t)) return PastTile(start: s, state: state, showTournament: showTournament);
    final meta = metaLine(s, tournament: showTournament);
    final live = s.liveAt(t);
    final mute = !live && silent(state, s, t);
    final ours = oursAll(s, t);
    final shown = ours.take(3).toList();
    final under = tight(context);
    final list = shown.isEmpty
        ? null
        : OursList(
            list: shown,
            more: ours.length - shown.length,
            data: state.data,
            times: times ?? shown.any(hasSlotTime),
            blankTime: !shown.any(hasSlotTime),
            slot: slot ?? shown.any(isPair),
          );
    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: timeColOf(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 8),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(hm(s.t0), style: clock(live ? p.live : p.ink, 27)),
                ),
              ),
              if (live) ...[const SizedBox(height: 7), const LivePill()],
            ],
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: SegTitle(start: s)),
                    if (mute) const Padding(padding: EdgeInsets.only(left: 8, top: 3), child: MutedBell()),
                  ],
                ),
              ),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: p.ink2, height: 1.3),
                ),
              ],
              if (countdown) ...[
                const SizedBox(height: 4),
                Text(
                  whenLabel(s, t),
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: p.accent, height: 1.3),
                ),
              ],
              if (list != null && !under) ...[const SizedBox(height: 12), list],
            ],
          ),
        ),
      ],
    );
    return InkWell(
      onTap: () => showStart(context, s, state),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        child: list != null && under
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [head, const SizedBox(height: 12), list],
              )
            : head,
      ),
    );
  }
}

/// Наш спортсмен в строке: время выхода, фото, фамилия.
bool isPair(Skater o) => o.name.contains(' / ');
bool hasSlotTime(Skater o) => o.time != null || o.no != null;

/// Ширина под имя в строке «наших»: всё, кроме колонки времени, аватара и зазора.
double oursNameWidth(BuildContext context, double width, {required bool times, required bool slot}) {
  const size = 26.0;
  final col = times ? MediaQuery.textScalerOf(context).scale(OursLine.col) : 0.0;
  return width - col - (slot ? Avatar.pairWidth(size) : size) - 8;
}

/// Список наших в строке старта. Формат имени один на весь список: хоть одно полное имя
/// не помещается — у всех фамилии.
class OursList extends StatelessWidget {
  final List<Skater> list;
  final int more;
  final Schedule? data;
  final bool onDark, times, blankTime, slot;
  const OursList({
    super.key,
    required this.list,
    required this.data,
    this.more = 0,
    this.onDark = false,
    this.times = true,
    this.blankTime = false,
    this.slot = false,
  });
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return MeasuredLayout(
      builder: (context, c) {
        final w = oursNameWidth(context, c.maxWidth, times: times, slot: slot);
        final style = OursLine.nameStyle(onDark ? Colors.white : p.ink);
        final warm = OursLine.warmStyle(p.ink2);
        final surnames = list.any(
          (o) =>
              !isPair(o) &&
              !NameLines.fits(
                context,
                [displayName(o.name)],
                style,
                w,
                OursLine.warmOf(o).isEmpty ? 0 : textWidth(context, OursLine.warmOf(o), warm) + NameLines.gap,
              ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final o in list)
              OursLine(o: o, data: data, onDark: onDark, slot: slot, times: times, blankTime: blankTime, surnames: surnames),
            if (more > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'ещё $more',
                  style: TextStyle(fontSize: 13, color: onDark ? Colors.white.withValues(alpha: .78) : p.ink2),
                ),
              ),
          ],
        );
      },
    );
  }
}

class OursLine extends StatelessWidget {
  final Skater o;
  final Schedule? data;
  final bool onDark;

  /// Есть пары рядом — место под аватар одной ширины, имена в столбик ровно.
  final bool slot;

  /// Колонка времени: нет ни времени, ни номера ни у кого в плашке — колонки нет.
  final bool times;

  /// Колонка есть (время у других стартов плашки), а в этом списке времени ни у кого — пусто.
  final bool blankTime;

  /// У одиночников — только фамилия.
  final bool surnames;
  const OursLine({
    super.key,
    required this.o,
    required this.data,
    this.onDark = false,
    this.slot = false,
    this.times = true,
    this.blankTime = false,
    this.surnames = false,
  });

  /// Колонка времени до масштаба шрифта: «19:30» не переносится.
  static const col = 46.0;
  static TextStyle nameStyle(Color ink) => TextStyle(fontSize: 14.5, color: ink, height: 1.25);
  static TextStyle warmStyle(Color ink2) => TextStyle(color: ink2, fontSize: 12.5, height: 1.25);
  static String warmOf(Skater o) => o.time == null && o.warmup != null ? 'разминка$nb${o.warmup}' : '';

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final ink = onDark ? Colors.white : p.ink;
    final ink2 = onDark ? Colors.white.withValues(alpha: .72) : p.ink2;
    final left = blankTime ? '' : (o.time ?? (o.no != null ? '№$nb${o.no}' : '—'));
    // у пары — фамилии, при нехватке места по партнёру на строку; партнёр не теряется
    final variants = isPair(o)
        ? nameVariants(o.name, full: false, lines: 2)
        : (surnames ? [[surname(o.name)]] : nameVariants(o.name));
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          if (times)
            SizedBox(
              width: MediaQuery.textScalerOf(context).scale(col),
              child: Text(
                left,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: TextStyle(
                  fontSize: o.time != null ? 14.5 : 13,
                  fontWeight: o.time != null ? FontWeight.w700 : FontWeight.w500,
                  color: o.time != null ? ink : ink2,
                  fontFeatures: tnum,
                ),
              ),
            ),
          Avatar(name: o.name, data: data, size: 26, slot: slot, ring: onDark ? const Color(0xFF1B4F86) : null),
          const SizedBox(width: 8),
          Expanded(
            child: NameLines(
              variants: variants,
              style: nameStyle(ink),
              suffix: warmOf(o),
              suffixStyle: warmStyle(ink2),
              semantics: displayName(o.name),
            ),
          ),
        ],
      ),
    );
  }
}

class LivePill extends StatelessWidget {
  final bool onDark;
  const LivePill({super.key, this.onDark = false});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = onDark ? Colors.white : p.live;
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 3, 8, 3),
      decoration: BoxDecoration(
        color: onDark ? Colors.white.withValues(alpha: .14) : p.live.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: onDark ? const Color(0xFFFF8A94) : p.live,
              boxShadow: [BoxShadow(color: (onDark ? const Color(0xFFFF8A94) : p.live).withValues(alpha: .5), blurRadius: 5)],
            ),
          ),
          const SizedBox(width: 5),
          Text(
            'ИДЁТ',
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.1, color: c, height: 1.1),
          ),
        ],
      ),
    );
  }
}

/// Идущий сейчас старт — синяя плашка цвета иконки.
class LiveCard extends StatelessWidget {
  final Start start;
  final AppState state;
  const LiveCard({super.key, required this.start, required this.state});
  @override
  Widget build(BuildContext context) {
    final s = start;
    final t = now();
    final (disc, seg) = splitSegment(s.segment);
    final rest = notYetSkated(s, t);
    const white = Colors.white;
    final dim = Colors.white.withValues(alpha: .78);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Palette.iceBlue, Color(0xFF17508F), Palette.deepBlue],
          stops: [0, .5, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(.8, -.9),
                  radius: .9,
                  colors: [Colors.white.withValues(alpha: .22), Colors.white.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
          Positioned.fill(child: CustomPaint(painter: SparklePainter(Colors.white, .75, variant: 1))),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => showStart(context, s, state),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const LivePill(onDark: true),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            '${hm(s.t0)}$nb–$nb${hm(s.t1)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: dim, fontFeatures: tnum),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(disc, style: display(Palette.light, 36, color: white)),
                    if (seg.isNotEmpty)
                      Text(
                        segNames[seg]!,
                        style: display(Palette.light, 22, italic: true, color: dim, weight: FontWeight.w500),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      metaLine(s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: dim),
                    ),
                    if (rest.isNotEmpty) ...[
                      Container(
                        height: 1,
                        margin: const EdgeInsets.fromLTRB(0, 14, 0, 12),
                        color: Colors.white.withValues(alpha: .16),
                      ),
                      Eyebrow('Наши · впереди', color: Colors.white.withValues(alpha: .7)),
                      const SizedBox(height: 8),
                      OursList(
                        list: rest.take(4).toList(),
                        more: rest.length - 4,
                        data: state.data,
                        onDark: true,
                        slot: rest.take(4).any(isPair),
                        times: rest.any(hasSlotTime),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Чья тройка: итог турнира, когда вид закончен, иначе — тройка сегмента.
(String, List<Placing>) topOf(Start s) =>
    s.total.isNotEmpty ? ('Итог турнира', s.total) : ('Тройка · ${s.seg.isEmpty ? 'сегмент' : s.seg}', s.podium);

/// Прошедший сегмент: компактно, с первой тройкой.
class PastTile extends StatelessWidget {
  final Start start;
  final AppState state;
  final bool showTournament;
  const PastTile({super.key, required this.start, required this.state, this.showTournament = true});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = start;
    final (label, top) = topOf(s);
    final meta = metaLine(s, tournament: showTournament);
    return InkWell(
      onTap: () => showStart(context, s, state),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: timeColOf(context),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1, right: 8),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(hm(s.t0), style: clock(p.ink2, 22, weight: FontWeight.w400)),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegTitle(start: s, size: 15.5),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: p.ink2),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            // тесно — тройка под строкой старта на всю ширину, без отступа под время
            Padding(
              padding: EdgeInsets.only(left: tight(context) ? 0 : timeColOf(context), top: 10),
              child: top.isEmpty
                  ? Text('Итогов пока нет', style: TextStyle(fontSize: 13.5, color: p.ink2))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Eyebrow(label, padding: const EdgeInsets.only(bottom: 5)),
                        MiniPodium(top: top, intl: s.intl),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Имя в итогах: наши на международных — цветом акцента без кода; иностранцы — с кодом
/// страны; на российских стартах код — это регион, приглушённо, и никого не выделяем.
/// Код — отдельно справа и не сжимается: при нехватке места короче становится имя.
class PlacingName extends StatelessWidget {
  final Placing x;
  final bool intl;

  /// Начинать с короткого: «А. Заикина», у пар — фамилии.
  final bool short;
  final double size;
  final FontWeight weight;

  /// Регион на российских стартах (в компактной тройке ленты его нет — там тесно).
  final bool region;
  final bool center;
  const PlacingName({
    super.key,
    required this.x,
    required this.intl,
    this.short = false,
    this.size = 15,
    this.weight = FontWeight.w600,
    this.region = true,
    this.center = false,
  });

  /// Код у имени: у иностранцев на международных — страна, на российских — регион.
  static String codeOf(Placing x, bool intl, {bool region = true}) {
    if (x.nation.isEmpty || (intl && x.ours)) return '';
    return intl ? nationCode(x.nation) : (region ? x.nation : '');
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final ours = intl && x.ours;
    final code = codeOf(x, intl, region: region);
    return NameLines(
      variants: nameVariants(x.name, full: !short, initial: true, lines: 2),
      style: TextStyle(fontSize: size, fontWeight: weight, color: ours ? p.accent : p.ink, height: 1.25),
      suffix: code,
      suffixStyle: TextStyle(
        fontSize: size * .76,
        fontWeight: FontWeight.w700,
        letterSpacing: .8,
        height: 1.25,
        color: p.ink2,
      ),
      center: center,
      semantics: displayName(x.name),
    );
  }
}

/// Первая тройка столбиком: медаль, имя, баллы.
class MiniPodium extends StatelessWidget {
  final List<Placing> top;
  final bool intl;
  const MiniPodium({super.key, required this.top, required this.intl});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final list = [...top]..sort((a, b) => a.place.compareTo(b.place));
    return Column(
      children: [
        for (final x in list.take(3))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Medal(x.place, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: PlacingName(x: x, intl: intl, short: true, size: 14, region: false),
                ),
                if (x.points.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(x.points, style: clock(p.ink2, 14, weight: FontWeight.w500)),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _Freshness extends StatelessWidget {
  final AppState state;
  const _Freshness({required this.state});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final f = freshness(state);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 30, 20, 0),
      child: Text(
        f.text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12.5, color: f.alarm ? p.live : p.ink2),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback? onAction;
  const EmptyState({super.key, required this.text, this.action, this.onAction});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: display(p, 26, italic: true, color: p.ink2),
            ),
            if (action != null) ...[
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(minimumSize: const Size(120, 46)),
                child: Text(action!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Турниры без расписания по сегментам: название, даты или «Время не объявлено», место,
/// наши из заявки. Сегментов нет — открывать нечего, строки не нажимаются.
class UnscheduledPlate extends StatelessWidget {
  final List<Upcoming> list;
  final AppState state;

  /// В ленте — даты турнира; в списке дня — «Время не объявлено».
  final bool dates;
  const UnscheduledPlate({super.key, required this.list, required this.state, this.dates = false});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Plate(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const Hairline(indent: 0),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Eyebrow(list[i].name, color: p.accent, maxLines: 2),
                  const SizedBox(height: 7),
                  Text(
                    dates ? dateRange(list[i].start, list[i].end) : 'Время не объявлено',
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: p.ink, height: 1.25),
                  ),
                  // место международных стартов — как в источнике, латиницей
                  if (list[i].venue.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      list[i].venue,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: p.ink2, height: 1.3),
                    ),
                  ],
                  if (list[i].ours.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    OursList(
                      list: [for (final n in list[i].ours.take(4)) Skater(n, null, null, null)],
                      more: list[i].ours.length - 4,
                      data: state.data,
                      times: false,
                      slot: list[i].ours.take(4).any((n) => n.contains(' / ')),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Одна строка на плашке: «Стартов нет».
class EmptyPlate extends StatelessWidget {
  final String text;
  const EmptyPlate(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Plate(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Text(text, style: TextStyle(fontSize: 15, color: p.ink2)),
    );
  }
}

// ------------------------------------------------------------------ месяц

class MonthView extends StatefulWidget {
  final AppState state;
  const MonthView({super.key, required this.state});
  @override
  State<MonthView> createState() => _MonthViewState();
}

class _MonthViewState extends State<MonthView> {
  late DateTime month;
  late String selected;

  @override
  void initState() {
    super.initState();
    final m = msk(now());
    month = DateTime(m.year, m.month);
    selected = dayKey(now());
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = widget.state;
    final byDay = <String, List<Start>>{};
    for (final s in state.data?.starts ?? <Start>[]) {
      if (state.filters.pass(s)) (byDay[s.day] ??= []).add(s);
    }
    final first = DateTime(month.year, month.month, 1);
    final lead = first.weekday - 1;
    final days = DateTime(month.year, month.month + 1, 0).day;
    final cells = ((lead + days) / 7).ceil() * 7;
    final today = dayKey(now());
    final dayList = byDay[selected] ?? [];
    final unscheduled = upcomingOn(state, selected);
    final monthHasUnscheduled = [
      for (var d = 1; d <= days; d++) '${month.year}-${two(month.month)}-${two(d)}',
    ].any((k) => upcomingOn(state, k).isNotEmpty);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: IceHero(
            eyebrow: '${month.year}',
            title: monthsNom[month.month - 1],
            sparkles: 3,
            actions: [
              RoundButton(
                icon: CupertinoIcons.chevron_left,
                tooltip: 'Предыдущий месяц',
                onTap: () => setState(() => month = DateTime(month.year, month.month - 1)),
              ),
              RoundButton(
                icon: CupertinoIcons.chevron_right,
                tooltip: 'Следующий месяц',
                onTap: () => setState(() => month = DateTime(month.year, month.month + 1)),
              ),
              if (state.data != null) FilterButton(state: state),
            ],
          ),
        ),
        if (state.data != null) SliverToBoxAdapter(child: NoticeLine(state: state)),
        if (state.filters.any) SliverToBoxAdapter(child: FilterLine(state: state)),
        SliverToBoxAdapter(
          child: Plate(
            margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            padding: const EdgeInsets.fromLTRB(6, 14, 6, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    for (var i = 0; i < 7; i++)
                      Expanded(
                        child: Center(
                          child: Text(
                            weekdaysShort[i].toUpperCase(),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                              color: i > 4 ? p.accent : p.ink2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                for (var r = 0; r < cells ~/ 7; r++)
                  Row(children: [for (var c = 0; c < 7; c++) _cell(context, r * 7 + c - lead + 1, days, byDay, today)]),
                const SizedBox(height: 8),
                Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 10), color: p.line),
                const SizedBox(height: 10),
                _Legend(unscheduled: monthHasUnscheduled),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(child: DayHeader(day: selected)),
        SliverToBoxAdapter(
          child: dayList.isEmpty && unscheduled.isEmpty
              ? const EmptyPlate('Стартов нет')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (dayList.isNotEmpty) DayPlate(starts: dayList, state: state),
                    if (dayList.isNotEmpty && unscheduled.isNotEmpty) const SizedBox(height: 12),
                    if (unscheduled.isNotEmpty) UnscheduledPlate(list: unscheduled, state: state),
                  ],
                ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  static const _order = ['women', 'men', 'pairs', 'dance'];

  Widget _cell(BuildContext context, int d, int days, Map<String, List<Start>> byDay, String today) {
    final p = Palette.of(context);
    if (d < 1 || d > days) return const Expanded(child: SizedBox(height: 54));
    final key = '${month.year}-${two(month.month)}-${two(d)}';
    final list = byDay[key] ?? [];
    final sel = key == selected;
    final isToday = key == today;
    final past = key.compareTo(today) < 0;
    final kinds = [
      for (final k in _order)
        if (list.any((s) => s.kind == k)) k,
    ];
    final other = list.any((s) => !_order.contains(s.kind));
    // турнир идёт, а расписания по сегментам ещё нет — полая точка
    final hollow = upcomingOn(widget.state, key).isNotEmpty;
    return Expanded(
      child: Semantics(
        button: true,
        selected: sel,
        label: '$d ${months[month.month - 1]}',
        child: InkResponse(
          onTap: () => setState(() => selected = key),
          radius: 24,
          child: SizedBox(
            height: 54,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: sel
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: p.isDark ? [p.accent, const Color(0xFF4B8FD1)] : const [Palette.iceBlue, Palette.deepBlue],
                          )
                        : null,
                    border: isToday && !sel ? Border.all(color: p.accent, width: 1.4) : null,
                  ),
                  child: Text(
                    '$d',
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      fontSize: 15.5,
                      // только турнир без расписания — день не пустой, но и стартов нет: ink2
                      fontWeight: isToday || sel
                          ? FontWeight.w700
                          : (list.isNotEmpty ? FontWeight.w600 : (hollow ? FontWeight.w500 : FontWeight.w400)),
                      color: sel
                          ? p.onAccent
                          : (isToday ? p.accent : (list.isNotEmpty ? (past ? p.ink2 : p.ink) : (hollow ? p.ink2 : p.ink3))),
                      fontFeatures: tnum,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 5,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final k in kinds) _dot(p.kind(k), past),
                        if (other) _dot(p.ink3, past),
                        if (hollow) _ring(p.ink2, past),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dot(Color c, bool past) => Container(
    width: 5,
    height: 5,
    margin: const EdgeInsets.symmetric(horizontal: 1),
    decoration: BoxDecoration(shape: BoxShape.circle, color: past ? c.withValues(alpha: .55) : c),
  );

  Widget _ring(Color c, bool past) => Container(
    width: 5,
    height: 5,
    margin: const EdgeInsets.symmetric(horizontal: 1),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: past ? c.withValues(alpha: .55) : c, width: 1.1),
    ),
  );
}

/// Легенда точек под сеткой месяца; полая точка — турнир без расписания.
class _Legend extends StatelessWidget {
  final bool unscheduled;
  const _Legend({this.unscheduled = false});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final e in kindNames.entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.kind(e.key)),
              ),
              const SizedBox(width: 6),
              Text(
                e.value,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.ink2),
              ),
            ],
          ),
        if (unscheduled)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: p.ink2, width: 1.2),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'Без расписания',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.ink2),
              ),
            ],
          ),
      ],
    );
  }
}
