// Уведомления о стартах на Android: их ставит своя часть приложения, а не общий плагин.
// Причина: уведомление может быть закреплено (не смахивается) до своего срока,
// не пропадать при открытии приложения и никогда не показывать цифру у значка.
import 'package:flutter/services.dart';

class AlertEntry {
  /// title — заголовок; body — одна строка свёрнутого вида.
  final String key, title, body;
  /// at — показать, hold — до этого не смахивается (не позже end), end — убрать.
  final DateTime at, hold, end;
  /// Строки развёрнутого вида (InboxStyle); пусто — развёрнутый вид повторяет body.
  final List<String> lines;
  /// Турнир: его уведомления в шторке складываются в одну стопку с названием [groupTitle].
  final String group, groupTitle;
  /// Выход спортсмена — напоминание (CATEGORY_REMINDER), начало старта — событие (CATEGORY_EVENT).
  final bool reminder;
  /// С [liveAt] (начало старта) заголовок — [liveTitle]: висящее обновляется само, тихо.
  /// Часть [liveMark] в нём — цветом [liveColor] ([liveColorDark] в тёмной теме, ARGB).
  final DateTime? liveAt;
  final String liveTitle, liveMark;
  final int liveColor, liveColorDark;
  const AlertEntry({
    required this.key,
    required this.at,
    required this.hold,
    required this.end,
    required this.title,
    required this.body,
    this.lines = const [],
    this.group = '',
    this.groupTitle = '',
    this.reminder = false,
    this.liveAt,
    this.liveTitle = '',
    this.liveMark = '',
    this.liveColor = 0,
    this.liveColorDark = 0,
  });

  Map<String, Object> toMap() => {
    'key': key,
    'at': at.millisecondsSinceEpoch,
    'hold': hold.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
    'title': title,
    'body': body,
    'lines': lines,
    'group': group,
    'groupTitle': groupTitle,
    'reminder': reminder,
    'liveAt': liveAt?.millisecondsSinceEpoch ?? 0,
    'liveTitle': liveTitle,
    'liveMark': liveMark,
    'liveColor': liveColor,
    'liveColorDark': liveColorDark,
  };
}

class StartyAlerts {
  static const _ch = MethodChannel('starty/alerts');

  /// Заменить расписание уведомлений. Уже показанные остаются, пока старт не кончится;
  /// пропавшие из списка убираются.
  static Future<void> sync(List<AlertEntry> entries) =>
      _ch.invokeMethod('sync', [for (final e in entries) e.toMap()]);

  /// Убрать всё: запланированное и показанное.
  static Future<void> clear() => _ch.invokeMethod('clear');

  /// Системные настройки канала: звук, вибрация, всплывание, экран блокировки.
  static Future<void> channelSettings() => _ch.invokeMethod('channelSettings');
}
