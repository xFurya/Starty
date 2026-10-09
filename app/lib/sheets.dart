// Нижние листы: карточка старта (уведомление, пьедестал, итог, наши) и фильтр ленты.
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'data.dart';
import 'main.dart';
import 'protocol.dart';
import 'state.dart';
import 'ui.dart';
import 'views.dart';

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
    final live = s.liveAt(t);
    final past = s.pastAt(t);
    final d = msk(s.t0);
    final (disc, seg) = splitSegment(s.segment);
    // «9 октября» не разрывается
    final date = '${cap(weekdays[d.weekday - 1])}, ${d.day}\u00A0${months[d.month - 1]}';
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final notify = _notifyRow(context, t);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .92),
      child: SheetScroll(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // шапка: лёд, турнир, вид и сегмент; растёт вместе со шрифтом
            Stack(
              children: [
                Positioned.fill(child: IceBackdrop(fadeTo: p.sheet, fadeStart: .25, sparkles: 2)),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 132, minWidth: double.infinity),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(22, 36, 22, 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Eyebrow(s.tournament, color: p.accent),
                          const SizedBox(height: 8),
                          Text(disc, style: display(p, 42)),
                          if (seg.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              segNames[seg]!,
                              style: display(p, 25, italic: true, color: p.ink2, weight: FontWeight.w500),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (past)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
                child: Text(
                  '$date · ${hm(s.t0)}–${hm(s.t1)} · завершён',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.ink2, fontFeatures: tnum),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(hm(s.t0), style: clock(live ? p.live : p.ink, narrow ? 44 : 54)),
                    SizedBox(width: narrow ? 12 : 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (live)
                            const Padding(padding: EdgeInsets.only(bottom: 5), child: LivePill())
                          else if (s.day == dayKey(t) || s.day == dayKey(t.add(const Duration(days: 1))))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: Text(
                                whenLabel(s, t),
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: p.accent),
                              ),
                            ),
                          Text(
                            date,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.ink),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'до ${hm(s.t1)} · МСК',
                            style: TextStyle(fontSize: 13, color: p.ink2, fontFeatures: tnum),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (notify != null) Padding(padding: const EdgeInsets.only(top: 18), child: notify),
            if (past) ..._results(context) else ..._oursAhead(context, t),
            if (s.src.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                child: SheetButton(
                  neutral: true,
                  icon: CupertinoIcons.doc_text,
                  label: 'Протокол',
                  onTap: () => openProtocol(context, s.src, s.title),
                ),
              ),
            _section(
              context,
              'Подробности',
              Plate(
                child: Column(
                  children: [
                    _InfoRow(
                      icon: CupertinoIcons.tv,
                      label: 'Трансляция',
                      value: s.broadcast.isEmpty ? '—' : s.broadcast.join(' / '),
                    ),
                    const Hairline(indent: 52),
                    // место международных стартов — как в источнике, латиницей
                    _InfoRow(icon: CupertinoIcons.location, label: 'Место', value: s.venue.isEmpty ? '—' : s.venue),
                  ],
                ),
              ),
            ),
            SizedBox(height: 26 + MediaQuery.paddingOf(context).bottom),
          ],
        ),
      ),
    );
  }

  /// Строка уведомления о начале. Старт начался — строки нет.
  Widget? _notifyRow(BuildContext context, DateTime t) {
    final p = Palette.of(context);
    if (!s.t0.isAfter(t)) return null;
    if (!state.rules.on) {
      return _NotifyPlate(
        icon: CupertinoIcons.bell_slash,
        iconColor: p.ink2,
        title: 'Уведомления выключены',
        onTap: () {
          Navigator.of(context).pop();
          homeTab.value = tabSettings;
        },
        trailing: Icon(CupertinoIcons.chevron_right, size: 17, color: p.ink3),
      );
    }
    if (state.allowed == false) {
      return _NotifyPlate(
        icon: CupertinoIcons.bell_slash,
        iconColor: p.live,
        title: 'Запрещены в системе',
        trailing: TextButton(
          onPressed: state.askPermission,
          style: TextButton.styleFrom(
            foregroundColor: p.accent,
            textStyle: const TextStyle(fontFamily: 'Manrope', fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
          child: const Text('Разрешить'),
        ),
      );
    }
    // до начала меньше, чем «заранее»: уведомлять уже поздно
    if (!s.t0.subtract(Duration(minutes: state.rules.lead)).isAfter(t)) return null;
    final at = state.notifyAt(s);
    final on = at != null;
    return _NotifyPlate(
      icon: on ? CupertinoIcons.bell_fill : CupertinoIcons.bell_slash,
      iconColor: on ? p.accent : p.ink3,
      title: on ? 'Уведомление в\u00A0${hm(at)}' : 'Без уведомления',
      subtitle: state.isException(s) ? 'исключение из правил' : null,
      onTap: () => state.toggleStart(s),
      trailing: ExcludeSemantics(
        child: Switch(value: on, onChanged: (_) => state.toggleStart(s)),
      ),
      toggled: on,
    );
  }

  /// Завершённый сегмент: пьедестал, итог турнира, наши вне тройки.
  List<Widget> _results(BuildContext context) {
    final podium = [...s.podium]..sort((a, b) => a.place.compareTo(b.place));
    final top3 = podium.where((x) => x.place <= 3).toList();
    final onPodium = {for (final x in top3) norm(x.name)};
    final rest = s.ours.where((o) {
      if (onPodium.contains(norm(o.name))) return false;
      // тройка без имени нашего, но место в тройке — всё равно на пьедестале
      if (top3.isNotEmpty && o.place != null && o.place! <= 3) return false;
      return true;
    }).toList()..sort((a, b) => (a.place ?? 999).compareTo(b.place ?? 999));
    return [
      _section(
        context,
        'Тройка · ${s.seg.isEmpty ? 'сегмент' : s.seg}',
        top3.isEmpty
            ? const EmptyPlate('Итогов пока нет')
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Podium(list: top3, data: state.data, intl: s.intl),
              ),
      ),
      if (s.total.isNotEmpty) _section(context, 'Итог турнира', _TotalPlate(list: s.total, data: state.data, intl: s.intl)),
      if (rest.isNotEmpty)
        _section(
          context,
          'Наши',
          Plate(
            child: Column(
              children: [
                for (var i = 0; i < rest.length; i++) ...[
                  if (i > 0) Hairline(indent: rest.any(isPair) ? 92 : 70),
                  _OurResult(o: rest[i], seg: s.seg, data: state.data, slot: rest.any(isPair)),
                ],
              ],
            ),
          ),
        ),
    ];
  }

  /// Предстоящий или идущий сегмент: наши со временем выхода.
  List<Widget> _oursAhead(BuildContext context, DateTime t) {
    if (s.ours.isEmpty) return const [];
    return [
      _section(
        context,
        s.ours.any((o) => o.time != null) ? 'Наши · выход на лёд' : 'Наши',
        Plate(
          child: Column(
            children: [
              for (var i = 0; i < s.ours.length; i++) ...[
                if (i > 0) Hairline(indent: s.ours.any(isPair) ? 92 : 70),
                _OurAhead(o: s.ours[i], s: s, state: state, t: t, slot: s.ours.any(isPair)),
              ],
            ],
          ),
        ),
      ),
    ];
  }

  Widget _section(BuildContext context, String label, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Eyebrow(label, padding: const EdgeInsets.fromLTRB(22, 0, 22, 10)),
        child,
      ],
    ),
  );
}

/// Плашка уведомления: значок, «Уведомление в 17:15», переключатель.
class _NotifyPlate extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final Widget trailing;
  final VoidCallback? onTap;
  final bool? toggled;
  const _NotifyPlate({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.trailing,
    this.subtitle,
    this.onTap,
    this.toggled,
  });
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Plate(
      child: Semantics(
        toggled: toggled,
        button: toggled == null && onTap != null,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: iconColor.withValues(alpha: .12)),
                    child: Icon(icon, size: 18, color: iconColor),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: p.ink, fontFeatures: tnum),
                        ),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(subtitle!, style: TextStyle(fontSize: 13, color: p.ink2)),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Пьедестал: 2 — 1 — 3, фото на ледяных ступенях.
class Podium extends StatelessWidget {
  final List<Placing> list;
  final Schedule? data;
  final bool intl;
  const Podium({super.key, required this.list, required this.data, required this.intl});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final byPlace = {for (final x in list) x.place: x};
    final order = [2, 1, 3].where(byPlace.containsKey).toList();
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final pl in order) ...[
              if (pl != order.first) const SizedBox(width: 6),
              Expanded(
                child: _Step(x: byPlace[pl]!, data: data, intl: intl),
              ),
            ],
          ],
        ),
        // кромка льда под пьедесталом
        Container(
          height: 1.5,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [p.plateLine.withValues(alpha: 0), p.accent.withValues(alpha: .45), p.plateLine.withValues(alpha: 0)],
            ),
          ),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final Placing x;
  final Schedule? data;
  final bool intl;
  const _Step({required this.x, required this.data, required this.intl});

  /// Золото, серебро, бронза: кант ступени, ободок фото и цифра.
  static Color metal(int place, bool dark) => switch (place) {
    1 => dark ? const Color(0xFFE9C766) : const Color(0xFFC9992B),
    2 => dark ? const Color(0xFFC7D2DD) : const Color(0xFF8E9CAA),
    _ => dark ? const Color(0xFFDA9B6A) : const Color(0xFFB0703F),
  };
  static Color numeral(int place, bool dark) => switch (place) {
    1 => dark ? const Color(0xFFF1D58A) : const Color(0xFF8A6512),
    2 => dark ? const Color(0xFFDCE4EC) : const Color(0xFF55636F),
    _ => dark ? const Color(0xFFE7B48C) : const Color(0xFF834C22),
  };

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final first = x.place == 1;
    final c = metal(x.place, p.isDark);
    final avatar = first ? 70.0 : 56.0;
    final step = switch (x.place) {
      1 => 76.0,
      2 => 58.0,
      _ => 46.0,
    };
    final pair = x.name.contains(' / ');
    final ours = intl && x.ours;
    final code = ours || x.nation.isEmpty ? '' : (intl ? nationCode(x.nation) : x.nation);
    return Column(
      children: [
        Avatar(name: x.name, data: data, size: avatar, ring: c, ringWidth: 2.5),
        const SizedBox(height: 8),
        Text(
          pair ? surname(x.name).replaceAll(' / ', ' /\n') : surname(x.name),
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: pair ? 13 : 14.5,
            fontWeight: first ? FontWeight.w800 : FontWeight.w700,
            color: ours ? p.accent : p.ink,
            height: 1.2,
          ),
        ),
        if (code.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              code,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: .9, color: intl ? p.ink2 : p.ink3),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 3, bottom: 8),
          child: Text(x.points.isEmpty ? '—' : x.points, style: clock(p.ink2, 16, weight: FontWeight.w500)),
        ),
        // ступень — прозрачный лёд с металлическим кантом
        Container(
          height: step,
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: p.isDark
                  ? [Color.lerp(const Color(0xFF1B3A5C), c, .10)!, const Color(0xFF0C1B2B)]
                  : [Colors.white, Color.lerp(const Color(0xFFDCEAF7), c, .08)!],
            ),
            border: Border.all(color: p.plateLine),
            boxShadow: [
              BoxShadow(
                color: (p.isDark ? Colors.black : Palette.deepBlue).withValues(alpha: p.isDark ? .25 : .06),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned(top: 0, left: 0, right: 0, height: 3, child: ColoredBox(color: c)),
              if (first)
                CustomPaint(painter: SparklePainter(p.isDark ? Colors.white : Palette.iceBlue, p.isDark ? .6 : .4, variant: 1)),
              Center(
                child: Text(
                  '${x.place}',
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontFamily: serif,
                    fontSize: first ? 46 : 36,
                    fontWeight: FontWeight.w700,
                    height: 1.0,
                    // цифры «в строку»: без выносных элементов, цифра целиком на ступени
                    fontFeatures: const [FontFeature.liningFigures()],
                    color: numeral(x.place, p.isDark),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Итог турнира: медаль, фото, имя, сумма.
class _TotalPlate extends StatelessWidget {
  final List<Placing> list;
  final Schedule? data;
  final bool intl;
  const _TotalPlate({required this.list, required this.data, required this.intl});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final rows = [...list]..sort((a, b) => a.place.compareTo(b.place));
    return Plate(
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Hairline(indent: 96),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
              child: Row(
                children: [
                  Medal(rows[i].place, size: 26),
                  const SizedBox(width: 10),
                  Avatar(name: rows[i].name, data: data, size: 36, slot: rows.any((x) => x.name.contains(' / '))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: PlacingName(
                      x: rows[i],
                      intl: intl,
                      size: 15,
                      weight: rows[i].place == 1 ? FontWeight.w700 : FontWeight.w600,
                      maxLines: 2,
                    ),
                  ),
                  if (rows[i].points.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(rows[i].points, style: clock(p.ink, 18, weight: FontWeight.w500)),
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

/// Наш вне тройки: место в сегменте крупно, итог — подписью.
class _OurResult extends StatelessWidget {
  final Skater o;
  final String seg;
  final Schedule? data;
  final bool slot;
  const _OurResult({required this.o, required this.seg, required this.data, required this.slot});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
      child: Row(
        children: [
          Avatar(name: o.name, data: data, size: 44, slot: slot),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName(o.name).replaceAll(' / ', ' /\n'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.ink, height: 1.25),
                ),
                if (o.overall != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'итог ${o.overall}',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.accent),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                o.place == null ? '—' : '${o.place}',
                style: TextStyle(
                  fontFamily: serif,
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  fontFeatures: const [FontFeature.liningFigures()],
                  color: p.ink,
                ),
              ),
              if (o.place != null && seg.isNotEmpty) Eyebrow('место · $seg'),
            ],
          ),
        ],
      ),
    );
  }
}

/// Наш на предстоящем или идущем старте: время выхода, номер, разминка.
class _OurAhead extends StatelessWidget {
  final Skater o;
  final Start s;
  final AppState state;
  final DateTime t;
  final bool slot;
  const _OurAhead({required this.o, required this.s, required this.state, required this.t, required this.slot});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final skate = s.skateAt(o);
    final skated = o.place != null || (skate != null && skate.add(const Duration(minutes: 4)).isBefore(t));
    final meta = [if (o.no != null) '№ ${o.no}', if (o.warmup != null) 'разминка ${o.warmup}'];
    if (meta.isEmpty && o.time == null) meta.add('порядок не объявлен');
    // отдельное уведомление о выходе — когда оно и правда стоит в плане
    final alertAt = skate?.subtract(Duration(minutes: state.rules.lead));
    final alert = state.rules.skaters && state.notifies(s) && alertAt != null && alertAt.isAfter(t)
        ? 'уведомление в ${hm(alertAt)}'
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
      child: Row(
        children: [
          Avatar(name: o.name, data: state.data, size: 44, slot: slot),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName(o.name).replaceAll(' / ', ' /\n'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.ink, height: 1.25),
                ),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(meta.join(' · '), style: TextStyle(fontSize: 13, color: p.ink2, height: 1.35)),
                  ),
                if (alert != null)
                  Text(
                    alert,
                    style: TextStyle(fontSize: 13, color: p.accent, fontWeight: FontWeight.w600, height: 1.35),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (o.place != null)
            Text(
              '${o.place}',
              style: TextStyle(
                fontFamily: serif,
                fontSize: 30,
                fontWeight: FontWeight.w700,
                height: 1,
                fontFeatures: const [FontFeature.liningFigures()],
                color: p.ink2,
              ),
            )
          else if (o.time != null)
            Text(o.time!, style: clock(skated ? p.ink2 : p.ink, 24, weight: FontWeight.w400)),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _InfoRow({required this.icon, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
      child: Row(
        children: [
          Icon(icon, size: 21, color: p.accent),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Eyebrow(label),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: value == '—' ? p.ink2 : p.ink),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ фильтр

void showFilters(BuildContext context, AppState state) {
  if (state.data == null) return;
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
  final _q = TextEditingController();
  String q = '';

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

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
    final found = q.isEmpty
        ? (athletes.toList()..sort())
        : (all.where((a) => norm(a).contains(norm(q))).toList()..sort()).take(8).toList();
    final canReset = kinds.isNotEmpty || tids.isNotEmpty || athletes.isNotEmpty || widget.state.filters.any;
    final count = feedPool(widget.state, Filters(kinds, tids, athletes), t).length;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .88,
      maxChildSize: .95,
      builder: (c, scroll) => Column(
        children: [
          const SizedBox(height: 22, child: SheetHandle()),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              children: [
                Text('Фильтр', style: display(p, 42)),
                const SizedBox(height: 20),
                const Eyebrow('Вид'),
                const SizedBox(height: 10),
                TileGrid(
                  keepGrid: true,
                  tiles: [
                    for (final k in kindNames.entries)
                      ChoiceTile(
                        label: k.value,
                        color: p.kind(k.key),
                        on: kinds.contains(k.key),
                        onTap: () => setState(() => kinds.contains(k.key) ? kinds.remove(k.key) : kinds.add(k.key)),
                      ),
                  ],
                ),
                const SizedBox(height: 26),
                const Eyebrow('Спортсмен'),
                const SizedBox(height: 10),
                TextField(
                  controller: _q,
                  style: TextStyle(fontSize: 15.5, color: p.ink),
                  decoration: InputDecoration(
                    hintText: 'Фамилия',
                    hintStyle: TextStyle(color: p.ink2),
                    prefixIcon: Icon(CupertinoIcons.search, size: 19, color: p.ink2),
                    suffixIcon: q.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Очистить',
                            icon: Icon(CupertinoIcons.xmark_circle_fill, size: 19, color: p.ink3),
                            onPressed: () => setState(() {
                              _q.clear();
                              q = '';
                            }),
                          ),
                    filled: true,
                    fillColor: p.plate,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: p.control.withValues(alpha: .6)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: p.accent, width: 1.4),
                    ),
                  ),
                  onChanged: (v) => setState(() => q = v.trim()),
                ),
                if (found.isNotEmpty) const SizedBox(height: 6),
                for (final a in found)
                  _CheckRow(
                    leading: Avatar(name: a, data: data, size: 34, slot: true),
                    title: displayName(a),
                    value: athletes.contains(a),
                    onTap: () => setState(() => athletes.contains(a) ? athletes.remove(a) : athletes.add(a)),
                  ),
                if (q.isNotEmpty && found.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text('Не найдено', style: TextStyle(color: p.ink2, fontSize: 15)),
                  ),
                const SizedBox(height: 26),
                const Eyebrow('Турнир'),
                const SizedBox(height: 4),
                for (final e in tours.entries)
                  _CheckRow(
                    title: e.value,
                    value: tids.contains(e.key),
                    onTap: () => setState(() => tids.contains(e.key) ? tids.remove(e.key) : tids.add(e.key)),
                  ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: p.sheet,
              border: Border(top: BorderSide(color: p.plateLine)),
            ),
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
            child: Row(
              children: [
                SheetButton(
                  neutral: true,
                  compact: true,
                  label: 'Сбросить',
                  onTap: canReset
                      ? () {
                          setState(() {
                            kinds.clear();
                            tids.clear();
                            athletes.clear();
                            _q.clear();
                            q = '';
                          });
                          widget.state.setFilters(const Filters({}, {}, {}));
                        }
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SheetButton(
                    filled: true,
                    label: count == 0 ? 'Стартов нет' : 'Показать $count ${plural(count, 'старт', 'старта', 'стартов')}',
                    onTap: count == 0
                        ? null
                        : () {
                            widget.state.setFilters(Filters(kinds, tids, athletes));
                            Navigator.pop(context);
                          },
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

class _CheckRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final bool value;
  final VoidCallback onTap;
  const _CheckRow({this.leading, required this.title, required this.value, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      checked: value,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      color: p.ink,
                      fontWeight: value ? FontWeight.w600 : FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SquareCheck(on: value),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
