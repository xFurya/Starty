// bePaid. Беларусь; самозанятые, ИП и организации. Оплата картой на странице bePaid.
// Секреты: BEPAID_SHOP_ID, BEPAID_SECRET_KEY.
// Уведомления bePaid присылает с Basic-авторизацией магазина; каждое ещё и перепроверяется запросом
// транзакции в API. Продление — оплата по токену карты (контракт recurring при первой оплате).

import { need } from '../env.ts';
import { same } from '../hash.ts';
import {
  basic, cardTitle, description, ProviderError, Unauthorized,
  type Charged, type Deps, type Event, type Hook, type Payment, type Provider,
} from './types.ts';

const checkout = 'https://checkout.bepaid.by/ctp/api/checkouts';
const gateway = 'https://gateway.bepaid.by';

type Tx = {
  uid?: string;
  status?: string;
  amount?: number;
  currency?: string;
  tracking_id?: string;
  type?: string;
  message?: string;
  credit_card?: { last_4?: string; token?: string };
};

export function bepaid({ env, fetch: http, test }: Deps): Provider {
  const auth = () => basic(need(env, 'BEPAID_SHOP_ID'), need(env, 'BEPAID_SECRET_KEY'));

  async function call<T>(method: 'GET' | 'POST', url: string, body?: unknown): Promise<T> {
    const r = await http(url, {
      method,
      headers: {
        Authorization: auth(),
        Accept: 'application/json',
        'Content-Type': 'application/json',
        'X-API-Version': '2',
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new ProviderError(`bePaid ${r.status}: ${JSON.stringify(j).slice(0, 200)}`);
    return j as T;
  }

  const failed = new Set(['failed', 'declined', 'expired', 'error']);

  function event(t: Tx): Event | null {
    if (!t.tracking_id || t.type !== 'payment') return null;
    if (t.status === 'successful') {
      return {
        kind: 'paid',
        paymentId: t.tracking_id,
        providerId: t.uid,
        amountMinor: t.amount,
        currency: t.currency,
        token: t.credit_card?.token || null,
        methodTitle: t.credit_card?.token ? cardTitle(t.credit_card.last_4) : null,
      };
    }
    if (t.status && failed.has(t.status)) {
      return { kind: 'failed', paymentId: t.tracking_id, providerId: t.uid, reason: t.message ?? t.status };
    }
    return null;
  }

  return {
    id: 'bepaid',

    async create(p: Payment, { returnUrl, notifyUrl }) {
      const j = await call<{ checkout?: { token?: string; redirect_url?: string } }>('POST', checkout, {
        checkout: {
          test,
          transaction_type: 'payment',
          attempts: 3,
          settings: {
            success_url: returnUrl,
            decline_url: returnUrl,
            fail_url: returnUrl,
            cancel_url: returnUrl,
            notification_url: notifyUrl,
            language: 'ru',
            customer_fields: { read_only: ['email'] },
          },
          order: {
            currency: p.currency,
            amount: p.amount_minor,
            description: description(p),
            tracking_id: p.payment_id,
            ...(p.save_method ? { additional_data: { contract: ['recurring'] } } : {}),
          },
          customer: { email: p.email },
          payment_method: { types: ['credit_card'] },
        },
      });
      const url = j.checkout?.redirect_url;
      if (!url) throw new ProviderError('bePaid не дал страницу оплаты');
      return { providerId: j.checkout?.token ?? null, url };
    },

    async charge(p): Promise<Charged> {
      if (!p.token) return { status: 'failed', providerId: null, reason: 'no_token' };
      try {
        const j = await call<{ transaction?: Tx }>('POST', `${gateway}/transactions/payments`, {
          request: {
            amount: p.amount_minor,
            currency: p.currency,
            description: description(p),
            tracking_id: p.payment_id,
            test,
            credit_card: { token: p.token },
            additional_data: { contract: ['recurring'] },
          },
        });
        const t = j.transaction ?? {};
        if (t.status === 'successful') return { status: 'succeeded', providerId: t.uid ?? null };
        if (t.status === 'incomplete' || t.status === 'pending') return { status: 'pending', providerId: t.uid ?? null };
        return { status: 'failed', providerId: t.uid ?? null, reason: t.message ?? t.status };
      } catch (e) {
        return { status: 'failed', providerId: null, reason: String(e) };
      }
    },

    async refund({ providerId, amountMinor }) {
      const j = await call<{ transaction?: Tx }>('POST', `${gateway}/transactions/refunds`, {
        request: { parent_uid: providerId, amount: amountMinor, reason: 'Отказ от подписки' },
      });
      if (j.transaction?.status !== 'successful') throw new ProviderError(`bePaid: возврат ${j.transaction?.status ?? '—'}`);
    },

    async webhook({ headers, body }): Promise<Hook> {
      if (!same(headers.get('authorization') ?? '', auth())) throw new Unauthorized('авторизация bePaid');
      let j: { transaction?: Tx };
      try {
        j = JSON.parse(body);
      } catch {
        return { events: [], reply: new Response('bad json', { status: 400 }) };
      }
      const uid = j.transaction?.uid;
      if (!uid) return { events: [], reply: new Response('ok') };
      // что с оплатой, говорит API, а не тело запроса
      const fresh = await call<{ transaction?: Tx }>('GET', `${gateway}/transactions/${encodeURIComponent(uid)}`);
      const e = fresh.transaction ? event(fresh.transaction) : null;
      return { events: e ? [e] : [], reply: new Response('ok') };
    },
  };
}
