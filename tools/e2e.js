// Сквозная проверка на стенде: офлайн, «смотрю», фильтр по спортсмену, ссылка на старт, меню.
// node tools/e2e.js <url> <outdir>
const { chromium } = require('playwright');
const path = require('path');
const [url, out] = process.argv.slice(2);
const when = new Date('2026-10-09T15:40:00+03:00');
const ok = [];
const bad = [];
const check = (c, msg) => (c ? ok : bad).push(msg);
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 360, height: 780 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, locale: 'ru-RU', timezoneId: 'America/New_York' });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  await p.clock.install({ time: when });
  await p.goto(url, { waitUntil: 'networkidle' });
  await p.evaluate(() => navigator.serviceWorker.ready);
  await p.reload({ waitUntil: 'networkidle' });
  // время показывается по Москве, даже если телефон в Нью-Йорке
  const clock = await p.textContent('#clock');
  check(clock.includes('15:40'), 'часы в МСК при чужом поясе: ' + clock);
  const first = await p.textContent('.ev.live .ev-time .t').catch(() => '');
  check(first === '15:15', 'идущий старт в 15:15 МСК: ' + first);

  // «смотрю»
  const id = await p.getAttribute('.ev[data-id]:not(.past) .ev-watch', 'data-watch');
  await p.click(`.ev-watch[data-watch="${id}"]`);
  await p.waitForTimeout(300);
  check(await p.getAttribute(`.ev-watch[data-watch="${id}"]`, 'aria-pressed') === 'true', 'отметка «смотрю» ставится');
  await p.screenshot({ path: path.join(out, 'e2e-watch.png') });
  await p.reload({ waitUntil: 'networkidle' });
  check(await p.getAttribute(`.ev-watch[data-watch="${id}"]`, 'aria-pressed') === 'true', 'отметка сохраняется после перезагрузки');

  // фильтр по спортсмену
  await p.click('#btn-filter');
  await p.fill('#f-q', 'бойкова');
  await p.waitForTimeout(200);
  await p.click('[data-a*="Бойкова"]');
  await p.click('#f-apply');
  await p.waitForTimeout(300);
  const titles = await p.$$eval('.ev .ev-tour', (n) => n.map((x) => x.textContent));
  check(titles.length > 0 && titles.every((t) => /GP|CS|Finlandia|France/.test(t)), 'фильтр по спортсмену: ' + titles.join(' | '));
  await p.screenshot({ path: path.join(out, 'e2e-athlete.png') });
  await p.reload({ waitUntil: 'networkidle' });
  check((await p.$$('.chip-x')).length === 1, 'фильтр сохраняется на устройстве');
  await p.click('.chip-x');
  await p.waitForTimeout(200);

  // ссылка на конкретный старт (как из календаря)
  await p.goto(url + '#e=' + encodeURIComponent(id), { waitUntil: 'networkidle' });
  await p.waitForTimeout(300);
  check(await p.$eval('#sheet', (d) => d.open), 'ссылка #e= открывает карточку');
  await p.screenshot({ path: path.join(out, 'e2e-deeplink.png') });
  await p.keyboard.press('Escape');

  // меню
  await p.click('#btn-more');
  await p.waitForTimeout(300);
  await p.screenshot({ path: path.join(out, 'e2e-menu.png') });
  const sub = await p.getAttribute('#m-sub', 'href');
  check(sub && sub.includes('calendar.google.com') && sub.includes('webcal'), 'подписка (Android → Google): ' + sub);
  await p.keyboard.press('Escape');

  // офлайн: сервер недоступен — приложение открывается из кэша и честно пишет об этом
  // (setOffline в Playwright не действует на сервис-воркер, поэтому гасим сам сервер)
  if (process.env.STOP_SERVER) require('child_process').execSync(process.env.STOP_SERVER);
  await p.reload({ waitUntil: 'load' }).catch(() => {});
  await p.waitForTimeout(9500);
  const rows = await p.$$('.ev[data-id]');
  const foot = await p.textContent('#foot');
  check(rows.length > 0, 'офлайн: расписание из сохранённой копии, строк ' + rows.length);
  check(/Нет связи/.test(foot), 'офлайн: пометка в подвале: ' + foot.slice(0, 80));
  await p.screenshot({ path: path.join(out, 'e2e-offline.png') });
  if (process.env.START_SERVER) { require('child_process').execSync(process.env.START_SERVER); await new Promise((r) => setTimeout(r, 800)); }

  // без уведомлений и без localStorage — ошибок быть не должно
  const ctx2 = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1' });
  await ctx2.addInitScript(() => { delete window.Notification; Object.defineProperty(window, 'localStorage', { get() { throw new Error('denied'); } }); });
  const p2 = await ctx2.newPage();
  const errs2 = [];
  p2.on('pageerror', (e) => errs2.push(e.message));
  await p2.clock.install({ time: when });
  await p2.goto(url, { waitUntil: 'networkidle' });
  await p2.click('.ev[data-id]:not(.past) .ev-watch');
  await p2.waitForTimeout(300);
  await p2.screenshot({ path: path.join(out, 'e2e-iphone.png') });
  check(!errs2.length, 'iPhone без уведомлений и хранилища — без ошибок ' + errs2.join('; '));
  check(await p2.isVisible('#install'), 'iPhone: подсказка по установке видна');
  check(!errs.length, 'без ошибок JS ' + errs.join('; '));
  await b.close();
  console.log('OK:\n  ' + ok.join('\n  '));
  if (bad.length) { console.log('ПРОВАЛ:\n  ' + bad.join('\n  ')); process.exitCode = 1; }
})();
