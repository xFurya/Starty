// Напоминание за 15 минут до старта, отмеченного «Смотрю».
// Ставится в системный планировщик — срабатывает и при закрытом приложении.
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'data.dart';

class Reminders {
  static final _n = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    if (kIsWeb) return;
    tzdata.initializeTimeZones();
    await _n.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_notify'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _ready = true;
  }

  /// Спросить разрешение при первой отметке. Отказ — не ошибка: отметка остаётся.
  static Future<void> ask() async {
    if (!_ready) return;
    try {
      final a = _n.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await a?.requestNotificationsPermission();
      final i = _n.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      await i?.requestPermissions(alert: true, sound: true);
    } catch (_) {}
  }

  static int _id(String s) => s.hashCode & 0x7fffffff;

  /// Пересобрать все напоминания по отмеченным стартам.
  static Future<void> sync(Schedule? data, Set<String> watched) async {
    if (!_ready || data == null) return;
    try {
      await _n.cancelAll();
      final t = DateTime.now();
      for (final id in watched) {
        final s = data.byId(id);
        if (s == null) continue;
        final at = s.t0.subtract(const Duration(minutes: 15));
        if (!at.isAfter(t)) continue;
        final ours = s.ours.where((o) => o.time != null).map((o) => '${o.time} ${o.short}').join(', ');
        await _n.zonedSchedule(
          id: _id(id),
          scheduledDate: tz.TZDateTime.from(at, tz.UTC),
          title: '${hm(s.t0)} · ${s.segment}',
          body: [s.tournament, if (ours.isNotEmpty) ours, if (s.broadcast.isNotEmpty) s.broadcast.join(' / ')].join(' · '),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'starts',
              'Старты',
              channelDescription: 'Напоминания за 15 минут до старта',
              importance: Importance.high,
              priority: Priority.high,
            ),
            iOS: DarwinNotificationDetails(),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          payload: id,
        );
      }
    } catch (_) {
      // без уведомлений — молча: отметка «Смотрю» всё равно работает
    }
  }
}
