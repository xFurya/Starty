// Настройки функций сервера. В Supabase — секреты функций (supabase secrets set …); в проверках — словарь.
// SUPABASE_URL, SUPABASE_ANON_KEY и SUPABASE_SERVICE_ROLE_KEY Supabase задаёт сам.

export type Env = (key: string) => string | undefined;

declare const Deno: { env: { get(key: string): string | undefined } } | undefined;
declare const process: { env: Record<string, string | undefined> } | undefined;

/** Настройки из окружения: Deno в Supabase, Node — в проверках. */
export function systemEnv(): Env {
  return (key) => {
    if (typeof Deno !== 'undefined') return Deno.env.get(key) || undefined;
    if (typeof process !== 'undefined') return process.env[key] || undefined;
    return undefined;
  };
}

export function need(env: Env, key: string): string {
  const v = env(key);
  if (!v) throw new Config(`не задано ${key}`);
  return v;
}

/** Сервер не настроен: функция отвечает 503, а не притворяется, что оплата прошла. */
export class Config extends Error {}
