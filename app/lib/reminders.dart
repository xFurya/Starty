// Уведомления, поставленные в системный планировщик — срабатывают и при закрытом приложении:
//  • отмеченный сегмент («Смотрю») — за 15 минут до начала;
//  • отслеживаемый спортсмен — за 5 минут до выхода на лёд, когда время выхода известно.
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'data.dart';

const segmentLead = Duration(minutes: 15);
const skaterLead = Duration(minutes: 5);

class Reminders {
  static final _n = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    if (kIsWeb || _ready) return;
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

  /// Разрешение спрашивается при первой отметке. Отказ — не ошибка: отметка остаётся.
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

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'starts',
      'Старты',
      channelDescription: 'Начало сегмента и выход спортсмена',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
  );

  /// Все будущие уведомления по отметкам: время, заголовок, текст.
  static List<Planned> plan(Schedule data, Set<String> watched, Set<String> followed, DateTime now) {
    final out = <Planned>[];
    final follow = followed.map(norm).toSet();
    for (final s in data.starts) {
      if (watched.contains(s.id)) {
        final at = s.t0.subtract(segmentLead);
        if (at.isAfter(now)) {
          out.add(Planned('seg:${s.id}', at, '${hm(s.t0)} · ${_cap(s.segment)}',
              [s.tournament, if (s.broadcast.isNotEmpty) s.broadcast.join(' / ')].join(' · '), s.id));
        }
      }
      for (final o in s.ours) {
        if (!_followed(o.name, follow)) continue;
        final skate = s.skateAt(o);
        if (skate == null) continue;
        final at = skate.subtract(skaterLead);
        if (!at.isAfter(now)) continue;
        out.add(Planned('sk:${s.id}:${o.name}', at, '${o.time} · ${o.name}',
            [_cap(s.segment), s.tournament, if (s.broadcast.isNotEmpty) s.broadcast.join(' / ')].join(' · '), s.id));
      }
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    // iOS держит не больше 64 запланированных уведомлений — берём ближайшие
    return out.take(60).toList();
  }

  /// Спортсмен отслеживается сам или в составе пары.
  static bool _followed(String name, Set<String> follow) {
    if (follow.contains(norm(name))) return true;
    if (name.contains(' / ')) return name.split(' / ').any((p) => follow.contains(norm(p.trim())));
    return false;
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Пересобрать все уведомления по текущему расписанию и отметкам.
  static Future<void> sync(Schedule? data, Set<String> watched, Set<String> followed) async {
    if (!_ready || data == null) return;
    try {
      await _n.cancelAll();
      for (final p in plan(data, watched, followed, DateTime.now())) {
        await _n.zonedSchedule(
          id: _id(p.key),
          scheduledDate: tz.TZDateTime.from(p.at, tz.UTC),
          title: p.title,
          body: p.body,
          notificationDetails: _details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          payload: p.startId,
        );
      }
    } catch (_) {
      // без уведомлений — молча: отметки всё равно работают
    }
  }
}

class Planned {
  final String key;
  final DateTime at;
  final String title, body, startId;
  Planned(this.key, this.at, this.title, this.body, this.startId);
}
