// Разрешение на уведомления: когда система больше не спрашивает сама, — её настройки.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'state.dart';

const _ch = MethodChannel('starty/update');

/// «Разрешить». Сначала — системный вопрос. Если система его уже не показывает
/// (окончательный отказ на iOS и Android 13+, выключено в настройках телефона,
/// Android 12 и ниже) — ответ приходит сразу, и открываются настройки уведомлений
/// приложения. Строка «Запрещены в системе» обновится сама при возврате
/// (resumed → refreshPermission).
Future<void> allowNotifications(AppState state) async {
  final asked = Stopwatch()..start();
  await state.askPermission();
  if (kIsWeb || state.allowed != false) return;
  // вопрос был на экране и человек сам ответил «нет» — в настройки не уводим
  if (asked.elapsed > const Duration(milliseconds: 800)) return;
  try {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await launchUrl(Uri.parse('app-settings:'));
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      await _ch.invokeMethod('notifySettings');
    }
  } catch (_) {}
}
