// Уведомления о стартах на Android: их ставит своя часть приложения, а не общий плагин.
// Причина: уведомление должно висеть до конца старта (его нельзя смахнуть),
// не пропадать при открытии приложения и никогда не показывать цифру у значка.
import 'package:flutter/services.dart';

class AlertEntry {
  final String key, title, body;
  final DateTime at, end;
  const AlertEntry({required this.key, required this.at, required this.end, required this.title, required this.body});

  Map<String, Object> toMap() => {
    'key': key,
    'at': at.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
    'title': title,
    'body': body,
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
}
