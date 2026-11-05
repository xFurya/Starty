// Робокасса. Россия; работает с самозанятыми («Робочеки СМЗ» — чек в «Мой налог» сам).
// Секреты: ROBOKASSA_LOGIN, ROBOKASSA_PASSWORD1, ROBOKASSA_PASSWORD2 (в тестовом режиме — тестовые пароли),
// ROBOKASSA_HASH (md5 по умолчанию; так же, как в настройках магазина: md5, sha1, sha256, sha384, sha512).
// В настройках магазина: Result URL — адрес billing-webhook?p=robokassa (метод POST), Success URL и Fail URL —
// BILLING_RETURN_URL (метод GET). Продление — «периодические платежи»: включает Робокасса по заявке.
// Возврат через API требует отдельного доступа — здесь он вручную, из кабинета.

import { need } from '../env.ts';
import { digest, same } from '../hash.ts';
import { decimal, minor } from '../money.ts';
import {
  description, Unauthorized,
  type Charged, type Deps, type Hook, type Payment, type Provider,
} from './types.ts';

const base = 'https://auth.robokassa.ru/Merchant';

export function robokassa({ env, fetch: http, test }: Deps): Provider {
  const alg = (env('ROBOKASSA_HASH') ?? 'md5').toLowerCase() as 'md5' | 'sha1' | 'sha256' | 'sha384' | 'sha512';
  const login = () => need(env, 'ROBOKASSA_LOGIN');

  // Shp_-параметры участвуют в подписи по алфавиту, после пароля
  const sign = (parts: string[], pass: string, shp: Record<string, string>) =>
    digest(alg, [...parts, pass, ...Object.keys(shp).sort().map((k) => `${k}=${shp[k]}`)].join(':'));

  return {
    id: 'robokassa',

    async create(p: Payment) {
      const shp = { Shp_pay: p.payment_id };
      const sum = decimal(p.amount_minor);
      const q = new URLSearchParams({
        MerchantLogin: login(),
        OutSum: sum,
        InvId: String(p.seq),
        Description: description(p).slice(0, 100),
        SignatureValue: await sign([login(), sum, String(p.seq)], need(env, 'ROBOKASSA_PASSWORD1'), shp),
        Email: p.email,
        Culture: 'ru',
        Encoding: 'utf-8',
        ...shp,
      });
      if (p.save_method) q.set('Recurring', 'true');
      if (test) q.set('IsTest', '1');
      return { providerId: String(p.seq), url: `${base}/Index.aspx?${q}` };
    },

    async charge(p: Payment): Promise<Charged> {
      if (!p.parent_seq) return { status: 'failed', providerId: null, reason: 'no_parent' };
      const shp = { Shp_pay: p.payment_id };
      const sum = decimal(p.amount_minor);
      const form = new URLSearchParams({
        MerchantLogin: login(),
        InvoiceID: String(p.seq),
        PreviousInvoiceID: String(p.parent_seq),
        OutSum: sum,
        Description: description(p).slice(0, 100),
        SignatureValue: await sign([login(), sum, String(p.seq)], need(env, 'ROBOKASSA_PASSWORD1'), shp),
        ...shp,
      });
      try {
        const r = await http(`${base}/Recurring`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: form.toString(),
        });
        const text = (await r.text()).trim();
        // «OK+номер» — принято; итог придёт на Result URL, как у обычной оплаты
        if (r.ok && text.startsWith('OK')) return { status: 'pending', providerId: String(p.seq) };
        return { status: 'failed', providerId: String(p.seq), reason: text.slice(0, 200) };
      } catch (e) {
        return { status: 'failed', providerId: String(p.seq), reason: String(e) };
      }
    },

    async webhook({ body, url, headers }): Promise<Hook> {
      const isForm = (headers.get('content-type') ?? '').includes('application/x-www-form-urlencoded');
      const f = isForm || body.includes('=') ? new URLSearchParams(body) : url.searchParams;
      const sum = f.get('OutSum') ?? '';
      const inv = f.get('InvId') ?? '';
      const shp: Record<string, string> = {};
      for (const [k, v] of f) if (k.startsWith('Shp_')) shp[k] = v;
      const want = await sign([sum, inv], need(env, 'ROBOKASSA_PASSWORD2'), shp);
      if (!same(want.toLowerCase(), (f.get('SignatureValue') ?? '').toLowerCase())) throw new Unauthorized('подпись Робокассы');
      const seq = Number(inv);
      return {
        events: [{
          kind: 'paid',
          seq,
          paymentId: shp.Shp_pay,
          providerId: inv,
          amountMinor: minor(sum) ?? undefined,
          currency: 'RUB',
          // продление в Робокассе — по номеру первого счёта
          token: inv,
          methodTitle: 'Карта',
        }],
        reply: new Response(`OK${inv}`, { headers: { 'Content-Type': 'text/plain' } }),
      };
    },
  };
}
