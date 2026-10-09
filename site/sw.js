/* Сервис-воркер: оболочка приложения из кэша, расписание — из сети с запасной копией.
   Без сети приложение показывает последнее полученное расписание. */
const VERSION = 'starty-1';
const SHELL = [
  './', 'index.html', 'style.css', 'app.js', 'fonts.css', 'manifest.webmanifest',
  'icons/icon.svg', 'icons/icon-192.png', 'icons/icon-512.png', 'icons/badge.png',
  'fonts/FiraSans-400-cyrillic.woff2', 'fonts/FiraSans-400-latin.woff2',
  'fonts/FiraSans-500-cyrillic.woff2', 'fonts/FiraSans-500-latin.woff2',
  'fonts/FiraSans-600-cyrillic.woff2', 'fonts/FiraSans-600-latin.woff2',
  'fonts/FiraSansCondensed-500-cyrillic.woff2', 'fonts/FiraSansCondensed-500-latin.woff2',
  'fonts/FiraSansCondensed-600-cyrillic.woff2', 'fonts/FiraSansCondensed-600-latin.woff2',
  'fonts/FiraSansCondensed-700-cyrillic.woff2', 'fonts/FiraSansCondensed-700-latin.woff2',
];
const DATA = 'starty-data';

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== VERSION && k !== DATA) await caches.delete(k);
    await self.clients.claim();
  })());
});

function timeout(ms) { return new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms)); }

async function networkFirst(req) {
  const cache = await caches.open(DATA);
  const key = new URL(req.url);
  key.search = '';
  try {
    const res = await Promise.race([fetch(req, { cache: 'no-store' }), timeout(8000)]);
    if (res.ok) await cache.put(key.href, res.clone());
    return res;
  } catch (err) {
    const hit = await cache.match(key.href);
    if (!hit) throw err;
    // помечаем, что это сохранённая копия — приложение напишет «нет связи»
    const h = new Headers(hit.headers);
    h.set('x-starty-cache', '1');
    return new Response(await hit.blob(), { status: 200, headers: h });
  }
}

async function staleWhileRevalidate(req, event) {
  const cache = await caches.open(VERSION);
  const hit = await cache.match(req, { ignoreSearch: true });
  const fresh = fetch(req).then((res) => { if (res.ok) cache.put(req, res.clone()); return res; }).catch(() => null);
  if (hit) { event.waitUntil(fresh); return hit; }
  return (await fresh) || (await cache.match('index.html')) || Response.error();
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;
  if (url.pathname.endsWith('/data/events.json') || url.pathname.endsWith('.ics')) {
    e.respondWith(networkFirst(req));
    return;
  }
  if (req.mode === 'navigate') {
    e.respondWith((async () => {
      try {
        const res = await Promise.race([fetch(req), timeout(5000)]);
        const c = await caches.open(VERSION);
        if (res.ok) c.put('index.html', res.clone());
        return res;
      } catch (err) {
        return (await caches.match('index.html')) || (await caches.match('./')) || Response.error();
      }
    })());
    return;
  }
  e.respondWith(staleWhileRevalidate(req, e));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const id = e.notification.data && e.notification.data.id;
  const target = new URL('./' + (id ? '#e=' + encodeURIComponent(id) : ''), self.registration.scope).href;
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) {
      if (c.url.startsWith(self.registration.scope)) { await c.focus(); c.navigate(target).catch(() => {}); return; }
    }
    await self.clients.openWindow(target);
  })());
});
