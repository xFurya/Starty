// Два входа в один аккаунт (ПРОЕКТ.md, раздел 2.4): код → привязать почту, почта → создать или ввести код,
// ошибки сервера, старая схема без link_code. Сервер в памяти повторяет правила tools/sync/schema.sql.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/state.dart';
import 'package:starty/sync.dart';

SyncDoc mk(String theme) => SyncDoc(
  updatedAt: SyncDoc.epoch,
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
);

/// Сервер: аккаунт один (вход любой почтой), коды, привязки, как в schema.sql.
class Srv {
  SyncDoc? account; // user_settings
  final codes = <String, SyncDoc>{}; // code_settings
  final links = <String>{}; // code_links этого аккаунта
  String? takenElsewhere; // хэш, привязанный к чужому аккаунту
  bool oldSchema = false; // нет link_code / has_code_link
  int n = 0;
  final log = <String>[];

  DateTime get _t => DateTime.utc(2026, 1, 1, 0, 0, ++n);

  List<Map<String, dynamic>> _rows(SyncDoc? d) =>
      d == null ? [] : [{'doc': d.toJson(), 'updated_at': d.updatedAt.toIso8601String()}];

  MockClient get client => MockClient((r) async {
    final p = r.url.path;
    log.add(p.split('/').last);
    if (p.endsWith('/token')) {
      return http.Response(jsonEncode({'access_token': 'a', 'refresh_token': 'r', 'expires_in': 3600}), 200);
    }
    final body = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    final h = body['code_hash'] as String?;
    if (p.endsWith('/load_settings')) return http.Response(jsonEncode(_rows(account)), 200);
    if (p.endsWith('/save_settings')) {
      account = SyncDoc.fromJson(body['doc'] as Map<String, dynamic>).at(_t);
      return http.Response(jsonEncode(account!.updatedAt.toIso8601String()), 200);
    }
    if (p.endsWith('/load_settings_by_code')) {
      return http.Response(jsonEncode(_rows(links.contains(h) ? account : codes[h])), 200);
    }
    if (p.endsWith('/save_settings_by_code')) {
      final d = SyncDoc.fromJson(body['doc'] as Map<String, dynamic>).at(_t);
      if (links.contains(h)) {
        account = d;
      } else {
        codes[h!] = d;
      }
      return http.Response(jsonEncode(d.updatedAt.toIso8601String()), 200);
    }
    if (p.endsWith('/has_code_link')) {
      return oldSchema ? http.Response('{}', 404) : http.Response(jsonEncode(links.isNotEmpty), 200);
    }
    if (p.endsWith('/link_code')) {
      if (oldSchema) return http.Response(jsonEncode({'code': 'PGRST202', 'message': 'Could not find the function'}), 404);
      if (h == takenElsewhere) return http.Response(jsonEncode({'code': 'P0001', 'message': 'code_taken'}), 400);
      if (!links.contains(h)) {
        links.clear(); // у аккаунта один код
        final c = codes.remove(h);
        if (c != null && (account == null || c.updatedAt.isAfter(account!.updatedAt))) account = c;
        links.add(h!);
      }
      return http.Response(jsonEncode(account?.updatedAt.toIso8601String()), 200);
    }
    return http.Response('', 404);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('код → привязать почту: документ не теряется, правка не пропадает, устройство на почте', () async {
    final srv = Srv();
    final s = AppState()..syncClient = srv.client;
    await s.setTheme(ThemeMode.dark);
    expect(await s.createSyncCode(), isNull);
    final code = s.syncCode!;
    final hash = CodeBackend.hashOf(code);
    expect(srv.codes[hash]!.theme, 'dark');
    // правка после последней сверки — ещё не отправлена
    await s.setTheme(ThemeMode.light);
    await s.sync.touch();
    expect(SyncLocal(Prefs.raw).state.pending, isTrue);

    expect(await s.linkMail('a@b.ru', 'secret1'), isNull);
    expect(srv.log, contains('link_code'));
    expect(srv.codes, isEmpty); // документ кода перенесён
    expect(srv.account!.theme, 'light'); // правка дошла до сервера до привязки
    expect(srv.links, {hash});
    expect(s.syncEmail, 'a@b.ru');
    expect(s.syncCode, isNull);
    expect(s.syncLinkedCode, code);
    expect(s.sync.backend, isA<AccountBackend>());
    expect(SyncLocal(Prefs.raw).state.pending, isFalse);
    expect(Prefs.theme, 'light');

    // другое устройство по этому коду работает с документом аккаунта
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
    final other = AppState()..syncClient = srv.client;
    expect(await other.enterSyncCode(code), isNull);
    expect(Prefs.theme, 'light');
    s.sync.dispose();
    other.sync.dispose();
  });

  test('код → почта: в аккаунте документ новее — устройство берёт его, а не затирает', () async {
    final srv = Srv();
    final s = AppState()..syncClient = srv.client;
    await s.setTheme(ThemeMode.dark);
    await s.createSyncCode();
    srv.account = mk('light').at(DateTime.utc(2030)); // сохранён позже документа кода
    expect(await s.linkMail('a@b.ru', 'secret1'), isNull);
    expect(srv.account!.theme, 'light');
    expect(Prefs.theme, 'light');
    s.sync.dispose();
  });

  test('регистрация с подтверждением почты: остаёмся на коде, привязка не вызывалась', () async {
    final srv = Srv();
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/signup')) return http.Response(jsonEncode({'id': 'u'}), 200);
      return srv.client.send(http.Request(r.method, r.url)..body = r.body).then(http.Response.fromStream);
    });
    final s = AppState()..syncClient = client;
    await s.createSyncCode();
    expect(await s.linkMail('a@b.ru', 'secret1', create: true), kConfirmMail);
    expect(srv.log, isNot(contains('link_code')));
    expect(s.syncCode, isNotNull);
    expect(s.syncEmail, isNull);
    s.sync.dispose();
  });

  test('почта → создать код: link_code вызван, код запомнен, прежний заменён', () async {
    final srv = Srv();
    final s = AppState()..syncClient = srv.client;
    await s.setTheme(ThemeMode.dark);
    expect(await s.signInSync('a@b.ru', 'secret1'), isNull);
    expect(await s.createLinkedCode(), isNull);
    final first = s.syncLinkedCode!;
    expect(first.length, 16);
    expect(srv.links, {CodeBackend.hashOf(first)});
    expect(s.syncEmail, 'a@b.ru'); // остались на почте
    expect(await s.createLinkedCode(), isNull);
    expect(s.syncLinkedCode, isNot(first));
    expect(srv.links, {CodeBackend.hashOf(s.syncLinkedCode!)});
    expect(srv.account!.theme, 'dark');
    s.sync.dispose();
  });

  test('почта → чужой код: привязывается, документ кода (новее) приходит на устройство', () async {
    final srv = Srv();
    const other = 'ABCDEFGH23456789';
    srv.codes[CodeBackend.hashOf(other)] = mk('light').at(DateTime.utc(2030));
    final s = AppState()..syncClient = srv.client;
    await s.setTheme(ThemeMode.dark);
    expect(await s.signInSync('a@b.ru', 'secret1'), isNull);
    expect(await s.linkEnteredCode('abcd efgh-2345 6789'), isNull);
    expect(srv.links, {CodeBackend.hashOf(other)});
    expect(srv.account!.theme, 'light');
    expect(Prefs.theme, 'light');
    expect(s.syncLinkedCode, other);
    s.sync.dispose();
  });

  test('почта → ввод кода: нет такого кода / не 16 знаков / код чужого аккаунта', () async {
    final srv = Srv();
    final s = AppState()..syncClient = srv.client;
    await s.signInSync('a@b.ru', 'secret1');
    expect(await s.linkEnteredCode('ABC'), 'Код — 16 знаков');
    expect(await s.linkEnteredCode('ABCDEFGH23456789'), 'Такого кода нет на сервере');
    expect(srv.log, isNot(contains('link_code')));
    const taken = 'ZZZZZZZZ23456789';
    srv.codes[CodeBackend.hashOf(taken)] = mk('dark');
    srv.takenElsewhere = CodeBackend.hashOf(taken);
    expect(await s.linkEnteredCode(taken), 'Код уже привязан к другому аккаунту');
    expect(s.syncLinkedCode, isNull);
    s.sync.dispose();
  });

  test('старая схема (link_code → 404): понятная ошибка, вход по коду и по почте целы', () async {
    final srv = Srv()..oldSchema = true;
    final s = AppState()..syncClient = srv.client;
    await s.setTheme(ThemeMode.dark);
    await s.createSyncCode();
    final code = s.syncCode!;
    expect(await s.linkMail('a@b.ru', 'secret1'), kOldSchema);
    // остались на коде, настройки на месте
    expect(s.syncCode, code);
    expect(s.syncEmail, isNull);
    expect(s.sync.backend, isA<CodeBackend>());
    expect(Prefs.theme, 'dark');
    expect(srv.codes[CodeBackend.hashOf(code)]!.theme, 'dark');

    // обычный вход по почте без привязки работает как раньше
    await s.disconnectSync();
    expect(await s.signInSync('a@b.ru', 'secret1'), isNull);
    expect(await s.createLinkedCode(), kOldSchema);
    expect(s.syncLinkedCode, isNull);
    expect(s.syncOn, isTrue);
    await s.refreshCodeLink(); // has_code_link → 404: ничего не утверждаем
    expect(s.codeLinked, isNull);
    s.sync.dispose();
  });

  test('refreshCodeLink: сервер знает о привязке, а устройству код неизвестен', () async {
    final srv = Srv()..links.add('x' * 64);
    final s = AppState()..syncClient = srv.client;
    await s.signInSync('a@b.ru', 'secret1');
    await s.refreshCodeLink();
    expect(s.codeLinked, isTrue);
    expect(s.syncLinkedCode, isNull);
    s.sync.dispose();
  });

  test('выход сбрасывает запомненный код', () async {
    final srv = Srv();
    final s = AppState()..syncClient = srv.client;
    await s.signInSync('a@b.ru', 'secret1');
    await s.createLinkedCode();
    await s.signOutSync();
    expect(s.syncLinkedCode, isNull);
    expect(s.codeLinked, isNull);
  });

  test('пока сервер не ответил о привязке — «не проверено»; ответ или ошибка снимают ожидание', () async {
    final srv = Srv();
    final s = AppState()..syncClient = srv.client;
    await s.signInSync('a@b.ru', 'secret1');
    expect(s.codeLinkChecked, isFalse);
    await s.refreshCodeLink();
    expect(s.codeLinkChecked, isTrue);
    expect(s.codeLinked, isFalse);
    // ошибка/404: проверено, но привязка неизвестна — интерфейс вернётся к «Создать код»
    await s.signOutSync();
    expect(s.codeLinkChecked, isFalse);
    srv.oldSchema = true;
    await s.signInSync('a@b.ru', 'secret1');
    await s.refreshCodeLink();
    expect(s.codeLinkChecked, isTrue);
    expect(s.codeLinked, isNull);
    s.sync.dispose();
  });
}
