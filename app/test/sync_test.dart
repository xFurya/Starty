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

/// Память вместо сервера: один документ на всех. Время сохранения ставит «сервер» — счётчик,
/// растёт на каждом save (как updated_at на сервере), и это время возвращается отправителю.
class MemoryBackend implements SyncBackend {
  SyncDoc? stored;
  int saves = 0;
  @override
  Future<SyncDoc?> load() async => stored;
  @override
  Future<DateTime> save(SyncDoc d) async {
    saves++;
    final t = at(1000 + saves);
    stored = d.at(t);
    return t;
  }
}

void main() {
  group('правило слияния', () {
    test('сервер пуст — отправить свои настройки', () {
      expect(
        decideSync(remote: null, baseAt: at(0), pending: false),
        SyncAction.push,
      );
    });
    test('ничего не менялось — ничего не делать', () {
      expect(
        decideSync(remote: at(5), baseAt: at(5), pending: false),
        SyncAction.none,
      );
    });
    test('на сервере новее, у нас тихо — взять с сервера', () {
      expect(
        decideSync(remote: at(9), baseAt: at(5), pending: false),
        SyncAction.pull,
      );
    });
    test('у нас правка — отправить', () {
      expect(
        decideSync(remote: at(5), baseAt: at(5), pending: true),
        SyncAction.push,
      );
    });
    test('у нас правка, на сервере новее — правка побеждает: кто сохранил последним', () {
      expect(
        decideSync(remote: at(9), baseAt: at(5), pending: true),
        SyncAction.push,
      );
    });
    test('сервер пуст, а правка есть — отправить', () {
      expect(
        decideSync(remote: null, baseAt: at(5), pending: true),
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
      expect(d.follow, isNull); // битое поле — «по умолчанию», а не явный пустой выбор
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
    test('сохранение шлёт хэш и документ, но не сам код, и возвращает время от сервера', () async {
      late http.Request sent;
      final client = MockClient((r) async {
        sent = r;
        return http.Response(jsonEncode('2026-10-15T10:02:00Z'), 200);
      });
      final b = CodeBackend(
        url: 'https://x.supabase.co',
        key: 'anon',
        code: 'ABCD2345EFGH6789',
        client: client,
      );
      expect(await b.save(doc(at(2))), at(2));
      expect(sent.url.path, '/rest/v1/rpc/save_settings_by_code');
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['code_hash'], CodeBackend.hashOf('ABCD2345EFGH6789'));
      expect(sent.body.contains('ABCD2345EFGH6789'), isFalse);
      expect(sent.headers['apikey'], 'anon');
    });
    test('сервер не сказал время сохранения — ошибка, а не тихий успех', () async {
      final client = MockClient((r) async => http.Response('', 200));
      final b = CodeBackend(
        url: 'https://x',
        key: 'anon',
        code: 'ABCD2345EFGH6789',
        client: client,
      );
      await expectLater(
        () => b.save(doc(at(2))),
        throwsA(
          isA<SyncError>().having(
            (e) => e.message,
            'message',
            'Сервер не сообщил время сохранения',
          ),
        ),
      );
    });
    test('загрузка: время документа — колонка updated_at строки, а не поле в JSON', () async {
      final client = MockClient(
        (r) async => http.Response(
          jsonEncode([
            {
              // в JSON старое время; колонка сервера — настоящее
              'doc': doc(at(99), theme: 'light').toJson(),
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
              {'doc': doc(at(6)).toJson(), 'updated_at': '2026-10-15T10:06:00Z'},
            ]),
            200,
          );
        }
        return http.Response(jsonEncode('2026-10-15T10:07:00Z'), 200);
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
      expect(await b.save(doc(at(7))), at(7));
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
      await local.markPending(true);
      current = doc(SyncDoc.epoch, theme: 'light');
      await ctl.reconcile();
      expect(server.stored!.theme, 'light');
      // база — время, которое вернул сервер, а не часы устройства
      expect(local.state.baseAt, server.stored!.updatedAt);
      expect(local.state.pending, isFalse);
    });

    test('своя правка побеждает, даже если на сервере новее: кто сохранил последним', () async {
      server.stored = doc(at(10));
      await ctl.reconcile();
      // на сервере поменяли, здесь — правка; она уходит и перезаписывает
      server.stored = doc(at(12), theme: 'dark');
      await local.markPending(true);
      current = doc(SyncDoc.epoch, theme: 'light');
      await ctl.reconcile();
      expect(server.stored!.theme, 'light');
      expect(local.state.pending, isFalse);
    });
  });

  group('вход в существующие настройки и сбои', () {
    test(
      'вход в чужие настройки: прежние правки не уходят, берём серверные',
      () async {
        SharedPreferences.setMockInitialValues({});
        final local = SyncLocal(await SharedPreferences.getInstance());
        await local.markPending(true); // меняли до входа
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
        expect(local.state.pending, isFalse);
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

    test('сбой сети при несохранённой правке: флаг остаётся, правка уходит при следующей сверке', () async {
      SharedPreferences.setMockInitialValues({});
      final local = SyncLocal(await SharedPreferences.getInstance());
      final ctl = SyncController(
        local: local,
        capture: () async => doc(SyncDoc.epoch, theme: 'dark'),
        apply: (_) async {},
        clock: () => at(5),
      )..backend = _BrokenSave();
      await ctl.touch();
      await ctl.reconcile();
      expect(ctl.problem, 'Нет связи с сервером');
      expect(local.state.pending, isTrue);
      final server = MemoryBackend();
      ctl.backend = server;
      await ctl.reconcile();
      ctl.dispose();
      expect(ctl.problem, isNull);
      expect(server.stored!.theme, 'dark');
      expect(local.state.pending, isFalse);
    });

    test('правка во время отправки не теряется: флаг остаётся, сверка её отправит', () async {
      SharedPreferences.setMockInitialValues({});
      final local = SyncLocal(await SharedPreferences.getInstance());
      late SyncController ctl;
      var current = doc(SyncDoc.epoch);
      // на первой отправке человек меняет тему (уже после захвата): правка и вторая сверка
      final server = _OnSave((n) async {
        if (n != 1) return;
        current = doc(SyncDoc.epoch, theme: 'light');
        await ctl.touch();
        unawaited(ctl.reconcile());
      });
      ctl = SyncController(
        local: local,
        capture: () async => current,
        apply: (_) async {},
        clock: () => at(6),
      )..backend = server;
      await local.markPending(true);
      current = doc(SyncDoc.epoch, theme: 'dark');
      await ctl.reconcile();
      // вторая отправка — с правкой; ждём, пока флаг снимется
      for (var i = 0; i < 40 && (server.saves < 2 || local.state.pending); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      ctl.dispose();
      expect(server.saves, 2);
      expect(server.stored!.theme, 'light');
      expect(local.state.pending, isFalse);
    });

    test('смена аккаунта во время отправки: база и правки нового аккаунта не портятся', () async {
      SharedPreferences.setMockInitialValues({});
      final local = SyncLocal(await SharedPreferences.getInstance());
      await local.markBase(at(1));
      await local.markPending(true);
      var current = doc(at(5), theme: 'light');
      final applied = <SyncDoc>[];
      late SyncController ctl;
      final accountB = MemoryBackend()..stored = doc(at(4), theme: 'dark');
      // пока документ первого аккаунта уходит, человек входит во второй
      final accountA = _OnSave((n) async {
        if (n != 1) return;
        await ctl.preferRemote();
        ctl.backend = accountB;
        unawaited(ctl.reconcile());
      });
      accountA.stored = doc(at(3), theme: 'system');
      ctl = SyncController(
        local: local,
        capture: () async => current,
        apply: (d) async {
          applied.add(d);
          current = d;
        },
        clock: () => at(8),
      )..backend = accountA;
      await ctl.reconcile();
      for (var i = 0; i < 40 && applied.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(applied.map((d) => d.theme), ['dark']);
      expect(local.state.baseAt, at(4));
      expect(accountB.saves, 0);
    });

    test('смена аккаунта во время загрузки: документ первого аккаунта не применяется', () async {
      SharedPreferences.setMockInitialValues({});
      final local = SyncLocal(await SharedPreferences.getInstance());
      final applied = <SyncDoc>[];
      late SyncController ctl;
      final accountB = MemoryBackend()..stored = doc(at(4), theme: 'dark');
      // вход меняют, пока первый аккаунт отдаёт документ
      final accountA = _OnLoad(() async {
        await ctl.preferRemote();
        ctl.backend = accountB;
        unawaited(ctl.reconcile());
      });
      accountA.stored = doc(at(3), theme: 'system');
      ctl = SyncController(
        local: local,
        capture: () async => doc(SyncDoc.epoch),
        apply: (d) async => applied.add(d),
        clock: () => at(8),
      )..backend = accountA;
      await ctl.reconcile();
      for (var i = 0; i < 40 && applied.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(applied.map((d) => d.theme), ['dark']);
      expect(local.state.baseAt, at(4));
    });

    test('часы устройства отстают: правка всё равно уходит (порядок задаёт сервер)', () async {
      SharedPreferences.setMockInitialValues({});
      final local = SyncLocal(await SharedPreferences.getInstance());
      var now = at(0);
      var current = doc(SyncDoc.epoch);
      final server = MemoryBackend()..stored = doc(at(10));
      final ctl = SyncController(
        local: local,
        capture: () async => current,
        apply: (d) async => current = d,
        clock: () => now,
      )..backend = server;
      await ctl.reconcile(); // сверились с документом на 10:10
      expect(local.state.baseAt, at(10));
      // часы устройства на час позади: раньше они мешали бы отправке, теперь — нет
      now = at(-50);
      current = doc(SyncDoc.epoch, theme: 'light');
      await ctl.touch();
      await ctl.reconcile();
      ctl.dispose();
      expect(server.saves, 1);
      expect(server.stored!.theme, 'light');
      expect(local.state.baseAt, server.stored!.updatedAt);
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

  group('два устройства, один сервер', () {
    test('последнее сохранение побеждает; первое устройство потом подтягивает', () async {
      // два устройства — два хранилища настроек: у каждого свой кэш, общего состояния нет
      SharedPreferences.setMockInitialValues({});
      final localA = SyncLocal(await SharedPreferences.getInstance());
      SharedPreferences.setMockInitialValues({});
      final localB = SyncLocal(await SharedPreferences.getInstance());
      final server = MemoryBackend();
      var docA = doc(SyncDoc.epoch, theme: 'dark');
      var docB = doc(SyncDoc.epoch);
      final ctlA = SyncController(
        local: localA,
        capture: () async => docA,
        apply: (d) async {
          docA = d;
        },
        clock: () => at(0),
      )..backend = server;
      final ctlB = SyncController(
        local: localB,
        capture: () async => docB,
        apply: (d) async {
          docB = d;
        },
        clock: () => at(0),
      )..backend = server;

      // A создаёт документ, B получает его
      await ctlA.reconcile();
      await ctlB.reconcile();
      expect(docB.theme, 'dark');

      // A меняет тему и сохраняет
      docA = doc(SyncDoc.epoch, theme: 'light');
      await ctlA.touch();
      await ctlA.reconcile();
      expect(server.stored!.theme, 'light');

      // B меняет тему и сохраняет позже: его сохранение перезаписывает сохранение A
      docB = doc(SyncDoc.epoch, theme: 'system');
      await ctlB.touch();
      await ctlB.reconcile();
      expect(server.stored!.theme, 'system');

      // A подтягивает то, что сохранил B последним
      await ctlA.reconcile();
      ctlA.dispose();
      ctlB.dispose();
      expect(docA.theme, 'system');
      expect(localA.state.baseAt, server.stored!.updatedAt);
      expect(localA.state.pending, isFalse);
    });
  });
}

/// Сервер, который не отвечает.
class _Broken implements SyncBackend {
  @override
  Future<SyncDoc?> load() async =>
      throw const SyncError('Нет связи с сервером');
  @override
  Future<DateTime> save(SyncDoc d) async =>
      throw const SyncError('Нет связи с сервером');
}

/// Загрузка проходит, а сохранение — нет: связь пропала на отправке.
class _BrokenSave extends MemoryBackend {
  @override
  Future<DateTime> save(SyncDoc d) async =>
      throw const SyncError('Нет связи с сервером');
}

/// Память, у которой хук вызывается перед ответом на загрузку (вход меняют, пока идёт загрузка).
class _OnLoad extends MemoryBackend {
  _OnLoad(this.onLoad);
  final Future<void> Function() onLoad;
  @override
  Future<SyncDoc?> load() async {
    final d = await super.load();
    await onLoad();
    return d;
  }
}

/// Память, которая после каждой отправки вызывает хук (номер отправки — с 1): в этот момент
/// человек меняет настройки или входит в другой аккаунт.
class _OnSave extends MemoryBackend {
  _OnSave(this.onSave);
  final Future<void> Function(int n) onSave;
  @override
  Future<DateTime> save(SyncDoc d) async {
    final t = await super.save(d);
    await onSave(saves);
    return t;
  }
}
