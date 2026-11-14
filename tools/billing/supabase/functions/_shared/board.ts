// Проверки функции board (табло для веб-версии): какой адрес можно читать и что считается табло.

/** Больше этого страница табло не бывает. */
export const MAX = 2 * 1024 * 1024;

/** Подпись программ табло: Swiss Timing, ISUCalcFS, comnet. */
export const BOARD = /Swiss\s*Timing|ISUCalcFS|by\s+comnet|FS\s*Manager/i;

/** Адрес можно читать: http(s), стандартный порт, доменное имя, страница .htm/.html. */
export function allowed(raw: string | null): URL | null {
  if (!raw) return null;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
  if (u.port && u.port !== '80' && u.port !== '443') return null;
  if (u.username || u.password) return null;
  const host = u.hostname.toLowerCase();
  if (!host.includes('.') || /^[\d.]+$/.test(host) || host.includes(':')) return null;
  if (/(^|\.)(localhost|local|internal|lan|home|supabase\.co|supabase\.in)$/.test(host)) return null;
  if (!/\.html?$/i.test(u.pathname)) return null;
  return u;
}

