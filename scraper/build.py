"""Сборка расписания.

    python3 -m scraper.build

Источники: ФФККР (все российские старты уровня МС/КМС), ISU (Гран-при, юниорский
Гран-при, челленджеры, чемпионаты), Golden Skate (прочие международные).
Международный сегмент попадает в календарь, только если в нём есть наши
(RUS или AIN2 — нейтральные россияне; AIN1 — белорусы, не наши).

Результат: site/data/events.json, site/calendar.ics, data/names.json.
Если источник не ответил, его события берутся из прошлого успешного запуска.

Когда сегмент прошёл, у события есть podium — первая тройка протокола
[{place, name, nation, points}] (nation у российских стартов — регион: МОС, СПБ…),
у наших — place. У последнего сегмента вида после его окончания — total, первая
тройка турнира. photos — {«Имя Фамилия»: фото} для имён из ours, podium,
total и watchlist (пары — по людям): сборная ФФККР, иначе портрет ISU. Фото —
миниатюра photos/xxx.jpg относительно сайта, без Pillow — адрес оригинала.
"""
import datetime as dt
import json
import math
import os
import re
import sys
import traceback

from . import fsr, goldenskate, ics, isu, net
from . import photos as ph
from . import names as nm
from . import swisstiming as st

MSK = dt.timezone(dt.timedelta(hours=3))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
OUT_JSON = os.path.join(SITE, "data", "events.json")
OUT_ICS = os.path.join(SITE, "calendar.ics")
NAMES = os.path.join(ROOT, "data", "names.json")
PUBLIC_URL = os.environ.get("STARTY_URL", "")

with open(os.path.join(os.path.dirname(__file__), "config.json"), encoding="utf-8") as f:
    CFG = json.load(f)

SEG_EN = {"short program": "КП", "free skating": "ПП", "free program": "ПП",
          "rhythm dance": "РТ", "short dance": "РТ", "free dance": "ПТ"}
SEG_ORDER = {"КП": 0, "РТ": 0, "ПП": 1, "ПТ": 1}

COUNTRIES = {
    "AND": "Andorra", "ARG": "Argentina", "ARM": "Armenia", "AUS": "Australia", "AUT": "Austria",
    "AZE": "Azerbaijan", "BEL": "Belgium", "BIH": "Bosnia and Herzegovina", "BLR": "Belarus",
    "BRA": "Brazil", "BUL": "Bulgaria", "CAN": "Canada", "CHI": "Chile", "CHN": "China",
    "CRO": "Croatia", "CYP": "Cyprus", "CZE": "Czechia", "DEN": "Denmark", "ESP": "Spain",
    "EST": "Estonia", "FIN": "Finland", "FRA": "France", "GBR": "Great Britain", "GEO": "Georgia",
    "GER": "Germany", "GRE": "Greece", "HKG": "Hong Kong", "HUN": "Hungary", "INA": "Indonesia",
    "IND": "India", "IRL": "Ireland", "ISL": "Iceland", "ISR": "Israel", "ITA": "Italy",
    "JPN": "Japan", "KAZ": "Kazakhstan", "KGZ": "Kyrgyzstan", "KOR": "South Korea",
    "LAT": "Latvia", "LTU": "Lithuania", "LUX": "Luxembourg", "MAS": "Malaysia", "MDA": "Moldova",
    "MEX": "Mexico", "MGL": "Mongolia", "MKD": "North Macedonia", "MON": "Monaco",
    "NED": "Netherlands", "NOR": "Norway", "NZL": "New Zealand", "PHI": "Philippines",
    "POL": "Poland", "POR": "Portugal", "ROU": "Romania", "RSA": "South Africa", "SGP": "Singapore",
    "SLO": "Slovenia", "SRB": "Serbia", "SUI": "Switzerland", "SVK": "Slovakia", "SWE": "Sweden",
    "THA": "Thailand", "TPE": "Chinese Taipei", "TUR": "Türkiye", "UAE": "United Arab Emirates",
    "UKR": "Ukraine", "USA": "USA", "UZB": "Uzbekistan",
}


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- имена и подписи

def kind_label(kind, level, mixed):
    if kind == "women":
        return "девушки" if level == "junior" else "женщины"
    if kind == "men":
        return "юноши" if level == "junior" else "мужчины"
    if kind == "pairs":
        return "юниорские пары" if level == "junior" and mixed else "пары"
    return "юниорские танцы" if level == "junior" and mixed else "танцы"


def cat_en(name):
    n = name.lower()
    level = "junior" if "junior" in n else "senior"
    if "dance" in n:
        return "dance", level
    if "pair" in n:
        return "pairs", level
    if re.search(r"women|ladies|girls", n):
        return "women", level
    if re.search(r"\bmen\b|boys", n):
        return "men", level
    return None, level


def seg_code(name):
    c = SEG_EN.get(name.strip().lower())
    return c or fsr.segment_of(name)


def yo(s):
    """«лед» → «лёд» в названиях турниров (на сайте ФФККР пишут без ё)."""
    return re.sub(r"\b([Лл])ед\b", lambda m: m.group(1) + "ёд", s)


def clean_ru_name(inner):
    s = inner
    s = re.sub(r"-20\d\d\b", "", s)
    s = re.sub(r"\b(ЗТ СССР|ЗТР|ЗРФК|ЗМС)\s+", "", s)
    s = re.sub(r"(первого русского |двукратного |двухкратного )?[Оо]лимпийского чемпиона\s+", "", s)
    s = re.sub(r"\b(?:[А-ЯЁ]\.\s?){1,2}(?=[А-ЯЁ][а-яё])", "", s)  # инициалы
    m = re.match(r"^(.+?)\s+памяти\s+.+$", s)
    if m and not s.lower().startswith("памяти"):
        s = m.group(1)
    return yo(re.sub(r"\s+", " ", s).strip())


def fsr_title(title, is_jgp):
    t = title.replace("\xa0", " ").strip()
    if re.match(r"^Чемпионат России\s+20\d\d$", t):
        return "Чемпионат России"
    m = re.search(r'["«“](.+?)["»”]\s*(среди юниоров)?$', t)
    inner = m.group(1) if m else None
    if t.startswith("Финал Кубка России") and inner and "Гран" in inner:
        return "Финал Гран-при России"
    if inner and re.match(r"^Гран[ -]При России\s*[–-]\s*", inner, re.I):
        rest = re.sub(r"^Гран[ -]При России\s*[–-]\s*", "", inner, flags=re.I)
        return f"Гран-при России «{clean_ru_name(rest)}»"
    if t.startswith("Командный турнир") and inner:
        return inner + (" среди юниоров" if "юниор" in t else "")
    if t.startswith("Контрольные прокаты"):
        return "Контрольные прокаты сборной"
    if inner and t.startswith("Всероссийские соревнования"):
        name = clean_ru_name(inner)
        return f"ЮГП России «{name}»" if is_jgp else name
    return yo(re.sub(r"\s+20\d\d$", "", t))


def clean_city(city):
    c = re.sub(r'^(г\.|с\.|пос\.|п\.)\s*', "", city.strip())
    c = re.sub(r'^ФТ\s*["«]?Сириус["»]?', "Сириус", c)
    return c.strip(' ,"')


def ru_venue(city, venue):
    city = clean_city(city)
    v = (venue or "").strip().strip(",")
    if not v or re.search(r"обл\.|област|край|Республик", v):
        return city
    v = re.sub(r'"([^"]+)"', r"«\1»", v)
    v = v.replace("“", "«").replace("”", "»")
    m = re.match(r"^[А-ЯЁ]{2,5}\s+«([^»]*(?:Арена|Arena)[^»]*)»$", v)
    if m:
        v = m.group(1)
    return f"{v}, {city}" if city else v


def intl_venue(city, nation_code, country_name=""):
    # табло иногда отдаёт город с многоточием («Almaty...») — оно не часть названия
    c = city.split(",")[0].strip().rstrip(".…").strip()
    if c.isupper():
        c = c.title()
    country = COUNTRIES.get(nation_code, country_name or nation_code)
    return f"{c}, {country}" if c else country


def tz_for(city):
    c = clean_city(city)
    for k, v in CFG["ru_tz"].items():
        if k.lower() in c.lower():
            return dt.timezone(dt.timedelta(hours=v))
    log(f"  ! нет часового пояса для «{city}», беру московский")
    return MSK


def slugify(s):
    tr = nm.ru_to_lat(s.lower())
    return re.sub(r"[^a-z0-9]+", "-", tr).strip("-")[:60]


# ---------------------------------------------------------------- длительность

SLOT = {"КП": 6.6, "РТ": 6.4, "ПП": 7.6, "ПТ": 7.4}


def estimate_end(start, seg, kind, n, last_start=None):
    slot = SLOT[seg] + (0.5 if kind == "pairs" else 0)
    if last_start is not None:
        end = last_start + dt.timedelta(minutes=slot)
        return end.replace(second=0, microsecond=0) + dt.timedelta(minutes=1)
    if not n:
        mins = {"КП": 120, "РТ": 110, "ПП": 150, "ПТ": 130}[seg]
    else:
        per = 5 if kind == "dance" else 6
        groups = math.ceil(n / per)
        mins = n * slot + groups * 6.5 + ((groups - 1) // 2) * 15
    mins = max(30, int(round(mins / 5.0)) * 5)
    return start + dt.timedelta(minutes=mins)


# ---------------------------------------------------------------- событие

def make_event(*, tid, tournament, kind, level, seg, mixed, start, end, venue, intl,
               broadcast, ours, athletes, src, podium=None, total=None):
    label = kind_label(kind, level, mixed)
    start = start.astimezone(MSK)
    end = end.astimezone(MSK)
    eid = f"{tid}:{kind}-{level}-{seg}"
    eid = re.sub(r"[^A-Za-z0-9:_\-]", "", nm.ru_to_lat(eid))
    ev = {
        "id": eid, "tid": tid, "tournament": tournament, "kind": kind, "level": level,
        "seg": seg, "title": f"{tournament} — {label} {seg}",
        "start": start.isoformat(), "end": end.isoformat(),
        "venue": venue, "intl": intl, "broadcast": broadcast,
        "ours": ours, "athletes": sorted(set(athletes)), "src": src,
    }
    if podium:
        ev["podium"] = podium
    if total:
        ev["total"] = total
    ev["desc"] = describe(ev)
    return ev


def describe(ev):
    lines = []
    for key, head in (("podium", "Итог:"), ("total", "Итог турнира:")):
        if ev.get(key):
            lines.append(head)
            for r in ev[key]:
                lines.append(f"{r['place']}. {r['name']} — {r['points']}")
            lines.append("")
    if ev["ours"]:
        lines.append("Наши:")
        for o in ev["ours"]:
            if o.get("time"):
                lines.append(f"• {o['name']} — {o['time']}")
            elif o.get("no"):
                w = f" (разминка {o['warmup']})" if o.get("warmup") else ""
                lines.append(f"• {o['name']} — {o['no']}-й{w}")
            else:
                lines.append(f"• {o['name']}")
        lines.append("")
    lines.append("Начало: " + dt.datetime.fromisoformat(ev["start"]).strftime("%H:%M") + " МСК")
    if ev["broadcast"]:
        lines.append("Трансляция: " + " / ".join(ev["broadcast"]))
    return "\n".join(lines)


def top3(rows, names):
    """Первые три места протокола; имена — как везде в приложении."""
    return [{"place": r["place"], "name": names.to_ru(r["name"]), "nation": r["nation"],
             "points": r["points"]}
            for r in sorted(rows, key=lambda r: r["place"])[:3]]


def sort_ours(ours):
    return sorted(ours, key=lambda o: (o.get("time") or "99", o.get("no") or 999, o["name"]))


def broadcast_for(name, base=None):
    out = list(base or [])
    for r in CFG["broadcast_rules"]:
        if re.search(r["match"], name):
            for b in r["broadcast"]:
                if b not in out:
                    out.append(b)
    for k, v in CFG.get("broadcast_overrides", {}).items():
        if k == name:
            out = list(v)
    return out


# ---------------------------------------------------------------- Swiss Timing → события

def times_to_msk(seg_start, local_times, offset_min):
    """{no: (h, m)} местного времени → {no: datetime MSK}; переход через полночь учтён."""
    tz = dt.timezone(dt.timedelta(minutes=offset_min))
    base = seg_start.astimezone(tz)
    out = {}
    for no, (h, m) in local_times.items():
        t = base.replace(hour=h, minute=m, second=0, microsecond=0)
        if t < base - dt.timedelta(hours=2):
            t += dt.timedelta(days=1)
        out[no] = t.astimezone(MSK)
    return out


def from_swisstiming(idx, *, tid, tournament, venue, intl, broadcast, names, ours_rule,
                     extra_starts=None):
    """Сегменты из табло. ours_rule(name, nation) → bool. extra_starts — запасные
    времена начала {(kind, level, seg): datetime}, если в табло нет расписания."""
    cats = []
    for c in idx["categories"]:
        if not intl and fsr.low_level(c["name"]):
            continue
        kind, level = (cat_en(c["name"]) if intl else fsr.classify(c["name"]))
        if kind is None:
            continue
        if level is None:
            level = "senior"
        cats.append((c, kind, level))
    levels = {lv for _, _, lv in cats}
    mixed = len(levels) > 1
    events = []
    now = dt.datetime.now(dt.timezone.utc)
    for c, kind, level in cats:
        try:
            entries = st.parse_entries(c["entries_url"])
        except net.FetchError:
            entries = []
        for p in entries:
            if nm.is_cyr(p["name"]):
                for one in p["name"].split(" / "):
                    names.add(one)
        codes = [seg_code(s["name"]) for s in c["segments"]]
        last_seg = max((SEG_ORDER[x] for x in codes if x), default=None)
        cat_events, cat_total, cat_rows = [], None, []
        for s, seg in zip(c["segments"], codes):
            if not seg:
                continue
            start = s.get("start") or (extra_starts or {}).get((kind, level, seg))
            if not start:
                continue
            try:
                seg_page = net.fetch(s["url"])
            except net.FetchError:
                seg_page = None
            order = st.parse_starting_order(s["url"], seg_page) if seg_page else []
            # Сегмент прошёл, только когда страница — протокол, время старта позади и,
            # если табло вообще выкладывает судейские оценки, они у сегмента уже есть
            # (до конца проката протокол может быть неполным).
            try:
                results = st.parse_segment_results(seg_page) if seg_page else None
            except Exception as e:  # итог необязателен — расписание важнее
                log("  ! протокол сегмента:", s["url"], e)
                results = None
            done = bool(results) and start.astimezone(dt.timezone.utc) <= now and \
                (s.get("final") or not idx.get("final_marks"))
            place = {r["name"]: r["place"] for r in results} if done else {}
            people = order if order else [dict(p, no=None, warmup=None) for p in entries]
            for p in people:
                if nm.is_cyr(p["name"]):
                    for one in p["name"].split(" / "):
                        names.add(one)
            local, warm = {}, {}
            if s.get("times_pdf"):
                try:
                    local, warm = st.parse_times_pdf(s["times_pdf"])
                except (net.FetchError, OSError) as e:
                    log("  ! PDF времени:", e)
            msk_times = times_to_msk(start, local, idx["offset"]) if local and idx["offset"] is not None else {}
            ours = []
            for p in people:
                if not ours_rule(p["name"], p.get("nation", "")):
                    continue
                o = {"name": names.to_ru(p["name"])}
                no = p.get("no")
                if no and no in msk_times and "rank" not in p:
                    o["time"] = msk_times[no].strftime("%H:%M")
                if no:
                    # после проката табло показывает итог, но стартовый номер в нём остаётся
                    o["no"] = no
                    o["warmup"] = p.get("warmup") or warm.get(no)
                if place.get(p["name"]):
                    o["place"] = place[p["name"]]
                ours.append(o)
            if done and SEG_ORDER[seg] == last_seg and c.get("results_url"):
                try:
                    cr = st.parse_category_results(c["results_url"])
                    if cr["complete"]:
                        cat_total, cat_rows = top3(cr["rows"], names), cr["rows"]
                except Exception as e:
                    log("  ! итог вида:", c["results_url"], e)
            if intl and not ours:
                continue
            podium = top3(results, names) if done else None
            total = cat_total if SEG_ORDER[seg] == last_seg else None
            last = max(msk_times.values()) if msk_times else None
            end = estimate_end(start, seg, kind, len(people), last)
            athletes = [names.to_ru(p["name"]) for p in people] if not intl else [o["name"] for o in ours]
            ev = make_event(
                tid=tid, tournament=tournament, kind=kind, level=level, seg=seg, mixed=mixed,
                start=start, end=end, venue=venue, intl=intl, broadcast=broadcast,
                ours=sort_ours(ours), athletes=athletes, src=idx["url"],
                podium=podium, total=total)
            events.append(ev)
            cat_events.append(ev)
        if cat_total and cat_events:
            # наши не прошли в последний сегмент — итог вида у их последнего старта
            ev = cat_events[-1]
            ev["total"] = cat_total
            # место наших в итоге вида
            final = {nm.key(names.to_ru(r["name"])): r["place"] for r in cat_rows}
            for o in ev["ours"]:
                if final.get(nm.key(o["name"])):
                    o["final"] = final[nm.key(o["name"])]
            ev["desc"] = describe(ev)
    return events


# ---------------------------------------------------------------- ФФККР

def watch_rule(watch_keys):
    def rule(name, nation):
        return nm.key(name) in watch_keys
    return rule


def do_fsr(names, report, failed, upcoming, photos):
    season_start = dt.date.fromisoformat(CFG["season_start"])
    cal = fsr.calendar()
    try:
        team = fsr.team()
        photos["team_ok"] = True
    except net.FetchError as e:
        log("  ! сборная:", e)
        team = []
    for sur, giv, img in team:
        names.add_fsr(sur, giv)
        if img:
            photos["raw"].append((f"{giv} {sur}", img, 0))
    page_urls = {c["page"] for c in cal if c["page"]}
    try:
        page_urls |= set(fsr.recent_pages())
    except net.FetchError as e:
        log("  ! раздел соревнований:", e)
    pages = []
    for u in sorted(page_urls):
        try:
            pages.append(fsr.tournament(u))
        except net.FetchError as e:
            log("  ! страница турнира:", e)

    gp_names = set()
    for c in cal:
        m = re.search(r"Гран При России\s*[–-]\s*([^\"»]+)", c["title"])
        if m:
            gp_names.add(clean_ru_name(m.group(1)).lower())

    watch_keys = {nm.key(w) for w in CFG["watchlist"]}
    rule = watch_rule(watch_keys)
    events = []
    today = dt.datetime.now(MSK).date()
    for c in cal:
        if c["end"] < season_start:
            continue
        if "назначени" in c["city"].lower():
            continue
        text = c["title"] + " " + c["levels"]
        if fsr.low_level(text) and not re.search(r"\bК?МС\b", c["levels"]):
            continue
        page = None
        for p in pages:
            if c["page"] and p["url"] == c["page"]:
                page = p
                break
        if page is None:
            for p in pages:
                if p["start"] == c["start"] and p["end"] == c["end"]:
                    q1 = re.search(r'"([^"]+)"', c["title"])
                    if not q1 or q1.group(1).split()[0].lower() in p["title"].lower():
                        page = p
                        break
        links = " ".join(filter(None, [page and page["results"], page and page["schedule_pdf"]]))
        inner = re.search(r'"([^"]+)"', c["title"])
        is_jgp = bool(re.search(r"\d+etap\d*_jun", links)) or (
            bool(inner) and "КМС" in c["levels"] and not re.search(r"\bМС\b", c["levels"].replace("КМС", ""))
            and clean_ru_name(inner.group(1)).lower() in gp_names)
        name = fsr_title(c["title"], is_jgp)
        tid = "fsr:" + (page["url"].rsplit("/", 1)[-1] if page else slugify(name + "-" + c["start"].isoformat()))
        place_city, place_venue = c["city"], c["venue"]
        if page and page["place"]:
            parts = page["place"].split(",", 1)
            place_city = parts[0]
            place_venue = parts[1] if len(parts) > 1 else ""
        venue = ru_venue(place_city, place_venue)
        tz = tz_for(place_city or c["city"])
        bcast = broadcast_for(name, page["broadcast"] if page else [])
        got = []
        try:
            pdf_starts = {}
            pdf_rows = []
            if page and page["schedule_pdf"]:
                try:
                    pdf_rows = fsr.schedule_pdf(page["schedule_pdf"], c["start"].year if c["start"].month >= 7 else c["start"].year - 1)
                except net.FetchError as e:
                    log("  ! PDF расписания:", e)
                for d, (h, m), (h2, m2), what in pdf_rows:
                    if fsr.low_level(what):
                        continue
                    kind, level = fsr.classify(what)
                    seg = fsr.segment_of(what)
                    if not kind or not seg:
                        continue
                    level = level or "senior"
                    st_ = dt.datetime(d.year, d.month, d.day, h, m, tzinfo=tz)
                    en_ = dt.datetime(d.year, d.month, d.day, h2, m2, tzinfo=tz)
                    if en_ <= st_:
                        en_ += dt.timedelta(days=1)
                    pdf_starts[(kind, level, seg)] = (st_, en_)
            if page and page["results"]:
                try:
                    idx = st.parse_index(page["results"])
                except net.FetchError as e:
                    log("  ! табло:", e)
                    idx = None
                if idx and idx["categories"]:
                    got = from_swisstiming(
                        idx, tid=tid, tournament=name, venue=venue, intl=False, broadcast=bcast,
                        names=names, ours_rule=rule,
                        extra_starts={k: v[0] for k, v in pdf_starts.items()})
            if not got and pdf_starts:
                levels = {k[1] for k in pdf_starts}
                for (kind, level, seg), (s0, e0) in pdf_starts.items():
                    got.append(make_event(
                        tid=tid, tournament=name, kind=kind, level=level, seg=seg,
                        mixed=len(levels) > 1, start=s0, end=e0, venue=venue, intl=False,
                        broadcast=bcast, ours=[], athletes=[], src=page["schedule_pdf"]))
        except Exception as e:  # один турнир не должен ронять весь сбор
            log(f"  ! {name}: {e}")
            traceback.print_exc()
            failed.add(tid)
            report["errors"].append(f"{name}: {e}")
            continue
        if got:
            events += got
            log(f"  ФФККР {name}: {len(got)}")
        elif c["end"] >= today:
            upcoming.append({"tid": tid, "name": name, "start": c["start"].isoformat(),
                             "end": c["end"].isoformat(), "venue": venue, "intl": False})
    return events


# ---------------------------------------------------------------- международные

def ours_rule_intl(name, nation):
    return nation in CFG["ours_codes"]


def results_index(url):
    if not url:
        return None
    u = url.split("#")[0]
    if u.endswith("/"):
        u += "index.htm"
    if not re.search(r"\.html?$", u):
        return None
    return u


def do_isu(names, report, failed, upcoming, photos):
    events = []
    now = dt.datetime.now(dt.timezone.utc)
    for e in isu.events():
        try:
            fr = dt.datetime.fromisoformat(e["from"].replace("Z", "+00:00"))
            to = dt.datetime.fromisoformat(e["to"].replace("Z", "+00:00"))
        except (TypeError, ValueError):
            continue
        if to < now - dt.timedelta(days=30) or fr > now + dt.timedelta(days=75):
            continue
        name = isu.short_name(e)
        tid = "isu:" + e["slug"]
        venue = intl_venue(e["city"], e["country"], e["country_name"])
        bcast = broadcast_for(name)
        try:
            got = []
            idx_url = results_index(e["results_url"])
            idx = None
            if idx_url:
                try:
                    idx = st.parse_index(idx_url)
                except net.FetchError as ex:
                    log("  ! табло ISU:", ex)
            sched = []
            try:
                sched = isu.schedule(e["slug"])
            except (net.FetchError, ValueError) as ex:
                log("  ! расписание ISU:", ex)
            extra = {}
            for when, cat, segname in sched:
                k, lv = cat_en(cat)
                sc = seg_code(segname)
                if k and sc:
                    extra[(k, lv, sc)] = when
            if idx and idx["categories"]:
                if idx["city"]:
                    venue = intl_venue(idx["city"], idx["nation"] or e["country"], e["country_name"])
                got = from_swisstiming(idx, tid=tid, tournament=name, venue=venue, intl=True,
                                       broadcast=bcast, names=names, ours_rule=ours_rule_intl,
                                       extra_starts=extra)
                if got:
                    try:
                        for full, url in isu.portraits(e["slug"], e["event_id"]).items():
                            photos["raw"].append((full, url, 1))
                    except Exception as ex:  # фото не повод терять турнир
                        log("  ! портреты ISU:", ex)
            else:
                got, ours_all = isu_api_events(e, tid, name, venue, bcast, names, sched, photos)
                if not got and ours_all and to > now:
                    upcoming.append({
                        "tid": tid, "name": name, "intl": True, "venue": venue,
                        "start": fr.astimezone(MSK).date().isoformat(),
                        "end": (to - dt.timedelta(hours=12)).astimezone(MSK).date().isoformat(),
                        "ours": sorted(set(ours_all)), "broadcast": bcast})
        except Exception as ex:
            log(f"  ! {name}: {ex}")
            traceback.print_exc()
            failed.add(tid)
            report["errors"].append(f"{name}: {ex}")
            continue
        log(f"  ISU {name}: {len(got)}")
        events += got
    return events


def isu_api_events(e, tid, name, venue, bcast, names, sched, photos):
    cats = isu.categories(e["slug"], e["event_id"])
    levels = {cat_en(c["name"])[1] for c in cats}
    out = []
    ours_all = []
    now = dt.datetime.now(dt.timezone.utc)
    for c in cats:
        kind, level = cat_en(c["name"])
        if not kind:
            continue
        ents = isu.entries(e["event_id"], c)
        ours = [{"name": names.to_ru(x["name"])} for x in ents if x["code"] in CFG["ours_codes"]]
        if not ours:
            continue
        for x in ents:
            for full, url in x.get("photos", {}).items():
                photos["raw"].append((full, url, 1))
        ours_all += [o["name"] for o in ours]
        segs = [(when, seg_code(segname)) for when, cat, segname in sched
                if cat_en(cat) == (kind, level) and seg_code(segname)]
        last_seg = max((SEG_ORDER[sc] for _, sc in segs), default=None)
        # итог вида из заявки ISU (final_rank/final_points) — только когда последний
        # сегмент позади и места проставлены с первого
        ranked = sorted((x for x in ents if x.get("rank") and x.get("points")), key=lambda x: x["rank"])
        for when, seg in segs:
            end = estimate_end(when, seg, kind, len(ents))
            total = None
            if SEG_ORDER[seg] == last_seg and end < now and ranked and ranked[0]["rank"] == 1:
                total = [{"place": x["rank"], "name": names.to_ru(x["name"]), "nation": x["code"],
                          "points": x["points"]} for x in ranked[:3]]
            out.append(make_event(
                tid=tid, tournament=name, kind=kind, level=level, seg=seg, mixed=len(levels) > 1,
                start=when, end=end, venue=venue, intl=True, broadcast=bcast,
                ours=sorted(ours, key=lambda o: o["name"]), athletes=[o["name"] for o in ours],
                src=f"https://isu-skating.com/en/figure-skating/events/eventdetail/{e['slug']}/",
                total=total))
    return out, ours_all


def do_goldenskate(names, report, failed, isu_ok):
    """Прочие международные турниры. Если ISU не ответил — и турниры ISU тоже
    (по ссылкам на их табло из календаря Golden Skate)."""
    today = dt.date.today()
    out = []
    for g in goldenskate.events(today - dt.timedelta(days=20), today + dt.timedelta(days=60),
                                include_isu=not isu_ok):
        url = results_index(g["results_url"])
        if not url:
            continue
        name = goldenskate.short_name(g["title"])
        tid = "gs:" + slugify(name)
        try:
            idx = st.parse_index(url)
            if not idx["categories"]:
                continue
            venue = intl_venue(idx["city"] or g["city"], idx["nation"], g["country"])
            got = from_swisstiming(idx, tid=tid, tournament=name, venue=venue, intl=True,
                                   broadcast=broadcast_for(name), names=names,
                                   ours_rule=ours_rule_intl)
        except Exception as ex:
            log(f"  ! {name}: {ex}")
            failed.add(tid)
            continue
        if got:
            log(f"  GS {name}: {len(got)}")
        out += got
    return out


# ---------------------------------------------------------------- main

def collect_photos(events, upcoming, names, photos, prev_photos):
    """{«Имя Фамилия» как в ours/podium/total/watchlist: адрес фото}. Пары — по людям.
    Источники: сборная ФФККР, потом портреты ISU. Адрес берётся, только если он
    действительно отдаёт картинку."""
    want = []

    def add(n):
        for one in n.split(" / "):
            one = one.strip()
            if one and one not in want:
                want.append(one)

    for e in events:
        for o in e["ours"]:
            add(o["name"])
        for r in (e.get("podium") or []) + (e.get("total") or []):
            add(r["name"])
    for w in CFG["watchlist"]:
        add(w)
    for u in upcoming:
        for n in u.get("ours") or []:
            add(n)

    src = {}
    for raw, url, _ in sorted(photos["raw"], key=lambda x: x[2]):
        src.setdefault(nm.key(names.to_ru(raw)), url)
    checked = {}
    out = {}
    for n in want:
        url = src.get(nm.key(names.to_ru(n)))
        if not url:
            # источник фото в этот раз не ответил — прошлое фото того же человека остаётся
            old = prev_photos.get(n)
            if old and (old.startswith("http") or os.path.exists(os.path.join(SITE, old))):
                out[n] = old
            continue
        if ph.have(SITE, url):
            out[n] = ph.rel_path(url)
            continue
        if url not in checked:
            checked[url] = net.is_image(url)
        ok = checked[url]
        if ok:
            out[n] = ph.make(SITE, url) or url
        elif ok is None and prev_photos.get(n) == url:
            out[n] = url
    bad = [u for u, ok in checked.items() if not ok]
    local = sum(1 for v in out.values() if not v.startswith("http"))
    gone = ph.prune(SITE, set(out.values()))
    log(f"  фото: {len(out)} из {len(want)}, миниатюр {local}" + (f"; не открылись: {len(bad)}" if bad else "")
        + (f"; убрано старых: {gone}" if gone else ""))
    return out


def load_prev():
    try:
        with open(OUT_JSON, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def main():
    now = dt.datetime.now(MSK).replace(microsecond=0)
    prev = load_prev()
    names = nm.Names(NAMES, CFG.get("aliases"))
    report = {"errors": [], "sources": {}}
    failed = set()
    upcoming = []
    events = []
    photos = {"raw": [], "team_ok": False}  # (имя как в источнике, адрес, приоритет)
    for label, fn in (("ФФККР", lambda: do_fsr(names, report, failed, upcoming, photos)),
                      ("ISU", lambda: do_isu(names, report, failed, upcoming, photos))):
        try:
            got = fn()
            events += got
            report["sources"][label] = "ok"
        except Exception as e:
            log(f"!! источник {label} недоступен: {e}")
            traceback.print_exc()
            report["sources"][label] = "fail"
            report["errors"].append(f"{label}: {e}")
            prefix = {"ФФККР": "fsr:", "ISU": "isu:"}[label]
            failed.add(prefix + "*")
    try:
        events += do_goldenskate(names, report, failed, report["sources"].get("ISU") == "ok")
        report["sources"]["Golden Skate"] = "ok"
    except Exception as e:
        log(f"!! Golden Skate недоступен: {e}")
        report["sources"]["Golden Skate"] = "fail"
        failed.add("gs:*")

    # После старта табло показывает результаты вместо стартового листа — время выхода
    # и номера наших берём из прошлого сбора, пока он их помнит. Так же итоги
    # прошедших сегментов: если протокол сейчас не открылся, остаётся прошлый.
    prev_by_id = {e["id"]: e for e in prev.get("events", [])}
    for e in events:
        old = prev_by_id.get(e["id"])
        if not old:
            continue
        was = {o["name"]: o for o in old.get("ours", [])}
        changed = False
        for o in e["ours"]:
            p = was.get(o["name"])
            if not p or (o.get("no") and p.get("no") and o["no"] != p["no"]):
                continue
            for k in ("time", "no", "warmup", "place", "final"):
                if p.get(k) and not o.get(k):
                    o[k] = p[k]
                    changed = True
        for k in ("podium", "total"):
            if old.get(k) and not e.get(k):
                e[k] = old[k]
                changed = True
        if changed:
            e["ours"] = sort_ours(e["ours"])
            e["desc"] = describe(e)

    # Прошлый успешный сбор: всё, что не удалось получить сейчас, и прошедшие старты
    have = {e["id"] for e in events}
    kept = 0
    season_start = CFG["season_start"]
    for e in prev.get("events", []):
        if e["id"] in have or e["start"] < season_start:
            continue
        pref = e["tid"].split(":")[0] + ":*"
        past = dt.datetime.fromisoformat(e["end"]) < now
        if e["tid"] in failed or pref in failed or past:
            events.append(e)
            kept += 1
    if kept:
        log(f"  из прошлого сбора: {kept}")

    # повтор одного и того же сегмента (два источника или два id) — оставляем более
    # подробный; один сегмент = то же время, тот же вид и сегмент, тот же город
    prio = {"fsr": 0, "isu": 1, "gs": 2}
    best = {}
    for e in events:
        k = (e["start"], e["kind"], e["level"], e["seg"], e["venue"].split(",")[0].strip().lower())
        cur = best.get(k)
        score = (-prio.get(e["tid"].split(":")[0], 9), len(e["ours"]), len(json.dumps(e, ensure_ascii=False)))
        if cur is None or score > cur[0]:
            best[k] = (score, e)
    events = sorted((e for _, e in best.values()), key=lambda e: (e["start"], e["title"]))

    have_tids = {e["tid"] for e in events}
    upcoming = [u for u in upcoming if u["tid"] not in have_tids]
    if any(s == "fail" for s in report["sources"].values()) and prev.get("upcoming"):
        for u in prev["upcoming"]:
            if u["tid"] not in have_tids and u["tid"] not in {x["tid"] for x in upcoming} \
                    and u["end"] >= now.date().isoformat():
                upcoming.append(u)
    upcoming.sort(key=lambda u: u["start"])

    all_ok = all(s == "ok" for s in report["sources"].values()) and not report["errors"]
    data = {
        "generated": now.isoformat(),
        "checked": now.isoformat(),
        "complete": all_ok,
        "sources": report["sources"],
        "events": events,
        "upcoming": upcoming,
        "watchlist": CFG["watchlist"],
        "photos": collect_photos(events, upcoming, names, photos, prev.get("photos") or {}),
    }
    # Если сбор вернул заметно меньше будущих стартов, чем было, — это поломка
    # источника, а не отмена турниров. Тогда оставляем прошлые данные.
    fut_new = sum(1 for e in events if e["start"] >= now.isoformat())
    fut_old = sum(1 for e in prev.get("events", []) if e["start"] >= now.isoformat())
    if fut_old >= 6 and fut_new < fut_old * 0.5:
        log(f"!! будущих стартов {fut_new} против {fut_old} в прошлый раз — данные не обновляю")
        prev["checked"] = now.isoformat()
        prev["complete"] = False
        data = prev
    else:
        names.save()

    os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    gen = dt.datetime.fromisoformat(data["generated"])
    with open(OUT_ICS, "w", encoding="utf-8", newline="") as f:
        f.write(ics.build(data["events"], gen, PUBLIC_URL))
    # по файлу на старт — кнопка «В календарь» с напоминанием за 15 минут
    edir = os.path.join(SITE, "e")
    os.makedirs(edir, exist_ok=True)
    keep = set()
    for e in data["events"]:
        fn = e["id"].replace(":", "_") + ".ics"
        keep.add(fn)
        with open(os.path.join(edir, fn), "w", encoding="utf-8", newline="") as f:
            f.write(ics.single(e, gen, PUBLIC_URL))
    for fn in os.listdir(edir):
        if fn.endswith(".ics") and fn not in keep:
            os.unlink(os.path.join(edir, fn))
    log(f"готово: {len(data['events'])} стартов, {len(data['upcoming'])} турниров без расписания;"
        f" источники: {report['sources']}; ошибок: {len(report['errors'])}")
    for e in report["errors"]:
        log("   -", e)
    return 0


if __name__ == "__main__":
    sys.exit(main())
