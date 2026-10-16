// Синхронизация настроек между устройствами. Один документ на человека: отслеживаемые, правила
// уведомлений, фильтр ленты, тема, значок. Две дороги к нему:
//  • аккаунт — почта и пароль (Supabase: auth + таблица user_settings с политикой «только свои строки»);
//  • код синхронизации — случайная строка, по её хэшу сервер хранит документ, входа нет.
// Сервер задаётся сборкой: --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON=…
// Без них раздел честно показывает, что сервер не подключён.
//
// Слияние — документ целиком. Побеждает последнее сохранение на сервере: время его ставит
// сервер при каждом сохранении. Часы устройств в порядке не участвуют. Правки на двух устройствах
// одновременно — одна затирает другую; список отслеживаемых — тоже целиком.
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

/// Схема на сервере старше приложения: нет функции привязки кода.
const kOldSchema = 'Обновите схему сервера';

/// Документ настроек: всё, что человек меняет в приложении, кроме служебного состояния устройства
/// (кэш расписания, разрешение ОС, заметки обновления и т. п. — см. ПРОЕКТ.md, раздел 2.4).
/// Версия 2 — текущая; версию 1 читаем (см. [_followOf]). Лишние поля игнорируются.
class SyncDoc {
  final DateTime updatedAt; // UTC; время сохранения на сервере (см. _docOf)
  final String rules; // NotifyRules.toJson()
  final List<String> forcedOn, forcedOff;

  /// null — человек не выбирал отслеживаемых, действует список сборщика; [] — выбрал «никого».
  final List<String>? follow;
  final bool followRussians, followBelarusians;
  final Map<String, List<String>>
  filters; // kinds, tids, athletes, levels, scope
  final bool showDone;
  final String theme; // system, light, dark
  final String icon; // classic, skate_teal, date_orange_… (см. app_icon.dart)
  final bool regional; // старты региональных федераций в ленте и уведомлениях

  /// Режим живых мест по умолчанию: instant (табло раз в минуту) или delayed (файл протокола).
  final String liveMode;

  /// Переопределения режима по id старта; отсутствующий id — режим по умолчанию.
  final Map<String, String> liveOverrides;

  /// Поля, которых в документе нет или они испорчены (см. [fromJson]). Такие не применяются:
  /// на устройстве остаётся своя настройка, а не значение по умолчанию. Для документа, собранного
  /// здесь, пусто. Имена полей — как в JSON; у фильтров — «filters.kinds» и т. п.
  final Set<String> absent;

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
    this.regional = false,
    this.liveMode = 'instant',
    this.liveOverrides = const {},
    this.absent = const {},
  });

  static const _filterKeys = ['kinds', 'tids', 'athletes', 'levels', 'scope'];
  static const _themes = {'system', 'light', 'dark'};

  Map<String, dynamic> toJson() => {
    'v': 2,
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
    'regional': regional,
    'liveMode': liveMode,
    'liveOverrides': liveOverrides,
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
    // что не читается — в absent: при применении такое поле не трогаем (см. SyncDoc.absent)
    final absent = <String>{
      if (j['rules'] is! String) 'rules',
      if (j['forcedOn'] is! List) 'forcedOn',
      if (j['forcedOff'] is! List) 'forcedOff',
      if (!_followKnown(j)) 'follow',
      if (j['followRussians'] is! bool) 'followRussians',
      if (j['followBelarusians'] is! bool) 'followBelarusians',
      for (final k in _filterKeys)
        if (f[k] is! List) 'filters.$k',
      if (j['showDone'] is! bool) 'showDone',
      if (!(j['theme'] is String && _themes.contains(j['theme']))) 'theme',
      if (j['icon'] is! String) 'icon',
      if (j['regional'] is! bool) 'regional',
      if (!(j['liveMode'] is String && (j['liveMode'] == 'instant' || j['liveMode'] == 'delayed'))) 'liveMode',
      if (j['liveOverrides'] is! Map) 'liveOverrides',
    };
    return SyncDoc(
      updatedAt:
          DateTime.tryParse('${j['updatedAt']}')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      rules: j['rules'] is String ? j['rules'] as String : '',
      forcedOn: list(j['forcedOn']),
      forcedOff: list(j['forcedOff']),
      follow: _followOf(j),
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
      regional: j['regional'] is bool ? j['regional'] as bool : false,
      liveMode: j['liveMode'] == 'delayed' ? 'delayed' : 'instant',
      liveOverrides: {
        if (j['liveOverrides'] is Map)
          for (final e in (j['liveOverrides'] as Map).entries)
            if (e.value == 'instant' || e.value == 'delayed') '${e.key}': e.value as String,
      },
      absent: absent,
    );
  }

  /// Отслеживаемые читаются, если поле — список или явный null («по умолчанию»); отсутствие поля — не null.
  static bool _followKnown(Map<String, dynamic> j) =>
      j['follow'] == null ? j.containsKey('follow') : j['follow'] is List;

  /// Отслеживаемые. В версии 1 пустой список означал и «не выбирал», и «снял всех» — различить нельзя.
  /// Поэтому пустой список из старого документа читаем как «не выбирал» (null). Цена: тот, кто до
  /// обновления явно снял всех, снова получит список сборщика. В версии 2 [] — это уже явный выбор.
  static List<String>? _followOf(Map<String, dynamic> j) {
    final raw = j['follow'];
    if (raw is! List) return null;
    final l = [
      for (final e in raw)
        if (e is String) e,
    ];
    final v = j['v'];
    final legacy = v is! num || v < 2;
    return legacy && l.isEmpty ? null : l;
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
    regional: regional,
    liveMode: liveMode,
    liveOverrides: liveOverrides,
    absent: absent,
  );

  static DateTime get epoch =>
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

/// Отслеживаемые для документа. Выбор, совпавший со списком сборщика, — это «по умолчанию» (null):
/// тогда следующее обновление списка дойдёт и до этого устройства. defaults == null — список
/// сборщика ещё не загружен, сравнивать не с чем, выбор сохраняется как есть.
List<String>? followToStore(Iterable<String> chosen, Iterable<String>? defaults) {
  final c = chosen.toSet();
  if (defaults != null) {
    final d = defaults.toSet();
    if (d.length == c.length && c.containsAll(d)) return null;
  }
  return c.toList()..sort();
}

/// Значок для документа. Если значок устройства с прошлой сверки не менялся, документ сохраняет свой
/// значок — даже если здесь его не поставили (датированного нет на iPhone, или система отказала),
/// иначе показанный здесь значок затёр бы документ. Если человек поменял значок здесь, берём здешний.
String iconToSync({
  required String device,
  required String? docIcon,
  required String? lastDevice,
}) {
  if (docIcon == null) return device;
  final changedHere = lastDevice != null && lastDevice != device;
  return changedHere ? device : docIcon;
}

/// Что делать при сверке.
enum SyncAction { none, pull, push }

/// Правило слияния. Документ целиком; побеждает последнее сохранение на сервере.
/// remote — updatedAt документа на сервере (его ставит сервер; null — документа ещё нет),
/// baseAt — время сохранения, которое видело устройство, pending — есть несохранённая правка.
/// Часы устройства в сравнении не участвуют: порядок задаёт сервер.
SyncAction decideSync({
  required DateTime? remote,
  required DateTime baseAt,
  required bool pending,
}) {
  if (remote == null) return SyncAction.push;
  // своя правка уходит на сервер и перезаписывает документ, даже если там уже новее:
  // кто сохранил последним, тот и прав
  if (pending) return SyncAction.push;
  if (remote.isAfter(baseAt)) return SyncAction.pull;
  return SyncAction.none;
}

/// Функции, возвращающие таблицу, отдают список строк: берём первую (или ничего).
/// Время документа — колонка updated_at строки: его ставит сервер при каждом сохранении.
/// Поле updatedAt внутри JSON не доверяем; если колонки нет — остаётся то, что в JSON.
SyncDoc? _docOf(http.Response r) {
  final rows = jsonDecode(utf8.decode(r.bodyBytes));
  if (rows is! List || rows.isEmpty || rows.first is! Map) return null;
  final row = rows.first as Map;
  final doc = row['doc'];
  if (doc is! Map) return null;
  final parsed = SyncDoc.fromJson(Map<String, dynamic>.from(doc));
  final col = row['updated_at'] is String
      ? DateTime.tryParse(row['updated_at'] as String)
      : null;
  return col == null ? parsed : parsed.at(col);
}

/// Время сохранения, которое вернул сервер: scalar-функция отдаёт JSON-строку с временем.
/// Не разобралось — сохранение нельзя считать подтверждённым.
DateTime _savedAt(http.Response r) {
  DateTime? t;
  try {
    final v = jsonDecode(utf8.decode(r.bodyBytes));
    if (v is String) t = DateTime.tryParse(v);
  } catch (_) {}
  if (t == null) throw const SyncError('Сервер не сообщил время сохранения');
  return t.toUtc();
}

/// Ошибка, которую можно показать человеку.
class SyncError implements Exception {
  final String message;

  /// Код ответа сервера, если ошибка пришла из ответа (а не из сети).
  final int? status;
  const SyncError(this.message, {this.status});
  @override
  String toString() => message;
}

/// Хранилище документа на сервере.
abstract class SyncBackend {
  Future<SyncDoc?> load();

  /// Сохранить документ. Возвращает время сохранения, которое поставил сервер.
  Future<DateTime> save(SyncDoc doc);
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
      final fresh = AccountSession.fromJson(_json(r), s.email);
      // вышли или сменили аккаунт, пока шло обновление: старая сессия не возвращается
      if (!identical(session, s)) return;
      session = fresh;
    } on SyncError catch (e) {
      // вход недействителен (сервер отказал в обновлении) — нужен новый; сеть, 5xx, 429 и прочее —
      // не получилось сейчас, токен остаётся, сообщение как есть
      if (e.status == 400 || e.status == 401) {
        throw const SyncError('Войдите в аккаунт заново');
      }
      rethrow;
    }
    await keep?.call(session!);
  }

  void signOut() => session = null;

  /// Привязать код к этому аккаунту (rpc link_code, ПРОЕКТ.md 2.4). Сервер сливает документы и дальше
  /// ведёт один — аккаунта. Схема сервера без link_code отвечает 404: это не «нет кода», а устаревшая схема.
  Future<void> linkCode(String code) async {
    if (session == null) throw const SyncError('Нужен вход в аккаунт');
    await refreshIfNeeded();
    try {
      await _send(
        () => _http.post(
          Uri.parse('$url/rest/v1/rpc/link_code'),
          headers: _headers(),
          body: jsonEncode({'code_hash': CodeBackend.hashOf(code)}),
        ),
      );
    } on SyncError catch (e) {
      if (e.status == 404) throw const SyncError(kOldSchema);
      rethrow;
    }
  }

  /// Привязан ли к аккаунту какой-нибудь код. null — не узнать (схема старая или нет связи): тогда
  /// интерфейс ничего не утверждает.
  Future<bool?> hasCodeLink() async {
    if (session == null) return null;
    try {
      await refreshIfNeeded();
      final r = await _send(
        () => _http.post(
          Uri.parse('$url/rest/v1/rpc/has_code_link'),
          headers: _headers(),
          body: '{}',
        ),
      );
      final v = jsonDecode(utf8.decode(r.bodyBytes));
      return v is bool ? v : null;
    } catch (_) {
      return null;
    }
  }

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
  Future<DateTime> save(SyncDoc doc) async {
    if (session == null) throw const SyncError('Нужен вход в аккаунт');
    await refreshIfNeeded();
    final r = await _send(
      () => _http.post(
        Uri.parse('$url/rest/v1/rpc/save_settings'),
        headers: _headers(),
        body: jsonEncode({'doc': doc.toJson()}),
      ),
    );
    return _savedAt(r);
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      final r = await call().timeout(const Duration(seconds: 20));
      if (r.statusCode >= 200 && r.statusCode < 300) return r;
      throw SyncError(_explain(r), status: r.statusCode);
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
    String msg = '', code = '';
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) {
        msg = '${j['error_description'] ?? j['msg'] ?? j['message'] ?? ''}';
        code = '${j['error_code'] ?? ''}'.toLowerCase();
      }
    } catch (_) {}
    // ошибки привязки кода: сервер отвечает стабильным идентификатором (tools/sync/schema.sql, link_code)
    if (msg == 'code_taken') return 'Код уже привязан к другому аккаунту';
    if (msg == 'bad_code') return 'Код не подходит';
    if (msg == 'not_signed_in') return 'Войдите в аккаунт заново';
    if (code == 'weak_password') return 'Пароль слишком простой';
    if (code == 'user_already_exists' || code == 'email_exists') {
      return 'Такая почта уже зарегистрирована';
    }
    if ([400, 401, 403, 422].contains(r.statusCode)) {
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
  Future<DateTime> save(SyncDoc doc) async {
    final r = await _send(
      () => _http.post(
        Uri.parse('$url/rest/v1/rpc/save_settings_by_code'),
        headers: _headers,
        body: jsonEncode({'code_hash': hashOf(code), 'doc': doc.toJson()}),
      ),
    );
    return _savedAt(r);
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      final r = await call().timeout(const Duration(seconds: 20));
      if (r.statusCode >= 200 && r.statusCode < 300) return r;
      if (r.statusCode == 404) {
        throw const SyncError('Такого кода нет на сервере');
      }
      throw SyncError('Сервер ответил ошибкой (${r.statusCode})', status: r.statusCode);
    } on SyncError {
      rethrow;
    } on TimeoutException {
      throw const SyncError('Сервер не отвечает');
    } catch (_) {
      throw const SyncError('Нет связи с сервером');
    }
  }
}

/// Что сохранено на устройстве о синхронизации: время сохранения, которое устройство видело
/// (baseAt, его ставит сервер), и есть ли несохранённая правка (pending).
class SyncState {
  final DateTime baseAt;
  final bool pending;
  const SyncState(this.baseAt, this.pending);
}

/// Хранение состояния синхронизации в preferences. Ключи — отдельные, не пересекаются с настройками.
class SyncLocal {
  SyncLocal(this._p);
  final SharedPreferences _p;

  SyncState get state => SyncState(
    DateTime.tryParse(_p.getString('sync.base') ?? '')?.toUtc() ??
        SyncDoc.epoch,
    _pending,
  );

  /// Флаг правки. Раньше хранилось время правки (sync.local): пока флага нет, а старое время есть,
  /// правка считается несохранённой, если она позже базы. Первая запись флага старый ключ убирает.
  bool get _pending {
    final flag = _p.getString('sync.pending');
    if (flag != null) return flag == '1';
    final old = DateTime.tryParse(_p.getString('sync.local') ?? '')?.toUtc();
    final base = DateTime.tryParse(_p.getString('sync.base') ?? '')?.toUtc() ??
        SyncDoc.epoch;
    return old != null && old.isAfter(base);
  }

  Future<void> markPending(bool v) async {
    await _p.setString('sync.pending', v ? '1' : '0');
    await _p.remove('sync.local');
  }

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

  /// Код, привязанный к аккаунту, если его создали или ввели на этом устройстве. Сервер хранит
  /// только хэш, поэтому узнать код с другого устройства нельзя.
  String? get linkedCode => _p.getString('sync.linked');
  Future<void> setLinkedCode(String? c) async {
    if (c == null) {
      await _p.remove('sync.linked');
    } else {
      await _p.setString('sync.linked', c);
    }
  }

  DateTime? get lastSyncAt => DateTime.tryParse(_p.getString('sync.at') ?? '');
  Future<void> markSynced(DateTime at) =>
      _p.setString('sync.at', at.toUtc().toIso8601String());

  /// Значок, который документ имел здесь, и значок устройства на той же сверке (см. [iconToSync]).
  String? get iconDoc => _p.getString('sync.icon.doc');
  String? get iconDev => _p.getString('sync.icon.dev');
  Future<void> setIconSeen({required String doc, required String device}) async {
    await _p.setString('sync.icon.doc', doc);
    await _p.setString('sync.icon.dev', device);
  }
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
  bool _again = false;

  /// Идущая сверка: тот, кто просит сверить во время неё, ждёт её итога, а не получает пустой ответ.
  Future<bool>? _running;

  /// Число правок. Растёт при каждом [touch]: отправка сравнивает его до и после сохранения, чтобы
  /// понять, не пришла ли правка, пока документ уходил. Порядок правок — по счётчику, не по часам.
  int _editSeq = 0;

  /// Отложенная сверка: несколько правок подряд уходят одной отправкой.
  void _later() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => unawaited(reconcile()));
  }

  /// Пользователь что-то поменял: отметить правку и отправить чуть позже (несколько правок — одной отправкой).
  Future<void> touch() async {
    _editSeq++;
    await local.markPending(true);
    if (backend == null) return;
    _later();
  }

  /// Вошли в уже существующие настройки: свои прошлые правки не шлём, сначала берём серверные.
  Future<void> preferRemote() async {
    await local.markBase(SyncDoc.epoch);
    await local.markPending(false);
  }

  /// Сверить с сервером: что новее — то и побеждает. Возвращает true, если что-то поменялось.
  /// Правка, пришедшая во время сверки, не теряется: она остаётся отмеченной и уйдёт следующей сверкой.
  Future<bool> reconcile() {
    final b = backend;
    if (b == null) return Future.value(false);
    final running = _running;
    if (running != null) {
      // сверка уже идёт: после неё пройдём ещё раз (вдруг изменилось), а этот вызов получит итог идущей
      _again = true;
      return running;
    }
    return _running = _reconcile(b);
  }

  Future<bool> _reconcile(SyncBackend b) async {
    try {
      final changed = await _run(b);
      problem = null;
      return changed;
    } catch (e) {
      problem = e is SyncError ? e.message : 'Не удалось обновить настройки';
      return false;
    } finally {
      _running = null;
      onChange?.call();
      if (_again) {
        _again = false;
        unawaited(reconcile());
      }
    }
  }

  Future<bool> _run(SyncBackend b) async {
    final remote = await b.load();
    // Вход сменили, пока шла загрузка: документ уже чужой, состояние сверки (база, правки) трогать нельзя —
    // оно теперь относится к новому аккаунту.
    if (!identical(backend, b)) return false;
    final st = local.state;
    switch (decideSync(
      remote: remote?.updatedAt,
      baseAt: st.baseAt,
      pending: st.pending,
    )) {
      case SyncAction.pull:
        // Применение пишет серверные значения разом, в самом начале: правка, пришедшая после этого,
        // лежит поверх них. Номер правок сверяем, как при отправке: правку не снимаем, её отправит следующая сверка.
        final seq = _editSeq;
        await apply(remote!);
        if (!identical(backend, b)) return true;
        await local.markBase(remote.updatedAt);
        if (_editSeq != seq) {
          await local.markPending(true);
          _later();
        }
        await local.markSynced(_now());
        return true;
      case SyncAction.push:
        // номер читаем до захвата: правки до него уже в документе, после него сверим по номеру
        final seq = _editSeq;
        final doc = await capture();
        final saved = await b.save(doc);
        if (!identical(backend, b)) return false;
        await local.markBase(saved);
        if (_editSeq == seq) {
          await local.markPending(false);
        } else {
          // правка пришла, пока документ уходил: отметку не снимаем, её отправит следующая сверка
          _later();
        }
        await local.markSynced(_now());
        return false;
      case SyncAction.none:
        await local.markSynced(_now());
        return false;
    }
  }

  void dispose() => _debounce?.cancel();
}
