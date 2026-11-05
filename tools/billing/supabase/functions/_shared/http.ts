// Ответы функций: JSON, и заголовки для веб-версии приложения (у телефона их никто не проверяет).

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}

export const preflight = () => new Response(null, { status: 204, headers: cors });

/** Адрес человека: первый из X-Forwarded-For (его ставит Supabase). */
export function ipOf(req: Request): string {
  return (req.headers.get('x-forwarded-for') ?? '').split(',')[0].trim();
}
