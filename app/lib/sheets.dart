// Нижние листы: карточка старта (уведомление, пьедестал, итог, наши) и фильтр ленты.
import 'dart:async' show scheduleMicrotask;
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'countries.dart';
import 'data.dart';
import 'flags.dart';
import 'main.dart';
import 'protocol.dart';
import 'state.dart';
import 'system.dart';
import 'ui.dart';
import 'views.dart';

// ------------------------------------------------------------------ карточка старта

/// Как открывается ссылка на трансляцию: в установленном приложении сервиса, иначе во встроенном
/// браузере — из приложения не выходим; в тестах подменяется.
Future<void> Function(BuildContext context, String url, String title) watchOpener = _openWatch;

Future<void> _openWatch(BuildContext context, String url, String title) => openLink(context, url, title, preferApp: true);

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
    // живые места: режим для этого старта, если у него есть табло и файл протокола — компактный чип.
    // Итог окончательный (settled, как в watching) — опрашивать нечего, чипа нет совсем.
    final liveChip = s.live != null && s.proto != null && !s.settled ? _LiveChip(state: state, start: s) : null;
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
            // время крупно слева; справа по строке: состояние, дата, конец по Москве.
            // У завершённого — то же, только время приглушено и вместо отсчёта «Завершён».
            Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // время и так крупное: со шрифтом не растёт, место справа остаётся словам
                    Text(
                      hm(s.t0),
                      textScaler: TextScaler.noScaling,
                      style: clock(live ? p.live : (past ? p.ink2 : p.ink), narrow ? 44 : 54),
                    ),
                    SizedBox(width: narrow ? 12 : 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (live)
                            const Padding(padding: EdgeInsets.only(bottom: 5), child: LivePill())
                          else if (past)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: Text(
                                'Завершён',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: p.ink2),
                              ),
                            )
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
                            'до$nb${hm(s.t1)}$nbМСК',
                            style: TextStyle(fontSize: 13, color: p.ink2, fontFeatures: tnum),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            // чип режима — под временем, слева, во всю ширину не растягивается
            if (liveChip != null) Padding(padding: const EdgeInsets.fromLTRB(22, 10, 22, 0), child: Align(alignment: Alignment.centerLeft, child: liveChip)),
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
                  onTap: () => openProtocol(context, s, state: state),
                ),
              ),
            _section(
              context,
              'Подробности',
              Plate(
                child: Column(
                  children: [
                    // трансляции нет в данных — строки нет
                    if (s.broadcast.isNotEmpty || s.watch.isNotEmpty) ...[
                      _InfoRow(
                        icon: CupertinoIcons.tv,
                        label: 'Трансляция',
                        value: s.watch.isNotEmpty ? s.watch.map((w) => w.name).join(', ') : s.broadcast.join(', '),
                        links: s.watch,
                      ),
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

  /// Тройка сегмента. Пока сегмент идёт — с пометкой «идёт».
  Widget _podium(BuildContext context) {
    final top3 = ([...s.podium]..sort((a, b) => a.place.compareTo(b.place))).where((x) => x.place <= 3).toList();
    return _section(
      context,
      podiumLabel(s),
      trailing: runningNote(s),
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
        // кто — слева, над колонкой времени справа — что это за время
        trailing: s.ours.any((o) => o.time != null) && oursLabel(s.ours, intl: s.intl).isNotEmpty ? 'выход на лёд' : '',
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

  /// Раздел листа: подпись слева, справа — пояснение к колонке или ход сегмента ([trailing]).
  Widget _section(BuildContext context, String label, Widget child, {String trailing = ''}) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty)
          Eyebrow(
            label,
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
            trailing: trailing.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(trailing.toUpperCase(), style: Eyebrow.style(Palette.of(context).ink2)),
                  ),
          ),
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
/// (флаг с кодом стоят под именем рядом с баллами).
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
            semantics: code.isEmpty ? displayName(x.name) : '${displayName(x.name)} ${NationTag.spoken(code)}',
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
                  ExcludeSemantics(child: NationTag(code, style: codeStyle)),
                  const SizedBox(width: 8),
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

/// Итог турнира: медаль, фото, имя, страна, сумма. Страна (флаг с кодом) и сумма — колонками
/// одной ширины: флаги и цифры стоят ровно друг под другом.
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
          // место под имя: поля 14 и 16, медаль 26, аватар, зазоры, колонки страны и баллов
          final points = rows.map((x) => x.points.isEmpty ? 0.0 : _width(x.points, pointsStyle, scale)).fold(0.0, math.max);
          final codeStyle = PlacingName.codeStyle(p, 15);
          final codes = [for (final x in rows) PlacingName.codeOf(x, intl)];
          var codeW = codes.map((c) => NationTag.widthOf(context, c, codeStyle)).fold(0.0, math.max);
          final nameStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25);
          double nameW(double codeW) =>
              c.maxWidth - 14 - 26 - 10 - (pairs ? Avatar.pairWidth(36) : 36) - 10 - 16 -
              (codeW > 0 ? codeW + 10 : 0) - (points > 0 ? points + 12 : 0);
          // тесно (узкий экран, крупный шрифт): рядом с колонкой страны хоть одно имя не помещается
          // даже коротким — у всех флаг с кодом встаёт под имя
          final under = codeW > 0 &&
              !rows.every((x) => nameVariants(x.name, full: false, initial: true, lines: 2).any((v) => NameLines.fits(context, v, nameStyle, nameW(codeW))));
          if (under) codeW = 0;
          // имена всегда сокращённые («В. Дикиджи»): полное у одного и короткое у другого выглядит странно
          return _rows(context, rows, pairs, scale, pointsStyle, codeW > 0 || under ? codes : null, codeW, points, codeStyle, under);
        },
      ),
    );
  }

  static double _width(String text, TextStyle style, double scale) => (TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(scale),
  )..layout()).width;

  Widget _rows(
    BuildContext context,
    List<Placing> rows,
    bool pairs,
    double scale,
    TextStyle pointsStyle,
    List<String>? codes,
    double codeW,
    double pointsW,
    TextStyle codeStyle,
    bool under,
  ) {
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PlacingName(
                        x: rows[i],
                        intl: intl,
                        short: true,
                        size: 15,
                        weight: rows[i].place == 1 ? FontWeight.w700 : FontWeight.w600,
                        withCode: false,
                      ),
                      if (under && codes![i].isNotEmpty)
                        Padding(padding: const EdgeInsets.only(top: 2), child: NationTag(codes[i], style: codeStyle)),
                    ],
                  ),
                ),
                if (codes != null && !under) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: codeW + 1,
                    child: Align(alignment: Alignment.centerLeft, child: NationTag(codes[i], style: codeStyle)),
                  ),
                ],
                if (pointsW > 0) ...[
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: pointsW + 9,
                      child: Text(
                        rows[i].points,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        softWrap: false,
                        textScaler: TextScaler.linear(scale),
                        style: pointsStyle,
                      ),
                    ),
                  ),
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

  /// Подпись под местом: что это за место.
  static String caption(String seg) => seg.isEmpty ? 'место' : 'место в $seg';

  /// Ширина правой колонки: место крупно и подпись «место в ПП».
  static double right(BuildContext context, Skater o, String seg) => math.max(
    textWidth(context, o.place == null ? '—' : '${o.place}', _placeStyle),
    o.place != null ? textWidth(context, caption(seg).toUpperCase(), Eyebrow.style(Colors.black)) : 0,
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
              if (o.place != null) Eyebrow(caption(seg)),
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

  /// Стартовый номер — подписью под временем выхода: «№ 5».
  static String? numberOf(Skater o) => o.no == null ? null : '№$nb${o.no}';

  /// Ширина правой колонки: место или время выхода и под ним стартовый номер.
  static double right(BuildContext context, Skater o) => math.max(
    o.place != null
        ? textWidth(context, '${o.place}', _placeStyle)
        : (o.time != null ? textWidth(context, o.time!, _timeStyle(Colors.black)) : 0),
    numberOf(o) == null || o.place != null ? 0 : textWidth(context, numberOf(o)!.toUpperCase(), Eyebrow.style(Colors.black)),
  );
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final skate = s.skateAt(o);
    final skated = o.place != null || (skate != null && skate.add(const Duration(minutes: 4)).isBefore(t));
    // под именем — разминка; стартовый номер — под временем справа
    final meta = o.warmup != null
        ? 'разминка$nb${o.warmup}'
        : (o.no == null && o.time == null ? 'порядок не объявлен' : null);
    final number = numberOf(o);
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
                if (meta != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(meta, style: TextStyle(fontSize: 13, color: p.ink2, height: 1.35)),
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (o.place != null)
                Text('${o.place}', style: _placeStyle.copyWith(color: p.ink2))
              else if (o.time != null)
                Text(o.time!, style: _timeStyle(skated ? p.ink2 : p.ink)),
              if (number != null && o.place == null) Padding(padding: const EdgeInsets.only(top: 3), child: Eyebrow(number)),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label, value;

  /// Названия со ссылкой: каждое — своя строка во всю ширину; пусто — обычная строка с текстом.
  final List<WatchLink> links;
  const _InfoRow({required this.icon, required this.label, required this.value, this.links = const []});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (links.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 0),
            child: Row(
              children: [
                Icon(icon, size: 21, color: p.accent),
                const SizedBox(width: 15),
                Expanded(child: Eyebrow(label)),
              ],
            ),
          ),
          for (var i = 0; i < links.length; i++) ...[
            if (i > 0) const Hairline(indent: 52),
            _WatchRow(link: links[i]),
          ],
        ],
      );
    }
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

/// Один ресурс трансляции: вся строка нажимается и открывает его ссылку во внешнем приложении.
/// Название переносится по словам; справа тихий значок акцентного цвета без заливки.
class _WatchRow extends StatelessWidget {
  final WatchLink link;
  const _WatchRow({required this.link});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: 'Открыть трансляцию: ${link.name}',
      child: InkWell(
        key: ValueKey('watch:${link.name}'),
        onTap: () => watchOpener(context, link.url, link.name),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            // отступ слева совпадает с текстом заголовка: 16 + 21 значок + 15
            padding: const EdgeInsets.fromLTRB(52, 12, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(link.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
                ),
                const SizedBox(width: 12),
                Icon(CupertinoIcons.arrow_up_right, size: 16, color: p.accent),
              ],
            ),
          ),
        ),
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

/// Шапка листа фильтра — закреплена: ручка, название и «Сбросить», только когда есть что
/// сбрасывать. Пока список прокручен, снизу — тонкая черта: список уходит под шапку.
class _FilterHeader extends StatelessWidget {
  final VoidCallback? onReset;
  final bool scrolled;
  const _FilterHeader({required this.onReset, required this.scrolled});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.sheet,
        border: Border(bottom: BorderSide(color: scrolled ? p.plateLine : p.sheet.withValues(alpha: 0))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 8, 4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: [
                  Expanded(child: Text('Фильтр', maxLines: 1, style: display(p, 28))),
                  if (onReset != null) _TextAction('Сбросить', onReset!),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Действие надписью цвета акцента; зона нажатия не меньше 44 pt.
class _TextAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _TextAction(this.label, this.onTap);
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      // начертание — на самой надписи: textStyle кнопки заменил бы шрифт приложения целиком
      child: Text(label, maxLines: 1, softWrap: false, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.accent)),
    );
  }
}

/// Нижняя полоса листа фильтра: одна главная кнопка — сколько стартов покажет лента.
class _SheetBar extends StatelessWidget {
  final String primary;
  final VoidCallback? onPrimary;
  const _SheetBar({required this.primary, required this.onPrimary});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.sheet,
        border: Border(top: BorderSide(color: p.plateLine)),
      ),
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
      child: SheetButton(filled: true, label: primary, onTap: onPrimary),
    );
  }
}

/// Нажатие на пункт группы фильтра, где «все» — без ограничения.
/// Были все — остаётся только нажатый. Иначе [many] — пункт добавляется или снимается,
/// без [many] — нажатый становится единственным. Не осталось ни одного или отмечены
/// все — снова все.
Set<String> pickChoice(Set<String> sel, Set<String> all, String k, {required bool many}) {
  final isAll = sel.length == all.length && sel.containsAll(all);
  if (isAll) return {k};
  final on = sel.contains(k);
  final next = many ? (on ? ({...sel}..remove(k)) : {...sel, k}) : (on ? <String>{} : {k});
  return next.isEmpty || next.containsAll(all) ? {...all} : next;
}

/// Группа фильтра чипами: «Все» и пункты. Выбранное — залито акцентом.
class _Choices extends StatelessWidget {
  final List<(String, String)> items;
  final Set<String> sel;
  final bool many;
  final Map<String, Color> dots;
  final ValueChanged<Set<String>> onChanged;
  const _Choices({required this.items, required this.sel, required this.onChanged, this.many = false, this.dots = const {}});
  @override
  Widget build(BuildContext context) {
    final all = {for (final (k, _) in items) k};
    final isAll = sel.length == all.length && sel.containsAll(all);
    return Wrap(
      spacing: 8,
      children: [
        _Chip(label: 'Все', on: isAll, onTap: () => onChanged({...all})),
        for (final (k, label) in items)
          _Chip(label: label, on: !isAll && sel.contains(k), dot: dots[k], onTap: () => onChanged(pickChoice(sel, all, k, many: many))),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool on;
  final Color? dot;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.on, required this.onTap, this.dot});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      selected: on,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // видимый чип 40 pt, зона нажатия 48
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: on ? p.accent : p.plate,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: on ? p.accent : p.control.withValues(alpha: .55), width: 1.2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (dot != null) ...[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dot,
                      border: on ? Border.all(color: p.onAccent, width: 1.5) : null,
                    ),
                  ),
                  const SizedBox(width: 7),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 14.5, height: 1.2, fontWeight: FontWeight.w600, color: on ? p.onAccent : p.ink),
                  ),
                ),
              ],
            ),
          ),
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

/// Подпись режима живых мест для строки и листа.
String liveModeLabel(String mode) => mode == liveDelayed ? 'С опозданием' : 'Моментально';

/// Живые места в карточке старта: маленький чип рядом со временем. Молния — табло раз в минуту,
/// часы — файл протокола. По нажатию — меню из трёх пунктов.
/// «Как в настройках» — переопределения для старта нет (Prefs.live.over без его id).
class _LiveChip extends StatelessWidget {
  final AppState state;
  final Start start;
  const _LiveChip({required this.state, required this.start});

  static const _asSettings = '';

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final own = state.liveOverrides[start.id];
    final mode = state.liveModeOf(start);
    return Builder(
      builder: (chipContext) => Tooltip(
        message: 'Живые места',
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () async {
            final v = await showChoiceMenu<String>(
              chipContext,
              label: 'Живые места',
              selected: own ?? _asSettings,
              items: const [(_asSettings, 'Как в настройках'), (liveInstant, 'Моментально'), (liveDelayed, 'С опозданием')],
            );
            if (v != null) state.setLiveOverride(start.id, v == _asSettings ? null : v);
          },
          // зона нажатия не меньше 44 pt, сам чип остаётся компактным
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Center(widthFactor: 1, child: _chip(p, mode)),
          ),
        ),
      ),
    );
  }

  Widget _chip(Palette p, String mode) {
    return Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: BoxDecoration(
          color: p.plate,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.plateLine),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(mode == liveDelayed ? CupertinoIcons.clock : CupertinoIcons.bolt_fill, size: 15, color: p.ink2),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                liveModeLabel(mode),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink, height: 1.2),
              ),
            ),
          ],
        ),
    );
  }
}

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
  // Старты, уровень, вид: «Все» — без ограничения, сохраняется пустым набором (Filters).
  static final _allKinds = kindNames.keys.toSet();
  static final _allLevels = levelNames.keys.toSet();
  static const _allScope = {'russian', 'intl'};
  late Set<String> kinds = _full(widget.state.filters.kinds, _allKinds);
  late Set<String> levels = _full(widget.state.filters.levels, _allLevels);
  late Set<String> scope = _full(widget.state.filters.scope, _allScope);
  // спортсмены и турниры: ничего не отмечено — все; отмеченные — только они
  late Set<String> tids = {...widget.state.filters.tids};
  late Set<String> athletes = {...widget.state.filters.athletes};

  /// Список отслеживаемых раскрыт, если среди них есть отмеченный: отметку не прячем.
  /// Иначе свёрнут — без отметок он лишь ярлыки и занимает пол-листа. Между открытиями
  /// листа не запоминается: каждый раз по тому же правилу, отметки и настройки не трогает.
  late bool _followOpen = widget.state.filters.athletes.any(widget.state.follow.names.contains);

  static Set<String> _full(Set<String> saved, Set<String> all) => saved.isEmpty ? {...all} : {...saved};

  /// Выбрано всё — это «без ограничения» (пустой набор).
  static Set<String> _save(Set<String> sel, Set<String> all) =>
      sel.length == all.length && sel.containsAll(all) ? <String>{} : {...sel};

  final _q = TextEditingController();
  String q = '';
  bool _scrolled = false;

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
        [for (final e in byDate) if (e.value.intl == intl && scope.contains(intl ? 'intl' : 'russian')) e];
    final groups = [for (final intl in [false, true]) if (group(intl).isNotEmpty) (intl, group(intl))];

    // отмеченный турнир, которого в списке нет (прошёл или скрыт выбором стартов), ленту не сужает
    final shownTids = {for (final g in groups) for (final e in g.$2) e.key};
    final pickedTids = tids.intersection(shownTids);
    final f = Filters(
      _save(kinds, _allKinds),
      pickedTids,
      athletes,
      levels: _save(levels, _allLevels),
      scope: _save(scope, _allScope),
    );

    final follow = widget.state.follow.names;
    final found = q.isEmpty ? const <String>[] : searchAthletes(data, q, soon: soonAthletes(data, t));
    // отслеживаемые стоят на своих местах и при отметке не прыгают; отмеченные из поиска — над ними
    final quick = follow.toList()..sort();
    final picked = [for (final a in athletes.toList()..sort()) if (!follow.contains(a)) a];

    final count = feedPool(widget.state, f, t).length;
    final more = upcomingAhead(widget.state, t, f).length;
    final action = filterAction(count, more);

    Widget athleteRow(String a) => _CheckRow(
      leading: Avatar(name: a, data: data, size: 34, slot: true),
      title: displayName(a),
      nation: data.people[a]?.nation ?? '',
      subtitle: _personLine(data, a),
      value: athletes.contains(a),
      onTap: () => _flip(athletes, a),
    );

    // заголовок раздела; есть отметки — справа «Снять отметки». Высота одна, чтобы не прыгало
    Widget head(String label, {VoidCallback? clear}) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Expanded(child: Eyebrow(label)),
          if (clear != null) _TextAction('Снять отметки', clear),
        ],
      ),
    );
    // что сейчас попадает в ленту из этого раздела
    Widget note(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: TextStyle(fontSize: 13.5, height: 1.35, color: p.ink2)),
    );
    Widget subhead(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: Text(text, style: TextStyle(fontSize: 13, height: 1.3, color: p.ink2, fontWeight: FontWeight.w600)),
    );
    Widget section(String label, Widget child) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [Eyebrow(label), const SizedBox(height: 4), child],
    );

    return Material(
      color: p.sheet,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: NotificationListener<ScrollUpdateNotification>(
              onNotification: (n) {
                final on = n.metrics.pixels > 0.5;
                if (on != _scrolled) setState(() => _scrolled = on);
                return false;
              },
              child: CustomScrollView(
                controller: widget.scroll,
                slivers: [
                  PinnedHeaderSliver(
                    child: _FilterHeader(
                      scrolled: _scrolled,
                      onReset: f.any
                          ? () => setState(() {
                              kinds = {..._allKinds};
                              levels = {..._allLevels};
                              scope = {..._allScope};
                              tids.clear();
                              athletes.clear();
                              _q.clear();
                              q = '';
                            })
                          : null,
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
                    sliver: SliverList.list(
                      children: [
                        section(
                          'Старты',
                          _Choices(
                            items: const [('russian', 'Российские'), ('intl', 'Международные')],
                            sel: scope,
                            onChanged: (v) => setState(() => scope = v),
                          ),
                        ),
                        const SizedBox(height: 12),
                        section(
                          'Уровень',
                          _Choices(
                            items: [for (final l in levelNames.entries) (l.key, l.value)],
                            sel: levels,
                            onChanged: (v) => setState(() => levels = v),
                          ),
                        ),
                        const SizedBox(height: 12),
                        section(
                          'Вид',
                          _Choices(
                            // оба уровня — короткие названия, как в настройках уведомлений:
                            // «Женщины (девушки)» не помещалась в строку
                            items: [for (final k in kindNames.keys) (k, levels.length == 1 ? kindLabel(k, levels) : kindNames[k]!)],
                            dots: {for (final k in kindNames.keys) k: p.kind(k)},
                            many: true,
                            sel: kinds,
                            onChanged: (v) => setState(() => kinds = v),
                          ),
                        ),
                        const SizedBox(height: 8),
                        head('Спортсмены', clear: athletes.isEmpty ? null : () => setState(athletes.clear)),
                        note(athletes.isEmpty ? 'Показаны все. Отметьте, чьи старты оставить.' : 'Показаны только отмеченные.'),
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
                          if (picked.isNotEmpty && quick.isNotEmpty) subhead('Отмеченные'),
                          for (final a in picked) athleteRow(a),
                          if (quick.isNotEmpty) ...[
                            _FoldHead(
                              label: 'Отслеживаемые',
                              total: quick.length,
                              marked: quick.where(athletes.contains).length,
                              open: _followOpen,
                              onTap: () => setState(() => _followOpen = !_followOpen),
                            ),
                            _Fold(
                              open: _followOpen,
                              child: Column(children: [for (final a in quick) athleteRow(a)]),
                            ),
                          ],
                        ],
                        if (groups.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          head('Турниры', clear: pickedTids.isEmpty ? null : () => setState(tids.clear)),
                          note(pickedTids.isEmpty ? 'Показаны все. Отметьте, какие оставить.' : 'Показаны только отмеченные.'),
                          for (final (intl, list) in groups) ...[
                            if (groups.length > 1) subhead(intl ? 'Международные' : 'Российские'),
                            for (final e in list)
                              _CheckRow(
                                title: e.value.name,
                                subtitle: dateRange(e.value.from, e.value.to),
                                value: tids.contains(e.key),
                                onTap: () => _flip(tids, e.key),
                              ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          _SheetBar(
            primary: action.$1,
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

/// Заголовок сворачиваемого списка в листе фильтра: подпись, справа число и стрелка.
/// Нажатие по всей строке; зона не ниже 44 pt. Отмеченные есть — «1 из 3» цветом акцента:
/// в свёрнутом списке их не видно, а ленту они сужают.
class _FoldHead extends StatelessWidget {
  final String label;
  final int total, marked;
  final bool open;
  final VoidCallback onTap;
  const _FoldHead({required this.label, required this.total, required this.marked, required this.open, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final count = marked == 0 ? '$total' : '$marked из $total';
    final style = TextStyle(fontSize: 13, height: 1.3, color: p.ink2, fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Semantics(
        button: true,
        expanded: open,
        label: marked == 0 ? '$label, $total' : '$label, отмечено $marked из $total',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              children: [
                Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
                const SizedBox(width: 12),
                Text(
                  count,
                  maxLines: 1,
                  style: marked == 0 ? style : style.copyWith(color: p.accent, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 10),
                // стрелка встаёт по центру квадрата-отметки строк ниже
                SizedBox(
                  width: 22,
                  child: AnimatedRotation(
                    turns: open ? .5 : 0,
                    duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
                    child: Icon(CupertinoIcons.chevron_down, size: 16, color: p.ink2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Сворачиваемая часть: плавно по высоте; свёрнутая из дерева уходит целиком.
class _Fold extends StatelessWidget {
  final bool open;
  final Widget child;
  const _Fold({required this.open, required this.child});
  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedSize(
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: open ? child : const SizedBox(width: double.infinity),
    ),
  );
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

/// Подпись спортсмена в поиске — виды; страна стоит флагом с кодом рядом с именем.
String? _personLine(Schedule data, String name) {
  final p = data.people[name];
  if (p == null) return null;
  final s = kindsLine(p.kinds);
  return s.isEmpty ? null : cap(s);
}

class _CheckRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final bool value;
  final VoidCallback onTap;

  /// Код страны спортсмена: флаг с кодом сразу за именем.
  final String nation;
  const _CheckRow({this.leading, required this.title, this.subtitle, required this.value, required this.onTap, this.nation = ''});
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
                      // имя переносится по словам, флаг с кодом — сразу за ним
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: title),
                            if (nation.isNotEmpty) ...[
                              const TextSpan(text: '  '),
                              WidgetSpan(
                                alignment: PlaceholderAlignment.baseline,
                                baseline: TextBaseline.alphabetic,
                                // WidgetSpan сам увеличивает вложенное под крупный шрифт: без этого
                                // флаг с кодом увеличивались дважды
                                child: MediaQuery.withNoTextScaling(
                                  child: NationTag(nation, style: PlacingName.codeStyle(p, 15).copyWith(height: 1.3)),
                                ),
                              ),
                            ],
                          ],
                        ),
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
    nation: data?.people[name]?.nation ?? '',
    subtitle: data == null ? null : _personLine(data!, name),
    value: value,
    onTap: onTap,
  );
}
