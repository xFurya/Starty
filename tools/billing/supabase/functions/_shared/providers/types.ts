// Платёжный сервис — одна реализация этого интерфейса. Выбор сервиса — в плане (billing_plans.provider),
// настройки — секреты функций (ПОДПИСКА.md).

import type { Env } from '../env.ts';
import type { Fetch } from '../db.ts';

/** Платёж, как его отдают billing_start и billing_renewals_start. */
export type Payment = {
  payment_id: string;
  seq: number;
  user_id: string;
  email: string;
  plan_id: string;
  title: string;
  period_days: number;
  amount_minor: number;
  currency: 'RUB' | 'BYN';
  provider: string;
  /** Первый платёж: человек согласился на продление — сервис должен сохранить способ оплаты. */
  save_method?: boolean;
  /** Продление: сохранённый способ оплаты и (Робокасса) номер первого счёта. */
  token?: string;
  parent_seq?: number | null;
};

export type Created = { providerId: string | null; url: string };

export type Charged = { status: 'succeeded' | 'pending' | 'failed'; providerId: string | null; reason?: string };

/** Что сообщил сервис. Наш платёж — по paymentId, по seq (номер счёта) или по номеру у сервиса. */
export type Event = {
  kind: 'paid' | 'failed';
  paymentId?: string;
  seq?: number;
  providerId?: string;
  amountMinor?: number;
  currency?: string;
  token?: string | null;
  methodTitle?: string | null;
  reason?: string;
};

export type Hook = { events: Event[]; reply: Response };

export type Incoming = { headers: Headers; body: string; url: URL };

export interface Provider {
  id: string;
  /** Страница оплаты сервиса. После оплаты сервис возвращает человека на returnUrl. */
  create(p: Payment, urls: { returnUrl: string; notifyUrl: string }): Promise<Created>;
  /** Списание по сохранённому способу без участия человека. Нет — продление этим сервисом невозможно. */
  charge?(p: Payment): Promise<Charged>;
  /** Возврат. Нет — возврат вручную в кабинете сервиса (функция пишет заявку и письмо владельцу). */
  refund?(r: { providerId: string; amountMinor: number; currency: string; email?: string; title?: string }): Promise<void>;
  /** Уведомление сервиса. Подпись не сошлась — бросает Unauthorized. */
  webhook(req: Incoming): Promise<Hook>;
}

export type Deps = { env: Env; fetch: Fetch; test: boolean };

export class Unauthorized extends Error {}

/** Сервис ответил ошибкой — текст для журнала функции, человеку показывается общее «не удалось». */
export class ProviderError extends Error {}

export const description = (p: Payment) => `Подписка «Фигурное катание», ${p.title.toLowerCase()}`;

export function basic(user: string, pass: string): string {
  return `Basic ${btoa(unescape(encodeURIComponent(`${user}:${pass}`)))}`;
}

export function cardTitle(last4: unknown): string {
  return typeof last4 === 'string' && /^\d{4}$/.test(last4) ? `Карта •• ${last4}` : 'Карта';
}
