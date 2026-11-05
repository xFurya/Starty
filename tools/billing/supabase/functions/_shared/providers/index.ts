import type { Env } from '../env.ts';
import type { Fetch } from '../db.ts';
import { bepaid } from './bepaid.ts';
import { cloudpayments } from './cloudpayments.ts';
import { robokassa } from './robokassa.ts';
import type { Provider } from './types.ts';
import { yookassa } from './yookassa.ts';

const all = { yookassa, robokassa, cloudpayments, bepaid } as const;

/** Сервис по имени из плана. BILLING_TEST=1 — тестовый режим у тех, кто его различает в запросе. */
export function provider(id: string, env: Env, http: Fetch = fetch): Provider | null {
  const make = (all as Record<string, typeof yookassa>)[id];
  return make ? make({ env, fetch: http, test: env('BILLING_TEST') === '1' }) : null;
}
