// Уведомления о стартах. По умолчанию — о каждом старте, за 15 минут до начала;
// какие старты и за сколько — решают правила из настроек, отдельный старт можно
// включить или выключить вручную. Ставятся в системный планировщик — срабатывают
// и при закрытом приложении.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:starty_alerts/starty_alerts.dart';

import 'data.dart';
import 'palette.dart';
import 'platform.dart';
import 'ui.dart' show cap, displayName, nb, segNames;

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
  final bool onlyFollowed; // только старты, где выступают отслеживаемые
  final int gone; // через сколько минут после выхода убрать уведомление о спортсмене
  final int skaterLead; // за сколько минут до выхода спортсмена
  // Android: закреплять (не смахиваются) — старт до конца, спортсмен — пока не откатал
  final bool pin;
  // Android: уведомление о выходе спортсмена убирается само вскоре после его проката
  final bool clear;

  static const allKinds = ['women', 'men', 'pairs', 'dance'];
  static const allLevels = ['senior', 'junior'];
  static const allSegs = ['short', 'free'];
  static const leads = [5, 10, 15, 30, 60];
  static const gones = [5, 10, 15, 30];

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
    this.onlyFollowed = false,
    this.gone = 15,
    this.skaterLead = 15,
    this.pin = true,
    this.clear = true,
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
    // ours — уже отслеживаемые (россияне и белорусы на международных — если их отслеживают).
    // Состав ещё не опубликован — убрать нельзя: вдруг там как раз отслеживаемые.
    if (onlyFollowed && s.ours.isEmpty && s.compositionKnown) return false;
    // международный старт, где нет никого из отслеживаемых, — не о чем напоминать
    if (!s.shown) return false;
    return true;
  }

  /// Правила по умолчанию — ни одного ограничения.
  bool get isDefault =>
      kinds.length == allKinds.length &&
      levels.length == allLevels.length &&
      segs.length == allSegs.length &&
      russian &&
      intl &&
      night &&
      !onlyFollowed;

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
    bool? onlyFollowed,
    int? gone,
    int? skaterLead,
    bool? pin,
    bool? clear,
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
    onlyFollowed: onlyFollowed ?? this.onlyFollowed,
    gone: gone ?? this.gone,
    skaterLead: skaterLead ?? this.skaterLead,
    pin: pin ?? this.pin,
    clear: clear ?? this.clear,
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
    'onlyFollowed': onlyFollowed,
    'gone': gone,
    'skaterLead': skaterLead,
    'pin': pin,
    'clear': clear,
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
        onlyFollowed: j['onlyFollowed'] is bool ? j['onlyFollowed'] : d.onlyFollowed,
        gone: j['gone'] is int && gones.contains(j['gone']) ? j['gone'] as int : d.gone,
        // раньше выход спортсмена шёл за то же время, что и начало старта
        skaterLead: j['skaterLead'] is int && leads.contains(j['skaterLead']) ? j['skaterLead'] as int : lead,
        pin: j['pin'] is bool ? j['pin'] : d.pin,
        clear: j['clear'] is bool ? j['clear'] : d.clear,
      );
    } catch (_) {
      return d;
    }
  }

  /// Правила из документа поверх местных ([local] — строка toJson). Поле, которого в строке нет,
  /// которое другого вида или вне допустимых значений, остаётся местным. Строка, которую не разобрать,
  /// не применяется вовсе. Так испорченный документ не включает уведомления, которые человек выключил.
  static String mergeJson(String local, String remote) {
    final base = Map<String, dynamic>.from(jsonDecode(local) as Map);
    final Map<String, dynamic> got;
    try {
      final j = jsonDecode(remote);
      if (j is! Map) return local;
      got = Map<String, dynamic>.from(j);
    } catch (_) {
      return local;
    }
    for (final k in base.keys) {
      final v = got[k];
      if (v != null && _fits(k, base[k], v)) base[k] = v;
    }
    return jsonEncode(base);
  }

  static bool _fits(String key, Object? local, Object v) {
    final sameKind = (local is bool && v is bool) || (local is int && v is int) || (local is List && v is List);
    if (!sameKind) return false;
    if (v is! int) return true;
    return key == 'gone' ? gones.contains(v) : leads.contains(v);
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

  static const _darwin = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );

  static Future<void> init() async {
    try {
      if (kIsWeb || _ready) return;
      tzdata.initializeTimeZones();
      await _n.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_notify'),
          iOS: _darwin,
          macOS: _darwin,
          windows: WindowsInitializationSettings(
            appName: 'Фигурное катание',
            appUserModelId: 'ru.furya.starty',
            guid: '6f1c2f4e-5b0d-4c6e-9a53-3c1d8a7e2b91',
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
      final m = _n.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
      await m?.requestPermissions(alert: true, sound: true);
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
      final m = _n.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
      if (m != null) return (await m.checkPermissions())?.isEnabled;
    } catch (_) {}
    return null;
  }

  static int _id(String s) => s.hashCode & 0x7fffffff;

  /// iPhone и Mac: уведомления ставит общий плагин; значок на иконке никогда не меняется.
  /// Подзаголовок — турнир, уведомления одного турнира — в одной стопке (threadIdentifier).
  static NotificationDetails _darwinDetails(Planned x) {
    final d = DarwinNotificationDetails(
      presentBadge: false,
      presentAlert: true,
      presentSound: true,
      subtitle: x.subtitle.isEmpty ? null : x.subtitle,
      threadIdentifier: x.group,
    );
    return NotificationDetails(iOS: d, macOS: d);
  }

  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Сколько после времени выхода спортсмен заведомо откатал: программа до 4 мин и оценки.
  static const skated = Duration(minutes: 8);


  /// «юниорские танцы РТ» → («юниорские танцы», «ритм-танец»), как в карточке старта.
  /// Незнакомое окончание — всё название как вид, без программы.
  static (String, String) discipline(Start s) {
    final w = s.segment.trim().split(RegExp(r'\s+'));
    if (w.length > 1 && segNames.containsKey(w.last)) return (w.sublist(0, w.length - 1).join(' '), segNames[w.last]!);
    return (s.segment.trim(), '');
  }

  /// Имя в уведомлении: у пар — фамилии, без капса из протоколов.
  static String _name(Skater o) => displayName(o.short);

  /// Статус идущего старта — как метка на его карточке: красная точка и «ИДЁТ» (неразрывно).
  /// Точка — эмодзи: цвет текста заголовка система вправе снять, а красный круг рисует сама.
  static const liveMark = '🔴$nbИДЁТ';

  /// Уведомление о начале старта.
  ///  заголовок — «17:45 — Танцы, ритм-танец»; когда старт начался — «🔴 ИДЁТ — Танцы, ритм-танец» ([live]);
  ///    время или статус первыми: в свёрнутом виде длинное название обрежет конец, а не их;
  ///  строки — турнир, затем по строке на отслеживаемого: «19:04 — Кузьмина / Студеникин»;
  ///  свёрнутый вид Android — «Кузьмина / Студеникин в 19:04 и ещё 1» (никого — турнир).
  /// [own] — спортсмены со своим уведомлением о выходе: здесь их не повторяем, чтобы одно и то же
  /// не приходило дважды.
  static ({String title, String live, List<String> lines, String collapsed}) startText(Start s, {Set<String> own = const {}}) {
    final (disc, seg) = discipline(s);
    final what = seg.isEmpty ? cap(disc) : '${cap(disc)}, $seg';
    final ours = [for (final o in s.ours) if (!own.contains(o.name)) o];
    String one(Skater o) => o.time == null ? _name(o) : '${_name(o)} в ${o.time}';
    final collapsed = ours.isEmpty
        ? s.tournament
        : ours.length == 1
        ? one(ours.first)
        : '${one(ours.first)} и ещё ${ours.length - 1}';
    return (
      title: '${hm(s.t0)} — $what',
      live: '$liveMark — $what',
      lines: [s.tournament, for (final o in ours) o.time == null ? _name(o) : '${o.time} — ${_name(o)}'],
      collapsed: collapsed,
    );
  }

  /// Уведомление о выходе спортсмена: «В 19:04 выходят Кузьмина / Студеникин» (время первым — длинное имя не обрежет его),
  /// строка — «CS Budapest Trophy, танцы, ритм-танец».
  static ({String title, List<String> lines, String collapsed}) skaterText(Start s, Skater o) {
    final (disc, seg) = discipline(s);
    final line = [s.tournament, disc, if (seg.isNotEmpty) seg].join(', ');
    return (
      title: 'В ${o.time} ${o.name.contains(' / ') ? 'выходят' : 'выходит'} ${_name(o)}',
      lines: [line],
      collapsed: line,
    );
  }

  /// Уведомления, которые должны быть: время, тексты, до какого момента закреплено
  /// и когда убрать. Сюда попадают и уже показанные (старт идёт), чтобы их не убирали.
  /// Ближайшие 60 — iOS держит не больше 64 запланированных.
  static List<Planned> plan(Schedule data, NotifyPlan p, DateTime now) {
    final out = <Planned>[];
    final lead = Duration(minutes: p.rules.lead);
    for (final s in data.starts) {
      if (!p.wants(s) || !s.t1.isAfter(now)) continue;
      final at = s.t0.subtract(lead);
      // у кого время выхода известно, тот приходит отдельным уведомлением — в уведомлении о старте его нет
      final own = p.rules.skaters ? {for (final o in s.ours) if (s.skateAt(o) != null) o.name} : const <String>{};
      final t = startText(s, own: own);
      out.add(Planned(
        key: 's:${s.id}',
        at: at,
        hold: p.rules.pin ? s.t1 : at,
        end: s.t1,
        title: t.title,
        liveAt: s.t0,
        liveTitle: t.live,
        lines: t.lines,
        collapsed: t.collapsed,
        startId: s.id,
        group: s.tid,
        groupTitle: s.tournament,
        reminder: false,
      ));
      if (!p.rules.skaters) continue;
      for (final o in s.ours) {
        final skate = s.skateAt(o);
        if (skate == null) continue;
        final at = skate.subtract(Duration(minutes: p.rules.skaterLead));
        // место в протоколе — уже откатал, раньше расчётного; закрепление снимается сразу
        final done = o.place != null ? now : skate.add(skated);
        var end = p.rules.clear ? skate.add(Duration(minutes: p.rules.gone)) : s.t1;
        if (end.isAfter(s.t1)) end = s.t1;
        if (!end.isAfter(now)) continue;
        final t = skaterText(s, o);
        out.add(Planned(
          key: 'k:${s.id}:${o.name}',
          at: at,
          hold: !p.rules.pin ? at : (done.isBefore(end) ? done : end),
          end: end,
          title: t.title,
          lines: t.lines,
          collapsed: t.collapsed,
          startId: s.id,
          group: s.tid,
          groupTitle: s.tournament,
          reminder: true,
        ));
      }
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out.take(60).toList();
  }

  /// Windows: тосты ставит сама система (работают и при закрытом приложении), но отменить
  /// поставленное без пакета MSIX нельзя. Поэтому помним, что уже поставлено, и ставим только новое
  /// или изменившееся — повторное открытие приложения не плодит дубликаты.
  static Future<void> _syncWindows(List<Planned> list, DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> have;
    try {
      have = Map<String, dynamic>.from(jsonDecode(prefs.getString('w.sched') ?? '{}') as Map);
    } catch (_) {
      have = {};
    }
    final next = <String, dynamic>{};
    for (final x in list) {
      if (!x.at.isAfter(now)) continue;
      final sig = '${x.at.millisecondsSinceEpoch}|${x.title}|${x.text}';
      next[x.key] = sig;
      if (have[x.key] == sig) continue;
      await _n.zonedSchedule(
        id: _id(x.key),
        scheduledDate: tz.TZDateTime.from(x.at, tz.UTC),
        title: x.title,
        body: x.text,
        // в центре уведомлений тосты одного турнира — под общей шапкой с его названием
        notificationDetails: NotificationDetails(
          windows: WindowsNotificationDetails(
            header: WindowsHeader(id: x.group, title: x.groupTitle, arguments: x.startId),
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: x.startId,
      );
    }
    // выключенное или сдвинутое: пробуем снять, получится не везде
    for (final k in have.keys) {
      if (next.containsKey(k)) continue;
      try {
        await _n.cancel(id: _id(k));
      } catch (_) {}
    }
    await prefs.setString('w.sched', jsonEncode(next));
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
          for (final x in list)
            AlertEntry(
              key: x.key,
              at: x.at,
              hold: x.hold,
              end: x.end,
              title: x.title,
              body: x.collapsed,
              lines: x.lines,
              group: x.group,
              groupTitle: x.groupTitle,
              reminder: x.reminder,
              // в начало старта висящее меняет время на статус само, и при закрытом приложении
              liveAt: x.liveAt,
              liveTitle: x.liveTitle,
              liveMark: liveMark,
              liveColor: Palette.light.live.toARGB32(),
              liveColorDark: Palette.dark.live.toARGB32(),
            ),
        ]);
        return;
      }
      if (!_ready) return;
      if (isWindows) {
        await _syncWindows(list, now);
        return;
      }
      // iPhone и Mac: убираем только запланированное, показанное остаётся
      await _n.cancelAllPendingNotifications();
      for (final x in list) {
        if (!x.at.isAfter(now)) continue;
        await _n.zonedSchedule(
          id: _id(x.key),
          scheduledDate: tz.TZDateTime.from(x.at, tz.UTC),
          title: x.title,
          body: x.body,
          notificationDetails: _darwinDetails(x),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          payload: x.startId,
        );
      }
    } catch (_) {
      // без уведомлений — молча: расписание всё равно работает
    }
  }
}

/// Одно уведомление. Главное — в заголовке; дальше по мысли на строку, без склеек через «·».
class Planned {
  final String key;
  final DateTime at, hold, end;
  final String title;

  /// Начало старта: с этого момента висящее уведомление — с [liveTitle] вместо [title].
  final DateTime? liveAt;

  /// Заголовок, пока старт идёт: статус вместо времени начала. Пусто — заголовок не меняется.
  final String liveTitle;

  /// Строки развёрнутого вида: у старта первая — турнир, дальше отслеживаемые; у спортсмена одна.
  final List<String> lines;

  /// Android, свёрнутый вид: одна строка под заголовком.
  final String collapsed;
  final String startId;

  /// Турнир: уведомления одного турнира складываются вместе.
  final String group, groupTitle;

  /// Выход спортсмена — напоминание; начало старта — событие.
  final bool reminder;

  const Planned({
    required this.key,
    required this.at,
    required this.hold,
    required this.end,
    required this.title,
    required this.lines,
    required this.collapsed,
    required this.startId,
    required this.group,
    required this.groupTitle,
    required this.reminder,
    this.liveAt,
    this.liveTitle = '',
  });

  /// Заголовок на момент [t]: старт уже идёт — со статусом, иначе — с временем начала.
  String titleAt(DateTime t) => liveAt != null && liveTitle.isNotEmpty && !t.isBefore(liveAt!) ? liveTitle : title;

  /// iPhone и Mac: подзаголовок — турнир, если ниже есть что-то ещё.
  String get subtitle => lines.length > 1 ? lines.first : '';

  /// iPhone и Mac: текст построчно (под подзаголовком).
  String get body => (lines.length > 1 ? lines.skip(1) : lines).join('\n');

  /// Windows: заголовок и строки — все, турнир первой.
  String get text => lines.join('\n');
}
