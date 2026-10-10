// Уведомления о стартах. По умолчанию — о каждом старте, за 15 минут до начала;
// какие старты и за сколько — решают правила из настроек, отдельный старт можно
// включить или выключить вручную. Ставятся в системный планировщик — срабатывают
// и при закрытом приложении.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:starty_alerts/starty_alerts.dart';

import 'data.dart';

/// Правила: о каких стартах напоминать и за сколько минут.
class NotifyRules {
  final bool on;
  final int lead; // минут до начала
  final Set<String> kinds; // women, men, pairs, dance
  final Set<String> levels; // senior, junior
  final Set<String> segs; // short — КП и РТ, free — ПП и ПТ
  final bool russian, intl;
  final bool night; // старты с 00:00 до 08:00 МСК
  final bool skaters; // отдельно — выход каждого нашего, когда время известно

  static const allKinds = ['women', 'men', 'pairs', 'dance'];
  static const allLevels = ['senior', 'junior'];
  static const allSegs = ['short', 'free'];
  static const leads = [5, 10, 15, 30, 60];

  const NotifyRules({
    this.on = true,
    this.lead = 15,
    this.kinds = const {'women', 'men', 'pairs', 'dance'},
    this.levels = const {'senior', 'junior'},
    this.segs = const {'short', 'free'},
    this.russian = true,
    this.intl = true,
    this.night = true,
    this.skaters = false,
  });

  static String segOf(Start s) => s.seg == 'ПП' || s.seg == 'ПТ' ? 'free' : 'short';

  /// Подходит ли старт под правила (без учёта общего выключателя).
  bool matches(Start s) {
    // незнакомые значения из данных не прячем: правило о них ничего не знает
    if (allKinds.contains(s.kind) && !kinds.contains(s.kind)) return false;
    if (allLevels.contains(s.level) && !levels.contains(s.level)) return false;
    if (!segs.contains(segOf(s))) return false;
    if (s.intl ? !intl : !russian) return false;
    if (!night && msk(s.t0).hour < 8) return false;
    return true;
  }

  /// Правила по умолчанию — ни одного ограничения.
  bool get isDefault =>
      kinds.length == allKinds.length &&
      levels.length == allLevels.length &&
      segs.length == allSegs.length &&
      russian &&
      intl &&
      night;

  NotifyRules copyWith({
    bool? on,
    int? lead,
    Set<String>? kinds,
    Set<String>? levels,
    Set<String>? segs,
    bool? russian,
    bool? intl,
    bool? night,
    bool? skaters,
  }) => NotifyRules(
    on: on ?? this.on,
    lead: lead ?? this.lead,
    kinds: kinds ?? this.kinds,
    levels: levels ?? this.levels,
    segs: segs ?? this.segs,
    russian: russian ?? this.russian,
    intl: intl ?? this.intl,
    night: night ?? this.night,
    skaters: skaters ?? this.skaters,
  );

  String toJson() => jsonEncode({
    'on': on,
    'lead': lead,
    'kinds': kinds.toList(),
    'levels': levels.toList(),
    'segs': segs.toList(),
    'russian': russian,
    'intl': intl,
    'night': night,
    'skaters': skaters,
  });

  static NotifyRules fromJson(String? s) {
    const d = NotifyRules();
    if (s == null || s.isEmpty) return d;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      Set<String> set(String k, Set<String> def) => j[k] is List ? Set<String>.from(j[k]) : def;
      final lead = j['lead'] is int && leads.contains(j['lead']) ? j['lead'] as int : d.lead;
      return NotifyRules(
        on: j['on'] is bool ? j['on'] : d.on,
        lead: lead,
        kinds: set('kinds', d.kinds),
        levels: set('levels', d.levels),
        segs: set('segs', d.segs),
        russian: j['russian'] is bool ? j['russian'] : d.russian,
        intl: j['intl'] is bool ? j['intl'] : d.intl,
        night: j['night'] is bool ? j['night'] : d.night,
        skaters: j['skaters'] is bool ? j['skaters'] : d.skaters,
      );
    } catch (_) {
      return d;
    }
  }
}

/// Правила плюс ручные исключения по отдельным стартам.
class NotifyPlan {
  final NotifyRules rules;
  final Set<String> forcedOn, forcedOff;
  const NotifyPlan(this.rules, this.forcedOn, this.forcedOff);

  /// Будет ли уведомление о начале старта (если время ещё не прошло).
  bool wants(Start s) {
    if (!rules.on) return false;
    if (forcedOn.contains(s.id)) return true;
    if (forcedOff.contains(s.id)) return false;
    return rules.matches(s);
  }

  /// Момент уведомления о начале старта или null — уведомления не будет.
  DateTime? at(Start s, DateTime now) {
    if (!wants(s)) return null;
    final t = s.t0.subtract(Duration(minutes: rules.lead));
    return t.isAfter(now) ? t : null;
  }
}

class Reminders {
  static final _n = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static final _done = Completer<void>();

  /// Завершается, когда init() отработал — удачно или нет.
  static Future<void> get settled => _done.future;

  static Future<void> init() async {
    try {
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
    } finally {
      if (!_done.isCompleted) _done.complete();
    }
  }

  /// Спросить разрешение у системы. Отказ — не ошибка: правила остаются.
  static Future<void> ask() async {
    if (!_ready) return;
    try {
      final a = _n.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await a?.requestNotificationsPermission();
      final i = _n.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      await i?.requestPermissions(alert: true, sound: true);
    } catch (_) {}
  }

  /// Разрешены ли уведомления в системе; null — узнать нельзя (веб, сбой).
  static Future<bool?> allowed() async {
    if (!_ready) return null;
    try {
      final a = _n.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (a != null) return await a.areNotificationsEnabled();
      final i = _n.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      if (i != null) return (await i.checkPermissions())?.isEnabled;
    } catch (_) {}
    return null;
  }

  static int _id(String s) => s.hashCode & 0x7fffffff;

  /// iPhone: уведомления ставит общий плагин; значок на иконке никогда не меняется.
  static const _iosDetails = NotificationDetails(
    iOS: DarwinNotificationDetails(presentBadge: false, presentAlert: true, presentSound: true),
  );

  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Уведомления, которые должны быть: время, заголовок, текст и конец старта — до него
  /// уведомление висит. Сюда попадают и уже показанные (старт идёт), чтобы их не убирали.
  /// Ближайшие 60 — iOS держит не больше 64 запланированных.
  static List<Planned> plan(Schedule data, NotifyPlan p, DateTime now) {
    final out = <Planned>[];
    final lead = Duration(minutes: p.rules.lead);
    for (final s in data.starts) {
      if (!p.wants(s) || !s.t1.isAfter(now)) continue;
      final at = s.t0.subtract(lead);
      final ours = s.ours.where((o) => o.time != null).map((o) => '${o.time} ${o.short}').join(', ');
      out.add(Planned(
        's:${s.id}',
        at,
        s.t1,
        '${hm(s.t0)} · ${s.segment}',
        [s.tournament, if (ours.isNotEmpty) ours, if (s.broadcast.isNotEmpty) s.broadcast.join(' / ')].join(' · '),
        s.id,
      ));
      if (!p.rules.skaters) continue;
      for (final o in s.ours) {
        final skate = s.skateAt(o);
        if (skate == null) continue;
        out.add(Planned(
          'k:${s.id}:${o.name}',
          skate.subtract(lead),
          s.t1,
          '${o.time} · ${o.name}',
          '${s.segment} · ${s.tournament}',
          s.id,
        ));
      }
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out.take(60).toList();
  }

  /// Один раз после перехода на свои уведомления: убрать то, что поставил общий плагин в 1.0.3 и раньше.
  static Future<void> _migrate() async {
    if (Prefs.alertsMigrated) return;
    try {
      await _n.cancelAll();
    } catch (_) {}
    await Prefs.setAlertsMigrated();
  }

  /// Привести уведомления в соответствие с расписанием и правилами. Уже показанные не трогаются
  /// (открытие приложения их не убирает), пока старт не кончился или его не выключили.
  static Future<void> sync(Schedule? data, NotifyPlan p) async {
    if (data == null) return;
    try {
      final now = DateTime.now();
      final list = plan(data, p, now);
      if (_android) {
        await _migrate();
        await StartyAlerts.sync([
          for (final x in list) AlertEntry(key: x.key, at: x.at, end: x.end, title: x.title, body: x.body),
        ]);
        return;
      }
      if (!_ready) return;
      // iPhone: убираем только запланированное, показанное остаётся
      await _n.cancelAllPendingNotifications();
      for (final x in list) {
        if (!x.at.isAfter(now)) continue;
        await _n.zonedSchedule(
          id: _id(x.key),
          scheduledDate: tz.TZDateTime.from(x.at, tz.UTC),
          title: x.title,
          body: x.body,
          notificationDetails: _iosDetails,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          payload: x.startId,
        );
      }
    } catch (_) {
      // без уведомлений — молча: расписание всё равно работает
    }
  }
}

class Planned {
  final String key;
  final DateTime at, end;
  final String title, body, startId;
  Planned(this.key, this.at, this.end, this.title, this.body, this.startId);
}
