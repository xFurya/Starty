// Исправления сверки настроек (ПРОЕКТ.md, раздел 2.4): повторный вход не стирает правки, правка во время
// загрузки документа не теряется, запоздалое обновление токена не возвращает вход, ошибки сервера
// называются правдиво, смена режима живых мест с другого устройства сбрасывает источник, «Сверить» во
// время сверки ждёт её итога.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/live.dart';
import 'package:starty/protocol_repo.dart';
import 'package:starty/state.dart';
import 'package:starty/sync.dart';

SyncDoc doc(String theme, DateTime at, {String liveMode = 'instant'}) => SyncDoc(
  updatedAt: at,
  rules: '{}',
  forcedOn: const [],
  forcedOff: const [],
  follow: null,
  followRussians: true,
  followBelarusians: true,
  filters: const {'kinds': [], 'tids': [], 'athletes': [], 'levels': [], 'scope': []},
  showDone: true,
  theme: theme,
  icon: 'classic',
  liveMode: liveMode,
);

/// Сервер в памяти: вход, обновление токена, документ. Время сохранения ставит он сам.
class Server {
  SyncDoc? stored;
  int n = 0;
  int refreshStatus = 200;
  Completer<void>? refreshGate;
  int tokenLife = 3600;

  DateTime get _t => DateTime.utc(2026, 1, 1, 0, 0, n);

  MockClient get client => MockClient((r) async {
    final p = r.url.path;
    if (p.endsWith('/token')) {
      if (r.url.queryParameters['grant_type'] == 'refresh_token') {
        await refreshGate?.future;
        if (refreshStatus != 200) return http.Response(jsonEncode({'msg': 'x'}), refreshStatus);
        return http.Response(jsonEncode({'access_token': 'a2', 'refresh_token': 'r2', 'expires_in': 3600}), 200);
      }
      return http.Response(jsonEncode({'access_token': 'a1', 'refresh_token': 'r1', 'expires_in': tokenLife}), 200);
    }
    if (p.contains('load_settings')) {
      final d = stored;
      return http.Response(jsonEncode(d == null ? [] : [{'doc': d.toJson(), 'updated_at': d.updatedAt.toIso8601String()}]), 200);
    }
    if (p.contains('save_settings')) {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      stored = SyncDoc.fromJson(body['doc'] as Map<String, dynamic>).at(_t.add(Duration(seconds: ++n)));
      return http.Response(jsonEncode(stored!.updatedAt.toIso8601String()), 200);
    }
    return http.Response('', 404);
  });
}

Schedule liveSchedule() {
  final now = DateTime.now().toUtc();
  final s = Start.fromJson({
    'id': 'ffkm:2026-08-24_pm:dance-junior-rt',
    'tid': 'ffkm:2026-08-24_pm',
    'tournament': 'Первенство Москвы',
    'kind': 'dance',
    'level': 'junior',
    'seg': 'РТ',
    'title': 'Первенство Москвы — танцы РТ',
    'src': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/index.htm',
    'start': now.subtract(const Duration(hours: 1)).toIso8601String(),
    'end': now.add(const Duration(hours: 1)).toIso8601String(),
    'proto': 'ffkm_2026-08-24_pm.json',
    'live': {
      'idx': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/index.htm',
      'seg': 'https://ffkm.ru/results/2026-2027/2026-08-24_pm/SEG007.HTM',
      'names': {},
    },
  });
  return Schedule([s], now, true, false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('повторный вход не стирает правки', () {
    test('та же почта: несохранённая правка остаётся и уходит на сервер', () async {
      final srv = Server()..stored = doc('light', DateTime.utc(2026, 1, 1));
      final s = AppState()..syncClient = srv.client;
      expect(await s.signInSync('a@b.ru', 'secret1'), isNull);
      expect(Prefs.theme, 'light');
      await s.setTheme(ThemeMode.dark);
      await settle();
      expect(await s.signInSync('a@b.ru', 'secret1'), isNull);
      expect(srv.stored!.theme, 'dark', reason: 'правка не должна быть стёрта серверным документом');
      expect(Prefs.theme, 'dark');
      s.sync.dispose();
    });

    test('другая почта: берём документ сервера, чужие правки не шлём', () async {
      final srv = Server()..stored = doc('light', DateTime.utc(2026, 1, 1));
      final s = AppState()..syncClient = srv.client;
      await s.signInSync('a@b.ru', 'secret1');
      await s.setTheme(ThemeMode.dark);
      await settle();
      await s.signInSync('c@d.ru', 'secret1');
      expect(srv.stored!.theme, 'light');
      expect(Prefs.theme, 'light');
      s.sync.dispose();
    });

    test('тот же код: правка остаётся', () async {
      final srv = Server()..stored = doc('light', DateTime.utc(2026, 1, 1));
      final s = AppState()..syncClient = srv.client;
      expect(await s.enterSyncCode('ABCDEFGHJKMNPQRS'), isNull);
      expect(Prefs.theme, 'light');
      await s.setTheme(ThemeMode.dark);
      await settle();
      expect(await s.enterSyncCode('abcd-efgh-jkmn-pqrs'), isNull);
      expect(srv.stored!.theme, 'dark');
      s.sync.dispose();
    });
  });

  group('правка во время загрузки документа', () {
    test('не теряется: значения человека после применения, правка отправляется', () async {
      final p = await SharedPreferences.getInstance();
      var theme = 'system';
      final remote = _Memory()..remote = doc('dark', DateTime.utc(2026, 1, 1));
      final gate = Completer<void>();
      final c = SyncController(
        local: SyncLocal(p),
        capture: () async => doc(theme, SyncDoc.epoch),
        apply: (d) async {
          if (!gate.isCompleted) await gate.future;
          theme = d.theme;
        },
      )..backend = remote;
      final r = c.reconcile();
      await settle();
      theme = 'light';
      await c.touch();
      gate.complete();
      await r;
      expect(theme, 'light');
      expect(SyncLocal(p).state.pending, isTrue);
      await c.reconcile();
      expect(remote.remote!.theme, 'light');
      c.dispose();
    });

    test('в приложении: тема, выбранная во время применения, остаётся в Prefs и уходит на сервер', () async {
      final srv = Server();
      final s = AppState()..syncClient = srv.client;
      srv.stored = doc('dark', DateTime.utc(2026, 1, 1));
      await s.signInSync('a@b.ru', 'secret1'); // подключились, документ взяли
      srv.stored = doc('light', DateTime.utc(2026, 1, 2)); // новый документ с другого устройства
      final gate = Completer<void>();
      final inner = s.sync.apply;
      var first = true;
      final c = SyncController(
        local: s.sync.local,
        capture: s.sync.capture,
        apply: (d) async {
          if (first) {
            first = false;
            await gate.future;
          }
          await inner(d);
        },
      )..backend = s.sync.backend;
      final r = c.reconcile();
      await settle();
      await s.setTheme(ThemeMode.dark);
      unawaited(c.touch());
      await settle();
      gate.complete();
      await r;
      expect(Prefs.theme, 'dark');
      await c.reconcile();
      expect(srv.stored!.theme, 'dark');
      c.dispose();
      s.sync.dispose();
    });
  });

  group('обновление токена', () {
    test('после выхода не возвращает вход', () async {
      final srv = Server();
      final s = AppState()..syncClient = srv.client;
      srv.stored = doc('light', DateTime.utc(2026, 1, 1));
      await s.signInSync('a@b.ru', 'secret1');
      final b = s.sync.backend! as AccountBackend;
      b.session = _expired(b.session!);
      srv.refreshGate = Completer<void>();
      final f = b.refreshIfNeeded();
      await settle();
      await s.signOutSync();
      srv.refreshGate!.complete();
      await f;
      expect(s.syncEmail, isNull, reason: 'выход не отменяется запоздалым обновлением');
      expect(s.syncOn, isFalse);
      s.sync.dispose();
    });

    test('после смены аккаунта старое обновление не перезаписывает новый вход', () async {
      final srv = Server();
      final s = AppState()..syncClient = srv.client;
      srv.stored = doc('light', DateTime.utc(2026, 1, 1));
      await s.signInSync('a@b.ru', 'secret1');
      final old = s.sync.backend! as AccountBackend;
      old.session = _expired(old.session!);
      final gate = srv.refreshGate = Completer<void>();
      final f = old.refreshIfNeeded();
      await settle();
      srv.refreshGate = null;
      await s.signInSync('c@d.ru', 'secret1');
      gate.complete();
      await f;
      expect(s.syncEmail, 'c@d.ru');
      s.sync.dispose();
    });

    test('сессия, выведенная из backend, не сохраняется после signOut', () async {
      final gate = Completer<void>();
      var kept = 0;
      final b = AccountBackend(
        url: 'http://x',
        key: 'k',
        client: MockClient((r) async {
          await gate.future;
          return http.Response(jsonEncode({'access_token': 'a2', 'refresh_token': 'r2', 'expires_in': 3600}), 200);
        }),
        session: AccountSession('a', 'r', DateTime.now().toUtc().subtract(const Duration(minutes: 1)), 'e@x'),
        keep: (s) async => kept++,
      );
      final f = b.refreshIfNeeded();
      b.signOut();
      gate.complete();
      await f;
      expect(kept, 0);
      expect(b.session, isNull);
    });
  });

  group('ошибка обновления токена', () {
    Future<(Object?, AccountBackend)> refreshWith(int status) async {
      final b = AccountBackend(
        url: 'http://x',
        key: 'k',
        client: MockClient((r) async => http.Response(jsonEncode({'msg': 'x'}), status)),
        session: AccountSession('a', 'r', DateTime.now().toUtc().subtract(const Duration(minutes: 1)), 'e@x'),
      );
      try {
        await b.refreshIfNeeded();
      } catch (e) {
        return (e, b);
      }
      return (null, b);
    }

    for (final st in [400, 401]) {
      test('$st — «Войдите в аккаунт заново»', () async {
        final (e, _) = await refreshWith(st);
        expect((e as SyncError).message, 'Войдите в аккаунт заново');
      });
    }
    test('503 — правдивое сообщение, токен сохраняется', () async {
      final (e, b) = await refreshWith(503);
      expect((e as SyncError).message, 'Сервер ответил ошибкой (503)');
      expect(b.session!.refresh, 'r');
    });
    test('429 — «Слишком много попыток», токен сохраняется', () async {
      final (e, b) = await refreshWith(429);
      expect((e as SyncError).message, startsWith('Слишком много попыток'));
      expect(b.session!.refresh, 'r');
    });
  });

  group('разбор ответов GoTrue', () {
    Future<String> signUpWith(int status, Map<String, dynamic> body) async {
      final b = AccountBackend(url: 'http://x', key: 'k', client: MockClient((r) async => http.Response(jsonEncode(body), status)));
      try {
        await b.signUp('a@b.ru', 'p');
      } on SyncError catch (e) {
        return e.message;
      }
      return '';
    }

    test('weak_password (422)', () async {
      expect(await signUpWith(422, {'error_code': 'weak_password', 'msg': 'Password should be at least 6 characters.'}), 'Пароль слишком простой');
    });
    test('user_already_exists и email_exists (422)', () async {
      expect(await signUpWith(422, {'error_code': 'user_already_exists', 'msg': 'User already registered'}), 'Такая почта уже зарегистрирована');
      expect(await signUpWith(422, {'error_code': 'email_exists', 'msg': 'x'}), 'Такая почта уже зарегистрирована');
    });
    test('422 без кода, но с текстом «already registered»', () async {
      expect(await signUpWith(422, {'msg': 'User already registered'}), 'Такая почта уже зарегистрирована');
    });
  });

  group('режим живых мест с другого устройства', () {
    test('применение документа сбрасывает источник итогов', () async {
      final calls = <String>[];
      Live.client = MockClient((r) async {
        calls.add('табло');
        return http.Response.bytes(File('test/golden/ffkm/SEG007.htm').readAsBytesSync(), 200);
      });
      ProtocolRepo.app = ProtocolRepo(
        client: MockClient((r) async {
          calls.add('файл');
          return http.Response.bytes(utf8.encode(File('test/protocol/sample.json').readAsStringSync()), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }),
      );
      try {
        final s = AppState()..data = liveSchedule();
        await s.pollLive();
        expect(calls, contains('табло'));
        calls.clear();
        await s.sync.apply(doc('system', DateTime.utc(2026, 1, 1), liveMode: 'delayed'));
        await pumpEventQueue();
        expect(s.liveMode, 'delayed');
        expect(calls, contains('файл'), reason: 'источник должен смениться сразу, а не через минуту');
        expect(calls, isNot(contains('табло')));
        s.sync.dispose();
      } finally {
        Live.client = http.Client();
        ProtocolRepo.app = ProtocolRepo();
      }
    });
  });

  group('«Сверить» во время сверки', () {
    test('ждёт итога идущей сверки', () async {
      final p = await SharedPreferences.getInstance();
      final gate = Completer<void>();
      final b = _Memory()
        ..remote = doc('dark', DateTime.utc(2026, 1, 1))
        ..gate = gate;
      var applied = 0;
      final c = SyncController(local: SyncLocal(p), capture: () async => doc('system', SyncDoc.epoch), apply: (d) async => applied++)
        ..backend = b;
      final first = c.reconcile();
      await settle();
      var done = false;
      final second = c.reconcile().then((v) {
        done = true;
        return v;
      });
      await settle();
      expect(done, isFalse, reason: 'пока идёт сверка, ответа нет');
      gate.complete();
      expect(await first, isTrue);
      expect(await second, isTrue, reason: 'итог тот же, что у идущей сверки');
      expect(applied, 1);
      c.dispose();
    });

    test('ошибка идущей сверки видна и второму вызову', () async {
      final p = await SharedPreferences.getInstance();
      final gate = Completer<void>();
      final b = _Memory()
        ..failWith = const SyncError('Сервер не отвечает')
        ..gate = gate;
      final c = SyncController(local: SyncLocal(p), capture: () async => doc('system', SyncDoc.epoch), apply: (d) async {})..backend = b;
      final first = c.reconcile();
      await settle();
      final second = c.reconcile();
      gate.complete();
      await first;
      await second;
      expect(c.problem, 'Сервер не отвечает');
      c.dispose();
    });
  });
}

AccountSession _expired(AccountSession s) =>
    AccountSession(s.access, s.refresh, DateTime.now().toUtc().subtract(const Duration(minutes: 1)), s.email);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

class _Memory implements SyncBackend {
  SyncDoc? remote;
  int n = 0;
  Completer<void>? gate;
  SyncError? failWith;
  @override
  Future<SyncDoc?> load() async {
    await gate?.future;
    if (failWith != null) throw failWith!;
    return remote;
  }

  @override
  Future<DateTime> save(SyncDoc d) async {
    final t = DateTime.utc(2026, 1, 1, 0, 0, 10 + ++n);
    remote = d.at(t);
    return t;
  }
}
