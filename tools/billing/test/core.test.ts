// Функции подписки целиком: база, сервис и почта подменены, проверяется порядок вызовов и ответы.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkout, refund, renew, webhook, type Deps } from '../supabase/functions/_shared/core.ts';
import { DbError } from '../supabase/functions/_shared/db.ts';
import type { Letter } from '../supabase/functions/_shared/mail.ts';
import { Unauthorized, type Payment, type Provider } from '../supabase/functions/_shared/providers/types.ts';

type Rpc = { fn: string; args: Record<string, unknown> };

function world(o: {
  env?: Record<string, string>;
  rpc?: Record<string, (args: Record<string, unknown>) => unknown>;
  provider?: Partial<Provider>;
  user?: { id: string; email: string } | null;
  mailFails?: boolean;
} = {}) {
  const rpcs: Rpc[] = [];
  const letters: Letter[] = [];
  const logs: unknown[][] = [];
  const env: Record<string, string> = {
    SUPABASE_URL: 'https://s.supabase.co', SUPABASE_ANON_KEY: 'anon', BILLING_RETURN_URL: 'https://xfurya.github.io/Starty/pay/',
    BILLING_CRON_SECRET: 'cron', BILLING_OWNER_MAIL: 'owner@x.ru', ...o.env,
  };
  const user = o.user === undefined ? { id: 'u-1', email: 'fan@example.ru' } : o.user;
  const prov: Provider = {
    id: 'yookassa',
    create: async () => ({ providerId: 'yk-1', url: 'https://pay.example/1' }),
    webhook: async () => ({ events: [], reply: new Response('ok') }),
    ...o.provider,
  } as Provider;
  const d: Deps = {
    env: (k) => env[k],
    db: {
      async rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
        rpcs.push({ fn, args });
        const h = o.rpc?.[fn];
        return (h ? h(args) : null) as T;
      },
    },
    http: (async (input: string | URL | Request, init?: RequestInit) => {
      // вход человека: /auth/v1/user
      assert.match(String(input), /\/auth\/v1\/user$/);
      const auth = new Headers(init?.headers).get('authorization');
      return user && auth === 'Bearer good' ? Response.json(user) : new Response('{}', { status: 401 });
    }) as typeof fetch,
    mail: {
      async send(l) {
        if (o.mailFails) throw new Error('smtp down');
        letters.push(l);
      },
    },
    provider: (id) => (id === 'yookassa' ? prov : null),
    now: () => new Date('2026-12-01T10:00:00Z'),
    log: (...a) => logs.push(a),
  };
  return { d, rpcs, letters, logs };
}

const post = (body: unknown, headers: Record<string, string> = { authorization: 'Bearer good' }, url = 'https://s/functions/v1/x') =>
  new Request(url, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) });

const started: Payment = {
  payment_id: 'p-1', seq: 7, user_id: 'u-1', email: 'fan@example.ru', plan_id: 'month', title: 'Месяц',
  period_days: 30, amount_minor: 14900, currency: 'RUB', provider: 'yookassa', save_method: true,
};

// ---------------------------------------------------------------- checkout

test('оплата: без входа — 401, база не трогается', async () => {
  const w = world({ user: null });
  const r = await checkout(w.d)(post({ plan: 'month' }));
  assert.equal(r.status, 401);
  assert.equal(w.rpcs.length, 0);
});

test('оплата: выключено — 409 billing_off', async () => {
  const w = world({ rpc: { billing_start: () => { throw new DbError('billing_off', 400); } } });
  const r = await checkout(w.d)(post({ plan: 'month', renew: false, offer_version: 'v1' }));
  assert.equal(r.status, 409);
  assert.deepEqual(await r.json(), { error: 'billing_off' });
});

test('оплата: согласие с текстом, ссылка на сервис, номер у сервиса записан', async () => {
  let seen: Payment | null = null;
  let back = '';
  const w = world({
    rpc: { billing_start: () => started },
    provider: { create: async (p, u) => { seen = p; back = u.returnUrl; return { providerId: 'yk-1', url: 'https://pay.example/1' }; } },
  });
  const r = await checkout(w.d)(post(
    { plan: 'month', renew: true, offer_version: 'v1', consent: 'Списывать 149 ₽ каждые 30 дней' },
    { authorization: 'Bearer good', 'x-forwarded-for': '1.2.3.4, 10.0.0.1', 'user-agent': 'starty/1.0.61' },
  ));
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { payment_id: 'p-1', url: 'https://pay.example/1', return_url: 'https://xfurya.github.io/Starty/pay/' });
  assert.deepEqual(w.rpcs[0], {
    fn: 'billing_start',
    args: { _uid: 'u-1', _plan: 'month', _renew: true, _offer_version: 'v1', _consent: 'Списывать 149 ₽ каждые 30 дней', _ip: '1.2.3.4', _ua: 'starty/1.0.61' },
  });
  assert.deepEqual(w.rpcs[1], { fn: 'billing_attach', args: { _payment: 'p-1', _provider_id: 'yk-1' } });
  assert.equal(seen!.payment_id, 'p-1');
  assert.equal(back, 'https://xfurya.github.io/Starty/pay/?pay=p-1');
});

test('оплата: без продления текст согласия не пишется', async () => {
  const w = world({ rpc: { billing_start: () => ({ ...started, save_method: false }) } });
  await checkout(w.d)(post({ plan: 'month', renew: false, offer_version: 'v1', consent: 'что-то' }));
  assert.equal(w.rpcs[0].args._consent, null);
  assert.equal(w.rpcs[0].args._renew, false);
});

test('оплата: сервис не ответил — платёж отменён, 502', async () => {
  const w = world({ rpc: { billing_start: () => started }, provider: { create: async () => { throw new Error('timeout'); } } });
  const r = await checkout(w.d)(post({ plan: 'month', offer_version: 'v1' }));
  assert.equal(r.status, 502);
  assert.equal(w.rpcs[1].fn, 'billing_failed');
  assert.equal(w.rpcs[1].args._payment, 'p-1');
});

test('оплата: сервер не настроен — 503, не 500', async () => {
  const w = world({ env: { BILLING_RETURN_URL: '' }, rpc: { billing_start: () => started } });
  const r = await checkout(w.d)(post({ plan: 'month', offer_version: 'v1' }));
  assert.equal(r.status, 503);
});

// ---------------------------------------------------------------- webhook

test('уведомление: оплата засчитана с суммой, токеном и картой', async () => {
  const w = world({
    provider: { webhook: async () => ({ events: [{ kind: 'paid', paymentId: 'p-1', providerId: 'yk-1', amountMinor: 14900, currency: 'RUB', token: 'pm-1', methodTitle: 'Карта •• 4242' }], reply: new Response('ok') }) },
  });
  const r = await webhook(w.d)(post('{}', {}, 'https://s/functions/v1/billing-webhook?p=yookassa'));
  assert.equal(r.status, 200);
  assert.deepEqual(w.rpcs, [{ fn: 'billing_paid', args: { _payment: 'p-1', _provider_id: 'yk-1', _amount: 14900, _currency: 'RUB', _token: 'pm-1', _method: 'Карта •• 4242' } }]);
});

test('уведомление: платёж по номеру счёта или по номеру у сервиса', async () => {
  const w = world({
    rpc: { billing_payment_by_seq: () => 'p-7', billing_payment_by_provider: () => 'p-9' },
    provider: { webhook: async () => ({ events: [{ kind: 'paid', seq: 7, amountMinor: 1, currency: 'RUB' }, { kind: 'failed', providerId: 'x-9', reason: 'declined' }], reply: new Response('OK7') }) },
  });
  const r = await webhook(w.d)(post('', {}, 'https://s/x?p=yookassa'));
  assert.equal(await r.text(), 'OK7');
  assert.deepEqual(w.rpcs.map((c) => c.fn), ['billing_payment_by_seq', 'billing_paid', 'billing_payment_by_provider', 'billing_failed']);
  assert.equal(w.rpcs[1].args._payment, 'p-7');
  assert.deepEqual(w.rpcs[3].args, { _payment: 'p-9', _reason: 'declined' });
});

test('уведомление: подпись не сошлась — 401, база не трогается', async () => {
  const w = world({ provider: { webhook: async () => { throw new Unauthorized('x'); } } });
  const r = await webhook(w.d)(post('', {}, 'https://s/x?p=yookassa'));
  assert.equal(r.status, 401);
  assert.equal(w.rpcs.length, 0);
});

test('уведомление: сумма не та — не засчитано, сервису «принято», в журнал функции', async () => {
  const w = world({
    rpc: { billing_paid: () => { throw new DbError('amount_mismatch', 400); } },
    provider: { webhook: async () => ({ events: [{ kind: 'paid', paymentId: 'p-1', amountMinor: 100, currency: 'RUB' }], reply: new Response('ok') }) },
  });
  const r = await webhook(w.d)(post('', {}, 'https://s/x?p=yookassa'));
  assert.equal(r.status, 200);
  assert.ok(w.logs.some((l) => l.includes('amount_mismatch')));
});

test('уведомление: база недоступна — 500, сервис повторит', async () => {
  const w = world({
    rpc: { billing_paid: () => { throw new DbError('http_503', 503); } },
    provider: { webhook: async () => ({ events: [{ kind: 'paid', paymentId: 'p-1', amountMinor: 100, currency: 'RUB' }], reply: new Response('ok') }) },
  });
  await assert.rejects(webhook(w.d)(post('', {}, 'https://s/x?p=yookassa')));
});

test('уведомление: неизвестный сервис — 404', async () => {
  const w = world();
  assert.equal((await webhook(w.d)(post('', {}, 'https://s/x?p=paypal'))).status, 404);
});

// ---------------------------------------------------------------- refund

test('возврат: через сервис, где умеет; вручную — заявка и письмо владельцу', async () => {
  const refunds: unknown[] = [];
  const w = world({
    rpc: {
      billing_refund_begin: () => [
        { payment_id: 'p-1', provider: 'yookassa', provider_id: 'yk-1', amount: 12000, currency: 'RUB' },
        { payment_id: 'p-2', provider: 'robokassa', provider_id: '8', amount: 14900, currency: 'RUB' },
      ],
    },
    provider: { refund: async (r) => { refunds.push(r); } },
  });
  const r = await refund(w.d)(post({}));
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { refunded_minor: 12000, manual_minor: 14900, currency: 'RUB' });
  assert.deepEqual(w.rpcs.map((c) => [c.fn, c.args._manual]), [
    ['billing_refund_begin', undefined], ['billing_refunded', false], ['billing_refunded', true],
  ]);
  assert.equal((refunds[0] as { providerId: string }).providerId, 'yk-1');
  assert.equal(w.letters.length, 1);
  assert.equal(w.letters[0].to, 'owner@x.ru');
  assert.match(w.letters[0].text, /fan@example\.ru/);
});

test('возврат: сервис отказал — переходит в ручной, деньги не теряются', async () => {
  const w = world({
    rpc: { billing_refund_begin: () => [{ payment_id: 'p-1', provider: 'yookassa', provider_id: 'yk-1', amount: 12000, currency: 'RUB' }] },
    provider: { refund: async () => { throw new Error('declined'); } },
  });
  const r = await refund(w.d)(post({}));
  assert.deepEqual(await r.json(), { refunded_minor: 0, manual_minor: 12000, currency: 'RUB' });
  assert.equal(w.rpcs[1].args._manual, true);
  assert.match(w.letters[0].text, /declined/);
});

test('возврат: вернуть нечего — нули', async () => {
  const w = world({ rpc: { billing_refund_begin: () => [] } });
  const r = await refund(w.d)(post({}));
  assert.deepEqual(await r.json(), { refunded_minor: 0, manual_minor: 0, currency: null });
  assert.equal(w.letters.length, 0);
});

test('возврат: без входа — 401', async () => {
  const w = world();
  assert.equal((await refund(w.d)(post({}, { authorization: 'Bearer bad' }))).status, 401);
  assert.equal(w.rpcs.length, 0);
});

// ---------------------------------------------------------------- renew

const notice = {
  user_id: 'u-1', email: 'fan@example.ru', paid_until: '2026-12-03T10:00:00Z', amount: 14900, currency: 'RUB',
  plan_title: 'Месяц', method_title: 'Карта •• 4242', seller: 'Продавец',
};

test('расписание: без секрета — 401', async () => {
  const w = world();
  assert.equal((await renew(w.d)(post({}, {}))).status, 401);
  assert.equal((await renew(w.d)(post({}, { authorization: 'Bearer nope' }))).status, 401);
  assert.equal((await renew(world({ env: { BILLING_CRON_SECRET: '' } }).d)(post({}, { authorization: 'Bearer ' }))).status, 401);
  assert.equal(w.rpcs.length, 0);
});

test('расписание: напоминание ушло — отмечено; продление списано и засчитано', async () => {
  const w = world({
    rpc: {
      billing_notices_due: () => [notice],
      billing_renewals_start: () => [{ ...started, payment_id: 'p-5', seq: 12, token: 'pm-1', save_method: true }],
    },
    provider: { charge: async () => ({ status: 'succeeded', providerId: 'yk-5' }) },
  });
  const r = await renew(w.d)(post({}, { authorization: 'Bearer cron' }));
  assert.deepEqual(await r.json(), { notices: 1, unsent: 0, succeeded: 1, pending: 0, failed: 0 });
  assert.equal(w.letters[0].to, 'fan@example.ru');
  assert.deepEqual(w.rpcs.map((c) => c.fn), ['billing_notices_due', 'billing_noticed', 'billing_renewals_start', 'billing_attach', 'billing_paid']);
  assert.deepEqual(w.rpcs[1].args, { _uid: 'u-1', _for: '2026-12-03T10:00:00Z', _amount: 14900 });
  assert.deepEqual(w.rpcs[4].args, { _payment: 'p-5', _provider_id: 'yk-5', _amount: 14900, _currency: 'RUB', _token: null, _method: null });
  assert.equal(w.rpcs[0].args._at, '2026-12-01T10:00:00.000Z');
});

test('расписание: письмо не ушло — напоминание не отмечено (значит, и списания не будет)', async () => {
  const w = world({ mailFails: true, rpc: { billing_notices_due: () => [notice], billing_renewals_start: () => [] } });
  const r = await renew(w.d)(post({}, { 'x-cron-secret': 'cron' }));
  assert.deepEqual(await r.json(), { notices: 0, unsent: 1, succeeded: 0, pending: 0, failed: 0 });
  assert.ok(!w.rpcs.some((c) => c.fn === 'billing_noticed'));
});

test('расписание: отказ банка — неуспех; ждёт — оставляем; сервис без списаний — неуспех', async () => {
  const results = [
    { status: 'failed' as const, providerId: 'yk-6', reason: 'insufficient_funds' },
    { status: 'pending' as const, providerId: 'yk-7' },
  ];
  const w = world({
    rpc: {
      billing_notices_due: () => [],
      // старые PostgREST отдают setof jsonb как {имя: значение}
      billing_renewals_start: () => [
        { billing_renewals_start: { ...started, payment_id: 'p-6', token: 'pm' } },
        { ...started, payment_id: 'p-7', token: 'pm' },
        { ...started, payment_id: 'p-8', provider: 'nowhere', token: 'pm' },
      ],
    },
    provider: { charge: async () => results.shift()! },
  });
  const r = await renew(w.d)(post({}, { authorization: 'Bearer cron' }));
  assert.deepEqual(await r.json(), { notices: 0, unsent: 0, succeeded: 0, pending: 1, failed: 2 });
  const failed = w.rpcs.filter((c) => c.fn === 'billing_failed').map((c) => c.args);
  assert.deepEqual(failed, [{ _payment: 'p-6', _reason: 'insufficient_funds' }, { _payment: 'p-8', _reason: 'no_provider' }]);
  assert.ok(!w.rpcs.some((c) => c.fn === 'billing_paid'));
});
