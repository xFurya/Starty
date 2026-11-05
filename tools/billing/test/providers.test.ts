// Платёжные сервисы без сети: что уходит в API и как читаются их уведомления.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { provider } from '../supabase/functions/_shared/providers/index.ts';
import { Unauthorized, type Payment } from '../supabase/functions/_shared/providers/types.ts';
import { digest, hmacBase64 } from '../supabase/functions/_shared/hash.ts';
import { Config } from '../supabase/functions/_shared/env.ts';

type Call = { url: string; method: string; headers: Record<string, string>; body: string };

function fake(answers: Array<(c: Call) => Response>) {
  const calls: Call[] = [];
  const http = (async (input: string | URL | Request, init?: RequestInit) => {
    const c: Call = {
      url: String(input),
      method: init?.method ?? 'GET',
      headers: Object.fromEntries(new Headers(init?.headers).entries()),
      body: typeof init?.body === 'string' ? init.body : '',
    };
    calls.push(c);
    const a = answers.shift();
    if (!a) throw new Error(`лишний запрос ${c.url}`);
    return a(c);
  }) as typeof fetch;
  return { http, calls };
}

const envOf = (o: Record<string, string>) => (k: string) => o[k];

const pay: Payment = {
  payment_id: 'aaaa-bbbb', seq: 7, user_id: 'u-1', email: 'fan@example.ru', plan_id: 'month', title: 'Месяц',
  period_days: 30, amount_minor: 14900, currency: 'RUB', provider: 'x', save_method: true,
};
const urls = { returnUrl: 'https://xfurya.github.io/Starty/pay/?pay=aaaa-bbbb', notifyUrl: 'https://s.supabase.co/functions/v1/billing-webhook?p=x' };
const incoming = (body: string, headers: Record<string, string> = {}, url = 'https://s/functions/v1/billing-webhook') =>
  ({ headers: new Headers(headers), body, url: new URL(url) });

test('неизвестный сервис — нет', () => {
  assert.equal(provider('paypal', envOf({})), null);
});

test('без ключей — Config, а не запрос с пустыми ключами', async () => {
  const { http, calls } = fake([]);
  const p = provider('yookassa', envOf({}), http)!;
  await assert.rejects(p.create(pay, urls), Config);
  assert.equal(calls.length, 0);
});

// ---------------------------------------------------------------- ЮKassa

const yk = envOf({ YOOKASSA_SHOP_ID: '123', YOOKASSA_SECRET_KEY: 'sk' });

test('ЮKassa: платёж с сохранением карты, чеком и нашим номером', async () => {
  const { http, calls } = fake([() => Response.json({ id: 'yk-1', status: 'pending', confirmation: { confirmation_url: 'https://yoomoney.ru/checkout/x' } })]);
  const r = await provider('yookassa', yk, http)!.create(pay, urls);
  assert.deepEqual(r, { providerId: 'yk-1', url: 'https://yoomoney.ru/checkout/x' });
  const c = calls[0];
  assert.equal(c.url, 'https://api.yookassa.ru/v3/payments');
  assert.equal(c.headers.authorization, `Basic ${btoa('123:sk')}`);
  assert.equal(c.headers['idempotence-key'], 'aaaa-bbbb');
  const b = JSON.parse(c.body);
  assert.deepEqual(b.amount, { value: '149.00', currency: 'RUB' });
  assert.equal(b.save_payment_method, true);
  assert.equal(b.confirmation.return_url, urls.returnUrl);
  assert.equal(b.metadata.payment_id, 'aaaa-bbbb');
  assert.equal(b.receipt.customer.email, 'fan@example.ru');
  assert.equal(b.receipt.items[0].vat_code, undefined, 'самозанятому НДС не указывается');
});

test('ЮKassa: без согласия карта не сохраняется', async () => {
  const { http, calls } = fake([() => Response.json({ id: 'yk-1', status: 'pending', confirmation: { confirmation_url: 'u' } })]);
  await provider('yookassa', yk, http)!.create({ ...pay, save_method: false }, urls);
  assert.equal(JSON.parse(calls[0].body).save_payment_method, false);
});

test('ЮKassa: чек по 54-ФЗ — с НДС и предметом расчёта', async () => {
  const { http, calls } = fake([() => Response.json({ id: 'yk-1', status: 'pending', confirmation: { confirmation_url: 'u' } })]);
  await provider('yookassa', envOf({ YOOKASSA_SHOP_ID: '1', YOOKASSA_SECRET_KEY: 's', YOOKASSA_RECEIPT: '54fz' }), http)!.create(pay, urls);
  const item = JSON.parse(calls[0].body).receipt.items[0];
  assert.equal(item.vat_code, 1);
  assert.equal(item.payment_subject, 'service');
});

test('ЮKassa: уведомлению не верим — спрашиваем API', async () => {
  const { http, calls } = fake([() => Response.json({
    id: 'yk-1', status: 'succeeded', amount: { value: '149.00', currency: 'RUB' }, metadata: { payment_id: 'aaaa-bbbb' },
    payment_method: { id: 'pm-1', saved: true, card: { last4: '4242' } },
  })]);
  const h = await provider('yookassa', yk, http)!.webhook(incoming(JSON.stringify({ event: 'payment.succeeded', object: { id: 'yk-1', status: 'succeeded', amount: { value: '1.00' } } })));
  assert.equal(calls[0].url, 'https://api.yookassa.ru/v3/payments/yk-1');
  assert.deepEqual(h.events, [{
    kind: 'paid', paymentId: 'aaaa-bbbb', providerId: 'yk-1', amountMinor: 14900, currency: 'RUB', token: 'pm-1', methodTitle: 'Карта •• 4242',
  }]);
  assert.equal(h.reply.status, 200);
});

test('ЮKassa: отмена — неуспех; не наш платёж — ничего', async () => {
  const { http } = fake([
    () => Response.json({ id: 'yk-2', status: 'canceled', metadata: { payment_id: 'p2' }, cancellation_details: { reason: 'insufficient_funds' } }),
    () => Response.json({ id: 'yk-3', status: 'succeeded', metadata: {} }),
  ]);
  const p = provider('yookassa', yk, http)!;
  const a = await p.webhook(incoming(JSON.stringify({ event: 'payment.canceled', object: { id: 'yk-2' } })));
  assert.deepEqual(a.events, [{ kind: 'failed', paymentId: 'p2', providerId: 'yk-2', reason: 'insufficient_funds' }]);
  const b = await p.webhook(incoming(JSON.stringify({ event: 'payment.succeeded', object: { id: 'yk-3' } })));
  assert.deepEqual(b.events, []);
});

test('ЮKassa: продление по сохранённой карте и возврат', async () => {
  const { http, calls } = fake([
    () => Response.json({ id: 'yk-9', status: 'succeeded' }),
    () => Response.json({ id: 'r-1', status: 'succeeded' }),
  ]);
  const p = provider('yookassa', yk, http)!;
  assert.deepEqual(await p.charge!({ ...pay, token: 'pm-1' }), { status: 'succeeded', providerId: 'yk-9' });
  assert.equal(JSON.parse(calls[0].body).payment_method_id, 'pm-1');
  await p.refund!({ providerId: 'yk-1', amountMinor: 12000, currency: 'RUB', email: 'fan@example.ru' });
  const b = JSON.parse(calls[1].body);
  assert.equal(calls[1].url, 'https://api.yookassa.ru/v3/refunds');
  assert.deepEqual(b.amount, { value: '120.00', currency: 'RUB' });
  assert.equal(b.payment_id, 'yk-1');
});

test('ЮKassa: без токена не списываем; ошибка API — неуспех, а не исключение', async () => {
  const { http } = fake([() => new Response(JSON.stringify({ description: 'bad' }), { status: 400 })]);
  const p = provider('yookassa', yk, http)!;
  assert.equal((await p.charge!(pay)).reason, 'no_token');
  assert.equal((await p.charge!({ ...pay, token: 'pm' })).status, 'failed');
});

// ---------------------------------------------------------------- Робокасса

const rk = envOf({ ROBOKASSA_LOGIN: 'shop1', ROBOKASSA_PASSWORD1: 'pass1', ROBOKASSA_PASSWORD2: 'pass2' });

test('Робокасса: ссылка с подписью, номером счёта и продлением', async () => {
  const r = await provider('robokassa', rk)!.create(pay, urls);
  const u = new URL(r.url);
  assert.equal(u.origin + u.pathname, 'https://auth.robokassa.ru/Merchant/Index.aspx');
  assert.equal(u.searchParams.get('OutSum'), '149.00');
  assert.equal(u.searchParams.get('InvId'), '7');
  assert.equal(u.searchParams.get('Shp_pay'), 'aaaa-bbbb');
  assert.equal(u.searchParams.get('Recurring'), 'true');
  assert.equal(u.searchParams.get('IsTest'), null);
  assert.equal(u.searchParams.get('SignatureValue'), '69d0e55e66044f5723d38a76e1cebe80');
  assert.equal(r.providerId, '7');
});

test('Робокасса: тестовый режим', async () => {
  const r = await provider('robokassa', envOf({ ROBOKASSA_LOGIN: 'shop1', ROBOKASSA_PASSWORD1: 'pass1', BILLING_TEST: '1' }))!.create(pay, urls);
  assert.equal(new URL(r.url).searchParams.get('IsTest'), '1');
});

test('Робокасса: Result URL — подпись вторым паролем, ответ OK+номер', async () => {
  const body = new URLSearchParams({ OutSum: '149.000000', InvId: '7', SignatureValue: '216D1F6CE2B5A6F39BC6101F54986054', Shp_pay: 'aaaa-bbbb' }).toString();
  const h = await provider('robokassa', rk)!.webhook(incoming(body, { 'content-type': 'application/x-www-form-urlencoded' }));
  assert.equal(await h.reply.text(), 'OK7');
  assert.deepEqual(h.events, [{
    kind: 'paid', seq: 7, paymentId: 'aaaa-bbbb', providerId: '7', amountMinor: 14900, currency: 'RUB', token: '7', methodTitle: 'Карта',
  }]);
});

test('Робокасса: чужая подпись — отказ', async () => {
  const body = new URLSearchParams({ OutSum: '149.000000', InvId: '7', SignatureValue: '00', Shp_pay: 'aaaa-bbbb' }).toString();
  await assert.rejects(provider('robokassa', rk)!.webhook(incoming(body, { 'content-type': 'application/x-www-form-urlencoded' })), Unauthorized);
  // подмена суммы при верной старой подписи
  const forged = new URLSearchParams({ OutSum: '1.000000', InvId: '7', SignatureValue: '216d1f6ce2b5a6f39bc6101f54986054', Shp_pay: 'aaaa-bbbb' }).toString();
  await assert.rejects(provider('robokassa', rk)!.webhook(incoming(forged, { 'content-type': 'application/x-www-form-urlencoded' })), Unauthorized);
});

test('Робокасса: sha256, если так в настройках магазина', async () => {
  const env = envOf({ ROBOKASSA_LOGIN: 'shop1', ROBOKASSA_PASSWORD1: 'pass1', ROBOKASSA_PASSWORD2: 'pass2', ROBOKASSA_HASH: 'SHA256' });
  const body = new URLSearchParams({ OutSum: '149.000000', InvId: '7', SignatureValue: await digest('sha256', '149.000000:7:pass2:Shp_pay=aaaa-bbbb'), Shp_pay: 'aaaa-bbbb' }).toString();
  const h = await provider('robokassa', env)!.webhook(incoming(body, { 'content-type': 'application/x-www-form-urlencoded' }));
  assert.equal(h.events.length, 1);
});

test('Робокасса: продление по номеру первого счёта', async () => {
  const { http, calls } = fake([() => new Response('OK12')]);
  const r = await provider('robokassa', rk, http)!.charge!({ ...pay, seq: 12, token: '7', parent_seq: 7 });
  assert.deepEqual(r, { status: 'pending', providerId: '12' });
  const f = new URLSearchParams(calls[0].body);
  assert.equal(calls[0].url, 'https://auth.robokassa.ru/Merchant/Recurring');
  assert.equal(f.get('InvoiceID'), '12');
  assert.equal(f.get('PreviousInvoiceID'), '7');
  assert.equal(f.get('SignatureValue'), await digest('md5', 'shop1:149.00:12:pass1:Shp_pay=aaaa-bbbb'));
  assert.equal(provider('robokassa', rk)!.refund, undefined, 'возврат — вручную');
});

// ---------------------------------------------------------------- CloudPayments

const cp = envOf({ CLOUDPAYMENTS_PUBLIC_ID: 'pk_1', CLOUDPAYMENTS_API_SECRET: 'secret' });

test('CloudPayments: счёт со ссылкой', async () => {
  const { http, calls } = fake([() => Response.json({ Success: true, Model: { Id: 'ord-1', Url: 'https://orders.cloudpayments.ru/d/x' } })]);
  const r = await provider('cloudpayments', cp, http)!.create(pay, urls);
  assert.deepEqual(r, { providerId: 'ord-1', url: 'https://orders.cloudpayments.ru/d/x' });
  const b = JSON.parse(calls[0].body);
  assert.equal(b.Amount, 149);
  assert.equal(b.InvoiceId, 'aaaa-bbbb');
  assert.equal(b.SuccessRedirectUrl, urls.returnUrl);
});

test('CloudPayments: уведомление Pay с проверкой HMAC', async () => {
  const body = 'InvoiceId=aaaa-bbbb&TransactionId=555&Amount=149.00&Currency=RUB&Status=Completed&Token=tk_1&CardLastFour=4242';
  const h = await provider('cloudpayments', cp)!.webhook(incoming(body, {
    'content-type': 'application/x-www-form-urlencoded', 'content-hmac': await hmacBase64('secret', body),
  }, 'https://s/functions/v1/billing-webhook?p=cloudpayments&n=pay'));
  assert.deepEqual(h.events, [{
    kind: 'paid', paymentId: 'aaaa-bbbb', providerId: '555', amountMinor: 14900, currency: 'RUB', token: 'tk_1', methodTitle: 'Карта •• 4242',
  }]);
  assert.deepEqual(await h.reply.json(), { code: 0 });
});

test('CloudPayments: Fail и чужая подпись', async () => {
  const body = 'InvoiceId=aaaa-bbbb&TransactionId=556&Amount=149.00&Currency=RUB&Reason=InsufficientFunds';
  const p = provider('cloudpayments', cp)!;
  const h = await p.webhook(incoming(body, { 'content-hmac': await hmacBase64('secret', body) }, 'https://s/x?p=cloudpayments&n=fail'));
  assert.deepEqual(h.events, [{ kind: 'failed', paymentId: 'aaaa-bbbb', providerId: '556', reason: 'InsufficientFunds' }]);
  await assert.rejects(p.webhook(incoming(body, { 'content-hmac': 'AAAA' })), Unauthorized);
});

test('CloudPayments: продление по токену — по расписанию, инициатор магазин', async () => {
  const { http, calls } = fake([() => Response.json({ Success: true, Model: { TransactionId: 777, Status: 'Completed' } })]);
  const r = await provider('cloudpayments', cp, http)!.charge!({ ...pay, token: 'tk_1' });
  assert.deepEqual(r, { status: 'succeeded', providerId: '777' });
  const b = JSON.parse(calls[0].body);
  assert.equal(calls[0].url, 'https://api.cloudpayments.ru/payments/tokens/charge');
  assert.equal(b.Token, 'tk_1');
  assert.equal(b.TrInitiatorCode, 0);
  assert.equal(b.PaymentScheduled, 1);
});

// ---------------------------------------------------------------- bePaid

const bp = envOf({ BEPAID_SHOP_ID: '361', BEPAID_SECRET_KEY: 'bsk' });
const byn: Payment = { ...pay, currency: 'BYN', amount_minor: 990 };

test('bePaid: страница оплаты в копейках, с контрактом на продление', async () => {
  const { http, calls } = fake([() => Response.json({ checkout: { token: 'ck-1', redirect_url: 'https://checkout.bepaid.by/v2/checkout?token=ck-1' } })]);
  const r = await provider('bepaid', bp, http)!.create(byn, urls);
  assert.deepEqual(r, { providerId: 'ck-1', url: 'https://checkout.bepaid.by/v2/checkout?token=ck-1' });
  const c = JSON.parse(calls[0].body).checkout;
  assert.equal(calls[0].headers['x-api-version'], '2');
  assert.equal(c.order.amount, 990);
  assert.equal(c.order.currency, 'BYN');
  assert.equal(c.order.tracking_id, 'aaaa-bbbb');
  assert.deepEqual(c.order.additional_data.contract, ['recurring']);
  assert.equal(c.settings.notification_url, urls.notifyUrl);
  assert.equal(c.test, false);
});

test('bePaid: уведомление — только с авторизацией магазина, и перепроверяется в API', async () => {
  const { http, calls } = fake([() => Response.json({
    transaction: { uid: 'tx-1', status: 'successful', type: 'payment', amount: 990, currency: 'BYN', tracking_id: 'aaaa-bbbb', credit_card: { last_4: '1111', token: 'ct-1' } },
  })]);
  const p = provider('bepaid', bp, http)!;
  const body = JSON.stringify({ transaction: { uid: 'tx-1', status: 'successful' } });
  await assert.rejects(p.webhook(incoming(body, { authorization: 'Basic eDp5' })), Unauthorized);
  const h = await p.webhook(incoming(body, { authorization: `Basic ${btoa('361:bsk')}` }));
  assert.equal(calls[0].url, 'https://gateway.bepaid.by/transactions/tx-1');
  assert.deepEqual(h.events, [{
    kind: 'paid', paymentId: 'aaaa-bbbb', providerId: 'tx-1', amountMinor: 990, currency: 'BYN', token: 'ct-1', methodTitle: 'Карта •• 1111',
  }]);
});

test('bePaid: продление по токену карты и возврат', async () => {
  const { http, calls } = fake([
    () => Response.json({ transaction: { uid: 'tx-2', status: 'successful' } }),
    () => Response.json({ transaction: { uid: 'rf-1', status: 'successful' } }),
  ]);
  const p = provider('bepaid', bp, http)!;
  assert.deepEqual(await p.charge!({ ...byn, token: 'ct-1' }), { status: 'succeeded', providerId: 'tx-2' });
  assert.equal(JSON.parse(calls[0].body).request.credit_card.token, 'ct-1');
  await p.refund!({ providerId: 'tx-1', amountMinor: 500, currency: 'BYN' });
  assert.deepEqual(JSON.parse(calls[1].body).request.parent_uid, 'tx-1');
  assert.equal(JSON.parse(calls[1].body).request.amount, 500);
});
