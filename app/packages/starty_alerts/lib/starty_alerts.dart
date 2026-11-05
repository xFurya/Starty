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
  /// Старт, к которому относится уведомление: по нему файл состояния говорит, что старт кончился
  /// (тогда его уведомления снимаются сразу) или затянулся (тогда не снимаются в [end]).
  final String start;
  /// Опоздало (время [at] прошло, а показано не было: старт добавили или сдвинули позже, телефон
  /// был выключен) — показать, если сейчас раньше [late]; позже — уже не о чем. null — до [end].
  final DateTime? late;
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
    this.start = '',
    this.late,
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
    'start': start,
    'late': (late ?? end).millisecondsSinceEpoch,
  };
}

class StartyAlerts {
  static const _ch = MethodChannel('starty/alerts');

  /// Заменить расписание уведомлений. Уже показанные остаются, пока старт не кончится;
  /// пропавшие из списка убираются. [watch] — адрес файла состояния стартов (now.json): пока висит
  /// уведомление о старте, приложение само спрашивает его и снимает уведомление, как только старт
  /// закончился. Пусто — не спрашивать. [done] — старты, которые по данным приложения уже закончились,
  /// и до какого момента это помнить: их уведомления не вернёт расписание, где они ещё идут
  /// (фоновое обновление без итогов с табло).
  static Future<void> sync(List<AlertEntry> entries, {String watch = '', Map<String, DateTime> done = const {}}) =>
      _ch.invokeMethod('sync', {
        'entries': [for (final e in entries) e.toMap()],
        'watch': watch,
        'done': {for (final d in done.entries) d.key: d.value.millisecondsSinceEpoch},
      });

  /// Убрать всё: запланированное и показанное.
  static Future<void> clear() => _ch.invokeMethod('clear');

  /// Работа в фоне: 0 — без ограничений; 1 — экономия энергии (по умолчанию: проверка конца старта
  /// и фоновое обновление могут опаздывать); 2 — запрещена (уведомления могут не прийти).
  static Future<int?> background() => _ch.invokeMethod<int>('background');

  /// Снять ограничение работы в фоне: системный вопрос или настройки приложения.
  static Future<void> allowBackground() => _ch.invokeMethod('allowBackground');

  /// Системные настройки канала: звук, вибрация, всплывание, экран блокировки.
  static Future<void> channelSettings() => _ch.invokeMethod('channelSettings');
}
