// Выход из аккаунта и отключение кода (ПРОЕКТ.md, раздел 2.4): настройки этого устройства сбрасываются к значениям
// по умолчанию, сервер и другие устройства не меняются, служебные ключи сверки обнуляются, несинхронизируемые не трогаются.
// Диалоги (только заголовок и кнопки): «Отмена» ничего не меняет, подтверждение сбрасывает.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/reminders.dart';
import 'package:starty/settings.dart';
import 'package:starty/state.dart';
import 'package:starty/sync.dart';

/// Сервер в памяти: вход, документ, журнал запросов.
class Server {
  SyncDoc? stored;
  final requests = <String>[];
  int n = 0;

  MockClient get client => MockClient((r) async {
    requests.add('${r.method} ${r.url.path}');
    final p = r.url.path;
    if (p.endsWith('/token')) {
      return http.Response(jsonEncode({'access_token': 'a$n', 'refresh_token': 'r', 'expires_in': 3600}), 200);
    }
    if (p.contains('load_settings')) {
      final d = stored;
      return http.Response(jsonEncode(d == null ? [] : [{'doc': d.toJson(), 'updated_at': d.updatedAt.toIso8601String()}]), 200);
    }
    if (p.contains('save_settings')) {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      n++;
      stored = SyncDoc.fromJson(body['doc'] as Map<String, dynamic>)
          .at(DateTime.utc(2026, 1, 1, 0, 0, n));
      return http.Response(jsonEncode(stored!.updatedAt.toIso8601String()), 200);
    }
    return http.Response('', 404);
  });
}

/// Значения по умолчанию, как их видит новый пользователь при первой установке.
void expectDefaults(AppState s) {
  expect(Prefs.rulesJson, isNull);
  expect(NotifyRules.fromJson(Prefs.rulesJson).toJson(), const NotifyRules().toJson());
  expect(Prefs.forcedOn, isEmpty);
  expect(Prefs.forcedOff, isEmpty);
  expect(Prefs.follow, isNull);
  expect(Prefs.followRussians, isTrue);
  expect(Prefs.followBelarusians, isTrue);
  expect(Prefs.kinds, isEmpty);
  expect(Prefs.tids, isEmpty);
  expect(Prefs.athletes, isEmpty);
  expect(Prefs.levels, isEmpty);
  expect(Prefs.scope, isEmpty);
  expect(Prefs.showDone, isTrue);
  expect(Prefs.regional, isFalse);
  expect(Prefs.liveMode, liveInstant);
  expect(Prefs.liveOverrides, isEmpty);
  expect(Prefs.theme, 'system');
  expect(Prefs.raw.getString('icon') ?? 'classic', 'classic');

  expect(s.rules.toJson(), const NotifyRules().toJson());
  expect(s.forcedOn, isEmpty);
  expect(s.forcedOff, isEmpty);
  expect(s.filters.any, isFalse);
  expect(s.showDone, isTrue);
  expect(s.regional, isFalse);
  expect(s.liveMode, liveInstant);
  expect(s.liveOverrides, isEmpty);
  expect(s.theme, ThemeMode.system);
}

/// Настройки, которые человек успел поменять (до входа в аккаунт).
Future<void> makeCustom() async {
  await Prefs.setRulesJson(const NotifyRules(on: false, lead: 30, skaters: true).toJson());
  await Prefs.setForced({'isu:a-1'}, {'isu:b-2'});
  await Prefs.setFollow(['Камила Валиева'], russians: false, belarusians: false);
  await Prefs.setFilters(const Filters({'women'}, {'ffkm:x'}, {'Камила Валиева'}, levels: {'junior'}, scope: {'intl'}));
  await Prefs.setShowDone(false);
  await Prefs.setRegional(true);
  await Prefs.setLiveMode(liveDelayed);
  await Prefs.setLiveOverrides({'isu:a-1': liveDelayed});
  await Prefs.setTheme('dark');
  await Prefs.raw.setString('icon', 'skate_teal');
}

/// Служебные ключи, которые не синхронизируются: выход их не трогает.
Future<void> makeLocalOnly() async {
  await Prefs.raw.setBool('n.mig2', true);
  await Prefs.raw.setBool('n.asked', true);
  await Prefs.raw.setString('w.sched', 'кэш');
  await Prefs.raw.setString('seenVersion', '1.0.22');
  await Prefs.raw.setString('deskNotes', 'заметка');
}

Future<void> freshPrefs() async {
  SharedPreferences.setMockInitialValues({});
  await Prefs.init();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await freshPrefs();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('выход сбрасывает настройки устройства, сервер не получает запросов, служебные ключи целы', () async {
    await makeCustom();
    await makeLocalOnly();
    final srv = Server();
    final s = AppState()..syncClient = srv.client;
    expect(await s.signInSync('a@b.ru', 'secret1'), isNull);
    // сверка при входе отправила прежние настройки на сервер (так и должно быть до выхода)
    expect(srv.stored!.theme, 'dark');
    expect(srv.stored!.follow, ['Камила Валиева']);
    expect(Prefs.raw.getString('sync.account'), isNotNull);

    srv.requests.clear();
    await s.signOutSync();

    expectDefaults(s);
    expect(s.syncOn, isFalse);
    expect(s.syncEmail, isNull);
    expect(Prefs.raw.getString('sync.account'), isNull);
    expect(Prefs.raw.getString('sync.pending'), isNull);
    expect(Prefs.raw.getString('sync.base'), isNull);
    expect(Prefs.raw.getString('sync.icon.doc'), isNull);
    expect(Prefs.raw.getString('sync.icon.dev'), isNull);

    // служебные ключи не тронуты
    expect(Prefs.raw.getBool('n.mig2'), isTrue);
    expect(Prefs.raw.getBool('n.asked'), isTrue);
    expect(Prefs.raw.getString('w.sched'), 'кэш');
    expect(Prefs.raw.getString('seenVersion'), '1.0.22');
    expect(Prefs.raw.getString('deskNotes'), 'заметка');

    // сервер ничего не получил, и отложенная сверка от прежних правок тоже
    await Future<void>.delayed(const Duration(seconds: 3, milliseconds: 200));
    expect(srv.requests, isEmpty, reason: 'после выхода на сервер не должно уйти ни одного запроса');
    expect(srv.stored!.theme, 'dark', reason: 'документ на сервере не меняется');
    s.sync.dispose();
  });

  test('вход в пустой аккаунт после выхода не отправляет прежних настроек', () async {
    await makeCustom();
    final first = Server();
    final s = AppState()..syncClient = first.client;
    await s.signInSync('a@b.ru', 'secret1');
    await s.signOutSync();

    final empty = Server();
    s.syncClient = empty.client;
    expect(await s.signInSync('new@b.ru', 'secret1'), isNull);

    final doc = empty.stored!;
    expect(doc.theme, 'system');
    expect(doc.follow, isNull);
    expect(doc.followRussians, isTrue);
    expect(doc.followBelarusians, isTrue);
    expect(doc.showDone, isTrue);
    expect(doc.regional, isFalse);
    expect(doc.liveMode, liveInstant);
    expect(doc.liveOverrides, isEmpty);
    expect(doc.icon, 'classic');
    expect(doc.forcedOn, isEmpty);
    expect(doc.forcedOff, isEmpty);
    expect(doc.filters.values.every((v) => v.isEmpty), isTrue);
    expect(NotifyRules.fromJson(doc.rules).toJson(), const NotifyRules().toJson());
    s.sync.dispose();
  });

  test('значок: если система не поставила значок, выход всё равно сбрасывает остальное', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('starty/icon');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'get') return 'skate_teal';
      if (call.method == 'set') throw PlatformException(code: 'nope');
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await makeCustom();
    final s = AppState()..syncClient = Server().client;
    await s.signInSync('a@b.ru', 'secret1');
    await s.signOutSync();
    expect(Prefs.theme, 'system');
    expect(Prefs.showDone, isTrue);
    s.sync.dispose();
  });

  // Строки «Выйти с этого устройства» и «Отключить на этом устройстве» в «Аккаунте» видны только в сборке с адресом
  // сервера (syncConfigured — из --dart-define), поэтому диалог проверяем напрямую: та же цепочка, что в строке.
  testWidgets('диалоги выхода и отключения: «Отмена» ничего не меняет, подтверждение сбрасывает', (tester) async {
    await makeCustom();
    final s = AppState();
    final answers = <bool>[];
    var title = 'Выйти из аккаунта?';
    var action = 'Выйти';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () async => answers.add(await confirmDisconnect(c, title: title, action: action)),
              child: const Text('открыть'),
            ),
          ),
        ),
      ),
    );

    // диалог: только заголовок и кнопки, пояснительного текста нет
    Future<void> open(String t, String a) async {
      title = t;
      action = a;
      await tester.tap(find.text('открыть'));
      await tester.pumpAndSettle();
      expect(find.text(t), findsOneWidget);
      expect(find.text(a), findsOneWidget);
      expect(find.text('Отмена'), findsOneWidget);
      expect(find.textContaining('сбрасы'), findsNothing);
      expect(find.textContaining('войдите снова'), findsNothing);
    }

    // выход из аккаунта: «Отмена» ничего не меняет
    await open('Выйти из аккаунта?', 'Выйти');
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.text('Выйти из аккаунта?'), findsNothing);
    expect(answers, [false]);
    expect(Prefs.theme, 'dark');
    expect(Prefs.showDone, isFalse);
    expect(Prefs.liveMode, liveDelayed);

    // отключение кода: «Отмена» тоже ничего не меняет
    await open('Отключить код?', 'Отключить');
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(answers, [false, false]);
    expect(Prefs.theme, 'dark');

    // подтверждение: ответ «да», сам сброс — в настоящем цикле событий
    await open('Отключить код?', 'Отключить');
    await tester.tap(find.text('Отключить'));
    await tester.pumpAndSettle();
    expect(answers, [false, false, true]);
    await tester.runAsync(() => s.signOutSync());
    expectDefaults(s);
    // переопределение платформы из setUp снимаем до проверки инвариантов теста
    debugDefaultTargetPlatformOverride = null;
  });

  test('отключение кода сбрасывает настройки устройства по тем же правилам, сервер не получает запросов', () async {
    await makeCustom();
    await makeLocalOnly();
    final srv = Server();
    final s = AppState()..syncClient = srv.client;
    expect(await s.createSyncCode(), isNull);
    expect(Prefs.raw.getString('sync.code'), isNotNull);
    expect(srv.stored!.theme, 'dark');

    srv.requests.clear();
    await s.disconnectSync();

    expectDefaults(s);
    expect(s.syncOn, isFalse);
    expect(s.syncCodeOn, isFalse);
    expect(Prefs.raw.getString('sync.code'), isNull);
    expect(Prefs.raw.getString('sync.pending'), isNull);
    expect(Prefs.raw.getString('sync.base'), isNull);
    expect(Prefs.raw.getBool('n.mig2'), isTrue);
    expect(Prefs.raw.getString('seenVersion'), '1.0.22');

    await Future<void>.delayed(const Duration(seconds: 3, milliseconds: 200));
    expect(srv.requests, isEmpty, reason: 'после отключения на сервер не должно уйти ни одного запроса');
    expect(srv.stored!.theme, 'dark', reason: 'документ на сервере не меняется');
    s.sync.dispose();
  });
}
