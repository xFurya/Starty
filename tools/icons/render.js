// Слои иконок приложения (запуск: node render.js <выходная папка>; нужен playwright с Chromium).
// Рисует в 1024×1024 — это видимая часть иконки; на выходе PNG 512×512:
//   bg.png — фон (лёд), skater.png — фигуристка (уменьшена под полосу календаря),
//   band_<цвет>.png — полоса календаря с кольцами, закладкой и искрами,
//   num_<d>_fill.png / num_<d>_line.png — число дня: заливка и белый контур (цвет контура — тинтом).
// Набор цветов и вариантов — в variants.json (общий для Android, iPhone, компьютера и приложения).
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const here = __dirname;
const out = process.argv[2] || path.join(here, 'out');
fs.mkdirSync(out, { recursive: true });
const cfg = JSON.parse(fs.readFileSync(path.join(here, 'variants.json'), 'utf8'));
const svgSrc = fs.readFileSync(path.join(here, '../../app/assets/icon/icon.svg'), 'utf8');
const font = fs.readFileSync(path.join(here, '../../app/assets/fonts/Manrope-Bold.ttf')).toString('base64');

// исходная иконка: фон до группы с фигуристкой, сама группа, искры после неё
const gi = svgSrc.indexOf('<g transform="translate(101.61');
let depth = 0, gj = gi;
for (const m of svgSrc.slice(gi).matchAll(/<g\b|<\/g>/g)) {
  depth += m[0] === '</g>' ? -1 : 1;
  if (depth === 0) { gj = gi + m.index + m[0].length; break; }
}
const head = svgSrc.slice(0, gi);           // <svg ...><defs>…</defs> фон, свечение, дуги
const skaterG = svgSrc.slice(gi, gj);

const svg = (body, defs = '') => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="512" height="512">
<defs><style>@font-face{font-family:M;src:url(data:font/ttf;base64,${font});font-weight:700}</style>${defs}</defs>${body}</svg>`;

const star = (x, y, r, fill, op = 1) => {
  const k = r * 0.3;
  return `<path d="M${x} ${y - r} L${x + k} ${y - k} L${x + r} ${y} L${x + k} ${y + k} L${x} ${y + r} L${x - k} ${y + k} L${x - r} ${y} L${x - k} ${y - k}Z" fill="${fill}" opacity="${op}"/>`;
};

const layers = {};
layers.bg = head.replace(/^<svg[^>]*>/, '').replace(/<defs>/, '<defs>') ;
// фигуристка ниже и чуть меньше: сверху — полоса календаря
layers.skater = `<g transform="translate(512 960) scale(0.82) translate(-512 -960)">${skaterG}</g>`;

function band(c) {
  const b = cfg.bands[c];
  return `<defs><linearGradient id="b" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${b.top}"/><stop offset="1" stop-color="${b.bottom}"/></linearGradient></defs>
<rect x="-40" y="-40" width="1104" height="215" fill="url(#b)"/>
<rect x="-40" y="175" width="1104" height="8" fill="#06152B" opacity=".25"/>
<path d="M772 175 H846 V312 L809 284 L772 312Z" fill="${b.accent}" opacity=".9"/>
${[330, 694].map(x => `<rect x="${x - 23}" y="34" width="46" height="104" rx="23" fill="#0B1E3A"/><rect x="${x - 9}" y="48" width="18" height="58" rx="9" fill="#FFFFFF" opacity=".55"/>`).join('')}
${star(232, 300, 30, b.accent, .95)}${star(760, 352, 14, '#FFFFFF', .85)}`;
}

function num(d, kind) {
  const t = String(d);
  const common = `x="512" y="790" text-anchor="middle" font-family="M" font-weight="700" font-size="${t.length > 1 ? 600 : 640}" letter-spacing="${t.length > 1 ? -36 : 0}"`;
  if (kind === 'fill') {
    return `<defs><linearGradient id="f" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity=".42"/><stop offset="1" stop-color="#FFFFFF" stop-opacity=".16"/></linearGradient></defs>
<text ${common} fill="url(#f)">${t}</text>`;
  }
  return `<defs><filter id="g" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="9"/></filter></defs>
<text ${common} fill="none" stroke="#FFFFFF" stroke-width="30" stroke-linejoin="round" opacity=".45" filter="url(#g)">${t}</text>
<text ${common} fill="none" stroke="#FFFFFF" stroke-width="15" stroke-linejoin="round">${t}</text>`;
}

(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 512, height: 512 } });
  const shot = async (name, body) => {
    await p.setContent(`<html><body style="margin:0;background:transparent">${svg(body)}</body></html>`);
    await p.evaluate(() => document.fonts.ready);
    await p.waitForTimeout(30);
    await p.locator('svg').screenshot({ path: path.join(out, name + '.png'), omitBackground: true });
  };
  await shot('bg', layers.bg);
  await shot('skater', layers.skater);
  for (const c of Object.keys(cfg.bands)) await shot('band_' + c, band(c));
  for (let d = 1; d <= 31; d++) {
    await shot(`num_${d}_fill`, num(d, 'fill'));
    await shot(`num_${d}_line`, num(d, 'line'));
  }
  await b.close();
})();
