// Общее состояние приложения: расписание, фильтр ленты, уведомления, оформление.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_icon.dart';
import 'archive.dart';
import 'billing.dart';
import 'data.dart';
import 'lineup.dart';
import 'live.dart';
import 'pace.dart';
import 'protocol_model.dart';
import 'protocol_repo.dart';
import 'platform.dart';
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

  /// Код, привязанный к аккаунту, если он известен этому устройству; [codeLinked] — знает ли сервер о привязке.
  String? get syncLinkedCode => SyncLocal(Prefs.raw).linkedCode;
  bool? codeLinked;

  /// Сервер уже ответил на вопрос о привязке (пусть и «не знаю»). Пока нет — интерфейс не утверждает ничего.
  bool codeLinkChecked = false;

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

  /// Есть ли с чем входить: адрес сервера в сборке (в тестах — подменённый клиент).
  bool get syncAvailable => _syncReady;
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
      liveEvery: liveEvery,
      liveEveryOver: liveEveryOver,
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
      if (has('liveEvery')) Prefs.setLiveEvery(d.liveEvery),
      if (has('liveEveryOver')) Prefs.setLiveEveryOver(d.liveEveryOver),
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
    liveEvery = Prefs.liveEvery;
    liveEveryOver = Prefs.liveEveryOver;
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
      if (!same) await SyncLocal(Prefs.raw).setLinkedCode(null);
      if (!same) {
        codeLinked = null;
        codeLinkChecked = false;
        await _forgetBilling();
      }
      await SyncLocal(Prefs.raw).setCode(null);
      await _keepSession(b, s);
      notifyListeners();
      unawaited(refreshBilling());
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
    await SyncLocal(Prefs.raw).setLinkedCode(null);
    codeLinked = null;
    codeLinkChecked = false;
    if (sync.backend case final AccountBackend a) a.signOut();
    sync.backend = null;
    await billing.clear();
    await _resetDevice();
  }

  /// Сброс настроек этого устройства к значениям по умолчанию (после отключения синхронизации).
  /// Забыть подписку прошлого аккаунта. Были в плане сводка дня, уведомления о составе или итоги — снять их из системы.
  /// (Выход сюда не ходит: там _resetDevice и так пересобирает уведомления.)
  Future<void> _forgetBilling() async {
    final had = plan.digest != null || billing.lineupAt(now()) || billing.resultsAt(now());
    await billing.clear();
    if (had) unawaited(_sync());
  }

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
      // подписка — у аккаунта, а не у кода
      await _forgetBilling();
      notifyListeners();
      await sync.reconcile();
      return null;
    } on SyncError catch (e) {
      return e.message;
    }
  }

  // ---------------------------------------------------------------- два входа в один аккаунт

  /// Вошли по коду, привязываем почту: войти (или зарегистрироваться), привязать код к аккаунту и
  /// переключить устройство на почту. Код остаётся привязанным и работает на других устройствах.
  /// Сначала уходят несохранённые правки (под кодом), чтобы сервер слил актуальный документ; при любой
  /// ошибке устройство остаётся на коде, ничего не сбрасывается.
  Future<String?> linkMail(String email, String password, {bool create = false}) async {
    if (!_syncReady) return 'Аккаунты в этой сборке недоступны';
    final code = SyncLocal(Prefs.raw).code;
    if (code == null || sync.backend is! CodeBackend) return 'Нужен вход по коду';
    final b = _accountBackend();
    try {
      final s = create ? await b.signUp(email, password) : await b.signIn(email, password);
      await sync.reconcile();
      if (sync.problem != null) return sync.problem;
      await b.linkCode(code);
      // база и правки остаются как были: время документа сервер при слиянии не меняет, так что
      // следующая сверка заберёт документ аккаунта, только если он новее
      sync.backend = b;
      final local = SyncLocal(Prefs.raw);
      await local.setLinkedCode(code);
      await local.setCode(null);
      await _keepSession(b, s);
      codeLinked = true;
      notifyListeners();
      unawaited(refreshBilling());
      await sync.reconcile();
      return null;
    } on SyncError catch (e) {
      return e.message;
    }
  }

  /// Вошли по почте: создать код и сразу привязать его к аккаунту. Прежняя привязка заменяется.
  Future<String?> createLinkedCode() async {
    final code = CodeBackend.newCode();
    return _linkCodeToAccount(code);
  }

  /// Вошли по почте: привязать к аккаунту существующий код. Документы сливаются на сервере по времени сохранения.
  Future<String?> linkEnteredCode(String input) async {
    final code = CodeBackend.normalize(input);
    if (code.length != 16) return 'Код — 16 знаков';
    try {
      if (!_syncReady) return 'Аккаунты в этой сборке недоступны';
      if (await CodeBackend(url: _url, key: _key, code: code, client: syncClient).load() == null) {
        return 'Такого кода нет на сервере';
      }
    } on SyncError catch (e) {
      return e.message;
    }
    final err = await _linkCodeToAccount(code);
    if (err == null) await sync.reconcile();
    return err;
  }

  Future<String?> _linkCodeToAccount(String code) async {
    final b = sync.backend;
    if (b is! AccountBackend) return 'Нужен вход в аккаунт';
    try {
      await b.linkCode(code);
      await SyncLocal(Prefs.raw).setLinkedCode(code);
      codeLinked = true;
      notifyListeners();
      return null;
    } on SyncError catch (e) {
      return e.message;
    }
  }

  /// Спросить сервер, привязан ли к аккаунту код (если этого устройства он не знает). Не получилось — не утверждаем.
  Future<void> refreshCodeLink() async {
    final b = sync.backend;
    if (b is! AccountBackend) return;
    final v = await b.hasCodeLink();
    if (!identical(sync.backend, b)) return;
    if (v != codeLinked || !codeLinkChecked) {
      codeLinked = v;
      codeLinkChecked = true;
      notifyListeners();
    }
  }

  /// Отключить синхронизацию на этом устройстве: код и вход забываются, настройки сбрасываются к умолчанию.
  /// Бэкенд отключаем раньше сброса, как в [signOutSync]: сброс на сервер не уходит.
  Future<void> disconnectSync() async {
    await SyncLocal(Prefs.raw).setAccount(null);
    await SyncLocal(Prefs.raw).setLinkedCode(null);
    codeLinked = null;
    codeLinkChecked = false;
    await SyncLocal(Prefs.raw).setCode(null);
    if (sync.backend case final AccountBackend a) a.signOut();
    sync.backend = null;
    await billing.clear();
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

  // ---------------------------------------------------------------- архив прошлых сезонов

  /// Месяцы прошлых лет: подгружаются, когда до них долистали (archive.dart).
  final Archive archive = Archive();

  /// Месяц, с которого нынешнее расписание знает всё само: раньше него — архив.
  String? get liveFrom {
    final first = _raw?.starts.isEmpty ?? true ? null : _raw!.starts.first;
    return first == null ? null : monthKey(msk(first.t0));
  }

  /// Нужен ли этому месяцу архив: он раньше или тот же, с которого начинается расписание.
  bool pastWanted(String month) {
    final from = liveFrom;
    return from == null || month.compareTo(from) <= 0;
  }

  /// Что с месяцем архива: загружается, готов, не загрузился, нет в архиве.
  PastState pastState(String month) => pastWanted(month) ? archive.stateOf(month) : PastState.none;

  /// Долистали до месяца: взять его из архива, если он там есть.
  Future<void> needPast(String month) async {
    if (!pastWanted(month)) return;
    final before = archive.stateOf(month);
    final run = archive.load(month);
    // «загружается» видно сразу, а не после ответа
    if (archive.stateOf(month) != before) notifyListeners();
    if (await run) notifyListeners();
  }

  /// Старты месяца из архива под выбор отслеживаемых; того, что уже есть в расписании, здесь нет.
  List<Start> pastStarts(String month) {
    final m = archive.month(month);
    if (m == null) return const [];
    final cached = _pastView[month];
    final f = follow;
    if (cached != null && identical(cached.$1, _raw) && cached.$2 == f.signature) return cached.$3;
    final have = {for (final s in _raw?.starts ?? const <Start>[]) s.id};
    final list = [for (final s in m.starts) if (!have.contains(s.id)) s.withFollow(f)];
    _pastView[month] = (_raw, f.signature, list);
    return list;
  }

  final Map<String, (Schedule?, String, List<Start>)> _pastView = {};

  /// Турниры месяца из архива, у которых нет времени сегментов.
  List<PastTournament> pastTournaments(String month) => archive.month(month)?.tournaments ?? const [];

  /// Только для тестов: расписание, как после загрузки (без сети), с отслеживаемыми по умолчанию.
  @visibleForTesting
  void adoptSchedule(Schedule raw) {
    _raw = raw;
    data = _apply(raw);
  }

  /// Только для тестов: итоги старта, как после опроса табло.
  @visibleForTesting
  void adoptLive(String startId, LiveOk l) {
    _live[startId] = l;
    if (_raw != null) data = _apply(_raw!);
    notifyListeners();
  }

  // уведомления
  NotifyRules rules = NotifyRules.fromJson(Prefs.rulesJson);
  Set<String> forcedOn = Prefs.forcedOn;
  Set<String> forcedOff = Prefs.forcedOff;

  /// Разрешены ли уведомления в системе; null — неизвестно (веб, ещё не проверено).
  bool? allowed;

  /// Android, работа в фоне: 0 — без ограничений, 1 — экономия энергии, 2 — запрещена;
  /// null — не Android или узнать нельзя.
  int? background;

  /// Запланированные уведомления — ближайшие, как их видит система.
  List<Planned> planned = const [];

  // лента и оформление
  bool showDone = Prefs.showDone;
  ThemeMode theme = _mode(Prefs.theme);

  /// Старты региональных федераций: по умолчанию не показываются.
  bool regional = Prefs.regional;

  /// Живые места: общий режим (instant — табло с заданной частотой, delayed — файл протокола) и переопределения.
  String liveMode = Prefs.liveMode;
  Map<String, String> liveOverrides = Prefs.liveOverrides;

  /// Частота опроса табло, секунды: общая и по id старта (не меньше [liveEveryMin]).
  int liveEvery = Prefs.liveEvery;
  Map<String, int> liveEveryOver = Prefs.liveEveryOver;
  int liveEveryOf(Start s) => effectiveLiveEvery(liveEvery, liveEveryOver, s.id);

  /// Действующий режим старта: своё переопределение или общий.
  /// В браузере табло недоступно (canReadBoards) — всегда файл протокола с нашего сайта.
  String liveModeOf(Start s) => canReadBoards ? effectiveLiveMode(liveMode, liveOverrides, s.id) : liveDelayed;

  /// Регионы, у которых есть старты в расписании — видно и при выключенном показе.
  List<String> get regionNames => {
    for (final s in _raw?.starts ?? const <Start>[]) if (s.regional && s.region.isNotEmpty) s.region,
  }.toList()..sort();

  /// Уведомления о составе (подписка, lineup.dart): найденные при сверках и ещё не истёкшие.
  List<LineupEvent> lineup = const [];

  /// Правила, исключения, сводка дня, уведомления о составе и итоги ваших (если подписка действует).
  NotifyPlan get plan => NotifyPlan(
    rules,
    forcedOn,
    forcedOff,
    digest: billing.digestAt(now()),
    events: billing.lineupAt(now()) ? [for (final e in lineup) e.planned()] : const [],
    results: billing.resultsAt(now()),
    updates: Reminders.updatesShown,
  );

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
      await _restoreLive();
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
      // ответ беднее прежнего (сборщик не досчитал, источник молчал) показанное не отбирает
      final prev = _raw;
      _raw = prev == null ? fresh : Schedule.mergeKeepingRicher(prev, fresh, now: now());
      data = _apply(_raw!);
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
    // подписка — тогда же: после оплаты в браузере человек возвращается в приложение
    unawaited(refreshBilling());
    // уведомления включены по умолчанию — разрешение спрашиваем один раз, при первом запуске
    if (rules.on && !Prefs.asked) {
      await Prefs.setAsked();
      await Reminders.ask();
    }
    await refreshPermission();
  }

  Future<void> refreshPermission() async {
    final a = await Reminders.allowed();
    final b = await Reminders.background();
    if (a != allowed || b != background) {
      allowed = a;
      background = b;
      notifyListeners();
    }
  }

  /// Снять ограничение работы в фоне; ответ системы — при возвращении в приложение (refreshPermission).
  Future<void> allowBackground() => Reminders.allowBackground();

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

  Future<void> setLiveEvery(int sec) async {
    liveEvery = validLiveEvery(sec) ?? liveEveryDefault;
    await Prefs.setLiveEvery(liveEvery);
    notifyListeners();
    touchSync();
    unawaited(pollLive(force: true));
  }

  /// Частота одного старта: null — как в настройках.
  Future<void> setLiveEveryOver(String startId, int? sec) async {
    final next = {...liveEveryOver};
    final v = validLiveEvery(sec);
    if (v == null) {
      next.remove(startId);
    } else {
      next[startId] = v;
    }
    liveEveryOver = next;
    await Prefs.setLiveEveryOver(next);
    notifyListeners();
    touchSync();
    unawaited(pollLive(force: true));
  }

  /// Итоги, прочитанные из другого источника, не должны остаться поверх нового режима.
  void _resetLiveSource() {
    // уже показанные итоги не стираем: новый источник заменит их, когда ответит, а до тех пор
    // они лучше пустого места (ответ беднее прежнего их не заменяет — см. pollLive)
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

  /// Свежие итоги старта с табло (или из файла в режиме «стандартный»); null — опроса ещё не было.
  LiveOk? liveOf(String startId) => _live[startId];

  /// Когда табло опубликовало оценку каждого выступившего: id старта → (personKey → момент). По ним
  /// считается темп (pace.dart): от последней оценки, а не от бумажного расписания.
  final Map<String, Map<String, DateTime>> _posted = {};

  /// Записать, кто уже выступил по табло. Момент — время самого табло ([stamp]: страница обновилась,
  /// когда появилась эта оценка), если оно правдоподобно; иначе — когда устройство увидело. Уже
  /// записанных не трогаем: первое появление и есть публикация.
  bool notePosted(String startId, Iterable<String> names, DateTime? stamp, {DateTime? seenAt}) {
    final at = seenAt ?? DateTime.now();
    final m = _posted.putIfAbsent(startId, () => {});
    // время табло из будущего (часы табло спешат) или слишком давнее — не верим ему
    final when = stamp != null && !stamp.isAfter(at.add(const Duration(minutes: 1))) && stamp.isAfter(at.subtract(const Duration(hours: 6)))
        ? (stamp.isAfter(at) ? at : stamp)
        : at;
    var added = false;
    for (final n in names) {
      final k = personKey(n);
      if (k.isEmpty || m.containsKey(k)) continue;
      m[k] = when;
      added = true;
    }
    if (stamp != null) _boardAt[startId] = stamp;
    return added;
  }

  /// Время табло по старту: когда страница сегмента обновилась в последний раз.
  final Map<String, DateTime> _boardAt = {};

  /// Кто выступает следующим по табло («Далее: …»), с какого момента и идёт ли ещё его разминка:
  /// id старта → (personKey, момент, разминка).
  final Map<String, ({String key, DateTime since, bool warmup})> _onIce = {};

  /// Табло назвало следующего: новое имя — с этого момента; у того же кончилась разминка — его выход
  /// с этого момента (время табло, если правдоподобно).
  bool noteOnIce(String startId, String? name, DateTime? stamp, {bool warmup = false, DateTime? seenAt}) {
    if (name == null || name.isEmpty) return false;
    final k = personKey(name);
    final was = _onIce[startId];
    if (was != null && was.key == k && (was.warmup == warmup || !was.warmup)) return false;
    final at = seenAt ?? DateTime.now();
    var since = stamp != null && !stamp.isAfter(at.add(const Duration(minutes: 1))) && stamp.isAfter(at.subtract(const Duration(hours: 1)))
        ? (stamp.isAfter(at) ? at : stamp)
        : at;
    // время табло — до минуты: не раньше прошлого «Далее»
    if (was != null && since.isBefore(was.since)) since = at;
    _onIce[startId] = (key: k, since: since, warmup: warmup);
    return true;
  }

  /// Протокол, собранный на устройстве (экран протокола): выступившие идущих сегментов — в темп.
  void noteProtocol(Iterable<Start> starts, ProtocolDoc doc) {
    var added = false;
    for (final s in starts) {
      final seg = doc.categoryFor(s.kind, s.level)?.segmentOf(s.seg);
      if (seg == null || (seg.rows.isEmpty && seg.next == null)) continue;
      if (seg.state != SegmentState.inProgress && seg.state != SegmentState.provisional) continue;
      _posted.putIfAbsent(s.id, () => {});
      added |= notePosted(s.id, [for (final r in seg.rows) if (r.place != null) r.name], seg.stamp);
      added |= noteOnIce(s.id, seg.next, seg.stamp, warmup: seg.nextWarmup);
    }
    if (added && _raw != null) {
      data = _apply(_raw!);
      notifyListeners();
      unawaited(_saveLive());
    }
  }

  /// Минута, на которую посчитан темп: затянувшийся прокат сдвигает время оставшихся с каждой минутой.
  int _paceMinute = -1;
  String _paceSig = '';

  /// Когда в последний раз читали файл протокола для старта (режим «стандартный» — не чаще раза в 5 минут).
  final Map<String, DateTime> _fileAt = {};

  /// Когда в последний раз спрашивали табло по старту: срок следующего — по его частоте.
  final Map<String, DateTime> _polledAt = {};
  static const _fileEvery = Duration(minutes: 5);
  Timer? _liveTimer;
  bool _polling = false;
  DateTime _fetchedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Когда телефон в последний раз получил расписание с сервера; null — за этот запуск ни разу.
  DateTime? get fetchedAt => _fetchedAt.millisecondsSinceEpoch == 0 ? null : _fetchedAt;

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

  /// Приложение на экране: табло с заданной частотой. Свёрнуто — не опрашиваем.
  void startLive() {
    _liveTimer?.cancel();
    // тик чаще самой короткой частоты; кому пора — решает pollLive по своим часам
    _liveTimer = Timer.periodic(const Duration(seconds: 5), (_) => pollLive());
    unawaited(pollLive(force: true));
  }

  void stopLive() {
    _liveTimer?.cancel();
    _liveTimer = null;
  }

  /// Порядок опроса: идущие, потом ближайшие по времени к «сейчас» (вот-вот начнутся или только
  /// закончились). Без этого при длинном дне утренние сегменты занимали все места, и идущий
  /// в конец списка не попадал.
  @visibleForTesting
  static List<Start> pollOrder(Iterable<Start> starts, DateTime t) {
    Duration gap(Start s) =>
        t.isBefore(s.t0) ? s.t0.difference(t) : (t.isAfter(s.t1) ? t.difference(s.t1) : Duration.zero);
    final items = starts.toList();
    final index = {for (var i = 0; i < items.length; i++) items[i]: i};
    items.sort((a, b) {
      final c = gap(a).compareTo(gap(b));
      return c != 0 ? c : index[a]!.compareTo(index[b]!);
    });
    return items;
  }

  /// [force] — опросить сразу, не дожидаясь срока (старт приложения, смена настроек).
  Future<void> pollLive({bool force = false}) async {
    if (_polling || data == null) return;
    _repace();
    final list = pollOrder(watching, now()).take(8).toList();
    if (list.isEmpty) return;
    _polling = true;
    try {
      // «моментально» — табло раз в минуту; «стандартный» — табло не трогаем, файл протокола раз в 5 минут
      final now = DateTime.now();
      final table = [
        for (final s in list)
          if (liveModeOf(s) == liveInstant &&
              (force || now.difference(_polledAt[s.id] ?? _epoch) >= Duration(seconds: liveEveryOf(s) - 1)))
            s,
      ];
      for (final s in table) {
        _polledAt[s.id] = now;
      }
      final file = [
        for (final s in list)
          if (liveModeOf(s) == liveDelayed && s.proto != null && now.difference(_fileAt[s.id] ?? _epoch) >= _fileEvery) s,
      ];
      if (table.isEmpty && file.isEmpty) return;
      final gotTable = await Future.wait(table.map(Live.poll));
      final gotFile = await Future.wait(file.map(_fromFile));
      for (final s in file) {
        _fileAt[s.id] = now;
      }
      var changed = false;
      void take(Start s, LiveResult g) {
        // табло ответило, а прокатов ещё нет: темп считаем и так — начало затянулось, если первому
        // давно пора получить оценку, а её всё нет
        if (g is LiveNone && table.contains(s)) {
          if (!_posted.containsKey(s.id)) {
            _posted[s.id] = {};
            changed = true;
          }
          changed |= noteOnIce(s.id, g.next, g.stamp, warmup: g.warmup, seenAt: now);
        }
        // сеть, пустое табло или чужая страница — прошлые итоги остаются как были
        if (g is! LiveOk) return;
        final prev = _live[s.id];
        // окончательный протокол не понижаем до промежуточного из-за неполного опроса
        if (prev != null && !prev.provisional && g.provisional) return;
        // и не оставляем меньше строк, чем уже видели: опрос мог прийти не весь
        if (prev != null && g.provisional == prev.provisional && g.rows.length < prev.rows.length) return;
        if (prev == null || _sig(g) != _sig(prev)) changed = true;
        _live[s.id] = g;
        // кто выступил и когда — для темпа; итоги из файла сервера моменту публикации не свидетели
        if (g.provisional && table.contains(s)) {
          changed |= notePosted(s.id, [for (final r in g.rows) r.name], g.stamp, seenAt: now);
          changed |= noteOnIce(s.id, g.next, g.stamp, warmup: g.warmup, seenAt: now);
        }
      }
      for (var i = 0; i < table.length; i++) {
        take(table[i], gotTable[i]);
      }
      for (var i = 0; i < file.length; i++) {
        take(file[i], gotFile[i]);
      }
      if (changed && _raw != null) {
        data = _apply(_raw!);
        _paceSig = _paceSignature();
        notifyListeners();
        unawaited(_saveLive());
        // по табло старт мог закончиться или затянуться — уведомления следом, не дожидаясь сервера
        unawaited(_sync());
      }
      // примечательное и окончательный итог считает сервер — забираем его чаще, пока что-то идёт
      if (DateTime.now().difference(_fetchedAt) > const Duration(minutes: 5)) unawaited(load());
    } finally {
      _polling = false;
    }
  }

  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  /// Раз в минуту, пока что-то идёт, — темп заново: время оставшихся зависит от «сейчас». Поменялось
  /// время чьего-то выхода — уведомления следом.
  void _repace() {
    final m = DateTime.now().millisecondsSinceEpoch ~/ 60000;
    if (m == _paceMinute || _raw == null) return;
    _paceMinute = m;
    if (!(data?.starts.any((s) => s.pace != null) ?? false) && _posted.isEmpty) return;
    data = _apply(_raw!);
    final sig = _paceSignature();
    notifyListeners();
    if (sig != _paceSig) {
      _paceSig = sig;
      unawaited(_sync());
    }
  }

  /// Время выхода всех, поправленное по темпу, одной строкой: по ней видно, что уведомления пора переставить.
  String _paceSignature() => [
    for (final s in data?.starts ?? const <Start>[])
      if (s.pace != null) '${s.id}:${[for (final o in s.ours) '${o.name}@${o.time}'].join(',')}',
  ].join('|');

  static const _liveKey = 'live.last';
  static const _postedKey = 'live.posted';

  /// Итоги с табло — на диск: после перезапуска без сети карточка показывает то, что уже показывала.
  Future<void> _saveLive() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_liveKey, jsonEncode({for (final e in _live.entries) e.key: e.value.toJson()}));
      await p.setString(_postedKey, jsonEncode({
        for (final e in _posted.entries) e.key: {for (final x in e.value.entries) x.key: x.value.toUtc().toIso8601String()},
      }));
    } catch (_) {}
  }

  /// Сохранённые итоги — до первой отрисовки; устаревшие уберёт [_apply] (сервер дошёл до окончательного).
  Future<void> _restoreLive() async {
    if (_live.isNotEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_liveKey);
      if (s == null) return;
      for (final e in (jsonDecode(s) as Map).entries) {
        final l = LiveOk.tryFromJson(e.value);
        if (l != null) _live['${e.key}'] = l;
      }
      final posted = p.getString(_postedKey);
      if (posted != null) {
        for (final e in (jsonDecode(posted) as Map).entries) {
          _posted['${e.key}'] = {
            for (final x in (e.value as Map).entries)
              if (DateTime.tryParse('${x.value}') case final DateTime t) '${x.key}': t,
          };
        }
      }
    } catch (_) {}
  }

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
    // баллы — в итогах ваших (уведомление)
    for (final p in s.rows) '${p.name}${p.points}',
    for (final e in s.finals.entries) '${e.key}${e.value}',
  ].join('|');

  /// Расписание с сервера → под отслеживаемых, с итогами с табло и временем выхода по темпу.
  /// Сервер дошёл до окончательного — его и берём.
  Schedule _apply(Schedule raw) {
    final shown = regional ? raw : raw.withStarts([for (final s in raw.starts) if (!s.regional) s]);
    final d = shown.withFollow(follow);
    _live.removeWhere((id, _) => d.byId(id)?.settled ?? true);
    // темп помним, пока старт не закончился и сутки после: дальше он никому не нужен
    final t = now();
    _posted.removeWhere((id, _) {
      final s = d.byId(id);
      return s == null || t.isAfter(s.t1.add(const Duration(hours: 24)));
    });
    _onIce.removeWhere((id, _) => !_posted.containsKey(id));
    if (_live.isEmpty && _posted.isEmpty) return d;
    return d.withStarts([for (final s in d.starts) _paced(_live[s.id] == null ? s : _withLive(s, _live[s.id]!), t)]);
  }

  Start _withLive(Start s, LiveOk l) => s.withResults(
    podium: l.podium,
    provisional: l.provisional,
    places: l.places,
    points: {for (final r in l.rows) if (r.points.isNotEmpty) norm(r.name): r.points},
    total: l.total,
    finals: l.finals,
  );

  /// Время выхода оставшихся — по темпу (pace.dart), пока сегмент идёт или вот-вот начнётся и
  /// устройство читает его табло. Закончился — поправлять нечего.
  Start _paced(Start s, DateTime t) {
    if (s.live == null || s.finishedAt(t) || s.field.length < 2) return s;
    if (t.isBefore(s.t0.subtract(const Duration(minutes: 30))) || t.isAfter(s.t1.add(const Duration(hours: 3)))) return s;
    // табло этого старта устройство не видело — опереться не на что, остаётся расписание
    if (!_live.containsKey(s.id) && !_posted.containsKey(s.id)) return s;
    final p = paceOf(s, posted: _posted[s.id] ?? const {}, boardAt: _boardAt[s.id] ?? _live[s.id]?.stamp, onIce: _onIce[s.id], now: t);
    return p == null ? s : s.withPace(p);
  }

  // ---------------------------------------------------------------- подписка (billing.dart)

  late final BillingState billing = BillingState(Prefs.raw);

  /// Вход по почте — через него идёт подписка. По коду или без входа — null.
  AccountBackend? get account => switch (sync.backend) {
    final AccountBackend a => a,
    _ => null,
  };

  Future<void>? _billingRun;

  /// Идёт ли сейчас обновление подписки.
  bool get billingRefreshing => _billingRun != null;

  /// Обновить подписку: что продаётся (и без входа), право и платежи (со входом). [history] — платежи
  /// тоже, даже если их ещё не загружали. Без подписки в сборке — ничего. Ошибка не стирает известное:
  /// право остаётся из кэша, а причина — в billing.problem, чтобы экран сказал, что данные могли устареть.
  /// Одно обновление за раз: попросили во время другого — дождёмся его и сделаем ещё одно, свежее
  /// (то могло начаться до оплаты или отказа).
  Future<void> refreshBilling({bool history = false}) async {
    if (!billingBuild || !_syncReady) return;
    for (var busy = _billingRun; busy != null; busy = _billingRun) {
      await busy;
    }
    final run = _refreshBilling(history);
    _billingRun = run;
    try {
      await run;
    } finally {
      if (identical(_billingRun, run)) _billingRun = null;
    }
  }

  Future<void> _refreshBilling(bool history) async {
    final b = billing;
    final digestWas = plan.digest;
    final lineupWas = b.lineupAt(now());
    final resultsWas = b.resultsAt(now());
    String? problem;
    try {
      try {
        b.offer = await BillingApi(account ?? _accountBackend()).offer();
        b.offerChecked = true;
      } on SyncError catch (e) {
        problem = e.message;
      }
      final acc = account;
      if (acc != null) {
        try {
          final api = BillingApi(acc);
          final e = await api.mine(DateTime.now);
          // вышли или сменили аккаунт, пока шёл ответ: чужое право не сохраняем
          if (!identical(account, acc)) return;
          await b.keep(e);
          if (history || b.payments != null) b.payments = await api.payments();
        } on SyncError catch (e) {
          problem ??= e.message;
        }
      }
      b.problem = problem;
    } finally {
      notifyListeners();
    }
    // план уведомлений пересчитывается сразу (в начале _sync), система — следом, не задерживая обновление
    if (plan.digest != digestWas || b.lineupAt(now()) != lineupWas || b.resultsAt(now()) != resultsWas) {
      unawaited(_sync());
    }
  }

  /// Начать оплату: страница сервиса для встроенного браузера. Ошибка — SyncError с понятным текстом.
  Future<BillingCheckout> startPayment(BillingPlan p, {required bool renew, String? consent}) async {
    final acc = account;
    if (acc == null) throw const SyncError('Нужен вход в аккаунт');
    final offer = billing.offer;
    if (offer == null) throw SyncError(billingErrors['billing_off']!);
    return BillingApi(acc).checkout(plan: p.id, renew: renew, offerVersion: offer.version, consent: consent);
  }

  /// Ждать подтверждения оплаты от сервиса (оно приходит на сервер отдельно от возврата из браузера):
  /// true — прошла, false — не прошла, null — за [limit] не подтвердили (подписка появится позже сама,
  /// при следующем обновлении).
  Future<bool?> awaitPayment(String id, {Duration limit = const Duration(seconds: 40), Duration every = const Duration(seconds: 2)}) async {
    final acc = account;
    if (acc == null) return null;
    final api = BillingApi(acc);
    final until = DateTime.now().add(limit);
    while (true) {
      try {
        final x = (await api.payments()).where((p) => p.id == id).firstOrNull;
        if (x != null && x.status != 'pending') {
          await refreshBilling(history: true);
          return x.status == 'succeeded';
        }
      } on SyncError {
        // нет связи сейчас — пробуем ещё, пока не выйдет время
      }
      if (!DateTime.now().add(every).isBefore(until)) {
        await refreshBilling(history: true);
        return null;
      }
      await Future<void>.delayed(every);
    }
  }

  /// Отключить продление. Возвращает причину, если не вышло.
  Future<String?> cancelRenew() async {
    final acc = account;
    if (acc == null) return 'Нужен вход в аккаунт';
    try {
      await BillingApi(acc).cancelRenew();
    } on SyncError catch (e) {
      return e.message;
    }
    await refreshBilling(history: true);
    return null;
  }

  /// Отказаться с возвратом за неиспользованные дни: подписка заканчивается сразу.
  Future<(BillingRefund?, String?)> refundSubscription() async {
    final acc = account;
    if (acc == null) return (null, 'Нужен вход в аккаунт');
    try {
      final r = await BillingApi(acc).refund();
      await refreshBilling(history: true);
      return (r, null);
    } on SyncError catch (e) {
      await refreshBilling(history: true);
      return (null, e.message);
    }
  }

  /// Время сводки дня ([BillingState.digestOff] — выключена).
  Future<void> setDigest(int minute) async {
    await billing.setDigest(minute);
    notifyListeners();
    unawaited(_sync());
  }

  /// Включить или выключить уведомления о жеребьёвке и составе.
  Future<void> setLineup(bool on) async {
    await billing.setLineup(on);
    notifyListeners();
    unawaited(_sync());
  }

  /// Включить или выключить итоги ваших в уведомлении.
  Future<void> setResults(bool on) async {
    await billing.setResults(on);
    notifyListeners();
    unawaited(_sync());
  }

  Future<void> _sync() async {
    // состав сверяется со всем расписанием с сервера — до плана, чтобы найденное сразу в него попало
    lineup = await Lineup.update(Prefs.raw, _raw, follow, now(), on: billing.lineupAt(now()));
    final d = data;
    planned = d == null ? const [] : Reminders.plan(d, plan, now());
    notifyListeners();
    // уведомления настраиваются после показа экрана — ждём, пока init() отработает
    await Reminders.settled.timeout(const Duration(seconds: 10), onTimeout: () {});
    await Reminders.sync(d, plan);
  }
}
