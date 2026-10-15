// Общее состояние приложения: расписание, фильтр ленты, уведомления, оформление.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'data.dart';
import 'live.dart';
import 'reminders.dart';
import 'sync.dart';

class AppState extends ChangeNotifier {
  /// Расписание под выбор человека (отслеживаемые) с итогами с табло.
  Schedule? data;

  /// Как пришло с сервера — от него пересчитывается [data], когда меняются отслеживаемые.
  Schedule? _raw;
  bool loading = true;
  bool offline = false;

  /// Идёт ручное или фоновое обновление расписания — для строки в настройках.
  bool refreshing = false;
  Filters filters = Filters(Prefs.kinds, Prefs.tids, Prefs.athletes, levels: Prefs.levels, scope: Prefs.scope);

  /// Отслеживаемые. Пока человек не выбирал — список сборщика (data.watchlist).
  List<String>? _follow = Prefs.follow;
  bool _followRu = Prefs.followRussians, _followBy = Prefs.followBelarusians;
  Follow get follow => Follow(_follow ?? _raw?.watchlist ?? const [], russians: _followRu, belarusians: _followBy);

  // ---------------------------------------------------------------- синхронизация между устройствами

  /// Сверка и отправка; сервер задаётся сборкой (sync.dart). Пока не подключено — ничего не делает.
  late final SyncController sync = SyncController(
    local: SyncLocal(Prefs.raw),
    capture: _captureSync,
    apply: _applySync,
    onChange: () => notifyListeners(),
  );

  /// Что человек видит в «Аккаунте»: почта, код или ничего.
  String? get syncEmail => SyncLocal(Prefs.raw).account?['email'];
  bool get syncCodeOn => SyncLocal(Prefs.raw).code != null;
  bool get syncOn => sync.backend != null;
  DateTime? get syncAt => SyncLocal(Prefs.raw).lastSyncAt;
  String? get syncProblem => sync.problem;
  String? get syncCode => SyncLocal(Prefs.raw).code;

  /// Сверить сейчас (кнопка в «Синхронизации»). Возвращает причину, если не вышло.
  Future<String?> syncNow() async {
    await sync.reconcile();
    return sync.problem;
  }

  /// Пользователь поменял настройку: отметить время, сверка — чуть позже.
  void touchSync() => unawaited(sync.touch());

  Future<void> _keepSession(AccountSession s) =>
      SyncLocal(Prefs.raw).setAccount(s.toMap());

  Future<SyncDoc> _captureSync() async {
    final icon = await AppIcons.current();
    return SyncDoc(
      updatedAt: SyncDoc.epoch,
      rules: rules.toJson(),
      forcedOn: (forcedOn.toList()..sort()),
      forcedOff: (forcedOff.toList()..sort()),
      follow: [...?_follow]..sort(),
      followRussians: _followRu,
      followBelarusians: _followBy,
      filters: {
        'kinds': (filters.kinds.toList()..sort()),
        'tids': (filters.tids.toList()..sort()),
        'athletes': (filters.athletes.toList()..sort()),
        'levels': (filters.levels.toList()..sort()),
        'scope': (filters.scope.toList()..sort()),
      },
      showDone: showDone,
      theme: theme.name,
      icon: icon,
    );
  }

  /// Пришёл документ с сервера: записать в настройки устройства и перерисовать.
  Future<void> _applySync(SyncDoc d) async {
    await Prefs.setRulesJson(d.rules.isEmpty ? rules.toJson() : d.rules);
    await Prefs.setForced(d.forcedOn.toSet(), d.forcedOff.toSet());
    await Prefs.setFollow(
      d.follow,
      russians: d.followRussians,
      belarusians: d.followBelarusians,
    );
    final f = d.filters;
    await Prefs.setFilters(
      Filters(
        (f['kinds'] ?? const []).toSet(),
        (f['tids'] ?? const []).toSet(),
        (f['athletes'] ?? const []).toSet(),
        levels: (f['levels'] ?? const []).toSet(),
        scope: (f['scope'] ?? const []).toSet(),
      ),
    );
    await Prefs.setShowDone(d.showDone);
    await Prefs.setTheme(d.theme);
    if (d.icon != (await AppIcons.current())) {
      await AppIcons.set(d.icon);
    }
    _reloadFromPrefs();
  }

  /// Перечитать настройки из preferences (после сверки с сервером).
  void _reloadFromPrefs() {
    rules = NotifyRules.fromJson(Prefs.rulesJson);
    forcedOn = Prefs.forcedOn;
    forcedOff = Prefs.forcedOff;
    filters = Filters(
      Prefs.kinds,
      Prefs.tids,
      Prefs.athletes,
      levels: Prefs.levels,
      scope: Prefs.scope,
    );
    _follow = Prefs.follow;
    _followRu = Prefs.followRussians;
    _followBy = Prefs.followBelarusians;
    showDone = Prefs.showDone;
    theme = _mode(Prefs.theme);
    if (_raw != null) data = _apply(_raw!);
    notifyListeners();
    unawaited(_sync());
  }

  /// Подключить сохранённый вход или код (после запуска). Уже подключённое не трогаем.
  void _restoreSync() {
    if (sync.backend != null || !syncConfigured) return;
    final local = SyncLocal(Prefs.raw);
    final acc = AccountSession.fromMap(local.account);
    final code = local.code;
    if (acc != null) {
      sync.backend = AccountBackend(
        url: syncUrl,
        key: syncKey,
        session: acc,
        keep: _keepSession,
      );
    } else if (code != null) {
      sync.backend = CodeBackend(url: syncUrl, key: syncKey, code: code);
    }
  }

  /// Вход или регистрация по почте. Возвращает текст ошибки или null.
  Future<String?> signInSync(
    String email,
    String password, {
    bool create = false,
  }) async {
    if (!syncConfigured) return 'Сервер не подключён в этой сборке';
    final b = AccountBackend(url: syncUrl, key: syncKey, keep: _keepSession);
    try {
      final s = create
          ? await b.signUp(email, password)
          : await b.signIn(email, password);
      await SyncLocal(Prefs.raw).setCode(null);
      await _keepSession(s);
      await sync.preferRemote();
      sync.backend = b;
      notifyListeners();
      await sync.reconcile();
      return null;
    } on SyncError catch (e) {
      return e.message;
    }
  }

  /// Выйти из аккаунта: на этом устройстве настройки остаются, на сервере — тоже.
  Future<void> signOutSync() async {
    await SyncLocal(Prefs.raw).setAccount(null);
    sync.backend = null;
    notifyListeners();
  }

  /// Создать код синхронизации: настройки этого устройства уходят на сервер под ним.
  Future<String?> createSyncCode() async {
    if (!syncConfigured) return 'Сервер не подключён в этой сборке';
    final code = CodeBackend.newCode();
    return _useCode(code, create: true);
  }

  /// Ввести код с другого устройства: настройки берутся с сервера.
  Future<String?> enterSyncCode(String input) async {
    if (!syncConfigured) return 'Сервер не подключён в этой сборке';
    final code = CodeBackend.normalize(input);
    if (code.length != 16) return 'Код — 16 знаков';
    return _useCode(code, create: false);
  }

  Future<String?> _useCode(String code, {required bool create}) async {
    final b = CodeBackend(url: syncUrl, key: syncKey, code: code);
    try {
      if (!create && await b.load() == null) {
        return 'Такого кода нет на сервере';
      }
      await SyncLocal(Prefs.raw).setAccount(null);
      await SyncLocal(Prefs.raw).setCode(code);
      // чужой код — значит, настройки уже есть на сервере: берём их, свои прошлые правки не шлём
      if (!create) await sync.preferRemote();
      sync.backend = b;
      notifyListeners();
      await sync.reconcile();
      return null;
    } on SyncError catch (e) {
      return e.message;
    }
  }

  /// Отключить синхронизацию на этом устройстве (код и вход забываются, настройки остаются).
  Future<void> disconnectSync() async {
    await SyncLocal(Prefs.raw).setAccount(null);
    await SyncLocal(Prefs.raw).setCode(null);
    sync.backend = null;
    notifyListeners();
  }

  Future<void> setFollow(Set<String> v, {required bool russians, required bool belarusians}) async {
    _follow = v.toList()..sort();
    _followRu = russians;
    _followBy = belarusians;
    if (_raw != null) data = _apply(_raw!);
    notifyListeners();
    await Prefs.setFollow(_follow!, russians: russians, belarusians: belarusians);
    touchSync();
    await _sync();
  }

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
    _restoreSync();
    if (refreshing) return;
    if (data == null) {
      _raw = await Repo.cached();
      if (_raw != null) data = _apply(_raw!);
    }
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
      _raw = fresh;
      data = _apply(fresh);
      offline = false;
    } else {
      offline = true;
    }
    loading = false;
    _prune();
    notifyListeners();
    await _sync();
    // сверка с сервером — при каждом запуске и возврате в приложение (load() вызывается и там)
    unawaited(sync.reconcile());
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
    touchSync();
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
    touchSync();
    await _sync();
    if (on && allowed != true) await askPermission();
  }

  Future<void> clearExceptions() async {
    forcedOn = {};
    forcedOff = {};
    notifyListeners();
    await Prefs.setForced(forcedOn, forcedOff);
    touchSync();
    await _sync();
  }

  Future<void> setFilters(Filters f) async {
    filters = f;
    notifyListeners();
    await Prefs.setFilters(f);
    touchSync();
  }

  Future<void> setShowDone(bool v) async {
    showDone = v;
    notifyListeners();
    await Prefs.setShowDone(v);
    touchSync();
  }

  Future<void> setTheme(ThemeMode m) async {
    theme = m;
    notifyListeners();
    await Prefs.setTheme(m.name);
    touchSync();
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
            (s.shown || filters.pass(s)) &&
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
      if (changed && _raw != null) {
        data = _apply(_raw!);
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

  /// Расписание с сервера → под отслеживаемых и с итогами с табло. Сервер дошёл до окончательного — его и берём.
  Schedule _apply(Schedule raw) {
    final d = raw.withFollow(follow);
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
