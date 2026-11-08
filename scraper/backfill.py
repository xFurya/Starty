"""Добор протоколов прошлых сезонов в архив элементов (archive.py).

Два источника судейских протоколов (…JudgesDetailsperSkater.pdf):
  ISU    — results.isu.org/results/season{YY}{YY}/{код}/ ; коды строим по списку турниров
           из API ISU (в самом API ссылок на итоги прошлых сезонов нет);
  ФФККР  — страницы турниров из раздела «Соревнования» fsrussia.ru.

Запуск (повторяемый: сегменты, уже лежащие в архиве, не скачиваются заново):
    python3 -m scraper.backfill discover            # списки → isu.json, fsr.json
    python3 -m scraper.backfill run [--src ISU|ФФККР] [--limit N]

Папка списков — переменная BACKFILL_DIR или --dir.
"""
import argparse
import datetime as dt
import json
import os
import re
import sys
import time

from . import build, fsr, isu, net, profiles
from . import swisstiming as st

DIR = os.environ.get("BACKFILL_DIR",
                     "/tmp/claude-0/-home-user/5a88bd61-0bb3-5694-a928-6a6f6ae00e83/scratchpad/backfill")
FIRST_SEASON = 2018          # сезон 2018/2019
SINCE = dt.date(2018, 7, 1)  # ФФККР: турниры не раньше
ISU_RESULTS = "https://results.isu.org/results/"
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


def is_synchro(slug_or_title):
    return "синхрон" in slug_or_title.lower() or "sinhron" in slug_or_title.lower()


def is_jgp_title(title, results=""):
    """Этап юниорского Гран-при России: в ссылке «…etapN_jun» либо в названии юниоры + «Гран-при»."""
    t = title.lower()
    return bool(re.search(r"\d+etap\d*_jun", results or "")) or (
        bool(re.search(r"юниор|первенств", t)) and bool(re.search(r"гран[ -]?при", t)))


def season_of(d):
    y = d.year if d.month >= 7 else d.year - 1
    return f"{y}/{y + 1}"


def discover_fsr():
    """([{src, season, ev, start, url, intl}], счётчики)."""
    out, seen = [], set()
    stat = {"pages": 0, "tournaments": 0, "synchro": 0, "old": 0, "no_date": 0, "no_results": 0, "errors": 0}
    old_streak = dull = 0
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
        for u in fresh:
            stat["tournaments"] += 1
            if is_synchro(u):
                stat["synchro"] += 1
                continue
            pause()
            try:
                t = fsr.tournament(u)
            except net.FetchError as ex:
                stat["errors"] += 1
                log("  ! страница:", ex)
                continue
            if is_synchro(t["title"]):
                stat["synchro"] += 1
                continue
            if not t["start"]:
                try:
                    t["start"] = single_day(net.fetch(u))
                except net.FetchError:
                    pass
            if not t["start"]:
                stat["no_date"] += 1
                log("  ? нет дат:", u)
                recent = True  # дату не знаем — не считаем страницу старой
                continue
            if t["start"] < SINCE:
                stat["old"] += 1
                continue
            recent = True
            idx = build.results_index(t["results"])
            if not idx:
                stat["no_results"] += 1
                continue
            jgp = is_jgp_title(t["title"], idx)
            out.append({"src": "ФФККР", "season": season_of(t["start"]),
                        "ev": build.fsr_title(t["title"], jgp),
                        "start": t["start"].isoformat(), "url": idx, "intl": False, "page": u})
        log(f"  стр. {n}: всего {len(out)}")
        old_streak = 0 if recent else old_streak + 1
        if old_streak >= FSR_OLD_STREAK:
            break
        if n % 10 == 0:
            _write("fsr.json", out)
    return out, stat


# ---------------------------------------------------------------- загрузка в архив

def ingest_event(ar, arc, item, stats, saver=None):
    """Один турнир: index → категории → сегменты с PDF судейских оценок → ar.ingest."""
    url, intl = item["url"], item["intl"]
    try:
        idx = st.parse_index(url)
    except net.FetchError as ex:
        stats["index_errors"].append(f"{url}: {ex}")
        return
    except Exception as ex:  # старый формат табло: не роняем прогон
        stats["index_errors"].append(f"{url}: разбор: {ex!r}")
        return
    cats = build.categories_of(idx, intl)
    n_pdf = 0
    for c, kind, level in cats:
        for s in c["segments"]:
            seg, pdf = build.seg_code(s["name"]), s.get("judges_pdf")
            if not seg or not pdf:
                continue
            n_pdf += 1
            if ar.has(arc, pdf):
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


def new_stats():
    return {"events": 0, "segments": 0, "skaters": 0, "have": 0, "empty": [],
            "index_errors": [], "pdf_errors": [], "no_pdf": []}


def run(ar, items, limit=None):
    arc = ar.load()
    stats = new_stats()
    saver = lambda: ar.save(arc)
    try:
        for it in items[:limit] if limit else items:
            stats["events"] += 1
            log(f"[{stats['events']}] {it['src']} {it['season']} {it['ev']}")
            ingest_event(ar, arc, it, stats, saver)
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
    ap.add_argument("cmd", choices=["discover", "run"])
    ap.add_argument("--src", choices=["ISU", "ФФККР"])
    ap.add_argument("--limit", type=int)
    ap.add_argument("--dir", default=DIR)
    ap.add_argument("--only", choices=["ISU", "ФФККР"], help="discover: только один источник")
    a = ap.parse_args(argv)
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
    items = []
    for name, src in (("isu.json", "ISU"), ("fsr.json", "ФФККР")):
        if a.src in (None, src):
            items += _read(name)
    stats = run(ar, items, a.limit)
    log(json.dumps({k: (len(v) if isinstance(v, list) else v) for k, v in stats.items()}, ensure_ascii=False))
    for k in ("index_errors", "pdf_errors", "empty", "no_pdf"):
        for x in stats[k][:20]:
            log(" ", k, x)
    return 0


if __name__ == "__main__":
    sys.exit(main())
