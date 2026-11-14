"""Архив прошлых сезонов: старты прошлых лет в том же виде, что events.json, по месяцам.

Приложение листает «Месяц» назад и подгружает месяц архива так же, как читает нынешнее расписание:
карточка старта, места всего состава, тройка, итог турнира, протокол с элементами.

Источники те же, что у добора элементов (backfill.py): табло турниров ISU на results.isu.org и
табло турниров ФФККР, с сезона 2018/19. Список турниров — `python3 -m scraper.backfill discover`.

Что лежит на сайте (в main коммитится руками, публикуется вместе с site/):
  site/data/past/index.json             {v, built, first, last, months: {"2024-12": число стартов}}
  site/data/past/<гггг-мм>.json          {v, month, events: [...], tournaments?: [...]}; поля события —
        как в events.json, без того, что прошедшему старту не нужно: desc, live, watch, broadcast,
        ours, athletes (приложение строит «ours» само по field — Start.withFollow). tournaments —
        турниры, у которых на табло нет времени сегментов: {tid, name, start, end, venue, intl,
        proto, kinds}; в календаре они стоят днями проведения, итоги — в протоколе
  site/data/past/protocols/<имя>.json    протокол турнира, как site/data/protocols (protocols.py),
        но без оценок отдельных судей (j) и без бригады: с ними архив втрое тяжелее
  site/h/<xx>.json                       история выступлений по спортсменам (см. athletes())

Запуск (повторяемый; турнир, уже лежащий в части, не скачивается заново):
    python3 -m scraper.backfill discover                       # списки isu.json, fsr.json
    python3 -m scraper.history run --out ЧАСТЬ.jsonl [--src ISU|ФФККР] [--shard I/N] [--limit N]
    python3 -m scraper.history merge ЧАСТЬ1.jsonl ЧАСТЬ2.jsonl …   # → site/data/past
    python3 -m scraper.history athletes                           # → site/h (и в конце merge)

Нынешний сезон в архив не собирается: он целиком лежит в events.json. Когда сезон сменится и сбор
перестанет держать прошлогодние старты, build.main отдаёт их сюда (fold) — архив растёт сам.

Имена. На табло ISU россияне записаны латиницей, на табло ФФККР — по-русски. Чтобы один человек
был одним человеком, run пишет имена как на табло, а merge переводит латиницу россиян и белорусов
(по коду страны) словарём: data/names.json плюс все русские имена с табло ФФККР за эти годы.
Иностранцев словарь не трогает.
"""
import argparse
import datetime as dt
import collections
import glob
import json
import os
import re
import sys
import zlib

from . import archive as ar
from . import backfill as bf
from . import build, fsr, net
from . import names as nm
from . import people as pp
from . import protocols as P
from . import results as rs
from . import swisstiming as st

V = 1
PAST_DIR = os.path.join(build.SITE, "data", "past")
PROTO_DIR = os.path.join(PAST_DIR, "protocols")
H_DIR = os.path.join(build.SITE, "h")
BUCKETS = 256
OURS = ("RUS", "AIN2", "AIN", "BLR", "AIN1")
# россияне прошлых лет под другими кодами: Олимпиада-2022 (ROC), чемпионат мира 2021 (FSR)
ALSO_RUS = {"ROC": "RUS", "FSR": "RUS"}
# у прошедшего старта этого не показываем — в архив не кладём
DROP = ("desc", "live", "watch", "broadcast", "ours", "athletes", "facts", "provisional")


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- имена

class RawNames:
    """Имена как на табло, с фамилией капсом: по капсу merge узнаёт, где фамилия («CHEN Nathan» на
    Олимпиаде), и переводит латиницу своих по коду страны."""

    def add(self, full_ru):
        pass

    def to_ru(self, name):
        return re.sub(r"\s+", " ", name.replace("\xa0", " ")).strip()


def latin_name(name):
    """«CHEN Nathan», «Nathan CHEN» → «Nathan Chen»; пара — по партнёру."""
    if " / " in name:
        return " / ".join(latin_name(p.strip()) for p in name.split(" / "))
    given, family = nm.split_given_family(name)
    return nm.pretty_latin(f"{given} {family}" if given and family else name)


_GIVEN = (("aleksander", "aleksandr"), ("victor", "viktor"), ("victoria", "viktoria"))


def _name_key(given, family):
    """Ключ человека: фамилия и имя в грубой свёртке (names.fold), с парой известных разночтений
    латиницы («Alexander» — «Александр»). Без «похожих» имён: Vladimir — не Владислав."""
    g = nm.fold(given)
    for a, b in _GIVEN:
        if g == nm.fold(a):
            g = nm.fold(b)
    return nm.fold(family), g


class Speller:
    """Латиница россиян и белорусов → по-русски: только точное совпадение имени и фамилии со
    словарём (data/names.json, data/roster.json, config latin_names и русские имена архива).
    Не нашли — человек остаётся латиницей, как на табло: чужое русское имя хуже."""

    def __init__(self, extra=()):
        self.aliases = build.CFG.get("aliases") or {}
        self.ru = {}
        self.latin = {}
        for lat, ru in nm._latin_names().items():
            given, _, family = lat.rpartition(" ")
            self.latin[_name_key(given, family)] = ru
        known = []
        for path in (build.NAMES, build.ROSTER):
            try:
                with open(path, encoding="utf-8") as f:
                    known += [n for n in json.load(f) if isinstance(n, str)]
            except (OSError, ValueError):
                pass
        for n in [*known, *extra]:
            for one in n.split(" / "):
                self._add(one)
        self._memo = {}

    def _add(self, full):
        full = nm.pretty_ru(ar._no_patronymic(re.sub(r"\s+", " ", full.replace("\xa0", " ")).strip()))
        parts = full.split()
        if len(parts) < 2 or not nm.is_cyr(full) or re.search(r"[A-Za-z]", full):
            return
        k = _name_key(nm.ru_to_lat(" ".join(parts[:-1])), nm.ru_to_lat(parts[-1]))
        if k not in self.ru or nm.spelling_rank(full) < nm.spelling_rank(self.ru[k]):
            self.ru[k] = full

    def _one(self, name):
        """Один человек латиницей → по-русски или None."""
        given, family = nm.split_given_family(name)
        if not given or not family:
            return None
        k = _name_key(given, family)
        return self.latin.get(k) or self.ru.get(k)

    def spell(self, name, nation, intl):
        """Имя для приложения. Российский старт — все свои; международный — по коду страны.
        Пара переводится целиком или остаётся латиницей целиком."""
        k = (name, nation, intl)
        if k in self._memo:
            return self._memo[k]
        if nm.is_cyr(name):
            # табло ФФККР 2025/26 пишет с отчеством («Аделия Тиграновна ПЕТРОСЯН») — человек тот же
            out = " / ".join(self.aliases.get(x, x)
                             for x in (nm.pretty_ru(ar._no_patronymic(p.strip())) for p in name.split(" / ")))
        else:
            out = latin_name(name)
            if not intl or st.nation_code(nation) in OURS or nation in OURS:
                ru = [self._one(p.strip()) for p in name.split(" / ")]
                if all(ru):
                    out = " / ".join(self.aliases.get(x, x) for x in ru)
        self._memo[k] = out
        return out


# ---------------------------------------------------------------- один турнир

_DATE_SLASH = re.compile(r">\s*(\d{2})/(\d{2})/(\d{2}|\d{4})\s*<")
_DATE_MON = re.compile(r">\s*(\d{1,2})-([A-Za-z]{3})-(\d{2}|\d{4})\s*<")
_COMNET_DETAIL = re.compile(r'(?is)<tr[^>]*class="?detail\d*"?[^>]*>.*?</table>\s*</td>\s*</tr>')
_HIDDEN_CELL = re.compile(r'(?is)<td[^>]*display:\s*none[^>]*>.*?</td>')


def norm_page(page):
    """Страница табло прошлых лет → к виду, который читает swisstiming.

    2018/19: даты расписания «23/08/18» и «06/09/2018» вместо «23.08.2018»; табло ISUCalcFS
    (чемпионат России 2019) — «20-Dec-18» и «Rythm Dance».
    Табло comnet (турниры ISU в Японии): теги прописными, колонка имени — «Competitor», под каждой
    строкой — вложенная таблица элементов, перед местом — скрытая ячейка с номером строки."""
    # «11/18/2023» (этап Гран-при России 2023) — месяц впереди: видно по числу больше 12 на втором месте
    us = any(int(m.group(2)) > 12 for m in _DATE_SLASH.finditer(page))

    def date(m):
        y = m.group(3)
        d, mo = (m.group(2), m.group(1)) if us else (m.group(1), m.group(2))
        return f">{d}.{mo}.{y if len(y) == 4 else '20' + y}<"
    page = _DATE_SLASH.sub(date, page)

    def mon(m):
        n = bf.MONTHS.get(m.group(2).lower())
        y = m.group(3)
        return f">{int(m.group(1)):02d}.{n:02d}.{y if len(y) == 4 else '20' + y}<" if n else m.group(0)
    page = _DATE_MON.sub(mon, page).replace("Rythm Dance", "Rhythm Dance")
    if "by comnet" in page:
        page = _COMNET_DETAIL.sub("", page)
        page = _HIDDEN_CELL.sub("", page)
        # разбор табло читает теги строчными
        page = re.sub(r"(?i)<(/?)(tr|td|th|table)\b", lambda m: f"<{m.group(1)}{m.group(2).lower()}", page)
        page = re.sub(r"(?i)(<td[^>]*>)\s*Competitor\s*(</td>)", r"\1Name\2", page)
        # итог вида: шапка «PL», места с точкой («1.»)
        page = re.sub(r"(<td[^>]*>)\s*PL\s*(</td>)", r"\1Pl.\2", page)
        page = re.sub(r"(<td[^>]*>)\s*(\d{1,3})\.\s*(</td>)", r"\1\2\3", page)
        # партнёры пары — через перенос строки внутри одной ссылки
        page = re.sub(r"(?is)(<a\b[^>]*>)(.*?)(</a>)",
                      lambda m: m.group(1) + re.sub(r"(?i)\s*<br\s*/?>\s*", " / ", m.group(2)) + m.group(3), page)
    return page


_fetch = net.fetch


def _fetch_norm(url, *a, **k):
    got = _fetch(url, *a, **k)
    return norm_page(got) if isinstance(got, str) and re.search(r"(?i)\.html?$", url.split("?")[0]) else got


def _quiet():
    """Сбор расписания по дороге считает «примечательное», ищет трансляции и пишет архив элементов.
    Прошлым сезонам это не нужно и вредно (facts.json и архив элементов — про нынешний сезон)."""
    net.fetch = _fetch_norm
    rs.segment_facts = lambda *a, **k: None
    rs.total_facts = lambda *a, **k: None
    build.watch_for = lambda *a, **k: None
    build.log = lambda *a: None
    build.CFG = dict(build.CFG, final_by_time=True, podium_from_judges_pdf=True)
    st.parse_entries = lambda u: []  # заявка не нужна: состав прошедшего сегмента — в его протоколе


def _zone_isu(idx):
    """Пояс табло ISU: подпись «UTC +02:00» — смещение на дни турнира (страница выложена тогда же)."""
    walls = [s["start"].replace(tzinfo=None) for c in idx["categories"] for s in c["segments"]
             if isinstance(s.get("start"), dt.datetime)]
    if not walls:
        return idx
    at = max(walls).replace(tzinfo=dt.timezone.utc)
    zone = st.zone_from_label(idx.get("nation"), idx.get("offset"), at, walls)
    if zone is None:
        zone = _only_zone(idx.get("nation"), walls)
    return st.set_zone(idx, zone)


def _only_zone(nation, walls):
    """Пояс страны, если он в ней один: подпись табло бывает чужой (Олимпиада в Пекине подписана
    «UTC +01:00»), а в стране с одним поясом ошибиться нельзя. Поясов несколько — None."""
    from zoneinfo import ZoneInfo
    zones = []
    for name in st._country_zones(st.IOC_ISO.get((nation or "").upper()) or ""):
        try:
            zones.append(ZoneInfo(name))
        except Exception:
            continue
    if not zones or any(len({w.replace(tzinfo=z).utcoffset() for z in zones}) > 1 for w in walls):
        return None
    return zones[0]


def comnet_idx(page, url):
    """index.htm табло comnet (и Swiss Timing без страниц категорий — командный чемпионат) → вид parse_index_page.
    Итог вида у comnet — dataNN90.htm рядом с сегментами dataNN03/05.htm."""
    from zoneinfo import ZoneInfo
    head = st.parse_index_page(page, url)
    old = bf.comnet_index(page, url)
    nation = head.get("nation") or "JPN"
    zone = _only_zone(nation, []) or ZoneInfo("Asia/Tokyo")
    cats = []
    for c in old["categories"]:
        segs = []
        for sg in c["segments"]:
            if not sg["url"]:
                continue
            start = sg["start"].replace(tzinfo=zone) if sg.get("start") else None
            segs.append({"name": sg["name"], "url": sg["url"], "officials": None, "times_pdf": None,
                         "judges_pdf": sg.get("judges_pdf"), "scores_pdf": None, "marks": bool(sg.get("judges_pdf")),
                         "judges_shared": None, **({"start": start} if start else {})})
        if not segs:
            continue
        m = re.search(r"(?i)/data(\d\d)\d\d\.htm$", segs[0]["url"])
        res = url.rsplit("/", 1)[0] + f"/data{m.group(1)}90.htm" if m else None
        cats.append({"name": c["name"], "entries_url": url, "results_url": res, "segments": segs})
    return {"url": url, "name": head.get("name") or "", "city": head.get("city") or "", "nation": nation,
            "venue": "", "offset": None, "zone": zone, "categories": cats,
            "marks": any(sg["marks"] for c in cats for sg in c["segments"])}


def _accept(idx, intl):
    """Категории, которые берём, и как их читать: (категории, как международные)."""
    cats = build.categories_of(idx, intl)
    as_intl = intl
    if not cats and not intl and idx["categories"]:
        cats, as_intl = build.categories_of(idx, True), True  # английская версия табло ФФККР
    if not intl:
        cats = [c for c in cats if not (pp._SKIP_CAT.search(c[0]["name"])
                                        or pp._SKIP_CAT.search(c[0]["name"].translate(pp._HOMO)))]
    return [c for c, _, _ in cats], as_intl


# турниры ISU в Японии: на табло comnet нет ни города, ни пояса
COMNET_CITY = {"gpjpn2018": "Hiroshima", "gpjpn2019": "Sapporo", "gpjpn2020": "Osaka", "gpjpn2021": "Tokyo",
               "gpjpn2022": "Sapporo", "gpjpn2023": "Osaka", "wc2019": "Saitama", "wc2023": "Saitama",
               "wtt2019": "Fukuoka", "wtt2021": "Osaka", "wtt2023": "Tokyo", "wtt2025": "Tokyo",
               "jgpjpn2023": "Osaka"}


def fill_fields(events, cats):
    """Состав старта — из строк протокола сегмента (он полный: стартовый лист прошедшего сегмента
    табло уже не показывает), итоговое место — из итога вида."""
    for c in cats:
        final = {r["name"]: r["place"] for r in (c.get("total") or {}).get("rows") or [] if r.get("place")}
        for sg in c["segments"]:
            cand = [e for e in events if (e["kind"], e["level"], e["seg"]) == (c["kind"], c["level"], sg["code"])
                    and bool(e.get("team")) == bool(c.get("team"))]
            if len(cand) > 1:
                slug = build.slugify(c["name"]) or "x"
                cand = [e for e in cand if e["id"].endswith("-" + slug)] or cand[:1]
            if not cand or not sg.get("rows"):
                continue
            field = []
            for r in sg["rows"]:
                o = {"name": r["name"], "nation": r.get("nation") or ""}
                for k in ("no", "place", "points"):
                    if r.get(k) is not None:
                        o[k] = r[k]
                if r.get("status") == "DSQ":  # дисквалифицирован: места нет, но он выступал
                    o["status"] = "DSQ"
                if final.get(r["name"]):
                    o["final"] = final[r["name"]]
                field.append(o)
            cand[0]["field"] = field
        # тройка турнира — у последнего сегмента вида; на табло comnet её читает только протокол
        t = c.get("total") or {}
        last = [e for e in events if (e["kind"], e["level"]) == (c["kind"], c["level"])
                and build.SEG_ORDER.get(e["seg"]) == 1 and bool(e.get("team")) == bool(c.get("team"))]
        if len(last) == 1 and not last[0].get("total") and t.get("state") == "final" and t.get("complete"):
            top = sorted((r for r in t["rows"] if r.get("place")), key=lambda r: r["place"])[:3]
            if len(top) == 3:
                last[0]["total"] = [{"place": r["place"], "name": r["name"], "nation": r.get("nation") or "",
                                     "points": r["points"]} for r in top]


def unheld(events, cats):
    """Старты, которых не было: на табло категория есть, а сегмент пустой (ни строки, ни мест), хотя в
    других категориях турнира выступили — заявки не набралось. В архиве им места нет: «завершён, итогов
    нет» о том, что не проходило, — неправда. → id таких стартов."""
    if not any(sg.get("rows") for c in cats for sg in c["segments"]):
        return set()
    empty = {(c["kind"], c["level"], sg["code"], bool(c.get("team"))) for c in cats for sg in c["segments"]
             if not sg.get("rows") and sg.get("state") != "final"}
    return {e["id"] for e in events if (e["kind"], e["level"], e["seg"], bool(e.get("team"))) in empty
            and not e.get("field") and not e.get("podium")}


def prune_unheld(past_dir=None, proto_dir=None):
    """Убрать из файлов месяцев старты, которых не было (unheld), по их файлам протокола. → сколько."""
    past_dir = past_dir or PAST_DIR
    proto_dir = proto_dir or PROTO_DIR
    gone = 0
    for path in sorted(glob.glob(os.path.join(past_dir, "[0-9][0-9][0-9][0-9]-[0-9][0-9].json"))):
        month = os.path.basename(path)[:-5]
        events, tours = load_month(month, past_dir)
        drop = set()
        for proto in {e.get("proto") for e in events if e.get("proto")}:
            doc = P.load_doc(os.path.join(proto_dir, proto))
            if doc:
                drop |= unheld([e for e in events if e.get("proto") == proto], doc["categories"])
        if not drop:
            continue
        keep = [e for e in events if e["id"] not in drop]
        gone += len(events) - len(keep)
        doc = {"v": V, "month": month, "events": keep}
        if tours:
            doc["tournaments"] = tours
        write_json(path, doc)
    write_index(past_dir)
    return gone


def tid_of(item):
    if item["src"] == "ISU":
        return "isu:" + item["code"]
    return "fsr:" + (item.get("page") or item["url"]).rstrip("/").rsplit("/", 1)[-1]


def tournament(item, now=None):
    """Один турнир прошлых лет → {url, tid, events, proto, note}. events и proto — с именами как на табло."""
    now = now or dt.datetime.now(dt.timezone.utc)
    url, intl = item["url"], item["intl"]
    out = {"url": url, "tid": tid_of(item), "src": item["src"], "ev": item["ev"], "start": item["start"],
           "end": item["start"], "venue": "", "intl": intl, "events": [], "proto": None, "note": None}
    try:
        page = net.fetch(url)
    except net.FetchError as ex:
        out["note"] = f"index: {ex}"
        return out
    old = False
    try:
        idx = st.parse_index_page(page, url)
        extra = bf.scores_links(page, url)
        if not idx["categories"]:
            idx, old = comnet_idx(page, url), True
    except Exception as ex:
        out["note"] = f"разбор index: {ex!r}"
        return out
    if not idx["categories"]:
        out["note"] = "категорий на табло нет"
        return out
    keep, as_intl = _accept(idx, intl)
    if not keep:
        out["note"] = "нет наших категорий"
        return out
    idx["categories"] = keep
    for c in idx["categories"]:
        for s in c["segments"]:
            s["times_pdf"] = None    # время выхода каждого у прошедшего старта не показываем
            s["officials"] = None    # бригаду без оценок судей не показываем
            pdf = s.get("judges_pdf") or extra.get(s["url"].lower())
            if pdf:
                # «…_Scores.pdf» у ISU 2018/19 и у ФФККР — тот же «Judges Details per Skater»
                s["judges_pdf"], s["scores_pdf"], s["marks"] = pdf, None, True
    idx["marks"] = any(s["marks"] for c in idx["categories"] for s in c["segments"])
    venue = ""
    if intl:
        if not old:
            idx = _zone_isu(idx)
        city = idx.get("city") or COMNET_CITY.get(item.get("code") or "", "")
        if city:
            venue = build.intl_venue(city, idx.get("nation") or "", "")
    else:
        city = place = ""
        if item.get("page"):
            try:
                t = fsr.tournament(item["page"])
                if t.get("end"):
                    out["end"] = t["end"].isoformat()
                parts = (t.get("place") or "").split(",", 1)
                city, place = parts[0], (parts[1] if len(parts) > 1 else "")
            except net.FetchError:
                pass
        city = city or idx.get("city") or ""
        venue = build.ru_venue(city, place) if city else ""
        zone = build.tz_known(city)
        idx = st.set_zone(idx, zone) if zone else idx
    out["venue"] = venue
    protos = {}
    try:
        events = build.from_swisstiming(
            idx, tid=out["tid"], tournament=item["ev"], venue=venue, intl=as_intl, broadcast=[],
            names=RawNames(), ours_rule=lambda n, c: False, protos=protos, now=now,
            proto_dir=os.path.join(PAST_DIR, ".none"))
    except Exception as ex:
        out["note"] = f"разбор турнира: {ex!r}"
        return out
    for ev in events:
        ev["intl"] = intl
        ev.pop("_old_id", None)
    p = protos.get(out["tid"])
    if p and p["categories"]:
        fill_fields(events, p["categories"])
        drop = unheld(events, p["categories"])
        events = [e for e in events if e["id"] not in drop]
        doc = P.make_doc(tid=out["tid"], tournament=item["ev"], src=idx["url"], marks=p["marks"],
                         categories=p["categories"], now=now, team=p.get("team"))
        out["proto"] = slim_doc(doc)
        errs = [e for u, e in p["fetcher"].errors]
        if errs:
            out["note"] = f"не прочитано адресов: {len(errs)}"
    out["events"] = [slim_event(ev) for ev in events]
    return out


def slim_event(ev):
    """Событие для архива: без полей нынешнего дня; состав — имя, страна, место, баллы, итоговое место."""
    out = {k: v for k, v in ev.items() if k not in DROP and not k.startswith("_")}
    out["field"] = [{k: o[k] for k in ("name", "nation", "no", "place", "points", "final", "status") if o.get(k) not in (None, "")}
                    for o in ev.get("field", [])]
    return out


def slim_doc(doc):
    """Протокол для архива: без оценок отдельных судей и бригады; прошедший сегмент — окончательный."""
    for c in doc["categories"]:
        for sg in c["segments"]:
            sg.pop("panel", None)
            if sg.get("rows") and sg.get("state") in ("provisional", "in_progress"):
                sg["state"], sg["basis"] = "final", sg.get("basis") or "time"
            for r in sg.get("rows") or []:
                for e in r.get("els") or []:
                    e.pop("j", None)
                for e in r.get("comp") or []:
                    e.pop("j", None)
        t = c.get("total")
        if t and t.get("rows") and t.get("state") == "provisional" and t.get("complete"):
            t["state"] = "final"
    return doc


# ---------------------------------------------------------------- прогон

def load_items(src=None, folder=None, before=None):
    """Турниры из списков добора (backfill discover), раньше начала нынешнего сезона."""
    folder = folder or bf.DIR
    before = before or build.CFG["season_start"]
    items = []
    for name, label in (("isu.json", "ISU"), ("fsr.json", "ФФККР")):
        if src and src != label:
            continue
        try:
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                items += json.load(f)
        except (OSError, ValueError):
            log(f"нет списка {name}: сначала python3 -m scraper.backfill discover")
    seen, out = set(), []
    for it in sorted(items, key=lambda i: (i["start"], i["url"])):
        if it["start"] >= before or it["url"] in seen:
            continue
        seen.add(it["url"])
        out.append(it)
    return out


def read_part(path):
    """Строки части: по турниру на строку. Битую последнюю строку (прогон оборвали) пропускаем."""
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        pass
    return out


def run(items, path, limit=None, retry=False):
    """retry — турниры, от которых в части нет стартов (табло не ответило, формат), берём заново."""
    _quiet()
    done = {r["url"] for r in read_part(path) if r["events"] or not retry}
    todo = [it for it in items if it["url"] not in done]
    if limit:
        todo = todo[:limit]
    log(f"турниров: {len(items)}, уже есть: {len(done)}, берём: {len(todo)}")
    with open(path, "a", encoding="utf-8") as f:
        for n, it in enumerate(todo, 1):
            rec = tournament(it)
            f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
            f.flush()
            log(f"  [{n}/{len(todo)}] {it['start']} {it['ev']}: стартов {len(rec['events'])}"
                + (f" — {rec['note']}" if rec["note"] else ""))


# ---------------------------------------------------------------- слияние в сайт

def _cyr_names(recs):
    for r in recs:
        for ev in r["events"]:
            for o in ev.get("field", []):
                if nm.is_cyr(o["name"]):
                    yield o["name"]


def respell(rec, sp):
    """Имена турнира — как в приложении."""
    for ev in rec["events"]:
        intl = ev["intl"]
        for key in ("field", "podium", "total"):
            if key == "total" and ev.get("team"):
                continue  # командный зачёт — страны, а не люди
            for o in ev.get(key) or []:
                if o.get("nation") in ALSO_RUS:
                    o["nation"] = ALSO_RUS[o["nation"]]
                o["name"] = sp.spell(o["name"], o.get("nation") or "", intl)
    doc = rec.get("proto")
    if doc:
        intl = any(ev["intl"] for ev in rec["events"])
        for c in doc["categories"]:
            for rows in [sg.get("rows") or [] for sg in c["segments"]] + [(c.get("total") or {}).get("rows") or []]:
                for r in rows:
                    if r.get("nation") in ALSO_RUS:
                        r["nation"] = ALSO_RUS[r["nation"]]
                    r["name"] = sp.spell(r["name"], r.get("nation") or "", intl)


def month_of(ev):
    return ev["start"][:7]


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = json.dumps(obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    try:
        with open(path, "rb") as f:
            if f.read() == data:
                return False
    except OSError:
        pass
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return True


def load_month(month, past_dir=None):
    """Файл месяца: (старты, турниры без расписания)."""
    try:
        with open(os.path.join(past_dir or PAST_DIR, month + ".json"), encoding="utf-8") as f:
            d = json.load(f)
        return (d.get("events") or [], d.get("tournaments") or []) if d.get("v") == V else ([], [])
    except (OSError, ValueError):
        return [], []


def _richer(a, b):
    """Из двух записей одного старта — та, где больше известно (места, итог)."""
    def score(e):
        return (len(e.get("podium") or []), len(e.get("total") or []),
                sum(1 for o in e.get("field") or [] if o.get("place")), len(e.get("field") or []), bool(e.get("proto")))
    return a if score(a) >= score(b) else b


def _months(start, end):
    """Месяцы, которые задевает турнир: «2019-12», «2020-01»."""
    a, b = dt.date.fromisoformat(start), dt.date.fromisoformat(end or start)
    out = []
    y, m = a.year, a.month
    while (y, m) <= (b.year, b.month) and len(out) < 3:
        out.append(f"{y}-{m:02d}")
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return out


def put_events(events, tournaments=(), past_dir=None, now=None):
    """Старты и турниры без расписания → файлы месяцев и index.json. Запись с тем же id заменяется
    более полной; турнир, у которого появились старты со временем, из «без расписания» уходит.
    → число записанных файлов."""
    past_dir = past_dir or PAST_DIR
    by_month = {}
    for ev in events:
        by_month.setdefault(month_of(ev), ([], []))[0].append(ev)
    for t in tournaments:
        for m in _months(t["start"], t["end"]):
            by_month.setdefault(m, ([], []))[1].append(t)
    written = 0
    for month, (evs, tours) in by_month.items():
        old_events, old_tours = load_month(month, past_dir)
        have = {e["id"]: e for e in old_events}
        for ev in evs:
            have[ev["id"]] = _richer(ev, have[ev["id"]]) if ev["id"] in have else ev
        body = sorted(have.values(), key=lambda e: (e["start"], e["title"]))
        timed = {e["tid"] for e in body}
        bare = {t["tid"]: t for t in [*old_tours, *tours] if t["tid"] not in timed}
        doc = {"v": V, "month": month, "events": body}
        if bare:
            doc["tournaments"] = sorted(bare.values(), key=lambda t: (t["start"], t["name"]))
        written += write_json(os.path.join(past_dir, month + ".json"), doc)
    write_index(past_dir, now)
    return written


def write_index(past_dir=None, now=None):
    """index.json: какие месяцы есть в архиве и сколько в них стартов (турнир без расписания — один)."""
    past_dir = past_dir or PAST_DIR
    months = {}
    for path in sorted(glob.glob(os.path.join(past_dir, "[0-9][0-9][0-9][0-9]-[0-9][0-9].json"))):
        m = os.path.basename(path)[:-5]
        evs, tours = load_month(m, past_dir)
        if evs or tours:
            months[m] = len(evs) + len(tours)
    if not months:
        return
    prev = None
    try:
        with open(os.path.join(past_dir, "index.json"), encoding="utf-8") as f:
            prev = json.load(f)
    except (OSError, ValueError):
        pass
    doc = {"v": V, "first": min(months), "last": max(months), "months": months}
    if prev and {k: prev.get(k) for k in doc} == doc:
        return
    doc["built"] = (now or dt.datetime.now(build.MSK)).replace(microsecond=0).isoformat()
    write_json(os.path.join(past_dir, "index.json"), doc)


def merge(paths, past_dir=None, proto_dir=None):
    """Части прогона → site/data/past. → сводка."""
    past_dir = past_dir or PAST_DIR
    proto_dir = proto_dir or os.path.join(past_dir, "protocols")
    recs = {}
    for p in paths:
        for r in read_part(p):
            old = recs.get(r["url"])
            if old is None or len(r["events"]) >= len(old["events"]):
                recs[r["url"]] = r
    recs = list(recs.values())
    sp = Speller(_cyr_names(recs))
    events, bare = [], []
    stat = {"tournaments": 0, "events": 0, "unscheduled": 0, "protocols": 0, "bad_protocols": 0, "empty": []}
    for r in recs:
        has_rows = bool(r.get("proto")) and any(sg.get("rows") for c in r["proto"]["categories"] for sg in c["segments"])
        if not r["events"] and not has_rows:
            stat["empty"].append(f"{r['start']} {r['ev']}: {r['note']}")
            continue
        respell(r, sp)
        stat["tournaments"] += 1
        doc = r.get("proto")
        name = None
        if doc:
            errs = P.validate(doc, final_by_time=True)
            if errs:
                stat["bad_protocols"] += 1
                log(f"  ! протокол {r['tid']}: {'; '.join(errs[:3])}")
            else:
                name = P.proto_name(r["tid"])
                P.write_if_changed(os.path.join(proto_dir, name), doc)
                stat["protocols"] += 1
        for ev in r["events"]:
            ev["proto"] = name
            if not name:
                ev.pop("proto")
            events.append(ev)
        if not r["events"] and name:
            # на табло нет времени сегментов: в календарь турнир встаёт днями проведения, как «без
            # расписания», а итоги открываются протоколом
            kinds = sorted({c["kind"] for c in doc["categories"] if any(sg.get("rows") for sg in c["segments"])})
            bare.append({"tid": r["tid"], "name": r["ev"], "start": r["start"], "end": r.get("end") or r["start"],
                         "venue": r.get("venue") or "", "intl": bool(r.get("intl")), "proto": name, "kinds": kinds})
    stat["events"], stat["unscheduled"] = len(events), len(bare)
    put_events(events, bare, past_dir)
    return stat


def fold(events, past_dir=None, now=None):
    """Старты, которые сбор перестаёт держать (сезон сменился), — в архив. Вызывает build.main.
    Протокол остаётся там, где лежал: у этих стартов proto указывает на site/data/protocols."""
    done = [slim_event(dict(e)) for e in events if e.get("podium") or e.get("field")]
    for e in done:
        e.pop("proto", None)  # файл протокола нынешнего сезона сбор уберёт вместе со стартом
    return put_events(done, (), past_dir, now) if done else 0


# ---------------------------------------------------------------- история выступлений

def loose(name):
    """«Мягкий» ключ имени россиянина для склейки написаний одного человека: Victoria/Viktoria,
    Данил/Даниил, Абдулина/Абдуллина, ё/е. Только для россиян и белорусов (см. canonical): у иностранцев
    латиница одна. Слова отсортированы, как в nm.key; пары — по людям."""
    parts = []
    for one in name.split(" / "):
        t = nm.key(one).replace("ck", "k").replace("ch", "#").replace("c", "k").replace("#", "ch")
        t = t.replace("kh", "h").replace("y", "i").replace("j", "i").replace("iy", "i").replace("ie", "e")
        parts.append(re.sub(r"(.)\1+", r"\1", t))
    return " / ".join(sorted(parts))


def canonical(names):
    """{имя: страна} → {имя: общее написание} для россиян и белорусов, у которых одно лицо записано
    по-разному (латиница ISU и кириллица ФФККР, «Пётр» и «Петр»). Общее — лучшее по nm.spelling_rank,
    при равенстве — то, что встречается чаще (по числу записей, если names — {имя: (страна, записей)})."""
    groups = {}
    for n, v in names.items():
        c, cnt = v if isinstance(v, tuple) else (v, 0)
        if c in OURS:
            groups.setdefault((loose(n), "BLR" if c in ("BLR", "AIN1") else "RUS"), []).append((n, cnt))
    out = {}
    for g in groups.values():
        if len(g) < 2:
            continue
        best = min(g, key=lambda x: (nm.spelling_rank(x[0]), -x[1], x[0]))[0]
        for n, _ in g:
            if n != best:
                out[n] = best
    return out


def bucket(name):
    """Номер файла истории по имени: тот же расчёт в приложении (history.dart)."""
    k = name.lower().replace("ё", "е").strip()
    return zlib.crc32(k.encode("utf-8")) % BUCKETS


def _skates(doc):
    """Прокаты из файла протокола: (имя, запись). Запись — по строке на выступление в сегменте."""
    for c in doc.get("categories") or []:
        totals = {r["name"]: r for r in (c.get("total") or {}).get("rows") or []}
        for sg in c.get("segments") or []:
            rows = [r for r in sg.get("rows") or [] if r.get("place")]
            if not rows or sg.get("state") != "final":
                continue
            day = (sg.get("start") or "")[:10]
            for r in rows:
                rec = {"d": day, "t": doc["tid"], "k": c["kind"], "l": c["level"], "s": sg["code"],
                       "pl": r["place"], "of": len(rows), "pts": r.get("points"), "c": r.get("nation") or ""}
                if c.get("team"):
                    rec["tm"] = 1  # командный турнир: тот же сегмент, что личный, — но другой старт
                for k in ("tes", "pcs", "ded"):
                    if r.get(k) is not None:
                        rec[k] = r[k]
                if "bv" in r:
                    rec["bv"] = r["bv"]
                if r.get("els"):
                    # элемент: код, отметки, GOE — этого хватает для «сколько раз чисто»; базу и оценку
                    # элемента показывает сам протокол
                    rec["els"] = [[e["n"], e.get("info") or "", e["g"]] for e in r["els"]]
                t = totals.get(r["name"])
                if t and t.get("place"):
                    rec["tp"], rec["tpts"] = t["place"], t.get("points")
                yield r["name"], rec


def athletes(past_proto=None, live_proto=None, h_dir=None):
    """История выступлений по спортсменам из протоколов архива и нынешнего сезона → site/h/<xx>.json.

    Файл: {v, t: {tid: [турнир, международный, в архиве]}, a: {имя: {r: [прокат, …], x?}}} — имя как
    в приложении, прокаты по дате. Прокат: d (день; пусто — на табло не было времени сегмента),
    t (турнир), k, l, s (вид, уровень, сегмент), pl (место), of (участников), pts, tes, pcs, ded,
    bv (сумма баз), els [[код, отметки, GOE]], tp и tpts (место и баллы в итоге вида), c (страна),
    tm (1 — командный турнир).
    День сегмента без времени на табло — день начала турнира из архива месяцев (dates).
    Двое с одним именем в одном сегменте — тёзки: у имени x: true, статистику по нему приложение
    не считает."""
    past_proto = past_proto or PROTO_DIR
    live_proto = live_proto or build.PROTO_DIR
    h_dir = h_dir or H_DIR
    who, twins, tours = {}, set(), {}
    bare = _bare_days(os.path.dirname(past_proto))
    for folder, past in ((past_proto, True), (live_proto, False)):
        for path in sorted(glob.glob(os.path.join(folder, "*.json"))):
            if os.path.basename(path) == P.STATUS_FILE:
                continue
            doc = P.load_doc(path)
            if not doc or (not past and doc["tid"] in tours):
                continue
            intl = not doc["tid"].startswith(("fsr:", "ffkm:", "samara:"))
            seen = set()
            for name, rec in _skates(doc):
                k = (name, rec["k"], rec["l"], rec["s"], rec.get("tm", 0))  # командный старт — не тёзка личного
                if k in seen:
                    twins.add(name)
                seen.add(k)
                if not rec["d"]:
                    rec["d"] = bare.get(doc["tid"], "")
                tours[doc["tid"]] = [doc["tournament"], int(intl), int(past)]
                who.setdefault(name, []).append(rec)
    def nation(recs):
        c = collections.Counter(r["c"] for r in recs if r.get("c") and r["t"].startswith("isu:")).most_common(1)
        return c[0][0] if c else ("RUS" if any(not r["t"].startswith("isu:") for r in recs) else "")

    # одно лицо под двумя написаниями — одной записью под лучшим написанием
    canon = canonical({n: (nation(r), len(r)) for n, r in who.items()})
    merged = {}
    for name, recs in who.items():
        merged.setdefault(canon.get(name, name), []).extend(recs)
    twins = {canon.get(n, n) for n in twins}
    files = {}
    for name, recs in merged.items():
        recs.sort(key=lambda r: (r["d"], r["s"] in ("ПП", "ПТ")))
        files.setdefault(bucket(name), {})[name] = {"r": recs, **({"x": True} if name in twins else {})}
    who = merged
    written = 0
    for b in range(BUCKETS):
        people = files.get(b, {})
        used = {r["t"] for a in people.values() for r in a["r"]}
        written += write_json(os.path.join(h_dir, f"{b:02x}.json"),
                              {"v": V, "t": {t: tours[t] for t in sorted(used)}, "a": people})
    return {"athletes": len(who), "skates": sum(len(v) for v in who.values()), "twins": len(twins), "written": written}


DOMESTIC = ("fsr:", "ffkm:", "samara:")
INTL = ("isu:",)
DOMESTIC_SRC = {"fsr:": "ФФККР", "ffkm:": "ФФКМ"}  # прочие — «протоколы турниров» (feats.OTHER)
SEG_PB = {"КП": "sp", "РТ": "sp", "ПП": "fs", "ПТ": "fs"}


def domestic_bests(past_proto=None, live_proto=None):
    """Лучшие результаты на российских стартах: archive_bests по протоколам ФФККР и регионов."""
    return archive_bests(DOMESTIC, past_proto, live_proto)


def intl_bests(past_proto=None, live_proto=None):
    """Лучшие результаты на международных стартах (протоколы ISU в архиве и в этом сезоне) — для тех, у
    кого нет биографии ISU со своими личными рекордами."""
    return archive_bests(INTL, past_proto, live_proto)


def archive_bests(prefixes, past_proto=None, live_proto=None):
    """Лучшие результаты по протоколам с тидом на prefixes (архив и этот сезон):
    ({ключ имени (names.key): {"total"|"sp"|"fs": {pts, ev, d, src}}}, сезон самого раннего протокола «2018/19»).
    Тёзки (двое с одним именем в одном сегменте) не считаются: чей результат — не различить. Только
    окончательные сегменты. Сезон нужен приложению: раньше него протоколов нет, и лучшее «с него» —
    не то же, что лучшее за всю карьеру."""
    past_proto = past_proto or PROTO_DIR
    live_proto = live_proto or build.PROTO_DIR
    best, twins, seen_tids, first = {}, set(), set(), ""
    bare = _bare_days(os.path.dirname(past_proto))
    for folder in (past_proto, live_proto):
        for path in sorted(glob.glob(os.path.join(folder, "*.json"))):
            if os.path.basename(path) == P.STATUS_FILE:
                continue
            doc = P.load_doc(path)
            if not doc or not doc["tid"].startswith(prefixes) or doc["tid"] in seen_tids:
                continue
            seen_tids.add(doc["tid"])
            src = DOMESTIC_SRC.get(doc["tid"].split(":")[0] + ":", "ISU" if doc["tid"].startswith("isu:") else "протоколы")
            seen, whole = set(), {}

            def put(name, seg, pts, day):
                try:
                    v = float(pts) if pts else None
                except ValueError:
                    return
                mine = best.setdefault(nm.key(name), {})
                if v is not None and (seg not in mine or v > float(mine[seg]["pts"])):
                    mine[seg] = {"pts": f"{v:.2f}", "ev": doc["tournament"], "d": day, "src": src}

            for name, rec in _skates(doc):
                k = (name, rec["k"], rec["l"], rec["s"], rec.get("tm", 0))
                if k in seen:
                    twins.add(nm.key(name))
                seen.add(k)
                day = rec["d"] or bare.get(doc["tid"], "")
                if day and (not first or day < first):
                    first = day
                seg = SEG_PB.get(rec["s"])
                if not seg:
                    continue
                put(name, seg, rec.get("pts"), day)
                w = whole.setdefault((name, rec["k"], rec["l"]), {})
                w[seg] = rec.get("pts")
                if seg == "fs":
                    w["tpts"], w["d"] = rec.get("tpts"), day
            # сумма — только если она и есть короткая плюс произвольная этого турнира: в турнире из одной
            # произвольной итог равен ей, а у младшего возраста в итог входят ещё ОФП и СФП
            for (name, _, _), w in whole.items():
                try:
                    ok = abs(float(w["sp"]) + float(w["fs"]) - float(w["tpts"])) < 0.015
                except (KeyError, TypeError, ValueError):
                    ok = False
                if ok:
                    put(name, "total", w["tpts"], w["d"])
    for k in twins:
        best.pop(k, None)
    since = ""
    if first:
        y = int(first[:4]) - (1 if int(first[5:7]) < 7 else 0)
        since = f"{y}/{(y + 1) % 100:02d}"
    return best, since


KIND_LETTER = {"women": "w", "men": "m", "pairs": "p", "dance": "d"}


def roster(h_dir=None):
    """Все из истории выступлений, кого стоит держать в справочнике: выступавшие на международных стартах
    ISU и взрослые российских стартов (детские и юношеские региональные — нет). → [{n, c, k, was, y}]:
    k пусто (в этом сезоне архив о нём не знает), was — виды последнего сезона (заглавная — юниоры), y —
    этот сезон («2021/22»), c — страна по международным стартам, у россиян без них — RUS. Тёзки (x) не
    берутся: чей результат — не различить. Справочник сводит эти имена с прежними: русское написание
    побеждает латинское, так что Медведева из справочника по ISU и из архива — один человек."""
    h_dir = h_dir or H_DIR
    out = []
    for path in sorted(glob.glob(os.path.join(h_dir, "*.json"))):
        try:
            with open(path, encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        for name, a in (d.get("a") or {}).items():
            rs = a.get("r") or []
            if a.get("x") or not rs:
                continue
            isu = [r for r in rs if r["t"].startswith("isu:")]
            if not isu and not any(r["l"] == "senior" for r in rs):
                continue
            nat = collections.Counter(r["c"] for r in isu if r.get("c")).most_common(1)
            c = nat[0][0] if nat else ("RUS" if any(not r["t"].startswith("isu:") for r in rs) else "")
            dated = [r for r in rs if r.get("d")]
            if not dated:
                continue
            last = max(r["d"] for r in dated)
            y = int(last[:4]) - (1 if int(last[5:7]) < 7 else 0)
            season = f"{y}/{(y + 1) % 100:02d}"
            letters = {KIND_LETTER[r["k"]].upper() if r["l"] == "junior" else KIND_LETTER[r["k"]]
                       for r in dated if r.get("k") in KIND_LETTER and
                       int(r["d"][:4]) - (1 if int(r["d"][5:7]) < 7 else 0) == y}
            out.append({"n": name, "c": c, "k": "", "was": "".join(sorted(letters)), "y": season})
    return out


def with_roster(people, roster_names=None):
    """Справочник + все из архива: (people, canon). Кто уже есть — остаётся как есть (виды, профиль), у него
    только подтягиваются виды и сезон архива, если своих нет; новые добавляются (k пусто — в этом сезоне
    не выступали). Написания одного человека сводятся к лучшему (canonical): «Evgenia Medvedeva» из
    справочника ISU и «Евгения Медведева» из архива — один человек, и нажатие на её имя в старте архива
    открывает профиль. canon — {прежнее имя: общее} для остального сборщика (поиск, фото)."""
    from . import keep as kp
    ros = roster() if roster_names is None else roster_names
    canon = canonical({**{p["n"]: (p.get("c", ""), 0) for p in people}, **{r["n"]: (r["c"], 1) for r in ros}})
    same = lambda p: (nm.key(p["n"]), p.get("c", ""))
    ren = [dict(p, n=canon.get(p["n"], p["n"])) for p in people]
    ros = [dict(r, n=canon.get(r["n"], r["n"])) for r in ros]
    merged = kp.merge_named(ren, ros, "n", same=same, rank=nm.spelling_rank)
    by = {same(r): r for r in ros}
    for p in merged:
        r = by.get(same(p))
        if r and not p.get("k") and not p.get("was"):
            p["was"], p["y"] = r["was"], r["y"]
    return merged, canon


def _bare_days(past_dir):
    """{турнир без времени сегментов: день начала} из файлов месяцев."""
    out = {}
    for path in glob.glob(os.path.join(past_dir, "[0-9][0-9][0-9][0-9]-[0-9][0-9].json")):
        for t in load_month(os.path.basename(path)[:-5], past_dir)[1]:
            out.setdefault(t["tid"], t["start"])
    return out


# ---------------------------------------------------------------- запуск

def main(argv=None):
    ap = argparse.ArgumentParser(description="Архив прошлых сезонов")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--src", choices=["ISU", "ФФККР"])
    r.add_argument("--shard")
    r.add_argument("--limit", type=int)
    r.add_argument("--dir")
    r.add_argument("--retry", action="store_true")
    r.add_argument("--out", required=True)
    m = sub.add_parser("merge")
    m.add_argument("parts", nargs="+")
    sub.add_parser("athletes")
    a = ap.parse_args(argv)
    if a.cmd == "run":
        items = load_items(a.src, a.dir)
        if a.shard:
            items = bf.shard(items, a.shard)
        run(items, a.out, a.limit, a.retry)
    elif a.cmd == "merge":
        stat = merge(a.parts)
        log(json.dumps({k: v for k, v in stat.items() if k != "empty"}, ensure_ascii=False))
        for e in stat["empty"]:
            log("  без стартов:", e)
        log(json.dumps(athletes(), ensure_ascii=False))
    else:
        log(json.dumps(athletes(), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
