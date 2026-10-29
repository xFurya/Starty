"""Сборка расписания.

    python3 -m scraper.build

Источники: ФФККР (все российские старты уровня МС/КМС), ISU (Гран-при, юниорский
Гран-при, челленджеры, чемпионаты), Golden Skate (прочие международные). Региональные
(ФФКМ — Москва, Самарская область) — старты с tier="regional" и region; в calendar.ics не попадают.
Международный сегмент попадает в календарь, только если в нём есть россияне или белорусы
(RUS или AIN2 — россияне, нейтральные россияне; BLR или AIN1 — белорусы).

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
from . import keep as kp
from . import protocols as P
from . import photos as ph
from . import names as nm
from . import people as pp
from . import regional as rg
from . import results as rs
from . import swisstiming as st

MSK = dt.timezone(dt.timedelta(hours=3))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
OUT_JSON = os.path.join(SITE, "data", "events.json")
OUT_ICS = os.path.join(SITE, "calendar.ics")
# файлы протоколов турниров: только на сайте (gh-pages), в main не коммитятся (.gitignore)
PROTO_DIR = os.path.join(SITE, "data", "protocols")
NAMES = os.path.join(ROOT, "data", "names.json")
ROSTER = os.path.join(ROOT, "data", "roster.json")


def load_roster():
    """Все спортсмены, которых сборщик когда-либо видел, — для фильтра по именам."""
    try:
        with open(ROSTER, encoding="utf-8") as f:
            return {s for s in json.load(f) if s}
    except Exception:
        return set()


def save_roster(roster):
    with open(ROSTER, "w", encoding="utf-8") as f:
        json.dump(sorted(roster), f, ensure_ascii=False, indent=0)
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
               broadcast, ours, athletes, src, podium=None, total=None, watch=None):
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
    w = watch_for(tournament, watch, (kind, level, seg, start.date()))
    if w:
        ev["watch"] = w
        for x in w:
            if x["name"] not in ev["broadcast"]:
                ev["broadcast"] = ev["broadcast"] + [x["name"]]
    if podium:
        ev["podium"] = podium
    if total:
        ev["total"] = total
    ev["desc"] = describe(ev)
    return ev


def describe(ev):
    lines = []
    for key, head in (("podium", "Итог:"), ("total", "Итог турнира:")):
        if key == "podium" and ev.get("provisional"):
            head = "Промежуточные итоги:"
        if ev.get(key):
            lines.append(head)
            for r in ev[key]:
                lines.append(f"{r['place']}. {r['name']} — {r['points']}")
            lines.append("")
    if ev.get("facts"):
        lines.append("Примечательное:")
        for f in ev["facts"]:
            lines.append(f"• {f['who']} — {f['text']}" if f.get("who") else f"• {f['text']}")
        lines.append("")
    if ev["ours"]:
        lines.append("Россияне:")
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


_YT = {}  # адрес RSS → [(видео, название, дата по Москве)]


def yt_streams(rss):
    """Эфиры канала по его RSS (последние ~15 записей): [(видео, название, дата по Москве)].
    Нет сети — пусто (ссылка остаётся общей /live, а прежняя конкретная — из прошлого сбора, см. keep.py)."""
    if rss not in _YT:
        out = []
        try:
            xml = net.fetch(rss)
            for e in re.findall(r"(?s)<entry>(.*?)</entry>", xml):
                v = re.search(r"<yt:videoId>([\w-]{11})<", e)
                t = re.search(r"<title>(.*?)</title>", e)
                d = re.search(r"<published>(.*?)</published>", e)
                if v and t and d:
                    when = dt.datetime.fromisoformat(d.group(1)).astimezone(MSK).date()
                    title = t.group(1).replace("&amp;", "&").replace("&#39;", "'").replace("&quot;", '"')
                    out.append((v.group(1), title, when))
        except Exception as ex:
            log("  ! RSS канала:", rss, ex)
        _YT[rss] = out
    return _YT[rss]


SEG_PHRASE = {"КП": "short program", "ПП": "free skating", "РТ": "rhythm dance", "ПТ": "free dance"}
KIND_PHRASE = {"men": "men", "women": "women", "pairs": "pairs", "dance": "ice dance"}


def stream_url(cfg, kind, level, seg, day):
    """Конкретный эфир по правилу stream: {rss, title, need?, by: day|segment}. День — «… День 2»
    на всё соревнование (ФФКР); сегмент — отдельное видео «Men Short Program | …» в день старта
    (±1 день: эфир заводят до начала). Не нашли — None (остаётся общая ссылка)."""
    for vid, title, when in yt_streams(cfg["rss"]):
        if not re.search(cfg["title"], title, re.I) or (cfg.get("need") and not re.search(cfg["need"], title)):
            continue
        if cfg.get("by") == "segment":
            low = " ".join(title.lower().split())
            if f"{KIND_PHRASE[kind]} {SEG_PHRASE[seg]}" not in low:
                continue
            if ("junior" in low) != (level == "junior") or abs((when - day).days) > 1:
                continue
        elif when != day:
            continue
        return "https://www.youtube.com/watch?v=" + vid
    return None


def _http_url(u):
    return isinstance(u, str) and re.match(r"https?://[^\s/]+", u) is not None


def watch_for(name, base=None, event=None):
    """Где смотреть: [{name, url}]. Ссылки со страницы турнира (base) важнее общих
    правил из config.json: правило не добавляет канал, который со страницы уже есть.
    event = (kind, level, seg, день по Москве): правило со stream подменяет общую ссылку
    конкретным эфиром, если он нашёлся в RSS."""
    out = [dict(w) for w in (base or []) if w.get("name") and _http_url(w.get("url"))]
    have = {w["name"] for w in out}
    for r in CFG["broadcast_rules"]:
        if re.search(r["match"], name):
            for w in r.get("watch", []):
                if w["name"] not in have and _http_url(w["url"]):
                    url = w["url"]
                    if event and w.get("stream"):
                        url = stream_url(w["stream"], *event) or url
                    out.append({"name": w["name"], "url": url})
                    have.add(w["name"])
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


def categories_of(idx, intl):
    """Категории табло, которые берём в события и в протокол: [(категория, вид, уровень)]."""
    cats = []
    for c in idx["categories"]:
        if not intl and fsr.low_level(c["name"]):
            continue
        kind, level = (cat_en(c["name"]) if intl else fsr.classify(c["name"]))
        if kind is None:
            continue
        cats.append((c, kind, level or "senior"))
    return cats


def protocol_name_of(names, fix):
    """Имя для файла протокола — как в событиях: fix табло, затем to_ru."""
    return lambda n: names.to_ru(fix(n))


def from_swisstiming(idx, *, tid, tournament, venue, intl, broadcast, names, ours_rule,
                     extra_starts=None, fix=None, protos=None, now=None, proto_dir=None, watch=None):
    """Сегменты из табло. ours_rule(name, nation) → bool. extra_starts — запасные
    времена начала {(kind, level, seg): datetime}, если в табло нет расписания.
    fix(имя) — приведение имени из табло (региональные: «Имя Отчество ФАМИЛИЯ» → «Имя ФАМИЛИЯ»).
    Окончательность, оценки и строки протокола — в protocols.segment_view.
    protos — словарь {tid: заготовка файла протокола}: сюда кладутся категории с сегментами
    (и сегменты без времени в расписании). now и proto_dir — для проверок на фикстурах."""
    fix = fix or (lambda s: s)
    cats = categories_of(idx, intl)
    levels = {lv for _, _, lv in cats}
    mixed = len(levels) > 1
    events = []
    now = now or dt.datetime.now(dt.timezone.utc)
    fetcher = P.Fetcher()  # PDF оценок и итоги: один адрес — один запрос на сборку
    name_of = protocol_name_of(names, fix)
    proto_cats = []
    prev_doc = P.load_doc(os.path.join(proto_dir or PROTO_DIR, P.proto_name(tid))) if protos is not None else None
    if protos is not None:
        protos[tid] = {"tournament": tournament, "src": idx["url"], "marks": idx["marks"],
                       "categories": proto_cats, "fetcher": fetcher}

    def record(s, seg, category, start, end, view):
        """Сегмент для файла протокола: с деталями оценок и бригадой, если они есть.
        Окончательный в прежнем файле и сейчас — берём прежний: PDF оценок второй раз не качаем."""
        prev = P.find_segment(prev_doc, category, seg)
        if prev and prev["state"] == "final" and view["state"] == "final" and len(prev["rows"]) == len(view["rows"]):
            return prev
        return P.make_segment(seg=s, code=seg, start=start, end=end, view=view, name_of=name_of,
                              fetcher=fetcher, prev=prev, log=log)

    for c, kind, level in cats:
        try:
            entries = [dict(p, name=fix(p["name"])) for p in st.parse_entries(c["entries_url"])]
        except net.FetchError:
            entries = []
        for p in entries:
            if nm.is_cyr(p["name"]):
                for one in p["name"].split(" / "):
                    names.add(one)
        codes = [seg_code(s["name"]) for s in c["segments"]]
        last_seg = max((SEG_ORDER[x] for x in codes if x), default=None)
        cat_events, cat_total, cat_rows = [], None, []
        first_places, first_url = {}, None
        seg_records = []
        for s, seg in zip(c["segments"], codes):
            if seg and SEG_ORDER[seg] == 0:
                first_url = s["url"]
            if not seg:
                continue
            start = s.get("start") or (extra_starts or {}).get((kind, level, seg))
            if not start and protos is None:
                continue
            try:
                seg_page = net.fetch(s["url"])
            except net.FetchError as e:
                seg_page = None
                fetcher.errors.append((s["url"], e.kind))
            if not start:
                # в расписании табло времени нет (ФФКМ: произвольные) — события нет, сегмент в протоколе есть
                try:
                    view = P.segment_view(
                        seg=s, category=c["name"], code=seg, page=seg_page,
                        cat_url=c.get("results_url") if SEG_ORDER[seg] == last_seg else None,
                        now=now, start=None, end=None, marks=idx["marks"], fetcher=fetcher,
                        final_by_time=CFG.get("final_by_time", False),
                        podium_from_pdf=CFG.get("podium_from_judges_pdf", False))
                    if seg_page is not None:
                        seg_records.append(record(s, seg, c["name"], None, None, view))
                except Exception as e:  # протокол необязателен — расписание важнее
                    log("  ! протокол сегмента:", s["url"], e)
                continue
            order = [dict(p, name=fix(p["name"])) for p in st.parse_starting_order(s["url"], seg_page)] \
                if seg_page else []
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
            last = max(msk_times.values()) if msk_times else None
            end = estimate_end(start, seg, kind, len(people), last)
            # состояние сегмента: сегмент прошёл только с подтверждёнными судейскими оценками
            try:
                view = P.segment_view(
                    seg=s, category=c["name"], code=seg, page=seg_page,
                    cat_url=c.get("results_url") if SEG_ORDER[seg] == last_seg else None,
                    now=now, start=start.astimezone(dt.timezone.utc), end=end.astimezone(dt.timezone.utc),
                    marks=idx["marks"], fetcher=fetcher,
                    final_by_time=CFG.get("final_by_time", False),
                    podium_from_pdf=CFG.get("podium_from_judges_pdf", False))
            except Exception as e:  # протокол необязателен — расписание важнее
                log("  ! протокол сегмента:", s["url"], e)
                view = {"state": "format", "basis": None, "results": None, "reason": None}
            if view["reason"] or view["state"] == "judges_mismatch":
                # оценки есть, но не к этому сегменту (или строки PDF не сошлись с табло): тройку не ставим
                log("  ! оценки сегмента не подтверждены:", s["url"], view["reason"] or "чужой файл")
            if protos is not None and seg_page is not None and "rows" in view:
                try:
                    seg_records.append(record(s, seg, c["name"], start, end, view))
                except Exception as e:
                    log("  ! протокол сегмента:", s["url"], e)
            done = view["state"] == "final"
            results = [dict(r, name=fix(r["name"])) for r in view["results"] or []]
            started = bool(results) and start.astimezone(dt.timezone.utc) <= now
            place = {r["name"]: r["place"] for r in results} if started else {}
            if started and SEG_ORDER[seg] == 0:
                first_places = place
            ours, field = [], []
            for p in people:
                o = {"name": names.to_ru(p["name"]), "nation": p.get("nation", "")}
                no = p.get("no")
                if no and no in msk_times and "rank" not in p:
                    o["time"] = msk_times[no].strftime("%H:%M")
                if no:
                    # после проката табло показывает итог, но стартовый номер в нём остаётся
                    o["no"] = no
                    o["warmup"] = p.get("warmup") or warm.get(no)
                if place.get(p["name"]):
                    o["place"] = place[p["name"]]
                # field — весь состав: за кем следить, решает человек в приложении
                field.append(o)
                if ours_rule(p["name"], p.get("nation", "")):
                    ours.append(o)
            if done and SEG_ORDER[seg] == last_seg and c.get("results_url"):
                try:
                    cr = st.parse_category_results(c["results_url"])
                    if cr["complete"]:
                        rows = [dict(r, name=fix(r["name"])) for r in cr["rows"]]
                        cat_total, cat_rows = top3(rows, names), rows
                except Exception as e:
                    log("  ! итог вида:", c["results_url"], e)
            podium = top3(results, names) if started else None
            total = cat_total if SEG_ORDER[seg] == last_seg else None
            athletes = sorted({names.to_ru(p["name"]) for p in people})
            ev = make_event(
                tid=tid, tournament=tournament, kind=kind, level=level, seg=seg, mixed=mixed,
                start=start, end=end, venue=venue, intl=intl, broadcast=broadcast,
                watch=watch, ours=sort_ours(ours), athletes=athletes, src=idx["url"],
                podium=podium, total=total)
            ev["field"] = sort_ours(field)
            ev["_cat"] = c["name"]
            # протокол уже на табло, но судейских оценок ещё нет — промежуточные итоги
            if started and not done:
                ev["provisional"] = True
            is_last = SEG_ORDER[seg] == last_seg
            # адреса табло — приложение во время старта читает их само, не дожидаясь сбора;
            # basis — окончательность сегмента (judges, time или null), по нему settled
            ev["live"] = {
                "idx": idx["url"], "seg": s["url"],
                "cat": c.get("results_url") if is_last else None,
                "first": first_url if is_last and first_url != s["url"] else None,
                "names": {p["name"]: names.to_ru(p["name"]) for p in people},
                "basis": view["basis"],
            }
            if done and s.get("judges_pdf"):
                f = rs.segment_facts(s["judges_pdf"], kind=kind, level=level, seg=seg, intl=intl,
                                     season=rs.season_of(CFG), to_ru=names.to_ru, log=log)
                if f:
                    ev["facts"] = f
            ev["desc"] = describe(ev)
            events.append(ev)
            cat_events.append(ev)
        if protos is not None:
            total = None
            last_final = any(r["state"] == "final" for r in seg_records if SEG_ORDER[r["code"]] == last_seg)
            if c.get("results_url") and any(r["state"] != "scheduled" for r in seg_records):
                try:
                    total = P.total_record(fetcher.page(c["results_url"]), last_final, name_of)
                except net.FetchError:
                    total = None
            proto_cats.append(P.category_record(kind, level, c["name"], seg_records, total))
        if cat_total and cat_events:
            # наши не прошли в последний сегмент — итог вида у их последнего старта
            ev = cat_events[-1]
            ev["total"] = cat_total
            # место наших в итоге вида
            final = {nm.key(names.to_ru(r["name"])): r["place"] for r in cat_rows}
            for o in ev["ours"] + ev.get("field", []):
                if final.get(nm.key(o["name"])):
                    o["final"] = final[nm.key(o["name"])]
            if c.get("results_url"):
                f = rs.total_facts(c["results_url"] + "#total", cat_rows, first_places, kind=kind,
                                   level=level, intl=intl, season=rs.season_of(CFG), to_ru=names.to_ru)
                if f:
                    ev["facts"] = rs.unique_facts((ev.get("facts") or []) + f)
            ev["desc"] = describe(ev)
    return unique_ids(events)


def unique_ids(events):
    """Id = турнир:вид-уровень-сегмент. Если у вида несколько разрядов (Golden Skate: «Solo Dance»
    по возрастам), id совпадал, и в приложении поле «скакало» между разными стартами. Совпавшим
    добавляем слаг категории — он стабилен между сборками; остальные id не меняются. Прежний id
    лежит в _old_id: build.main по нему переносит данные и убирает старые записи."""
    groups = {}
    for ev in events:
        groups.setdefault(ev["id"], []).append(ev)
    for base, evs in groups.items():
        if len(evs) > 1:
            used = set()
            for ev in evs:
                suffix = slugify(ev.get("_cat", "")) or "x"
                new = f"{base}-{suffix}"
                n = 2
                while new in used:
                    new = f"{base}-{suffix}-{n}"
                    n += 1
                used.add(new)
                ev["_old_id"] = base
                ev["id"] = new
    for ev in events:
        ev.pop("_cat", None)
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
    report["fsr_pages"] = pages  # региональные источники отбрасывают турниры, уже взятые отсюда
    # и записи календаря без страницы: их тоже нельзя заводить второй раз пустой записью «без расписания»
    report["fsr_cal"] = [{"title": c["title"], "start": c["start"], "end": c["end"]} for c in cal]

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
                        idx, protos=report.get("protos"), tid=tid, tournament=name, venue=venue, intl=False, broadcast=bcast,
                        watch=page["watch"] if page else None, names=names, ours_rule=rule,
                        extra_starts={k: v[0] for k, v in pdf_starts.items()})
            if not got and pdf_starts:
                levels = {k[1] for k in pdf_starts}
                for (kind, level, seg), (s0, e0) in pdf_starts.items():
                    got.append(make_event(
                        tid=tid, tournament=name, kind=kind, level=level, seg=seg,
                        mixed=len(levels) > 1, start=s0, end=e0, venue=venue, intl=False,
                        broadcast=bcast, watch=page["watch"] if page else None,
                        ours=[], athletes=[], src=page["schedule_pdf"]))
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


# ---------------------------------------------------------------- регионы

SAMARA_TZ = dt.timezone(dt.timedelta(hours=4))  # Самарская область целиком, включая Сызрань и Тольятти
MSK_OFFSET = 180  # табло ФФКМ без пояса: московское время


class SourceDown(Exception):
    """Региональный источник не отдал данные. Текст — причина, она уходит в статус источника."""


def _core(title):
    """Название турнира без кавычек — для сравнения с федеральным списком."""
    m = re.search(r"[«\"](.+?)[»\"]", title)
    return (m.group(1) if m else title).lower().strip()


def _fed_dup(title, start, end, fed_pages):
    """Турнир уже в федеральном календаре ФФККР: те же даты и то же название. Федеральная запись важнее."""
    core = _core(title)
    return any(p.get("start") == start and p.get("end") == end and core and
               (core in p["title"].lower() or _core(p["title"]) in title.lower())
               for p in fed_pages)


def _regional_upcoming(tid, name, start, end, venue, region):
    return {"tid": tid, "name": name, "start": start.isoformat(), "end": end.isoformat(),
            "venue": venue, "intl": False, "tier": "regional", "region": region}


def _tag_regional(events, region):
    for ev in events:
        ev["tier"] = "regional"
        ev["region"] = region
    return events


def _ffkm_rn_tid(r, name):
    """id турнира ФФКМ без табло — реестровый номер: название и даты по slugify склеиваются (обрезка
    60 знаков). Номера нет у многих записей календаря — тогда карточка (в адресе номер статьи), а без
    неё название с датой; иначе у всех таких турниров один id, и они подменяют друг друга в кэше."""
    if r["number"]:
        return "ffkm:rn" + r["number"]
    if r["page"]:
        return "ffkm:" + rg.tail(r["page"])
    return "ffkm:" + slugify(name + "-" + r["start"].isoformat())


def do_ffkm(names, report, failed, upcoming, fed_pages, fed_cal=()):
    """ФФКМ (Москва): календарь → карточка турнира → табло (классическая вёрстка).
    Карточная вёрстка табло пока не разбирается: турнир уходит в «без расписания»."""
    try:
        rows = rg.ffkm_calendar()
    except net.FetchError as e:
        raise SourceDown(f"календарь не открылся ({e})")
    if len(rows) < 20:
        raise SourceDown(f"в календаре {len(rows)} строк — подозрительно мало")
    today = dt.datetime.now(MSK).date()
    fed_urls = {p["results"] for p in fed_pages if p.get("results")}
    rule = watch_rule({nm.key(w) for w in CFG["watchlist"]})
    events = []
    for r in rows:
        # федеральный порог: разряды без МС/КМС не берём (по программе, а не по каждой категории)
        if fsr.low_level(r["program"]) and not re.search(r"\bК?МС\b", r["program"]):
            continue
        if _fed_dup(r["title"], r["start"], r["end"], fed_pages):
            continue
        name = r["title"]
        venue = ru_venue("Москва", r["place"])
        rn_tid = _ffkm_rn_tid(r, name)
        try:
            table = rg.ffkm_detail(r["page"], r["start"]) if r["page"] else None
        except net.FetchError as e:
            # табло этого турнира неизвестно — прошлые старты ФФКМ остаются (как при сбое источника)
            log(f"  ! ФФКМ карточка «{name}»: {e}")
            failed.add("ffkm:*")
            report["errors"].append(f"ФФКМ {name}: карточка: {e}")
            continue
        if table and table in fed_urls:
            continue
        tid = "ffkm:" + rg.tail(table.rsplit("/", 1)[0]) if table else rn_tid
        got = []
        if table:
            try:
                idx = st.parse_index(table, default_offset=MSK_OFFSET)
                if idx["categories"]:
                    got = _tag_regional(from_swisstiming(
                        idx, protos=report.get("protos"), tid=tid, tournament=name, venue=venue, intl=False,
                        broadcast=broadcast_for(name), names=names, ours_rule=rule,
                        fix=pp.entry_name), "Москва")
                else:
                    log(f"  ФФКМ «{name}»: табло в карточной вёрстке — старты не разобраны")
            except Exception as e:  # один турнир не должен ронять источник
                log(f"  ! ФФКМ «{name}»: {e}")
                traceback.print_exc()
                failed.add(tid)
                report["errors"].append(f"ФФКМ {name}: {e}")
                continue
            if got:
                events += got
                log(f"  ФФКМ {name}: {len(got)}")
        # тот же турнир есть в федеральном календаре — вторую пустую запись «без расписания» не заводим
        if not got and r["end"] >= today and not _fed_dup(name, r["start"], r["end"], fed_cal):
            upcoming.append(_regional_upcoming(tid, name, r["start"], r["end"], venue, "Москва"))
    return events


def do_samara(names, report, failed, upcoming, fed_pages, fed_cal=()):
    """Самарская область (СООО «ФФКК», skate63.ru): статьи турниров сезона → расписания PDF.
    Календарь PDF — сверка дат. Протоколы не разбираются: своя вёрстка, разборщика пока нет.
    Расписание PDF без вида катания («Короткая программа – КМС») не даёт стартов: вид неизвестен."""
    season_start = dt.date.fromisoformat(CFG["season_start"])
    try:
        cards = rg.samara_cards(season_start)
    except net.FetchError as e:
        raise SourceDown(f"статьи не открылись ({e})")
    if len(cards) < 3:
        raise SourceDown(f"статей сезона {len(cards)} — подозрительно мало")
    cal = None
    try:
        cal_url = rg.samara_calendar_pdf()
        if cal_url:
            cal = rg.samara_calendar_ranges(net.pdf_text(cal_url))
    except net.FetchError as e:
        log(f"  ! календарь Самары: {e}")
    today = dt.datetime.now(MSK).date()
    events, matched = [], 0
    for c in cards:
        if _fed_dup(c["title"], c["start"], c["end"], fed_pages):
            continue
        if cal is not None:
            if (c["start"], c["end"]) in cal:
                matched += 1
            else:
                log(f"  Самара: в календаре PDF нет дат {c['start']}–{c['end']}: {c['title']}")
        tid = "samara:" + rg.tail(c["url"])
        try:
            schedules = rg.samara_schedules(c["url"])
        except net.FetchError as e:
            log(f"  ! Самара «{c['title']}»: {e}")
            failed.add(tid)
            report["errors"].append(f"Самара {c['title']}: {e}")
            continue
        got = []
        season_hint = c["start"].year if c["start"].month >= 7 else c["start"].year - 1
        for pdf in schedules:
            try:
                text = net.pdf_text(pdf)
                rows = fsr.schedule_text(text, season_hint)
            except (net.FetchError, OSError) as e:
                log(f"  ! Самара PDF «{c['title']}»: {e}")
                failed.add(tid)
                continue
            city, place = rg.schedule_venue(text)
            venue = ru_venue(city, place) if city else ""
            picks = []
            for d, (h, m), (h2, m2), what in rows:
                if fsr.low_level(what):
                    continue
                kind, level = fsr.classify(what)
                seg = fsr.segment_of(what)
                if kind and seg:
                    picks.append((kind, level or "senior", seg, d, (h, m), (h2, m2)))
            mixed = len({p[1] for p in picks}) > 1
            for kind, level, seg, d, (h, m), (h2, m2) in picks:
                s0 = dt.datetime(d.year, d.month, d.day, h, m, tzinfo=SAMARA_TZ)
                e0 = dt.datetime(d.year, d.month, d.day, h2, m2, tzinfo=SAMARA_TZ)
                if e0 <= s0:
                    e0 += dt.timedelta(days=1)
                got.append(make_event(
                    tid=tid, tournament=c["title"], kind=kind, level=level, seg=seg, mixed=mixed,
                    start=s0, end=e0, venue=venue, intl=False, broadcast=[], ours=[], athletes=[],
                    src=pdf))
        if got:
            events += _tag_regional(got, "Самарская область")
            log(f"  Самара {c['title']}: {len(got)}")
        elif c["end"] >= today and not _fed_dup(c["title"], c["start"], c["end"], fed_cal):
            upcoming.append(_regional_upcoming(tid, c["title"], c["start"], c["end"], "", "Самарская область"))
    if cal is not None:
        log(f"  Самара: даты статей совпали с календарём PDF: {matched} из {len(cards)}")
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
                got = from_swisstiming(idx, protos=report.get("protos"), tid=tid, tournament=name, venue=venue, intl=True,
                                       broadcast=bcast, names=names, ours_rule=ours_rule_intl,
                                       extra_starts=extra)
                if got:
                    try:
                        for full, url in isu.portraits(e["slug"], e["event_id"]).items():
                            photos["raw"].append((full, url, 1))
                    except Exception as ex:  # фото не повод терять турнир
                        log("  ! портреты ISU:", ex)
            else:
                got, ours_all, all_names = isu_api_events(e, tid, name, venue, bcast, names, sched, photos)
                if not got and to > now:
                    # заявка есть, расписания нет: турнир — в «скоро», с полным составом для поиска
                    upcoming.append({
                        "tid": tid, "name": name, "intl": True, "venue": venue,
                        "start": fr.astimezone(MSK).date().isoformat(),
                        "end": (to - dt.timedelta(hours=12)).astimezone(MSK).date().isoformat(),
                        "ours": sorted({n for n, _ in ours_all}), "ours_nation": dict(sorted(set(ours_all))),
                        "athletes": sorted(set(all_names)),
                        "broadcast": bcast, "watch": watch_for(name)})
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
    ours_all, all_names = [], []
    now = dt.datetime.now(dt.timezone.utc)
    for c in cats:
        kind, level = cat_en(c["name"])
        if not kind:
            continue
        ents = isu.entries(e["event_id"], c)
        ours = [{"name": names.to_ru(x["name"]), "nation": st.nation_code(x["code"])} for x in ents if x["code"] in CFG["ours_codes"]]
        field = [{"name": names.to_ru(x["name"]), "nation": st.nation_code(x["code"])} for x in ents]
        if not field:
            continue
        for x in ents:
            for full, url in x.get("photos", {}).items():
                photos["raw"].append((full, url, 1))
        ours_all += [(o["name"], o["nation"]) for o in ours]
        all_names += [o["name"] for o in field]
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
                total = [{"place": x["rank"], "name": names.to_ru(x["name"]), "nation": st.nation_code(x["code"]),
                          "points": x["points"]} for x in ranked[:3]]
            ev = make_event(
                tid=tid, tournament=name, kind=kind, level=level, seg=seg, mixed=len(levels) > 1,
                start=when, end=end, venue=venue, intl=True, broadcast=bcast,
                ours=sorted(ours, key=lambda o: o["name"]), athletes=sorted(o["name"] for o in field),
                src=f"https://isu-skating.com/en/figure-skating/events/eventdetail/{e['slug']}/",
                total=total)
            ev["field"] = sorted(field, key=lambda o: o["name"])
            out.append(ev)
    return out, ours_all, all_names


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
            got = from_swisstiming(idx, protos=report.get("protos"), tid=tid, tournament=name, venue=venue, intl=True,
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

def withdraw_photos(photos, skip):
    """Отбракованный снимок (адрес в photo_skip) не публикуется, даже если остался в прошлых данных.
    Имя остаётся с пустым значением: так приложение узнаёт, что прежнее фото надо забыть."""
    bad = {ph.rel_path(u) for u in skip if not u.startswith("person:")}
    return {k: ("" if v in bad else v) for k, v in photos.items()}


def collect_photos(events, upcoming, names, photos, prev_photos, everyone=()):
    """{«Имя Фамилия» как в ours/podium/total/watchlist и справочнике: адрес фото}. Пары — по людям.
    Источники: сборная ФФККР, портреты ISU (заявки, общий список), Викиданные. Адрес берётся,
    только если он действительно отдаёт картинку."""
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
    for n in everyone:
        add(n)

    # выбор источника, миниатюры и память о найденном («не пропадает») — в photos.collect
    return ph.collect(SITE, want, photos["raw"], prev_photos, names, ph.BOOK, PHOTO_SKIP, log,
                      wiki_ok=photos.get("wiki_ok", False))


PHOTO_SKIP = os.path.join(ROOT, "data", "photo_skip.json")


def _load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _save_json(path, value):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False, indent=0)


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
    roster = load_roster()
    report = {"errors": [], "sources": {}, "protos": {}}
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

    # Регионы: старты с tier=regional. Статус источника — «ok» или причина текстом;
    # сбой оставляет прошлые старты этого источника (как у федеральных).
    fed_pages = report.get("fsr_pages") or []
    fed_cal = report.get("fsr_cal") or []
    for label, prefix, fn in (
            ("ФФКМ", "ffkm:", lambda: do_ffkm(names, report, failed, upcoming, fed_pages, fed_cal)),
            ("Самара", "samara:", lambda: do_samara(names, report, failed, upcoming, fed_pages, fed_cal))):
        try:
            events += fn()
            report["sources"][label] = "ok"
        except SourceDown as e:
            log(f"!! {label}: {e}")
            report["sources"][label] = str(e)
            failed.add(prefix + "*")
        except Exception as e:
            log(f"!! {label} недоступен: {e}")
            traceback.print_exc()
            report["sources"][label] = f"ошибка: {e}"
            report["errors"].append(f"{label}: {e}")
            failed.add(prefix + "*")

    # Монотонность (scraper/keep.py): после старта табло показывает результаты вместо стартового
    # листа, источник мог не ответить, PDF не прочитаться — всё, что уже было опубликовано
    # и не изменено явно, остаётся. Время выхода и номера наших, итоги прошедших сегментов,
    # примечательное, ссылки трансляций, ссылки табло.
    prev_by_id = {e["id"]: e for e in prev.get("events", [])}
    # события, у которых id изменился из-за коллизии (unique_ids): данные берём у прежнего
    # с тем же старым id и временем, прежние записи под старым id убираем
    migrated = {e["_old_id"] for e in events if "_old_id" in e}
    for e in events:
        old_id = e.pop("_old_id", None)
        if old_id:
            twin = next((o for o in prev.get("events", [])
                         if o["id"] in (old_id, e["id"]) and o["start"] == e["start"]), None)
            if twin:
                prev_by_id[e["id"]] = twin
    prev["events"] = [o for o in prev.get("events", []) if o["id"] not in migrated]
    same_rules = prev.get("facts_version", rs.VERSION) == rs.VERSION
    retract = CFG.get("keep_retract") or {}
    for e in events:
        old = prev_by_id.get(e["id"])
        if old and kp.merge_event(e, old, same_rules=same_rules, retract_facts=retract.get("facts", ()),
                                  retract_urls=retract.get("urls", ()), to_ru=names.to_ru):
            e["ours"] = sort_ours(e["ours"])
            e["facts"] = rs.unique_facts(e.get("facts"))
            if not e["facts"]:
                e.pop("facts", None)
            e["desc"] = describe(e)

    # Прошлый успешный сбор: всё, что не удалось получить сейчас, и прошедшие старты
    have = {e["id"] for e in events}
    kept = 0
    season_start = CFG["season_start"]
    vanished = running_tids(prev.get("events", []), {e["tid"] for e in events}, now)
    if vanished:
        log("  идущие турниры пропали из источника, остаются прошлые старты:", ", ".join(sorted(vanished)))
    for e in prev.get("events", []):
        if e["id"] in have or e["start"] < season_start:
            continue
        pref = e["tid"].split(":")[0] + ":*"
        past = dt.datetime.fromisoformat(e["end"]) < now
        if e["tid"] in failed or pref in failed or past or e["tid"] in vanished:
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
    upcoming = [u for u in kp.merge_upcoming(upcoming, [u for u in prev.get("upcoming", []) if u["tid"] not in have_tids],
                                             report["sources"], failed, now.date().isoformat())]

    # Справочник для поиска: россияне от КМС и выше, все участники турниров ISU за два сезона
    try:
        book = pp.build(names, CFG["season_start"], log)
    except Exception as e:  # справочник — не расписание: без него лента работает
        log("!! справочник спортсменов:", e)
        traceback.print_exc()
        book = {"people": prev.get("people") or [], "photos": []}
    photos["raw"].extend(book["photos"])
    photos["wiki_ok"] = bool(book.get("wiki_ok"))  # Викиданные ответили: неподтверждённые фото можно убирать

    # Справочник для фильтра по спортсменам копится между сборами: все, кого видел
    # сборщик, — российские старты (МС/КМС) и участники международных турниров.
    roster.update(names.ru.values())
    roster.update(CFG["watchlist"])
    for e in events:
        roster.update(e.get("athletes", []))
        roster.update(o["name"] for o in e.get("ours", []))
        roster.update(p["name"] for p in e.get("podium", []))
        roster.update(p["name"] for p in e.get("total", []))
        roster.update((e.get("live") or {}).get("names", {}).values())
    roster.update(p["n"] for p in book["people"])
    roster = kp.merge_names(roster, prev.get("roster"), retract.get("roster", ()))
    # латинское написание того, кого уже знаем по-русски, в справочнике не держим: поиск не должен давать двойников
    roster = {n for n in roster if not names.known_latin(n)}
    # пара наполовину кириллицей, наполовину латиницей — иностранец, ошибочно принятый за нашего
    roster = {n for n in roster if " / " not in n
              or len({nm.is_cyr(m) for m in n.split(" / ")}) == 1}

    all_ok = all(s == "ok" for s in report["sources"].values()) and not report["errors"]
    data = {
        "generated": now.isoformat(),
        "checked": now.isoformat(),
        "complete": all_ok,
        "facts_version": rs.VERSION,
        "sources": report["sources"],
        "events": events,
        "upcoming": upcoming,
        "watchlist": CFG["watchlist"],
        "roster": sorted(roster),
        "people": kp.merge_named(book["people"], prev.get("people"), "n", retract.get("people", ())),
        "photos": withdraw_photos(kp.merge_map(collect_photos(events, upcoming, names, photos, prev.get("photos") or {},
                                                              [p["n"] for p in book["people"]]),
                                               prev.get("photos"), retract.get("photos", ())),
                                  ph.load_skip(PHOTO_SKIP)),
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
        save_roster(roster)
        rs.save()

    report["protocols"] = write_protocols(report["protos"], data["events"], now)
    write_site(data)
    log(f"готово: {len(data['events'])} стартов, {len(data['upcoming'])} турниров без расписания;"
        f" источники: {report['sources']}; протоколы: {report['protocols']}; ошибок: {len(report['errors'])}")
    for e in report["errors"]:
        log("   -", e)
    return 0


def running_tids(prev_events, new_tids, now):
    """Турниры, которые в прошлый сбор уже шли (между первым стартом и концом последнего), а в этом
    из источника пропали (календарь отдал урезанный список): их будущие старты оставляем из
    прошлого сбора, иначе табло турнира перестают опрашивать посреди проведения."""
    span = {}
    for e in prev_events:
        lo, hi = dt.datetime.fromisoformat(e["start"]), dt.datetime.fromisoformat(e["end"])
        old = span.get(e["tid"])
        span[e["tid"]] = (min(lo, old[0]), max(hi, old[1])) if old else (lo, hi)
    return {t for t, (lo, hi) in span.items() if t not in new_tids and lo <= now <= hi}


def write_protocols(protos, events, now, proto_dir=None):
    """Файлы протоколов собранных турниров и status.json; events[].proto. → {ok, format, net, missing}.

    Прежний файл — с gh-pages (workflow кладёт его в site/data/protocols до сбора): защита от
    регресса берёт из него окончательные сегменты, а файл, не прошедший проверку, не пишется —
    на сайте остаётся последний удачный."""
    proto_dir = proto_dir or PROTO_DIR
    os.makedirs(proto_dir, exist_ok=True)
    status = P.read_status(proto_dir)
    summary = {"ok": 0, "format": 0, "net": 0, "missing": 0}
    final_by_time = CFG.get("final_by_time", False)
    for tid, p in protos.items():
        doc = P.make_doc(tid=tid, tournament=p["tournament"], src=p["src"], marks=p["marks"],
                         categories=p["categories"], now=now)
        for note in P.merge_prev(doc, P.load_doc(os.path.join(proto_dir, P.proto_name(tid)))):
            log(f"  протокол {tid}: {note}")
        if not doc["categories"]:
            summary["missing"] += 1
            continue
        ok, _ = P.publish(proto_dir, doc, final_by_time, log)
        error = "format" if not ok else P.fetch_error(p["fetcher"].errors)
        status[tid] = P.status_item(status.get(tid), now, error)
        summary["ok" if error is None else ("format" if error == "format" else "net")] += 1
    P.write_status(proto_dir, status, now)
    P.attach_proto(events, proto_dir)
    return summary


def write_site(data):
    """events.json, общая лента calendar.ics и по файлу .ics на старт."""
    os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    gen = dt.datetime.fromisoformat(data["generated"])
    with open(OUT_ICS, "w", encoding="utf-8", newline="") as f:
        # общая лента календаря — как лента приложения по умолчанию: российские старты
        # и международные с россиянами и белорусами; региональные сюда не попадают — файл
        # статичный и не может переключаться в приложении (по файлу на старт — ниже)
        f.write(ics.build([e for e in data["events"]
                           if (not e["intl"] or e["ours"]) and e.get("tier") != "regional"], gen, PUBLIC_URL))
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
    # файлы протоколов турниров, которых нет среди событий, — на сайте не нужны
    P.cleanup(PROTO_DIR, {P.proto_name(e["tid"]) for e in data["events"]})


if __name__ == "__main__":
    sys.exit(main())
