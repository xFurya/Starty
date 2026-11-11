"""Место рождения по-русски.

ISU пишет место рождения латиницей и как придётся: «Riazan», «Moscow RUS», «St. Petersburg»,
«Boston, MA», «Changchun Jilin». В профиль идёт русское название из Викиданных, но только когда
место узнано наверняка; иначе остаётся написание ISU: оно верное, просто латиницей.

Как узнаём. Поиск Викиданных по названию на любом языке («Riazan» — каталанская подпись Рязани);
из найденного берутся только совпавшие с запросом целиком и только населённые пункты и
административные единицы. Страна — из кода в конце строки («Moscow RUS»), а без кода — страна
спортсмена. Если в стране спортсмена такого места нет, годится место, когда все совпавшие лежат в
одной стране («Kharkiv» у россиянки). Когда в стране спортсмена есть тёзка куда менее известного
места в другой стране («Moscow» у американца: Москва или Москоу в Айдахо), не угадываем.

Найденное копится в data/places.json: «<строка ISU>|<страна спортсмена>» → {"ru", "q", "at", "v"};
ненайденное ("ru": "") пробуем снова через RETRY дней."""
import datetime as dt
import json
import os
import re
import unicodedata
from urllib.parse import urlencode

from . import net

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "data", "places.json")
API = "https://www.wikidata.org/w/api.php"
RETRY = dt.timedelta(days=60)
BUDGET = 150  # поисков за сбор (раз в секунду): остальное доберётся в следующий раз
# правила выбора поменялись — поднять: узнанное раньше узнаётся заново
VERSION = 2
FAMOUS = 2  # во сколько раз известнее (по числу статей в Википедиях) тёзка за границей, чтобы не угадывать

# населённый пункт, административная единица
_PLACE_TYPES = "wd:Q486972 wd:Q56061"


def _norm(s):
    s = unicodedata.normalize("NFKD", s)
    s = "".join(ch for ch in s if not unicodedata.combining(ch)).casefold()
    s = re.sub(r"[’'`]", "", s)
    s = re.sub(r"[-‐–—_/]", " ", s)
    s = re.sub(r"\b(?:saint|sankt|st)\b\.?", "st", s)
    s = re.sub(r"\b(?:mount|mt)\b\.?", "mt", s)
    s = re.sub(r"[.,()]", " ", s)
    return " ".join(s.split())


def nation_code(nation):
    """Страна спортсмена кодом МОК: AIN2 и регионы на российских стартах — RUS, AIN1 — BLR."""
    if nation == "AIN2" or (len(nation) == 3 and nation.isalpha() and not nation.isascii()):
        return "RUS"
    if nation == "AIN1":
        return "BLR"
    return nation


def split(place):
    """Строка ISU → (запросы по порядку, код страны или ""). Регион после запятой («Boston, MA»,
    «Sakai, Osaka») и двухбуквенный в конце («Toronto ON») отбрасываются: ищем город. Второй
    запрос — без последнего слова («Changchun Jilin»), годится только в известной стране."""
    s = " ".join(place.split())
    code = ""
    m = re.search(r",?\s+([A-Z]{3})$", s)
    if m:
        code, s = m.group(1), s[:m.start()]
    comma = "," in s
    s = s.split(",")[0].strip()
    s = re.sub(r"\s+[A-Z]{2}$", "", s).strip()
    out = [s] if s else []
    w = s.split()
    if not comma and len(w) >= 2:
        out.append(" ".join(w[:-1]))
    return out, code


def region(place):
    """Уточнение после города: «Ontario» из «London, Ontario», «ON» из «Toronto ON», «Madrid» из
    «Mostoles (Madrid)». Пусто, если его нет."""
    s = re.sub(r",?\s+[A-Z]{3}$", "", " ".join(place.split()))
    if "," in s:
        return s.split(",", 1)[1].strip(" ,")
    m = re.search(r"\(([^)]+)\)$", s) or re.search(r"\s([A-Z]{2})$", s)
    return m.group(1).strip() if m else ""


def _search(q):
    """[(id, текст совпадения, подпись, описание)] из поиска Викиданных по подписям и псевдонимам
    на всех языках."""
    url = API + "?" + urlencode({"action": "wbsearchentities", "search": q, "language": "en",
                                 "type": "item", "limit": 12, "format": "json"})
    net._throttle(url, gap=1.0)
    d = json.loads(net.fetch(url, tries=2))
    return [(x["id"], (x.get("match") or {}).get("text") or "", x.get("label") or "", x.get("description") or "")
            for x in d.get("search") or []]


def exact(q, hits):
    """id совпавших с запросом целиком (по тексту совпадения или по подписи), в порядке поиска."""
    n = _norm(q)
    return [h[0] for h in hits if n and (_norm(h[1]) == n or _norm(h[2]) == n)]


def _facts(ids, rows_of):
    """{id: {"ru", "links", "cc": {коды страны}}} для мест из ids (только населённые пункты и
    административные единицы с координатами и страной)."""
    out = {}
    ids = list(dict.fromkeys(ids))
    for i in range(0, len(ids), 120):
        chunk = " ".join("wd:" + x for x in ids[i:i + 120])
        rows = rows_of(f"""SELECT ?item ?ru ?links ?ioc ?iso ?sioc ?siso WHERE {{
  VALUES ?item {{ {chunk} }}
  ?item wdt:P625 ?coord ; wdt:P17 ?c ; wikibase:sitelinks ?links .
  FILTER EXISTS {{ VALUES ?t {{ {_PLACE_TYPES} }} ?item wdt:P31/wdt:P279* ?t }}
  OPTIONAL {{ ?c wdt:P984 ?ioc }}
  OPTIONAL {{ ?c wdt:P298 ?iso }}
  OPTIONAL {{ ?item wdt:P984 ?sioc }}
  OPTIONAL {{ ?item wdt:P298 ?siso }}
  OPTIONAL {{ ?item rdfs:label ?ru FILTER(LANG(?ru) = "ru") }}
}}""")
        if rows is None:
            raise net.FetchError("Викиданные не ответили")
        for r in rows:
            q = r["item"]["value"].rsplit("/", 1)[-1]
            f = out.setdefault(q, {"ru": "", "links": 0, "cc": set()})
            if r.get("ru"):
                f["ru"] = r["ru"]["value"]
            f["links"] = max(f["links"], int(r["links"]["value"]))
            for k in ("ioc", "iso", "sioc", "siso"):  # страна, а у Гонконга и свой код
                if r.get(k):
                    f["cc"].add(r[k]["value"])
    return out


def _dominant(top, rivals, facts):
    """top известнее всех мест из rivals в других странах больше чем в FAMOUS раз."""
    other = [facts[q]["links"] for q in rivals if not facts[q]["cc"] & facts[top]["cc"]]
    return all(facts[top]["links"] > FAMOUS * max(n, 1) for n in other)


def choose(cands, facts, code, nation, fallback=False, region="", descs=None):
    """Какое из совпавших мест (id в порядке поиска) — то самое, или None.
    code — код страны из строки ISU, nation — страна спортсмена (код МОК);
    fallback — запрос без последнего слова: тогда только в известной стране;
    region — уточнение из строки ISU, descs — {id: описание из поиска}: место, в описании которого
    уточнение есть («Ontario» — «city in Ontario, Canada»), — то самое и без сравнения известности.
    Двухбуквенное уточнение («ON», «VA») — область или штат страны спортсмена."""
    geo = [q for q in cands if q in facts]
    if not geo:
        return None
    sure = bool(re.fullmatch(r"[A-Z]{2}", region or ""))
    r = _norm(region or "")
    if r and not sure and descs:
        named = [q for q in geo if f" {r} " in f" {_norm(descs.get(q, ''))} "]
        if named:
            geo, sure = named, True
    if code:
        geo_in = [q for q in geo if code in facts[q]["cc"]]
        return geo_in[0] if geo_in else None
    home = [q for q in geo if nation and nation in facts[q]["cc"]]
    if home:
        pick = home[0]
        top = max(geo, key=lambda q: facts[q]["links"])
        if not sure and top != pick and _dominant(top, [pick], facts):
            return None
        return pick
    if fallback:
        return None
    if len({frozenset(facts[q]["cc"]) for q in geo}) == 1:
        return geo[0]
    top = max(geo, key=lambda q: facts[q]["links"])
    return top if _dominant(top, geo, facts) else None


def _ru_name(s):
    """Подпись годится, если она по-русски: кириллица, без пояснений в скобках."""
    s = re.sub(r"\s*\(.*\)\s*$", "", s or "").strip()
    return s if re.search(r"[А-Яа-яЁё]", s) else ""


def load(path=None):
    try:
        with open(path or CACHE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save(cache, path=None):
    path = path or CACHE
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=1, sort_keys=True)


def cache_key(place, nation):
    return f"{place}|{nation_code(nation)}"


def refresh(pairs, log=print, path=None, budget=BUDGET, today=None, search=None, rows_of=None):
    """Узнать места из pairs [(строка ISU, страна спортсмена)], которых нет в кэше или которые давно
    не находились. Возвращает кэш {ключ: {"ru", "q", "at"}}; на диск пишет сам."""
    from . import people as pp
    today = today or dt.datetime.now(dt.timezone.utc).date()
    search = search or _search
    rows_of = rows_of or (lambda q: pp._wikidata_rows(q, log))
    cache = load(path)
    todo = []
    for place, nation in dict.fromkeys(pairs):
        k = cache_key(place, nation)
        c = cache.get(k)
        if c and c.get("v") == VERSION and (c.get("ru") or dt.date.fromisoformat(c["at"]) + RETRY > today):
            continue
        todo.append((place, nation_code(nation), k))
    if not todo:
        return cache
    found, descs, spent = {}, {}, 0
    for place, _, _ in todo:
        for q in split(place)[0]:
            if q in found or spent >= budget:
                continue
            spent += 1
            try:
                hits = search(q)
                found[q] = exact(q, hits)
                descs.update((h[0], h[3]) for h in hits if len(h) > 3)
            except (net.FetchError, ValueError, KeyError) as e:
                # Викиданные не отвечают или просят реже: остальное — в следующий сбор
                log("  ! места рождения, поиск:", q, e)
                spent = budget
    try:
        facts = _facts([i for ids in found.values() if ids for i in ids], rows_of)
    except net.FetchError as e:
        log("  ! места рождения:", e)
        return cache
    done = 0
    for place, nation, k in todo:
        qs, code = split(place)
        if not qs or qs[0] not in found:
            continue  # не дошла очередь или поиск не ответил
        reg = region(place)
        pick = choose(found[qs[0]], facts, code, nation, region=reg, descs=descs)
        if pick is None and len(qs) > 1:
            if qs[1] not in found:
                continue  # второй запрос ещё не искали
            pick = choose(found[qs[1]], facts, code, nation, fallback=True, region=reg, descs=descs)
        ru = _ru_name(facts[pick]["ru"]) if pick else ""
        cache[k] = {"ru": ru, "q": pick or "", "at": today.isoformat(), "v": VERSION}
        done += 1
    save(cache, path)
    known = sum(1 for v in cache.values() if v.get("ru"))
    log(f"  места рождения: проверено {done}, по-русски {known} из {len(cache)}")
    return cache


def ru(place, nation, cache):
    """Место рождения для профиля: по-русски, если узнано, иначе как у ISU."""
    c = (cache or {}).get(cache_key(place, nation))
    return c["ru"] if c and c.get("ru") else place
