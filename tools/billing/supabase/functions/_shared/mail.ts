// Письма: напоминание о продлении (без него списания не будет) и заявка владельцу на ручной возврат.
// Отправка — Resend (RESEND_API_KEY, BILLING_MAIL_FROM — адрес на своём домене, подтверждённом в Resend).
// Не настроено — письмо не уходит, напоминание не считается отправленным, продление не списывается.

import { type Env, need } from './env.ts';
import type { Fetch } from './db.ts';
import { day, human } from './money.ts';

export type Letter = { to: string; subject: string; text: string };

export interface Mailer {
  send(l: Letter): Promise<void>;
}

export function resend(env: Env, http: Fetch = fetch): Mailer {
  return {
    async send({ to, subject, text }) {
      const r = await http('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${need(env, 'RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: need(env, 'BILLING_MAIL_FROM'), to: [to], subject, text }),
      });
      if (!r.ok) throw new Error(`Resend ${r.status}: ${(await r.text()).slice(0, 200)}`);
    },
  };
}

/** Строка billing_notices_due. */
export type Notice = {
  user_id: string;
  email: string;
  paid_until: string;
  amount: number;
  currency: string;
  plan_title: string;
  method_title: string | null;
  seller: string | null;
};

/** Напоминание до списания: когда, сколько, с чего и как отказаться. */
export function noticeLetter(n: Notice): Letter {
  const seller = n.seller;
  const when = day(n.paid_until);
  // «Карта •• 1234» → «с карты •• 1234»
  const card = n.method_title ? ` с ${n.method_title.replace(/^Карта/, 'карты')}` : '';
  const lines = [
    'Здравствуйте!',
    '',
    `${when}${card} спишется ${human(n.amount, n.currency)} — продление подписки «Фигурное катание» (${n.plan_title.toLowerCase()}).`,
    '',
    'Если продлевать не нужно, отключите продление до этой даты: приложение «Фигурное катание» → Настройки → Подписка → «Отключить продление». Оплаченные дни останутся до конца срока.',
    '',
    'Отказаться можно и после списания: за неиспользованные дни деньги вернутся.',
  ];
  if (seller) lines.push('', `Продавец: ${seller}`);
  return { to: n.email, subject: `Подписка продлится ${when}`, text: lines.join('\n') };
}

export type Manual = { payment_id: string; provider: string; provider_id: string | null; amount: number; currency: string; reason: string };

/** Владельцу: вернуть вручную в кабинете сервиса — по закону в течение 10 дней. */
export function ownerLetter(to: string, buyer: string | null, rows: Manual[]): Letter {
  const total = rows.reduce((s, r) => s + r.amount, 0);
  const lines = [
    `Покупатель${buyer ? ` ${buyer}` : ''} отказался от подписки. Вернуть вручную, в течение 10 дней:`,
    '',
    ...rows.map((r) =>
      `• ${human(r.amount, r.currency)} — ${r.provider}, платёж у сервиса ${r.provider_id ?? '—'} (наш ${r.payment_id}). Почему вручную: ${r.reason}`),
    '',
    'Подписка уже закрыта, продление выключено. Деньги — в кабинете сервиса, раздел возвратов.',
    '',
    'Вернули — отметьте, чтобы в приложении у покупателя возврат перестал значиться ожидающим (Supabase → SQL Editor):',
    ...rows.map((r) => `select public.billing_refunded('${r.payment_id}', ${r.amount}, false);`),
  ];
  return { to, subject: `Возврат вручную: ${human(total, rows[0]?.currency ?? 'RUB')}`, text: lines.join('\n') };
}
