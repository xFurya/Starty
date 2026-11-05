// ЮKassa (API v3). Россия; работает и с самозанятыми — чеки в «Мой налог» отправляет сама.
// Секреты: YOOKASSA_SHOP_ID, YOOKASSA_SECRET_KEY; YOOKASSA_RECEIPT = self (самозанятый, по умолчанию) |
// 54fz (ИП с онлайн-кассой ЮKassa) | none; YOOKASSA_VAT_CODE для 54fz (1 — без НДС).
// Продление — автоплатежи: их включает ЮKassa по заявке в кабинете.
// Уведомления подписи не имеют: каждое перепроверяется запросом платежа в API.

import { need } from '../env.ts';
import { decimal, minor } from '../money.ts';
import {
  basic, cardTitle, description, ProviderError,
  type Charged, type Deps, type Event, type Hook, type Payment, type Provider,
} from './types.ts';

const api = 'https://api.yookassa.ru/v3';

type YkPayment = {
  id: string;
  status: 'pending' | 'waiting_for_capture' | 'succeeded' | 'canceled';
  amount?: { value: string; currency: string };
  metadata?: Record<string, string>;
  payment_method?: { id?: string; saved?: boolean; card?: { last4?: string } };
  confirmation?: { confirmation_url?: string };
  cancellation_details?: { reason?: string };
};

export function yookassa({ env, fetch: http }: Deps): Provider {
  const auth = () => basic(need(env, 'YOOKASSA_SHOP_ID'), need(env, 'YOOKASSA_SECRET_KEY'));

  async function call<T>(method: 'GET' | 'POST', path: string, body?: unknown, key?: string): Promise<T> {
    const r = await http(`${api}${path}`, {
      method,
      headers: {
        Authorization: auth(),
        'Content-Type': 'application/json',
        ...(key ? { 'Idempotence-Key': key } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new ProviderError(`ЮKassa ${r.status}: ${(j as { description?: string }).description ?? ''}`);
    return j as T;
  }

  function receipt(p: { email?: string; title: string; amount: number; currency: string }) {
    const mode = env('YOOKASSA_RECEIPT') ?? 'self';
    if (mode === 'none' || !p.email) return undefined;
    const item: Record<string, unknown> = {
      description: p.title.slice(0, 128),
      quantity: '1',
      amount: { value: decimal(p.amount), currency: p.currency },
    };
    if (mode === '54fz') {
      item.vat_code = Number(env('YOOKASSA_VAT_CODE') ?? '1');
      item.payment_subject = 'service';
      item.payment_mode = 'full_payment';
    }
    return { customer: { email: p.email }, items: [item] };
  }

  function event(y: YkPayment): Event | null {
    const paymentId = y.metadata?.payment_id;
    if (!paymentId) return null;
    if (y.status === 'succeeded') {
      const saved = y.payment_method?.saved && y.payment_method.id;
      return {
        kind: 'paid',
        paymentId,
        providerId: y.id,
        amountMinor: minor(y.amount?.value) ?? undefined,
        currency: y.amount?.currency,
        token: saved ? y.payment_method!.id! : null,
        methodTitle: saved ? cardTitle(y.payment_method?.card?.last4) : null,
      };
    }
    if (y.status === 'canceled') {
      return { kind: 'failed', paymentId, providerId: y.id, reason: y.cancellation_details?.reason ?? 'canceled' };
    }
    return null;
  }

  return {
    id: 'yookassa',

    async create(p, { returnUrl }) {
      const y = await call<YkPayment>('POST', '/payments', {
        amount: { value: decimal(p.amount_minor), currency: p.currency },
        capture: true,
        confirmation: { type: 'redirect', return_url: returnUrl, locale: 'ru_RU' },
        description: description(p).slice(0, 128),
        save_payment_method: !!p.save_method,
        metadata: { payment_id: p.payment_id },
        receipt: receipt({ email: p.email, title: description(p), amount: p.amount_minor, currency: p.currency }),
      }, p.payment_id);
      const url = y.confirmation?.confirmation_url;
      if (!url) throw new ProviderError('ЮKassa не дала страницу оплаты');
      return { providerId: y.id, url };
    },

    async charge(p): Promise<Charged> {
      if (!p.token) return { status: 'failed', providerId: null, reason: 'no_token' };
      try {
        const y = await call<YkPayment>('POST', '/payments', {
          amount: { value: decimal(p.amount_minor), currency: p.currency },
          capture: true,
          payment_method_id: p.token,
          description: description(p).slice(0, 128),
          metadata: { payment_id: p.payment_id },
          receipt: receipt({ email: p.email, title: description(p), amount: p.amount_minor, currency: p.currency }),
        }, p.payment_id);
        if (y.status === 'succeeded') return { status: 'succeeded', providerId: y.id };
        if (y.status === 'canceled') return { status: 'failed', providerId: y.id, reason: y.cancellation_details?.reason };
        return { status: 'pending', providerId: y.id };
      } catch (e) {
        return { status: 'failed', providerId: null, reason: String(e) };
      }
    },

    async refund({ providerId, amountMinor, currency, email, title }) {
      const r = await call<{ status: string }>('POST', '/refunds', {
        payment_id: providerId,
        amount: { value: decimal(amountMinor), currency },
        receipt: receipt({ email, title: title ?? 'Возврат за подписку', amount: amountMinor, currency }),
      }, `refund-${providerId}-${amountMinor}`);
      if (r.status === 'canceled') throw new ProviderError('ЮKassa отклонила возврат');
    },

    async webhook({ body }): Promise<Hook> {
      let j: { event?: string; object?: { id?: string } };
      try {
        j = JSON.parse(body);
      } catch {
        return { events: [], reply: new Response('bad json', { status: 400 }) };
      }
      const id = j.object?.id;
      // уведомление — только повод спросить: что с платежом, говорит API, а не тело запроса
      if (!id || !String(j.event ?? '').startsWith('payment.')) return { events: [], reply: new Response('ok') };
      const y = await call<YkPayment>('GET', `/payments/${encodeURIComponent(id)}`);
      const e = event(y);
      return { events: e ? [e] : [], reply: new Response('ok') };
    },
  };
}
