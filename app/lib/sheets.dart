// Нижние листы: карточка старта (уведомление, пьедестал, итог, наши) и фильтр ленты.
import 'dart:async' show scheduleMicrotask;
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import 'countries.dart';
import 'data.dart';
import 'flags.dart';
import 'main.dart';
import 'pace.dart';
import 'platform.dart';
import 'profile.dart';
import 'protocol.dart';
import 'settings.dart' show FeedbackAbout, ReportLink;
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
  showSwipeSheet<void>(
    context,
    (c, scroll) => ListenableBuilder(
      listenable: state,
      // имя в карточке открывает того, кто выступал в этом виде (тёзки — см. KindScope)
      builder: (c, _) => KindScope(kind: s.kind, child: _StartSheet(s: s, state: state, scrollController: scroll)),
    ),
    top: .92,
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
    final (disc, seg) = splitSegment(s.segmentPlain);
    // «9 октября» не разрывается
    final date = '${cap(weekdays[d.weekday - 1])}, ${d.day}\u00A0${months[d.month - 1]}${otherYear(d)}';
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final notify = _notifyRow(context, t);
    // живые места: режим для этого старта, если у него есть табло и файл протокола — компактный чип.
    // Итог окончательный (settled, как в watching) — опрашивать нечего, чипа нет совсем.
    final liveChip = canReadBoards && s.live != null && s.proto != null && !s.settled ? _LiveChip(state: state, start: s) : null;
    final short = isShortWindow(context);
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // название турнира есть только здесь — до двух строк, не обрезаем
        Eyebrow(s.teamSub ? '${s.tournament} · командный турнир' : s.tournament, color: p.accent, maxLines: 2),
        const SizedBox(height: 8),
        Text(disc, style: display(p, 42)),
        if (seg.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            segNames[seg]!,
            style: display(p, 25, italic: true, color: p.ink2, weight: FontWeight.w400),
          ),
        ],
      ],
    );
    final time = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // время и так крупное: со шрифтом не растёт, место справа остаётся словам
        Text(
          hm(s.t0),
          textScaler: TextScaler.noScaling,
          style: clock(live ? p.live : (past ? p.ink2 : p.ink), short ? 48 : (narrow ? 44 : 54)),
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
              // затянувшийся сегмент идёт дольше расписания, а досрочно закончившийся уже не идёт:
              // время из расписания не выдаём за настоящий конец
              Text(
                '${s.overrunAt(t) || (s.finishedAt(t) && t.isBefore(s.t1)) ? 'по расписанию ' : ''}до$nb${s.endPaced ? '≈' : ''}${hm(s.t1)}$nbМСК',
                style: TextStyle(fontSize: 13, color: p.ink2, fontFeatures: tnum),
              ),
              // темп: старт отстаёт или опережает — время выхода ниже уже с этой поправкой
              if (paceShort(s.pace) case final pace? when !past)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(pace, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: s.pace!.late ? p.live : p.ink2)),
                ),
            ],
          ),
        ),
      ],
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .92),
      child: SheetScroll(
        controller: scrollController,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // шапка: лёд, турнир, вид и сегмент; растёт вместе со шрифтом.
            // Телефон боком — время в шапке справа: высоты мало, ниже остаётся место делу
            Stack(
              children: [
                Positioned.fill(child: IceBackdrop(fadeTo: p.sheet, fadeStart: .25, sparkles: -1)),
                // искры — над подписью турнира, на текст не ложатся
                const Positioned(top: 0, left: 0, right: 0, child: SheetSparkles()),
                ConstrainedBox(
                  constraints: BoxConstraints(minHeight: short ? 0 : 132, minWidth: double.infinity),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(22, short ? 30 : 36, 22, 2),
                      child: short
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(child: heading),
                                const SizedBox(width: 16),
                                Expanded(child: time),
                              ],
                            )
                          : heading,
                    ),
                  ),
                ),
              ],
            ),
            // время крупно слева; справа по строке: состояние, дата, конец по Москве.
            // У завершённого — то же, только время приглушено и вместо отсчёта «Завершён».
            if (!short) Padding(padding: const EdgeInsets.fromLTRB(22, 16, 22, 0), child: time),
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
            // неверное время, нет трансляции, ошибка в итогах — сообщение сразу знает, о каком старте
            ReportLink(
              about: FeedbackAbout(
                id: 'start:${s.id}',
                icon: CupertinoIcons.calendar,
                title: seg.isEmpty ? disc : '$disc, ${segNames[seg]}',
                subtitle: '${s.tournament}\n$date',
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
    if (!canNotify || !s.t0.isAfter(t)) return null;
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
      // исключение — только когда оно и правда расходится с правилами. Выключено лишь потому, что
      // состав неизвестен при «только с отслеживаемыми», — так и сказать: остальным правилам старт подходит
      subtitle: state.notifies(s) != state.rules.matches(s)
          ? 'исключение из правил'
          : !on && state.rules.onlyFollowed && !s.compositionKnown && state.rules.copyWith(onlyFollowed: false).matches(s)
              ? 'состав ещё не объявлен'
              : null,
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
        _section(
          context,
          totalLabel(s),
          s.team ? TeamTotalPlate(list: s.total) : _TotalPlate(list: s.total, data: state.data, intl: s.intl),
        ),
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
                      _OurResult(o: rest[i], seg: s.seg, data: state.data, slot: slot, full: full, intl: s.intl),
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
          ? EmptyPlate(noResultsText(s))
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

  static const _actionStyle = TextStyle(fontFamily: sans, fontSize: 14.5, fontWeight: FontWeight.w700);

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
    return ProfileTap(
      name: x.name,
      data: data,
      radius: const BorderRadius.vertical(top: Radius.circular(14)),
      child: Column(
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
                      fontSize: first ? 41 : 32,
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
      ),
    );
  }
}

/// Итог турнира: медаль, фото, имя, страна, сумма. Страна (флаг с кодом) и сумма — колонками
/// одной ширины: флаги и цифры стоят ровно друг под другом.
/// Командный зачёт: место медалью, флаг и страна, баллы команды. Без аватаров — это страны, не люди.
class TeamTotalPlate extends StatelessWidget {
  final List<Placing> list;
  const TeamTotalPlate({super.key, required this.list});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final rows = [...list]..sort((a, b) => a.place.compareTo(b.place));
    final k = MediaQuery.textScalerOf(context);
    return Plate(
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Hairline(indent: 54),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
              child: Row(
                children: [
                  Medal(rows[i].place, size: 26),
                  const SizedBox(width: 14),
                  if (flagAsset(rows[i].nation) case final f?) ...[
                    Flag(f, height: k.scale(18)),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      rows[i].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.ink, height: 1.25),
                    ),
                  ),
                  if (rows[i].points.isNotEmpty) ...[
                    const SizedBox(width: 12),
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
          // имена в результатах — только фамилии
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
          ProfileTap(
            name: rows[i].name,
            data: data,
            child: Padding(
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

  /// Международный старт: под именем — флаг и код страны (россиянин или белорус — видно сразу).
  final bool intl;
  const _OurResult({required this.o, required this.seg, required this.data, required this.slot, this.full = true, this.intl = false});

  static const _placeStyle = TextStyle(
    fontFamily: serif,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.0,
    fontFeatures: [FontFeature.liningFigures()],
  );

  /// Подпись под местом: что это за место.
  static String caption(String seg) => seg.isEmpty ? 'место' : 'место в $seg';

  /// Что крупно справа: место, «DSQ» у дисквалифицированного (результат аннулирован), иначе прочерк.
  static String mark(Skater o) => o.place != null ? '${o.place}' : (o.disqualified ? 'DSQ' : '—');

  /// Ширина правой колонки: место крупно и подпись «место в ПП».
  static double right(BuildContext context, Skater o, String seg) => math.max(
    textWidth(context, mark(o), _placeStyle),
    o.place != null ? textWidth(context, caption(seg).toUpperCase(), Eyebrow.style(Colors.black)) : 0,
  );
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ProfileTap(
      name: o.name,
      data: data,
      child: Padding(
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
                  if ((intl && o.nation.isNotEmpty) || o.overall != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Wrap(
                        spacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (intl && o.nation.isNotEmpty) NationTag(o.nation, style: PlacingName.codeStyle(p, 13)),
                          if (o.overall != null)
                            Text(
                              'итог ${o.overall}',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.accent),
                            ),
                        ],
                      ),
                    ),
                  // результат аннулирован (дисквалификация): выступал, протокол есть, места нет
                  if (o.disqualified)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'дисквалификация, результат аннулирован',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.live, height: 1.3),
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
                  mark(o),
                  style: _placeStyle.copyWith(color: o.disqualified && o.place == null ? p.live : p.ink),
                ),
                if (o.place != null) Eyebrow(caption(seg)),
              ],
            ),
          ],
        ),
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
    fontSize: 27,
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
        canNotify && state.rules.skaters && state.notifies(s) && state.allowed != false && alertAt != null && alertAt.isAfter(t)
        ? 'уведомление в$nb${hm(alertAt)}'
        : null;
    return ProfileTap(
      name: o.name,
      data: state.data,
      child: Padding(
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
                  if ((s.intl && o.nation.isNotEmpty) || meta != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Wrap(
                        spacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (s.intl && o.nation.isNotEmpty) NationTag(o.nation, style: PlacingName.codeStyle(p, 13)),
                          if (meta != null) Text(meta, style: TextStyle(fontSize: 13, color: p.ink2, height: 1.35)),
                        ],
                      ),
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
            WatchRow(link: links[i]),
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
/// Название переносится по словам; под ним — где площадка доступна, если это известно;
/// справа тихий значок акцентного цвета без заливки.
class WatchRow extends StatelessWidget {
  final WatchLink link;

  /// Отступы строки: в листе старта текст стоит под заголовком (16 + 21 значок + 15).
  final EdgeInsets padding;
  const WatchRow({super.key, required this.link, this.padding = const EdgeInsets.fromLTRB(52, 12, 16, 12)});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final note = link.note;
    return Semantics(
      button: true,
      label: 'Открыть трансляцию: ${link.name}${note == null ? '' : ', $note'}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('watch:${link.name}'),
        onTap: () => watchOpener(context, link.url, link.name),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: padding,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(link.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
                      if (note != null) ...[
                        const SizedBox(height: 2),
                        Text(note, style: TextStyle(fontSize: 13, color: p.ink2, height: 1.3)),
                      ],
                    ],
                  ),
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
///
/// На компьютере (панель разделов слева, окно широкое) вместо листа — панель справа: мышью лист
/// не тянут, а панель закрывается крестиком, щелчком мимо и клавишей Esc.
Future<T?> showSwipeSheet<T>(
  BuildContext context,
  Widget Function(BuildContext, ScrollController) builder, {
  double top = .94,
}) {
  if (navPlace(context) == NavPlace.side) return showSidePanel<T>(context, builder);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    builder: (c) => _SwipeSheet(builder: builder, top: top),
  );
}

/// Панель справа поверх содержимого: то же, что лист на телефоне, для мыши и клавиатуры.
Future<T?> showSidePanel<T>(
  BuildContext context,
  Widget Function(BuildContext, ScrollController) builder, {
  double width = 580,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Закрыть',
    barrierColor: const Color(0x4D0B1B2E),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (c, a, b) => _SidePanel(builder: builder, width: width),
    transitionBuilder: (c, a, b, child) {
      final curved = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeIn);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(position: Tween(begin: const Offset(.04, 0), end: Offset.zero).animate(curved), child: child),
      );
    },
  );
}

class _SidePanel extends StatefulWidget {
  final Widget Function(BuildContext, ScrollController) builder;
  final double width;
  const _SidePanel({required this.builder, required this.width});
  @override
  State<_SidePanel> createState() => _SidePanelState();
}

class _SidePanelState extends State<_SidePanel> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // крестик — снаружи панели: внутри у листов справа вверху свои кнопки
              RoundButton(icon: CupertinoIcons.xmark, tooltip: 'Закрыть (Esc)', onTap: () => Navigator.of(context).maybePop()),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.width),
                child: Material(
                  color: p.sheet,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                    side: BorderSide(color: p.plateLine),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: PanelScope(child: widget.builder(context, _scroll)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwipeSheet extends StatefulWidget {
  final Widget Function(BuildContext, ScrollController) builder;
  final double top;
  const _SwipeSheet({required this.builder, required this.top});
  @override
  State<_SwipeSheet> createState() => _SwipeSheetState();
}

class _SwipeSheetState extends State<_SwipeSheet> {
  @override
  Widget build(BuildContext context) {
    // клавиатура поиска не закрывает ни найденных, ни кнопок внизу
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SwipeSurface(top: widget.top, builder: widget.builder),
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
  final String title;

  /// Закреплено под названием вместе с шапкой: строка поиска.
  final Widget? below;
  const _FilterHeader({required this.onReset, required this.scrolled, this.title = 'Фильтр', this.below});
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
                  Expanded(
                    child: Semantics(header: true, child: Text(title, maxLines: 1, style: display(p, 28))),
                  ),
                  if (onReset != null) _TextAction('Сбросить', onReset!),
                ],
              ),
            ),
          ),
          ?below,
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

  /// Лист открыли ради поиска — клавиатура сразу.
  final bool autofocus;
  final FocusNode? focusNode;
  const SearchBox({super.key, required this.controller, required this.onChanged, this.autofocus = false, this.focusNode});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      autocorrect: false,
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
String liveModeLabel(String mode) => mode == liveDelayed ? 'Стандартный' : 'Моментально';

/// Живые места в карточке старта: маленький чип рядом со временем. Молния — табло с заданной частотой,
/// часы — файл протокола. По нажатию — меню из трёх пунктов.
/// «Как в настройках» — переопределения для старта нет (Prefs.live.over без его id).
class _LiveChip extends StatelessWidget {
  final AppState state;
  final Start start;
  const _LiveChip({required this.state, required this.start});

  static const _asSettings = '';
  static const _every = 'every';

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
              items: [
                (_asSettings, 'Как в настройках'),
                (liveInstant, 'Моментально'),
                (liveDelayed, 'Стандартный'),
                // частота имеет смысл только для табло
                if (mode == liveInstant) (_every, 'Частота: ${liveEveryLabel(state.liveEveryOf(start))}'),
              ],
            );
            if (v == _every) {
              if (!chipContext.mounted) return;
              final sec = await showLiveEverySheet(
                chipContext,
                current: state.liveEveryOf(start),
                own: state.liveEveryOver.containsKey(start.id),
                global: state.liveEvery,
              );
              if (sec != null) state.setLiveEveryOver(start.id, sec == liveEveryAsSettings ? null : sec);
              return;
            }
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

  /// Прошедшие турниры свёрнуты, пока среди них нет отмеченного: список длинный, а нужен редко.
  bool? _pastOpen;

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

    // турниры впереди: со стартами в расписании и без расписания; российские и международные отдельно.
    // Прошедшие — отдельным свёрнутым списком: фильтр действует и на календарь, где они видны
    final tours = <String, ({String name, bool intl, String from, String to})>{};
    final gone = <String, ({String name, bool intl, String from, String to})>{};
    for (final s in data.starts) {
      final into = s.pastAt(t) ? gone : tours;
      final d = dayKey(s.t0);
      final have = into[s.tid];
      into[s.tid] = (
        name: s.tournament,
        intl: s.intl,
        from: have == null || d.compareTo(have.from) < 0 ? d : have.from,
        to: have == null || d.compareTo(have.to) > 0 ? d : have.to,
      );
    }
    // турнир, который ещё идёт, — в списке предстоящих, а не в обоих
    gone.removeWhere((tid, _) => tours.containsKey(tid));
    final today = dayKey(t), horizon = dayKey(t.add(const Duration(days: 60)));
    for (final u in data.upcoming) {
      if (u.end.compareTo(today) < 0 || u.start.compareTo(horizon) >= 0) continue;
      tours.putIfAbsent(u.tid, () => (name: u.name, intl: u.intl, from: u.start, to: u.end));
    }
    final byDate = tours.entries.toList()..sort((a, b) => a.value.from.compareTo(b.value.from));
    List<MapEntry<String, ({String name, bool intl, String from, String to})>> group(bool intl) =>
        [for (final e in byDate) if (e.value.intl == intl && scope.contains(intl ? 'intl' : 'russian')) e];
    final groups = [for (final intl in [false, true]) if (group(intl).isNotEmpty) (intl, group(intl))];

    // прошедшие — свежие сверху, с тем же выбором «российские / международные»
    final past = [
      for (final e in gone.entries.toList()..sort((a, b) => b.value.from.compareTo(a.value.from)))
        if (scope.contains(e.value.intl ? 'intl' : 'russian')) e,
    ];
    final pastOpen = _pastOpen ?? past.any((e) => tids.contains(e.key));
    // отмеченный турнир, которого в списке нет (скрыт выбором стартов), ленту не сужает
    final shownTids = {for (final g in groups) for (final e in g.$2) e.key, for (final e in past) e.key};
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
    // прошедшие по этому фильтру: их показывает календарь, даже когда впереди ничего нет
    final behind = pastMatches(data, f, t);
    final action = filterAction(count, more, behind);

    Widget athleteRow(String a) => _CheckRow(
      leading: _ProfileAvatar(name: a, data: data),
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
                        if (groups.isNotEmpty || past.isNotEmpty) ...[
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
                          if (past.isNotEmpty) ...[
                            _FoldHead(
                              label: 'Прошедшие',
                              total: past.length,
                              marked: past.where((e) => tids.contains(e.key)).length,
                              open: pastOpen,
                              onTap: () => setState(() => _pastOpen = !pastOpen),
                            ),
                            _Fold(
                              open: pastOpen,
                              child: Column(
                                children: [
                                  for (final e in past)
                                    _CheckRow(
                                      title: e.value.name,
                                      subtitle: dateRange(e.value.from, e.value.to),
                                      value: tids.contains(e.key),
                                      onTap: () => _flip(tids, e.key),
                                    ),
                                ],
                              ),
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
          // кнопка работает всегда: фильтр действует и на календарь с прошлыми сезонами, а там
          // совпадения могут быть в месяцах, которые ещё не загружены
          _SheetBar(
            primary: action.$1,
            onPrimary: () {
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
/// (у турнира без расписания один старт в ленте). Впереди ничего — сколько прошедших покажет
/// календарь; и их нет — просто «Применить»: в архиве прошлых сезонов считать нечем.
(String, String?) filterAction(int starts, int unscheduled, [int past = 0]) {
  final n = starts + unscheduled;
  if (n > 0) return ('Показать $n ${plural(n, 'старт', 'старта', 'стартов')}', null);
  if (past > 0) return ('Показать $past ${plural(past, 'прошедший старт', 'прошедших старта', 'прошедших стартов')}', null);
  return ('Применить', null);
}

/// Сколько прошедших стартов расписания подходит под фильтр (их показывает календарь).
int pastMatches(Schedule data, Filters f, DateTime t) => data.starts.where((s) => s.pastAt(t) && f.pass(s)).length;

/// День последнего прошедшего старта, подходящего под фильтр; null — таких нет.
String? lastPastMatch(Schedule data, Filters f, DateTime t) {
  for (final s in data.starts.reversed) {
    if (s.pastAt(t) && f.pass(s)) return s.day;
  }
  return null;
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
  final s = kindsLineOf(p.kinds, was: p.was, wasSeason: p.wasSeason);
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

  /// Строка-переход, а не отметка: это стоит справа вместо квадрата.
  final Widget? trailing;

  /// Что будет по нажатию — вслух, для строки-перехода: «открыть профиль».
  final String? hint;
  const _CheckRow({
    this.leading,
    required this.title,
    this.subtitle,
    this.value = false,
    required this.onTap,
    this.nation = '',
    this.trailing,
    this.hint,
  });
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      checked: trailing == null ? value : null,
      button: trailing != null ? true : null,
      hint: hint,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            // фото с целью нажатия 44 — поля по 4, высота строки прежняя
            padding: EdgeInsets.symmetric(vertical: leading != null ? 4 : 6),
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
                trailing ?? SquareCheck(on: value),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// Фото в строке с отметкой: нажатие на фото — профиль, на остальную строку — отметка.
/// Цель нажатия — 44 точки в высоту, как у кнопок, хотя само фото меньше.
class _ProfileAvatar extends StatelessWidget {
  final String name;
  final Schedule? data;
  const _ProfileAvatar({required this.name, required this.data});
  @override
  Widget build(BuildContext context) => ProfileTap(
    name: name,
    data: data,
    label: 'Профиль: ${displayName(name)}',
    radius: BorderRadius.circular(12),
    child: SizedBox(
      height: 44,
      child: Center(child: Avatar(name: name, data: data, size: 34, slot: true)),
    ),
  );
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
    leading: _ProfileAvatar(name: name, data: data),
    title: displayName(name),
    nation: data?.people[name]?.nation ?? '',
    subtitle: data == null ? null : _personLine(data!, name),
    value: value,
    onTap: onTap,
  );
}


// ------------------------------------------------------------------ поиск спортсмена

/// Кто выступает на ближайших стартах, в порядке стартов: только те, у кого есть профиль.
List<String> nextAthletes(Schedule data, DateTime t, {int limit = 12}) {
  final starts = [for (final s in data.starts) if (!s.pastAt(t)) s]..sort((a, b) => a.t0.compareTo(b.t0));
  final seen = <String>{};
  final out = <String>[];
  for (final s in starts) {
    for (final a in [...s.ours.map((o) => o.name), ...s.athletes]) {
      if (out.length >= limit) return out;
      if (hasProfile(data, a) && seen.add(norm(a))) out.add(a);
    }
  }
  return out;
}

/// Найденные по запросу, кого можно открыть: строка поиска ведёт в профиль, пустых нажатий нет.
/// Те, о ком есть справка, — выше тех, о ком известны только имя и страна; внутри порядок поиска.
List<String> searchProfiles(Schedule data, String query, DateTime t, {int limit = 30}) {
  final found = [
    for (final a in searchAthletes(data, query, soon: soonAthletes(data, t), limit: 200))
      if (hasProfile(data, a)) a,
  ];
  bool rich(String a) => data.personOf(a)?.profile != null;
  return [...found.where(rich), ...found.where((a) => !rich(a))].take(limit).toList();
}

/// Поиск спортсмена: нажатие на строку — его профиль. Пока запроса нет — отслеживаемые
/// и те, кто на ближайших стартах.
void showAthleteSearch(BuildContext context, AppState state) {
  if (state.data == null) return;
  // высота — как у профиля, который открывается поверх: тот закрывает лист целиком, без второй ручки над собой
  showSwipeSheet<void>(context, (c, scroll) => _AthleteSearchSheet(state: state, scroll: scroll), top: .92);
}

class _AthleteSearchSheet extends StatefulWidget {
  final AppState state;
  final ScrollController scroll;
  const _AthleteSearchSheet({required this.state, required this.scroll});
  @override
  State<_AthleteSearchSheet> createState() => _AthleteSearchSheetState();
}

class _AthleteSearchSheetState extends State<_AthleteSearchSheet> {
  final _q = TextEditingController();
  final _focus = FocusNode();
  String q = '';
  bool _scrolled = false;

  @override
  void dispose() {
    _q.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = widget.state.data!;
    final t = now();
    final found = q.isEmpty ? const <String>[] : searchProfiles(data, q, t);
    final follow = q.isEmpty
        ? ([for (final a in widget.state.follow.names) if (hasProfile(data, a)) a]..sort())
        : const <String>[];
    final followed = {for (final a in follow) norm(a)};
    final next = q.isEmpty
        ? [for (final a in nextAthletes(data, t, limit: 12 + follow.length)) if (!followed.contains(norm(a))) a].take(12).toList()
        : const <String>[];

    Widget row(String a) => _CheckRow(
      leading: SizedBox(
        height: 44,
        child: Center(child: Avatar(name: a, data: data, size: 34, slot: true)),
      ),
      title: displayName(a),
      nation: data.personOf(a)?.nation ?? '',
      subtitle: _personLine(data, a),
      // цвет рамок элементов управления: на фоне листа он различим, ink3 — уже нет
      trailing: SizedBox(width: 22, child: Icon(CupertinoIcons.chevron_right, size: 16, color: p.control)),
      hint: 'открыть профиль',
      onTap: () {
        // клавиатура не остаётся под профилем
        _focus.unfocus();
        showProfile(context, a, data);
      },
    );
    Widget head(String label) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Semantics(header: true, child: Eyebrow(label)),
    );

    return Material(
      color: p.sheet,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
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
                title: 'Спортсмены',
                onReset: null,
                scrolled: _scrolled,
                below: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
                  child: SearchBox(
                    controller: _q,
                    focusNode: _focus,
                    autofocus: true,
                    onChanged: (v) => setState(() => q = v.trim()),
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.paddingOf(context).bottom),
              sliver: SliverList.list(
                children: [
                  if (q.isNotEmpty && found.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        'Никого не нашлось. Проверьте фамилию.',
                        style: TextStyle(color: p.ink2, fontSize: 15, height: 1.35),
                      ),
                    ),
                  for (final a in found) row(a),
                  if (follow.isNotEmpty) ...[head('Отслеживаемые'), for (final a in follow) row(a)],
                  if (next.isNotEmpty) ...[head('На ближайших стартах'), for (final a in next) row(a)],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ частота обновления

/// Ответ листа частоты: «как в настройках» (только для старта).
const liveEveryAsSettings = 0;

/// Лист выбора частоты опроса табло: пресеты, своё значение и предупреждение о батарее.
/// Возвращает секунды (не меньше [liveEveryMin]) или [liveEveryAsSettings]; закрыли — null.
/// [global] не null — это лист старта: появляется пункт «Как в настройках».
Future<int?> showLiveEverySheet(BuildContext context, {required int current, bool own = false, int? global}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: _LiveEverySheet(current: current, own: own, global: global),
    ),
  );
}

/// Предупреждение о батарее для частоты [sec]; null — предупреждать не о чем.
String? liveEveryWarning(int sec) {
  if (sec < 30) return 'Так часто телефон почти не спит: заряд батареи будет уходить заметно быстрее.';
  if (sec < 120) return 'Частые обновления расходуют заряд батареи.';
  return null;
}

class _LiveEverySheet extends StatefulWidget {
  final int current;
  final bool own;
  final int? global;
  const _LiveEverySheet({required this.current, required this.own, required this.global});
  @override
  State<_LiveEverySheet> createState() => _LiveEverySheetState();
}

class _LiveEverySheetState extends State<_LiveEverySheet> {
  late final TextEditingController _c = TextEditingController(
    text: liveEveryPresets.contains(widget.current) ? '' : '${widget.current}',
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Введённое: число секунд; пусто — null (не вводили); меньше минимума — отдельная ошибка.
  int? get _typed => int.tryParse(_c.text.trim());
  bool get _tooLow => _c.text.trim().isNotEmpty && (_typed == null || _typed! < liveEveryMin);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final shown = _typed != null && !_tooLow ? _typed! : widget.current;
    final warn = liveEveryWarning(shown);
    Widget item(String text, int value, bool selected) => ListTile(
      title: Text(text, style: TextStyle(fontSize: 16, color: p.ink)),
      trailing: selected ? Icon(CupertinoIcons.checkmark, size: 18, color: p.ink) : null,
      onTap: () => Navigator.of(context).pop(value),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 18, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                'Как часто обновлять',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: p.ink),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Пока идёт турнир, новые оценки и места появляются в приложении сами. Если нового нет, ничего не меняется.',
                style: TextStyle(fontSize: 14, color: p.ink2, height: 1.3),
              ),
            ),
            if (widget.global != null)
              item('Как в настройках (${liveEveryLabel(widget.global!)})', liveEveryAsSettings, !widget.own),
            for (final v in liveEveryPresets)
              item(liveEveryLabel(v), v, (widget.global == null || widget.own) && widget.current == v),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: TextField(
                controller: _c,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _apply(),
                style: TextStyle(fontSize: 15.5, color: p.ink),
                decoration: InputDecoration(
                  labelText: 'Своё значение, секунд',
                  hintText: 'от $liveEveryMin',
                  errorText: _tooLow ? 'Не чаще, чем раз в $liveEveryMin секунд' : null,
                  suffixIcon: IconButton(
                    tooltip: 'Применить',
                    icon: const Icon(CupertinoIcons.checkmark_circle_fill),
                    onPressed: _typed != null && !_tooLow ? _apply : null,
                  ),
                ),
              ),
            ),
            if (warn != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(CupertinoIcons.battery_25, size: 18, color: p.ink2),
                    const SizedBox(width: 8),
                    Expanded(child: Text(warn, style: TextStyle(fontSize: 13.5, color: p.ink2, height: 1.3))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _apply() {
    final v = _typed;
    if (v == null || _tooLow) return;
    Navigator.of(context).pop(v > liveEveryMax ? liveEveryMax : v);
  }
}

// ------------------------------------------------------------------ выбор месяца

const _monthsShort = ['янв', 'фев', 'мар', 'апр', 'май', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];

/// Выбор месяца и года во вкладке «Месяц»: к декабрю 2024 года — в два нажатия, а не в двадцать три.
/// [first] — с какого месяца есть архив: раньше него месяцы не нажимаются. Возвращает первый день месяца.
Future<DateTime?> showMonthPicker(BuildContext context, {required DateTime current, required DateTime today, DateTime? first}) {
  // компьютер — окно по центру, а не лист от нижнего края
  if (navPlace(context) == NavPlace.side) {
    return showDialog<DateTime>(
      context: context,
      barrierColor: const Color(0x4D0B1B2E),
      builder: (c) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: PanelScope(child: _MonthPicker(current: current, today: today, first: first)),
        ),
      ),
    );
  }
  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (c) => _MonthPicker(current: current, today: today, first: first),
  );
}

class _MonthPicker extends StatefulWidget {
  final DateTime current, today;
  final DateTime? first;
  const _MonthPicker({required this.current, required this.today, required this.first});
  @override
  State<_MonthPicker> createState() => _MonthPickerState();
}

class _MonthPickerState extends State<_MonthPicker> {
  late int year = widget.current.year;

  int get _minYear => math.min(widget.first?.year ?? widget.today.year, widget.today.year);
  int get _maxYear => widget.today.year + 1;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final first = widget.first;
    Widget arrow(IconData icon, String tip, int delta) {
      final ok = year + delta >= _minYear && year + delta <= _maxYear;
      return IconButton(
        tooltip: tip,
        onPressed: ok ? () => setState(() => year += delta) : null,
        icon: Icon(icon, size: 20, color: ok ? p.ink : p.ink3),
      );
    }

    Widget cell(int m) {
      final at = DateTime(year, m);
      final off = first != null && at.isBefore(first);
      final sel = at == DateTime(widget.current.year, widget.current.month);
      final now = at == widget.today;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Semantics(
            button: true,
            selected: sel,
            enabled: !off,
            label: '${monthsNom[m - 1]} $year',
            excludeSemantics: true,
            child: Material(
              color: sel ? p.accent : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: sel ? p.accent : (now ? p.accent : p.plateLine), width: now && !sel ? 1.4 : 1),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: off ? null : () => Navigator.pop(context, at),
                child: SizedBox(
                  height: 48,
                  child: Center(
                    child: Text(
                      _monthsShort[m - 1],
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: sel || now ? FontWeight.w700 : FontWeight.w500,
                        color: sel ? p.onAccent : (off ? p.ink3 : (now ? p.accent : p.ink)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: p.sheet,
      borderRadius: PanelScope.of(context) ? BorderRadius.circular(26) : const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 14, 16, 16 + MediaQuery.paddingOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                arrow(CupertinoIcons.chevron_left, 'Предыдущий год', -1),
                SizedBox(
                  width: 92,
                  child: Center(child: Text('$year', style: display(p, 30))),
                ),
                arrow(CupertinoIcons.chevron_right, 'Следующий год', 1),
                const Spacer(),
                _TextAction('Сегодня', () => Navigator.pop(context, widget.today)),
              ],
            ),
            const SizedBox(height: 8),
            for (var r = 0; r < 3; r++) Row(children: [for (var c = 0; c < 4; c++) cell(r * 4 + c + 1)]),
            // раньше архива листать некуда — об этом сказано, а не просто серые месяцы
            if (first != null && year <= first.year) ...[
              const SizedBox(height: 10),
              Text(
                'Архив начинается с$nb${months[first.month - 1]} ${first.year}$nbгода',
                style: TextStyle(fontSize: 13.5, color: p.ink2, height: 1.3),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
