// Виджет «Месяц» на рабочий стол Android: его рисует своя часть приложения (MonthWidget.kt),
// а что рисовать — дни со стартами, свежесть расписания, есть ли подписка — присылает приложение.
import 'package:flutter/services.dart';

class MonthWidget {
  static const _ch = MethodChannel('starty/widget');

  /// Данные виджета — JSON (month_widget.dart в приложении). Нет нативной части — молча ничего.
  static Future<void> publish(String json) async {
    try {
      await _ch.invokeMethod('publish', json);
    } on MissingPluginException {
      // не Android
    } on PlatformException {
      // виджет не главное: его сбой не должен мешать остальному
    }
  }

  /// Сколько виджетов на рабочем столе и умеет ли рабочий стол ставить их по просьбе приложения.
  static Future<({int placed, bool canPin})?> status() async {
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('status');
      if (m == null) return null;
      return (placed: (m['placed'] as num?)?.toInt() ?? 0, canPin: m['canPin'] == true);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Попросить рабочий стол поставить виджет; дальше человек подтверждает сам. false — не вышло.
  static Future<bool> pin() async {
    try {
      return await _ch.invokeMethod<bool>('pin') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Приложение запустили нажатием на виджет: куда открыть («day:2026-11-12», «month:2026-11»,
  /// «billing»), один раз. Уже открытому это приходит в [listen].
  static Future<String?> takeOpen() async {
    try {
      return await _ch.invokeMethod<String>('takeOpen');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Нажали на виджет, когда приложение уже открыто.
  static void listen(void Function(String what) onOpen) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) onOpen(call.arguments as String);
    });
  }
}
