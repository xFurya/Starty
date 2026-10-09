// Скриншоты телефонного размера: node tools/shots.js <url> <outdir> [ISO-время]
const { chromium } = require('playwright');
const path = require('path');
const [url, out, when = '2026-10-09T15:40:00+03:00'] = process.argv.slice(2);
(async () => {
  const b = await chromium.launch();
  const errors = [];
  for (const scheme of ['light', 'dark']) {
    const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: scheme, isMobile: true, hasTouch: true, locale: 'ru-RU', timezoneId: 'Asia/Novosibirsk' });
    const p = await ctx.newPage();
    p.on('pageerror', (e) => errors.push(scheme + ': ' + e.message));
    p.on('console', (m) => { if (m.type() === 'error') errors.push(scheme + ' console: ' + m.text()); });
    await p.clock.install({ time: new Date(when) });
    await p.goto(url, { waitUntil: 'networkidle' });
    await p.waitForTimeout(600);
    await p.screenshot({ path: path.join(out, `feed-${scheme}.png`) });
    await p.screenshot({ path: path.join(out, `feed-${scheme}-full.png`), fullPage: true });
    // карточка старта
    const row = await p.$('.ev.live') || await p.$('.ev[data-id]');
    if (row) { await row.click(); await p.waitForTimeout(400); await p.screenshot({ path: path.join(out, `sheet-${scheme}.png`) }); await p.keyboard.press('Escape'); }
    // месяц
    await p.click('#tab-month');
    await p.waitForTimeout(400);
    await p.screenshot({ path: path.join(out, `month-${scheme}.png`) });
    await p.click('#tab-feed');
    // фильтры
    await p.click('#btn-filter');
    await p.waitForTimeout(400);
    await p.screenshot({ path: path.join(out, `filters-${scheme}.png`) });
    await p.keyboard.press('Escape');
    // горизонтальная прокрутка — недопустима
    const overflow = await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    if (overflow > 0) errors.push(`${scheme}: горизонтальная прокрутка ${overflow}px`);
    await ctx.close();
  }
  await b.close();
  console.log(errors.length ? errors.join('\n') : 'без ошибок');
})();
