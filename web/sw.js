// Веб-версия без лишних загрузок. Оболочка — движок, код, шрифты, значки — отдаётся из своего
// кэша, пока номер сборки на сайте тот же (version.json пишет сам Flutter); сменился — кэш
// выбрасывается и всё качается заново, так что старая версия не застревает. Без сети — с тем,
// что есть. Расписание, фото и всё вне папки веб-версии идут мимо: у них свои правила.
'use strict';

const CACHE = 'starty-shell';
const SCOPE = new URL('./', self.location).pathname;
const PAGE = SCOPE;
const MARK = SCOPE + '__build';

self.addEventListener('install', () => self.skipWaiting());
// метка сборки — до того, как первая же загрузка начнёт класть в кэш, иначе следующий заход
// не узнает, от какой она сборки, и скачает всё заново
self.addEventListener('activate', (e) => e.waitUntil(check().then(() => self.clients.claim())));

/// Номер выложенной сборки; null — сервер не ответил (нет связи или слишком долго).
async function published() {
  const stop = new AbortController();
  const timer = setTimeout(() => stop.abort(), 3000);
  try {
    const r = await fetch(SCOPE + 'version.json', { cache: 'no-store', signal: stop.signal });
    // сервер ответил, но номера нет — считать каждую загрузку новой сборкой, ничего не держать
    if (!r.ok) return 'unknown:' + Date.now();
    const j = await r.json().catch(() => null);
    return j && j.build_number ? String(j.build_number) : 'unknown:' + Date.now();
  } catch (_) {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/// Перед открытием страницы: сборка на сайте сменилась — кэш оболочки выбрасывается.
async function check() {
  const build = await published();
  if (build === null) return;
  const cache = await caches.open(CACHE);
  const mark = await cache.match(MARK);
  if (mark && (await mark.text()) === build) return;
  await caches.delete(CACHE);
  await (await caches.open(CACHE)).put(MARK, new Response(build));
}

/// Из кэша; нет — из сети в обход кэша браузера (там может лежать прежняя сборка) и в кэш.
async function cached(req, key) {
  const cache = await caches.open(CACHE);
  const hit = await cache.match(key);
  if (hit) return hit;
  const res = await fetch(key, { cache: 'no-cache', credentials: 'same-origin' });
  if (res.status === 200 && res.type === 'basic') await cache.put(key, res.clone());
  return res;
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET' || req.headers.has('range')) return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin || !url.pathname.startsWith(SCOPE)) return;
  const path = url.pathname;
  if (req.mode === 'navigate') {
    if (path !== SCOPE && path !== SCOPE + 'index.html') return;
    e.respondWith(check().then(() => cached(req, PAGE)));
    return;
  }
  if (path === SCOPE + 'version.json' || path === SCOPE + 'sw.js' || path === MARK) return;
  e.respondWith(cached(req, req.url));
});
