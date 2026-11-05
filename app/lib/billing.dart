// Подписка: удобства сверх бесплатного приложения. Всё главное — расписание, протоколы, трансляции,
// уведомления о стартах и о выходе своих — бесплатно и без ограничений. Подписка добавляет «Сводку дня»:
// одно уведомление в выбранное время — кто из отслеживаемых выступает сегодня.
//
// Выключена дважды, и включается только обоими ключами:
//  - в сборке: без --dart-define=BILLING=true приложение о подписке не знает, строки в настройках нет;
//  - на сервере: пока billing_config.enabled = false, billing_offer отвечает null — строки тоже нет.
// Купленная подписка видна и управляется (отказ, возврат) и после того, как продажу выключили.
// Сервер — tools/billing (схема, функции Supabase); как включить — ПОДПИСКА.md в корне.
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'data.dart' show months, msk;
import 'sync.dart';
import 'ui.dart' show nb, plural;

const _billingBuild = bool.fromEnvironment('BILLING');

/// Для тестов: подписка в сборке включена.
@visibleForTesting
bool billingForce = false;

/// Подписка есть в этой сборке (--dart-define=BILLING=true; «1» не считается).
bool get billingBuild => _billingBuild || billingForce;

/// «149 ₽», «1 290 ₽», «9,90 BYN» — неразрывно, чтобы сумма не разорвалась по строкам.
String money(int minor, String currency) {
  final whole = (minor ~/ 100).toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => nb);
  final frac = minor % 100;
  final n = frac == 0 ? whole : '$whole,${frac.toString().padLeft(2, '0')}';
  return currency == 'RUB' ? '$n$nb₽' : '$n$nb$currency';
}

/// «5 декабря» по Москве; другой год — «5 декабря 2027».
String billingDay(DateTime t, DateTime now) {
  final m = msk(t);
  final y = m.year == msk(now).year ? '' : '$nb${m.year}';
  return '${m.day}$nb${months[m.month - 1]}$y';
}

/// «раз в месяц», «раз в год», «раз в 90 дней» — как часто продление.
String periodWords(int days) => switch (days) {
  7 => 'раз в неделю',
  >= 28 && <= 31 => 'раз в месяц',
  >= 365 && <= 366 => 'раз в год',
  _ => 'раз в $days ${plural(days, 'день', 'дня', 'дней')}',
};

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

class BillingPlan {
  final String id, title, currency;
  final int periodDays, priceMinor;
  const BillingPlan({
    required this.id,
    required this.title,
    required this.periodDays,
    required this.priceMinor,
    required this.currency,
  });

  static BillingPlan? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = _str(j['id']), title = _str(j['title']), cur = _str(j['currency']);
    final days = _int(j['period_days']), price = _int(j['price_minor']);
    if (id == null || title == null || cur == null || days == null || days <= 0 || price == null || price <= 0) {
      return null;
    }
    return BillingPlan(id: id, title: title, periodDays: days, priceMinor: price, currency: cur);
  }

  String get price => money(priceMinor, currency);
}

/// Что продаётся сейчас: условия (оферта) с версией, продавец, за сколько дней напоминаем, варианты.
class BillingOffer {
  final String url, version;
  final String? seller;
  final int noticeDays;
  final List<BillingPlan> plans;
  const BillingOffer({required this.url, required this.version, required this.noticeDays, required this.plans, this.seller});

  /// null — не продаётся: сервер выключил продажу, условий нет или ни одного варианта.
  static BillingOffer? fromJson(Object? j) {
    if (j is! Map) return null;
    final url = _str(j['offer_url']), version = _str(j['offer_version']);
    final plans = [
      for (final x in (j['plans'] is List ? j['plans'] as List : const [])) ?BillingPlan.fromJson(x),
    ];
    if (url == null || version == null || plans.isEmpty) return null;
    return BillingOffer(
      url: url,
      version: version,
      seller: _str(j['seller']),
      noticeDays: _int(j['notice_days']) ?? 3,
      plans: plans,
    );
  }
}

/// Подписка вошедшего — как её видит сервер (my_subscription), с поправкой на часы устройства.
class Entitlement {
  final DateTime? paidUntil;
  final String? planId, planTitle, methodTitle, currency;
  final bool autoRenew;

  /// Сколько спишется при продлении; null — продления нет.
  final int? renewMinor;

  /// Сколько вернётся при отказе сейчас (за неиспользованные дни).
  final int refundMinor;

  /// Часы сервера минус часы устройства: срок сверяем по серверу, а не по часам телефона.
  final Duration skew;

  /// Когда сервер это ответил (по часам устройства).
  final DateTime checkedAt;

  const Entitlement({
    required this.checkedAt,
    this.paidUntil,
    this.planId,
    this.planTitle,
    this.methodTitle,
    this.currency,
    this.autoRenew = false,
    this.renewMinor,
    this.refundMinor = 0,
    this.skew = Duration.zero,
  });

  /// Ответ my_subscription; [at] — время устройства в момент ответа.
  static Entitlement fromServer(Object? j, DateTime at) {
    final m = j is Map ? j : const {};
    final server = _time(m['now']);
    return Entitlement(
      checkedAt: at,
      paidUntil: _time(m['paid_until']),
      planId: _str(m['plan_id']),
      planTitle: _str(m['plan_title']),
      methodTitle: _str(m['method_title']),
      currency: _str(m['currency']),
      autoRenew: m['auto_renew'] == true,
      renewMinor: _int(m['renew_minor']),
      refundMinor: _int(m['refund_minor']) ?? 0,
      skew: server == null ? Duration.zero : server.difference(at.toUtc()),
    );
  }

  /// Подписка действует в момент [deviceNow] (время устройства).
  bool activeAt(DateTime deviceNow) => paidUntil != null && paidUntil!.isAfter(deviceNow.toUtc().add(skew));

  /// Была ли подписка вообще (срок есть, пусть и прошедший).
  bool get ever => paidUntil != null;

  Map<String, Object?> toJson() => {
    'paid_until': paidUntil?.toIso8601String(),
    'plan_id': planId,
    'plan_title': planTitle,
    'method_title': methodTitle,
    'currency': currency,
    'auto_renew': autoRenew,
    'renew_minor': renewMinor,
    'refund_minor': refundMinor,
    'skew_ms': skew.inMilliseconds,
    'checked_at': checkedAt.toUtc().toIso8601String(),
  };

  static Entitlement? fromCache(String? s) {
    if (s == null) return null;
    try {
      final m = jsonDecode(s);
      if (m is! Map) return null;
      final at = _time(m['checked_at']);
      if (at == null) return null;
      return Entitlement(
        checkedAt: at,
        paidUntil: _time(m['paid_until']),
        planId: _str(m['plan_id']),
        planTitle: _str(m['plan_title']),
        methodTitle: _str(m['method_title']),
        currency: _str(m['currency']),
        autoRenew: m['auto_renew'] == true,
        renewMinor: _int(m['renew_minor']),
        refundMinor: _int(m['refund_minor']) ?? 0,
        skew: Duration(milliseconds: _int(m['skew_ms']) ?? 0),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Строка истории платежей (my_payments).
class BillingPayment {
  final String id, kind, status, currency;
  final DateTime at;
  final int amountMinor, refundedMinor, refundPendingMinor;
  const BillingPayment({
    required this.id,
    required this.at,
    required this.kind,
    required this.status,
    required this.amountMinor,
    required this.currency,
    this.refundedMinor = 0,
    this.refundPendingMinor = 0,
  });

  static BillingPayment? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = _str(j['id']), at = _time(j['at']), status = _str(j['status']), cur = _str(j['currency']);
    final amount = _int(j['amount_minor']);
    if (id == null || at == null || status == null || cur == null || amount == null) return null;
    return BillingPayment(
      id: id,
      at: at,
      kind: _str(j['kind']) ?? 'first',
      status: status,
      amountMinor: amount,
      currency: cur,
      refundedMinor: _int(j['refunded_minor']) ?? 0,
      refundPendingMinor: _int(j['refund_pending_minor']) ?? 0,
    );
  }

  /// «Оплата» / «Продление».
  String get title => kind == 'renew' ? 'Продление' : 'Оплата';

  /// Что с платежом — по факту, строками: «Прошла», «Возвращено 120 ₽», «Возврат 120 ₽ оформляется».
  List<String> get state => [
    switch (status) {
      'succeeded' || 'refunded' => 'Прошла',
      'pending' => 'Ждёт подтверждения банка',
      'canceled' => 'Не прошла',
      _ => status,
    },
    if (refundedMinor > 0) 'Возвращено ${money(refundedMinor, currency)}',
    if (refundPendingMinor > 0) 'Возврат ${money(refundPendingMinor, currency)} оформляется',
  ];
}

/// Начатая оплата: страница сервиса и адрес, куда сервис вернёт после оплаты.
class BillingCheckout {
  final String paymentId, url, returnUrl;
  const BillingCheckout(this.paymentId, this.url, this.returnUrl);
}

/// Итог отказа с возвратом: сколько вернул сервис сразу и сколько вернёт продавец вручную.
class BillingRefund {
  final int refunded, manual;
  final String currency;
  const BillingRefund(this.refunded, this.manual, this.currency);
}

/// Запросы подписки — через тот же вход, что и синхронизация (AccountBackend.post).
class BillingApi {
  BillingApi(this.backend);
  final AccountBackend backend;

  /// Что продаётся; null — не продаётся (выключено, или на сервере нет схемы подписки — 404).
  Future<BillingOffer?> offer() async {
    try {
      return BillingOffer.fromJson(await backend.post('rest/v1/rpc/billing_offer', null, false));
    } on SyncError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<Entitlement> mine(DateTime Function() clock) async {
    final j = await backend.post('rest/v1/rpc/my_subscription');
    return Entitlement.fromServer(j, clock());
  }

  Future<List<BillingPayment>> payments() async {
    final j = await backend.post('rest/v1/rpc/my_payments');
    return [for (final x in (j is List ? j : const [])) ?BillingPayment.fromJson(x)];
  }

  Future<void> cancelRenew() => backend.post('rest/v1/rpc/cancel_auto_renew');

  /// [consent] — текст согласия на продление ровно как на экране; сервер хранит его в журнале.
  Future<BillingCheckout> checkout({
    required String plan,
    required bool renew,
    required String offerVersion,
    String? consent,
  }) async {
    final j = await backend.post('functions/v1/billing-checkout', {
      'plan': plan,
      'renew': renew,
      'offer_version': offerVersion,
      if (renew && consent != null) 'consent': consent,
    });
    final m = j is Map ? j : const {};
    final id = _str(m['payment_id']), url = _str(m['url']), back = _str(m['return_url']);
    if (id == null || url == null || back == null) throw const SyncError('Сервер не ответил, куда платить');
    return BillingCheckout(id, url, back);
  }

  Future<BillingRefund> refund() async {
    final j = await backend.post('functions/v1/billing-refund');
    final m = j is Map ? j : const {};
    return BillingRefund(_int(m['refunded_minor']) ?? 0, _int(m['manual_minor']) ?? 0, _str(m['currency']) ?? 'RUB');
  }
}

/// Подписка на этом устройстве: что продаётся, право (с кэшем — оно нужно и фоновой задаче без сети),
/// история платежей, время сводки.
class BillingState {
  BillingState(this._p) : entitlement = Entitlement.fromCache(_p.getString(entKey));
  final SharedPreferences _p;

  static const entKey = 'b.ent';
  static const digestKey = 'b.digest';

  /// Сводка по умолчанию — в 9:00 по Москве.
  static const digestDefault = 9 * 60;

  /// Выключенная сводка хранится как -1 (отсутствие ключа — «по умолчанию»).
  static const digestOff = -1;

  BillingOffer? offer;

  /// Спрашивали ли сервер, что продаётся (до ответа строка в настройках не решает, показываться ли).
  bool offerChecked = false;

  Entitlement? entitlement;
  List<BillingPayment>? payments;

  /// Последнее обновление не удалось — почему (показывается рядом с данными, которые могли устареть).
  String? problem;

  /// Время сводки: минута московских суток или [digestOff].
  int get digestSetting => _p.getInt(digestKey) ?? digestDefault;
  Future<void> setDigest(int minute) => _p.setInt(digestKey, minute);

  /// Сводка в плане уведомлений сейчас: подписка действует и сводка не выключена.
  int? digestAt(DateTime now) => digestFor(_p, now);

  /// То же для фоновой задачи (background.dart): только из сохранённого, без сети.
  static int? digestFor(SharedPreferences p, DateTime now) {
    final e = Entitlement.fromCache(p.getString(entKey));
    if (e == null || !e.activeAt(now)) return null;
    final m = p.getInt(digestKey) ?? digestDefault;
    return m < 0 || m >= 24 * 60 ? null : m;
  }

  bool activeAt(DateTime now) => entitlement?.activeAt(now) ?? false;

  /// Строка «Подписка» в настройках: продаётся — или куплена раньше (тогда ею можно управлять и вернуть деньги).
  bool get visible => billingBuild && (offer != null || (entitlement?.ever ?? false));

  Future<void> keep(Entitlement e) async {
    entitlement = e;
    await _p.setString(entKey, jsonEncode(e.toJson()));
  }

  /// Выход из аккаунта: право и история — чужие для следующего входа.
  Future<void> clear() async {
    entitlement = null;
    payments = null;
    problem = null;
    await _p.remove(entKey);
  }
}

/// Варианты времени сводки: с 6:00 до 12:00 по Москве, каждые полчаса.
final digestTimes = [for (var m = 6 * 60; m <= 12 * 60; m += 30) m];

/// «9:00».
String digestLabel(int minute) => '${minute ~/ 60}:${(minute % 60).toString().padLeft(2, '0')}';
