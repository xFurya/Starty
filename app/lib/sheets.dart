// Нижние листы: карточка старта (уведомление, пьедестал, итог, наши) и фильтр ленты.
import 'dart:async' show scheduleMicrotask;
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'countries.dart';
import 'data.dart';
import 'main.dart';
import 'protocol.dart';
import 'state.dart';
import 'system.dart';
import 'ui.dart';
import 'views.dart';

// ------------------------------------------------------------------ карточка старта

void showStart(BuildContext context, Start s, AppState state) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    builder: (c) => _StartSheetHost(s: s, state: state),
  );
}

// Лист закрывается только когда палец отпущен: если к этому моменту его дотянули
// до нижней границы — закрываем, иначе плавно возвращаем наверх. Пока палец держится,
// окно ходит за ним и не исчезает.
class _StartSheetHost extends StatefulWidget {
  final Start s;
  final AppState state;
  const _StartSheetHost({required this.s, required this.state});

  @override
  State<_StartSheetHost> createState() => _StartSheetHostState();
}

class _StartSheetHostState extends State<_StartSheetHost> {
  @override
  Widget build(BuildContext context) => SwipeSurface(
    top: .92,
    builder: (sheetContext, scrollController) => ListenableBuilder(
      listenable: widget.state,
      builder: (c, _) => _StartSheet(s: widget.s, state: widget.state, scrollController: scrollController),
    ),
  );
}

class _StartSheet extends StatelessWidget {
  final Start s;
  final AppState state;
  final ScrollController scrollController;
  const _StartSheet({required this.s, required this.state, required this.scrollController});

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
        controller: scrollController,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // шапка: лёд, турнир, вид и сегмент; растёт вместе со шрифтом
            Stack(
              children: [
                Positioned.fill(child: IceBackdrop(fadeTo: p.sheet, fadeStart: .25, sparkles: -1)),
                // искры — над подписью турнира, на текст не ложатся
                const Positioned(top: 0, left: 0, right: 0, child: SheetSparkles()),
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
                          // название турнира есть только здесь — до двух строк, не обрезаем
                          Eyebrow(s.tournament, color: p.accent, maxLines: 2),
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
              // перенос — только между частями, интервал «09:00–13:20» не рвётся
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  children: [
                    for (final part in ['$date ·', '${hm(s.t0)}–${hm(s.t1)} ·', 'завершён'])
                      Text(
                        part,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.ink2, fontFeatures: tnum),
                      ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // время и так крупное: со шрифтом не растёт, место справа остаётся словам
                    Text(
                      hm(s.t0),
                      textScaler: TextScaler.noScaling,
                      style: clock(live ? p.live : p.ink, narrow ? 44 : 54),
                    ),
                    SizedBox(width: narrow ? 12 : 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (live)
                            const Padding(padding: EdgeInsets.only(bottom: 5), child: LivePill())
                          else if (s.day == dayKey(t) || s.day == dayKey(t.add(const Duration(days: 1))))
                            // «через 1 ч 50 мин» одной строкой: не помещается — мельче, а не по буквам
                            Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  whenLabel(s, t),
                                  maxLines: 1,
                                  softWrap: false,
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: p.accent),
                                ),
                              ),
                            ),
                          Text(
                            date,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.ink),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'до$nb${hm(s.t1)}$nb·$nbМСК',
                            style: TextStyle(fontSize: 13, color: p.ink2, fontFeatures: tnum),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (notify != null) Padding(padding: const EdgeInsets.only(top: 18), child: notify),
            // во время старта — места по ходу, с табло; после — итог
            if (past) ..._results(context) else ...[if (s.podium.isNotEmpty) _podium(context), ..._oursAhead(context, t)],
            if (s.facts.isNotEmpty) _section(context, 'Примечательное', _FactsPlate(facts: s.facts, data: state.data)),
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
                    // трансляции нет в данных — строки нет
                    if (s.broadcast.isNotEmpty) ...[
                      _InfoRow(icon: CupertinoIcons.tv, label: 'Трансляция', value: s.broadcast.join(' / ')),
                      const Hairline(indent: 52),
                    ],
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
        action: 'Разрешить',
        onAction: () => allowNotifications(state),
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
      // исключение — только когда оно и правда расходится с правилами
      subtitle: state.notifies(s) != state.rules.matches(s) ? 'исключение из правил' : null,
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
      _podium(context),
      if (s.total.isNotEmpty)
        _section(context, 'Итог турнира', _TotalPlate(list: s.total, data: state.data, intl: s.intl)),
      if (rest.isNotEmpty)
        _section(
          context,
          oursLabel(s.ours, intl: s.intl),
          Plate(
            child: MeasuredLayout(
              builder: (context, c) {
                final slot = rest.any(isPair);
                final full = _oursFull(context, c.maxWidth, rest, slot, (o) => _OurResult.right(context, o, s.seg));
                return Column(
                  children: [
                    for (var i = 0; i < rest.length; i++) ...[
                      if (i > 0) Hairline(indent: slot ? 92 : 70),
                      _OurResult(o: rest[i], seg: s.seg, data: state.data, slot: slot, full: full),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
    ];
  }

  /// Тройка сегмента. Пока протокол не утверждён — с пометкой «промежуточные».
  Widget _podium(BuildContext context) {
    final top3 = ([...s.podium]..sort((a, b) => a.place.compareTo(b.place))).where((x) => x.place <= 3).toList();
    return _section(
      context,
      podiumLabel(s),
      top3.isEmpty
          ? const EmptyPlate('Итогов пока нет')
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Podium(list: top3, data: state.data, intl: s.intl),
            ),
    );
  }

  /// Предстоящий или идущий сегмент: наши со временем выхода.
  List<Widget> _oursAhead(BuildContext context, DateTime t) {
    if (s.ours.isEmpty) return const [];
    return [
      _section(
        context,
        oursLabel(s.ours, exitTimes: s.ours.any((o) => o.time != null), intl: s.intl),
        Plate(
          child: MeasuredLayout(
            builder: (context, c) {
              final slot = s.ours.any(isPair);
              final full = _oursFull(context, c.maxWidth, s.ours, slot, (o) => _OurAhead.right(context, o));
              return Column(
                children: [
                  for (var i = 0; i < s.ours.length; i++) ...[
                    if (i > 0) Hairline(indent: slot ? 92 : 70),
                    _OurAhead(o: s.ours[i], s: s, state: state, t: t, slot: slot, full: full),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    ];
  }

  /// Полные имена у всех наших — только если у каждого полное имя помещается рядом
  /// с фото и тем, что справа (место, время выхода); иначе у всех фамилии.
  static bool _oursFull(BuildContext context, double width, List<Skater> list, bool slot, double Function(Skater) right) {
    // поля 14 и 16, фото 44 (у пар шире), зазоры 12 и 10
    final base = width - 14 - (slot ? Avatar.pairWidth(44) : 44) - 12 - 10 - 16;
    for (final o in list) {
      if (!allFull(context, [o.name], _oursStyle, base - right(o))) return false;
    }
    return true;
  }

  static const _oursStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25);

  Widget _section(BuildContext context, String label, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty) Eyebrow(label, padding: const EdgeInsets.fromLTRB(22, 0, 22, 10)),
        child,
      ],
    ),
  );
}

/// Плашка уведомления: значок, «Уведомление в 17:15», переключатель. Кнопка-действие
/// ([action]) встаёт под заголовок, если рядом с ней слово заголовка не помещается.
class _NotifyPlate extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final String? action;
  final VoidCallback? onAction;
  final VoidCallback? onTap;
  final bool? toggled;
  const _NotifyPlate({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.trailing,
    this.action,
    this.onAction,
    this.subtitle,
    this.onTap,
    this.toggled,
  });

  static const _actionStyle = TextStyle(fontFamily: 'Manrope', fontSize: 14.5, fontWeight: FontWeight.w700);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final titleStyle = TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: p.ink, fontFeatures: tnum);
    Widget? button(EdgeInsets padding) => action == null
        ? null
        : TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: p.accent,
              padding: padding,
              minimumSize: const Size(44, 44),
              textStyle: _actionStyle,
            ),
            child: Text(action!, maxLines: 1, softWrap: false),
          );
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
              child: MeasuredLayout(
                builder: (context, c) {
                  // заголовок рядом с кнопкой: 34 значок, 12 и 8 зазоры
                  final below =
                      action != null &&
                      actionBelow(context, c.maxWidth - 34 - 12 - 8, title, titleStyle, action!, _actionStyle);
                  final side = below ? trailing : (trailing ?? button(const EdgeInsets.symmetric(horizontal: 12)));
                  return Row(
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
                            Text(title, style: titleStyle),
                            if (subtitle != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(subtitle!, style: TextStyle(fontSize: 13, color: p.ink2)),
                              ),
                            if (below) button(const EdgeInsets.only(right: 12))!,
                          ],
                        ),
                      ),
                      if (side != null) ...[const SizedBox(width: 8), side],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Пьедестал: 2 — 1 — 3, фото на ледяных ступенях. Подписи у всех трёх одной высоты
/// и прижаты к ступени: высоту фото задают только ступени, а не длина имени или код страны
/// (код стоит в строке баллов: «GEO 123.44»).
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
    // у пары — по партнёру на строку
    final lines = list.map((x) => x.name.split(' / ').length).fold(1, math.max);
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final pl in order) ...[
              if (pl != order.first) const SizedBox(width: 6),
              Expanded(
                child: _Step(x: byPlace[pl]!, data: data, intl: intl, lines: lines),
              ),
            ],
          ],
        ),
        // кромка льда под пьедесталом
        Container(
          height: 1.5,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                p.plateLine.withValues(alpha: 0),
                p.accent.withValues(alpha: .45),
                p.plateLine.withValues(alpha: 0),
              ],
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

  /// Строк имени у самой длинной подписи пьедестала.
  final int lines;
  const _Step({required this.x, required this.data, required this.intl, required this.lines});

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
    final ours = intl && x.ours;
    final code = PlacingName.codeOf(x, intl);
    final nameStyle = TextStyle(
      fontSize: lines > 1 ? 13 : 14.5,
      fontWeight: first ? FontWeight.w800 : FontWeight.w700,
      color: ours ? p.accent : p.ink,
      height: 1.2,
    );
    final codeStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: .9,
      height: 1.0,
      color: p.ink2,
    );
    final pointsStyle = clock(p.ink2, 16, weight: FontWeight.w500);
    // подпись: фамилия (у пары — по партнёру на строку, длинная — мельче, но целиком),
    // ниже одной строкой код страны и баллы
    final sur = surname(x.name).split(' / ');
    Widget caption({bool ghost = false}) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (ghost)
          for (var i = 0; i < lines; i++) Text('И', style: nameStyle)
        else
          NameLines(
            variants: [
              [for (var i = 0; i < sur.length; i++) i < sur.length - 1 ? '${sur[i]} /' : sur[i]],
            ],
            style: nameStyle,
            center: true,
            semantics: code.isEmpty ? displayName(x.name) : '${displayName(x.name)} $code',
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                if (!ghost && code.isNotEmpty) ...[
                  ExcludeSemantics(child: Text(code, style: codeStyle)),
                  const SizedBox(width: 6),
                ],
                Text(ghost || x.points.isEmpty ? '—' : x.points, style: pointsStyle),
              ],
            ),
          ),
        ),
      ],
    );
    return Column(
      children: [
        Avatar(name: x.name, data: data, size: avatar, ring: c, ringWidth: 2.5),
        const SizedBox(height: 8),
        Stack(
          alignment: Alignment.bottomCenter,
          children: [
            // невидимая подпись наибольшей высоты задаёт высоту у всех трёх
            ExcludeSemantics(
              child: Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: caption(ghost: true),
              ),
            ),
            caption(),
          ],
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
                CustomPaint(
                  painter: SparklePainter(p.isDark ? Colors.white : Palette.iceBlue, p.isDark ? .6 : .4, variant: 1),
                ),
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
    final pairs = rows.any((x) => x.name.contains(' / '));
    // крупные баллы растут со шрифтом не больше чем на 10 %: место нужнее имени
    final scale = math.min(MediaQuery.textScalerOf(context).scale(1), 1.1);
    final pointsStyle = clock(p.ink, 18, weight: FontWeight.w500);
    return Plate(
      child: MeasuredLayout(
        builder: (context, c) {
          // место под имя: поля 14 и 16, медаль 26, аватар, зазоры, самые широкие баллы
          final points = rows
              .map((x) => x.points.isEmpty ? 0.0 : _width(x.points, pointsStyle, scale) + 8)
              .fold(0.0, math.max);
          final nameW = c.maxWidth - 14 - 26 - 10 - (pairs ? Avatar.pairWidth(36) : 36) - 10 - 16 - points;
          final codeStyle = TextStyle(fontSize: 15 * .76, fontWeight: FontWeight.w700, letterSpacing: .8, height: 1.25);
          // полные имена — только если помещаются у всех; иначе у всех короткие
          final full = allFull(
            context,
            [for (final x in rows) x.name],
            TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25),
            nameW,
            suffix: (i) {
              final code = PlacingName.codeOf(rows[i], intl);
              return code.isEmpty ? 0 : textWidth(context, code, codeStyle) + NameLines.gap;
            },
          );
          return _rows(context, rows, pairs, full, scale, pointsStyle);
        },
      ),
    );
  }

  static double _width(String text, TextStyle style, double scale) => (TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(scale),
  )..layout()).width;

  Widget _rows(BuildContext context, List<Placing> rows, bool pairs, bool full, double scale, TextStyle pointsStyle) {
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          // линия — под именем: 14 + медаль 26 + 10 + аватар (у пар шире) + 10
          if (i > 0) Hairline(indent: 60 + (pairs ? Avatar.pairWidth(36) : 36)),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
            child: Row(
              children: [
                Medal(rows[i].place, size: 26),
                const SizedBox(width: 10),
                Avatar(name: rows[i].name, data: data, size: 36, slot: pairs),
                const SizedBox(width: 10),
                Expanded(
                  child: PlacingName(
                    x: rows[i],
                    intl: intl,
                    short: !full,
                    size: 15,
                    weight: rows[i].place == 1 ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
                if (rows[i].points.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(rows[i].points, textScaler: TextScaler.linear(scale), style: pointsStyle),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Примечательное: рекорды, редкие прыжки, лучшие оценки сезона, взлёт по итогу.
class _FactsPlate extends StatelessWidget {
  final List<Fact> facts;
  final Schedule? data;
  const _FactsPlate({required this.facts, required this.data});

  static IconData iconOf(String kind) => switch (kind) {
    'record' => CupertinoIcons.rosette,
    'element' => CupertinoIcons.sparkles,
    'score' => CupertinoIcons.chart_bar_alt_fill,
    'place' => CupertinoIcons.arrow_up_right,
    _ => CupertinoIcons.star,
  };

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // сначала рекорды и редкие элементы, потом итоги и оценки — внутри вида как на табло
    const order = ['record', 'element', 'place', 'score'];
    int rank(Fact f) => order.indexOf(f.kind) * 1000 + this.facts.indexOf(f);
    final facts = [...this.facts]..sort((a, b) => rank(a).compareTo(rank(b)));
    return Plate(
      child: Column(
        children: [
          for (var i = 0; i < facts.length; i++) ...[
            if (i > 0) const Hairline(indent: 52),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(iconOf(facts[i].kind), size: 20, color: facts[i].kind == 'record' ? p.live : p.accent),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          facts[i].text,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink, height: 1.3),
                        ),
                        if (facts[i].who.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(facts[i].who, style: TextStyle(fontSize: 13.5, color: p.ink2, height: 1.3)),
                        ],
                      ],
                    ),
                  ),
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

  /// Полное имя (решается на весь список «Наши»).
  final bool full;
  const _OurResult({required this.o, required this.seg, required this.data, required this.slot, this.full = true});

  static const _placeStyle = TextStyle(
    fontFamily: serif,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    height: 1.0,
    fontFeatures: [FontFeature.liningFigures()],
  );

  /// Ширина правой колонки: место крупно и подпись «место · ПП».
  static double right(BuildContext context, Skater o, String seg) => math.max(
    textWidth(context, o.place == null ? '—' : '${o.place}', _placeStyle),
    o.place != null && seg.isNotEmpty ? textWidth(context, 'место · $seg'.toUpperCase(), Eyebrow.style(Colors.black)) : 0,
  );
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
                // пара — по партнёру на строку или фамилиями; партнёр не теряется
                NameLines(
                  variants: nameVariants(o.name, full: full, lines: 2),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.ink, height: 1.25),
                  semantics: displayName(o.name),
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
              Text(o.place == null ? '—' : '${o.place}', style: _placeStyle.copyWith(color: p.ink)),
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

  /// Полное имя (решается на весь список «Наши»).
  final bool full;
  const _OurAhead({
    required this.o,
    required this.s,
    required this.state,
    required this.t,
    required this.slot,
    this.full = true,
  });

  static const _placeStyle = TextStyle(
    fontFamily: serif,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    height: 1,
    fontFeatures: [FontFeature.liningFigures()],
  );
  static TextStyle _timeStyle(Color c) => clock(c, 24, weight: FontWeight.w400);

  /// Ширина правой колонки: место или время выхода.
  static double right(BuildContext context, Skater o) => o.place != null
      ? textWidth(context, '${o.place}', _placeStyle)
      : (o.time != null ? textWidth(context, o.time!, _timeStyle(Colors.black)) : 0);
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final skate = s.skateAt(o);
    final skated = o.place != null || (skate != null && skate.add(const Duration(minutes: 4)).isBefore(t));
    final meta = [if (o.no != null) '№$nb${o.no}', if (o.warmup != null) 'разминка$nb${o.warmup}'];
    if (meta.isEmpty && o.time == null) meta.add('порядок не объявлен');
    // отдельное уведомление о выходе — когда оно и правда стоит в плане и система его покажет
    final alertAt = skate?.subtract(Duration(minutes: state.rules.lead));
    final alert =
        state.rules.skaters && state.notifies(s) && state.allowed != false && alertAt != null && alertAt.isAfter(t)
        ? 'уведомление в$nb${hm(alertAt)}'
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
                NameLines(
                  variants: nameVariants(o.name, full: full, lines: 2),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.ink, height: 1.25),
                  semantics: displayName(o.name),
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
            Text('${o.place}', style: _placeStyle.copyWith(color: p.ink2))
          else if (o.time != null)
            Text(o.time!, style: _timeStyle(skated ? p.ink2 : p.ink)),
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

// ------------------------------------------------------------------ лист со свайпом

/// Лист настроек и выбора: тянется пальцем целиком, закрывается, только если его дотянули
/// ниже середины и отпустили; иначе возвращается наверх. Закрытие свайпом — без сохранения.
Future<T?> showSwipeSheet<T>(BuildContext context, Widget Function(BuildContext, ScrollController) builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    builder: (c) => _SwipeSheet(builder: builder),
  );
}

class _SwipeSheet extends StatefulWidget {
  final Widget Function(BuildContext, ScrollController) builder;
  const _SwipeSheet({required this.builder});
  @override
  State<_SwipeSheet> createState() => _SwipeSheetState();
}

class _SwipeSheetState extends State<_SwipeSheet> {
  @override
  Widget build(BuildContext context) {
    // клавиатура поиска не закрывает ни найденных, ни кнопок внизу
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SwipeSurface(top: .94, builder: widget.builder),
    );
  }
}

/// Поверхность листа, которую тянут пальцем (карточка старта, фильтр).
///
/// Решение — когда палец отпущен: дотянули ниже середины или смахнули быстро вниз —
/// закрыть, иначе плавно вернуть наверх. Быстрый жест лист дотягивает по инерции
/// и после отпускания — поэтому следим и за самим положением: лист ушёл вниз, пока палец
/// не касается, — закрываем. Иначе лист пропадал, а затемнение оставалось.
class SwipeSurface extends StatefulWidget {
  final double top;
  final Widget Function(BuildContext, ScrollController) builder;
  const SwipeSurface({super.key, required this.top, required this.builder});
  @override
  State<SwipeSurface> createState() => _SwipeSurfaceState();
}

class _SwipeSurfaceState extends State<SwipeSurface> {
  static const _dismiss = .5;
  static const _fling = 1100.0; // логических точек в секунду вниз
  final _sheet = DraggableScrollableController();
  int _pointers = 0;
  bool _closing = false;
  // скорость пальца — по двум последним точкам
  Offset? _lastPos;
  Duration? _lastTime;
  double _vy = 0;

  @override
  void initState() {
    super.initState();
    _sheet.addListener(_watch);
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  void _watch() {
    if (_pointers == 0 && _sheet.isAttached && _sheet.size <= _dismiss) _close();
  }

  void _settle() {
    if (!mounted || !_sheet.isAttached || _closing) return;
    final pulled = _sheet.size < widget.top - 0.04;
    if (_sheet.size <= _dismiss + 0.0001 || (pulled && _vy > _fling)) {
      _close();
    } else if (_sheet.size < widget.top - 0.0001) {
      _sheet.animateTo(widget.top, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    _sheet.removeListener(_watch);
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        _pointers++;
        _lastPos = e.position;
        _lastTime = e.timeStamp;
        _vy = 0;
      },
      onPointerMove: (e) {
        final t0 = _lastTime, p0 = _lastPos;
        if (t0 != null && p0 != null) {
          final dt = (e.timeStamp - t0).inMicroseconds / 1e6;
          if (dt > 0) _vy = (e.position.dy - p0.dy) / dt;
        }
        _lastPos = e.position;
        _lastTime = e.timeStamp;
      },
      onPointerUp: (_) {
        _pointers = (_pointers - 1).clamp(0, 10);
        scheduleMicrotask(_settle);
      },
      onPointerCancel: (_) {
        _pointers = (_pointers - 1).clamp(0, 10);
        scheduleMicrotask(_settle);
      },
      child: DraggableScrollableSheet(
        controller: _sheet,
        expand: false,
        initialChildSize: widget.top,
        minChildSize: 0,
        maxChildSize: widget.top,
        snap: false,
        shouldCloseOnMinExtent: false,
        builder: widget.builder,
      ),
    );
  }
}

/// Шапка листа: лёд и название; [trailing] — справа.
class _SheetTitle extends StatelessWidget {
  final String title;
  const _SheetTitle(this.title);
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Stack(
      children: [
        Positioned.fill(child: IceBackdrop(fadeTo: p.sheet, fadeStart: .25, sparkles: -1)),
        const Positioned(top: 0, left: 0, right: 0, child: SheetSparkles()),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 104, minWidth: double.infinity),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 34, 20, 4),
              child: Text(title, style: display(p, 40)),
            ),
          ),
        ),
      ],
    );
  }
}

/// Нижняя полоса листа: «Сбросить»/«Отменить» и главная кнопка — подтверждение.
class _SheetBar extends StatelessWidget {
  final String secondary;
  final VoidCallback? onSecondary;
  final String primary;
  final String? detail;
  final VoidCallback? onPrimary;
  const _SheetBar({
    required this.secondary,
    required this.onSecondary,
    required this.primary,
    required this.onPrimary,
    this.detail,
  });
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.sheet,
        border: Border(top: BorderSide(color: p.plateLine)),
      ),
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
      // левая кнопка — не шире 40 % ряда: главная остаётся главной
      child: LayoutBuilder(
        builder: (context, k) => Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: k.maxWidth * .4),
              child: SheetButton(neutral: true, compact: true, label: secondary, onTap: onSecondary),
            ),
            const SizedBox(width: 10),
            Expanded(child: SheetButton(filled: true, label: primary, detail: detail, onTap: onPrimary)),
          ],
        ),
      ),
    );
  }
}

/// Поиск спортсмена по фамилии.
class SearchBox extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const SearchBox({super.key, required this.controller, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return TextField(
      controller: controller,
      style: TextStyle(fontSize: 15.5, color: p.ink),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Фамилия',
        hintStyle: TextStyle(color: p.ink2),
        prefixIcon: Icon(CupertinoIcons.search, size: 19, color: p.ink2),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Очистить',
                icon: Icon(CupertinoIcons.xmark_circle_fill, size: 19, color: p.ink2),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        filled: true,
        fillColor: p.plate,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: p.control),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: p.accent, width: 1.4),
        ),
      ),
      onChanged: onChanged,
    );
  }
}

// ------------------------------------------------------------------ фильтр

void showFilters(BuildContext context, AppState state) {
  if (state.data == null) return;
  showSwipeSheet<void>(context, (c, scroll) => _FilterSheet(state: state, scroll: scroll));
}

class _FilterSheet extends StatefulWidget {
  final AppState state;
  final ScrollController scroll;
  const _FilterSheet({required this.state, required this.scroll});
  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late Set<String> kinds = {...widget.state.filters.kinds};
  late Set<String> levels = {...widget.state.filters.levels};
  late Set<String> scope = {...widget.state.filters.scope};
  late Set<String> tids = {...widget.state.filters.tids};
  late Set<String> athletes = {...widget.state.filters.athletes};
  final _q = TextEditingController();
  String q = '';

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _flip(Set<String> set, String k) => setState(() => set.contains(k) ? set.remove(k) : set.add(k));

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = widget.state.data!;
    final t = now();
    final f = Filters(kinds, tids, athletes, levels: levels, scope: scope);

    // турниры впереди: со стартами в расписании и без расписания; российские и международные отдельно
    final tours = <String, ({String name, bool intl, String from, String to})>{};
    for (final s in data.starts) {
      if (s.pastAt(t)) continue;
      final d = dayKey(s.t0);
      final have = tours[s.tid];
      tours[s.tid] = (
        name: s.tournament,
        intl: s.intl,
        from: have == null || d.compareTo(have.from) < 0 ? d : have.from,
        to: have == null || d.compareTo(have.to) > 0 ? d : have.to,
      );
    }
    final today = dayKey(t), horizon = dayKey(t.add(const Duration(days: 60)));
    for (final u in data.upcoming) {
      if (u.end.compareTo(today) < 0 || u.start.compareTo(horizon) >= 0) continue;
      tours.putIfAbsent(u.tid, () => (name: u.name, intl: u.intl, from: u.start, to: u.end));
    }
    final byDate = tours.entries.toList()..sort((a, b) => a.value.from.compareTo(b.value.from));
    List<MapEntry<String, ({String name, bool intl, String from, String to})>> group(bool intl) =>
        [for (final e in byDate) if (e.value.intl == intl && (scope.isEmpty || scope.contains(intl ? 'intl' : 'russian'))) e];

    final follow = widget.state.follow.names;
    final found = q.isEmpty ? const <String>[] : searchAthletes(data, q, soon: soonAthletes(data, t));
    final picked = athletes.toList()..sort();
    final quick = [for (final a in follow.toList()..sort()) if (!athletes.contains(a)) a];

    final count = feedPool(widget.state, f, t).length;
    final more = upcomingAhead(widget.state, t, f).length;
    final action = filterAction(count, more);
    final canReset = f.any || widget.state.filters.any;

    Widget athleteRow(String a) => _CheckRow(
      leading: Avatar(name: a, data: data, size: 34, slot: true),
      title: displayName(a),
      subtitle: _personLine(data, a),
      value: athletes.contains(a),
      onTap: () => _flip(athletes, a),
    );

    return Material(
      color: p.sheet,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                ListView(
                  controller: widget.scroll,
                  padding: EdgeInsets.zero,
                  children: [
                    const _SheetTitle('Фильтр'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Eyebrow('Старты'),
                          const SizedBox(height: 10),
                          TileGrid(
                            tiles: [
                              ChoiceTile(label: 'Российские', on: scope.contains('russian'), onTap: () => _flip(scope, 'russian')),
                              ChoiceTile(label: 'Международные', on: scope.contains('intl'), onTap: () => _flip(scope, 'intl')),
                            ],
                          ),
                          const SizedBox(height: 22),
                          const Eyebrow('Уровень'),
                          const SizedBox(height: 10),
                          TileGrid(
                            tiles: [
                              for (final l in levelNames.entries)
                                ChoiceTile(label: l.value, on: levels.contains(l.key), onTap: () => _flip(levels, l.key)),
                            ],
                          ),
                          const SizedBox(height: 22),
                          const Eyebrow('Вид'),
                          const SizedBox(height: 10),
                          TileGrid(
                            tiles: [
                              for (final k in kindNames.keys)
                                ChoiceTile(
                                  label: kindLabel(k, levels),
                                  color: p.kind(k),
                                  on: kinds.contains(k),
                                  onTap: () => _flip(kinds, k),
                                ),
                            ],
                          ),
                          const SizedBox(height: 26),
                          const Eyebrow('Спортсмены'),
                          const SizedBox(height: 10),
                          SearchBox(controller: _q, onChanged: (v) => setState(() => q = v.trim())),
                          const SizedBox(height: 6),
                          if (q.isNotEmpty) ...[
                            for (final a in found) athleteRow(a),
                            if (found.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                child: Text('Не найдено', style: TextStyle(color: p.ink2, fontSize: 15)),
                              ),
                          ] else ...[
                            for (final a in picked) athleteRow(a),
                            if (quick.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text('Отслеживаемые', style: TextStyle(fontSize: 13, color: p.ink2, fontWeight: FontWeight.w600)),
                              for (final a in quick) athleteRow(a),
                            ],
                          ],
                          for (final intl in [false, true])
                            if (group(intl).isNotEmpty) ...[
                              const SizedBox(height: 26),
                              Eyebrow(intl ? 'Международные' : 'Российские'),
                              const SizedBox(height: 4),
                              for (final e in group(intl))
                                _CheckRow(
                                  title: e.value.name,
                                  subtitle: dateRange(e.value.from, e.value.to),
                                  value: tids.contains(e.key),
                                  onTap: () => _flip(tids, e.key),
                                ),
                            ],
                        ],
                      ),
                    ),
                  ],
                ),
                const Positioned(top: 0, left: 0, right: 0, child: SheetHandle()),
              ],
            ),
          ),
          _SheetBar(
            secondary: 'Сбросить',
            onSecondary: canReset
                ? () {
                    setState(() {
                      kinds.clear();
                      levels.clear();
                      scope.clear();
                      tids.clear();
                      athletes.clear();
                      _q.clear();
                      q = '';
                    });
                  }
                : null,
            primary: action.$1,
            detail: action.$2,
            onPrimary: count + more == 0
                ? null
                : () {
                    widget.state.setFilters(f);
                    Navigator.pop(context);
                  },
          ),
        ],
      ),
    );
  }
}

/// Главная кнопка листа фильтра: сколько стартов покажет лента — с расписанием и без него
/// (у турнира без расписания один старт в ленте).
(String, String?) filterAction(int starts, int unscheduled) {
  final n = starts + unscheduled;
  if (n == 0) return ('Впереди стартов нет', null);
  return ('Показать $n ${plural(n, 'старт', 'старта', 'стартов')}', null);
}

/// Кто на стартах впереди — их в поиске выше.
Set<String> soonAthletes(Schedule data, DateTime t) => {
  for (final s in data.starts)
    if (!s.pastAt(t)) ...[...s.ours.map((o) => o.name), ...s.athletes],
  for (final u in data.upcoming) ...[...u.ours, ...u.athletes],
};

String? _personLine(Schedule data, String name) {
  final p = data.people[name];
  if (p == null) return null;
  final s = personLine(p.nation, p.kinds);
  return s.isEmpty ? null : s;
}

class _CheckRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final bool value;
  final VoidCallback onTap;
  const _CheckRow({this.leading, required this.title, this.subtitle, required this.value, required this.onTap});
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          color: p.ink,
                          fontWeight: value ? FontWeight.w600 : FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                      if (subtitle != null)
                        Text(subtitle!, style: TextStyle(fontSize: 13, color: p.ink2, height: 1.3)),
                    ],
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


/// Строка спортсмена с фото, страной и видом и отметкой выбора.
class AthleteCheckRow extends StatelessWidget {
  final String name;
  final Schedule? data;
  final bool value;
  final VoidCallback onTap;
  const AthleteCheckRow({super.key, required this.name, required this.data, required this.value, required this.onTap});
  @override
  Widget build(BuildContext context) => _CheckRow(
    leading: Avatar(name: name, data: data, size: 34, slot: true),
    title: displayName(name),
    subtitle: data == null ? null : _personLine(data!, name),
    value: value,
    onTap: onTap,
  );
}
