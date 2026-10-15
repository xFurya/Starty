// Синхронизация настроек между устройствами. Один документ на человека: отслеживаемые, правила
// уведомлений, фильтр ленты, тема, значок. Две дороги к нему:
//  • аккаунт — почта и пароль (Supabase: auth + таблица user_settings с политикой «только свои строки»);
//  • код синхронизации — случайная строка, по её хэшу сервер хранит документ, входа нет.
// Сервер задаётся сборкой: --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON=…
// Без них раздел честно показывает, что сервер не подключён.
//
// Слияние — по времени последнего изменения. Устройство помнит, на каком документе
// (времени) оно остановилось (baseAt) и когда его меняли сами (localAt). Что изменилось
// позже, то и побеждает; при одновременных правках — последнее по времени.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const syncUrl = String.fromEnvironment('SUPABASE_URL');
const syncKey = String.fromEnvironment('SUPABASE_ANON');

bool get syncConfigured => syncUrl.isNotEmpty && syncKey.isNotEmpty;

/// Регистрация прошла, но вход станет возможен только после письма. Это подсказка, а не ошибка.
const kConfirmMail = 'Письмо для подтверждения отправлено на почту';

/// Документ настроек. Версия — для будущих изменений формата: лишние поля игнорируются.
class SyncDoc {
  final DateTime updatedAt; // UTC
  final String rules; // NotifyRules.toJson()
  final List<String> forcedOn, forcedOff;
  final List<String> follow;
  final bool followRussians, followBelarusians;
  final Map<String, List<String>>
  filters; // kinds, tids, athletes, levels, scope
  final bool showDone;
  final String theme; // system, light, dark
  final String icon; // classic, skate_teal, date_orange_… (см. app_icon.dart)

  const SyncDoc({
    required this.updatedAt,
    required this.rules,
    required this.forcedOn,
    required this.forcedOff,
    required this.follow,
    required this.followRussians,
    required this.followBelarusians,
    required this.filters,
    required this.showDone,
    required this.theme,
    required this.icon,
  });

  static const _filterKeys = ['kinds', 'tids', 'athletes', 'levels', 'scope'];

  Map<String, dynamic> toJson() => {
    'v': 1,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'rules': rules,
    'forcedOn': forcedOn,
    'forcedOff': forcedOff,
    'follow': follow,
    'followRussians': followRussians,
    'followBelarusians': followBelarusians,
    'filters': filters,
    'showDone': showDone,
    'theme': theme,
    'icon': icon,
  };

  /// Разбор с защитой: битое поле — значение по умолчанию, а не падение.
  factory SyncDoc.fromJson(Map<String, dynamic> j) {
    List<String> list(Object? v) => v is List
        ? [
            for (final e in v)
              if (e is String) e,
          ]
        : const [];
    final f = j['filters'] is Map
        ? Map<String, dynamic>.from(j['filters'] as Map)
        : const <String, dynamic>{};
    return SyncDoc(
      updatedAt:
          DateTime.tryParse('${j['updatedAt']}')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      rules: j['rules'] is String ? j['rules'] as String : '',
      forcedOn: list(j['forcedOn']),
      forcedOff: list(j['forcedOff']),
      follow: list(j['follow']),
      followRussians: j['followRussians'] is bool
          ? j['followRussians'] as bool
          : true,
      followBelarusians: j['followBelarusians'] is bool
          ? j['followBelarusians'] as bool
          : true,
      filters: {for (final k in _filterKeys) k: list(f[k])},
      showDone: j['showDone'] is bool ? j['showDone'] as bool : true,
      theme: j['theme'] is String ? j['theme'] as String : 'system',
      icon: j['icon'] is String ? j['icon'] as String : 'classic',
    );
  }

  /// Тот же документ с новым временем изменения.
  SyncDoc at(DateTime t) => SyncDoc(
    updatedAt: t.toUtc(),
    rules: rules,
    forcedOn: forcedOn,
    forcedOff: forcedOff,
    follow: follow,
    followRussians: followRussians,
    followBelarusians: followBelarusians,
    filters: filters,
    showDone: showDone,
    theme: theme,
    icon: icon,
  );

  static DateTime get epoch =>
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

/// Что делать при сверке.
enum SyncAction { none, pull, push }

/// Правило слияния. remote — updatedAt документа на сервере (null — документа ещё нет),
/// baseAt — документ, на котором устройство остановилось, localAt — последнее изменение здесь.
SyncAction decideSync({
  required DateTime? remote,
  required DateTime baseAt,
  required DateTime localAt,
}) {
  final remoteChanged = remote != null && remote.isAfter(baseAt);
  final localChanged = localAt.isAfter(baseAt);
  if (remote == null) return SyncAction.push;
  if (remoteChanged && localChanged) {
    return remote.isAfter(localAt) ? SyncAction.pull : SyncAction.push;
  }
  if (remoteChanged) return SyncAction.pull;
  if (localChanged) return SyncAction.push;
  return SyncAction.none;
}

/// Функции, возвращающие таблицу, отдают список строк: берём первую (или ничего).
SyncDoc? _docOf(http.Response r) {
  final rows = jsonDecode(utf8.decode(r.bodyBytes));
  if (rows is! List || rows.isEmpty || rows.first is! Map) return null;
  final doc = (rows.first as Map)['doc'];
  return doc is Map ? SyncDoc.fromJson(Map<String, dynamic>.from(doc)) : null;
}

/// Ошибка, которую можно показать человеку.
class SyncError implements Exception {
  final String message;
  const SyncError(this.message);
  @override
  String toString() => message;
}

/// Хранилище документа на сервере.
abstract class SyncBackend {
  Future<SyncDoc?> load();
  Future<void> save(SyncDoc doc);
}

/// Вход по почте и паролю: Supabase (GoTrue для входа, PostgREST для таблицы user_settings).
class AccountBackend implements SyncBackend {
  AccountBackend({
    required this.url,
    required this.key,
    http.Client? client,
    this.session,
    this.keep,
  }) : _http = client ?? http.Client();

  final String url, key;
  final http.Client _http;
  AccountSession? session;

  /// Сохранить вход после обновления: токен обновления меняется при каждом обновлении.
  final Future<void> Function(AccountSession s)? keep;

  Map<String, String> _headers({bool auth = true}) => {
    'apikey': key,
    'Content-Type': 'application/json',
    if (auth && session != null) 'Authorization': 'Bearer ${session!.access}',
  };

  Future<AccountSession> signUp(String email, String password) async {
    final r = await _send(
      () => _http.post(
        Uri.parse('$url/auth/v1/signup'),
        headers: _headers(auth: false),
        body: jsonEncode({'email': email, 'password': password}),
      ),
    );
    final j = _json(r);
    // при включённом подтверждении почты токена нет — сообщаем, что нужно открыть письмо
    if (j['access_token'] == null) throw const SyncError(kConfirmMail);
    return session = AccountSession.fromJson(j, email);
  }

  Future<AccountSession> signIn(String email, String password) async {
    final r = await _send(
      () => _http.post(
        Uri.parse('$url/auth/v1/token?grant_type=password'),
        headers: _headers(auth: false),
        body: jsonEncode({'email': email, 'password': password}),
      ),
    );
    return session = AccountSession.fromJson(_json(r), email);
  }

  Future<void> refreshIfNeeded() async {
    final s = session;
    if (s == null ||
        DateTime.now().toUtc().isBefore(
          s.expiresAt.subtract(const Duration(minutes: 2)),
        )) {
      return;
    }
    try {
      final r = await _send(
        () => _http.post(
          Uri.parse('$url/auth/v1/token?grant_type=refresh_token'),
          headers: _headers(auth: false),
          body: jsonEncode({'refresh_token': s.refresh}),
        ),
      );
      session = AccountSession.fromJson(_json(r), s.email);
    } on SyncError catch (e) {
      // сеть — просто не получилось сейчас; иначе вход недействителен, нужен новый
      if (e.message == 'Сервер не отвечает' || e.message == 'Нет связи с сервером') {
        rethrow;
      }
      throw const SyncError('Войдите в аккаунт заново');
    }
    await keep?.call(session!);
  }

  void signOut() => session = null;

  @override
  Future<SyncDoc?> load() async {
    if (session == null) throw const SyncError('Нужен вход в аккаунт');
    await refreshIfNeeded();
    final r = await _send(
      () => _http.post(
        Uri.parse('$url/rest/v1/rpc/load_settings'),
        headers: _headers(),
        body: '{}',
      ),
    );
    return _docOf(r);
  }

  @override
  Future<void> save(SyncDoc doc) async {
    if (session == null) throw const SyncError('Нужен вход в аккаунт');
    await refreshIfNeeded();
    await _send(
      () => _http.post(
        Uri.parse('$url/rest/v1/rpc/save_settings'),
        headers: _headers(),
        body: jsonEncode({'doc': doc.toJson()}),
      ),
    );
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      final r = await call().timeout(const Duration(seconds: 20));
      if (r.statusCode >= 200 && r.statusCode < 300) return r;
      throw SyncError(_explain(r));
    } on SyncError {
      rethrow;
    } on TimeoutException {
      throw const SyncError('Сервер не отвечает');
    } catch (_) {
      throw const SyncError('Нет связи с сервером');
    }
  }

  Map<String, dynamic> _json(http.Response r) {
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    return j is Map<String, dynamic> ? j : <String, dynamic>{};
  }

  static String _explain(http.Response r) {
    String msg = '';
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) {
        msg = '${j['error_description'] ?? j['msg'] ?? j['message'] ?? ''}';
      }
    } catch (_) {}
    if (r.statusCode == 400 || r.statusCode == 401 || r.statusCode == 403) {
      if (msg.toLowerCase().contains('invalid login')) {
        return 'Неверная почта или пароль';
      }
      if (msg.toLowerCase().contains('already registered') ||
          msg.toLowerCase().contains('already exists')) {
        return 'Такая почта уже зарегистрирована';
      }
      if (msg.toLowerCase().contains('password')) {
        return 'Пароль не подходит: нужно больше символов';
      }
      return 'Вход не выполнен';
    }
    if (r.statusCode == 429) return 'Слишком много попыток, подождите немного';
    return 'Сервер ответил ошибкой (${r.statusCode})';
  }
}

class AccountSession {
  final String access, refresh, email;
  final DateTime expiresAt;
  const AccountSession(this.access, this.refresh, this.expiresAt, this.email);

  factory AccountSession.fromJson(Map<String, dynamic> j, String email) {
    final access = j['access_token'];
    if (access is! String) throw const SyncError('Вход не выполнен');
    final secs = j['expires_in'] is int ? j['expires_in'] as int : 3600;
    return AccountSession(
      access,
      j['refresh_token'] is String ? j['refresh_token'] as String : '',
      DateTime.now().toUtc().add(Duration(seconds: secs)),
      email,
    );
  }

  Map<String, String> toMap() => {
    'access': access,
    'refresh': refresh,
    'expires': expiresAt.toIso8601String(),
    'email': email,
  };

  static AccountSession? fromMap(Map<String, String>? m) {
    if (m == null || m['access'] == null) return null;
    return AccountSession(
      m['access']!,
      m['refresh'] ?? '',
      DateTime.tryParse(m['expires'] ?? '')?.toUtc() ?? DateTime.now().toUtc(),
      m['email'] ?? '',
    );
  }
}

/// Код синхронизации: сервер хранит документ под хэшем кода. Сам код у сервера не бывает.
class CodeBackend implements SyncBackend {
  CodeBackend({
    required this.url,
    required this.key,
    required this.code,
    http.Client? client,
  }) : _http = client ?? http.Client();

  final String url, key, code;
  final http.Client _http;

  /// Хэш для сервера: код ни в логах, ни в базе не появляется открытым.
  static String hashOf(String code) =>
      sha256.convert(utf8.encode('starty-sync:$code')).toString();

  /// Новый код: 16 знаков без похожих символов (без 0/O, 1/I/L).
  static String newCode([Random? rnd]) {
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final r = rnd ?? Random.secure();
    return [for (var i = 0; i < 16; i++) alphabet[r.nextInt(alphabet.length)]]
        .join();
  }

  /// Код, как его вводят: регистр и разделители не важны.
  static String normalize(String input) =>
      input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  Map<String, String> get _headers => {
    'apikey': key,
    'Authorization': 'Bearer $key',
    'Content-Type': 'application/json',
  };

  @override
  Future<SyncDoc?> load() async {
    final r = await _send(
      () => _http.post(
        Uri.parse('$url/rest/v1/rpc/load_settings_by_code'),
        headers: _headers,
        body: jsonEncode({'code_hash': hashOf(code)}),
      ),
    );
    return _docOf(r);
  }

  @override
  Future<void> save(SyncDoc doc) async {
    await _send(
      () => _http.post(
        Uri.parse('$url/rest/v1/rpc/save_settings_by_code'),
        headers: _headers,
        body: jsonEncode({'code_hash': hashOf(code), 'doc': doc.toJson()}),
      ),
    );
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      final r = await call().timeout(const Duration(seconds: 20));
      if (r.statusCode >= 200 && r.statusCode < 300) return r;
      if (r.statusCode == 404) {
        throw const SyncError('Такого кода нет на сервере');
      }
      throw SyncError('Сервер ответил ошибкой (${r.statusCode})');
    } on SyncError {
      rethrow;
    } on TimeoutException {
      throw const SyncError('Сервер не отвечает');
    } catch (_) {
      throw const SyncError('Нет связи с сервером');
    }
  }
}

/// Что сохранено на устройстве о синхронизации: базовый момент и локальные изменения.
class SyncState {
  final DateTime baseAt, localAt;
  const SyncState(this.baseAt, this.localAt);
}

/// Хранение состояния синхронизации в preferences. Ключи — отдельные, не пересекаются с настройками.
class SyncLocal {
  SyncLocal(this._p);
  final SharedPreferences _p;

  SyncState get state => SyncState(
    DateTime.tryParse(_p.getString('sync.base') ?? '')?.toUtc() ??
        SyncDoc.epoch,
    DateTime.tryParse(_p.getString('sync.local') ?? '')?.toUtc() ??
        SyncDoc.epoch,
  );

  Future<void> markLocal(DateTime at) =>
      _p.setString('sync.local', at.toUtc().toIso8601String());
  Future<void> markBase(DateTime at) =>
      _p.setString('sync.base', at.toUtc().toIso8601String());

  Map<String, String>? get account {
    final raw = _p.getString('sync.account');
    if (raw == null) return null;
    try {
      return {
        for (final e in (jsonDecode(raw) as Map).entries)
          '${e.key}': '${e.value}',
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> setAccount(Map<String, String>? m) async {
    if (m == null) {
      await _p.remove('sync.account');
    } else {
      await _p.setString('sync.account', jsonEncode(m));
    }
  }

  String? get code => _p.getString('sync.code');
  Future<void> setCode(String? c) async {
    if (c == null) {
      await _p.remove('sync.code');
    } else {
      await _p.setString('sync.code', c);
    }
  }

  DateTime? get lastSyncAt => DateTime.tryParse(_p.getString('sync.at') ?? '');
  Future<void> markSynced(DateTime at) =>
      _p.setString('sync.at', at.toUtc().toIso8601String());
}

/// Сверка и отправка. Не знает, откуда берутся настройки: их даёт [capture], принимает [apply].
class SyncController {
  SyncController({
    required this.local,
    required this.capture,
    required this.apply,
    this.onChange,
    DateTime Function()? clock,
  }) : _now = clock ?? (() => DateTime.now().toUtc());

  final SyncLocal local;
  final Future<SyncDoc> Function() capture;
  final Future<void> Function(SyncDoc doc) apply;
  final DateTime Function() _now;

  /// Куда подключено: аккаунт или код. null — синхронизация выключена.
  SyncBackend? backend;

  /// Что не вышло в последний раз, по-человечески; null — всё в порядке.
  String? problem;

  /// Дёргается после каждой сверки (успешной и нет) — чтобы экран перерисовал статус.
  final void Function()? onChange;

  Timer? _debounce;
  bool _busy = false, _again = false;

  /// Пользователь что-то поменял: отметить время и отправить чуть позже (несколько правок — одной отправкой).
  Future<void> touch() async {
    await local.markLocal(_now());
    if (backend == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => unawaited(reconcile()));
  }

  /// Вошли в уже существующие настройки: свои прошлые правки не шлём, сначала берём серверные.
  Future<void> preferRemote() async {
    await local.markBase(SyncDoc.epoch);
    await local.markLocal(SyncDoc.epoch);
  }

  /// Сверить с сервером: что новее — то и побеждает. Возвращает true, если что-то поменялось.
  /// Правка, пришедшая во время сверки, не теряется: сверка повторится сразу после.
  Future<bool> reconcile() async {
    final b = backend;
    if (b == null) return false;
    if (_busy) {
      _again = true;
      return false;
    }
    _busy = true;
    try {
      final changed = await _run(b);
      problem = null;
      return changed;
    } catch (e) {
      problem = e is SyncError ? e.message : 'Не удалось синхронизировать';
      return false;
    } finally {
      _busy = false;
      onChange?.call();
      if (_again) {
        _again = false;
        unawaited(reconcile());
      }
    }
  }

  Future<bool> _run(SyncBackend b) async {
    final remote = await b.load();
    final st = local.state;
    switch (decideSync(
      remote: remote?.updatedAt,
      baseAt: st.baseAt,
      localAt: st.localAt,
    )) {
      case SyncAction.pull:
        await apply(remote!);
        await local.markBase(remote.updatedAt);
        await local.markSynced(_now());
        return true;
      case SyncAction.push:
        final stamped = (await capture()).at(_now());
        await b.save(stamped);
        await local.markBase(stamped.updatedAt);
        await local.markSynced(_now());
        return false;
      case SyncAction.none:
        await local.markSynced(_now());
        return false;
    }
  }

  void dispose() => _debounce?.cancel();
}
