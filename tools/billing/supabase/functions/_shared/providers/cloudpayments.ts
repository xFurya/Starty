// CloudPayments. Россия; ИП и организации (для самозанятых — уточнить у сервиса).
// Секреты: CLOUDPAYMENTS_PUBLIC_ID, CLOUDPAYMENTS_API_SECRET.
// В кабинете — уведомление Pay на адрес billing-webhook?p=cloudpayments&n=pay, Fail — на …&n=fail
// (кодировка UTF-8, формат любой).
// Продление — оплата по токену карты (payments/tokens/charge), который сервис выдаёт после первой оплаты.

import { need } from '../env.ts';
import { hmacBase64, same } from '../hash.ts';
import { minor } from '../money.ts';
import {
  basic, cardTitle, description, ProviderError, Unauthorized,
  type Charged, type Deps, type Event, type Hook, type Payment, type Provider,
} from './types.ts';

const api = 'https://api.cloudpayments.ru';

type Answer = { Success?: boolean; Message?: string | null; Model?: Record<string, unknown> | null };

export function cloudpayments({ env, fetch: http }: Deps): Provider {
  const secret = () => need(env, 'CLOUDPAYMENTS_API_SECRET');

  async function call(path: string, body: unknown, key?: string): Promise<Answer> {
    const r = await http(`${api}${path}`, {
      method: 'POST',
      headers: {
        Authorization: basic(need(env, 'CLOUDPAYMENTS_PUBLIC_ID'), secret()),
        'Content-Type': 'application/json',
        ...(key ? { 'X-Request-ID': key } : {}),
      },
      body: JSON.stringify(body),
    });
    if (!r.ok) throw new ProviderError(`CloudPayments ${r.status}`);
    return (await r.json()) as Answer;
  }

  const amount = (p: Payment) => p.amount_minor / 100;

  return {
    id: 'cloudpayments',

    async create(p, { returnUrl }) {
      const a = await call('/orders/create', {
        Amount: amount(p),
        Currency: p.currency,
        Description: description(p),
        Email: p.email,
        InvoiceId: p.payment_id,
        AccountId: p.user_id,
        RequireConfirmation: false,
        SendEmail: false,
        SuccessRedirectUrl: returnUrl,
        FailRedirectUrl: returnUrl,
        JsonData: { payment_id: p.payment_id, recurring: !!p.save_method },
      }, p.payment_id);
      const url = a.Model?.Url;
      if (!a.Success || typeof url !== 'string') throw new ProviderError(`CloudPayments: ${a.Message ?? 'нет ссылки'}`);
      return { providerId: typeof a.Model?.Id === 'string' ? a.Model.Id : null, url };
    },

    async charge(p): Promise<Charged> {
      if (!p.token) return { status: 'failed', providerId: null, reason: 'no_token' };
      try {
        const a = await call('/payments/tokens/charge', {
          Amount: amount(p),
          Currency: p.currency,
          AccountId: p.user_id,
          Token: p.token,
          InvoiceId: p.payment_id,
          Description: description(p),
          Email: p.email,
          // списание инициирует магазин по сохранённым данным, по расписанию
          TrInitiatorCode: 0,
          PaymentScheduled: 1,
        }, p.payment_id);
        const id = a.Model?.TransactionId != null ? String(a.Model.TransactionId) : null;
        if (a.Success && a.Model?.Status === 'Completed') return { status: 'succeeded', providerId: id };
        return { status: 'failed', providerId: id, reason: String(a.Model?.CardHolderMessage ?? a.Message ?? 'declined') };
      } catch (e) {
        return { status: 'failed', providerId: null, reason: String(e) };
      }
    },

    async refund({ providerId, amountMinor }) {
      const a = await call('/payments/refund', { TransactionId: Number(providerId), Amount: amountMinor / 100 });
      if (!a.Success) throw new ProviderError(`CloudPayments: ${a.Message ?? 'возврат отклонён'}`);
    },

    async webhook({ headers, body, url }): Promise<Hook> {
      const got = headers.get('content-hmac') ?? '';
      if (!same(await hmacBase64(secret(), body), got)) throw new Unauthorized('подпись CloudPayments');
      let f: Record<string, unknown>;
      if ((headers.get('content-type') ?? '').includes('json')) {
        f = JSON.parse(body);
      } else {
        f = Object.fromEntries(new URLSearchParams(body));
      }
      const reply = Response.json({ code: 0 });
      const paymentId = typeof f.InvoiceId === 'string' ? f.InvoiceId : undefined;
      const providerId = f.TransactionId != null ? String(f.TransactionId) : undefined;
      // Pay приходит с Status=Completed; Fail — без; тип уведомления — по параметру адреса или по полю
      const kind = url.searchParams.get('n') ?? (f.Status === 'Completed' ? 'pay' : f.Reason != null ? 'fail' : '');
      let e: Event | null = null;
      if (kind === 'pay' && f.Status === 'Completed') {
        e = {
          kind: 'paid',
          paymentId,
          providerId,
          amountMinor: minor(f.Amount) ?? undefined,
          currency: typeof f.Currency === 'string' ? f.Currency : undefined,
          token: typeof f.Token === 'string' && f.Token ? f.Token : null,
          methodTitle: cardTitle(f.CardLastFour),
        };
      } else if (kind === 'fail') {
        e = { kind: 'failed', paymentId, providerId, reason: String(f.Reason ?? 'fail') };
      }
      return { events: e && paymentId ? [e] : [], reply };
    },
  };
}
