// База: функции из tools/billing/schema.sql через PostgREST с ключом service_role, и вход человека
// по его токену (GoTrue). Ничего, кроме fetch, — функции работают и в Supabase (Deno), и в проверках (Node).

import { type Env, need } from './env.ts';

export type Fetch = typeof fetch;

/** Ошибка функции базы: message — её идентификатор (billing_off, no_plan, …). */
export class DbError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

export interface Db {
  rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T>;
}

export function postgrest(env: Env, http: Fetch = fetch): Db {
  const url = need(env, 'SUPABASE_URL');
  const key = need(env, 'SUPABASE_SERVICE_ROLE_KEY');
  return {
    async rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
      const r = await http(`${url}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(args),
      });
      const text = await r.text();
      let body: unknown = null;
      try {
        body = text ? JSON.parse(text) : null;
      } catch {
        body = text;
      }
      if (!r.ok) {
        const msg = body && typeof body === 'object' && 'message' in body ? String((body as { message: unknown }).message) : `http_${r.status}`;
        throw new DbError(msg, r.status);
      }
      return body as T;
    },
  };
}

export type User = { id: string; email: string | null };

/** Кто вошёл: токен из приложения проверяет сам Supabase. Нет входа или токен чужой — null. */
export async function userOf(env: Env, auth: string | null, http: Fetch = fetch): Promise<User | null> {
  const token = /^Bearer\s+(.+)$/i.exec(auth ?? '')?.[1];
  if (!token) return null;
  const r = await http(`${need(env, 'SUPABASE_URL')}/auth/v1/user`, {
    headers: { apikey: need(env, 'SUPABASE_ANON_KEY'), Authorization: `Bearer ${token}` },
  });
  if (!r.ok) return null;
  const j = (await r.json()) as { id?: unknown; email?: unknown };
  return typeof j.id === 'string' ? { id: j.id, email: typeof j.email === 'string' ? j.email : null } : null;
}
