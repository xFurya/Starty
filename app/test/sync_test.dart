import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/sync.dart';

SyncDoc doc(
  DateTime at, {
  String theme = 'system',
  List<String> follow = const [],
}) => SyncDoc(
  updatedAt: at,
  rules: '{"on":true}',
  forcedOn: const [],
  forcedOff: const [],
  follow: follow,
  followRussians: true,
  followBelarusians: true,
  filters: const {
    'kinds': [],
    'tids': [],
    'athletes': [],
    'levels': [],
    'scope': [],
  },
  showDone: true,
  theme: theme,
  icon: 'classic',
);

final t0 = DateTime.utc(2026, 10, 15, 10);
DateTime at(int min) => t0.add(Duration(minutes: min));

/// Память вместо сервера: один документ на всех.
class MemoryBackend implements SyncBackend {
  SyncDoc? stored;
  int saves = 0;
  @override
  Future<SyncDoc?> load() async => stored;
  @override
  Future<void> save(SyncDoc d) async {
    saves++;
    stored = d;
  }
}

void main() {
  group('правило слияния', () {
    test('сервер пуст — отправить свои настройки', () {
      expect(
        decideSync(remote: null, baseAt: at(0), localAt: at(0)),
        SyncAction.push,
      );
    });
    test('ничего не менялось — ничего не делать', () {
      expect(
        decideSync(remote: at(5), baseAt: at(5), localAt: at(5)),
        SyncAction.none,
      );
    });
    test('на сервере новее, у нас тихо — взять с сервера', () {
      expect(
        decideSync(remote: at(9), baseAt: at(5), localAt: at(5)),
        SyncAction.pull,
      );
    });
    test('у нас поменяли, на сервере нет — отправить', () {
      expect(
        decideSync(remote: at(5), baseAt: at(5), localAt: at(7)),
        SyncAction.push,
      );
    });
    test('поменяли оба: позже изменение побеждает (сервер позже)', () {
      expect(
        decideSync(remote: at(9), baseAt: at(5), localAt: at(7)),
        SyncAction.pull,
      );
    });
    test('поменяли оба: позже изменение побеждает (у нас позже)', () {
      expect(
        decideSync(remote: at(7), baseAt: at(5), localAt: at(9)),
        SyncAction.push,
      );
    });
  });

  group('документ', () {
    test('круг туда-обратно сохраняет всё', () {
      final d = doc(at(3), theme: 'dark', follow: ['Камила Валиева']);
      final back = SyncDoc.fromJson(
        jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>,
      );
      expect(back.updatedAt, at(3));
      expect(back.theme, 'dark');
      expect(back.follow, ['Камила Валиева']);
      expect(back.rules, d.rules);
    });
    test('битые поля — значения по умолчанию, без падения', () {
      final d = SyncDoc.fromJson({
        'updatedAt': 'не дата',
        'theme': 7,
        'filters': 'сломано',
        'follow': 'нет',
      });
      expect(d.updatedAt, SyncDoc.epoch);
      expect(d.theme, 'system');
      expect(d.follow, isEmpty);
      expect(d.filters['kinds'], isEmpty);
      expect(d.showDone, isTrue);
    });
    test('чужие и новые поля игнорируются', () {
      final d = SyncDoc.fromJson({...doc(at(1)).toJson(), 'будущее': 42});
      expect(d.theme, 'system');
    });
  });

  group('код синхронизации', () {
    test('хэш стабилен, 64 знака, код на сервер не уходит открытым', () {
      final h = CodeBackend.hashOf('ABCD2345EFGH6789');
      expect(h, hasLength(64));
      expect(h, CodeBackend.hashOf('ABCD2345EFGH6789'));
      expect(h.contains('ABCD'), isFalse);
    });
    test('новый код — 16 знаков из разрешённого алфавита, без похожих', () {
      for (var i = 0; i < 50; i++) {
        final c = CodeBackend.newCode();
        expect(c, hasLength(16));
        expect(
          RegExp(r'^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]+$').hasMatch(c),
          isTrue,
        );
      }
    });
    test('ввод: регистр и дефисы не важны', () {
      expect(CodeBackend.normalize('abcd-2345 efgh'), 'ABCD2345EFGH');
    });
    test('сохранение шлёт хэш и документ, но не сам код', () async {
      late http.Request sent;
      final client = MockClient((r) async {
        sent = r;
        return http.Response('', 200);
      });
      final b = CodeBackend(
        url: 'https://x.supabase.co',
        key: 'anon',
        code: 'ABCD2345EFGH6789',
        client: client,
      );
      await b.save(doc(at(2)));
      expect(sent.url.path, '/rest/v1/rpc/save_settings_by_code');
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['code_hash'], CodeBackend.hashOf('ABCD2345EFGH6789'));
      expect(sent.body.contains('ABCD2345EFGH6789'), isFalse);
      expect(sent.headers['apikey'], 'anon');
    });
    test('загрузка: первая строка функции', () async {
      final client = MockClient(
        (r) async => http.Response(
          jsonEncode([
            {
              'doc': doc(at(4), theme: 'light').toJson(),
              'updated_at': '2026-10-15T10:04:00Z',
            },
          ]),
          200,
        ),
      );
      final b = CodeBackend(
        url: 'https://x',
        key: 'anon',
        code: 'ABCD2345EFGH6789',
        client: client,
      );
      final got = await b.load();
      expect(got!.theme, 'light');
      expect(got.updatedAt, at(4));
    });
    test('нет такой строки — null, а не ошибка', () async {
      final client = MockClient((r) async => http.Response('[]', 200));
      final b = CodeBackend(
        url: 'https://x',
        key: 'anon',
        code: 'ABCD2345EFGH6789',
        client: client,
      );
      expect(await b.load(), isNull);
    });
  });

  group('аккаунт', () {
    test(
      'вход: токен сохраняется, неверный пароль — понятная ошибка',
      () async {
        final client = MockClient((r) async {
          if (r.body.contains('wrong')) {
            return http.Response(
              jsonEncode({'error_description': 'Invalid login credentials'}),
              400,
            );
          }
          return http.Response(
            jsonEncode({
              'access_token': 'tok',
              'refresh_token': 'ref',
              'expires_in': 3600,
            }),
            200,
          );
        });
        final b = AccountBackend(url: 'https://x', key: 'anon', client: client);
        final s = await b.signIn('a@b.ru', 'secret');
        expect(s.access, 'tok');
        expect(s.email, 'a@b.ru');
        expect(
          () => b.signIn('a@b.ru', 'wrong'),
          throwsA(
            isA<SyncError>().having(
              (e) => e.message,
              'message',
              'Неверная почта или пароль',
            ),
          ),
        );
      },
    );
    test('регистрация без токена — просьба открыть письмо', () async {
      final client = MockClient((r) async => http.Response('{}', 200));
      final b = AccountBackend(url: 'https://x', key: 'anon', client: client);
      expect(
        () => b.signUp('a@b.ru', 'secret123'),
        throwsA(
          isA<SyncError>().having(
            (e) => e.message,
            'message',
            contains('Письмо'),
          ),
        ),
      );
    });
    test('загрузка и сохранение идут с токеном владельца', () async {
      final seen = <http.Request>[];
      final client = MockClient((r) async {
        seen.add(r);
        if (r.url.path.endsWith('load_settings')) {
          return http.Response(
            jsonEncode([
              {'doc': doc(at(6)).toJson()},
            ]),
            200,
          );
        }
        return http.Response('', 200);
      });
      final b = AccountBackend(
        url: 'https://x',
        key: 'anon',
        client: client,
        session: AccountSession(
          'tok',
          'ref',
          DateTime.now().toUtc().add(const Duration(hours: 1)),
          'a@b.ru',
        ),
      );
      expect((await b.load())!.updatedAt, at(6));
      await b.save(doc(at(7)));
      expect(
        seen.every((r) => r.headers['Authorization'] == 'Bearer tok'),
        isTrue,
      );
      expect(seen.last.url.path, '/rest/v1/rpc/save_settings');
    });
    test('без входа — не отправляем ничего', () async {
      final b = AccountBackend(
        url: 'https://x',
        key: 'anon',
        client: MockClient((r) async => http.Response('', 500)),
      );
      expect(() => b.load(), throwsA(isA<SyncError>()));
    });
    test(
      'сервер упал — «Сервер ответил ошибкой», без технических подробностей',
      () async {
        final client = MockClient((r) async => http.Response('boom', 503));
        final b = AccountBackend(url: 'https://x', key: 'anon', client: client);
        expect(
          () => b.signIn('a@b.ru', 'secret'),
          throwsA(
            isA<SyncError>().having(
              (e) => e.message,
              'message',
              'Сервер ответил ошибкой (503)',
            ),
          ),
        );
      },
    );
  });

  group('сверка двух устройств', () {
    late SharedPreferences prefs;
    late SyncLocal local;
    late SyncDoc current;
    var now = at(0);
    late SyncController ctl;
    late MemoryBackend server;
    List<SyncDoc> applied = [];

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      local = SyncLocal(prefs);
      current = doc(SyncDoc.epoch);
      server = MemoryBackend();
      applied = [];
      ctl = SyncController(
        local: local,
        capture: () async => current,
        apply: (d) async {
          applied.add(d);
          current = d;
        },
        clock: () => now,
      )..backend = server;
    });

    test('первое устройство создаёт документ на сервере', () async {
      current = doc(SyncDoc.epoch, theme: 'dark');
      await ctl.reconcile();
      expect(server.stored!.theme, 'dark');
      expect(server.saves, 1);
    });

    test('второе устройство получает настройки первого', () async {
      server.stored = doc(at(10), follow: ['Камила Валиева']);
      await ctl.reconcile();
      expect(applied.single.follow, ['Камила Валиева']);
      expect(local.state.baseAt, at(10));
    });

    test('после сверки без изменений повторно ничего не шлём', () async {
      server.stored = doc(at(10));
      await ctl.reconcile();
      await ctl.reconcile();
      expect(server.saves, 0);
    });

    test('изменение здесь уходит на сервер', () async {
      server.stored = doc(at(10));
      await ctl.reconcile();
      now = at(20);
      await local.markLocal(now);
      current = doc(now, theme: 'light');
      await ctl.reconcile();
      expect(server.stored!.theme, 'light');
      expect(server.stored!.updatedAt, at(20));
    });

    test('одновременные правки: побеждает позже', () async {
      server.stored = doc(at(10));
      await ctl.reconcile();
      // на сервере поменяли в 12:00, здесь — в 11:00 (позже менее)
      server.stored = doc(at(12), theme: 'dark');
      now = at(11);
      await local.markLocal(at(11));
      current = doc(at(11), theme: 'light');
      await ctl.reconcile();
      expect(current.theme, 'dark');
      expect(applied.last.theme, 'dark');
    });
  });

  group('вход в существующие настройки и сбои', () {
    test(
      'вход в чужие настройки: прежние правки не уходят, берём серверные',
      () async {
        SharedPreferences.setMockInitialValues({});
        final local = SyncLocal(await SharedPreferences.getInstance());
        await local.markLocal(at(20)); // меняли до входа
        final server = MemoryBackend()..stored = doc(at(10), theme: 'dark');
        var current = doc(SyncDoc.epoch, theme: 'light');
        final applied = <SyncDoc>[];
        final ctl = SyncController(
          local: local,
          capture: () async => current,
          apply: (d) async {
            applied.add(d);
            current = d;
          },
          clock: () => at(30),
        );
        await ctl.preferRemote();
        ctl.backend = server;
        await ctl.reconcile();
        expect(applied.single.theme, 'dark');
        expect(server.saves, 0);
      },
    );

    test('сбой сети: причина видна, правки не теряются, после связи статус очищается', () async {
      SharedPreferences.setMockInitialValues({});
      final local = SyncLocal(await SharedPreferences.getInstance());
      final ctl = SyncController(
        local: local,
        capture: () async => doc(SyncDoc.epoch),
        apply: (_) async {},
        clock: () => at(5),
      )..backend = _Broken();
      await ctl.reconcile();
      expect(ctl.problem, 'Нет связи с сервером');
      ctl.backend = MemoryBackend();
      await ctl.reconcile();
      expect(ctl.problem, isNull);
    });

    test('правка во время сверки не теряется: сверка повторяется', () async {
      SharedPreferences.setMockInitialValues({});
      final local = SyncLocal(await SharedPreferences.getInstance());
      late SyncController ctl;
      late _Hooked b;
      b = _Hooked(() async {
        // пока идёт первая сверка, приходит вторая
        if (b.loads == 1) unawaited(ctl.reconcile());
      });
      ctl = SyncController(
        local: local,
        capture: () async => doc(SyncDoc.epoch),
        apply: (_) async {},
        clock: () => at(5),
      )..backend = b;
      await ctl.reconcile();
      expect(b.loads, 2);
    });

    test('обновлённый вход сохраняется: токен обновления меняется при каждом обновлении', () async {
      final kept = <AccountSession>[];
      final client = MockClient(
        (r) async => http.Response(
          jsonEncode({
            'access_token': 'new',
            'refresh_token': 'ref2',
            'expires_in': 3600,
          }),
          200,
        ),
      );
      final b = AccountBackend(
        url: 'https://x',
        key: 'anon',
        client: client,
        session: AccountSession(
          'old',
          'ref',
          DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
          'a@b.ru',
        ),
        keep: (s) async => kept.add(s),
      );
      await b.refreshIfNeeded();
      expect(b.session!.access, 'new');
      expect(kept.single.refresh, 'ref2');
    });

    test('вход больше не действует — просьба войти заново', () async {
      final client = MockClient(
        (r) async => http.Response(jsonEncode({'error': 'invalid'}), 400),
      );
      final b = AccountBackend(
        url: 'https://x',
        key: 'anon',
        client: client,
        session: AccountSession(
          'old',
          'ref',
          DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
          'a@b.ru',
        ),
      );
      expect(
        () => b.refreshIfNeeded(),
        throwsA(
          isA<SyncError>().having(
            (e) => e.message,
            'message',
            'Войдите в аккаунт заново',
          ),
        ),
      );
    });
  });
}

/// Сервер, который не отвечает.
class _Broken implements SyncBackend {
  @override
  Future<SyncDoc?> load() async =>
      throw const SyncError('Нет связи с сервером');
  @override
  Future<void> save(SyncDoc d) async =>
      throw const SyncError('Нет связи с сервером');
}

/// Сервер, который даёт вызвать хук на каждой загрузке и считает их.
class _Hooked implements SyncBackend {
  _Hooked(this.onLoad);
  final Future<void> Function() onLoad;
  int loads = 0;
  @override
  Future<SyncDoc?> load() async {
    loads++;
    await onLoad();
    return null;
  }

  @override
  Future<void> save(SyncDoc d) async {}
}
