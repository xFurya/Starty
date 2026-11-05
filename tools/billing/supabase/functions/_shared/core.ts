// Четыре функции подписки. Всё внешнее (база, сервисы, почта, часы) — в Deps, чтобы проверять без сети.
//   billing-checkout — начать оплату: страница сервиса для встроенного браузера приложения;
//   billing-webhook  — уведомления сервисов (?p=yookassa|robokassa|cloudpayments|bepaid);
//   billing-refund   — отказ с возвратом за неиспользованные дни;
//   billing-renew    — раз в час по расписанию: напоминания и продления.
// Пока billing_config.enabled = false, billing_start отвечает billing_off, а напоминаний и продлений нет:
// код на месте, но ничего не происходит.

import { Config, type Env, need, systemEnv } from './env.ts';
import { type Db, DbError, type Fetch, postgrest, type User, userOf } from './db.ts';
import { ipOf, json, preflight } from './http.ts';
import { type Mailer, type Manual, type Notice, noticeLetter, ownerLetter, resend } from './mail.ts';
import { provider } from './providers/index.ts';
import { type Payment, type Provider, Unauthorized } from './providers/types.ts';

export type Deps = {
  env: Env;
  db: Db;
  http: Fetch;
  mail: Mailer;
  provider: (id: string) => Provider | null;
  now: () => Date;
  log?: (...a: unknown[]) => void;
};

const known = new Set(['billing_off', 'offer_changed', 'no_plan', 'no_email', 'already_active', 'not_signed_in']);

async function signedIn(d: Deps, req: Request): Promise<User | null> {
  return userOf(d.env, req.headers.get('authorization'), d.http);
}

/** Обёртка: OPTIONS, только POST, ненастроенный сервер — 503, прочее — 500 без подробностей наружу. */
function guarded(d: Deps, fn: (req: Request) => Promise<Response>) {
  return async (req: Request): Promise<Response> => {
    if (req.method === 'OPTIONS') return preflight();
    if (req.method !== 'POST') return json(405, { error: 'method' });
    try {
      return await fn(req);
    } catch (e) {
      if (e instanceof Config) {
        d.log?.('billing config', e.message);
        return json(503, { error: 'not_configured' });
      }
      if (e instanceof DbError && known.has(e.message)) return json(409, { error: e.message });
      d.log?.('billing error', e);
      return json(500, { error: 'internal' });
    }
  };
}

// ---------------------------------------------------------------- начать оплату

export function checkout(d: Deps) {
  return guarded(d, async (req) => {
    const user = await signedIn(d, req);
    if (!user) return json(401, { error: 'not_signed_in' });
    const b = (await req.json().catch(() => ({}))) as Record<string, unknown>;
    const plan = typeof b.plan === 'string' ? b.plan : '';
    const renew = b.renew === true;
    const start = await d.db.rpc<Payment>('billing_start', {
      _uid: user.id,
      _plan: plan,
      _renew: renew,
      _offer_version: typeof b.offer_version === 'string' ? b.offer_version : null,
      // текст согласия ровно тот, что был на экране, — его и хранит журнал
      _consent: renew && typeof b.consent === 'string' ? b.consent.slice(0, 2000) : null,
      _ip: ipOf(req),
      _ua: (req.headers.get('user-agent') ?? '').slice(0, 300),
    });
    const prov = d.provider(start.provider);
    if (!prov) {
      await d.db.rpc('billing_failed', { _payment: start.payment_id, _reason: `no provider ${start.provider}` });
      return json(503, { error: 'not_configured' });
    }
    const back = new URL(need(d.env, 'BILLING_RETURN_URL'));
    back.searchParams.set('pay', start.payment_id);
    const notify = `${need(d.env, 'SUPABASE_URL')}/functions/v1/billing-webhook?p=${prov.id}`;
    let created;
    try {
      created = await prov.create(start, { returnUrl: back.toString(), notifyUrl: notify });
    } catch (e) {
      d.log?.('billing create', e);
      await d.db.rpc('billing_failed', { _payment: start.payment_id, _reason: `create: ${String(e).slice(0, 300)}` });
      return json(e instanceof Config ? 503 : 502, { error: e instanceof Config ? 'not_configured' : 'provider' });
    }
    if (created.providerId) await d.db.rpc('billing_attach', { _payment: start.payment_id, _provider_id: created.providerId });
    // приложение ведёт человека по url во встроенном браузере и закрывает его, дойдя до return_url
    return json(200, { payment_id: start.payment_id, url: created.url, return_url: back.origin + back.pathname });
  });
}

// ---------------------------------------------------------------- уведомления сервисов

export function webhook(d: Deps) {
  return async (req: Request): Promise<Response> => {
    const url = new URL(req.url);
    const prov = d.provider(url.searchParams.get('p') ?? '');
    if (!prov) return new Response('unknown provider', { status: 404 });
    const body = req.method === 'GET' ? '' : await req.text();
    let hook;
    try {
      hook = await prov.webhook({ headers: req.headers, body, url });
    } catch (e) {
      if (e instanceof Unauthorized) {
        d.log?.('billing webhook: bad signature', prov.id);
        return new Response('unauthorized', { status: 401 });
      }
      // сервис повторит уведомление позже
      d.log?.('billing webhook', prov.id, e);
      return new Response('retry', { status: e instanceof Config ? 503 : 500 });
    }
    for (const ev of hook.events) {
      const id = ev.paymentId ??
        (ev.seq ? await d.db.rpc<string | null>('billing_payment_by_seq', { _seq: ev.seq }) : null) ??
        (ev.providerId ? await d.db.rpc<string | null>('billing_payment_by_provider', { _provider: prov.id, _provider_id: ev.providerId }) : null);
      if (!id) {
        d.log?.('billing webhook: unknown payment', prov.id, ev);
        continue;
      }
      try {
        if (ev.kind === 'paid') {
          await d.db.rpc('billing_paid', {
            _payment: id,
            _provider_id: ev.providerId ?? null,
            _amount: ev.amountMinor ?? null,
            _currency: ev.currency ?? null,
            _token: ev.token ?? null,
            _method: ev.methodTitle ?? null,
          });
        } else {
          await d.db.rpc('billing_failed', { _payment: id, _reason: (ev.reason ?? 'failed').slice(0, 300) });
        }
      } catch (e) {
        // сумма не та или платежа нет: повтор уведомления этого не исправит — в журнал функции, сервису «принято»
        if (e instanceof DbError && (e.message === 'amount_mismatch' || e.message === 'no_payment')) {
          d.log?.('billing webhook: rejected', e.message, prov.id, ev);
          continue;
        }
        throw e;
      }
    }
    return hook.reply;
  };
}

// ---------------------------------------------------------------- отказ с возвратом

type RefundRow = { payment_id: string; provider: string; provider_id: string | null; amount: number; currency: string };

export function refund(d: Deps) {
  return guarded(d, async (req) => {
    const user = await signedIn(d, req);
    if (!user) return json(401, { error: 'not_signed_in' });
    // сроки обрезаются и подписка закрывается сразу, в одной транзакции: второе нажатие получит пусто
    const rows = await d.db.rpc<RefundRow[]>('billing_refund_begin', { _uid: user.id });
    let done = 0;
    const manual: Manual[] = [];
    for (const r of rows ?? []) {
      const prov = d.provider(r.provider);
      if (prov?.refund && r.provider_id) {
        try {
          await prov.refund({ providerId: r.provider_id, amountMinor: r.amount, currency: r.currency, email: user.email ?? undefined, title: 'Возврат за подписку «Фигурное катание»' });
          await d.db.rpc('billing_refunded', { _payment: r.payment_id, _amount: r.amount, _manual: false });
          done += r.amount;
          continue;
        } catch (e) {
          d.log?.('billing refund', r.payment_id, e);
          manual.push({ ...r, reason: `сервис не принял возврат: ${String(e).slice(0, 200)}` });
        }
      } else {
        manual.push({ ...r, reason: prov ? 'у сервиса нет возврата через API' : 'сервис не настроен' });
      }
      await d.db.rpc('billing_refunded', { _payment: r.payment_id, _amount: r.amount, _manual: true });
    }
    if (manual.length) {
      const owner = d.env('BILLING_OWNER_MAIL');
      try {
        if (!owner) throw new Config('не задано BILLING_OWNER_MAIL');
        await d.mail.send(ownerLetter(owner, user.email, manual));
      } catch (e) {
        // заявка всё равно в журнале (refund_requested) — письмо только напоминание
        d.log?.('billing owner mail', e);
      }
    }
    const currency = rows?.[0]?.currency ?? null;
    return json(200, {
      refunded_minor: done,
      manual_minor: manual.reduce((s, m) => s + m.amount, 0),
      currency,
    });
  });
}

// ---------------------------------------------------------------- напоминания и продления

export function renew(d: Deps) {
  return async (req: Request): Promise<Response> => {
    const secret = d.env('BILLING_CRON_SECRET');
    const got = /^Bearer\s+(.+)$/i.exec(req.headers.get('authorization') ?? '')?.[1] ?? req.headers.get('x-cron-secret');
    if (!secret || got !== secret) return json(401, { error: 'unauthorized' });
    const at = d.now().toISOString();
    let notices = 0;
    let unsent = 0;
    for (const n of (await d.db.rpc<Notice[]>('billing_notices_due', { _at: at })) ?? []) {
      try {
        await d.mail.send(noticeLetter(n));
      } catch (e) {
        // без напоминания не списываем: следующий запуск попробует снова
        d.log?.('billing notice', n.user_id, e);
        unsent++;
        continue;
      }
      await d.db.rpc('billing_noticed', { _uid: n.user_id, _for: n.paid_until, _amount: n.amount });
      notices++;
    }
    const tally = { succeeded: 0, pending: 0, failed: 0 };
    for (const p of unwrap<Payment>(await d.db.rpc('billing_renewals_start', { _at: at }), 'billing_renewals_start')) {
      const prov = d.provider(p.provider);
      if (!prov?.charge) {
        await d.db.rpc('billing_failed', { _payment: p.payment_id, _reason: prov ? 'no_charge' : 'no_provider' });
        tally.failed++;
        continue;
      }
      const c = await prov.charge(p);
      if (c.providerId) await d.db.rpc('billing_attach', { _payment: p.payment_id, _provider_id: c.providerId });
      if (c.status === 'succeeded') {
        await d.db.rpc('billing_paid', {
          _payment: p.payment_id, _provider_id: c.providerId, _amount: p.amount_minor, _currency: p.currency, _token: null, _method: null,
        });
      } else if (c.status === 'failed') {
        await d.db.rpc('billing_failed', { _payment: p.payment_id, _reason: (c.reason ?? 'declined').slice(0, 300) });
      }
      tally[c.status]++;
    }
    return json(200, { notices, unsent, ...tally });
  };
}

// setof jsonb PostgREST отдаёт плоским списком; старые версии — списком {имя_функции: значение}
function unwrap<T>(v: unknown, fn: string): T[] {
  if (!Array.isArray(v)) return [];
  return v.map((x) => (x && typeof x === 'object' && fn in x && Object.keys(x).length === 1 ? (x as Record<string, T>)[fn] : x as T));
}

// ---------------------------------------------------------------- в Supabase

export function live(): Deps {
  const env = systemEnv();
  return {
    env,
    db: lazyDb(() => postgrest(env)),
    http: fetch,
    mail: resend(env),
    provider: (id) => provider(id, env),
    now: () => new Date(),
    log: (...a) => console.error(...a),
  };
}

// база создаётся при первом запросе: без SUPABASE_URL функция отвечает 503, а не падает при запуске
function lazyDb(make: () => Db): Db {
  let db: Db | null = null;
  return { rpc: (fn, args) => (db ??= make()).rpc(fn, args) };
}

