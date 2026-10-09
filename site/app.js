/* Старты — календарь стартов по фигурному катанию.
   Всё время — московское, независимо от часового пояса телефона. */
(() => {
  'use strict';

  const MSK = 3 * 3600e3;
  const DAY = 86400e3;
  const WD = ['вс', 'пн', 'вт', 'ср', 'чт', 'пт', 'сб'];
  const WD_FULL = ['воскресенье', 'понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота'];
  const MON_GEN = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
  const MON_SHORT = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
  const MON_NOM = ['Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'];
  const KINDS = [['women', 'Девушки'], ['men', 'Мужчины'], ['pairs', 'Пары'], ['dance', 'Танцы']];
  const STALE_H = 16; // обновление дважды в день — дольше 16 часов значит, что сбор не прошёл

  // ---------------------------------------------------------------- хранилище
  const store = {
    get(k, d) { try { const v = localStorage.getItem('starty.' + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem('starty.' + k, JSON.stringify(v)); } catch (e) { /* приватный режим */ } },
  };

  const state = {
    data: null,
    offline: false,
    view: store.get('view', 'feed'),
    filters: Object.assign({ kinds: [], tids: [], athletes: [], watchedOnly: false }, store.get('filters', {})),
    watched: store.get('watched', {}),
    showPast: false,
    month: null,
    day: null,
    installEvt: null,
  };

  // ---------------------------------------------------------------- время МСК
  const msk = (t) => { const d = new Date(+t + MSK); return { y: d.getUTCFullYear(), m: d.getUTCMonth(), d: d.getUTCDate(), h: d.getUTCHours(), mi: d.getUTCMinutes(), wd: d.getUTCDay() }; };
  const pad = (n) => String(n).padStart(2, '0');
  const hm = (t) => { const p = msk(t); return pad(p.h) + ':' + pad(p.mi); };
  const dayKey = (t) => { const p = msk(t); return p.y + '-' + pad(p.m + 1) + '-' + pad(p.d); };
  const keyToMs = (k) => { const [y, m, d] = k.split('-').map(Number); return Date.UTC(y, m - 1, d) - MSK; };
  const addDays = (k, n) => dayKey(keyToMs(k) + n * DAY + 3600e3);
  const fmtDay = (k, opts = {}) => {
    const p = msk(keyToMs(k));
    const wd = opts.full ? WD_FULL[p.wd] : WD[p.wd];
    return `${wd}, ${p.d} ${opts.short ? MON_SHORT[p.m] : MON_GEN[p.m]}`;
  };
  const now = () => Date.now();

  // ---------------------------------------------------------------- утилиты
  const $ = (s, r = document) => r.querySelector(s);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const norm = (s) => String(s).toLowerCase().replace(/ё/g, 'е');
  const icon = (id) => `<svg aria-hidden="true"><use href="#${id}"/></svg>`;

  function shortName(name) {
    // в ленте у пар — фамилии: «Кагановская / Некрасов»
    if (name.includes(' / ')) return name.split(' / ').map((p) => p.trim().split(' ').slice(-1)[0]).join(' / ');
    return name;
  }
  // время выхода «HH:MM» (МСК) → момент времени; старт сегмента мог быть до полуночи
  function oursAt(t0, time) {
    const p = msk(t0);
    return t0 + (((+time.slice(0, 2) - p.h + 24) % 24) * 60 + (+time.slice(3) - p.mi)) * 60e3;
  }
  function oursLine(o, compact, ev) {
    // как в протоколе: слева время выхода (или стартовый номер), потом имя
    const nm = esc(compact ? shortName(o.name) : o.name);
    let left = '<span class="tm none">·</span>';
    let after = '';
    let cls = '';
    if (o.time) {
      left = `<span class="tm">${esc(o.time)}</span>`;
      if (ev && ev.live) {
        if (oursAt(ev.t0, o.time) + 4 * 60e3 < now()) cls = ' class="done"';
        else if (!ev._next) { ev._next = true; cls = ' class="next"'; }
      }
    } else if (o.no) {
      left = `<span class="tm no">${o.no}-й</span>`;
      if (o.warmup) after = `<span class="wu">разминка ${o.warmup}</span>`;
    }
    return `<li${cls}>${left}<span class="n">${nm}</span>${after}</li>`;
  }
  function toast(html, ms = 3200) {
    const t = $('#toast');
    t.innerHTML = html;
    t.hidden = false;
    clearTimeout(toast._t);
    toast._t = setTimeout(() => { t.hidden = true; }, ms);
  }

  // ---------------------------------------------------------------- данные
  async function load(force) {
    try {
      const r = await fetch('data/events.json' + (force ? '?r=' + Date.now() : ''), { cache: 'no-cache' });
      if (!r.ok) throw new Error(r.status);
      const data = await r.json();
      state.data = prepare(data);
      state.offline = r.headers.get('x-starty-cache') === '1';
    } catch (e) {
      state.offline = true;
      if (!state.data) {
        try {
          const c = await caches.match('data/events.json', { ignoreSearch: true });
          if (c) state.data = prepare(await c.json());
        } catch (e2) { /* кэша нет */ }
      }
    }
    render();
    scheduleReminders();
  }

  function prepare(data) {
    for (const e of data.events) {
      e.t0 = Date.parse(e.start);
      e.t1 = Date.parse(e.end);
      e.day = dayKey(e.t0);
    }
    data.events.sort((a, b) => a.t0 - b.t0 || a.title.localeCompare(b.title));
    data.byId = Object.fromEntries(data.events.map((e) => [e.id, e]));
    return data;
  }

  // ---------------------------------------------------------------- фильтры
  function passes(e) {
    const f = state.filters;
    if (f.kinds.length && !f.kinds.includes(e.kind)) return false;
    if (f.tids.length && !f.tids.includes(e.tid)) return false;
    if (f.watchedOnly && !state.watched[e.id]) return false;
    if (f.athletes.length) {
      const names = (e.athletes || []).concat((e.ours || []).map((o) => o.name)).map(norm);
      if (!f.athletes.some((a) => names.includes(norm(a)))) return false;
    }
    return true;
  }
  const filterCount = () => state.filters.kinds.length + state.filters.tids.length + state.filters.athletes.length + (state.filters.watchedOnly ? 1 : 0);
  function saveFilters() { store.set('filters', state.filters); }

  function tournaments() {
    const m = new Map();
    for (const e of state.data.events) {
      const t = m.get(e.tid) || { tid: e.tid, name: e.tournament, a: e.day, b: e.day, intl: e.intl };
      if (e.day < t.a) t.a = e.day;
      if (e.day > t.b) t.b = e.day;
      m.set(e.tid, t);
    }
    for (const u of state.data.upcoming || []) {
      if (!m.has(u.tid)) m.set(u.tid, { tid: u.tid, name: u.name, a: u.start, b: u.end, intl: u.intl, noSched: true });
    }
    return [...m.values()];
  }
  function athletes() {
    const s = new Map();
    const add = (n) => { if (n && !s.has(norm(n))) s.set(norm(n), n); };
    for (const w of state.data.watchlist || []) add(w);
    for (const e of state.data.events) { for (const o of e.ours || []) add(o.name); for (const a of e.athletes || []) add(a); }
    for (const u of state.data.upcoming || []) for (const o of u.ours || []) add(o);
    return [...s.values()].sort((a, b) => a.localeCompare(b, 'ru'));
  }

  // ---------------------------------------------------------------- отрисовка
  function render() {
    renderClock();
    renderTabs();
    renderActive();
    if (!state.data) {
      $('#feed').innerHTML = `<div class="empty"><h2>Нет данных</h2><p>Расписание ещё не загрузилось, а сохранённой копии на устройстве пока нет. Нужна сеть для первого запуска.</p><button class="btn" id="retry">Повторить</button></div>`;
      $('#retry').onclick = () => load(true);
      $('#month').hidden = true;
      $('#feed').hidden = false;
      renderFoot();
      return;
    }
    $('#feed').hidden = state.view !== 'feed';
    $('#month').hidden = state.view !== 'month';
    if (state.view === 'feed') renderFeed(); else renderMonth();
    renderFoot();
    requestAnimationFrame(drawTraces);
  }

  function renderClock() {
    const t = now();
    const p = msk(t);
    $('#clock').innerHTML = `${WD[p.wd]}, ${p.d} ${MON_SHORT[p.m]} · <b>${hm(t)}</b> МСК`;
  }
  function renderTabs() {
    $('#tab-feed').setAttribute('aria-selected', state.view === 'feed');
    $('#tab-month').setAttribute('aria-selected', state.view === 'month');
    const n = filterCount();
    const b = $('#btn-filter .badge');
    b.hidden = !n;
    b.textContent = n;
  }
  function renderActive() {
    const box = $('#active-filters');
    if (!state.data) { box.hidden = true; return; }
    const f = state.filters;
    const tmap = Object.fromEntries(tournaments().map((t) => [t.tid, t.name]));
    const chips = [];
    if (f.watchedOnly) chips.push(['w', '', 'Смотрю']);
    for (const k of f.kinds) chips.push(['k', k, KINDS.find((x) => x[0] === k)[1]]);
    for (const t of f.tids) chips.push(['t', t, tmap[t] || 'Турнир']);
    for (const a of f.athletes) chips.push(['a', a, shortName(a)]);
    box.hidden = !chips.length;
    box.innerHTML = chips.map(([g, v, l]) => `<button class="chip-x" data-g="${g}" data-v="${esc(v)}">${esc(l)}${icon('i-close')}</button>`).join('');
  }

  function evRow(e, opts = {}) {
    const t = now();
    const live = e.t0 <= t && t < e.t1;
    const past = t >= e.t1;
    const w = !!state.watched[e.id];
    const cls = ['ev', live && 'live', past && 'past', w && 'watched'].filter(Boolean).join(' ');
    const ours = e.ours || [];
    const MAX = 4;
    const ctx = { live, t0: e.t0 };
    const list = ours.slice(0, MAX).map((o) => oursLine(o, true, ctx)).join('') +
      (ours.length > MAX ? `<li class="more">и ещё ${ours.length - MAX}</li>` : '');
    const meta = [];
    if (e.broadcast && e.broadcast.length) meta.push(`<span class="tv">${esc(e.broadcast.join(' / '))}</span>`);
    meta.push(`<span class="vn">${esc(e.venue)}</span>`);
    const seg = e.title.slice(e.tournament.length).replace(/^\s*—\s*/, '');
    return `<article class="${cls}" data-id="${esc(e.id)}">
      <div class="ev-time"><span class="t">${hm(e.t0)}</span>${live ? '<span class="tag">ИДЁТ</span>' : ''}</div>
      <span class="notch" aria-hidden="true"></span>
      <div class="ev-body">
        <div class="ev-tour">${esc(e.tournament)}</div>
        <h3 class="ev-seg">${esc(seg)}</h3>
        ${list ? `<ol class="ev-ours">${list}</ol>` : ''}
        <div class="ev-meta">${meta.join('')}</div>
      </div>
      <button class="ev-watch" aria-pressed="${w}" aria-label="${w ? 'Не смотрю' : 'Смотрю'}" data-watch="${esc(e.id)}">${icon(w ? 'i-eye-on' : 'i-eye')}</button>
    </article>`;
  }
  function dayHead(name, date, sub) {
    return `<div class="day${sub ? ' sub' : ''}"><div class="day-name">${esc(name)}${date ? `<span class="day-date">${esc(date)}</span>` : ''}</div></div>`;
  }
  function group(rows) {
    // последней строке дня — без линейки
    return rows.map((r, i) => (i === rows.length - 1 ? r.replace('class="ev', 'class="ev lastinday') : r)).join('');
  }

  function renderFeed() {
    const t = now();
    const today = dayKey(t);
    const tomorrow = addDays(today, 1);
    const wd = msk(t).wd;
    const weekEnd = addDays(today, wd === 0 ? 0 : 7 - wd);
    const evs = state.data.events.filter(passes);
    const live = evs.filter((e) => e.t0 <= t && t < e.t1);
    const todayPast = evs.filter((e) => e.day === today && e.t1 <= t);
    const todayNext = evs.filter((e) => e.day === today && e.t0 > t);
    const tom = evs.filter((e) => e.day === tomorrow);
    const week = evs.filter((e) => e.day > tomorrow && e.day <= weekEnd);
    const later = evs.filter((e) => e.day > weekEnd && e.day <= addDays(today, 70));
    let html = '';

    if (live.length || todayNext.length || todayPast.length) {
      html += dayHead('Сегодня', fmtDay(today, { short: true }));
      if (todayPast.length) {
        html += `<button class="past-toggle" id="past-toggle" aria-expanded="${state.showPast}"><span>${state.showPast ? 'Скрыть прошедшие' : `Уже прошло сегодня: ${todayPast.length}`}</span></button>`;
        if (state.showPast) html += group(todayPast.map((e) => evRow(e)));
      }
      html += group(live.concat(todayNext).map((e) => evRow(e)));
    } else {
      html += dayHead('Сегодня', fmtDay(today, { short: true }));
      html += `<div class="ev" style="cursor:default;min-height:52px"><div></div><span class="notch" aria-hidden="true"></span><div class="ev-body" style="color:var(--ink-3)">Стартов нет</div></div>`;
    }
    if (tom.length) html += dayHead('Завтра', fmtDay(tomorrow, { short: true })) + group(tom.map((e) => evRow(e)));
    if (week.length) {
      html += dayHead('На этой неделе');
      html += byDay(week);
    }
    if (later.length) {
      html += dayHead('Дальше');
      html += byDay(later);
    }
    if (!evs.length) {
      html += `<div class="empty"><h2>Ничего не нашлось</h2><p>${filterCount() ? 'По выбранным фильтрам стартов нет.' : 'В расписании пока нет стартов.'}</p>${filterCount() ? '<button class="btn" id="reset-f">Сбросить фильтры</button>' : ''}</div>`;
    }
    html += laterTournaments();
    $('#feed').innerHTML = html;
    const pt = $('#past-toggle');
    if (pt) pt.onclick = () => { state.showPast = !state.showPast; render(); };
    const rf = $('#reset-f');
    if (rf) rf.onclick = resetFilters;
  }
  function byDay(list) {
    let html = '';
    let cur = null;
    let rows = [];
    const flush = () => { if (rows.length) html += dayHead(fmtDay(cur), '', true) + group(rows); rows = []; };
    for (const e of list) {
      if (e.day !== cur) { flush(); cur = e.day; }
      rows.push(evRow(e));
    }
    flush();
    return html;
  }
  function rangeText(a, b) {
    const pa = msk(keyToMs(a));
    const pb = msk(keyToMs(b));
    if (a === b) return `${pa.d} ${MON_SHORT[pa.m]}`;
    if (pa.m === pb.m) return `${pa.d}–${pb.d} ${MON_SHORT[pa.m]}`;
    return `${pa.d} ${MON_SHORT[pa.m]} – ${pb.d} ${MON_SHORT[pb.m]}`;
  }
  function laterTournaments() {
    const f = state.filters;
    const today = dayKey(now());
    let ups = (state.data.upcoming || []).filter((u) => u.end >= today && u.start <= addDays(today, 60));
    if (f.tids.length) ups = ups.filter((u) => f.tids.includes(u.tid));
    if (f.athletes.length) ups = ups.filter((u) => (u.ours || []).some((o) => f.athletes.map(norm).includes(norm(o))));
    if (f.watchedOnly || !ups.length) return '';
    return `<section class="later"><h2>Скоро, без расписания</h2><p>Даты известны, время сегментов ещё не опубликовано — появится здесь само.</p><ul>${ups.map((u) => `
      <li><div class="d">${rangeText(u.start, u.end)}</div><div><div class="nm">${esc(u.name)}</div><div class="vn">${esc(u.venue)}</div>${u.ours && u.ours.length ? `<div class="ou">Наши: ${esc(u.ours.map((n) => n.includes(' / ') ? shortName(n) : n.split(' ').slice(-1)[0]).join(', '))}</div>` : ''}</div></li>`).join('')}</ul></section>`;
  }

  // ---------------------------------------------------------------- месяц
  function renderMonth() {
    const t = now();
    const today = dayKey(t);
    if (!state.month) { const p = msk(t); state.month = { y: p.y, m: p.m }; }
    const { y, m } = state.month;
    const evs = state.data.events.filter(passes);
    const byDayMap = {};
    for (const e of evs) (byDayMap[e.day] = byDayMap[e.day] || []).push(e);
    const bands = {};
    for (const u of state.data.upcoming || []) {
      if (state.filters.tids.length && !state.filters.tids.includes(u.tid)) continue;
      for (let k = u.start; k <= u.end; k = addDays(k, 1)) bands[k] = true;
    }
    const first = Date.UTC(y, m, 1);
    const startWd = (new Date(first).getUTCDay() + 6) % 7; // пн = 0
    const daysIn = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
    const cells = Math.ceil((startWd + daysIn) / 7) * 7;
    if (!state.day || state.day.slice(0, 7) !== `${y}-${pad(m + 1)}`) {
      const inMonth = Object.keys(byDayMap).filter((k) => k.startsWith(`${y}-${pad(m + 1)}`)).sort();
      const firstWith = inMonth.find((k) => k >= today) || inMonth[0];
      state.day = today.startsWith(`${y}-${pad(m + 1)}`) ? today : (firstWith || `${y}-${pad(m + 1)}-01`);
    }
    let grid = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'].map((d, i) => `<div class="m-wd${i > 4 ? ' we' : ''}">${d}</div>`).join('');
    for (let i = 0; i < cells; i++) {
      const dnum = i - startWd + 1;
      const ms = Date.UTC(y, m, dnum);
      const d = new Date(ms);
      const k = d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate());
      const out = dnum < 1 || dnum > daysIn;
      const list = byDayMap[k] || [];
      const marks = list.slice(0, 4).map((e) => `<i class="mk${state.watched[e.id] ? ' w' : (e.ours && e.ours.length ? ' ours' : '')}"></i>`).join('');
      grid += `<button class="m-day${out ? ' out' : ''}${k === today ? ' today' : ''}" data-day="${k}" aria-pressed="${k === state.day}" aria-label="${fmtDay(k, { full: true })}: стартов ${list.length}">
        <span class="num">${d.getUTCDate()}</span>
        <span class="marks">${marks}${list.length > 4 ? `<span class="plus">+${list.length - 4}</span>` : ''}</span>
        ${bands[k] && !list.length ? '<span class="band"></span>' : ''}
      </button>`;
    }
    const dayList = (byDayMap[state.day] || []);
    const dayUps = (state.data.upcoming || []).filter((u) => u.start <= state.day && state.day <= u.end && (!state.filters.tids.length || state.filters.tids.includes(u.tid)));
    let listHtml = dayHead(state.day === today ? 'Сегодня' : fmtDay(state.day, { full: true }), state.day === today ? fmtDay(today, { short: true }) : '');
    if (dayList.length) listHtml += group(dayList.map((e) => evRow(e)));
    else listHtml += `<div class="ev" style="cursor:default;min-height:52px"><div></div><span class="notch" aria-hidden="true"></span><div class="ev-body" style="color:var(--ink-3)">Стартов нет</div></div>`;
    if (dayUps.length) {
      listHtml += `<section class="later" style="margin-top:14px"><p>В эти дни, расписание ещё не опубликовано:</p><ul>${dayUps.map((u) => `<li><div class="d">${rangeText(u.start, u.end)}</div><div><div class="nm">${esc(u.name)}</div><div class="vn">${esc(u.venue)}</div></div></li>`).join('')}</ul></section>`;
    }
    $('#month').innerHTML = `
      <div class="m-head">
        <button class="icon-btn" id="m-prev" aria-label="Предыдущий месяц">${icon('i-left')}</button>
        <div class="m-title">${MON_NOM[m]} ${y}</div>
        <button class="icon-btn" id="m-next" aria-label="Следующий месяц">${icon('i-right')}</button>
      </div>
      <div class="m-grid">${grid}</div>
      <div class="m-legend"><span><i class="ours"></i>с нашими</span><span><i></i>старт</span><span><i class="w"></i>смотрю</span><span><i class="band"></i>турнир без расписания</span></div>
      <div class="m-list feed">${listHtml}</div>`;
    $('#m-prev').onclick = () => { shiftMonth(-1); };
    $('#m-next').onclick = () => { shiftMonth(1); };
  }
  function shiftMonth(d) {
    let { y, m } = state.month;
    m += d;
    if (m < 0) { m = 11; y--; }
    if (m > 11) { m = 0; y++; }
    state.month = { y, m };
    state.day = null;
    render();
  }

  // ---------------------------------------------------------------- след лезвия
  function drawTraces() {
    document.querySelectorAll('.feed').forEach((box) => {
      if (box.offsetParent === null) return;
      box.querySelectorAll(':scope > .trace-svg').forEach((n) => n.remove());
      const notches = [...box.querySelectorAll('.notch')];
      if (!notches.length) return;
      const br = box.getBoundingClientRect();
      const pts = notches.map((n) => {
        const r = n.getBoundingClientRect();
        return { x: r.left - br.left + r.width / 2, y: r.top - br.top + r.height / 2, live: n.parentElement.classList.contains('live') };
      });
      const H = box.scrollHeight;
      const x0 = pts[0].x;
      const W = 26;
      const ox = x0 - W / 2;
      let d = `M${W / 2} 0 L${W / 2} ${pts[0].y}`;
      let red = '';
      for (let i = 1; i < pts.length; i++) {
        const a = pts[i - 1];
        const b = pts[i];
        const dy = b.y - a.y;
        const bend = (i % 2 ? 1 : -1) * Math.min(9, 3 + dy / 40);
        const seg = ` C${W / 2 + bend} ${a.y + dy * 0.3} ${W / 2 + bend} ${b.y - dy * 0.3} ${W / 2} ${b.y}`;
        d += seg;
        if (a.live) red += `M${W / 2} ${a.y}` + seg;
      }
      const last = pts[pts.length - 1];
      const tail = Math.min(H, last.y + 60);
      d += ` C${W / 2 - 6} ${last.y + 20} ${W / 2 - 10} ${tail - 10} ${W / 2 - 14} ${tail}`;
      if (last.live) red += `M${W / 2} ${last.y} C${W / 2 - 6} ${last.y + 20} ${W / 2 - 10} ${tail - 10} ${W / 2 - 14} ${tail}`;
      const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.setAttribute('class', 'trace-svg');
      svg.setAttribute('width', W);
      svg.setAttribute('height', H);
      svg.setAttribute('aria-hidden', 'true');
      svg.style.cssText = `position:absolute;left:${ox}px;top:0;pointer-events:none;overflow:visible`;
      svg.innerHTML = `<path d="${d}" class="cut-all"/>${red ? `<path d="${red}" class="cut-live"/>` : ''}`;
      box.prepend(svg);
    });
  }

  // ---------------------------------------------------------------- подвал
  function renderFoot() {
    const f = $('#foot');
    if (!state.data) { f.innerHTML = ''; return; }
    const g = Date.parse(state.data.generated);
    const ago = now() - g;
    const when = dayKey(g) === dayKey(now()) ? `сегодня в ${hm(g)}` : `${fmtDay(dayKey(g), { short: true })} в ${hm(g)}`;
    let line = `Расписание обновлено ${when} МСК. Обновляется само в 09:00 и 15:00.`;
    if (state.offline) line = `<span class="stale">Нет связи — показано последнее расписание (обновлено ${when} МСК).</span>`;
    else if (ago > STALE_H * 3600e3) line = `<span class="stale">Источники давно не отвечали — показано расписание от ${when} МСК.</span>`;
    else if (state.data.complete === false) line += ' Часть источников в последний раз не ответила — их старты взяты из прошлого обновления.';
    f.innerHTML = `${line}<br>Источники: ФФККР, ISU, табло турниров. <button id="foot-about">Как это работает</button>`;
    $('#foot-about').onclick = () => openAbout();
  }

  // ---------------------------------------------------------------- шторки
  const sheet = $('#sheet');
  function openSheet(html, onOpen) {
    $('#sheet-body').innerHTML = `<div class="grab" aria-hidden="true"></div>${html}`;
    if (!sheet.open) { try { sheet.showModal(); } catch (e) { sheet.setAttribute('open', ''); } }
    sheet.scrollTop = 0;
    if (onOpen) onOpen($('#sheet-body'));
  }
  function closeSheet() { if (sheet.open) sheet.close(); if (location.hash.startsWith('#e=')) history.replaceState(null, '', location.pathname + location.search); }
  sheet.addEventListener('click', (ev) => { if (ev.target === sheet) closeSheet(); });
  sheet.addEventListener('close', () => { if (location.hash.startsWith('#e=')) history.replaceState(null, '', location.pathname + location.search); });

  function srcLabel(u) {
    try {
      const h = new URL(u).hostname.replace(/^www\./, '');
      return /\.pdf$/i.test(u) ? `расписание, ${h}` : /isu-skating/.test(h) ? 'страница турнира, ISU' : `протокол, ${h}`;
    } catch (e) { return 'протокол'; }
  }
  function icsName(id) { return 'e/' + id.replace(/:/g, '_') + '.ics'; }

  function openEvent(id) {
    const e = state.data && state.data.byId[id];
    if (!e) return;
    const t = now();
    const live = e.t0 <= t && t < e.t1;
    const w = !!state.watched[e.id];
    const seg = e.title.slice(e.tournament.length).replace(/^\s*—\s*/, '');
    const ours = e.ours || [];
    const day = dayKey(e.t0);
    const canRemind = e.t0 - 15 * 60e3 > t;
    openSheet(`
      <div class="sh-head">
        <div><div class="sh-kicker">${esc(e.tournament)}</div><h2 class="sh-title" id="sheet-title">${esc(seg)}</h2></div>
        <button class="x-btn" data-close aria-label="Закрыть">${icon('i-close')}</button>
      </div>
      <div class="sh-when"><span class="t">${hm(e.t0)}</span><span class="d">МСК · ${esc(fmtDay(day, { full: true }))}</span>${live ? '<span class="sh-live">● ИДЁТ</span>' : ''}</div>
      ${ours.length ? `<div class="sh-sec"><h3>Наши${ours.some((o) => o.time) ? ' · выход на лёд' : ''}</h3><ol class="sh-ours">${ours.map((o) => oursLine(o, false, { live, t0: e.t0 })).join('')}</ol></div>` : ''}
      ${e.broadcast && e.broadcast.length ? `<div class="sh-sec"><h3>Трансляция</h3><p>${esc(e.broadcast.join(' / '))}</p></div>` : ''}
      <div class="sh-sec"><h3>Место</h3><p>${esc(e.venue)}</p></div>
      <div class="sh-actions">
        <button class="btn ${w ? 'red' : 'ghost'}" data-watch="${esc(e.id)}">${icon(w ? 'i-eye-on' : 'i-eye')}${w ? 'Смотрю' : 'Буду смотреть'}</button>
        ${canRemind ? `<a class="btn ghost" href="${icsName(e.id)}" download>${icon('i-plus')}В календарь</a>` : '<span></span>'}
      </div>
      ${canRemind ? '<div class="sh-note">«В календарь» добавит старт в календарь телефона с напоминанием за 15 минут.</div>' : ''}
      <div class="sh-src">Источник: <a href="${esc(e.src)}" target="_blank" rel="noopener">${esc(srcLabel(e.src))}</a></div>
    `);
    if (location.hash !== '#e=' + e.id) history.replaceState(null, '', '#e=' + e.id);
  }

  function openFilters() {
    const f = JSON.parse(JSON.stringify(state.filters));
    const ts = tournaments().filter((t) => t.b >= addDays(dayKey(now()), -14)).sort((a, b) => a.a.localeCompare(b.a));
    const all = athletes();
    const body = () => `
      <div class="sh-head"><h2 class="sh-title" id="sheet-title">Фильтры</h2><button class="x-btn" data-close aria-label="Закрыть">${icon('i-close')}</button></div>
      <div class="f-group"><h3>Вид</h3><div class="f-chips">${KINDS.map(([k, l]) => `<button class="f-chip" data-k="${k}" aria-pressed="${f.kinds.includes(k)}">${l}</button>`).join('')}
        <button class="f-chip" data-wo aria-pressed="${f.watchedOnly}">Смотрю</button></div></div>
      <div class="f-group"><h3>Спортсмен</h3>
        <input class="f-search" id="f-q" type="search" placeholder="Фамилия, например Петросян" autocomplete="off" enterkeyhint="search">
        <ul class="f-list" id="f-ath"></ul></div>
      <div class="f-group"><h3>Турнир</h3><ul class="f-list">${ts.map((t) => `<li><button data-t="${esc(t.tid)}" aria-pressed="${f.tids.includes(t.tid)}"><span class="box"></span><span>${esc(t.name)}</span><span class="dates">${rangeText(t.a, t.b)}</span></button></li>`).join('')}</ul></div>
      <div class="f-foot"><button class="btn ghost" id="f-reset">Сбросить</button><button class="btn" id="f-apply">Показать</button></div>`;
    openSheet(body(), (root) => {
      const q = $('#f-q', root);
      const list = $('#f-ath', root);
      const drawAth = () => {
        const v = norm(q.value.trim());
        const chosen = f.athletes;
        let items = v ? all.filter((a) => norm(a).includes(v)).slice(0, 12) : chosen.slice();
        for (const c of chosen) if (!items.includes(c) && (!v || norm(c).includes(v))) items.unshift(c);
        if (!v && !chosen.length) items = (state.data.watchlist || []).slice(0, 9);
        list.innerHTML = items.map((a) => `<li><button data-a="${esc(a)}" aria-pressed="${chosen.includes(a)}"><span class="box"></span><span>${esc(a)}</span></button></li>`).join('') ||
          `<li style="padding:12px 0;color:var(--ink-3)">Нет такого спортсмена в расписании</li>`;
      };
      drawAth();
      q.addEventListener('input', drawAth);
      root.addEventListener('click', (ev) => {
        const b = ev.target.closest('button');
        if (!b) return;
        if (b.dataset.k) { toggleIn(f.kinds, b.dataset.k); b.setAttribute('aria-pressed', f.kinds.includes(b.dataset.k)); }
        else if (b.hasAttribute('data-wo')) { f.watchedOnly = !f.watchedOnly; b.setAttribute('aria-pressed', f.watchedOnly); }
        else if (b.dataset.t) { toggleIn(f.tids, b.dataset.t); b.setAttribute('aria-pressed', f.tids.includes(b.dataset.t)); }
        else if (b.dataset.a) { toggleIn(f.athletes, b.dataset.a); b.setAttribute('aria-pressed', f.athletes.includes(b.dataset.a)); }
        else if (b.id === 'f-reset') { f.kinds = []; f.tids = []; f.athletes = []; f.watchedOnly = false; root.querySelectorAll('[aria-pressed]').forEach((x) => x.setAttribute('aria-pressed', 'false')); q.value = ''; drawAth(); }
        else if (b.id === 'f-apply') { state.filters = f; saveFilters(); closeSheet(); render(); window.scrollTo(0, 0); }
      });
    });
  }
  function toggleIn(arr, v) { const i = arr.indexOf(v); if (i >= 0) arr.splice(i, 1); else arr.push(v); }
  function resetFilters() { state.filters = { kinds: [], tids: [], athletes: [], watchedOnly: false }; saveFilters(); render(); }

  const isIOS = () => /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const standalone = () => window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;

  function feedUrls() {
    const u = new URL('calendar.ics', location.href);
    const https = u.href;
    const webcal = https.replace(/^https?:/, 'webcal:');
    return { https, webcal, google: 'https://calendar.google.com/calendar/render?cid=' + encodeURIComponent(webcal) };
  }

  function openMenu() {
    const theme = store.get('theme', 'auto');
    const urls = feedUrls();
    const canInstall = !!state.installEvt;
    openSheet(`
      <div class="sh-head"><h2 class="sh-title" id="sheet-title">Ещё</h2><button class="x-btn" data-close aria-label="Закрыть">${icon('i-close')}</button></div>
      <ul class="menu-list">
        ${canInstall ? `<li><button id="m-install"><span>Установить приложение<small>Значок на экране, работает без сети</small></span>${icon('i-right')}</button></li>` : ''}
        ${!standalone() && isIOS() ? `<li><button id="m-ios"><span>Установить на iPhone<small>Через «Поделиться» → «На экран „Домой“»</small></span>${icon('i-right')}</button></li>` : ''}
        <li><a href="${isIOS() ? urls.webcal : urls.google}" id="m-sub"><span>Подписаться в календаре<small>${isIOS() ? 'Календарь iPhone' : 'Google Календарь'} — все старты сами появятся и будут обновляться</small></span>${icon('i-right')}</a></li>
        <li><a href="${isIOS() ? urls.google : urls.webcal}"><span>${isIOS() ? 'В Google Календарь' : 'В другой календарь (webcal)'}<small>Если пользуетесь ${isIOS() ? 'Google Календарём' : 'Outlook, Apple и др.'}</small></span>${icon('i-right')}</a></li>
        <li><button id="m-copy"><span>Скопировать ссылку на ленту<small>${esc(urls.https)}</small></span></button></li>
        <li><button id="m-refresh"><span>Обновить сейчас<small>Подтянуть свежее расписание с сайта</small></span></button></li>
        <li><div style="display:flex;align-items:center;justify-content:space-between;min-height:58px;border-bottom:1px solid var(--rule)"><span>Тема</span>
          <div class="seg3" role="group" aria-label="Тема">${[['auto', 'Авто'], ['light', 'Светлая'], ['dark', 'Тёмная']].map(([k, l]) => `<button data-theme="${k}" aria-pressed="${theme === k}">${l}</button>`).join('')}</div></div></li>
        <li><button id="m-about"><span>Как это работает</span>${icon('i-right')}</button></li>
      </ul>`, (root) => {
      root.addEventListener('click', async (ev) => {
        const b = ev.target.closest('button');
        if (!b) return;
        if (b.dataset.theme) { setTheme(b.dataset.theme); root.querySelectorAll('[data-theme]').forEach((x) => x.setAttribute('aria-pressed', x === b)); }
        else if (b.id === 'm-install') { closeSheet(); doInstall(); }
        else if (b.id === 'm-ios') { showIOSHint(true); closeSheet(); }
        else if (b.id === 'm-copy') { try { await navigator.clipboard.writeText(urls.https); toast('Ссылка скопирована'); } catch (e) { toast(esc(urls.https), 6000); } }
        else if (b.id === 'm-refresh') { closeSheet(); toast('Обновляю…', 1500); load(true); }
        else if (b.id === 'm-about') openAbout();
      });
    });
  }

  function openAbout() {
    openSheet(`
      <div class="sh-head"><h2 class="sh-title" id="sheet-title">Как это работает</h2><button class="x-btn" data-close aria-label="Закрыть">${icon('i-close')}</button></div>
      <div class="about">
        <p>Расписание собирается само дважды в день — в 09:00 и 15:00 МСК — с сайтов ФФККР, ISU и табло турниров. Время везде московское.</p>
        <p>Российские старты — все уровня МС и КМС. Международные — только сегменты, где выступают наши (россияне, в том числе под нейтральным статусом).</p>
        <p>У наших показано время выхода, когда организаторы его опубликовали, иначе — стартовый номер и разминка. Чего нет в источниках, того нет и здесь.</p>
        <p>Если источник не ответил, приложение показывает последнее полученное расписание и пишет внизу, когда оно обновлялось. Без сети работает по сохранённой копии.</p>
        <p>«Буду смотреть» отмечает старт. Кнопка «В календарь» добавляет его в календарь телефона с напоминанием за 15 минут — так напоминание сработает, даже если приложение закрыто.</p>
      </div>`);
  }

  function setTheme(k) {
    store.set('theme', k);
    if (k === 'auto') delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = k;
    const dark = k === 'dark' || (k === 'auto' && matchMedia('(prefers-color-scheme: dark)').matches);
    document.querySelectorAll('meta[name="theme-color"]').forEach((m) => { m.content = dark ? '#08121A' : '#EEF3F5'; m.removeAttribute('media'); });
  }

  // ---------------------------------------------------------------- «смотрю» и напоминания
  async function toggleWatch(id) {
    const on = !state.watched[id];
    if (on) state.watched[id] = true; else delete state.watched[id];
    store.set('watched', state.watched);
    render();
    if (sheet.open && location.hash === '#e=' + id) openEvent(id);
    if (on) {
      const e = state.data.byId[id];
      const canRemind = e && e.t0 - 15 * 60e3 > now();
      toast(canRemind ? `Смотрю. <a href="${icsName(id)}" download style="color:inherit;font-weight:600">В календарь с напоминанием →</a>` : 'Смотрю', canRemind ? 5000 : 2000);
      await askNotifications();
      scheduleReminders();
    }
  }
  async function askNotifications() {
    try {
      if (!('Notification' in window) || !('serviceWorker' in navigator)) return false;
      if (Notification.permission === 'default') await Notification.requestPermission();
      return Notification.permission === 'granted';
    } catch (e) { return false; }
  }
  const timers = [];
  async function scheduleReminders() {
    timers.splice(0).forEach(clearTimeout);
    try {
      if (!state.data || !('Notification' in window) || Notification.permission !== 'granted' || !('serviceWorker' in navigator)) return;
      const reg = await navigator.serviceWorker.ready;
      const t = now();
      for (const id of Object.keys(state.watched)) {
        const e = state.data.byId[id];
        if (!e) continue;
        const at = e.t0 - 15 * 60e3;
        if (at <= t || at - t > 2 ** 31 - 1) continue;
        const opts = { body: `${hm(e.t0)} МСК${e.broadcast && e.broadcast.length ? ' · ' + e.broadcast.join(' / ') : ''}`, tag: 'starty-' + id, icon: 'icons/icon-192.png', badge: 'icons/badge.png', data: { id } };
        if ('showTrigger' in Notification.prototype && typeof TimestampTrigger === 'function') {
          // браузеры с отложенными уведомлениями сработают и при закрытом приложении
          reg.showNotification(e.title, Object.assign({}, opts, { showTrigger: new TimestampTrigger(at) })).catch(() => {});
        } else {
          timers.push(setTimeout(() => reg.showNotification(e.title, opts).catch(() => {}), at - t));
        }
      }
    } catch (e) { /* без уведомлений — молча */ }
  }

  // ---------------------------------------------------------------- установка
  window.addEventListener('beforeinstallprompt', (ev) => {
    ev.preventDefault();
    state.installEvt = ev;
    if (!store.get('installDismissed', false)) showInstallBar();
  });
  window.addEventListener('appinstalled', () => { state.installEvt = null; $('#install').hidden = true; });
  function showInstallBar() {
    const box = $('#install');
    box.innerHTML = `<p><b>Установите приложение</b> — значок на экране, обновляется само, работает без сети.</p><button class="btn" id="do-install">Установить</button><button class="x-btn" id="x-install" aria-label="Скрыть">${icon('i-close')}</button>`;
    box.hidden = false;
    $('#do-install').onclick = doInstall;
    $('#x-install').onclick = () => { box.hidden = true; store.set('installDismissed', true); };
  }
  async function doInstall() {
    if (!state.installEvt) return;
    state.installEvt.prompt();
    try { await state.installEvt.userChoice; } catch (e) { /* отказ */ }
    state.installEvt = null;
    $('#install').hidden = true;
  }
  function showIOSHint(force) {
    if (!isIOS() || standalone()) return;
    if (!force && store.get('iosHintDismissed', false)) return;
    const box = $('#install');
    box.innerHTML = `<p><b>Установить на iPhone:</b> нажмите <svg class="ios-share"><use href="#i-share"/></svg> «Поделиться» внизу Safari, затем «На экран „Домой“».</p><button class="x-btn" id="x-install" aria-label="Скрыть">${icon('i-close')}</button>`;
    box.hidden = false;
    $('#x-install').onclick = () => { box.hidden = true; store.set('iosHintDismissed', true); };
  }

  // ---------------------------------------------------------------- события интерфейса
  document.addEventListener('click', (ev) => {
    const w = ev.target.closest('[data-watch]');
    if (w) { ev.stopPropagation(); toggleWatch(w.dataset.watch); return; }
    const c = ev.target.closest('[data-close]');
    if (c) { closeSheet(); return; }
    const chip = ev.target.closest('.chip-x');
    if (chip) {
      const { g, v } = chip.dataset;
      const f = state.filters;
      if (g === 'w') f.watchedOnly = false;
      if (g === 'k') toggleIn(f.kinds, v);
      if (g === 't') toggleIn(f.tids, v);
      if (g === 'a') toggleIn(f.athletes, v);
      saveFilters();
      render();
      return;
    }
    const day = ev.target.closest('.m-day');
    if (day) { state.day = day.dataset.day; render(); return; }
    const row = ev.target.closest('.ev[data-id]');
    if (row && !ev.target.closest('a')) openEvent(row.dataset.id);
  });
  $('#tab-feed').onclick = () => { state.view = 'feed'; store.set('view', 'feed'); render(); };
  $('#tab-month').onclick = () => { state.view = 'month'; store.set('view', 'month'); render(); };
  $('#btn-filter').onclick = () => state.data && openFilters();
  $('#btn-more').onclick = openMenu;
  window.addEventListener('resize', () => requestAnimationFrame(drawTraces));
  window.addEventListener('hashchange', () => {
    const m = location.hash.match(/^#e=(.+)$/);
    if (m && state.data) openEvent(decodeURIComponent(m[1]));
  });
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') return;
    // вернулись в приложение — свежие данные, если прошло больше получаса
    if (state.data && now() - (load._at || 0) > 30 * 60e3) { load._at = now(); load(); } else render();
  });
  // раз в минуту: часы; ленту — только если что-то началось, закончилось или наш откатал
  let sig = '';
  const statusSig = () => {
    const t = now();
    return state.data ? state.data.events.map((e) => (e.t1 <= t ? 'p' : e.t0 <= t ? 'l' + (e.ours || []).filter((o) => o.time && oursAt(e.t0, o.time) + 4 * 60e3 < t).length : '')).join('') + dayKey(t) : '';
  };
  setInterval(() => {
    renderClock();
    const s2 = statusSig();
    if (s2 !== sig) { sig = s2; if (!sheet.open) render(); }
  }, 30e3);
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => requestAnimationFrame(drawTraces));

  // ---------------------------------------------------------------- старт
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('sw.js').catch(() => {});
    navigator.serviceWorker.addEventListener('message', (m) => {
      if (m.data && m.data.type === 'data-updated') load();
    });
  }
  setTheme(store.get('theme', 'auto'));
  load._at = now();
  load().then(() => {
    const m = location.hash.match(/^#e=(.+)$/);
    if (m) openEvent(decodeURIComponent(m[1]));
    showIOSHint(false);
  });
})();
