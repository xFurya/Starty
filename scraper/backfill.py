"""Добор протоколов прошлых сезонов в архив элементов (archive.py).

Два источника судейских протоколов (…JudgesDetailsperSkater.pdf):
  ISU    — results.isu.org/results/season{YY}{YY}/{код}/ ; коды строим по списку турниров
           из API ISU (в самом API ссылок на итоги прошлых сезонов нет);
  ФФККР  — страницы турниров из раздела «Соревнования» fsrussia.ru.

Запуск (повторяемый: сегменты, уже лежащие в архиве, не скачиваются заново):
    python3 -m scraper.backfill discover            # списки → isu.json, fsr.json
    python3 -m scraper.backfill run [--src ISU|ФФККР] [--limit N] [--out ПУТЬ] [--shard I/N] [--skip-in АРХИВ]
    python3 -m scraper.backfill merge ЧАСТЬ1.json ЧАСТЬ2.json … [--out ПУТЬ] [--full] [--not-in АРХИВ]

Прошлые сезоны лежат в своём файле (archive.PAST), а не в archive.ARCHIVE — его пишет сбор по CI.
run кладёт в --out (по умолчанию PAST). Несколько процессов гоняют параллельно, каждый свою долю
(--shard I/N берёт items[I::N], I с нуля) и свой --out; merge сливает части в один архив, --full
ставит признак полноты (прошлые сезоны собраны целиком).

Добор захватывает и начало нынешнего сезона — турниры, до которых сбор уже не дотягивается. Один
протокол в обоих файлах удвоил бы счёт элементов (archive.merge), поэтому файлы не пересекаются:
run --skip-in data/archive.json пропускает протоколы, которые уже взял сбор, merge --not-in
data/archive.json отказывается писать, если пересечение всё же есть, а сбор не берёт то, что лежит
в прошлых сезонах (results._in_past).

В архив не идут любители, балеты на льду и синхронное катание (skip_event), а из российских табло —
разряды и детские категории (people._SKIP_CAT).

Старый формат табло (comnet: турниры ISU в Японии — NHK Trophy, wc2019, wc2023, wtt…, jgpjpn2023):
в index.htm нет CATnnn/SEGnnn, файлы с постоянными именами dataNNNN.htm/.pdf. Его разбирает
comnet_index; ссылка на PDF берётся из самой страницы. Страницу wtt2025 (Swiss Timing без CATnnn:
категория и сегмент в каждой строке) он тоже понимает.

Папка списков — переменная BACKFILL_DIR или --dir (иначе временная папка starty-backfill).
"""
import argparse
import datetime as dt
import html
import json
import os
import re
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urljoin

from . import build, fsr, isu, net, profiles
from . import people as pp
from . import swisstiming as st

DIR = os.environ.get("BACKFILL_DIR") or os.path.join(tempfile.gettempdir(), "starty-backfill")
FIRST_SEASON = 2018          # сезон 2018/2019
SINCE = dt.date(2018, 7, 1)  # ФФККР: турниры не раньше
ISU_RESULTS = "https://results.isu.org/results/"
WORKERS = 3                  # потоков при чтении страниц турниров ФФККР
PAUSE = 0.4                  # пауза между запросами, с
SAVE_EVERY = 20              # сегментов между сохранениями архива
FSR_LIST = [fsr.BASE + "/sorevnovaniya", fsr.BASE + "/sorevnovaniya/sorevnovaniya/page-{}"]
FSR_MAX_PAGES = 200
FSR_OLD_STREAK = 3           # страниц подряд только со старыми турнирами → конец


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def pause():
    time.sleep(PAUSE)


# ---------------------------------------------------------------- ISU: коды

def seasons(today=None):
    """['2018/2019', …, текущий] — сезон начинается 1 июля."""
    last = int(isu.season_name(today or dt.date.today()).split("/")[0])
    return [f"{y}/{y + 1}" for y in range(FIRST_SEASON, last + 1)]


def season_dir(season):
    """'2018/2019' → 'season1819'."""
    a, b = season.split("/")
    return f"season{a[2:]}{b[2:]}"


def isu_kind(e):
    """Вид турнира по подтипу и названию в API: gp, jgp, gpf, jgpf, ec, fc, wc, wjc, owg, wtt или None
    (Challenger Series и прочие международные на results.isu.org не лежат)."""
    sub = (e.get("event_sub_type_name") or "").lower()
    name = (e.get("name") or "").lower()
    if "synchro" in name or "synchro" in sub or "youth" in name:
        return None  # синхронное катание и юношеская Олимпиада — не наше
    if "team trophy" in name:
        return "wtt"
    junior = "junior grand prix" in name or "jgp" in name or "junior grand prix" in sub
    if sub in ("isu grand prix", "isu grand prix final", "isu junior grand prix",
               "isu junior grand prix final") or "grand prix" in sub:
        if re.search(r"\bfinal\b", name):
            return "jgpf" if junior else "gpf"
        return "jgp" if junior else "gp"
    if "european" in sub:
        return "ec"
    if "four continents" in sub:
        return "fc"
    if "world junior" in sub:
        return "wjc"
    if "world championships" in sub:
        return "wc"
    if "olympic" in sub:
        return "owg"
    return None


def _year(e):
    return (e.get("from_date") or "")[:4]


def isu_codes(e, dup=1, n=0):
    """Кандидаты в код турнира на results.isu.org, лучший первым.
    dup — сколько турниров того же вида, страны и года в сезоне, n — номер этого (с 0):
    при повторах код второго — jgpfra22021, первого — jgpfra2021; порядок в API
    не гарантирует соответствия, поэтому при dup>1 пробуем оба и сверяем даты."""
    kind = isu_kind(e)
    if kind is None:
        return []
    y = _year(e)
    if kind in ("gpf", "jgpf"):
        # финал называют по сезону (gpf1819) или по году начала (gpf2025)
        s = e.get("_season") or ""
        a, b = (s.split("/") + ["", ""])[:2]
        return [f"{kind}{a[2:]}{b[2:]}", f"{kind}{a}"]
    if kind in ("gp", "jgp"):
        cc = (e.get("country_code") or "").lower()
        base = f"{kind}{cc}{y}"
        if dup <= 1:
            return [base]
        alts = [f"{kind}{cc}{k}{y}" for k in range(2, dup + 1)] + [f"{kind}{cc}1{y}"]
        alts += [f"{kind}{cc}{y}{k}" for k in range(2, dup + 1)]
        return [base] + alts
    return [f"{kind}{y}"]


def _page_dates(page):
    """Даты проведения в шапке index.htm: (с, по) или None."""
    m = re.search(r"(\d{2})\.(\d{2})\.(\d{4})\s*[-–]\s*(\d{2})\.(\d{2})\.(\d{4})", page)
    if not m:
        return None
    g = [int(x) for x in m.groups()]
    try:
        return dt.date(g[2], g[1], g[0]), dt.date(g[5], g[4], g[3])
    except ValueError:
        return None


def _date_ok(page, e):
    """Страница относится к этому турниру: даты на ней пересекаются с датами из API (запас 3 дня;
    у Олимпиады на странице считается и командный турнир до официального начала).
    Страница без дат подходит."""
    got = _page_dates(page)
    if not got:
        return True
    a = dt.date.fromisoformat((e.get("from_date") or "")[:10])
    b = dt.date.fromisoformat((e.get("to_date") or e.get("from_date") or "")[:10])
    gap = dt.timedelta(days=3)
    return got[0] <= b + gap and got[1] >= a - gap


def display_name(e):
    """Русское название для архива: как в приложении (profiles.event_ru)."""
    raw = re.sub(r"\s+", " ", e.get("name") or "").strip()
    raw = raw.replace("Figure Skating ", "").replace("Junior World Championships", "World Junior Championships")
    raw = re.sub(r"\bGrand Prix of Final\b", "Grand Prix Final", raw)
    kind = isu_kind(e)
    if kind == "jgp":
        raw = raw.replace("Junior Grand Prix", "JGP")
    elif kind == "gp":
        raw = re.sub(r"^(ISU )?Grand Prix (?!Final)", r"\1GP ", raw)
    ru = profiles.event_ru(raw)
    ru = re.sub(r"^(J?GP) (\d{4}) (.+)$", r"\1 \3 \2", ru)  # «GP 2025 Saatva Skate America» — год в конец
    if kind == "gpf" and not ru.startswith("Финал"):
        a, b = e["_season"].split("/")
        ru = f"Финал Гран-при {a}/{b[2:]}"
    if kind == "jgpf" and not ru.startswith("Финал"):
        a, b = e["_season"].split("/")
        ru = f"Финал юниорского Гран-при {a}/{b[2:]}"
    return ru


def _probe(season, code, e):
    """(URL index.htm или None, причина): ok / нет страницы / другие даты / старый формат табло
    (страница есть, но parse_index категорий не находит — data0100.htm вместо CATnnnEN.htm)."""
    url = f"{ISU_RESULTS}{season_dir(season)}/{code}/index.htm"
    pause()
    try:
        page = net.fetch(url)
    except net.FetchError:
        return None, "нет страницы"
    if not _date_ok(page, e):
        return None, "другие даты"
    try:
        if st.parse_index_page(page, url)["categories"]:
            return url, "ok"
    except Exception:
        pass
    try:
        if any(seg.get("judges_pdf") for c in comnet_index(page, url)["categories"] for seg in c["segments"]):
            return url, "ok"
    except Exception:
        pass
    return None, "старый формат"


def _extras(season, events):
    """Командный чемпионат мира (wtt) иногда не помечен в API: в нечётные годы пробуем код в сезоне."""
    a = int(season.split("/")[0])
    if any(isu_kind(e) == "wtt" for e in events):
        return []
    return [{"name": f"ISU World Team Trophy {a + 1}", "event_sub_type_name": "",
             "country_code": "", "from_date": f"{a + 1}-04-01", "_season": season, "_extra": True}
            ] if (a + 1) in (2019, 2021, 2023, 2025) else []


def discover_isu(today=None):
    """([{src, season, ev, start, url, intl, code}], [не найденные], {пропущено по виду})."""
    found, missing, skipped = [], [], {}
    claimed = set()
    for season in seasons(today):
        try:
            events = net.fetch_json(isu.API + "/events/list", data={
                "pagesize": 200, "discipline_id": 1, "season": season}).get("data") or []
        except net.FetchError as ex:
            log("  ! список ISU", season, ex)
            continue
        for e in events:
            e["_season"] = season
        events = sorted(events, key=lambda e: e.get("from_date") or "")
        groups = {}
        for e in events:
            if isu_kind(e) in ("gp", "jgp"):
                groups.setdefault((isu_kind(e), e.get("country_code"), _year(e)), []).append(e)
        todo = [e for e in events if isu_kind(e)] + _extras(season, events)
        for e in events:
            if not isu_kind(e):
                sub = e.get("event_sub_type_name") or "—"
                skipped[sub] = skipped.get(sub, 0) + 1
        for e in todo:
            kind = isu_kind(e)
            grp = groups.get((kind, e.get("country_code"), _year(e)), [e])
            codes = isu_codes(e, len(grp), grp.index(e) if e in grp else 0)
            url = code = None
            why = []
            for code in codes:
                u = f"{ISU_RESULTS}{season_dir(season)}/{code}/index.htm"
                if u in claimed:
                    continue
                url, reason = _probe(season, code, e)
                if url:
                    break
                why.append(f"{code}: {reason}")
            if not url:
                if not e.get("_extra"):
                    missing.append({"season": season, "name": e.get("name"), "tried": why})
                    log("  - нет кода:", season, e.get("name"), why)
                continue
            claimed.add(url)
            found.append({"src": "ISU", "season": season, "ev": display_name(e),
                          "start": (e.get("from_date") or "")[:10], "url": url, "intl": True, "code": code})
            log("  +", season, code)
    return found, missing, skipped


# ---------------------------------------------------------------- ФФККР: список

def list_links(page):
    """Ссылки на страницы турниров в списке «Соревнования» (без rss/atom/page-N), по порядку."""
    out = []
    for l in re.findall(r'href="(/sorevnovaniya/sorevnovaniya/[^"#?]+)[#?"]', page):
        if re.search(r"/(page-\d+|rss|atom)$", l):
            continue
        u = fsr.BASE + l
        if u not in out:
            out.append(u)
    return out


def single_day(page):
    """Дата турнира на один день («Сроки проведения: 02 мая 2026 года») — fsr.tournament её не разбирает."""
    m = re.search(r"Сроки проведения:(?:\s|&nbsp;|<[^>]+>)*(\d{1,2})\s+([а-я]+)\s+(\d{4})", page)
    mon = fsr.month_num(m.group(2)) if m else None
    if not mon:
        return None
    try:
        return dt.date(int(m.group(3)), mon, int(m.group(1)))
    except ValueError:
        return None


# любители, балеты на льду, синхронное катание: слова в названии и латиницей в адресах страницы и табло
SKIP_EVENT = re.compile(r"любител|балет|синхрон|l[yj]ubit|balet|ballet|adult|s[iy]n(?:kh|ch|h)", re.I)


def skip_event(*texts):
    """Турнир не для архива: любители, балеты на льду, синхронное катание."""
    return bool(SKIP_EVENT.search(" ".join(t or "" for t in texts)))


def is_jgp_title(title, results=""):
    """Этап юниорского Гран-при России: в ссылке «…etapN_jun» или «…Netap/jun» либо в названии
    юниоры + «Гран-при»."""
    t = title.lower()
    return bool(re.search(r"\d+etap\d*[_/]jun", results or "")) or (
        bool(re.search(r"юниор|первенств", t)) and bool(re.search(r"гран[ -]?при", t)))


QUOTED = r'["«“]([^"«»“”]+)["»”]'


def past_title(full, results):
    """Название турнира ФФККР прошлых сезонов → как его показывает приложение. full — заголовок
    страницы целиком (fsr.tournament()["full"]), results — адрес табло: на сайте чемпионат России
    назван по спонсору («Ростелеком - Чемпионат России 2019»), этапы Кубка России — без номера, а у
    этапов Гран-при 2023–2025 название города стоит после дефиса."""
    t = re.sub(r"\s+", " ", full.replace("\xa0", " ")).strip()
    first = t.split(" - ")[0].strip()
    u = (results or "").lower()
    if "/rusnat" in u:
        return "Чемпионат России"
    if "/junnat" in u:
        return "Первенство России среди юниоров"
    stage = re.search(r"/(\d)etap", u)
    junior = bool(re.search(r"etap\d*[_/]jun", u))
    if stage and not junior and re.search(r"Куб(?:ок|ка) России", t):
        return f"{stage.group(1)} этап Кубка России"
    gp = re.search(r'["«“](?:Ростелеком\s+)?Гран[ -]При России\s*[–—-]?\s*([^"«»“”]+)["»”]', t, re.I)
    if gp and not first.startswith("Финал"):
        return f"Гран-при России «{build.clean_ru_name(gp.group(1))}»"
    m = re.match(r"^(?:Всероссийск\w+|Международн\w+)\s+(?:соревнования|физкультурное мероприятие|турнир)\s+"
                 + QUOTED + r"$", first) or re.match(r"^ВС\s+" + QUOTED + r"$", first)
    if m and not junior:
        return build.clean_ru_name(m.group(1))
    m = re.match(r"^Всероссийские соревнования\s+(памяти\s+.+)$", first)
    if m:
        name = build.clean_ru_name(m.group(1))
        return name[:1].upper() + name[1:]
    return build.fsr_title(first, junior or is_jgp_title(first, results))


def season_of(d):
    y = d.year if d.month >= 7 else d.year - 1
    return f"{y}/{y + 1}"


def load_tournament(u):
    """Страница турнира → (причина отказа или None, запись списка или None).
    Причины: skip (любители, балеты, синхронное), error, no_date, old, no_results."""
    if skip_event(u):
        return "skip", None
    pause()
    try:
        t = fsr.tournament(u)
    except net.FetchError as ex:
        log("  ! страница:", ex)
        return "error", None
    full = t.get("full") or t["title"]
    if skip_event(full, t["results"]):
        return "skip", None
    if not t["start"]:
        try:
            t["start"] = single_day(net.fetch(u))
        except net.FetchError:
            pass
    if not t["start"]:
        log("  ? нет дат:", u)
        return "no_date", None
    if t["start"] < SINCE:
        return "old", None
    idx = build.results_index(t["results"])
    if not idx:
        return "no_results", None
    return None, {"src": "ФФККР", "season": season_of(t["start"]), "ev": past_title(full, idx),
                  "start": t["start"].isoformat(), "url": idx, "intl": False, "page": u}


def discover_fsr():
    """([{src, season, ev, start, url, intl}], счётчики). Страницы турниров читаем в WORKERS потоков
    (сайт отвечает по ~3 с); сам список — по одной странице."""
    out, seen = [], set()
    stat = {"pages": 0, "tournaments": 0, "skip": 0, "old": 0, "no_date": 0, "no_results": 0, "error": 0}
    old_streak = dull = 0
    with ThreadPoolExecutor(WORKERS) as pool:
        for n in range(1, FSR_MAX_PAGES + 1):
            url = FSR_LIST[0] if n == 1 else FSR_LIST[1].format(n)
            pause()
            try:
                links = list_links(net.fetch(url))
            except net.FetchError as ex:
                log("  конец списка:", ex)
                break
            if not links:
                break
            fresh = [u for u in links if u not in seen]
            if not fresh:
                # сайт каждые 10 страниц повторяет одну из прежних (page-11 = page-2): пропускаем,
                # но три пустых подряд — конец списка
                dull += 1
                if dull >= 3:
                    break
                continue
            dull = 0
            stat["pages"] += 1
            seen.update(fresh)
            recent = False
            for why, rec in pool.map(load_tournament, fresh):
                stat["tournaments"] += 1
                if why:
                    stat[why] += 1
                # дату не знаем (no_date) — страницу старой не считаем
                recent = recent or why in (None, "no_date", "no_results")
                if rec:
                    out.append(rec)
            log(f"  стр. {n}: всего {len(out)}")
            old_streak = 0 if recent else old_streak + 1
            if old_streak >= FSR_OLD_STREAK:
                break
            if n % 10 == 0:
                _write("fsr.json", out)
    return out, stat


# ---------------------------------------------------------------- старый формат табло (comnet)

MONTHS = {m: i + 1 for i, m in enumerate("jan feb mar apr may jun jul aug sep oct nov dec".split())}
DATE_EN = re.compile(r"(\d{1,2})\s+([A-Za-z]{3})[A-Za-z]*\.?\s+(\d{4})")
DATE_DOT = re.compile(r"(\d{1,2})\.(\d{2})\.(\d{4})")
TIME_RE = re.compile(r"^(\d{1,2}):(\d{2})(?::\d{2})?$")


def _plain(s):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"(?s)<[^>]+>", " ", s)).replace("\xa0", " ")).strip()


def _cells(row):
    """[(атрибуты, текст, [(href, текст ссылки)])] строки: ячейки td/th, регистр тегов не важен."""
    out = []
    for attrs, inner in re.findall(r"(?is)<t[dh]\b([^>]*)>(.*?)</t[dh]\s*>", row):
        links = [(html.unescape(h).strip(), _plain(t)) for h, t in
                 re.findall(r"""(?is)<a\b[^>]*?\bhref\s*=\s*["']?([^"'\s>]+)[^>]*>(.*?)</a\s*>""", inner)]
        out.append((attrs, _plain(inner), links))
    return out


def _sched_date(text):
    m = DATE_EN.search(text)
    if m and m.group(2).lower() in MONTHS:
        d, mon, y = int(m.group(1)), MONTHS[m.group(2).lower()], int(m.group(3))
    else:
        m = DATE_DOT.search(text)
        if not m:
            return None
        d, mon, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
    try:
        return dt.date(y, mon, d)
    except ValueError:
        return None


def comnet_index(page, url):
    """index.htm старого формата → {"categories": [{name, segments: [{name, url, judges_pdf, start}]}]}
    (как parse_index_page в части, которую читает ingest_event). Строки режем по </tr>: в расписании
    у comnet нет открывающих <TR>. Категория — ячейка с классом Header… ; сегмент — ячейка с rowspan и
    без ссылки, PDF и страница сегмента — ссылки в её строке и следующих. Swiss Timing без CATnnn
    (wtt2025): категория и сегмент в первых двух ячейках каждой строки. start — по расписанию в конце
    страницы (дата с rowspan действует на следующие строки), без расписания None."""
    cats, cat, seg = [], None, None
    sched, cur_date, in_sched = {}, None, False

    def add_seg(name, c):
        nonlocal seg, cat
        if cat is None or cat["name"] != c:
            cat = {"name": c, "segments": []}
            cats.append(cat)
        seg = {"name": name, "url": "", "judges_pdf": None, "start": None}
        cat["segments"].append(seg)

    for row in re.split(r"(?i)</tr\s*>", page):
        cells = _cells(row)
        if not cells:
            continue
        texts = [t for _, t, _ in cells]
        links = [(urljoin(url, h), t) for _, _, ls in cells for h, t in ls]
        if [t.lower() for t in texts if t] == ["date", "time", "category", "segment"]:
            in_sched = True
            continue
        if in_sched:
            for t in texts:
                d = _sched_date(t)
                if d:
                    cur_date = d
            tm = next((TIME_RE.match(t) for t in texts if TIME_RE.match(t)), None)
            target = next((h for h, _ in links if h.lower().split("?")[0].endswith(".htm")), None)
            if tm and cur_date and target:
                sched[target.lower()] = dt.datetime.combine(cur_date, dt.time(int(tm.group(1)), int(tm.group(2))))
            continue
        attrs0, text0, links0 = cells[0]
        if re.search(r"(?i)class\s*=\s*[\"']?header", attrs0) and text0:
            cat, seg = {"name": text0, "segments": []}, None
            cats.append(cat)
            continue
        if re.search(r"(?i)rowspan", attrs0) and text0 and not links0 and cat is not None:
            seg = {"name": text0, "url": "", "judges_pdf": None, "start": None}
            cat["segments"].append(seg)
        elif (len(cells) >= 2 and text0 and texts[1] and not links0
              and any(re.search(r"(?i)SEG\d+\.htm$", h) for h, _ in links)):
            add_seg(texts[1], text0)
        if seg is None:
            continue
        for h, t in links:
            low, tl = h.lower().split("?")[0], t.lower()
            if low.endswith(".pdf") and "judge" in tl:
                seg["judges_pdf"] = h
            elif low.endswith(".htm") and ("starting order" in tl or "classification" in tl):
                seg["url"] = h
    for c in cats:
        for s in c["segments"]:
            s["start"] = sched.get(s["url"].lower()) if s["url"] else None
    return {"categories": [c for c in cats if c["segments"]]}


# ---------------------------------------------------------------- загрузка в архив

def ingest_event(ar, arc, item, stats, saver=None, skip=()):
    """Один турнир: index → категории → сегменты с PDF судейских оценок → ar.ingest.
    skip — адреса протоколов, которые уже взял сбор: их не берём (см. начало файла)."""
    url, intl = item["url"], item["intl"]
    try:
        page = net.fetch(url)
    except net.FetchError as ex:
        stats["index_errors"].append(f"{url}: {ex}")
        return
    bad = None
    try:
        idx = st.parse_index_page(page, url)
        extra = scores_links(page, url)
    except Exception as ex:  # старый формат табло: не роняем прогон
        idx, extra, bad = {"categories": []}, {}, ex
    if not idx["categories"]:
        try:
            old = comnet_index(page, url)  # старый формат (comnet): файлы с постоянными именами
        except Exception as ex:
            old, bad = {"categories": []}, bad or ex
        if old["categories"]:
            idx, bad = old, None
    if bad is not None:
        stats["index_errors"].append(f"{url}: разбор: {bad!r}")
        return
    cats = build.categories_of(idx, intl)
    if not cats and not intl and idx["categories"]:
        cats = build.categories_of(idx, True)  # английская версия табло ФФККР (…/ENG/): названия по-английски
    if not intl:
        # разряды, дети, любительские классы: английская версия табло мимо fsr.low_level проходит
        # название — и как есть, и с латинскими двойниками, переведёнными в кириллицу: «Дeвoчки» из
        # смешанных букв ловится только после перевода, а «Basic Novice» — только до него
        cats = [c for c in cats if not (pp._SKIP_CAT.search(c[0]["name"])
                                        or pp._SKIP_CAT.search(c[0]["name"].translate(pp._HOMO)))]
    n_pdf = 0
    for c, kind, level in cats:
        for s in c["segments"]:
            seg = build.seg_code(s["name"])
            pdf = s.get("judges_pdf") or extra.get(s["url"].lower())
            if not seg or not pdf:
                continue
            n_pdf += 1
            if ar.has(arc, pdf) or pdf in skip:
                stats["have"] += 1
                continue
            pause()
            try:
                skaters = st.parse_judges(net.pdf_text(pdf))
            except net.FetchError as ex:
                stats["pdf_errors"].append(f"{pdf}: {ex}")
                continue
            except Exception as ex:
                stats["pdf_errors"].append(f"{pdf}: разбор: {ex!r}")
                continue
            if not skaters:
                stats["empty"].append(pdf)
                continue
            day = s["start"].date().isoformat() if s.get("start") else item["start"]
            ar.ingest(arc, skaters, {"u": pdf, "ev": item["ev"], "d": day, "kind": kind,
                                     "level": level, "seg": seg, "src": item["src"]})
            stats["segments"] += 1
            stats["skaters"] += len(skaters)
            if saver and stats["segments"] % SAVE_EVERY == 0:
                saver()
    if not cats:
        stats["index_errors"].append(f"{url}: нет категорий")
    elif not n_pdf:
        stats["no_pdf"].append(url)


def scores_links(page, url):
    """{адрес сегмента: PDF «…Scores.pdf»} с index.htm. У ISU 2018/19 и у ФФККР судейские оценки лежат
    в «<имя>_Scores.pdf» (тот же «JUDGES DETAILS PER SKATER», что и JudgesDetailsperSkater), а
    parse_index видит только JudgesDetails. Файл, на который ссылаются два сегмента, не берём:
    чей он, по ссылке не понять."""
    seg_of, count = {}, {}
    for row in re.findall(r"(?is)<tr[^>]*>(.*?)</tr>", page):
        seg = re.search(r'(?i)href=["\']?(SEG\d+\.htm)', row)
        pdf = re.search(r'(?i)href=["\']?([^"\'\s>]*Scores\.pdf)', row)
        if seg and pdf:
            full = urljoin(url, pdf.group(1))
            seg_of[urljoin(url, seg.group(1)).lower()] = full
            count[full] = count.get(full, 0) + 1
    return {k: v for k, v in seg_of.items() if count[v] == 1}


def new_stats():
    return {"events": 0, "segments": 0, "skaters": 0, "have": 0, "empty": [],
            "index_errors": [], "pdf_errors": [], "no_pdf": []}


def shard(items, spec):
    """'I/N' → items[I::N] (I с нуля, 0 ≤ I < N)."""
    try:
        i, n = (int(x) for x in spec.split("/"))
    except ValueError:
        raise ValueError(f"доля должна быть вида I/N: {spec!r}")
    if not 0 <= i < n:
        raise ValueError(f"доля {spec!r}: нужно 0 ≤ I < N")
    return items[i::n]


def merge_parts(ar, files, out=None, full=False, not_in=None):
    """Части run → один архив: пустой, затем ar.merge в порядке files; full ставит признак полноты.
    not_in — файл архива сбора: общий с ним протокол — отказ (ValueError), ничего не пишется."""
    dst = ar.empty()
    for f in files:
        ar.merge(dst, ar.load(f))
    if not_in:
        both = sorted(set(ar.urls(ar.load(not_in))) & set(ar.urls(dst)))
        if both:
            raise ValueError(f"протоколов и в частях, и в {not_in}: {len(both)}, первый {both[0]}")
    if full:
        dst["full"] = True
    ar.save(dst, out or ar.PAST)
    log(f"протоколов: {len(dst['segs'])}, спортсменов: {len(dst['ath'])}")
    return dst


def run(ar, items, limit=None, path=None, skip=()):
    """Прошлые сезоны — в свой файл (по умолчанию ar.PAST), ARCHIVE не трогаем.
    skip — адреса протоколов, которые уже взял сбор."""
    path = path or ar.PAST
    arc = ar.load(path)
    stats = new_stats()
    saver = lambda: ar.save(arc, path)
    try:
        for it in items[:limit] if limit else items:
            if skip_event(it.get("ev"), it.get("url"), it.get("page")):
                continue
            stats["events"] += 1
            log(f"[{stats['events']}] {it['src']} {it['season']} {it['ev']}")
            ingest_event(ar, arc, it, stats, saver, skip)
            pause()
    finally:
        saver()
    return stats


# ---------------------------------------------------------------- CLI

def _write(name, data):
    os.makedirs(DIR, exist_ok=True)
    with open(os.path.join(DIR, name), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)


def _read(name):
    try:
        with open(os.path.join(DIR, name), encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return []


def _count(items):
    c = {}
    for it in items:
        c.setdefault(it["season"], {}).setdefault(it["src"], 0)
        c[it["season"]][it["src"]] += 1
    return c


def main(argv=None):
    global DIR
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["discover", "run", "merge"])
    ap.add_argument("files", nargs="*", help="merge: файлы частей")
    ap.add_argument("--src", choices=["ISU", "ФФККР"])
    ap.add_argument("--limit", type=int)
    ap.add_argument("--dir", default=DIR)
    ap.add_argument("--only", choices=["ISU", "ФФККР"], help="discover: только один источник")
    ap.add_argument("--out", help="run, merge: файл архива (по умолчанию archive.PAST)")
    ap.add_argument("--shard", help="run: доля I/N списка (items[I::N], I с нуля)")
    ap.add_argument("--full", action="store_true", help="merge: отметить архив полным")
    ap.add_argument("--skip-in", help="run: файл архива сбора — его протоколы не берём")
    ap.add_argument("--not-in", help="merge: файл архива сбора — общий с ним протокол считается ошибкой")
    a = ap.parse_args(argv)
    if a.cmd != "merge" and a.files:
        ap.error("лишние аргументы: " + " ".join(a.files))
    DIR = a.dir
    if a.cmd == "discover":
        if a.only != "ФФККР":
            found, missing, skipped = discover_isu()
            _write("isu.json", found)
            _write("isu_missing.json", missing)
            log("ISU:", json.dumps(_count(found), ensure_ascii=False), "не найдено:", len(missing),
                "пропущено (не на results.isu.org):", json.dumps(skipped, ensure_ascii=False))
        if a.only != "ISU":
            found, stat = discover_fsr()
            _write("fsr.json", found)
            log("ФФККР:", json.dumps(_count(found), ensure_ascii=False), stat)
        return 0
    from . import archive as ar
    if a.cmd == "merge":
        if not a.files:
            ap.error("merge: укажите файлы частей")
        try:
            merge_parts(ar, a.files, a.out, a.full, a.not_in)
        except ValueError as ex:
            log("!", ex)
            return 1
        return 0
    items = []
    for name, src in (("isu.json", "ISU"), ("fsr.json", "ФФККР")):
        if a.src in (None, src):
            items += _read(name)
    if a.shard:
        try:
            items = shard(items, a.shard)
        except ValueError as ex:
            ap.error(str(ex))
    skip = set(ar.urls(ar.load(a.skip_in))) if a.skip_in else ()
    stats = run(ar, items, a.limit, a.out, skip)
    log(json.dumps({k: (len(v) if isinstance(v, list) else v) for k, v in stats.items()}, ensure_ascii=False))
    for k in ("index_errors", "pdf_errors", "empty", "no_pdf"):
        for x in stats[k][:20]:
            log(" ", k, x)
    return 0


if __name__ == "__main__":
    sys.exit(main())
