// Табло турнира для веб-версии приложения. Сайты табло (Swiss Timing на results.isu.org, fsrussia.ru
// и других) не разрешают читать себя со страницы чужого сайта, поэтому браузер получает страницу
// табло отсюда: функция забирает её и отдаёт как есть, с разрешением CORS.
//
// Не открытый прокси: только GET, только адреса страниц .htm/.html обычных доменов (не IP, не
// внутренние имена), только страницы табло (в тексте — подпись Swiss Timing, ISUCalcFS или comnet),
// не больше 2 МБ. Ответ не кэшируется: смысл — в свежести.
// Выложить: supabase functions deploy board --project-ref <проект> (из папки tools/billing;
// проверка входа для неё выключена в config.toml — табло читают и без аккаунта).

import { allowed, BOARD, MAX } from '../_shared/board.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Expose-Headers': 'x-board, last-modified',
  // по заголовку приложение понимает, что функция выложена (иначе 404 — читает файл сайта)
  'x-board': '1',
  'Cache-Control': 'no-store',
};

function reply(status: number, body: BodyInit | null, extra: Record<string, string> = {}): Response {
  return new Response(body, { status, headers: { ...cors, ...extra } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return reply(204, null);
  if (req.method !== 'GET') return reply(405, 'method');
  const target = allowed(new URL(req.url).searchParams.get('u'));
  if (!target) return reply(400, 'url');
  let r: Response;
  try {
    r = await fetch(target, {
      headers: { 'User-Agent': 'Mozilla/5.0 (compatible; StartyBoard/1.0)', 'Cache-Control': 'no-cache' },
      redirect: 'follow',
      signal: AbortSignal.timeout(12000),
    });
  } catch {
    return reply(502, 'fetch');
  }
  // 404 табло отдаём как 404: «страницы ещё нет» для приложения — не сбой
  if (r.status === 404 || r.status === 410) return reply(r.status, 'none');
  if (!r.ok) return reply(502, `upstream ${r.status}`);
  const buf = new Uint8Array(await r.arrayBuffer());
  if (buf.length > MAX) return reply(413, 'size');
  // табло бывает в cp1251: проверяем подпись по латинице, она в любой кодировке одинакова
  const ascii = new TextDecoder('latin1').decode(buf);
  if (!BOARD.test(ascii)) return reply(403, 'not a board');
  const extra: Record<string, string> = { 'Content-Type': r.headers.get('content-type') ?? 'text/html' };
  const lm = r.headers.get('last-modified');
  if (lm) extra['last-modified'] = lm;
  return reply(200, buf, extra);
});
