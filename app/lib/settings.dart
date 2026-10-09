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
import 'ui.dart';
import 'update.dart';

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
    final planned = state.planned;
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
                    iconColor: Palette.of(context).live,
                    title: 'Запрещены в системе',
                    trailing: _TextAction('Разрешить', onTap: state.askPermission),
                  ),
                ],
                _Rules(
                  enabled: r.on,
                  children: [
                    const Hairline(),
                    _Block(
                      title: 'Заранее',
                      child: Segmented<int>(
                        items: [for (final m in NotifyRules.leads) (m, '$m мин')],
                        value: r.lead,
                        onChanged: (v) => set(r.copyWith(lead: v)),
                      ),
                    ),
                    const Hairline(),
                    _Block(
                      title: 'Виды',
                      child: TileGrid(
                        keepGrid: true,
                        tiles: [
                          for (final k in NotifyRules.allKinds)
                            ChoiceTile(
                              label: kindNames[k]!,
                              color: Palette.of(context).kind(k),
                              on: r.kinds.contains(k),
                              onTap: () => set(r.copyWith(kinds: flip(r.kinds, k))),
                            ),
                        ],
                      ),
                    ),
                    const Hairline(),
                    _Block(
                      title: 'Уровень',
                      child: TileGrid(
                        tiles: [
                          for (final k in NotifyRules.allLevels)
                            ChoiceTile(
                              label: levelNames[k]!,
                              on: r.levels.contains(k),
                              onTap: () => set(r.copyWith(levels: flip(r.levels, k))),
                            ),
                        ],
                      ),
                    ),
                    const Hairline(),
                    _Block(
                      title: 'Турниры',
                      child: TileGrid(
                        tiles: [
                          ChoiceTile(
                            label: 'Российские',
                            on: r.russian,
                            onTap: () => set(r.copyWith(russian: !r.russian)),
                          ),
                          ChoiceTile(
                            label: 'Международные',
                            on: r.intl,
                            onTap: () => set(r.copyWith(intl: !r.intl)),
                          ),
                        ],
                      ),
                    ),
                    const Hairline(),
                    _Block(
                      title: 'Программы',
                      child: TileGrid(
                        tiles: [
                          ChoiceTile(
                            label: 'Короткая и ритм-танец',
                            on: r.segs.contains('short'),
                            onTap: () => set(r.copyWith(segs: flip(r.segs, 'short'))),
                          ),
                          ChoiceTile(
                            label: 'Произвольная',
                            on: r.segs.contains('free'),
                            onTap: () => set(r.copyWith(segs: flip(r.segs, 'free'))),
                          ),
                        ],
                      ),
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
                    if (state.exceptions > 0) ...[
                      const Hairline(),
                      _Row(
                        icon: CupertinoIcons.hand_point_right,
                        title: 'Исключения: ${state.exceptions}',
                        trailing: _TextAction('Сбросить', onTap: state.clearExceptions),
                      ),
                    ],
                  ],
                ),
                _Summary(
                  text: planned.isEmpty
                      ? 'Запланированных нет'
                      : 'Запланировано: ${planned.length} · ближайшее\u00A0${_when(planned.first.at)}',
                  empty: planned.isEmpty,
                ),
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
                _Block(
                  title: 'Тема',
                  child: Segmented<ThemeMode>(
                    items: const [(ThemeMode.system, 'Системная'), (ThemeMode.light, 'Светлая'), (ThemeMode.dark, 'Тёмная')],
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
              title: 'Подписка',
              subtitle: _ios ? 'Календарь' : 'Google Календарь',
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
                _Row(icon: CupertinoIcons.info, title: 'Версия', trailing: _Value(appVersion)),
                const Hairline(),
                _Row(
                  icon: CupertinoIcons.arrow_2_circlepath,
                  title: 'Расписание',
                  subtitle: state.data == null
                      ? (state.loading ? 'загрузка' : 'нет связи')
                      : state.offline
                      ? 'нет связи · ${dateTime(state.data!.generated)}'
                      : 'обновлено ${dateTime(state.data!.generated)}',
                  subtitleColor: state.offline ? Palette.of(context).live : null,
                ),
                const Hairline(),
                const _Row(icon: CupertinoIcons.doc_text, title: 'Источники', subtitle: 'ФФККР, ISU, Swiss Timing'),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(height: 32 + MediaQuery.paddingOf(context).bottom)),
      ],
    );
  }
}

/// Заголовок раздела.
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

/// Строка: значок, название, подпись, что-то справа.
class _Row extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  const _Row({
    required this.icon,
    required this.title,
    this.iconColor,
    this.subtitle,
    this.subtitleColor,
    this.trailing,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 9, 12, 9),
        child: Row(
          children: [
            _RowIcon(icon, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: p.ink, height: 1.25),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: TextStyle(fontSize: 13, color: subtitleColor ?? p.ink2, height: 1.3, fontFeatures: tnum),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
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

/// Итог правил: сколько уведомлений стоит в системе и когда ближайшее.
class _Summary extends StatelessWidget {
  final String text;
  final bool empty;
  const _Summary({required this.text, required this.empty});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
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
            child: Text(
              text,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: empty ? p.ink2 : p.ink, fontFeatures: tnum),
            ),
          ),
        ],
      ),
    );
  }
}

class _TextAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _TextAction(this.label, {required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        minimumSize: const Size(44, 44),
        textStyle: const TextStyle(fontFamily: 'Manrope', fontSize: 14.5, fontWeight: FontWeight.w700),
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
