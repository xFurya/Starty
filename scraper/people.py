"""Справочник спортсменов для поиска в фильтрах и уведомлениях.

Кто в нём:
  • россияне от КМС и выше — все, кто выступал на всероссийских стартах ФФККР
    за этот и прошлый сезон (категории «МС» и «КМС»; разряды ниже не берём);
  • все, кто выступал на международных стартах ISU за этот и прошлый сезон, —
    по сезонной статистике ISU (лучшие оценки сезона, туда попадает каждый,
    у кого есть оценка на турнире ISU).

Фото — там, где оно действительно есть: сборная ФФККР, портреты ISU (заявки
турниров и общий список фигуристов ISU), Викиданные (по номеру ISU). Не нашлось —
фото нет, а не чужое.

Протоколы прошедших стартов не меняются, поэтому разобранное копится в
data/people.json и в следующий раз не скачивается.
"""
import datetime as dt
import html
import json
import os
import re
import time

from . import isu
from . import names as nm
from . import net
from . import swisstiming as st

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "data", "people.json")
FSR = "https://fsrussia.ru"
STAT = "https://www.isuresults.com/isujsstat/"
OURS = {"RUS", "AIN2", "BLR", "AIN1", "AIN"}
KINDS = {"w": "women", "m": "men", "p": "pairs", "d": "dance"}
_SINGLES = {"men", "women"}
# сколько страниц раздела «Соревнования» листать за сбор (по 10 турниров; конец — пустая страница)
MAX_PAGES = 200
# Страницу турнира ФФККР заводит задолго до старта, а ссылку на табло ставит к самому старту.
# Страница, прочитанная без ссылки, перечитывается: за WAIT_BEFORE дней до начала и ещё WAIT_AFTER
# после конца. Без этого турниры текущего сезона не попадали в справочник вовсе.
WAIT_BEFORE = 3
WAIT_AFTER = 45
# у страниц, прочитанных раньше, дат в кэше нет: их перечитываем понемногу, свежие по адресу первыми
RECHECK_BUDGET = 60
# Вид спорта «открыт» в текущем сезоне, когда в нём уже выступает не меньше OPEN_MIN человек и не меньше
# OPEN_SHARE от прошлогоднего числа: тогда отсутствие человека в нём что-то значит. Пока сезон в этом
# классе (страна, вид, взрослые/юниоры) не раскачался, прошлогодний вид остаётся текущим.
OPEN_MIN = 5
OPEN_SHARE = 0.5
# версия разбора протоколов: при смене разобранное считается заново
RULES = 4


def _load():
    try:
        with open(CACHE, encoding="utf-8") as f:
            c = json.load(f)
    except (OSError, ValueError):
        c = {}
    c.setdefault("pages", {})    # страница турнира → адрес табло или ""
    c.setdefault("dates", {})    # страница турнира → [начало, конец] (ГГГГ-ММ-ДД или "")
    c.setdefault("results", {})  # адрес табло → [[имя, вид]] (только закончившиеся)
    if c.get("v") != RULES:
        c["results"] = {}
        c["v"] = RULES
    return c


def _save(c):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(CACHE, "w", encoding="utf-8") as f:
        json.dump(c, f, ensure_ascii=False, indent=0, sort_keys=True)


def seasons(season_start):
    """«2627» и «2526» для сезона, начавшегося в 2026-м."""
    y = int(season_start[:4]) % 100
    return [f"{y:02d}{y + 1:02d}", f"{y - 1:02d}{y:02d}"]


# ---------------------------------------------------------------- россияне

# Адреса страниц ФФККР набраны латиницей (lyubitel, sinkhron, balet…), названия — кириллицей: ищем в обоих
_SKIP_TOUR = re.compile(
    r"любител|синхрон|мальчик|девоч|межрегион|фестивал|спортивн\w* бал|балет"
    r"|lyubit|sinkhr|sinhr|synchr|balet|ballet|festival|mezhregion|mezhreg",
    re.I,
)
# «Класс I–III», «Пре-бронза», «Молодежный класс» — любительские, в справочнике спортсменов им не место
_SKIP_CAT = re.compile(r"разряд|юношеск|мальчик|девоч|синхрон|команд|любител|новичк|basic|novice|класс|бронз", re.I)


# латинские буквы, которыми на табло ФФККР бывают набраны русские слова («Mужчины», «Жeнщины»)
_HOMO = str.maketrans("AaBEeKMHOoPpCcTXxy", "АаВЕеКМНОоРрСсТХху")


def level_of_category(name):
    """Юниоры, юниорки, девушки, юноши и КМС — юниорский уровень; МС — взрослый."""
    n = name.translate(_HOMO).lower()
    if re.search(r"юниор|юнош|девушк", n):
        return "junior"
    if re.search(r"\bкмс\b", n) and not re.search(r"(?<!к)\bмс\b", n):
        return "junior"
    return "senior"


def kind_of_category(name):
    n = name.translate(_HOMO).lower()
    if "пар" in n:
        return "pairs"
    if "танц" in n:
        return "dance"
    if re.search(r"женщин|девушк|юниорк", n):
        return "women"
    if re.search(r"мужчин|юноши|юниор", n):
        return "men"
    return None


def _tournament_links(page):
    return [x for x in dict.fromkeys(re.findall(r'href="(/sorevnovaniya/sorevnovaniya/[^"#?]+)"', page))
            if not re.search(r"/(page-\d+|rss|atom)$", x)]


def _day(s):
    try:
        return dt.date.fromisoformat(s)
    except (TypeError, ValueError):
        return None


def recheck(links, known, dates, today):
    """Страницы турниров без табло, которые пора перечитать (см. WAIT_BEFORE). С известными датами —
    в окне вокруг турнира; без дат — не больше RECHECK_BUDGET за сбор."""
    due, blind = [], []
    for l in links:
        if known.get(l) != "" or _SKIP_TOUR.search(l.replace("-", " ")):
            continue
        d = dates.get(l)
        if d is None:
            blind.append(l)
            continue
        start, end = _day(d[0]), _day(d[1])
        if start and end and start - dt.timedelta(days=WAIT_BEFORE) <= today <= end + dt.timedelta(days=WAIT_AFTER):
            due.append(l)
    blind.sort(key=lambda l: max(re.findall(r"20\d\d", l) or ["0"]), reverse=True)
    return due + blind[:RECHECK_BUDGET]


def _gone(e):
    """Страницы нет и не будет (404, 410) — это не сбой связи, повторять незачем."""
    return e.kind == "http" and e.status in (404, 410)


def russians(cache, season_codes, log=print, today=None, miss=None):
    """[(имя по-русски как в протоколе, вид, уровень, сезон)] со всех всероссийских стартов этих сезонов.
    miss — сюда пишется [(что не прочиталось, сезон или None)]: с пропуском список сезона неполон,
    и по нему нельзя судить, что человек в этом сезоне не выступал."""
    from . import fsr
    today = today or dt.datetime.now(dt.timezone.utc).date()
    miss = [] if miss is None else miss
    known, dates = cache["pages"], cache.setdefault("dates", {})
    listed = {}
    for n in range(MAX_PAGES):
        try:
            listing = net.fetch(f"{FSR}/sorevnovaniya?start={n * 10}")
        except net.FetchError as e:
            log("  ! список соревнований ФФККР:", e)
            miss.append(("список соревнований", None))
            break
        links = _tournament_links(listing)
        if not links:
            break
        # листаем весь раздел: старые турниры на последних страницах, и порядок дат не гарантирован
        listed.update(dict.fromkeys(links))
    fresh_pages = found = 0
    again = recheck(listed, known, dates, today)
    for l in [x for x in listed if x not in known] + again:
        try:
            t = fsr.tournament(FSR + l)
        except net.FetchError as e:
            log("  ! страница турнира ФФККР:", FSR + l, e)
            if not _gone(e):
                miss.append((l, None))
            continue
        res = t["results"] or ""
        if l in known:
            found += bool(res)
        else:
            fresh_pages += 1
        known[l] = res
        dates[l] = [t["start"].isoformat() if t.get("start") else "", t["end"].isoformat() if t.get("end") else ""]
    out = []
    for page, res in known.items():  # noqa: E501
        if not res or _SKIP_TOUR.search(f"{page.replace('-', ' ')} {res}"):
            continue
        m = re.search(r"/results/(\d{4})/", res)
        if not m or m.group(1) not in season_codes:
            continue
        rows = cache["results"].get(res)
        if rows is None:
            try:
                rows = _results(res, log)
            except net.FetchError as e:
                log("  ! табло:", res, e)
                if not _gone(e):
                    miss.append((res, m.group(1)))
                continue
            if rows is None:
                continue
            # в кэш — только закончившийся турнир: до конца заявки ещё меняются
            end = _day((dates.get(page) or ["", ""])[1])
            if not end or today > end:
                cache["results"][res] = rows
        out.extend((n, k, lv, m.group(1)) for n, k, lv in rows)
    # новые сезоны первыми: уровень — по последнему
    out.sort(key=lambda x: x[3], reverse=True)
    log(f"  справочник: россиян с протоколов {len({x[0] for x in out})}; новых страниц турниров {fresh_pages}; "
        f"перечитано без табло {len(again)}, табло появилось у {found}")
    return out


def _results(idx_url, log):
    """[[имя, вид, уровень]] по заявкам категорий КМС и выше; None — табло ещё не готово.
    Не ответила страница категории — FetchError: неполный список в кэш не кладём."""
    try:
        idx = st.parse_index(idx_url)
    except ValueError as e:
        log("  ! табло:", idx_url, e)
        return None
    if not idx.get("categories"):
        return None
    out = []
    for c in idx["categories"]:
        raw = c.get("name") or ""
        name = raw.translate(_HOMO)
        kind = kind_of_category(name)
        level = level_of_category(name)
        if not kind or _SKIP_CAT.search(name) or _SKIP_CAT.search(raw):
            continue
        url = c.get("entries_url") or c.get("results_url")
        if not url:
            continue
        try:
            page = net.fetch(url)
        except net.FetchError as e:
            if not _gone(e):
                raise
            log("  ! протокол категории:", url, e)
            continue
        for cells, _ in st._rows(page):
            vals = [v for v in cells if v]
            if len(vals) >= 2 and re.fullmatch(r"\d+", vals[0]) and nm.is_cyr(vals[1]):
                out.append([entry_name(vals[1]), kind, level])
    return out


_PATRONYMIC = re.compile(r"(вич|вна|ична|инична|ьич)$", re.I)


def entry_name(raw):
    """«Матвей Рубенович ВЕТЛУГИН» → «Матвей ВЕТЛУГИН»; пара — по каждому."""
    parts = []
    for one in raw.split("/"):
        w = one.split()
        w = [x for i, x in enumerate(w) if not (0 < i < len(w) - 1 and _PATRONYMIC.search(x) and not x.isupper())]
        parts.append(" ".join(w))
    return " / ".join(p for p in parts if p)


# ---------------------------------------------------------------- международные

def _stat_rows(path, season=None, miss=None, log=print):
    """Строки сезонной статистики ISU. Страницы сезона ещё нет (404, 410) — пустой список, не сбой;
    любой другой сбой — в miss как (адрес, сезон), тоже пустой список."""
    try:
        page = net.fetch(STAT + path, timeout=40)
    except net.FetchError as e:
        if not _gone(e):
            log("  ! статистика ISU:", path, e)
            if miss is not None:
                miss.append((path, season))
        return []
    out = []
    for r in re.findall(r"(?s)<tr[^>]*>(.*?)</tr>", page):
        m = re.search(r"bios/(isufs\d+)\.htm'?\"?>([^<]+)</a>", r)
        if not m:
            continue
        cells = [re.sub(r"\s+", " ", re.sub(r"(?s)<[^>]+>", " ", c)).strip()
                 for c in re.findall(r"(?s)<td[^>]*>(.*?)</td>", r)]
        nation = next((c for c in cells if re.fullmatch(r"[A-Z]{3}\d?", c)), "")
        level = "junior" if cells and cells[-1] == "J" else "senior"
        out.append((html.unescape(m.group(2)).strip(), nation, level, m.group(1)[5:]))
    return out


def internationals(season_codes, log=print, miss=None):
    """[(имя латиницей как в протоколе, страна, вид, уровень, номер биографии ISU, сезон)] — у всех есть
    оценка на турнире ISU; по строке на каждый сезон, где человек есть. Сезоны — от нового к старому:
    уровень в каждом сезоне свой (вчерашняя юниорка уже взрослая). miss — [(страница, сезон)] тех,
    что не прочитались: по такому списку нельзя судить, что человека в сезоне не было."""
    out = {}
    for s in season_codes:
        season = f"20{s[:2]}-{s[2:]}"
        for k, kind in KINDS.items():
            for seg in ("to", "rd") if k == "d" else ("to", "sp"):
                for name, nation, level, bio in _stat_rows(f"sb{season}/sbts{k}{seg}.htm", s, miss, log):
                    out.setdefault((name, kind, s), (nation, level, bio))
    log(f"  справочник: участников турниров ISU {len({(n, k) for n, k, _ in out})}")
    return [(n, st.nation_code(c), k, lv, b, s) for (n, k, s), (c, lv, b) in out.items()]


# ---------------------------------------------------------------- фото

def isu_russians(log=print):
    """[(имя латиницей, гражданство, организация)] — активные фигуристы ISU из России и Беларуси."""
    out = {}
    for page in range(1, 40):
        d = net.fetch_json(f"{isu.API}/skaters/merged-list",
                           data={"pagesize": 1000, "page": page, "discipline_id": 1})
        for x in d.get("data") or []:
            n = x.get("nationality_code") or ""
            org = x.get("organization_code") or x.get("nf_organization_code") or ""
            if n not in ("RUS", "BLR") and org not in ("RUS", "BLR", "AIN"):
                continue
            if x.get("status") not in ("Active", None, ""):
                continue
            # пара или танец: у строки имени нет, каждый партнёр — отдельная строка в members
            if x.get("skaters_type") == "Team":
                people = x.get("members") or []
            else:
                people = [x]
            for m in people:
                name = m.get("full_name") or ""
                if not name:
                    continue
                mn = m.get("nationality_code") or ""
                morg = m.get("organization_code") or org
                out.setdefault(name, (mn or morg, morg))
        if d.get("is_next_page") != "Y":
            break
    log(f"  список ISU, россияне и белорусы: {len(out)}")
    return [(k, v[0], v[1]) for k, v in out.items()]


def isu_photos(log=print):
    """[(имя латиницей, портрет)] из общего списка фигуристов ISU."""
    out = []
    page = 1
    while page <= 40:
        try:
            d = net.fetch_json(f"{isu.API}/skaters/merged-list",
                               data={"pagesize": 1000, "page": page, "discipline_id": 1})
        except (net.FetchError, ValueError) as e:
            log("  ! фигуристы ISU:", e)
            break
        for x in d.get("data") or []:
            people = x.get("members") or [x]
            for m in people:
                u = isu.portrait(m.get("thumbnail_image"))
                if not u and x.get("skaters_type") == "Single":
                    u = isu.portrait(m.get("image"))
                if u and m.get("full_name"):
                    out.append((m["full_name"], u))
        if d.get("is_next_page") != "Y":
            break
        page += 1
    log(f"  фото ISU из общего списка: {len(out)}")
    return out


WIKIDATA = "https://query.wikidata.org/sparql"
# Строка на (человек, картинка, страна): год рождения, точность даты, коды страны гражданства,
# «фигурист» (P106) и «вид спорта — фигурное катание» (P641 = Q38108). Всё это нужно для проверки
# личности: фото из Викиданных берётся только у того, чья дата рождения и страна совпали с ISU.
_SELECT = """SELECT ?p ?en ?ru ?img ?dob ?prec ?cc ?ioc ?sk ?fs WHERE {
%s
  OPTIONAL { ?p wdt:P569 ?dob . ?p p:P569/psv:P569/wikibase:timePrecision ?prec }
  OPTIONAL { ?p wdt:P27 ?c . OPTIONAL { ?c wdt:P298 ?cc } OPTIONAL { ?c wdt:P984 ?ioc } }
  BIND(EXISTS { ?p wdt:P106 wd:Q13219587 } AS ?sk)
  BIND(EXISTS { ?p wdt:P641 wd:Q38108 } AS ?fs)
  OPTIONAL { ?p rdfs:label ?en FILTER(LANG(?en) = "en") }
  OPTIONAL { ?p rdfs:label ?ru FILTER(LANG(?ru) = "ru") }
}"""
_SPARQL = _SELECT % "  ?p wdt:P2694 ?isu ; wdt:P18 ?img ."
# Россияне и белорусы-фигуристы с фото, но без номера ISU в Викиданных (номер вносят не у всех).
# Без номера ISU «фигурист» там бывает и певицей, и тренером, поэтому только с известной датой
# рождения и не старше 1994 года: действующие спортсмены
_SPARQL_OURS = _SELECT % """  VALUES ?c0 { wd:Q159 wd:Q184 }
  ?p wdt:P106 wd:Q13219587 ; wdt:P27 ?c0 ; wdt:P18 ?img ; wdt:P569 ?dob0 .
  FILTER(YEAR(?dob0) >= 1994)"""


def wikidata_label(label, lang):
    """Подпись из Викиданных → «Имя Фамилия». «Ксения Олеговна Макарова» — без отчества, как в
    протоколах; «Павлова, Наталья Евгеньевна» — фамилия впереди через запятую."""
    label = label.strip()
    if "," in label:
        fam, _, rest = label.partition(",")
        w = rest.split()
        label = f"{w[0]} {fam.strip()}" if w else label
    w = label.split()
    if lang == "ru" and len(w) == 3 and re.search(r"(вна|вич|ична|ич)$", w[1]):
        label = f"{w[0]} {w[2]}"
    return label


def _wikidata_rows(query, log):
    from urllib.parse import quote
    try:
        raw = net.fetch(WIKIDATA + "?format=json&query=" + quote(query), timeout=90,
                        headers={"Accept": "application/sparql-results+json"})
        return json.loads(raw)["results"]["bindings"]
    except (net.FetchError, ValueError, KeyError) as e:
        log("  ! Викиданные:", e)
        return None


BIRTH_CACHE = os.path.join(ROOT, "data", "photo_dob.json")
BIRTH_FETCH_MAX = 600  # новых профилей ISU за сбор: остальное доберётся в следующий раз


def isu_directory(log=print):
    """[(имя, slug, гражданство)] всех фигуристов ISU: у каждого есть профиль с датой рождения."""
    out = []
    page = 1
    while page <= 40:
        try:
            d = net.fetch_json(f"{isu.API}/skaters/merged-list",
                               data={"pagesize": 1000, "page": page, "discipline_id": 1})
        except (net.FetchError, ValueError) as e:
            log("  ! список ISU для проверки личности:", e)
            break
        for x in d.get("data") or []:
            for m in x.get("members") or [x]:
                if m.get("full_name") and m.get("slug"):
                    out.append((m["full_name"], m["slug"], m.get("nationality_code") or x.get("nationality_code") or ""))
        if d.get("is_next_page") != "Y":
            break
        page += 1
    return out


class Births:
    """Год и дата рождения по профилю ISU (slug → (дата, гражданство)). Дата рождения не меняется,
    поэтому копится в data/photo_dob.json. Нет профиля или даты — None: личность не подтвердить."""

    def __init__(self, path=BIRTH_CACHE, budget=BIRTH_FETCH_MAX):
        self.path = path
        self.budget = budget
        try:
            with open(path, encoding="utf-8") as f:
                self.d = json.load(f)
        except (OSError, ValueError):
            self.d = {}
        self.dirty = False

    def get(self, slug):
        if slug in self.d:
            return tuple(self.d[slug]) if self.d[slug] else None
        if self.budget <= 0:
            return None
        self.budget -= 1
        try:
            x = net.fetch_json(f"{isu.API}/skaters/detail/{slug}").get("data") or {}
        except (net.FetchError, ValueError):
            return None
        dob = (x.get("date_of_birth") or "")[:10]
        self.d[slug] = [dob, x.get("nationality_code") or ""] if re.fullmatch(r"\d{4}-\d{2}-\d{2}", dob) else None
        self.dirty = True
        return tuple(self.d[slug]) if self.d[slug] else None

    def save(self):
        if self.dirty:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.path, "w", encoding="utf-8") as f:
                json.dump(self.d, f, ensure_ascii=False, indent=0, sort_keys=True)


def wikidata_same_person(item, isu_dob, isu_nat):
    """Тот ли это человек, что в ISU. item — {dob: {'YYYY-MM-DD'…}, prec: точность, countries: {коды},
    skater: P106 = фигурист, sport: P641 = фигурное катание}; isu_dob — 'YYYY-MM-DD', isu_nat — код страны.
    Нужны все четыре: фигурист (или фигурное катание), страна, год рождения (и день, если в Викиданных
    он есть). Хоть одного нет — это может быть однофамилец, фото не берём."""
    if not (item.get("skater") or item.get("sport")):
        return False
    if not isu_dob or not isu_nat or isu_nat not in item.get("countries", ()):
        return False
    dobs = item.get("dob") or ()
    if not dobs:
        return False
    if item.get("prec", 0) >= 11:
        return isu_dob in dobs
    return any(d[:4] == isu_dob[:4] for d in dobs)


def _wikidata_items(rows):
    """Строки SPARQL → {id: {en, ru, imgs, dob, prec, countries, skater, sport}}."""
    items = {}
    for r in rows:
        it = items.setdefault(r["p"]["value"], {"en": None, "ru": None, "imgs": set(), "dob": set(),
                                                 "prec": 0, "countries": set(), "skater": False, "sport": False})
        for lang in ("en", "ru"):
            if lang in r:
                it[lang] = r[lang]["value"]
        it["imgs"].add(r["img"]["value"])
        if "dob" in r:
            it["dob"].add(r["dob"]["value"][:10])
            it["prec"] = max(it["prec"], int(r.get("prec", {}).get("value", 0) or 0))
        for c in ("cc", "ioc"):
            if c in r:
                it["countries"].add(r[c]["value"])
        it["skater"] |= r.get("sk", {}).get("value") == "true"
        it["sport"] |= r.get("fs", {}).get("value") == "true"
    return items


def wikidata_photos(log=print, covered=(), directory=None, births=None):
    """[(имя, фото)] из Викиданных — только тех, чья личность подтверждена профилем ISU: человек с таким
    именем есть в ISU, дата рождения (год, а если в Викиданных точная — вся дата) и страна совпали,
    в Викиданных он фигурист (P106) или у него фигурное катание (P641). Нет профиля ISU, нет даты
    рождения — Викиданные для него не используются. covered — ключи имён, у кого уже есть фото ISU или
    сборной (им Викиданные не нужны, профили не запрашиваем).
    Возвращает (список, ок): ок=False — Викиданные не ответили."""
    from urllib.parse import quote, unquote
    rows = _wikidata_rows(_SPARQL, log)
    ours = _wikidata_rows(_SPARQL_OURS, log)
    ok = rows is not None and ours is not None  # один из двух запросов не ответил — «нет в списке» ничего не значит
    items = _wikidata_items((rows or []) + (ours or []))
    if directory is None:
        directory = isu_directory(log)
    births = births or Births()
    by_key = {}
    for name, slug, nat in directory:
        by_key.setdefault(nm.key(name), []).append(slug)
    out = []
    seen = set()
    stats = {"items": len(items), "ok": 0, "no_isu": 0, "mismatch": 0, "covered": 0}
    for it in items.values():
        labels = [(lang, it[lang]) for lang in ("en", "ru") if it[lang]]
        if not labels:
            continue
        keys = {nm.key(wikidata_label(v, lang)) for lang, v in labels}
        if keys & set(covered):
            stats["covered"] += 1
            continue
        slugs = [sl for k in keys for sl in by_key.get(k, ())]
        if not slugs:
            stats["no_isu"] += 1
            continue
        same = False
        for sl in dict.fromkeys(slugs):
            b = births.get(sl)
            if b and wikidata_same_person(it, b[0], b[1]):
                same = True
                break
        if not same:
            stats["mismatch"] += 1
            continue
        stats["ok"] += 1
        for img in sorted(it["imgs"]):
            file = unquote(img.rsplit("/", 1)[-1])
            url = "https://commons.wikimedia.org/wiki/Special:FilePath/" + quote(file) + "?width=500"
            for lang, v in labels:
                label = wikidata_label(v, lang)
                if (label, url) not in seen:
                    seen.add((label, url))
                    out.append((label, url))
    births.save()
    log(f"  фото из Викиданных: {stats['items']} людей; личность подтверждена {stats['ok']}, "
        f"нет в ISU {stats['no_isu']}, дата/страна/вид не совпали или профиль не открылся {stats['mismatch']}, "
        f"уже есть фото ISU {stats['covered']}")
    return out, ok


# ---------------------------------------------------------------- картотека ФФККР

CARDS_CACHE = os.path.join(ROOT, "data", "cards.json")
CARDS_LIST_EVERY = dt.timedelta(hours=20)  # список картотеки — раз в сутки
CARDS_STALE = dt.timedelta(days=7)          # карточку — раз в неделю (фото, звание, результаты сезона)
CARDS_BUDGET = 40                           # карточек за сбор: остальное доберётся в следующий раз


def cards(log=print, path=None, budget=CARDS_BUDGET, now=None):
    """{номер: карточка} официальной картотеки спортсменов ФФККР, с «fio» — «Фамилия Имя Отчество».
    Копится в data/cards.json: сбой сети оставляет прежнее, человек, пропавший из списка, убирается
    (картотека — реестр: нет в нём — нет и его карточки)."""
    from . import fsr
    path = path or CARDS_CACHE
    now = now or dt.datetime.now(dt.timezone.utc)
    try:
        with open(path, encoding="utf-8") as f:
            c = json.load(f)
    except (OSError, ValueError):
        c = {}
    c.setdefault("list", [])
    c.setdefault("cards", {})
    listed_at = c.get("list_at")
    if not listed_at or now - dt.datetime.fromisoformat(listed_at) >= CARDS_LIST_EVERY:
        rows, total = {}, None
        try:
            for i in range(60):
                got, total = fsr.card_list(net.fetch(fsr.CARDS.format(i * 20)))
                new = [(a, b) for a, b in got if a not in rows]
                rows.update(new)
                if not new or (total and len(rows) >= total):
                    break
            if rows and (total is None or len(rows) >= total):
                c["list"] = sorted([a, b] for a, b in rows.items())
                c["list_at"] = now.isoformat()
            else:
                log(f"  ! картотека ФФККР: список неполный ({len(rows)} из {total})")
        except net.FetchError as e:
            log("  ! картотека ФФККР:", e)
    ids = {str(a): fio for a, fio in c["list"]}
    for k in list(c["cards"]):
        if k not in ids:
            del c["cards"][k]
    # сначала новые, потом самые давние
    order = sorted(ids, key=lambda k: c["cards"].get(k, {}).get("at", ""))
    fetched = 0
    for k in order:
        old = c["cards"].get(k)
        if old and now - dt.datetime.fromisoformat(old["at"]) < CARDS_STALE:
            continue
        if fetched >= budget:
            break
        fetched += 1
        if fetched > 1:
            time.sleep(1)  # официальный сайт: не чаще раза в секунду
        try:
            x = fsr.card(net.fetch(fsr.CARD.format(k)))
        except net.FetchError as e:
            log(f"  ! карточка {k}:", e)
            continue
        if not x["photo"] and old and old.get("photo"):
            x["photo"] = old["photo"]  # фото не пропадает из-за пустого ответа
        x["at"] = now.isoformat()
        c["cards"][k] = x
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(c, f, ensure_ascii=False, indent=0, sort_keys=True)
    out = {}
    for k, fio in ids.items():
        if k in c["cards"]:
            out[k] = dict(c["cards"][k], fio=fio)
    log(f"  картотека ФФККР: {len(ids)} человек, карточек {len(out)}, обновлено {fetched}")
    return out


def card_name(fio):
    """«Фамилия Имя Отчество» → «Имя Фамилия» как в остальных данных."""
    parts = fio.split()
    if len(parts) < 2:
        return ""
    return nm.pretty_ru(f"{parts[1]} {parts[0]}")


# ---------------------------------------------------------------- всё вместе

_LETTER = {"women": "w", "men": "m", "pairs": "p", "dance": "d"}


def _letters(kinds):
    """{вид: уровень} → «Wp»: строчная — взрослые, заглавная — юниоры."""
    return "".join(sorted(_LETTER[k].upper() if lv == "junior" else _LETTER[k] for k, lv in kinds.items()))


def _aged(old, ok):
    """(k, was, y) для человека, о котором в двух сезонах ничего нет, по его прежней записи old.
    Можно верить (ok): прежний вид уходит в «был» без сезона (y пуст — приложение скажет «в прошлых
    сезонах»). Нельзя — прежнее как есть. У прежней записи вида нет — сохраняется её was/y."""
    k = old.get("k") or ""
    if k and ok:
        return "", k, ""
    return k, old.get("was") or "", old.get("y") or ""


def _with(entry, k, was, y):
    """Копия записи справочника с новыми k/was/y; was и y — только при непустом was."""
    e = {a: b for a, b in entry.items() if a not in ("was", "y")}
    e["k"] = k
    if was:
        e["was"] = was
        e["y"] = y or ""
    return e


def _trusted(sure, c):
    """Верим ли «нет в списке» для страны c: источники ответили целиком."""
    return bool(sure["INT"] and (sure["RU"] or c not in OURS))


def _pkey(p):
    return (nm.key(p["n"]), p.get("c", ""))


def aged(prev_people, book):
    """Прежний справочник → тот же, но тем, кого нет в свежем book["people"], прежний вид уходит в
    «был» (см. _aged). Без book["sure"] (сбор справочника упал) — как есть. Вход не меняется."""
    sure = (book or {}).get("sure")
    if not prev_people or not sure:
        return prev_people
    have = {_pkey(p) for p in book["people"]}
    out = []
    for e in prev_people:
        if _pkey(e) in have:
            out.append(dict(e))
        else:
            out.append(_with(e, *_aged(e, _trusted(sure, e.get("c", "")))))
    return out


def build(names, season_start, log=print, seen=(), prev=None):
    """{"people": [{n, c, k, was?, y?}], "photos": [(имя, адрес, приоритет)], "sure": {...}}.
    n — имя как в остальных данных (наши — по-русски), c — страна, k — виды сейчас, was и y — виды
    прошлого сезона, которого в этом ещё нет (y — «2025/26» или пусто). seen — [(имя, вид, уровень)]
    из событий текущего сбора: свидетельство текущего сезона. prev — прежний справочник: пока источник
    сбоит, по нему не решаем, что человек пропал. sure — ответили ли источники целиком."""
    cache = _load()
    codes = seasons(season_start)
    cur, last = codes
    people = {}

    def add(name, nation, kind, level, season=None):
        key = nm.key(name)
        if not key:
            return
        p = people.setdefault(key, {"n": name, "c": nation, "k": {}})
        if not p["c"]:
            p["c"] = nation
        # {вид: {сезон: уровень}}; в сезоне первый выигрывает. Без вида (сборная, протокола не нашли) — только страна
        if kind is not None:
            p["k"].setdefault(kind, {}).setdefault(season, level)
        # русское написание важнее латинского, «Пётр» — чем «Петр» (nm.spelling_rank)
        if nm.spelling_rank(name) < nm.spelling_rank(p["n"]):
            p["n"] = name

    # полный список ISU: все фигуристы с российским или белорусским гражданством (вид — по заявке ISU)
    try:
        for raw, nation, org in isu_russians(log):
            c = st.nation_code(nation)
            add(names.to_ru(raw) if c in ("RUS", "BLR") else raw,
                "BLR" if c == "BLR" else "RUS", None, None)
    except net.FetchError as e:
        log("  ! список ISU:", e)
    # сборная ФФККР — российские спортсмены по определению (КМС и выше); вид пока неизвестен
    try:
        from . import fsr
        for sur, giv, _ in fsr.team():
            add(names.to_ru(nm.pretty_ru(f"{giv} {sur}")), "RUS", None, None)
    except net.FetchError as e:
        log("  ! сборная ФФККР:", e)
    # картотека ФФККР — официальный реестр (КМС и выше); вид из карточки без уровня не ставим:
    # взрослый или юниор — скажут протоколы. Имя — через псевдонимы config.json: картотека пишет
    # фамилию по мужу («Игнатова»), а знают её по прежней («Трусова») — человек один, профиль один
    try:
        card = cards(log)
    except Exception as e:  # картотека — дополнение: без неё справочник собирается как раньше
        log("  ! картотека ФФККР:", e)
        card = {}
    for x in card.values():
        n = card_name(x["fio"])
        if n:
            add(names.to_ru(n), "RUS", None, None)
    miss_ru, miss_int = [], []
    try:
        ru = russians(cache, codes, log, miss=miss_ru)
    except net.FetchError as e:
        log("  ! россияне:", e)
        miss_ru.append(("россияне", None))
        ru = []
    for raw, kind, level, season in ru:
        for one in raw.split(" / "):
            names.add(one)
        add(names.to_ru(raw), "RUS", kind, level, season)
    bios = {}  # ключ имени → номер биографии ISU (для профиля)
    try:
        intl = internationals(codes, log, miss=miss_int)
    except net.FetchError as e:
        log("  ! международные:", e)
        miss_int.append(("международные", None))
        intl = []
    for raw, nation, kind, level, bio, season in intl:
        # по-русски — только россияне и белорусы: иначе похожая фамилия иностранца
        # («Koval» у украинца) превращается в чужого человека с чужим фото
        ours = nation in OURS
        name = names.to_ru(raw) if ours else nm.pretty_latin(raw)
        add(name, nation, kind, level, season)
        if bio:
            bios.setdefault(nm.key(name), bio)
    sure = {"RU": not miss_ru, "INT": not miss_int}
    for what, lost in (("россиян", miss_ru), ("международных", miss_int)):
        if lost:
            log(f"  ! справочник: источник {what} ответил не целиком ({len(lost)}), «нет в списке» не считаем")
    # события текущего сбора — свидетельство текущего сезона, но только для тех, кто уже есть
    kinds = set(KINDS.values())
    for name, kind, level in seen:
        if kind not in kinds or level not in ("senior", "junior"):
            continue
        for who in dict.fromkeys([name] + name.split(" / ") if " / " in name else [name]):
            p = people.get(nm.key(who))
            # одиночник — либо мужчина, либо женщина: событие, где табло перепутало разряды, не делает
            # его обоими сразу (что уже известно, сильнее)
            if p and not (kind in _SINGLES and any(k in p["k"] for k in _SINGLES - {kind})):
                p["k"].setdefault(kind, {}).setdefault(cur, level)
    # участникам пары — вид пары (у кого есть своя сольная запись): в протоколе они «А / Б»
    for p in [x for x in people.values() if " / " in x["n"]]:
        for who in p["n"].split(" / "):
            solo = people.get(nm.key(who))
            if solo and solo is not p:
                for kind, by_season in p["k"].items():
                    for season, level in by_season.items():
                        solo["k"].setdefault(kind, {}).setdefault(season, level)
    _save(cache)

    photos = []
    try:
        from . import fsr
        for sur, giv, img in fsr.team():
            if img:
                photos.append((names.to_ru(nm.pretty_ru(f"{giv} {sur}")), img, 0))
    except net.FetchError as e:
        log("  ! фото сборной ФФККР:", e)
    for x in card.values():
        if x.get("photo") and card_name(x["fio"]):
            photos.append((names.to_ru(card_name(x["fio"])), x["photo"], 0))
    for raw, url in isu_photos(log):
        photos.append((raw, url, 2))
    covered = {nm.key(raw) for raw, _, _ in photos}
    wiki, wiki_ok = wikidata_photos(log, covered=covered)
    for raw, url in wiki:
        photos.append((raw, url, 3))
    # найденное вручную — ниже всех: любое фото из реестра или ISU заменяет его в следующем сборе
    from . import photos as ph
    photos.extend((n, u, ph.HAND_PRIO) for n, u in ph.load_hand())
    out = sorted(people.values(), key=lambda p: p["n"])
    # сколько людей в классе (наши ли, вид, уровень) выступало в каждом из двух сезонов
    now_n, last_n = {}, {}
    for p in out:
        for kind, by_season in p["k"].items():
            for season, level in by_season.items():
                cl = (p["c"] in OURS, kind, level)
                if season == cur:
                    now_n[cl] = now_n.get(cl, 0) + 1
                elif season == last:
                    last_n[cl] = last_n.get(cl, 0) + 1

    def is_open(cl):
        return now_n.get(cl, 0) >= max(OPEN_MIN, OPEN_SHARE * last_n.get(cl, 0))

    before = {_pkey(e): e for e in prev or []}
    for p in out:
        by_kind = p.pop("k")
        c = p["c"]
        now = {k: s[cur] for k, s in by_kind.items() if cur in s}
        old = {k: s[last] for k, s in by_kind.items() if cur not in s and last in s}
        ok = _trusted(sure, c)
        pe = before.get(_pkey(p))
        k, was, y = "", "", ""
        if now:
            # найденному верим всегда; прошлогодние виды рядом с текущими не показываем
            k = _letters(now)
        elif not ok and pe:
            k, was, y = pe.get("k") or "", pe.get("was") or "", pe.get("y") or ""
        elif old:
            if ok and all(is_open((c in OURS, kind, lv)) for kind, lv in old.items()):
                was, y = _letters(old), f"20{last[:2]}/{last[2:]}"
            else:
                k = _letters(old)
        elif pe:
            k, was, y = _aged(pe, ok)
        p["k"] = k
        if was:
            p["was"], p["y"] = was, y
    return {"people": out, "photos": photos, "wiki_ok": wiki_ok, "cards": card, "bios": bios, "sure": sure}
