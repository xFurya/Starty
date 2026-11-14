// Подписка в приложении (billing.dart, billing_page.dart): выключена, пока её нет в сборке и сервер её не продаёт;
// сводка дня — только при действующей подписке; разбор ответов сервера; оплата, отказ, возврат, выход из аккаунта.
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/billing.dart';
import 'package:starty/data.dart';
import 'package:starty/month_widget.dart' show widgetJson;
import 'package:starty/reminders.dart';
import 'package:starty/settings.dart';
import 'package:starty/state.dart';
import 'package:starty/sync.dart';

const nb = ' ';
String sp(String s) => s.replaceAll(nb, ' ');

final offerJson = {
  'offer_url': 'https://xfurya.github.io/Starty/offer/',
  'offer_version': 'v1',
  'seller': 'Иванов И. И., самозанятый',
  'notice_days': 3,
  'plans': [
    {'id': 'month', 'title': 'Месяц', 'period_days': 30, 'price_minor': 14900, 'currency': 'RUB'},
    {'id': 'year', 'title': 'Год', 'period_days': 365, 'price_minor': 129000, 'currency': 'RUB'},
  ],
};

/// Ответ сервера в UTF-8 (в ответах кириллица).
http.Response res(Object? body, [int code = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), code);

/// Сервер подписки в памяти: продажа включена или нет, подписка, платежи, журнал запросов.
class Billing {
  bool selling = true;
  bool schema = true;
  DateTime? paidUntil;
  bool autoRenew = false;
  final pays = <Map<String, Object?>>[];
  final requests = <String>[];
  Map<String, dynamic>? lastCheckout;

  MockClient get client => MockClient((r) async {
    final p = r.url.path;
    requests.add(p);
    if (p.endsWith('/token')) {
      return http.Response(jsonEncode({'access_token': 'a', 'refresh_token': 'r', 'expires_in': 3600}), 200);
    }
    if (p.contains('load_settings')) return http.Response('[]', 200);
    if (p.contains('save_settings')) return http.Response(jsonEncode('2026-01-01T00:00:00Z'), 200);
    if (!schema) return http.Response('{"code":"PGRST202"}', 404);
    if (p.endsWith('/rpc/billing_offer')) {
      expect(r.headers['Authorization'], isNull, reason: 'что продаётся — без входа');
      return res(selling ? offerJson : null);
    }
    expect(r.headers['Authorization'], 'Bearer a', reason: p);
    if (p.endsWith('/rpc/my_subscription')) {
      final now = DateTime.now().toUtc().toIso8601String();
      return res(paidUntil == null
          ? {'now': now}
          : {
              'now': now,
              'plan_id': 'month',
              'plan_title': 'Месяц',
              'paid_until': paidUntil!.toIso8601String(),
              'auto_renew': autoRenew,
              'method_title': autoRenew ? 'Карта •• 4242' : null,
              'renew_minor': autoRenew ? 14900 : null,
              'currency': 'RUB',
              'refund_minor': paidUntil!.isAfter(DateTime.now()) ? 12000 : 0,
            });
    }
    if (p.endsWith('/rpc/my_payments')) return res(pays);
    if (p.endsWith('/rpc/cancel_auto_renew')) {
      autoRenew = false;
      return http.Response('', 204);
    }
    if (p.endsWith('/functions/v1/billing-checkout')) {
      lastCheckout = jsonDecode(r.body) as Map<String, dynamic>;
      if (paidUntil != null && paidUntil!.isAfter(DateTime.now())) {
        return http.Response(jsonEncode({'error': 'already_active'}), 409);
      }
      pays.insert(0, {
        'id': 'pay-1', 'at': DateTime.now().toUtc().toIso8601String(), 'kind': 'first', 'status': 'pending',
        'amount_minor': 14900, 'refunded_minor': 0, 'refund_pending_minor': 0, 'currency': 'RUB',
      });
      return res({
        'payment_id': 'pay-1',
        'url': 'https://pay.example/checkout/1',
        'return_url': 'https://xfurya.github.io/Starty/pay/',
      });
    }
    if (p.endsWith('/functions/v1/billing-refund')) {
      paidUntil = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
      autoRenew = false;
      pays.first['refund_pending_minor'] = 12000;
      return res({'refunded_minor': 0, 'manual_minor': 12000, 'currency': 'RUB'});
    }
    return http.Response('', 404);
  });

  /// Сервис подтвердил оплату (уведомление на сервер).
  void paid() {
    pays.first['status'] = 'succeeded';
    paidUntil = DateTime.now().toUtc().add(const Duration(days: 30));
    autoRenew = lastCheckout?['renew'] == true;
  }
}

Schedule day(String startIso, String endIso, {List<String> ours = const ['Алиса Заикина']}) => Schedule.parse(jsonEncode({
  'generated': '2026-10-20T08:00:00+03:00',
  'events': [
    {
      'id': 'f', 'tid': 't', 'tournament': 'T', 'kind': 'women', 'level': 'senior', 'seg': 'КП',
      'title': 'T — женщины КП', 'start': startIso, 'end': endIso, 'venue': '', 'intl': false,
      'ours': [for (final n in ours) {'name': n, 'time': '12:10'}],
      'field': [for (final n in ours) {'name': n, 'time': '12:10'}],
    },
  ],
})).withFollow(Follow(ours));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
  });
  tearDown(() => billingForce = false);

  group('деньги и сроки', () {
    test('суммы — как в письмах сервера, неразрывно', () {
      expect(sp(money(14900, 'RUB')), '149 ₽');
      expect(sp(money(129000, 'RUB')), '1 290 ₽');
      expect(sp(money(990, 'BYN')), '9,90 BYN');
      expect(money(129000, 'RUB'), isNot(contains(' ')));
    });
    test('как часто продление', () {
      expect(periodWords(30), 'раз в месяц');
      expect(periodWords(365), 'раз в год');
      expect(periodWords(7), 'раз в неделю');
      expect(periodWords(90), 'раз в 90 дней');
      expect(periodWords(2), 'раз в 2 дня');
    });
    test('дата по Москве; другой год — с годом', () {
      final now = DateTime.utc(2026, 11, 5, 12);
      expect(sp(billingDay(DateTime.utc(2026, 12, 4, 21, 30), now)), '5 декабря');
      expect(sp(billingDay(DateTime.utc(2027, 1, 5, 9), now)), '5 января 2027');
    });
  });

  group('разбор ответов', () {
    test('не продаётся: null, нет условий, нет вариантов', () {
      expect(BillingOffer.fromJson(null), isNull);
      expect(BillingOffer.fromJson({...offerJson, 'offer_url': null}), isNull);
      expect(BillingOffer.fromJson({...offerJson, 'plans': []}), isNull);
    });
    test('варианты: битые отбрасываются, порядок сервера сохраняется', () {
      final o = BillingOffer.fromJson({
        ...offerJson,
        'plans': [
          {'id': 'bad', 'title': 'Ноль', 'period_days': 30, 'price_minor': 0, 'currency': 'RUB'},
          ...(offerJson['plans'] as List),
        ],
      })!;
      expect(o.plans.map((p) => p.id), ['month', 'year']);
      expect(o.version, 'v1');
      expect(o.noticeDays, 3);
      expect(o.seller, startsWith('Иванов'));
    });
    test('срок сверяется по часам сервера, а не телефона', () {
      final device = DateTime.utc(2026, 11, 5, 12);
      // часы телефона отстают на час: по ним подписка ещё идёт, по серверу — уже нет
      final e = Entitlement.fromServer({
        'now': device.add(const Duration(hours: 1)).toIso8601String(),
        'paid_until': device.add(const Duration(minutes: 30)).toIso8601String(),
      }, device);
      expect(e.activeAt(device), isFalse);
      final back = Entitlement.fromCache(jsonEncode(e.toJson()))!;
      expect(back.skew, const Duration(hours: 1));
      expect(back.activeAt(device), isFalse);
      expect(back.activeAt(device.subtract(const Duration(hours: 1))), isTrue);
    });
    test('история: что с платежом — по факту', () {
      final x = BillingPayment.fromJson({
        'id': 'p', 'at': '2026-11-05T09:00:00Z', 'kind': 'renew', 'status': 'succeeded',
        'amount_minor': 14900, 'refunded_minor': 3000, 'refund_pending_minor': 9000, 'currency': 'RUB',
      })!;
      expect(x.title, 'Продление');
      expect(x.state.map(sp), ['Прошла', 'Возвращено 30 ₽', 'Возврат 90 ₽ оформляется']);
      expect(BillingPayment.fromJson({'id': 'p'}), isNull);
    });
    test('ошибки сервера — понятными словами', () async {
      final b = AccountBackend(
        url: 'https://sync.test',
        key: 'k',
        session: AccountSession.fromMap({'access': 'a', 'refresh': 'r', 'expires': '2999-01-01T00:00:00Z', 'email': 'a@b.ru'}),
        client: MockClient((_) async => http.Response(jsonEncode({'error': 'already_active'}), 409)),
      );
      await expectLater(
        BillingApi(b).checkout(plan: 'month', renew: false, offerVersion: 'v1'),
        throwsA(isA<SyncError>().having((e) => e.message, 'message', 'Подписка уже действует')),
      );
    });
  });

  group('режим владельца', () {
    test('код: свой подходит в любой записи, чужой — нет', () {
      final own = File(Platform.environment['OWNER_CODE_FILE'] ?? '');
      // сам код в репозитории не лежит; проверяем только отказы и нормализацию пустого
      expect(BillingState.previewCodeOk(''), isFalse);
      expect(BillingState.previewCodeOk('AAAA-BBBB-CCCC-DDDD'), isFalse);
      expect(BillingState.previewCodeOk('furya.preview'), isFalse);
      if (own.path.isNotEmpty && own.existsSync()) {
        final code = own.readAsStringSync().trim();
        expect(BillingState.previewCodeOk(code), isTrue);
        expect(BillingState.previewCodeOk(code.toLowerCase().replaceAll('-', ' ')), isTrue);
      }
    });

    test('без режима и без подписки удобств нет; с режимом — все, и в фоне тоже', () async {
      final now = DateTime.parse('2026-11-14T12:00:00+03:00');
      final b = BillingState(Prefs.raw);
      expect(b.perksAt(now), isFalse);
      expect(BillingState.perksFor(Prefs.raw, now), isFalse);
      expect(BillingState.digestFor(Prefs.raw, now), isNull);
      expect(b.visible, isFalse);
      await b.setPreview(true);
      expect(b.perksAt(now), isTrue);
      expect(b.lineupAt(now) && b.resultsAt(now), isTrue);
      expect(BillingState.perksFor(Prefs.raw, now), isTrue);
      expect(BillingState.lineupFor(Prefs.raw, now) && BillingState.resultsFor(Prefs.raw, now), isTrue);
      expect(BillingState.digestFor(Prefs.raw, now), BillingState.digestDefault);
      expect(b.visible, isTrue);
      await b.setPreview(false);
      expect(b.perksAt(now), isFalse);
    });

    test('виджет «Месяц» в режиме владельца открыт без подписки, срок — сутки', () {
      final t = DateTime.parse('2026-11-14T12:00:00+03:00');
      final j = jsonDecode(widgetJson(data: null, filters: Filters.none, ent: null, now: t, preview: true)) as Map;
      expect(j['mode'], 'on');
      expect(j['until'], t.add(const Duration(hours: 24)).millisecondsSinceEpoch);
      final off = jsonDecode(widgetJson(data: null, filters: Filters.none, ent: null, now: t)) as Map;
      expect(off['mode'], 'locked');
    });
  });

  group('сводка дня', () {
    test('в выбранное время, только дни со своими и только впереди', () {
      final d = day('2026-10-20T10:00:00+03:00', '2026-10-20T13:00:00+03:00');
      final early = DateTime.parse('2026-10-20T06:00:00+03:00');
      final x = Reminders.digestPlan(d, 9 * 60, early);
      expect(x, hasLength(1));
      expect(x.single.at, DateTime.parse('2026-10-20T09:00:00+03:00'));
      expect(x.single.key, 'd:2026-10-20');
      expect(x.single.title, 'Сегодня у ваших 1 старт');
      expect(x.single.lines.single, startsWith('10:00 — '));
      expect(x.single.lines.single, contains('Заикина'));
      expect(x.single.end, DateTime.parse('2026-10-21T00:00:00+03:00'));
      // сводка «на сегодня» после её времени не приходит
      expect(Reminders.digestPlan(d, 9 * 60, DateTime.parse('2026-10-20T09:30:00+03:00')), isEmpty);
      // старт кончился до сводки — его в ней нет
      expect(Reminders.digestPlan(d, 14 * 60, early), isEmpty);
      // свои не выступают — сводки нет
      expect(Reminders.digestPlan(day('2026-10-20T10:00:00+03:00', '2026-10-20T13:00:00+03:00', ours: []), 9 * 60, early), isEmpty);
    });

    test('в плане уведомлений — только с digest и при включённых уведомлениях', () {
      final d = day('2026-10-20T10:00:00+03:00', '2026-10-20T13:00:00+03:00');
      final early = DateTime.parse('2026-10-20T06:00:00+03:00');
      bool has(NotifyPlan p) => Reminders.plan(d, p, early).any((x) => x.group == 'digest');
      expect(has(const NotifyPlan(NotifyRules(), {}, {})), isFalse);
      expect(has(const NotifyPlan(NotifyRules(), {}, {}, digest: 540)), isTrue);
      expect(has(const NotifyPlan(NotifyRules(on: false), {}, {}, digest: 540)), isFalse);
    });

    test('фоновая задача берёт право из памяти: нет подписки, кончилась, выключена — сводки нет', () async {
      final p = Prefs.raw;
      final t = DateTime.utc(2026, 11, 5, 12);
      expect(BillingState.digestFor(p, t), isNull);
      Future<void> keep(Duration left) => p.setString(
        BillingState.entKey,
        jsonEncode(Entitlement(checkedAt: t, paidUntil: t.add(left)).toJson()),
      );
      await keep(const Duration(days: 3));
      expect(BillingState.digestFor(p, t), BillingState.digestDefault);
      await p.setInt(BillingState.digestKey, 7 * 60 + 30);
      expect(BillingState.digestFor(p, t), 450);
      await p.setInt(BillingState.digestKey, BillingState.digestOff);
      expect(BillingState.digestFor(p, t), isNull);
      await p.remove(BillingState.digestKey);
      await keep(const Duration(seconds: -1));
      expect(BillingState.digestFor(p, t), isNull);
    });
  });

  group('приложение и сервер', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('в обычной сборке подписки нет: сервер не спрашивается, строки нет', () async {
      final srv = Billing();
      final s = AppState()..syncClient = srv.client;
      expect(await s.signInSync('a@b.ru', 'secret1'), isNull);
      await s.refreshBilling(history: true);
      expect(srv.requests.where((p) => p.contains('billing') || p.contains('my_')), isEmpty);
      expect(s.billing.visible, isFalse);
      expect(s.plan.digest, isNull);
    });

    test('сервер не продаёт (или схемы нет) — строки нет', () async {
      billingForce = true;
      final srv = Billing()..selling = false;
      final s = AppState()..syncClient = srv.client;
      await s.refreshBilling();
      expect(s.billing.offerChecked, isTrue);
      expect(s.billing.visible, isFalse);
      srv.schema = false;
      await s.refreshBilling();
      expect(s.billing.visible, isFalse);
      expect(s.billing.problem, isNull);
    });

    test('оплата: продление только с согласием, сводка появляется, отказ с возвратом, выход забывает право', () async {
      billingForce = true;
      final srv = Billing();
      final s = AppState()..syncClient = srv.client;
      // без входа видно, что продаётся, но купить нельзя
      await s.refreshBilling();
      expect(s.billing.problem, isNull);
      expect(srv.requests, contains(endsWith('billing_offer')));
      expect(s.billing.visible, isTrue);
      expect(s.account, isNull);
      await expectLater(s.startPayment(s.billing.offer!.plans.first, renew: false), throwsA(isA<SyncError>()));

      expect(await s.signInSync('a@b.ru', 'secret1'), isNull);
      await s.refreshBilling(history: true);
      expect(s.billing.activeAt(DateTime.now()), isFalse);
      expect(s.plan.digest, isNull);

      final c = await s.startPayment(s.billing.offer!.plans.first, renew: true, consent: 'Продлевать автоматически. текст');
      expect(c.url, 'https://pay.example/checkout/1');
      expect(srv.lastCheckout, {'plan': 'month', 'renew': true, 'offer_version': 'v1', 'consent': 'Продлевать автоматически. текст'});
      // пока банк не подтвердил — ждём и честно говорим, что не дождались
      expect(await s.awaitPayment(c.paymentId, limit: Duration.zero), isNull);
      srv.paid();
      expect(await s.awaitPayment(c.paymentId, limit: Duration.zero), isTrue);
      expect(s.billing.activeAt(DateTime.now()), isTrue);
      expect(s.billing.entitlement!.autoRenew, isTrue);
      expect(s.plan.digest, BillingState.digestDefault);
      expect(Prefs.raw.getString(BillingState.entKey), isNotNull);
      expect(s.billing.payments!.single.state, ['Прошла']);

      // второй раз не купить, пока срок идёт
      await expectLater(
        s.startPayment(s.billing.offer!.plans.first, renew: false),
        throwsA(isA<SyncError>().having((e) => e.message, 'message', 'Подписка уже действует')),
      );

      expect(await s.cancelRenew(), isNull);
      expect(s.billing.entitlement!.autoRenew, isFalse);
      expect(s.billing.activeAt(DateTime.now()), isTrue);

      await s.setDigest(BillingState.digestOff);
      expect(s.plan.digest, isNull);
      await s.setDigest(8 * 60);
      expect(s.plan.digest, 480);

      final (r, err) = await s.refundSubscription();
      expect(err, isNull);
      expect(r!.manual, 12000);
      expect(s.billing.activeAt(DateTime.now()), isFalse);
      expect(s.plan.digest, isNull);
      expect(s.billing.payments!.single.state.map(sp), ['Прошла', 'Возврат 120 ₽ оформляется']);

      srv.paid();
      await s.refreshBilling();
      expect(s.billing.activeAt(DateTime.now()), isTrue);
      await s.signOutSync();
      expect(s.billing.entitlement, isNull);
      expect(Prefs.raw.getString(BillingState.entKey), isNull);
      expect(s.plan.digest, isNull);
    });

    test('вход в другой аккаунт сразу забывает чужую подписку и её сводку', () async {
      billingForce = true;
      final srv = Billing()..paidUntil = DateTime.now().toUtc().add(const Duration(days: 20));
      final s = AppState()..syncClient = srv.client;
      expect(await s.signInSync('a@b.ru', 'secret1'), isNull);
      await s.refreshBilling();
      expect(s.plan.digest, BillingState.digestDefault);
      // о новом аккаунте сервер ничего не скажет: прежнее право убирает сам вход, а не ответ сервера
      srv.schema = false;
      expect(await s.signInSync('c@d.ru', 'secret2'), isNull);
      await s.refreshBilling();
      expect(s.billing.problem, isNotNull);
      expect(s.billing.entitlement, isNull);
      expect(Prefs.raw.getString(BillingState.entKey), isNull);
      expect(s.plan.digest, isNull);
    });

    test('без согласия на продление согласие не отправляется', () async {
      billingForce = true;
      final srv = Billing();
      final s = AppState()..syncClient = srv.client;
      expect(await s.signInSync('a@b.ru', 'secret1'), isNull);
      await s.refreshBilling();
      await s.startPayment(s.billing.offer!.plans.last, renew: false, consent: 'не должно уйти');
      expect(srv.lastCheckout, {'plan': 'year', 'renew': false, 'offer_version': 'v1'});
    });
  });

  group('экран', () {
    Future<AppState> settings(WidgetTester t, Billing srv) async {
      t.view.physicalSize = const Size(1080, 5800); // страница целиком: с «Статистикой» она стала длиннее
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final s = AppState()
        ..loading = false
        ..syncClient = srv.client;
      await t.runAsync(() async {
        expect(await s.signInSync('a@b.ru', 'secret1'), isNull);
        await s.refreshBilling();
      });
      await t.pumpWidget(MaterialApp(home: Scaffold(body: SettingsView(state: s))));
      await t.pump(const Duration(milliseconds: 300));
      return s;
    }

    testWidgets('в обычной сборке строки «Подписка» нет, даже если сервер продаёт', (t) async {
      await settings(t, Billing());
      expect(find.text('Подписка', skipOffstage: false), findsNothing);
    });

    testWidgets('со сборкой и продажей — строка и страница: что даёт, сроки, продление выключено', (t) async {
      billingForce = true;
      final srv = Billing();
      await settings(t, srv);
      expect(find.text('Подписка', skipOffstage: false), findsOneWidget);
      expect(find.text('Итоги ваших, статистика, жеребьёвка, сводка дня и поддержка приложения', skipOffstage: false), findsOneWidget);
      await t.tap(find.text('Подписка'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      expect(find.text('Сводка дня'), findsOneWidget);
      expect(find.text('Месяц'), findsOneWidget);
      expect(find.text('Год'), findsOneWidget);
      final renew = find.ancestor(of: find.text('Продлевать автоматически'), matching: find.byType(InkWell));
      expect(t.widget<Switch>(find.descendant(of: renew, matching: find.byType(Switch))).value, isFalse);
      expect(find.textContaining('Оплатить 149'), findsOneWidget);
      expect(find.textContaining('Продавец: Иванов'), findsOneWidget);
      // выбрали год — сумма на кнопке меняется
      await t.tap(find.text('Год'));
      await t.pump();
      expect(find.textContaining('Оплатить 1${nb}290'), findsOneWidget);
    });

    testWidgets('подписка действует: срок, сводка, продление, возврат', (t) async {
      billingForce = true;
      final srv = Billing()
        ..paidUntil = DateTime.now().toUtc().add(const Duration(days: 20))
        ..autoRenew = true;
      final s = await settings(t, srv);
      expect(s.billing.activeAt(DateTime.now()), isTrue);
      expect(find.textContaining('Продлится автоматически', skipOffstage: false), findsOneWidget);
      await t.tap(find.text('Подписка'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      expect(find.textContaining('Подписка до'), findsOneWidget);
      expect(find.text('Продление включено'), findsOneWidget);
      expect(find.text('Отключить'), findsOneWidget);
      expect(find.text('Отказаться с возвратом'), findsOneWidget);
      expect(find.textContaining('Вернём 120'), findsOneWidget);
      expect(find.textContaining('Каждый день в 9:00'), findsOneWidget);
      // оплачивать нечего, пока срок идёт
      expect(find.textContaining('Оплатить'), findsNothing);
    });
  });
}
