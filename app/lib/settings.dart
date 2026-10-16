// Настройки: уведомления по правилам, лента, календарь, о приложении.
import 'package:flutter/cupertino.dart' show CupertinoAlertDialog, CupertinoDialogAction, CupertinoIcons, showCupertinoDialog;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:starty_alerts/starty_alerts.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_icon.dart';
import 'data.dart';
import 'main.dart';
import 'platform.dart';
import 'reminders.dart';
import 'sheets.dart';
import 'state.dart';
import 'sync.dart';
import 'system.dart';
import 'ui.dart';
import 'update.dart';
import 'updater.dart';
import 'views.dart' show freshness;

const _ics = 'webcal://xfurya.github.io/Starty/calendar.ics';
const _google = 'https://calendar.google.com/calendar/render?cid=webcal%3A%2F%2Fxfurya.github.io%2FStarty%2Fcalendar.ics';

bool get _ios => !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS);

/// «2 вида · 1 турнир · 1 спортсмен» или «Все старты».
String filterSummary(Filters f) {
  if (!f.any) return 'Все старты';
  return [
    if (f.scope.length == 1) f.scope.first == 'intl' ? 'международные' : 'российские',
    if (f.levels.length == 1) levelNames[f.levels.first]!.toLowerCase(),
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

/// Кратко о правилах: «за 15 мин · все старты» или «за 15 мин · девушки, юниоры · отслеживаемые».
String rulesSummary(NotifyRules r) {
  final parts = <String>['за ${r.lead} мин'];
  if (r.isDefault) {
    parts.add('все старты');
  } else {
    if (r.kinds.length != NotifyRules.allKinds.length) {
      parts.add([for (final k in NotifyRules.allKinds) if (r.kinds.contains(k)) kindLabel(k, r.levels).toLowerCase()].join(', '));
    }
    if (r.levels.length == 1) parts.add(levelNames[r.levels.first]!.toLowerCase());
    if (r.russian != r.intl) parts.add(r.russian ? 'российские' : 'международные');
    if (r.segs.length == 1) parts.add(r.segs.first == 'short' ? 'короткая и ритм-танец' : 'произвольная и танец');
    if (!r.night) parts.add('без ночных');
    if (r.onlyFollowed) parts.add('только с отслеживаемыми');
  }
  return parts.join(' · ');
}

class SettingsView extends StatelessWidget {
  final AppState state;
  const SettingsView({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final r = state.rules;
    // уже сработавшие не считаем: минутный тик перестраивает экран
    final t = now();
    final planned = state.planned.where((x) => x.at.isAfter(t)).toList();
    final p = Palette.of(context);
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
                  onChanged: (v) => state.setRules(r.copyWith(on: v)),
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
                const Hairline(),
                _Rules(
                  enabled: r.on,
                  children: [
                    _Row(
                      icon: CupertinoIcons.slider_horizontal_3,
                      title: 'Правила',
                      subtitle: rulesSummary(r),
                      onTap: () => openNotifySettings(context, state),
                      trailing: const _Chevron(),
                    ),
                  ],
                ),
                // запрещены в системе — ни одно не придёт, так и пишем
                if (planned.isEmpty)
                  const _Summary(head: 'Запланированных нет', empty: true)
                else if (state.allowed == false)
                  _Summary(head: 'Запланировано: ${planned.length}', tail: 'не придут', empty: true)
                else
                  _Summary(
                    head: 'Запланировано: ${planned.length}',
                    tail: 'ближайшее ${_when(planned.first.at)}',
                  ),
              ],
            ),
          ),
        ),

        // ---------------------------------------------------------- отслеживаемые
        const SliverToBoxAdapter(child: _Head('Спортсмены')),
        SliverToBoxAdapter(
          child: Plate(
            child: _Row(
              icon: CupertinoIcons.person_crop_circle_badge_checkmark,
              title: 'Отслеживаемые',
              subtitle: followSummary(state.follow),
              onTap: () => openFollow(context, state),
              trailing: const _Chevron(),
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
                _SwitchRow(
                  icon: CupertinoIcons.map,
                  title: 'Региональные федерации',
                  subtitle: state.regionNames.isEmpty
                      ? 'в расписании пока нет'
                      : 'Старты региональных федераций: ${state.regionNames.join(', ')}',
                  value: state.regional,
                  onChanged: state.setRegional,
                ),
                const Hairline(),
                _ChoiceRow<String>(
                  icon: state.liveMode == liveDelayed ? CupertinoIcons.timer : CupertinoIcons.bolt,
                  title: 'Живые места',
                  value: state.liveMode,
                  items: const [(liveInstant, 'Моментально'), (liveDelayed, 'С опозданием')],
                  showValue: true,
                  onChanged: state.setLiveMode,
                ),
              ],
            ),
          ),
        ),

        // ---------------------------------------------------------- оформление
        const SliverToBoxAdapter(child: _Head('Оформление')),
        SliverToBoxAdapter(
          child: Plate(
            child: Column(
              children: [
                if (AppIcons.supported)
                  _Row(
                    icon: CupertinoIcons.app,
                    title: 'Значок приложения',
                    onTap: () => openIcons(context, state),
                    trailing: const _Chevron(),
                  ),
                if (AppIcons.supported) const Hairline(),
                _ChoiceRow<ThemeMode>(
                  icon: CupertinoIcons.circle_lefthalf_fill,
                  title: 'Тема',
                  value: state.theme,
                  items: const [(ThemeMode.system, 'Системная'), (ThemeMode.light, 'Светлая'), (ThemeMode.dark, 'Тёмная')],
                  showValue: true,
                  onChanged: state.setTheme,
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
              subtitle: 'Российские и международные с россиянами и белорусами · обновляются сами',
              onTap: () => launchUrl(Uri.parse(_ios ? _ics : _google), mode: LaunchMode.externalApplication),
              trailing: const _Chevron(external: true),
            ),
          ),
        ),

        // ---------------------------------------------------------- аккаунт
        if (syncConfigured) const SliverToBoxAdapter(child: _Head('Аккаунт')),
        if (syncConfigured)
          SliverToBoxAdapter(
            child: Plate(
              child: _Row(
                icon: CupertinoIcons.person_crop_circle,
                title: 'Аккаунт',
                subtitle: syncSummary(state),
                subtitleColor: state.syncProblem != null ? p.live : null,
                onTap: () => openAccount(context, state),
                trailing: const _Chevron(),
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
    if (!Updates.managed) {
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

/// Строка выбора одного из нескольких: как остальные строки, справа «вверх-вниз»;
/// по нажатию — меню рядом со строкой. Текущее значение видно всегда: в подписи
/// ([caption]) или справа ([showValue]).
class _ChoiceRow<T> extends StatelessWidget {
  final IconData icon;
  final String title;
  final T value;
  final List<(T, String)> items;
  final String Function(T value)? caption;
  final bool showValue;
  final ValueChanged<T> onChanged;
  const _ChoiceRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.items,
    required this.onChanged,
    this.caption,
    this.showValue = false,
  });
  @override
  Widget build(BuildContext context) {
    final label = [for (final (v, l) in items) if (v == value) l].firstOrNull ?? '';
    return Builder(
      builder: (rowContext) => _Row(
        icon: icon,
        title: title,
        subtitle: caption?.call(value),
        onTap: () async {
          final v = await showChoiceMenu<T>(rowContext, items: items, selected: value, label: title);
          if (v != null && v != value) onChanged(v);
        },
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showValue) _Value(label),
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: _UpDown(),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpDown extends StatelessWidget {
  const _UpDown();
  @override
  Widget build(BuildContext context) =>
      Icon(CupertinoIcons.chevron_up_chevron_down, size: 17, color: Palette.of(context).ink3);
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

/// «9 спортсменов · россияне и белорусы на международных».
String followSummary(Follow f) {
  final n = f.names.length;
  final parts = <String>[
    n == 0 ? 'спортсмены не выбраны' : '$n ${plural(n, 'спортсмен', 'спортсмена', 'спортсменов')}',
    if (f.russians && f.belarusians)
      'россияне и белорусы на международных'
    else if (f.russians)
      'россияне на международных'
    else if (f.belarusians)
      'белорусы на международных',
  ];
  return cap(parts.join(' · '));
}

// ------------------------------------------------------------------ окна настроек

/// Окно настроек: неподвижная однотонная область строки состояния (как на главных экранах),
/// шапка со «‹ Настройки», содержимое и полоса «Отменить / Сохранить». Выход с несохранённым — вопрос.
class _SettingsPage extends StatelessWidget {
  final String title;
  final List<Widget> slivers;
  final bool dirty;

  /// Есть — внизу панель «Отменить / Сохранить»; нет — страница действует сразу (как «Аккаунт»).
  final Future<void> Function()? onSave;
  const _SettingsPage({
    required this.title,
    required this.slivers,
    this.dirty = false,
    this.onSave,
  });

  Future<void> _leave(BuildContext context) async {
    final nav = Navigator.of(context);
    if (!dirty) {
      nav.pop();
      return;
    }
    final save = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Изменения не сохранены'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Не сохранять'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (save == null) return;
    if (save) await onSave?.call();
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final save = onSave;
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave(context);
      },
      child: Scaffold(
        backgroundColor: p.bg,
        body: Column(
          children: [
            // область строки состояния — неподвижная и однотонная, как на главных экранах
            Container(height: MediaQuery.paddingOf(context).top, color: p.bg),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Stack(
                        children: [
                          IceHero(eyebrow: '', title: title, sparkles: 2),
                          Positioned(
                            top: 12,
                            left: 6,
                            child: TextButton.icon(
                              onPressed: () => _leave(context),
                              style: TextButton.styleFrom(
                                foregroundColor: p.accent,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                              ),
                              icon: const Icon(
                                CupertinoIcons.chevron_back,
                                size: 18,
                              ),
                              label: const Text(
                                'Настройки',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ...slivers,
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
              ),
            ),
            if (save != null)
              Container(
                decoration: BoxDecoration(
                  color: p.bg,
                  border: Border(top: BorderSide(color: p.plateLine)),
                ),
                padding: EdgeInsets.fromLTRB(
                  16,
                  12,
                  16,
                  12 + MediaQuery.paddingOf(context).bottom,
                ),
                child: LayoutBuilder(
                  builder: (context, k) => Row(
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: k.maxWidth * .4),
                        child: SheetButton(
                          neutral: true,
                          compact: true,
                          label: 'Отменить',
                          onTap: () => Navigator.of(context).pop(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SheetButton(
                          filled: true,
                          label: 'Сохранить',
                          onTap: dirty
                              ? () async {
                                  final nav = Navigator.of(context);
                                  await save();
                                  nav.pop();
                                }
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ правила уведомлений

void openNotifySettings(BuildContext context, AppState state) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _NotifyPage(state: state)));
}

class _NotifyPage extends StatefulWidget {
  final AppState state;
  const _NotifyPage({required this.state});
  @override
  State<_NotifyPage> createState() => _NotifyPageState();
}

class _NotifyPageState extends State<_NotifyPage> {
  late NotifyRules r = widget.state.rules;

  bool get _dirty => r.toJson() != widget.state.rules.toJson();

  void _set(NotifyRules n) => setState(() => r = n);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = widget.state;
    Set<String> flip(Set<String> s, String k) => s.contains(k) ? ({...s}..remove(k)) : {...s, k};
    final exceptions = activeExceptions(state);
    final kinds = [
      for (final k in NotifyRules.allKinds)
        ChoiceTile(
          label: kindLabel(k, r.levels),
          color: p.kind(k),
          on: r.kinds.contains(k),
          onTap: () => _set(r.copyWith(kinds: flip(r.kinds, k))),
        ),
    ];
    final levels = [
      for (final k in NotifyRules.allLevels)
        ChoiceTile(label: levelNames[k]!, on: r.levels.contains(k), onTap: () => _set(r.copyWith(levels: flip(r.levels, k)))),
    ];
    final scope = [
      ChoiceTile(label: 'Российские', on: r.russian, onTap: () => _set(r.copyWith(russian: !r.russian))),
      ChoiceTile(label: 'Международные', on: r.intl, onTap: () => _set(r.copyWith(intl: !r.intl))),
    ];
    final segs = [
      ChoiceTile(label: 'Короткая и ритм-танец', on: r.segs.contains('short'), onTap: () => _set(r.copyWith(segs: flip(r.segs, 'short')))),
      // ПП и ПТ: произвольная программа и произвольный танец
      ChoiceTile(label: 'Произвольная и танец', on: r.segs.contains('free'), onTap: () => _set(r.copyWith(segs: flip(r.segs, 'free')))),
    ];
    final group = [...kinds, ...levels, ...scope, ...segs];
    return _SettingsPage(
      title: 'Уведомления',
      dirty: _dirty,
      onSave: () => state.setRules(r.copyWith(on: state.rules.on)),
      slivers: [
        const SliverToBoxAdapter(child: _Head('Начало старта')),
        SliverToBoxAdapter(
          child: Plate(
            child: Column(
              children: [
                // «5 мин … 60 мин» не помещаются — «Заранее, мин» и одни числа
                _ShortBlock(
                  title: 'Заранее',
                  shortTitle: 'Заранее, мин',
                  labels: [for (final m in NotifyRules.leads) '$m мин'],
                  shortLabels: [for (final m in NotifyRules.leads) '$m'],
                  child: (labels) => Segmented<int>(
                    items: [for (var i = 0; i < NotifyRules.leads.length; i++) (NotifyRules.leads[i], labels[i])],
                    value: r.lead,
                    onChanged: (v) => _set(r.copyWith(lead: v)),
                  ),
                ),
                const Hairline(),
                _Block(title: 'Старты', child: TileGrid(tiles: scope, group: group)),
                const Hairline(),
                _Block(title: 'Уровень', child: TileGrid(tiles: levels, group: group)),
                const Hairline(),
                _Block(title: 'Виды', child: TileGrid(tiles: kinds, group: group)),
                const Hairline(),
                _Block(title: 'Программы', child: TileGrid(tiles: segs, group: group)),
                const Hairline(),
                _SwitchRow(
                  icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                  title: 'Только с отслеживаемыми',
                  subtitle: followSummary(state.follow),
                  value: r.onlyFollowed,
                  onChanged: (v) => _set(r.copyWith(onlyFollowed: v)),
                ),
                const Hairline(),
                _SwitchRow(
                  icon: CupertinoIcons.moon,
                  title: 'Ночные старты',
                  subtitle: '00:00–08:00',
                  value: r.night,
                  onChanged: (v) => _set(r.copyWith(night: v)),
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: _Head('Выход на лёд')),
        SliverToBoxAdapter(
          child: Plate(
            child: Column(
              children: [
                _SwitchRow(
                  icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                  title: 'Выход отслеживаемых',
                  subtitle: followSummary(state.follow),
                  value: r.skaters,
                  onChanged: (v) => _set(r.copyWith(skaters: v)),
                ),
                if (r.skaters)
                  _ShortBlock(
                    title: 'Заранее',
                    shortTitle: 'Заранее, мин',
                    labels: [for (final m in NotifyRules.leads) '$m мин'],
                    shortLabels: [for (final m in NotifyRules.leads) '$m'],
                    child: (labels) => Segmented<int>(
                      items: [for (var i = 0; i < NotifyRules.leads.length; i++) (NotifyRules.leads[i], labels[i])],
                      value: r.skaterLead,
                      onChanged: (v) => _set(r.copyWith(skaterLead: v)),
                    ),
                  ),
                // закрепить и убрать само умеет только Android
                if (isAndroid) ...[
                  const Hairline(),
                  _SwitchRow(
                    icon: CupertinoIcons.pin,
                    title: 'Не смахиваются',
                    subtitle: r.skaters ? 'старт — до конца, спортсмен — до выхода на лёд' : 'до конца старта',
                    value: r.pin,
                    onChanged: (v) => _set(r.copyWith(pin: v)),
                  ),
                  if (r.skaters) ...[
                    const Hairline(),
                    _SwitchRow(
                      icon: CupertinoIcons.clear,
                      title: 'Убирать после выхода',
                      value: r.clear,
                      onChanged: (v) => _set(r.copyWith(clear: v)),
                    ),
                    if (r.clear)
                      _ShortBlock(
                        title: 'Через',
                        shortTitle: 'Через, мин',
                        labels: [for (final m in NotifyRules.gones) '$m мин'],
                        shortLabels: [for (final m in NotifyRules.gones) '$m'],
                        child: (labels) => Segmented<int>(
                          items: [for (var i = 0; i < NotifyRules.gones.length; i++) (NotifyRules.gones[i], labels[i])],
                          value: r.gone,
                          onChanged: (v) => _set(r.copyWith(gone: v)),
                        ),
                      ),
                  ],
                ],
                if (exceptions > 0) ...[
                  const Hairline(),
                  _Row(
                    icon: CupertinoIcons.bell_circle,
                    title: 'Исключения: $exceptions',
                    subtitle: 'включены или выключены вручную',
                    action: 'Сбросить',
                    onAction: state.clearExceptions,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (isAndroid) ...[
          const SliverToBoxAdapter(child: _Head('Система')),
          SliverToBoxAdapter(
            child: Plate(
              child: _Row(
                icon: CupertinoIcons.speaker_2,
                title: 'Звук и вибрация',
                subtitle: 'всплывание, экран блокировки',
                onTap: () => StartyAlerts.channelSettings().catchError((_) {}),
                trailing: const _Chevron(external: true),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ------------------------------------------------------------------ отслеживаемые

void openFollow(BuildContext context, AppState state) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _FollowPage(state: state)));
}

/// Отслеживаемые: россияне и белорусы на международных стартах (по отдельности) и выбранные
/// спортсмены. Они в карточках стартов, в «Выходе на лёд» и в правиле «Только с отслеживаемыми».
class _FollowPage extends StatefulWidget {
  final AppState state;
  const _FollowPage({required this.state});
  @override
  State<_FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<_FollowPage> {
  late final Follow f0 = widget.state.follow;
  late bool ru = f0.russians, by = f0.belarusians;
  late final Set<String> sel = {...f0.names};
  final _q = TextEditingController();
  String q = '';

  bool get _dirty => ru != f0.russians || by != f0.belarusians || sel.length != f0.names.length || !sel.containsAll(f0.names);

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = widget.state.data;
    final shown = q.isEmpty || data == null ? ([...sel]..sort()) : searchAthletes(data, q, soon: soonAthletes(data, now()));
    return _SettingsPage(
      title: 'Отслеживаемые',
      dirty: _dirty,
      onSave: () => widget.state.setFollow(sel, russians: ru, belarusians: by),
      slivers: [
        const SliverToBoxAdapter(child: _Head('Международные старты')),
        SliverToBoxAdapter(
          child: Plate(
            child: Column(
              children: [
                _SwitchRow(icon: CupertinoIcons.person_2, title: 'Все россияне', value: ru, onChanged: (v) => setState(() => ru = v)),
                const Hairline(),
                _SwitchRow(icon: CupertinoIcons.person_2, title: 'Все белорусы', value: by, onChanged: (v) => setState(() => by = v)),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(child: _Head(sel.isEmpty ? 'Спортсмены' : 'Спортсмены · ${sel.length}')),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SearchBox(controller: _q, onChanged: (v) => setState(() => q = v.trim())),
                const SizedBox(height: 6),
                for (final a in shown)
                  AthleteCheckRow(
                    name: a,
                    data: data,
                    value: sel.contains(a),
                    onTap: () => setState(() => sel.contains(a) ? sel.remove(a) : sel.add(a)),
                  ),
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text(q.isEmpty ? 'Не выбраны' : 'Не найдено', style: TextStyle(color: p.ink2, fontSize: 15)),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ синхронизация

void openAccount(BuildContext context, AppState state) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => _AccountPage(state: state)));
}

/// Строка в настройках: что с синхронизацией на этом устройстве.
String syncSummary(AppState st) {
  if (!syncConfigured) return 'Недоступен в этой сборке';
  if (!st.syncOn) return 'Вход не выполнен';
  final who = st.syncEmail ?? 'по коду';
  if (st.syncProblem != null) return '${st.syncProblem} · $who';
  final at = st.syncAt;
  return at == null
      ? 'Ещё не обновлялось · $who'
      : 'Обновлено ${_when(at)} · $who';
}

/// Код группами по четыре знака — так его легче прочитать и продиктовать.
String _groupedCode(String c) => c.length == 16
    ? '${c.substring(0, 4)} ${c.substring(4, 8)} ${c.substring(8, 12)} ${c.substring(12)}'
    : c;

/// Синхронизация настроек между устройствами. Основной путь — почта и пароль; код — без почты.
/// Настройки общие для всех устройств с одним входом или одним кодом.
/// Подтверждение отключения (выход из аккаунта или код): true — кнопка [action], false — «Отмена».
/// Только заголовок и кнопки, без пояснений.
Future<bool> confirmDisconnect(BuildContext context, {required String title, required String action}) async {
  final go = await showCupertinoDialog<bool>(
    context: context,
    builder: (c) => CupertinoAlertDialog(
      title: Text(title),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Отмена'),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(c, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return go == true;
}

class _AccountPage extends StatefulWidget {
  final AppState state;
  const _AccountPage({required this.state});
  @override
  State<_AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<_AccountPage> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _mailOpen = false; // в режиме кода: раскрыта форма «Привязать почту»
  String? _error, _info;

  @override
  void initState() {
    super.initState();
    widget.state.refreshCodeLink();
  }

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Выход из аккаунта сбрасывает настройки этого устройства: сначала спрашиваем.
  Future<void> _signOut(AppState st) async {
    if (!await confirmDisconnect(context, title: 'Выйти из аккаунта?', action: 'Выйти') || !mounted) return;
    await _act(() async {
      await st.signOutSync();
      return null;
    });
  }

  /// Отключение кода сбрасывает настройки этого устройства: сначала спрашиваем.
  Future<void> _disconnectCode(AppState st) async {
    if (!await confirmDisconnect(context, title: 'Выйти из аккаунта?', action: 'Выйти') || !mounted) return;
    await _act(() async {
      await st.disconnectSync();
      return null;
    });
  }

  /// Одно действие с сервером. Пока идёт — кнопки неактивны; итог или причина — под разделами.
  Future<void> _act(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final msg = await action();
    if (!mounted) return;
    final hint = msg == kConfirmMail;
    setState(() {
      _busy = false;
      _error = hint ? null : msg;
      _info = hint ? msg : null;
    });
    widget.state.refreshCodeLink();
  }

  /// Новый код вместо прежнего: другие устройства со старым кодом перестанут получать общие настройки.
  Future<void> _replaceCode(AppState st) async {
    if (!await confirmDisconnect(context, title: 'Заменить код?', action: 'Заменить') || !mounted) return;
    await _act(st.createLinkedCode);
  }

  Future<void> _mail({required bool create, bool link = false}) async {
    final mail = _email.text.trim();
    if (!mail.contains('@')) {
      setState(() => _error = 'Введите почту');
      return;
    }
    if (_pass.text.isEmpty) {
      setState(() => _error = 'Введите пароль');
      return;
    }
    await _act(
      () => link
          ? widget.state.linkMail(mail, _pass.text, create: create)
          : widget.state.signInSync(mail, _pass.text, create: create),
    );
  }

  /// Поля почты и пароля и кнопки «Войти» / «Регистрация» — вход и привязка почты к коду.
  List<Widget> _mailForm(Palette p, {required bool link}) => [
    TextField(
      controller: _email,
      keyboardType: TextInputType.emailAddress,
      autocorrect: false,
      enableSuggestions: false,
      style: TextStyle(fontSize: 15.5, color: p.ink),
      decoration: _field(p, 'Почта'),
    ),
    const SizedBox(height: 8),
    TextField(
      controller: _pass,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      style: TextStyle(fontSize: 15.5, color: p.ink),
      decoration: _field(p, 'Пароль'),
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        Expanded(
          child: SheetButton(
            filled: true,
            label: 'Войти',
            onTap: _busy ? null : () => _mail(create: false, link: link),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SheetButton(
            neutral: true,
            label: 'Регистрация',
            onTap: _busy ? null : () => _mail(create: true, link: link),
          ),
        ),
      ],
    ),
  ];

  void _copy(String code) {
    Clipboard.setData(ClipboardData(text: code));
    setState(() => _info = 'Код скопирован');
  }

  InputDecoration _field(Palette p, String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: p.ink2),
    filled: true,
    fillColor: p.bg,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: p.control),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: p.accent, width: 1.4),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final p = Palette.of(context);
        final st = widget.state;
        final code = st.syncCode;
        final connected = st.syncOn;
        return _SettingsPage(
          title: 'Аккаунт',
          slivers: [
            if (!syncConfigured) ...[
              SliverToBoxAdapter(
                child: Plate(
                  child: _Row(
                    icon: CupertinoIcons.exclamationmark_circle,
                    iconColor: p.live,
                    title: 'Аккаунты в этой сборке недоступны',
                    subtitle: 'Настройки хранятся только на этом устройстве.',
                  ),
                ),
              ),
            ] else if (connected) ...[
              const SliverToBoxAdapter(child: _Head('Состояние')),
              SliverToBoxAdapter(
                child: Plate(
                  child: _Row(
                    icon: st.syncProblem == null
                        ? CupertinoIcons.checkmark_circle
                        : CupertinoIcons.exclamationmark_circle,
                    iconColor: st.syncProblem == null ? null : p.live,
                    title: st.syncProblem ?? 'Настройки в аккаунте',
                    subtitle: st.syncAt == null
                        ? 'Ещё не обновлялось'
                        : 'Обновлено: ${_when(st.syncAt!)}',
                    subtitleColor: st.syncProblem == null ? null : p.live,
                    action: _busy ? null : 'Обновить',
                    onAction: _busy ? null : () => _act(st.syncNow),
                  ),
                ),
              ),
              if (st.syncEmail != null) ...[
                const SliverToBoxAdapter(child: _Head('Аккаунт')),
                SliverToBoxAdapter(
                  child: Plate(
                    child: Column(
                      children: [
                        _Row(
                          icon: CupertinoIcons.mail,
                          title: st.syncEmail!,
                          subtitle:
                              'Настройки одни на все устройства, где вы вошли',
                        ),
                        const Hairline(),
                        _Row(
                          icon: CupertinoIcons.square_arrow_right,
                          title: 'Выйти с этого устройства',
                          onTap: _busy ? null : () => _signOut(st),
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: _Head('Вход по коду')),
                SliverToBoxAdapter(
                  child: Plate(
                    child: Column(
                      children: [
                        if (st.syncLinkedCode == null && !st.codeLinkChecked)
                          // сервер ещё не ответил: ничего не утверждаем и действий не даём
                          const _Row(icon: CupertinoIcons.number, title: 'Проверяем…')
                        else if (st.syncLinkedCode != null) ...[
                          _Row(
                            icon: CupertinoIcons.number,
                            title: _groupedCode(st.syncLinkedCode!),
                            action: 'Копировать',
                            onAction: () => _copy(st.syncLinkedCode!),
                          ),
                          const Hairline(),
                          _Row(
                            icon: CupertinoIcons.arrow_2_circlepath,
                            title: 'Создать новый код',
                            onTap: _busy ? null : () => _replaceCode(st),
                          ),
                        ] else if (st.codeLinked == true) ...[
                          const _Row(icon: CupertinoIcons.number, title: 'Код привязан'),
                          const Hairline(),
                          _Row(
                            icon: CupertinoIcons.arrow_2_circlepath,
                            title: 'Создать новый код',
                            onTap: _busy ? null : () => _replaceCode(st),
                          ),
                        ] else
                          _Row(
                            icon: CupertinoIcons.plus_circle,
                            title: 'Создать код',
                            onTap: _busy ? null : () => _act(st.createLinkedCode),
                          ),
                        if (st.syncLinkedCode != null || st.codeLinkChecked) ...[
                        const Hairline(),
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _code,
                                  textCapitalization: TextCapitalization.characters,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  style: TextStyle(fontSize: 15.5, color: p.ink),
                                  decoration: _field(p, 'Другой код'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              SheetButton(
                                compact: true,
                                label: 'Привязать',
                                onTap: _busy ? null : () => _act(() => st.linkEnteredCode(_code.text)),
                              ),
                            ],
                          ),
                        ),
                        ],
                      ],
                    ),
                  ),
                ),
              ] else if (code != null) ...[
                const SliverToBoxAdapter(child: _Head('Вход по коду')),
                SliverToBoxAdapter(
                  child: Plate(
                    child: Column(
                      children: [
                        _Row(
                          icon: CupertinoIcons.number,
                          title: _groupedCode(code),
                          subtitle: 'Введите его на другом устройстве, и настройки станут общими. Код открывает настройки: не отправляйте его посторонним',
                          action: 'Копировать',
                          onAction: () => _copy(code),
                        ),
                        const Hairline(),
                        _Row(
                          icon: CupertinoIcons.square_arrow_right,
                          title: 'Выйти с этого устройства',
                          onTap: _busy ? null : () => _disconnectCode(st),
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: _Head('Почта')),
                SliverToBoxAdapter(
                  child: Plate(
                    child: Column(
                      children: [
                        _Row(
                          icon: CupertinoIcons.mail,
                          title: 'Привязать почту',
                          onTap: _busy ? null : () => setState(() => _mailOpen = !_mailOpen),
                        ),
                        if (_mailOpen) ...[
                          const Hairline(),
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _mailForm(p, link: true),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ] else ...[
              const SliverToBoxAdapter(child: _Head('Аккаунт')),
              SliverToBoxAdapter(
                child: Plate(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Почта и пароль. Настройки одни на все устройства, где вы вошли.',
                          style: TextStyle(
                            fontSize: 14,
                            color: p.ink2,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ..._mailForm(p, link: false),
                      ],
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: _Head('Вход по коду')),
              SliverToBoxAdapter(
                child: Plate(
                  child: Column(
                    children: [
                      _Row(
                        icon: CupertinoIcons.plus_circle,
                        title: 'Создать код',
                        subtitle: 'Без почты. Настройки этого устройства уйдут на сервер под новым кодом',
                        onTap: _busy ? null : () => _act(st.createSyncCode),
                      ),
                      const Hairline(),
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _code,
                                textCapitalization:
                                    TextCapitalization.characters,
                                autocorrect: false,
                                enableSuggestions: false,
                                style: TextStyle(fontSize: 15.5, color: p.ink),
                                decoration: _field(
                                  p,
                                  'Код с другого устройства',
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            SheetButton(
                              compact: true,
                              label: 'Ввести',
                              onTap: _busy
                                  ? null
                                  : () => _act(
                                      () => st.enterSyncCode(_code.text),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_busy || _error != null || _info != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text(
                    _busy ? 'Связываемся с сервером…' : (_error ?? _info!),
                    style: TextStyle(
                      fontSize: 14,
                      color: _error != null ? p.live : p.ink2,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ------------------------------------------------------------------ значок приложения

void openIcons(BuildContext context, AppState state) {
  Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => _IconPage(state: state)));
}

class _IconPage extends StatefulWidget {
  final AppState state;
  const _IconPage({required this.state});
  @override
  State<_IconPage> createState() => _IconPageState();
}

class _IconPageState extends State<_IconPage> {
  List<IconVariant> all = const [];
  String? was, pick;
  String? error;

  @override
  void initState() {
    super.initState();
    () async {
      final a = await AppIcons.available();
      final c = await AppIcons.current();
      // у значка с числом на Android в имени — день: date_teal_15 → date_teal
      final cur = a.where((v) => c == v.id || c.startsWith('${v.id}_')).firstOrNull?.id ?? 'classic';
      if (!mounted) return;
      setState(() {
        all = a;
        was = cur;
        pick = cur;
      });
    }();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final groups = <String, String>{'classic': 'Классический', 'date': 'С сегодняшним числом'};
    Widget tile(IconVariant v) {
      final on = v.id == pick;
      return Semantics(
        selected: on,
        button: true,
        label: v.name,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => pick = v.id),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: on ? p.accent : Colors.transparent, width: 2.5),
                  ),
                  child: Padding(padding: const EdgeInsets.all(3), child: IconPreview(variant: v, size: 64)),
                ),
                const SizedBox(height: 6),
                Text(
                  v.name,
                  style: TextStyle(fontSize: 13, color: on ? p.ink : p.ink2, fontWeight: on ? FontWeight.w700 : FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return _SettingsPage(
      title: 'Значок',
      dirty: pick != null && pick != was,
      onSave: () async {
        final ok = await AppIcons.set(pick!);
        if (ok) widget.state.touchSync();
        if (!ok && mounted) setState(() => error = 'Система не сменила значок');
      },
      slivers: [
        for (final g in groups.entries)
          if (all.any((v) => v.group == g.key)) ...[
            SliverToBoxAdapter(child: _Head(g.value)),
            SliverToBoxAdapter(
              child: Plate(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Wrap(spacing: 4, runSpacing: 6, children: [for (final v in all) if (v.group == g.key) tile(v)]),
                ),
              ),
            ),
          ],
        if (isAndroid)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text('Значок сменится, когда приложение уйдёт с экрана', style: TextStyle(fontSize: 13, color: p.ink2)),
            ),
          ),
        if (isDesktop)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text(
                isWindows ? 'Значок окна и панели задач; ярлык в «Пуске» — классический' : 'Значок в Доке, пока приложение открыто',
                style: TextStyle(fontSize: 13, color: p.ink2),
              ),
            ),
          ),
        if (error != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text(error!, style: TextStyle(fontSize: 13, color: p.live)),
            ),
          ),
      ],
    );
  }
}
