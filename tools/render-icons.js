// Растеризует SVG-иконки в PNG нужных размеров (Playwright + Chromium).
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const dir = path.join(__dirname, '..', 'site', 'icons');
const jobs = [
  ['icon.svg', 'icon-192.png', 192], ['icon.svg', 'icon-512.png', 512],
  ['maskable.svg', 'maskable-512.png', 512], ['maskable.svg', 'maskable-192.png', 192],
  ['icon.svg', 'apple-touch-icon.png', 180], ['badge.svg', 'badge.png', 96],
];
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage();
  for (const [src, out, size] of jobs) {
    const svg = fs.readFileSync(path.join(dir, src), 'utf8');
    await p.setViewportSize({ width: size, height: size });
    await p.setContent(`<html><body style="margin:0;background:transparent">${svg.replace('<svg ', `<svg width="${size}" height="${size}" `)}</body></html>`);
    await p.screenshot({ path: path.join(dir, out), omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
  }
  await b.close();
})();
