// Страница «Аккаунт»: состояния (почта + код, почта без кода, только код, не вошёл, ошибка статуса),
// копирование кода, меню «Заменить код», выход, листы входа и матрица ширин/масштабов/тем без переполнений.
// Сервер в памяти (как в sync_link_test), шрифт Manrope — настоящий, чтобы замеры были честными.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoAlertDialog, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/settings.dart';
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
  bool silent = false; // has_code_link не отвечает
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
      if (silent) return Completer<http.Response>().future;
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

Future<void> _manrope() async {
  final l = FontLoader('Manrope');
  for (final f in Directory('assets/fonts').listSync().whereType<File>().where((f) => f.path.contains('Manrope'))) {
    l.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await l.load();
}

enum Mode { emailCode, emailLinkedUnknown, emailNoCode, codeOnly, out }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_manrope);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
  });

  /// Состояние приложения в нужном виде; сетевые шаги — в настоящем цикле событий.
  Future<(AppState, Srv)> make(WidgetTester t, Mode m) async {
    final srv = Srv();
    final s = AppState()..syncClient = srv.client;
    addTearDown(s.sync.dispose);
    await t.runAsync(() async {
      switch (m) {
        case Mode.emailCode:
          await s.signInSync('anna@example.com', 'secret1');
          await s.createLinkedCode();
        case Mode.emailLinkedUnknown:
          await s.signInSync('anna@example.com', 'secret1');
          srv.links.add('someone'); // сервер знает о привязке, а этому устройству код не известен
        case Mode.emailNoCode:
          await s.signInSync('anna@example.com', 'secret1');
        case Mode.codeOnly:
          await s.createSyncCode();
        case Mode.out:
          break;
      }
    });
    return (s, srv);
  }

  Future<void> show(WidgetTester t, AppState s, {double width = 390, double scale = 1.0, Brightness b = Brightness.light}) async {
    t.view.physicalSize = Size(width * 3, 900 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        theme: ThemeData(brightness: b, fontFamily: 'Manrope'),
        builder: (c, nav) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: nav!,
        ),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    openAccount(t.element(find.byType(Scaffold)), s);
    await t.pumpAndSettle();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
  }

  testWidgets('почта и известный код: шапка, почта, код с копированием, выход', (t) async {
    final (s, _) = await make(t, Mode.emailCode);
    await show(t, s);
    expect(find.text('anna@example.com'), findsNWidgets(2)); // шапка и строка «Почта»
    expect(find.text('A'), findsOneWidget);
    expect(find.textContaining('Сохранено в'), findsOneWidget);
    expect(find.text('СПОСОБЫ ВХОДА'), findsOneWidget);
    expect(find.text('Почта'), findsOneWidget);
    expect(find.text('Код'), findsOneWidget);
    expect(find.text(RegExp(r'^[A-Z0-9]{4} [A-Z0-9]{4} [A-Z0-9]{4} [A-Z0-9]{4}$').pattern), findsNothing);
    expect(find.byIcon(CupertinoIcons.doc_on_doc), findsOneWidget);
    expect(find.text('Выйти'), findsOneWidget);
    for (final gone in ['Обновить', 'Другой код', 'Привязать', 'Создать новый код', 'Состояние']) {
      expect(find.text(gone), findsNothing);
    }
    expect(t.takeException(), isNull);
  });

  testWidgets('почта, код привязан, но устройству не известен: «Привязан»', (t) async {
    final (s, _) = await make(t, Mode.emailLinkedUnknown);
    await show(t, s);
    expect(find.text('Привязан'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.doc_on_doc), findsNothing);
  });

  testWidgets('почта без кода: «Создать код» создаёт и показывает код', (t) async {
    final (s, srv) = await make(t, Mode.emailNoCode);
    await show(t, s);
    expect(find.text('Создать код'), findsOneWidget);
    await t.tap(find.text('Создать код'));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    expect(s.syncLinkedCode, isNotNull);
    expect(srv.links, isNotEmpty);
    expect(find.text('Создать код'), findsNothing);
    expect(find.byIcon(CupertinoIcons.doc_on_doc), findsOneWidget);
  });

  testWidgets('пока сервер не ответил о привязке, справа «…» и действий нет', (t) async {
    final (s, srv) = await make(t, Mode.emailNoCode);
    srv.silent = true; // проверка привязки не отвечает
    s.codeLinkChecked = false;
    s.codeLinked = null;
    t.view.physicalSize = const Size(390 * 3, 900 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: const Scaffold(body: SizedBox())));
    openAccount(t.element(find.byType(Scaffold)), s);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('…'), findsOneWidget);
    expect(find.text('Создать код'), findsNothing);
    await t.pump(const Duration(seconds: 21)); // таймаут молчащего запроса
  });

  testWidgets('только код: значок #, «Вход по коду», привязка почты, выход', (t) async {
    final (s, _) = await make(t, Mode.codeOnly);
    await show(t, s);
    expect(find.text('Вход по коду'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.number), findsWidgets);
    expect(find.text('Привязать почту'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.doc_on_doc), findsOneWidget);
    expect(find.text('Выйти'), findsOneWidget);

    await t.tap(find.text('Привязать почту'));
    await t.pumpAndSettle();
    expect(find.text('Пароль'), findsOneWidget);
    expect(find.text('Регистрация'), findsOneWidget);
  });

  testWidgets('не вошёл: «Вход не выполнен» и две строки-действия, листы входа', (t) async {
    final (s, srv) = await make(t, Mode.out);
    await show(t, s);
    expect(find.text('Вход не выполнен'), findsOneWidget);
    expect(find.text('Войти по почте'), findsOneWidget);
    expect(find.text('Войти по коду'), findsOneWidget);
    expect(find.text('Выйти'), findsNothing);

    await t.tap(find.text('Войти по почте'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Почта'), 'anna@example.com');
    await t.enterText(find.widgetWithText(TextField, 'Пароль'), 'secret1');
    await t.tap(find.text('Войти'));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    expect(s.syncEmail, 'anna@example.com');
    expect(find.text('Пароль'), findsNothing); // лист закрылся
    expect(find.text('СПОСОБЫ ВХОДА'), findsOneWidget);
    expect(srv.log, contains('token'));
  });

  testWidgets('лист «Войти по коду»: поле, «Войти» и «Создать код» без почты', (t) async {
    final (s, _) = await make(t, Mode.out);
    await show(t, s);
    await t.tap(find.text('Войти по коду'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Код'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Почта'), findsNothing);
    await t.tap(find.text('Создать код'));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    expect(s.syncCode, isNotNull);
    expect(find.text('Вход по коду'), findsOneWidget);
  });

  testWidgets('ошибка статуса: текст ошибки и «Повторить», который сверяет заново', (t) async {
    final (s, srv) = await make(t, Mode.emailCode);
    s.sync.problem = 'Нет связи с сервером';
    s.sync.onChange!();
    await show(t, s);
    expect(find.text('Нет связи с сервером'), findsOneWidget);
    expect(find.textContaining('Сохранено в'), findsNothing);
    expect(find.text('Повторить'), findsOneWidget);
    final size = t.getSize(find.widgetWithText(TextButton, 'Повторить'));
    expect(size.height, greaterThanOrEqualTo(44));
    srv.log.clear();
    await t.tap(find.text('Повторить'));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    expect(srv.log, contains('load_settings'));
    expect(find.text('Повторить'), findsNothing);
    expect(find.textContaining('Сохранено в'), findsOneWidget);
  });

  testWidgets('копирование: весь ряд копирует код и говорит «Скопировано»', (t) async {
    final (s, _) = await make(t, Mode.emailCode);
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await show(t, s);
    await t.tap(find.text('Код'));
    await t.pump();
    expect(copied, s.syncLinkedCode);
    expect(find.text('Скопировано'), findsOneWidget);
  });

  testWidgets('долгое нажатие на код: «Заменить код», подтверждение только заголовком', (t) async {
    final (s, srv) = await make(t, Mode.emailCode);
    await show(t, s);
    final old = s.syncLinkedCode!;
    await t.longPress(find.text('Код'));
    await t.pumpAndSettle();
    expect(find.text('Заменить код'), findsOneWidget);
    await t.tap(find.text('Заменить код'));
    await t.pumpAndSettle();
    expect(find.text('Заменить код?'), findsOneWidget);
    expect(find.text('Отмена'), findsOneWidget);
    // «Отмена»: код прежний
    await t.tap(find.text('Отмена'));
    await t.pumpAndSettle();
    expect(s.syncLinkedCode, old);
    // подтверждение: код новый
    await t.longPress(find.text('Код'));
    await t.pumpAndSettle();
    await t.tap(find.text('Заменить код'));
    await t.pumpAndSettle();
    await t.tap(find.text('Заменить'));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    expect(s.syncLinkedCode, isNot(old));
    expect(srv.links, hasLength(1));
  });

  testWidgets('выход: «Отмена» оставляет вход, «Выйти» возвращает к «Вход не выполнен»', (t) async {
    final (s, _) = await make(t, Mode.emailCode);
    await show(t, s);
    await t.tap(find.text('Выйти'));
    await t.pumpAndSettle();
    expect(find.text('Выйти из аккаунта?'), findsOneWidget);
    await t.tap(find.text('Отмена'));
    await t.pumpAndSettle();
    expect(s.syncOn, isTrue);
    await t.tap(find.text('Выйти'));
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: find.byType(CupertinoAlertDialog), matching: find.text('Выйти')));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 11));
    expect(s.syncOn, isFalse);
    expect(find.text('Вход не выполнен'), findsOneWidget);
  });

  testWidgets('выход из режима кода отключает код', (t) async {
    final (s, _) = await make(t, Mode.codeOnly);
    await show(t, s);
    await t.tap(find.text('Выйти'));
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: find.byType(CupertinoAlertDialog), matching: find.text('Выйти')));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 11));
    expect(s.syncCodeOn, isFalse);
    expect(find.text('Вход не выполнен'), findsOneWidget);
  });

  for (final width in [360.0, 390.0, 430.0]) {
    for (final scale in [1.0, 1.3]) {
      for (final b in Brightness.values) {
        testWidgets('без переполнений: ${width.toInt()} px, шрифт $scale, $b', (t) async {
          for (final m in [Mode.emailCode, Mode.emailLinkedUnknown, Mode.codeOnly, Mode.out]) {
            final (s, _) = await make(t, m);
            if (m == Mode.emailCode) {
              s.sync.problem = 'Не удалось обновить настройки: сервер не отвечает, попробуйте позже';
              s.sync.onChange!();
            }
            await show(t, s, width: width, scale: scale, b: b);
            expect(t.takeException(), isNull, reason: '$m');
            await t.pumpWidget(const SizedBox());
            SharedPreferences.setMockInitialValues({});
            await Prefs.init();
          }
        });
      }
    }
  }
}
