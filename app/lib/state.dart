// Общее состояние приложения: расписание, фильтр ленты, уведомления, оформление.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, mapEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_icon.dart';
import 'data.dart';
import 'live.dart';
import 'protocol_repo.dart';
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

  /// Сохранить обновлённый вход. Только если [b] всё ещё текущее подключение: после выхода или смены
  /// аккаунта запоздалое обновление токена не должно вернуть старую сессию.
  Future<void> _keepSession(AccountBackend b, AccountSession s) async {
    if (!identical(sync.backend, b)) return;
    await SyncLocal(Prefs.raw).setAccount(s.toMap());
  }

  /// Для тестов: подмена http-клиента сервера (в тестовой сборке адрес сервера не задан).
  @visibleForTesting
  http.Client? syncClient;
  bool get _syncReady => syncConfigured || syncClient != null;
  String get _url => syncConfigured ? syncUrl : 'https://sync.test';
  String get _key => syncConfigured ? syncKey : 'test';

  AccountBackend _accountBackend({AccountSession? session}) {
    late final AccountBackend b;
    b = AccountBackend(
      url: _url,
      key: _key,
      client: syncClient,
      session: session,
      keep: (s) => _keepSession(b, s),
    );
    return b;
  }

  /// Всё, что человек меняет, — в документ (см. SyncDoc). Служебное состояние устройства сюда не входит.
  Future<SyncDoc> _captureSync() async {
    final icon = await _iconForSync();
    return SyncDoc(
      updatedAt: SyncDoc.epoch,
      rules: rules.toJson(),
      forcedOn: (forcedOn.toList()..sort()),
      forcedOff: (forcedOff.toList()..sort()),
      // null — «по умолчанию» сохраняем как null, а не как пустой список
      follow: _follow == null ? null : ([..._follow!]..sort()),
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
      regional: regional,
      liveMode: liveMode,
      liveOverrides: liveOverrides,
    );
  }

  /// Пришёл документ с сервера: записать в настройки устройства и перерисовать. Поле, которого в документе
  /// нет или которое испорчено (SyncDoc.absent), не трогаем: остаётся настройка устройства.
  /// Все записи в Prefs стартуют подряд, без ожидания между ними (кэш обновляется сразу, на диск — потом):
  /// правка человека, пришедшая в любой момент применения, ложится поверх целиком серверного состояния.
  /// Значок идёт последним и может ждать систему.
  Future<void> _applySync(SyncDoc d) async {
    bool has(String k) => !d.absent.contains(k);
    Set<String> pick(String k, Set<String> local) => has('filters.$k') ? d.filters[k]!.toSet() : local;
    final writes = <Future<void>>[
      if (has('rules')) Prefs.setRulesJson(NotifyRules.mergeJson(rules.toJson(), d.rules)),
      Prefs.setForced(
        has('forcedOn') ? d.forcedOn.toSet() : Prefs.forcedOn,
        has('forcedOff') ? d.forcedOff.toSet() : Prefs.forcedOff,
      ),
      Prefs.setFollow(
        has('follow') ? d.follow : Prefs.follow,
        russians: has('followRussians') ? d.followRussians : Prefs.followRussians,
        belarusians: has('followBelarusians') ? d.followBelarusians : Prefs.followBelarusians,
      ),
      Prefs.setFilters(
        Filters(
          pick('kinds', Prefs.kinds),
          pick('tids', Prefs.tids),
          pick('athletes', Prefs.athletes),
          levels: pick('levels', Prefs.levels),
          scope: pick('scope', Prefs.scope),
        ),
      ),
      if (has('showDone')) Prefs.setShowDone(d.showDone),
      if (has('regional')) Prefs.setRegional(d.regional),
      if (has('liveMode')) Prefs.setLiveMode(d.liveMode),
      if (has('liveOverrides')) Prefs.setLiveOverrides(d.liveOverrides),
      if (has('theme')) Prefs.setTheme(d.theme),
    ];
    await Future.wait(writes);
    if (has('icon')) await _applyIcon(d.icon);
    _reloadFromPrefs();
  }

  /// Значок из документа. Датированного значка здесь нет (iPhone) — не пробуем снова на каждой сверке.
  Future<void> _applyIcon(String id) async {
    final here = (await AppIcons.available()).any((v) => v.id == id);
    if (here && id != await AppIcons.current()) {
      await AppIcons.set(id);
    }
    await SyncLocal(Prefs.raw).setIconSeen(doc: id, device: await AppIcons.current());
  }

  /// Значок в документ. Если человек его здесь не менял, документ сохраняет свой (см. iconToSync):
  /// не затирает ни датированный значок с другого устройства, ни значок, который система здесь не поставила.
  Future<String> _iconForSync() async {
    final sl = SyncLocal(Prefs.raw);
    final device = await AppIcons.current();
    final icon = iconToSync(device: device, docIcon: sl.iconDoc, lastDevice: sl.iconDev);
    await sl.setIconSeen(doc: icon, device: device);
    return icon;
  }

  /// Перечитать настройки из preferences (после сверки с сервером).
  void _reloadFromPrefs() {
    // режим живых мест сменили на другом устройстве: прошлые итоги могли прийти из другого источника
    final liveChanged = liveMode != Prefs.liveMode || !mapEquals(liveOverrides, Prefs.liveOverrides);
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
    regional = Prefs.regional;
    liveMode = Prefs.liveMode;
    liveOverrides = Prefs.liveOverrides;
    theme = _mode(Prefs.theme);
    if (_raw != null) data = _apply(_raw!);
    if (liveChanged) _resetLiveSource();
    notifyListeners();
    unawaited(_sync());
  }

  /// Подключить сохранённый вход или код (после запуска). Уже подключённое не трогаем.
  void _restoreSync() {
    if (sync.backend != null || !_syncReady) return;
    final local = SyncLocal(Prefs.raw);
    final acc = AccountSession.fromMap(local.account);
    final code = local.code;
    if (acc != null) {
      sync.backend = _accountBackend(session: acc);
    } else if (code != null) {
      sync.backend = CodeBackend(url: _url, key: _key, code: code, client: syncClient);
    }
  }

  /// Вход или регистрация по почте. Возвращает текст ошибки или null.
  Future<String?> signInSync(
    String email,
    String password, {
    bool create = false,
  }) async {
    if (!_syncReady) return 'Аккаунты в этой сборке недоступны';
    final b = _accountBackend();
    try {
      final s = create
          ? await b.signUp(email, password)
          : await b.signIn(email, password);
      // сначала новый вход и сброс сверки, потом сохранение: прерванный вход не оставит
      // правки или базу прежнего состояния под новым аккаунтом
      // тот же аккаунт (та же почта), что уже подключён: несохранённые правки остаются и уйдут на сервер
      final prev = SyncLocal(Prefs.raw).account?['email'];
      final same = prev != null && prev.trim().toLowerCase() == s.email.trim().toLowerCase();
      sync.backend = b;
      if (!same) await sync.preferRemote();
      await SyncLocal(Prefs.raw).setCode(null);
      await _keepSession(b, s);
      notifyListeners();
      await sync.reconcile();
      return null;
    } on SyncError catch (e) {
      return e.message;
    }
  }

  /// Выйти из аккаунта: настройки на этом устройстве сбрасываются к значениям по умолчанию, на сервере и на
  /// других устройствах — не меняются. Бэкенд отключаем раньше сброса: сброс не должен уйти на сервер.
  Future<void> signOutSync() async {
    await SyncLocal(Prefs.raw).setAccount(null);
    if (sync.backend case final AccountBackend a) a.signOut();
    sync.backend = null;
    await _resetDevice();
  }

  /// Сброс настроек этого устройства к значениям по умолчанию (после отключения синхронизации).
  Future<void> _resetDevice() async {
    await Prefs.resetSynced();
    try {
      if (await AppIcons.current() != 'classic') await AppIcons.set('classic');
    } catch (_) {
      // система не дала поставить значок: остальное всё равно сброшено
    }
    _reloadFromPrefs();
    _resetLiveSource();
    notifyListeners();
  }

  /// Создать код синхронизации: настройки этого устройства уходят на сервер под ним.
  Future<String?> createSyncCode() async {
    if (!_syncReady) return 'Аккаунты в этой сборке недоступны';
    final code = CodeBackend.newCode();
    return _useCode(code, create: true);
  }

  /// Ввести код с другого устройства: настройки берутся с сервера.
  Future<String?> enterSyncCode(String input) async {
    if (!_syncReady) return 'Аккаунты в этой сборке недоступны';
    final code = CodeBackend.normalize(input);
    if (code.length != 16) return 'Код — 16 знаков';
    return _useCode(code, create: false);
  }

  Future<String?> _useCode(String code, {required bool create}) async {
    final b = CodeBackend(url: _url, key: _key, code: code, client: syncClient);
    try {
      if (!create && await b.load() == null) {
        return 'Такого кода нет на сервере';
      }
      // чужой код — значит, настройки уже есть на сервере: берём их, свои прошлые правки не шлём.
      // Сброс сверки — раньше сохранения кода (см. signInSync)
      final same = SyncLocal(Prefs.raw).code == code;
      sync.backend = b;
      if (!create && !same) await sync.preferRemote();
      await SyncLocal(Prefs.raw).setAccount(null);
      await SyncLocal(Prefs.raw).setCode(code);
      notifyListeners();
      await sync.reconcile();
      return null;
    } on SyncError catch (e) {
      return e.message;
    }
  }

  /// Отключить синхронизацию на этом устройстве: код и вход забываются, настройки сбрасываются к умолчанию.
  /// Бэкенд отключаем раньше сброса, как в [signOutSync]: сброс на сервер не уходит.
  Future<void> disconnectSync() async {
    await SyncLocal(Prefs.raw).setAccount(null);
    await SyncLocal(Prefs.raw).setCode(null);
    if (sync.backend case final AccountBackend a) a.signOut();
    sync.backend = null;
    await _resetDevice();
  }

  /// Выбор совпал со списком сборщика — сохраняем «по умолчанию» (null), чтобы его обновления дошли сюда.
  Future<void> setFollow(Set<String> v, {required bool russians, required bool belarusians}) async {
    // список сборщика не загружен и не выбирали: показано пусто, и выбор «как было» — это «по умолчанию»,
    // а не явный пустой выбор «никого» (его потом не отменить обновлением списка)
    _follow = followToStore(v, _raw?.watchlist ?? (_follow == null ? const <String>[] : null));
    _followRu = russians;
    _followBy = belarusians;
    if (_raw != null) data = _apply(_raw!);
    notifyListeners();
    await Prefs.setFollow(_follow, russians: russians, belarusians: belarusians);
    touchSync();
    await _sync();
  }

  /// Только для тестов: расписание, как после загрузки (без сети), с отслеживаемыми по умолчанию.
  @visibleForTesting
  void adoptSchedule(Schedule raw) {
    _raw = raw;
    data = _apply(raw);
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

  /// Старты региональных федераций: по умолчанию не показываются.
  bool regional = Prefs.regional;

  /// Живые места: общий режим (instant — табло раз в минуту, delayed — файл протокола) и переопределения.
  String liveMode = Prefs.liveMode;
  Map<String, String> liveOverrides = Prefs.liveOverrides;

  /// Действующий режим старта: своё переопределение или общий.
  String liveModeOf(Start s) => effectiveLiveMode(liveMode, liveOverrides, s.id);

  /// Регионы, у которых есть старты в расписании — видно и при выключенном показе.
  List<String> get regionNames => {
    for (final s in _raw?.starts ?? const <Start>[]) if (s.regional && s.region.isNotEmpty) s.region,
  }.toList()..sort();

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
    prune();
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

  /// Общий режим живых мест. Смена режима сбрасывает прошлые итоги: они могли прийти из другого источника.
  Future<void> setLiveMode(String v) async {
    liveMode = validLiveMode(v) ?? liveInstant;
    await Prefs.setLiveMode(liveMode);
    _resetLiveSource();
    touchSync();
  }

  /// Режим одного старта: null — как в настройках.
  Future<void> setLiveOverride(String startId, String? mode) async {
    final next = {...liveOverrides};
    final m = validLiveMode(mode);
    if (m == null) {
      next.remove(startId);
    } else {
      next[startId] = m;
    }
    liveOverrides = next;
    await Prefs.setLiveOverrides(next);
    _resetLiveSource();
    touchSync();
  }

  /// Итоги, прочитанные из другого источника, не должны остаться поверх нового режима.
  void _resetLiveSource() {
    _live.clear();
    _fileAt.clear();
    if (_raw != null) data = _apply(_raw!);
    notifyListeners();
    unawaited(pollLive());
  }

  Future<void> setRegional(bool v) async {
    regional = v;
    if (_raw != null) data = _apply(_raw!);
    notifyListeners();
    await Prefs.setRegional(v);
    touchSync();
    await _sync();
  }

  Future<void> setTheme(ThemeMode m) async {
    theme = m;
    notifyListeners();
    await Prefs.setTheme(m.name);
    touchSync();
  }

  static ThemeMode _mode(String s) => ThemeMode.values.firstWhere((m) => m.name == s, orElse: () => ThemeMode.system);

  /// Исключения для стартов, которых больше нет в расписании, не копим. Сверяем с полным расписанием,
  /// а не с показанным: региональные старты при выключенных федерациях не пропали, и их исключения живут.
  void prune() {
    final ids = {for (final s in _raw?.starts ?? const <Start>[]) s.id};
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

  /// Итоги, прочитанные с табло или из файла протокола, пока сервер их не догнал: id → итог.
  final Map<String, LiveOk> _live = {};

  /// Когда в последний раз читали файл протокола для старта (режим «с опозданием» — не чаще раза в 5 минут).
  final Map<String, DateTime> _fileAt = {};
  static const _fileEvery = Duration(minutes: 5);
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
            // без basis окончательность на табло не определить: опрос идёт недолго после конца,
            // дальше — итог сервера (иначе батарея тратится сутки после каждого старта)
            t.isBefore(s.t1.add(s.live!.basis == null ? const Duration(hours: 2) : const Duration(hours: 24))))
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
      // «моментально» — табло раз в минуту; «с опозданием» — табло не трогаем, файл протокола раз в 5 минут
      final table = [for (final s in list) if (liveModeOf(s) == liveInstant) s];
      final now = DateTime.now();
      final file = [
        for (final s in list)
          if (liveModeOf(s) == liveDelayed && s.proto != null && now.difference(_fileAt[s.id] ?? _epoch) >= _fileEvery) s,
      ];
      final gotTable = await Future.wait(table.map(Live.poll));
      final gotFile = await Future.wait(file.map(_fromFile));
      for (final s in file) {
        _fileAt[s.id] = now;
      }
      var changed = false;
      void take(Start s, LiveResult g) {
        // сеть, пустое табло или чужая страница — прошлые итоги остаются как были
        if (g is! LiveOk) return;
        final prev = _live[s.id];
        // окончательный протокол не понижаем до промежуточного из-за неполного опроса
        if (prev != null && !prev.provisional && g.provisional) return;
        if (prev == null || _sig(g) != _sig(prev)) changed = true;
        _live[s.id] = g;
      }
      for (var i = 0; i < table.length; i++) {
        take(table[i], gotTable[i]);
      }
      for (var i = 0; i < file.length; i++) {
        take(file[i], gotFile[i]);
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

  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  /// Итоги старта из файла протокола: тот же вид результата, что и с табло.
  Future<LiveResult> _fromFile(Start s) async {
    final load = await ProtocolRepo.app.load(s.proto!);
    return switch (load) {
      ProtocolOk(:final doc) => liveFromProtocol(s, doc),
      ProtocolNetError() => const LiveNet(),
      ProtocolMissing() => const LiveNone(),
      ProtocolFormatError() => const LiveFormat(),
    };
  }

  static String _sig(LiveOk s) => [
    s.provisional,
    for (final p in s.podium) '${p.place}${p.name}${p.points}',
    for (final p in s.total ?? const <Placing>[]) '${p.place}${p.name}${p.points}',
    for (final e in s.places.entries) '${e.key}${e.value}',
    for (final e in s.finals.entries) '${e.key}${e.value}',
  ].join('|');

  /// Расписание с сервера → под отслеживаемых и с итогами с табло. Сервер дошёл до окончательного — его и берём.
  Schedule _apply(Schedule raw) {
    final shown = regional ? raw : raw.withStarts([for (final s in raw.starts) if (!s.regional) s]);
    final d = shown.withFollow(follow);
    if (_live.isEmpty) return d;
    _live.removeWhere((id, _) => d.byId(id)?.settled ?? true);
    if (_live.isEmpty) return d;
    return d.withStarts([
      for (final s in d.starts)
        if (_live[s.id] case final l?)
          s.withResults(
            podium: l.podium,
            provisional: l.provisional,
            places: l.places,
            total: l.total,
            finals: l.finals,
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
