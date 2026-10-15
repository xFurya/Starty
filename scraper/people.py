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
import html
import json
import os
import re

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
# сколько страниц раздела «Соревнования» листать за сбор (по 10 турниров; конец — пустая страница)
MAX_PAGES = 200
# версия разбора протоколов: при смене разобранное считается заново
RULES = 4


def _load():
    try:
        with open(CACHE, encoding="utf-8") as f:
            c = json.load(f)
    except (OSError, ValueError):
        c = {}
    c.setdefault("pages", {})    # страница турнира → адрес табло или ""
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

_SKIP_TOUR = re.compile(r"любител|синхрон|мальчик|девоч|межрегион|фестивал|спортивн\w* бал|балет", re.I)
_SKIP_CAT = re.compile(r"разряд|юношеск|мальчик|девоч|синхрон|команд|любител|новичк|basic|novice", re.I)


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


def russians(cache, season_codes, log=print):
    """[(имя по-русски как в протоколе, вид, уровень, сезон)] со всех всероссийских стартов этих сезонов."""
    from . import fsr
    oldest = min(season_codes)
    known = cache["pages"]
    fresh_pages = 0
    for n in range(MAX_PAGES):
        try:
            listing = net.fetch(f"{FSR}/sorevnovaniya?start={n * 10}")
        except net.FetchError as e:
            log("  ! список соревнований ФФККР:", e)
            break
        links = _tournament_links(listing)
        if not links:
            break
        # листаем весь раздел: старые турниры на последних страницах, и порядок дат не гарантирован
        for l in links:
            if l in known:
                continue
            try:
                res = fsr.tournament(FSR + l)["results"] or ""
            except net.FetchError:
                continue
            known[l] = res
            fresh_pages += 1
    out = []
    for page, res in known.items():  # noqa: E501
        if not res or _SKIP_TOUR.search(page.replace("-", " ")):
            continue
        m = re.search(r"/results/(\d{4})/", res)
        if not m or m.group(1) not in season_codes:
            continue
        if res not in cache["results"]:
            got = _results(res, log)
            if got is None:
                continue
            cache["results"][res] = got
        out.extend((n, k, lv, m.group(1)) for n, k, lv in cache["results"][res])
    # новые сезоны первыми: уровень — по последнему
    out.sort(key=lambda x: x[3], reverse=True)
    log(f"  справочник: россиян с протоколов {len({x[0] for x in out})}; новых страниц турниров {fresh_pages}")
    return out


def _results(idx_url, log):
    """[[имя, вид]] по заявкам категорий КМС и выше; None — табло ещё не готово."""
    try:
        idx = st.parse_index(idx_url)
    except (net.FetchError, ValueError) as e:
        log("  ! табло:", idx_url, e)
        return None
    if not idx.get("categories"):
        return None
    out = []
    for c in idx["categories"]:
        name = (c.get("name") or "").translate(_HOMO)
        kind = kind_of_category(name)
        level = level_of_category(name)
        if not kind or _SKIP_CAT.search(name):
            continue
        url = c.get("entries_url") or c.get("results_url")
        if not url:
            continue
        try:
            page = net.fetch(url)
        except net.FetchError:
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

def _stat_rows(path):
    try:
        page = net.fetch(STAT + path, timeout=40)
    except net.FetchError:
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
        out.append((html.unescape(m.group(2)).strip(), nation, level))
    return out


def internationals(season_codes, log=print):
    """[(имя латиницей как в протоколе, страна, вид, уровень)] — у всех есть оценка на турнире ISU.
    Сезоны — от нового к старому: уровень берётся по последнему (вчерашняя юниорка уже взрослая)."""
    out = {}
    for s in season_codes:
        season = f"20{s[:2]}-{s[2:]}"
        for k, kind in KINDS.items():
            for seg in ("to", "rd") if k == "d" else ("to", "sp"):
                for name, nation, level in _stat_rows(f"sb{season}/sbts{k}{seg}.htm"):
                    out.setdefault((name, kind), (nation, level))
    log(f"  справочник: участников турниров ISU {len(out)}")
    return [(n, c, k, lv) for (n, k), (c, lv) in out.items()]


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
            name = x.get("full_name") or ""
            if name:
                out.setdefault(name, (n or org, org))
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
_SPARQL = """SELECT ?en ?ru ?img WHERE {
  ?p wdt:P2694 ?isu ; wdt:P18 ?img .
  OPTIONAL { ?p rdfs:label ?en FILTER(LANG(?en) = "en") }
  OPTIONAL { ?p rdfs:label ?ru FILTER(LANG(?ru) = "ru") }
}"""


def wikidata_photos(log=print):
    """[(имя, фото)] фигуристов с номером ISU и фотографией на Викискладе."""
    from urllib.parse import quote, unquote
    try:
        raw = net.fetch(WIKIDATA + "?format=json&query=" + quote(_SPARQL), timeout=90,
                        headers={"Accept": "application/sparql-results+json"})
        rows = json.loads(raw)["results"]["bindings"]
    except (net.FetchError, ValueError, KeyError) as e:
        log("  ! Викиданные:", e)
        return []
    out = []
    for r in rows:
        img = r["img"]["value"]
        file = unquote(img.rsplit("/", 1)[-1])
        url = "https://commons.wikimedia.org/wiki/Special:FilePath/" + quote(file) + "?width=500"
        for lang in ("en", "ru"):
            if lang in r:
                label = r[lang]["value"]
                # «Ксения Олеговна Макарова» — без отчества, как в протоколах
                w = label.split()
                if lang == "ru" and len(w) == 3 and re.search(r"(вна|вич|ична|ич)$", w[1]):
                    label = f"{w[0]} {w[2]}"
                out.append((label, url))
    log(f"  фото из Викиданных: {len(rows)}")
    return out


# ---------------------------------------------------------------- всё вместе

def build(names, season_start, log=print):
    """{"people": [{n, c, k}], "photos": [(имя, адрес, приоритет)]}.
    n — имя как в остальных данных (наши — по-русски), c — страна, k — виды."""
    cache = _load()
    codes = seasons(season_start)
    people = {}

    def add(name, nation, kind, level):
        key = nm.key(name)
        if not key:
            return
        p = people.setdefault(key, {"n": name, "c": nation, "k": {}})
        if not p["c"]:
            p["c"] = nation
        # первый — из самого нового сезона; без вида (сборная, протокола не нашли) — только страна
        if kind is not None:
            p["k"].setdefault(kind, level)
        # русское написание важнее латинского
        if nm.is_cyr(name) and not nm.is_cyr(p["n"]):
            p["n"] = name

    # полный список ISU: все фигуристы с российским или белорусским гражданством (вид — по заявке ISU)
    try:
        for raw, nation, org in isu_russians(log):
            add(names.to_ru(raw) if nation == "RUS" or nation == "BLR" else raw,
                "BLR" if nation == "BLR" else "RUS", None, None)
    except net.FetchError as e:
        log("  ! список ISU:", e)
    # сборная ФФККР — российские спортсмены по определению (КМС и выше); вид пока неизвестен
    try:
        from . import fsr
        for sur, giv, _ in fsr.team():
            add(nm.pretty_ru(f"{giv} {sur}"), "RUS", None, None)
    except net.FetchError as e:
        log("  ! сборная ФФККР:", e)
    try:
        ru = russians(cache, codes, log)
    except net.FetchError as e:
        log("  ! россияне:", e)
        ru = []
    for raw, kind, level, _ in ru:
        for one in raw.split(" / "):
            names.add(one)
        add(names.to_ru(raw), "RUS", kind, level)
    for raw, nation, kind, level in internationals(codes, log):
        # по-русски — только россияне и белорусы: иначе похожая фамилия иностранца
        # («Koval» у украинца) превращается в чужого человека с чужим фото
        ours = nation in OURS
        add(names.to_ru(raw) if ours else nm.pretty_latin(raw), nation, kind, level)
    _save(cache)

    photos = []
    for raw, url in isu_photos(log):
        photos.append((raw, url, 2))
    for raw, url in wikidata_photos(log):
        photos.append((raw, url, 3))
    out = sorted(people.values(), key=lambda p: p["n"])
    # вид буквой: строчная — взрослые, заглавная — юниоры (W — девушки, M — юноши)
    letter = {"women": "w", "men": "m", "pairs": "p", "dance": "d"}
    for p in out:
        p["k"] = "".join(sorted(letter[k].upper() if lv == "junior" else letter[k] for k, lv in p["k"].items()))
    return {"people": out, "photos": photos}
