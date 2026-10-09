// Общее состояние приложения: расписание, фильтр ленты, уведомления, оформление.
import 'dart:async';

import 'package:flutter/material.dart';

import 'data.dart';
import 'reminders.dart';

class AppState extends ChangeNotifier {
  Schedule? data;
  bool loading = true;
  bool offline = false;
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
    data ??= await Repo.cached();
    if (data != null) {
      loading = false;
      notifyListeners();
      unawaited(_sync());
    }
    final fresh = await Repo.fetch();
    if (fresh != null) {
      data = fresh;
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

  Future<void> _sync() async {
    final d = data;
    planned = d == null ? const [] : Reminders.plan(d, plan, now());
    notifyListeners();
    // уведомления настраиваются после показа экрана — ждём, пока init() отработает
    await Reminders.settled.timeout(const Duration(seconds: 10), onTimeout: () {});
    await Reminders.sync(d, plan);
  }
}
