import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data.dart';
import 'main.dart';

String cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String dayTitle(String key) {
  final t = now();
  if (key == dayKey(t)) return 'Сегодня';
  if (key == dayKey(t.add(const Duration(days: 1)))) return 'Завтра';
  final d = DateTime.parse(key);
  return '${cap(weekdays[d.weekday - 1])}, ${d.day} ${months[d.month - 1]}';
}

String daySub(String key) {
  final t = now();
  final d = DateTime.parse(key);
  if (key == dayKey(t) || key == dayKey(t.add(const Duration(days: 1)))) {
    return '${weekdaysShort[d.weekday - 1]}, ${d.day} ${months[d.month - 1]}';
  }
  return '';
}

// ------------------------------------------------------------------ лента

class FeedView extends StatelessWidget {
  final AppState state;
  const FeedView({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final data = state.data;
    final t = now();
    final list = data == null
        ? <Start>[]
        : data.starts
              .where((s) => !s.pastAt(t) && state.filters.pass(s) && s.t0.isBefore(t.add(const Duration(days: 60))))
              .toList();
    return RefreshIndicator(
      onRefresh: state.load,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _Header(title: 'Старты', state: state),
          ),
          if (state.filters.any) SliverToBoxAdapter(child: _FilterLine(state: state)),
          if (data == null && state.loading)
            const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
          else if (data == null)
            SliverFillRemaining(
              child: _Empty(text: 'Нет связи, а сохранённого расписания ещё нет.\nПотяните вниз, чтобы повторить.'),
            )
          else if (list.isEmpty)
            SliverFillRemaining(
              child: _Empty(text: state.filters.any ? 'По фильтру ближайших стартов нет.' : 'Ближайших стартов нет.'),
            )
          else
            ..._grouped(context, list),
          if (data != null) SliverToBoxAdapter(child: _Freshness(state: state)),
          SliverToBoxAdapter(child: SizedBox(height: 24 + MediaQuery.of(context).padding.bottom)),
        ],
      ),
    );
  }

  List<Widget> _grouped(BuildContext context, List<Start> list) {
    final out = <Widget>[];
    String? day;
    var rows = <Start>[];
    void flush() {
      if (day == null) return;
      final items = List<Start>.of(rows);
      out.add(SliverToBoxAdapter(child: DayHeader(day: day!)));
      out.add(
        SliverList.separated(
          itemCount: items.length,
          itemBuilder: (c, i) => StartRow(start: items[i], state: state),
          separatorBuilder: (c, i) => Divider(height: 1, indent: 84, color: Palette.of(c).line),
        ),
      );
    }

    for (final s in list) {
      if (s.day != day) {
        flush();
        day = s.day;
        rows = [];
      }
      rows.add(s);
    }
    flush();
    return out;
  }
}

class _Header extends StatelessWidget {
  final String title;
  final AppState state;
  final bool filter;
  const _Header({required this.title, required this.state, this.filter = true});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -.6, color: p.ink),
            ),
          ),
          if (filter && state.data != null)
            IconButton(
              tooltip: 'Фильтр',
              onPressed: () => showFilters(context, state),
              icon: Badge(
                isLabelVisible: state.filters.any,
                label: Text('${state.filters.count}'),
                child: Icon(Icons.tune_rounded, color: p.ink),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterLine extends StatelessWidget {
  final AppState state;
  const _FilterLine({required this.state});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final f = state.filters;
    final names = <String>[
      ...f.kinds.map((k) => kindNames[k] ?? k),
      ...f.athletes.map((a) => a.split(' / ').map((x) => x.split(' ').last).join(' / ')),
      if (f.tids.isNotEmpty) f.tids.length == 1 ? _tournamentName(state, f.tids.first) : '${f.tids.length} турнира',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              names.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.ink2, fontSize: 14),
            ),
          ),
          TextButton(onPressed: () => state.setFilters(const Filters({}, {}, {})), child: const Text('Сбросить')),
        ],
      ),
    );
  }
}

String _tournamentName(AppState s, String tid) =>
    s.data!.starts.firstWhere((x) => x.tid == tid, orElse: () => s.data!.starts.first).tournament;

const kindNames = {'women': 'Девушки', 'men': 'Мужчины', 'pairs': 'Пары', 'dance': 'Танцы'};

class DayHeader extends StatelessWidget {
  final String day;
  const DayHeader({super.key, required this.day});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final sub = daySub(day);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            dayTitle(day),
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: p.ink),
          ),
          if (sub.isNotEmpty) ...[const SizedBox(width: 8), Text(sub, style: TextStyle(fontSize: 14, color: p.ink3))],
        ],
      ),
    );
  }
}

/// Строка старта: время, что за сегмент, кто из наших и когда выходит.
class StartRow extends StatelessWidget {
  final Start start;
  final AppState state;
  const StartRow({super.key, required this.start, required this.state});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = start;
    final t = now();
    final live = s.liveAt(t);
    final watched = state.watched.contains(s.id);
    // у идущего старта показываем только тех, кто ещё не откатал
    var ours = s.ours;
    if (live) {
      ours = ours.where((o) {
        final at = s.skateAt(o);
        return at == null || at.add(const Duration(minutes: 4)).isAfter(t);
      }).toList();
    }
    final shown = ours.take(3).toList();
    return InkWell(
      onTap: () => showStart(context, s, state),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hm(s.t0),
                    style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                      color: live ? p.live : p.ink,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (live)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'идёт',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: p.live),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          cap(s.segment),
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.2, color: p.ink),
                        ),
                      ),
                      if (watched) Icon(Icons.notifications_active, size: 18, color: p.accent),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [s.tournament, if (s.broadcast.isNotEmpty) s.broadcast.join(' / ')].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: p.ink2, height: 1.3),
                  ),
                  if (shown.isNotEmpty) const SizedBox(height: 6),
                  for (final o in shown) _OursLine(o: o),
                  if (ours.length > shown.length)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('и ещё ${ours.length - shown.length}', style: TextStyle(fontSize: 13.5, color: p.ink3)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OursLine extends StatelessWidget {
  final Skater o;
  final bool full;
  const _OursLine({required this.o, this.full = false});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final left = o.time ?? (o.no != null ? '${o.no}-й' : '');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          if (left.isNotEmpty)
            SizedBox(
              width: 50,
              child: Text(
                left,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: o.time != null ? FontWeight.w600 : FontWeight.w400,
                  color: o.time != null ? p.ink : p.ink3,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: full ? o.name : o.short),
                  if (o.time == null && o.warmup != null)
                    TextSpan(
                      text: '  разминка ${o.warmup}',
                      style: TextStyle(color: p.ink3, fontSize: 13.5),
                    ),
                ],
              ),
              maxLines: full ? 3 : 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, color: p.ink, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

class _Freshness extends StatelessWidget {
  final AppState state;
  const _Freshness({required this.state});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final g = state.data!.generated;
    final when = dayKey(g) == dayKey(now()) ? 'сегодня в ${hm(g)}' : '${msk(g).day} ${months[msk(g).month - 1]} в ${hm(g)}';
    final stale = now().difference(g).inHours >= 16;
    final text = state.offline
        ? 'Нет сети · расписание от $when'
        : stale
        ? 'Источники не отвечают · расписание от $when'
        : 'Обновлено $when · время московское';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: state.offline || stale ? p.live : p.ink3),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty({required this.text});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, color: Palette.of(context).ink2, height: 1.4),
      ),
    ),
  );
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
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Header(
            title: '${monthsNom[month.month - 1]} ${month.year == msk(now()).year ? '' : month.year}'.trim(),
            state: state,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () => setState(() => month = DateTime(month.year, month.month - 1)),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => setState(() => month = DateTime(month.year, month.month + 1)),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                Row(
                  children: [
                    for (var i = 0; i < 7; i++)
                      Expanded(
                        child: Center(
                          child: Text(
                            weekdaysShort[i].toUpperCase(),
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: .6,
                              color: i > 4 ? p.ink2 : p.ink3,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                for (var r = 0; r < cells ~/ 7; r++)
                  Row(children: [for (var c = 0; c < 7; c++) _cell(context, r * 7 + c - lead + 1, days, byDay, today)]),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(child: DayHeader(day: selected)),
        if (dayList.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Text('Стартов нет', style: TextStyle(color: p.ink3, fontSize: 15)),
            ),
          )
        else
          SliverList.separated(
            itemCount: dayList.length,
            itemBuilder: (c, i) => StartRow(start: dayList[i], state: state),
            separatorBuilder: (c, i) => Divider(height: 1, indent: 84, color: p.line),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  Widget _cell(BuildContext context, int d, int days, Map<String, List<Start>> byDay, String today) {
    final p = Palette.of(context);
    if (d < 1 || d > days) return const Expanded(child: SizedBox(height: 52));
    final key = '${month.year}-${two(month.month)}-${two(d)}';
    final list = byDay[key] ?? [];
    final sel = key == selected;
    final isToday = key == today;
    final hasOurs = list.any((s) => s.ours.isNotEmpty);
    final hasWatch = list.any((s) => widget.state.watched.contains(s.id));
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => selected = key),
        child: SizedBox(
          height: 52,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: sel ? p.ink : null,
                  border: isToday && !sel ? Border.all(color: p.accent, width: 1.6) : null,
                ),
                child: Text(
                  '$d',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: isToday || sel ? FontWeight.w700 : FontWeight.w500,
                    color: sel ? p.bg : (isToday ? p.accent : p.ink),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: list.isEmpty
                      ? Colors.transparent
                      : hasWatch
                      ? p.accent
                      : (hasOurs ? p.ink2 : p.ink3.withValues(alpha: .5)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ мои

class MineView extends StatelessWidget {
  final AppState state;
  const MineView({super.key, required this.state});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = now();
    final list = (state.data?.starts ?? <Start>[]).where((s) => state.watched.contains(s.id) && !s.pastAt(t)).toList();
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Header(title: 'Мои', state: state, filter: false),
        ),
        if (list.isEmpty)
          SliverFillRemaining(
            child: _Empty(
              text: 'Здесь будут старты, которые вы отметили.\n\nОткройте старт и нажмите «Смотрю» — за 15 минут до начала придёт напоминание.',
            ),
          )
        else ...[
          for (final day in list.map((s) => s.day).toSet()) ...[
            SliverToBoxAdapter(child: DayHeader(day: day)),
            SliverList.separated(
              itemCount: list.where((s) => s.day == day).length,
              itemBuilder: (c, i) => StartRow(start: list.where((s) => s.day == day).elementAt(i), state: state),
              separatorBuilder: (c, i) => Divider(height: 1, indent: 84, color: p.line),
            ),
          ],
        ],
      ],
    );
  }
}

// ------------------------------------------------------------------ карточка старта

void showStart(BuildContext context, Start s, AppState state) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) => ListenableBuilder(
      listenable: state,
      builder: (c, _) => _StartSheet(s: s, state: state),
    ),
  );
}

class _StartSheet extends StatelessWidget {
  final Start s;
  final AppState state;
  const _StartSheet({required this.s, required this.state});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = now();
    final watched = state.watched.contains(s.id);
    final live = s.liveAt(t);
    final d = msk(s.t0);
    final canRemind = s.t0.subtract(const Duration(minutes: 15)).isAfter(t);
    return Padding(
      padding: EdgeInsets.fromLTRB(22, 0, 22, 18 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.tournament, style: TextStyle(fontSize: 15, color: p.ink2)),
          const SizedBox(height: 2),
          Text(
            cap(s.segment),
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -.4, color: p.ink),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                hm(s.t0),
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  color: live ? p.live : p.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  live ? 'идёт сейчас' : '${weekdays[d.weekday - 1]}, ${d.day} ${months[d.month - 1]}',
                  style: TextStyle(
                    fontSize: 15,
                    color: live ? p.live : p.ink2,
                    fontWeight: live ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
          if (s.ours.isNotEmpty) ...[
            const SizedBox(height: 18),
            _Label(s.ours.any((o) => o.time != null) ? 'Наши · выход на лёд' : 'Наши'),
            for (final o in s.ours) _OursLine(o: o, full: true),
          ],
          if (s.broadcast.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Label('Где смотреть'),
            Text(s.broadcast.join(' / '), style: TextStyle(fontSize: 16, color: p.ink)),
          ],
          const SizedBox(height: 16),
          _Label('Место'),
          Text(s.venue, style: TextStyle(fontSize: 16, color: p.ink)),
          const SizedBox(height: 22),
          if (canRemind || watched)
            SizedBox(
              width: double.infinity,
              height: 52,
              child: watched
                  ? OutlinedButton.icon(
                      onPressed: () => state.toggleWatch(s.id),
                      icon: const Icon(Icons.notifications_active),
                      label: const Text(
                        'Смотрю · напомню за 15 минут',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: p.accent,
                        side: BorderSide(color: p.accent, width: 1.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: () => state.toggleWatch(s.id),
                      icon: const Icon(Icons.notifications_none),
                      label: const Text('Смотрю', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      style: FilledButton.styleFrom(
                        backgroundColor: p.accent,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
            ),
          if (s.src.isNotEmpty)
            Center(
              child: TextButton(
                onPressed: () => launchUrl(Uri.parse(s.src), mode: LaunchMode.externalApplication),
                child: Text('Протокол турнира', style: TextStyle(color: p.ink3, fontSize: 13.5)),
              ),
            ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Palette.of(context).ink3),
    ),
  );
}

// ------------------------------------------------------------------ фильтр

void showFilters(BuildContext context, AppState state) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) => _FilterSheet(state: state),
  );
}

class _FilterSheet extends StatefulWidget {
  final AppState state;
  const _FilterSheet({required this.state});
  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late Set<String> kinds = {...widget.state.filters.kinds};
  late Set<String> tids = {...widget.state.filters.tids};
  late Set<String> athletes = {...widget.state.filters.athletes};
  String q = '';

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = widget.state.data!;
    final t = now();
    final tours = <String, String>{};
    for (final s in data.starts) {
      if (!s.pastAt(t)) tours.putIfAbsent(s.tid, () => s.tournament);
    }
    final all = <String>{...data.watchlist};
    for (final s in data.starts) {
      if (s.pastAt(t)) continue;
      all.addAll(s.ours.map((o) => o.name));
      all.addAll(s.athletes);
    }
    final found = q.isEmpty ? athletes.toList() : (all.where((a) => norm(a).contains(norm(q))).toList()..sort()).take(8).toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .85,
      maxChildSize: .95,
      builder: (c, scroll) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
              children: [
                Text(
                  'Фильтр',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: p.ink),
                ),
                const SizedBox(height: 16),
                _Label('Вид'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final k in kindNames.entries)
                      FilterChip(
                        label: Text(k.value),
                        selected: kinds.contains(k.key),
                        onSelected: (v) => setState(() => v ? kinds.add(k.key) : kinds.remove(k.key)),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                _Label('Спортсмен'),
                TextField(
                  decoration: InputDecoration(
                    hintText: 'Фамилия',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: p.bg,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  ),
                  onChanged: (v) => setState(() => q = v.trim()),
                ),
                for (final a in found)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: athletes.contains(a),
                    title: Text(a),
                    onChanged: (v) => setState(() => v == true ? athletes.add(a) : athletes.remove(a)),
                  ),
                const SizedBox(height: 16),
                _Label('Турнир'),
                for (final e in tours.entries)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: tids.contains(e.key),
                    title: Text(e.value),
                    onChanged: (v) => setState(() => v == true ? tids.add(e.key) : tids.remove(e.key)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(22, 8, 22, 12 + MediaQuery.of(context).padding.bottom),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() {
                      kinds.clear();
                      tids.clear();
                      athletes.clear();
                    }),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('Сбросить'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () {
                      widget.state.setFilters(Filters(kinds, tids, athletes));
                      Navigator.pop(context);
                    },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      backgroundColor: p.accent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('Показать', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
