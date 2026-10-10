// Общее состояние приложения: расписание, фильтр ленты, уведомления, оформление.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'data.dart';
import 'live.dart';
import 'reminders.dart';

class AppState extends ChangeNotifier {
  Schedule? data;
  bool loading = true;
  bool offline = false;

  /// Идёт ручное или фоновое обновление расписания — для строки в настройках.
  bool refreshing = false;
  Filters filters = Filters(Prefs.kinds, Prefs.tids, Prefs.athletes);

  // уведомления
  NotifyRules rules = NotifyRules.fromJson(Prefs.rulesJson);
  Set<String> forcedOn = Prefs.forcedOn;
  Set<String> forcedOff = Prefs.forcedOff;

  /// Разрешены ли уведомления в системе; null — неизвестно (веб, ещё не проверено).
  bool? allowed;

  /// Запланированные уведомления — ближайшие, как их видит система.
  List<Planned> planned = const [];

  // лента и оформление
  bool showDone = Prefs.showDone;
  ThemeMode theme = _mode(Prefs.theme);

  NotifyPlan get plan => NotifyPlan(rules, forcedOn, forcedOff);

  /// Придёт ли уведомление о начале старта (правила + исключения).
  bool notifies(Start s) => plan.wants(s);

  /// Когда придёт уведомление о начале; null — не придёт (выключено или время прошло).
  DateTime? notifyAt(Start s) => plan.at(s, now());

  /// Старт включён или выключен вручную, вопреки правилам.
  bool isException(Start s) => forcedOn.contains(s.id) || forcedOff.contains(s.id);
  int get exceptions => forcedOn.length + forcedOff.length;

  Future<void> load() async {
    if (refreshing) return;
    data ??= await Repo.cached();
    if (data != null) {
      loading = false;
      notifyListeners();
      unawaited(_sync());
    }
    refreshing = true;
    notifyListeners();
    final fresh = await Repo.fetch();
    refreshing = false;
    if (fresh != null) {
      _fetchedAt = DateTime.now();
      data = _apply(fresh);
      offline = false;
    } else {
      offline = true;
    }
    loading = false;
    _prune();
    notifyListeners();
    await _sync();
    // уведомления включены по умолчанию — разрешение спрашиваем один раз, при первом запуске
    if (rules.on && !Prefs.asked) {
      await Prefs.setAsked();
      await Reminders.ask();
    }
    await refreshPermission();
  }

  Future<void> refreshPermission() async {
    final a = await Reminders.allowed();
    if (a != allowed) {
      allowed = a;
      notifyListeners();
    }
  }

  /// Попросить разрешение ещё раз (Android 13+ и iOS показывают системный вопрос,
  /// пока его не отклонили окончательно).
  Future<void> askPermission() async {
    await Reminders.ask();
    await refreshPermission();
  }

  Future<void> setRules(NotifyRules r) async {
    final wasOff = !rules.on;
    rules = r;
    notifyListeners();
    await Prefs.setRulesJson(r.toJson());
    await _sync();
    if (r.on && wasOff) await askPermission();
  }

  /// Включить или выключить уведомление об одном старте. Совпало с правилами —
  /// исключение снимается.
  Future<void> toggleStart(Start s) async {
    if (!rules.on) return;
    final on = !plan.wants(s);
    forcedOn = {...forcedOn}..remove(s.id);
    forcedOff = {...forcedOff}..remove(s.id);
    if (on != rules.matches(s)) (on ? forcedOn : forcedOff).add(s.id);
    notifyListeners();
    await Prefs.setForced(forcedOn, forcedOff);
    await _sync();
    if (on && allowed != true) await askPermission();
  }

  Future<void> clearExceptions() async {
    forcedOn = {};
    forcedOff = {};
    notifyListeners();
    await Prefs.setForced(forcedOn, forcedOff);
    await _sync();
  }

  Future<void> setFilters(Filters f) async {
    filters = f;
    notifyListeners();
    await Prefs.setFilters(f.kinds, f.tids, f.athletes);
  }

  Future<void> setShowDone(bool v) async {
    showDone = v;
    notifyListeners();
    await Prefs.setShowDone(v);
  }

  Future<void> setTheme(ThemeMode m) async {
    theme = m;
    notifyListeners();
    await Prefs.setTheme(m.name);
  }

  static ThemeMode _mode(String s) => ThemeMode.values.firstWhere((m) => m.name == s, orElse: () => ThemeMode.system);

  /// Исключения для стартов, которых больше нет в расписании, не копим.
  void _prune() {
    final ids = {for (final s in data?.starts ?? const <Start>[]) s.id};
    if (ids.isEmpty) return;
    final on = forcedOn.where(ids.contains).toSet();
    final off = forcedOff.where(ids.contains).toSet();
    if (on.length != forcedOn.length || off.length != forcedOff.length) {
      forcedOn = on;
      forcedOff = off;
      unawaited(Prefs.setForced(on, off));
    }
  }

  // ---------------------------------------------------------------- итоги с табло

  /// Итоги, прочитанные с табло, пока сервер их не догнал: id → старт.
  final Map<String, Start> _live = {};
  Timer? _liveTimer;
  bool _polling = false;
  DateTime _fetchedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Старты, итоги которых сейчас читаются с табло: идут, вот-вот начнутся или прошли,
  /// а окончательного протокола ещё нет.
  List<Start> get watching {
    final t = now();
    return [
      for (final s in data?.starts ?? const <Start>[])
        if (s.live != null &&
            !s.settled &&
            !t.isBefore(s.t0.subtract(const Duration(minutes: 10))) &&
            t.isBefore(s.t1.add(const Duration(hours: 24))))
          s,
    ];
  }

  /// Приложение на экране: раз в минуту — табло. Свёрнуто — не опрашиваем.
  void startLive() {
    _liveTimer?.cancel();
    if (kIsWeb) return; // браузер не пустит на чужой сайт без разрешения сайта
    _liveTimer = Timer.periodic(const Duration(minutes: 1), (_) => pollLive());
    unawaited(pollLive());
  }

  void stopLive() {
    _liveTimer?.cancel();
    _liveTimer = null;
  }

  Future<void> pollLive() async {
    if (_polling || data == null) return;
    final list = watching.take(8).toList();
    if (list.isEmpty) return;
    _polling = true;
    try {
      final got = await Future.wait(list.map(Live.poll));
      var changed = false;
      for (var i = 0; i < list.length; i++) {
        final g = got[i];
        if (g == null) continue;
        if (_sig(g) != _sig(_live[g.id] ?? list[i])) changed = true;
        _live[g.id] = g;
      }
      if (changed && data != null) {
        data = _apply(data!);
        notifyListeners();
      }
      // примечательное и окончательный итог считает сервер — забираем его чаще, пока что-то идёт
      if (DateTime.now().difference(_fetchedAt) > const Duration(minutes: 5)) unawaited(load());
    } finally {
      _polling = false;
    }
  }

  static String _sig(Start s) => [
    s.provisional,
    for (final p in s.podium) '${p.place}${p.name}${p.points}',
    for (final p in s.total) '${p.place}${p.name}${p.points}',
    for (final o in s.ours) '${o.name}${o.place}${o.overall}',
  ].join('|');

  /// Наложить итоги с табло на расписание с сервера. Сервер дошёл до окончательного — его и берём.
  Schedule _apply(Schedule d) {
    if (_live.isEmpty) return d;
    _live.removeWhere((id, _) => d.byId(id)?.settled ?? true);
    if (_live.isEmpty) return d;
    return d.withStarts([
      for (final s in d.starts)
        if (_live[s.id] case final l?)
          s.withResults(
            podium: l.podium,
            provisional: l.provisional,
            places: {for (final o in l.ours) if (o.place != null) norm(o.name): o.place!},
            total: l.total.isNotEmpty ? l.total : null,
            finals: {for (final o in l.ours) if (o.overall != null) norm(o.name): o.overall!},
          )
        else
          s,
    ]);
  }

  Future<void> _sync() async {
    final d = data;
    planned = d == null ? const [] : Reminders.plan(d, plan, now());
    notifyListeners();
    // уведомления настраиваются после показа экрана — ждём, пока init() отработает
    await Reminders.settled.timeout(const Duration(seconds: 10), onTimeout: () {});
    await Reminders.sync(d, plan);
  }
}
