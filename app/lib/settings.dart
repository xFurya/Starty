// Настройки: уведомления по правилам, лента, календарь, о приложении.
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data.dart';
import 'main.dart';
import 'reminders.dart';
import 'sheets.dart';
import 'state.dart';
import 'system.dart';
import 'ui.dart';
import 'update.dart';
import 'updater.dart';
import 'views.dart' show freshness;

const _ics = 'webcal://xfurya.github.io/Starty/calendar.ics';
const _google = 'https://calendar.google.com/calendar/render?cid=webcal%3A%2F%2Fxfurya.github.io%2FStarty%2Fcalendar.ics';

bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// «2 вида · 1 турнир · 1 спортсмен» или «Все старты».
String filterSummary(Filters f) {
  if (!f.any) return 'Все старты';
  return [
    if (f.kinds.isNotEmpty) '${f.kinds.length} ${plural(f.kinds.length, 'вид', 'вида', 'видов')}',
    if (f.tids.isNotEmpty) '${f.tids.length} ${plural(f.tids.length, 'турнир', 'турнира', 'турниров')}',
    if (f.athletes.isNotEmpty) '${f.athletes.length} ${plural(f.athletes.length, 'спортсмен', 'спортсмена', 'спортсменов')}',
  ].join(' · ');
}

/// Действующие исключения: старт ещё впереди (переключатель в его карточке виден)
/// и его уведомление и правда расходится с правилами. Прошедшие и совпавшие с правилами
/// ни на что не влияют — их не считаем.
int activeExceptions(AppState st) {
  final r = st.rules;
  final t = now();
  return st.data?.starts
          .where(
            (s) =>
                st.isException(s) &&
                s.t0.subtract(Duration(minutes: r.lead)).isAfter(t) &&
                st.notifies(s) != r.matches(s),
          )
          .length ??
      0;
}

/// «17:15», «завтра 07:15», «12 октября 09:00» — неразрывно, одной строкой.
String _when(DateTime at) {
  final t = now();
  if (dayKey(at) == dayKey(t)) return hm(at);
  if (dayKey(at) == dayKey(t.add(const Duration(days: 1)))) return 'завтра\u00A0${hm(at)}';
  final m = msk(at);
  return '${m.day}\u00A0${months[m.month - 1]}\u00A0${hm(at)}';
}

class SettingsView extends StatelessWidget {
  final AppState state;
  const SettingsView({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final r = state.rules;
    void set(NotifyRules n) => state.setRules(n);
    Set<String> flip(Set<String> s, String k) => s.contains(k) ? ({...s}..remove(k)) : {...s, k};
    // уже сработавшие не считаем: минутный тик перестраивает экран
    final t = now();
    final planned = state.planned.where((x) => x.at.isAfter(t)).toList();
    final exceptions = activeExceptions(state);
    final p = Palette.of(context);
    // все плитки карточки — одной плотности и кегля
    final kinds = [
      for (final k in NotifyRules.allKinds)
        ChoiceTile(
          label: kindNames[k]!,
          color: p.kind(k),
          on: r.kinds.contains(k),
          onTap: () => set(r.copyWith(kinds: flip(r.kinds, k))),
        ),
    ];
    final levels = [
      for (final k in NotifyRules.allLevels)
        ChoiceTile(
          label: levelNames[k]!,
          on: r.levels.contains(k),
          onTap: () => set(r.copyWith(levels: flip(r.levels, k))),
        ),
    ];
    final tours = [
      ChoiceTile(label: 'Российские', on: r.russian, onTap: () => set(r.copyWith(russian: !r.russian))),
      ChoiceTile(label: 'Международные', on: r.intl, onTap: () => set(r.copyWith(intl: !r.intl))),
    ];
    final segs = [
      ChoiceTile(
        label: 'Короткая и ритм-танец',
        on: r.segs.contains('short'),
        onTap: () => set(r.copyWith(segs: flip(r.segs, 'short'))),
      ),
      // ПП и ПТ: произвольная программа и произвольный танец
      ChoiceTile(
        label: 'Произвольная и танец',
        on: r.segs.contains('free'),
        onTap: () => set(r.copyWith(segs: flip(r.segs, 'free'))),
      ),
    ];
    final group = [...kinds, ...levels, ...tours, ...segs];
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(
          child: IceHero(eyebrow: 'Фигурное катание', title: 'Настройки', sparkles: 2),
        ),

        // ---------------------------------------------------------- уведомления
        const SliverToBoxAdapter(child: _Head('Уведомления')),
        SliverToBoxAdapter(
          child: Plate(
            child: Column(
              children: [
                _SwitchRow(
                  icon: r.on ? CupertinoIcons.bell_fill : CupertinoIcons.bell_slash,
                  title: 'Уведомления',
                  value: r.on,
                  onChanged: (v) => set(r.copyWith(on: v)),
                ),
                if (r.on && state.allowed == false) ...[
                  const Hairline(),
                  _Row(
                    icon: CupertinoIcons.exclamationmark_circle,
                    iconColor: p.live,
                    title: 'Запрещены в системе',
                    action: 'Разрешить',
                    onAction: () => allowNotifications(state),
                  ),
                ],
                _Rules(
                  enabled: r.on,
                  children: [
                    const Hairline(),
                    // «5 мин … 60 мин» не помещаются — «Заранее, мин» и одни числа
                    _ShortBlock(
                      title: 'Заранее',
                      shortTitle: 'Заранее, мин',
                      labels: [for (final m in NotifyRules.leads) '$m мин'],
                      shortLabels: [for (final m in NotifyRules.leads) '$m'],
                      child: (labels) => Segmented<int>(
                        items: [for (var i = 0; i < NotifyRules.leads.length; i++) (NotifyRules.leads[i], labels[i])],
                        value: r.lead,
                        onChanged: (v) => set(r.copyWith(lead: v)),
                      ),
                    ),
                    const Hairline(),
                    _Block(
                      title: 'Виды',
                      child: TileGrid(tiles: kinds, group: group),
                    ),
                    const Hairline(),
                    _Block(
                      title: 'Уровень',
                      child: TileGrid(tiles: levels, group: group),
                    ),
                    const Hairline(),
                    _Block(
                      title: 'Турниры',
                      child: TileGrid(tiles: tours, group: group),
                    ),
                    const Hairline(),
                    _Block(
                      title: 'Программы',
                      child: TileGrid(tiles: segs, group: group),
                    ),
                    const Hairline(),
                    _SwitchRow(
                      icon: CupertinoIcons.moon,
                      title: 'Ночные старты',
                      subtitle: '00:00–08:00',
                      value: r.night,
                      onChanged: (v) => set(r.copyWith(night: v)),
                    ),
                    const Hairline(),
                    _SwitchRow(
                      icon: CupertinoIcons.person_2,
                      title: 'Выход наших',
                      subtitle: 'за ${r.lead} мин до выхода',
                      value: r.skaters,
                      onChanged: (v) => set(r.copyWith(skaters: v)),
                    ),
                    if (exceptions > 0) ...[
                      const Hairline(),
                      _Row(
                        icon: CupertinoIcons.bell_circle,
                        title: 'Исключения: $exceptions',
                        action: 'Сбросить',
                        onAction: state.clearExceptions,
                      ),
                    ],
                  ],
                ),
                // запрещены в системе — ни одно не придёт, так и пишем
                if (planned.isEmpty)
                  const _Summary(head: 'Запланированных нет', empty: true)
                else if (state.allowed == false)
                  _Summary(head: 'Запланировано: ${planned.length}', tail: 'не придут', empty: true)
                else
                  _Summary(head: 'Запланировано: ${planned.length}', tail: 'ближайшее ${_when(planned.first.at)}'),
              ],
            ),
          ),
        ),

        // ---------------------------------------------------------- лента
        const SliverToBoxAdapter(child: _Head('Лента')),
        SliverToBoxAdapter(
          child: Plate(
            child: Column(
              children: [
                _Row(
                  icon: CupertinoIcons.slider_horizontal_3,
                  title: 'Фильтр',
                  subtitle: filterSummary(state.filters),
                  onTap: state.data == null ? null : () => showFilters(context, state),
                  trailing: const _Chevron(),
                ),
                const Hairline(),
                _SwitchRow(icon: CupertinoIcons.flag, title: 'Завершённые', value: state.showDone, onChanged: state.setShowDone),
                const Hairline(),
                _ShortBlock(
                  title: 'Тема',
                  labels: const ['Системная', 'Светлая', 'Тёмная'],
                  shortLabels: const ['Авто', 'Светлая', 'Тёмная'],
                  child: (labels) => Segmented<ThemeMode>(
                    items: [(ThemeMode.system, labels[0]), (ThemeMode.light, labels[1]), (ThemeMode.dark, labels[2])],
                    value: state.theme,
                    onChanged: state.setTheme,
                  ),
                ),
              ],
            ),
          ),
        ),

        // ---------------------------------------------------------- календарь
        const SliverToBoxAdapter(child: _Head('Календарь')),
        SliverToBoxAdapter(
          child: Plate(
            child: _Row(
              icon: CupertinoIcons.calendar_badge_plus,
              title: _ios ? 'Старты в Календаре' : 'Старты в Google Календаре',
              subtitle: 'Все старты, обновляются сами',
              onTap: () => launchUrl(Uri.parse(_ios ? _ics : _google), mode: LaunchMode.externalApplication),
              trailing: const _Chevron(external: true),
            ),
          ),
        ),

        // ---------------------------------------------------------- приложение
        const SliverToBoxAdapter(child: _Head('Приложение')),
        SliverToBoxAdapter(
          child: Plate(
            child: Column(
              children: [
                ListenableBuilder(
                  listenable: Updates.instance,
                  builder: (context, _) => _Updates(Updates.instance),
                ),
                const Hairline(),
                // то же правило, что у нижней строки ленты
                Builder(
                  builder: (context) {
                    final f = state.data == null ? null : freshness(state, short: true);
                    return _Row(
                      icon: CupertinoIcons.arrow_2_circlepath,
                      title: 'Расписание',
                      subtitle: state.refreshing ? 'обновление…' : (f?.text ?? (state.loading ? 'загрузка' : 'нет связи')),
                      subtitleColor: !state.refreshing && (f == null || f.alarm) ? p.live : null,
                      // нажатие — обновить расписание сейчас
                      onTap: state.refreshing ? null : state.load,
                      trailing: state.refreshing
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
                            )
                          : null,
                    );
                  },
                ),
                const Hairline(),
                _Row(icon: CupertinoIcons.doc_text, title: 'Источники', subtitle: _sources(state)),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(height: 32 + MediaQuery.paddingOf(context).bottom)),
      ],
    );
  }
}

/// Источники данных; не ответившие при последнем сборе — отдельно.
String _sources(AppState st) {
  const all = ['ФФККР', 'ISU', 'Swiss Timing', 'Golden Skate'];
  final failed = [
    for (final e in st.data?.sources.entries ?? const <MapEntry<String, String>>[])
      if (e.value != 'ok') e.key,
  ];
  return failed.isEmpty ? all.join(', ') : '${all.join(', ')} · нет ответа: ${failed.join(', ')}';
}

/// Версия и обновления — честное состояние самообновления (как у Дневника).
class _Updates extends StatelessWidget {
  final Updates u;
  const _Updates(this.u);
  @override
  Widget build(BuildContext context) {
    final s = u.state;
    final version = _Row(icon: CupertinoIcons.info, title: 'Версия', trailing: _Value(s?.current ?? appVersion));
    if (!Updates.native) {
      if (kIsWeb) return version;
      // iPhone: ставит SideStore, приложение только говорит о новой версии
      final a = u.available;
      return Column(
        children: [
          version,
          const Hairline(),
          _Row(
            icon: CupertinoIcons.arrow_down_circle,
            title: 'Обновления',
            subtitle: a == null ? 'Через SideStore' : 'Новая версия — в SideStore',
          ),
        ],
      );
    }
    return Column(
      children: [
        version,
        const Hairline(),
        _Row(
          icon: CupertinoIcons.arrow_down_circle,
          title: 'Обновления',
          subtitle: s == null ? 'Проверка…' : s.line(DateTime.now()),
          subtitleColor: s != null && s.problem ? Palette.of(context).live : null,
          onTap: s?.checking == true ? null : u.check,
        ),
        if (s != null && s.ready && !s.canInstall) ...[
          const Hairline(),
          _Row(
            icon: CupertinoIcons.lock_open,
            title: 'Разрешить установку',
            subtitle: 'Неизвестные приложения',
            onTap: u.allowInstall,
            trailing: const _Chevron(external: true),
          ),
        ],
        if (s != null && s.ready && s.canInstall) ...[
          const Hairline(),
          _Row(
            icon: CupertinoIcons.arrow_down_to_line,
            title: 'Обновить сейчас',
            subtitle: 'С перезапуском',
            onTap: u.installNow,
          ),
        ],
        if (s != null && s.ready && (s.wait == 'confirm' || s.installError.isNotEmpty || s.stuck)) ...[
          const Hairline(),
          _Row(
            icon: CupertinoIcons.square_arrow_up,
            title: 'Открыть установщик',
            onTap: u.openInstaller,
            trailing: const _Chevron(external: true),
          ),
        ],
      ],
    );
  }
}

class _Head extends StatelessWidget {
  final String text;
  const _Head(this.text);
  @override
  Widget build(BuildContext context) => Eyebrow(text, padding: const EdgeInsets.fromLTRB(20, 22, 20, 10));
}

/// Правила гаснут, пока уведомления выключены.
class _Rules extends StatelessWidget {
  final bool enabled;
  final List<Widget> children;
  const _Rules({required this.enabled, required this.children});
  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !enabled,
    child: AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: enabled ? 1 : .42,
      child: ExcludeSemantics(
        excluding: !enabled,
        child: Column(children: children),
      ),
    ),
  );
}

class _RowIcon extends StatelessWidget {
  final IconData icon;
  final Color? color;
  const _RowIcon(this.icon, {this.color});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = color ?? p.accent;
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: p.isDark ? .16 : .10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 17, color: c),
    );
  }
}

/// Строка: значок, название, подпись, что-то справа. Текстовая кнопка ([action]) — справа,
/// а если рядом с ней слово названия не помещается — под названием.
class _Row extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? trailing;
  final String? action;
  final VoidCallback? onAction;
  final VoidCallback? onTap;
  const _Row({
    required this.icon,
    required this.title,
    this.iconColor,
    this.subtitle,
    this.subtitleColor,
    this.trailing,
    this.action,
    this.onAction,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final titleStyle = TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: p.ink, height: 1.25);
    final body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 9, 12, 9),
        child: MeasuredLayout(
          builder: (context, c) {
            // значок 32 и зазоры 12 + 8
            final below = action != null &&
                actionBelow(context, c.maxWidth - 32 - 12 - 8, title, titleStyle, action!, _TextAction.style);
            final side = action == null ? trailing : (below ? null : _TextAction(action!, onTap: onAction!));
            return Row(
              children: [
                _RowIcon(icon, color: iconColor),
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
                          child: Text(
                            subtitle!,
                            style: TextStyle(fontSize: 13, color: subtitleColor ?? p.ink2, height: 1.3, fontFeatures: tnum),
                          ),
                        ),
                      if (below) _TextAction(action!, onTap: onAction!, below: true),
                    ],
                  ),
                ),
                if (side != null) ...[const SizedBox(width: 8), side],
              ],
            );
          },
        ),
      ),
    );
    if (onTap == null) return MergeSemantics(child: body);
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: InkWell(onTap: onTap, child: body),
      ),
    );
  }
}

/// Строка с переключателем: нажатие по всей строке.
class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchRow({required this.icon, required this.title, required this.value, required this.onChanged, this.subtitle});
  @override
  Widget build(BuildContext context) => _Row(
    icon: icon,
    title: title,
    subtitle: subtitle,
    onTap: () => onChanged(!value),
    trailing: Switch(value: value, onChanged: onChanged),
  );
}

/// Название над выбором: «Заранее», «Виды».
class _Block extends StatelessWidget {
  final String title;
  final Widget child;
  const _Block({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: p.ink),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// Итог правил: «Запланировано: N · ближайшее 17:15». Не помещается в строку — две строки,
/// без разделителя на конце первой: «Запланировано: 17» и «ближайшее завтра 07:15».
class _Summary extends StatelessWidget {
  final String head;
  final String tail;
  final bool empty;
  const _Summary({required this.head, this.tail = '', this.empty = false});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final style = TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: empty ? p.ink2 : p.ink, fontFeatures: tnum);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
      decoration: BoxDecoration(
        color: p.frost.withValues(alpha: p.isDark ? .55 : .8),
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Row(
        children: [
          Icon(empty ? CupertinoIcons.bell_slash : CupertinoIcons.checkmark_seal, size: 17, color: empty ? p.ink2 : p.accent),
          const SizedBox(width: 10),
          Expanded(
            child: MeasuredLayout(
              builder: (context, c) {
                final one = tail.isEmpty ? head : '$head · $tail';
                if (tail.isEmpty || textWidth(context, one, style) <= c.maxWidth) {
                  return Text(one, style: style);
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(head, style: style),
                    const SizedBox(height: 2),
                    Text(tail, style: style.copyWith(fontWeight: FontWeight.w500, color: p.ink2)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Блок с выбором, у которого есть короткие подписи: длинные не помещаются в дорожку
/// крупно — короткие («5 / 10 / 15», «Авто») и, если нужно, другой заголовок.
class _ShortBlock extends StatelessWidget {
  final String title;
  final String? shortTitle;
  final List<String> labels, shortLabels;
  final Widget Function(List<String> labels) child;
  const _ShortBlock({
    required this.title,
    required this.labels,
    required this.shortLabels,
    required this.child,
    this.shortTitle,
  });
  @override
  Widget build(BuildContext context) => MeasuredLayout(
    builder: (context, c) {
      // ширина дорожки — без полей блока
      final short = Segmented.fontFor(context, c.maxWidth - 28, labels) < Segmented.minFont;
      return _Block(title: short ? (shortTitle ?? title) : title, child: child(short ? shortLabels : labels));
    },
  );
}

/// Текстовая кнопка в строке. Правый край надписи — на одной линии с переключателями
/// и значением версии (у них поле 4 от края строки).
class _TextAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  /// Под названием строки: край надписи — по левому краю названия.
  final bool below;
  const _TextAction(this.label, {required this.onTap, this.below = false});
  static const style = TextStyle(fontFamily: 'Manrope', fontSize: 14.5, fontWeight: FontWeight.w700);
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        minimumSize: const Size(44, 44),
        padding: below ? const EdgeInsets.only(right: 12) : const EdgeInsets.only(left: 12, right: 4),
        alignment: below ? Alignment.centerLeft : Alignment.centerRight,
        textStyle: style,
      ),
      child: Text(label, maxLines: 1, softWrap: false),
    );
  }
}

class _Value extends StatelessWidget {
  final String text;
  const _Value(this.text);
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink2, fontFeatures: tnum),
      ),
    );
  }
}

class _Chevron extends StatelessWidget {
  final bool external;
  const _Chevron({this.external = false});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: Icon(
      external ? CupertinoIcons.arrow_up_right : CupertinoIcons.chevron_right,
      size: 17,
      color: Palette.of(context).ink3,
    ),
  );
}
