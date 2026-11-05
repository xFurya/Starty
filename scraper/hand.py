"""Фото, найденные в открытых источниках, для тех, у кого их нет ни в одном реестре.

Запускается руками, не в каждом сборе:

    python3 -m scraper.hand

Берёт всех из справочника (site/data/events.json → people), у кого фото нет, и ищет человека на
Викискладе: категорию с тем же именем, которая сама лежит среди фигуристов (иначе это может быть
тёзка). Из категории — только снимки, в названии которых он назван и назван один: без партнёра
(«Righi, Dubrovin», «Khodkova-Sliusarenko», «Alina Pepeleva Roman Pleshkov»), без пьедестала и
трибун. Кадр, вырезанный из общего («… (cropped) - Фамилия»), — первым. Найденное дописывается в
data/photo_hand.json; записанное раньше не стирается.

    python3 -m scraper.hand --again

перебирает уже найденное заново по тем же правилам (после того как правила поменялись).

В сборе такие фото идут ниже всех (photos.HAND_PRIO): как только у человека появится фото в
картотеке или сборной ФФККР, у ISU или в Викиданных, сборщик заменит найденное здесь на него.
Портрет проверяется строго, как у Викисклада: одно лицо, крупно, без головного убора — снимок,
где не понять, кто это, отбраковывается и в приложение не попадает."""
import json
import os
import re
import sys
import time
import unicodedata
from urllib.parse import quote, unquote, urlencode

from . import names as nm
from . import net
from . import photos as ph

API = "https://commons.wikimedia.org/w/api.php"
SITE_JSON = os.path.join(ph.ROOT, "site", "data", "events.json")
PER_PERSON = 4  # снимков на человека: строгая проверка портрета отбрасывает часть
_SKATER = re.compile(r"(?i)figure skat|ice danc|pair skat")
_TWO = re.compile(r"(?i)\s(&|and|und|et|и|with|mit|avec|с|со)\s|/")


def _api(**params):
    params.update(format="json", formatversion="2")
    time.sleep(1)  # Викисклад просит не чаще раза в секунду
    return net.fetch_json(API + "?" + urlencode(params))


def latin(name):
    """Латиница для поиска: русское имя — по ICAO (Ivan Tertyshnikov), латинское — как есть."""
    if not nm.is_cyr(name):
        return name
    return " ".join(w.capitalize() for w in nm.ru_to_lat(name).split())


def same_name(title, name):
    """Название категории — то же имя (написания сводятся: Sofia = Sofiya, Akateva = Akatyeva)."""
    t = re.sub(r"\s*\(.*\)\s*$", "", title)
    a = [nm.norm_lat(w) for w in latin(t).split()]
    b = [nm.norm_lat(w) for w in latin(name).split()]
    return bool(a) and sorted(a) == sorted(b)


_SKATING_FILE = re.compile(
    r"(?i)figure skat|short program|free skat|free dance|rhythm dance|short dance|(men|women|ladies|pairs?)[’'`]?s? (short|free)|"
    r"grand prix|skate (america|canada)|four continents|nhk trophy|cup of (china|russia)|rostelecom|nebelhorn|"
    r"finlandia trophy|ondrej nepela|lombardia trophy|skating championships|figure-skating|фигурн")


def _members(cat):
    got = _api(action="query", list="categorymembers", cmtitle=cat, cmtype="file", cmlimit=100)
    return [m["title"].split(":", 1)[1] for m in got.get("query", {}).get("categorymembers", [])]


def find(name, others=frozenset()):
    """(категория, [адреса снимков]) или (None, []). Категория — того же имени и про фигуриста: она сама
    среди фигуристов или её снимки — с соревнований по фигурному катанию (иначе это может быть тёзка)."""
    found = _api(action="query", list="search", srnamespace=14, srlimit=10, srsearch=latin(name))
    for hit in found.get("query", {}).get("search", []):
        title = hit["title"]
        if not same_name(title.split(":", 1)[1], name):
            continue
        info = _api(action="query", prop="categories", titles=title, cllimit=50)
        parents = [c["title"] for p in info.get("query", {}).get("pages", []) for c in p.get("categories", [])]
        members = _members(title)
        if any(_SKATER.search(c) for c in parents) or any(_SKATING_FILE.search(t) for t in members):
            return title, files(members, name, others)
    return None, []


_CROWD = re.compile(r"(?i)medal|podium|ceremon|audience|spectator|crowd|(?<![^\W\d_])(team|group|band|cast|fans|press|parade)(?![^\W\d_])")
_CROP = re.compile(r"(?i)\(cropped\)\s*[-–]\s*([^\W\d_]+)")
_WORD = re.compile(r"[^\W\d_]+")
_EVENT = re.compile(r"(?i)(worlds|euros?|nationals|olympics|universiade|championships?|cup|trophy|gala|final|"
                    r"juniors?|seniors?|men|women|ladies|pairs?|dance|grand prix|isu|jgp|gp)(?![^\W\d_])|" +
                    _SKATING_FILE.pattern.replace("(?i)", ""))


def _fold(word):
    """Слово для сравнения: без диакритики, по-латински, написания сведены (Jakušina = Yakushina)."""
    w = "".join(c for c in unicodedata.normalize("NFKD", word) if not unicodedata.combining(c))
    return nm.fold(nm.norm_lat(latin(w)))


def _same(a, b):
    """Та же фамилия: совпадает или отличается одной буквой при той же длине (Lobasheva = Lobacheva)."""
    return a == b or (len(a) == len(b) >= 7 and nm._lev(a, b) <= 1)


def _near(a, b):
    """То же имя: Alexander = Alexandr, Anastaisa = Anastasia."""
    return a == b or (min(len(a), len(b)) >= 5 and nm._lev(a, b) <= 1)


def split(name):
    """(имена, фамилии) в виде для сравнения. В протоколе ISU фамилия капсом; иначе — первое слово имя."""
    words = latin(name).split()
    caps = [w for w in words if w.isupper() and len(w) > 1]
    giv = [w for w in words if w not in caps] if caps else words[:1]
    fam = caps or words[1:]
    return ([_fold(w) for w in giv],
            [_fold(x) for w in fam for x in w.split("-") if x])


def known_names(names):
    """Имена и фамилии всех людей справочника — чтобы узнать в названии снимка чужое имя."""
    out = set()
    for n in names:
        giv, fam = split(n)
        out.update(g for g in giv if len(g) >= 3)
        out.update(f for f in fam if len(f) >= 4)
    return out


def _namelike(w):
    """Слово похоже на имя: «Otar», «Japaridze», «LICHEV» (не «IMG», не «RUS», не «jsfb»)."""
    return (len(w) >= 3 and w[0].isupper() and w[1:].islower()) or (len(w) >= 4 and w.isupper())


def rank(title, name, others):
    """Место снимка среди кандидатов (меньше — лучше) или None, если он не годится: не назван этот
    человек, назван ещё кто-то (партнёр через запятую, дефис, полным именем или человек из
    справочника) или это пьедестал, трибуны, команда. Вырезанный из общего кадра под этого человека
    («… (cropped) - Фамилия») — первым."""
    if not re.search(r"(?i)\.(jpe?g|png)$", title):
        return None
    stem = re.sub(r"\.\w+$", "", title).replace("_", " ")
    giv, fam = split(name)
    if not fam:
        return None
    crop = _CROP.search(stem)
    if crop:
        return 0 if any(_same(_fold(crop.group(1)), f) for f in fam) else None
    bare = re.sub(r"\([^)]*\)", " ", stem)  # в скобках — событие и дата: «(Белые ночи - 2023, день 2)»
    words = [(m, _fold(m.group())) for m in _WORD.finditer(bare)]
    mine = lambda w: any(_same(w, f) for f in fam) or any(_near(w, g) for g in giv)
    at = [i for i, (_, w) in enumerate(words) if any(_same(w, f) for f in fam)]
    if not at:
        return None
    if _TWO.search(bare) or _CROWD.search(bare) or "," in bare:
        return None
    for joined in re.findall(r"[^\W\d_]+(?:-[^\W\d_]+)+", bare):
        parts = [_fold(x) for x in joined.split("-")]
        if any(_same(p, f) for p in parts for f in fam) and any(len(p) >= 4 and not mine(p) for p in parts):
            return None
    if any(_namelike(m.group()) and w in others and not mine(w) for m, w in words):
        return None
    # Сразу за ним — ещё имя: «Angelina Telegina Otar Japaridze», «Golovina Voiko EC04». Название
    # соревнования («… Skate Canada», «… Worlds 2019») именем не считается.
    run = [m for m, _ in words[at[-1]:at[-1] + 3]]
    if len(run) >= 2 and _namelike(run[1].group()) and not mine(_fold(run[1].group())) and \
            not bare[run[0].end():run[1].start()].strip() and not _EVENT.match(bare[run[1].start():]):
        return None
    return 1 if "cropped" in stem.lower() else 2


def files(members, name, others=frozenset()):
    """До PER_PERSON адресов снимков, где человек один: вырезанные под него первыми, потом свежие."""
    ranked = [(r, t) for t in members for r in [rank(t, name, others)] if r is not None]
    year = lambda t: max((int(y) for y in re.findall(r"(?<!\d)((?:19|20)\d\d)(?!\d)", t)), default=0)
    ranked.sort(key=lambda x: (x[0], -year(x[1])))
    return ["https://commons.wikimedia.org/wiki/Special:FilePath/" + quote(t.replace(" ", "_")) + "?width=500"
            for _, t in ranked[:PER_PERSON]]


def missing(data):
    """Все люди справочника (пары — по одному), у кого фото нет."""
    have = {nm.key(k) for k, v in (data.get("photos") or {}).items() if v}
    out = []
    for p in data.get("people") or []:
        for one in p["n"].split(" / "):
            one = one.strip()
            if one and nm.key(one) not in have and one not in out:
                out.append(one)
    return out


def _save(book):
    with open(ph.HAND, "w", encoding="utf-8") as f:
        json.dump(book, f, ensure_ascii=False, indent=1, sort_keys=True)


def again(book, others):
    """Уже найденное — заново по нынешним правилам: из той же категории. Что не прошло — убирается."""
    kept = 0
    for n in sorted(book):
        cat = book[n].get("src", "").rsplit("/", 1)[-1]
        try:
            urls = files(_members(unquote(cat).replace("_", " ")), n, others)
        except (net.FetchError, ValueError, KeyError) as e:
            print(f"  ! {n}: {e}", flush=True)
            continue
        if urls:
            book[n]["u"] = urls
            kept += 1
        else:
            del book[n]
            print(f"  - {n}", flush=True)
        _save(book)
    print(f"осталось {kept}")


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    with open(SITE_JSON, encoding="utf-8") as f:
        data = json.load(f)
    try:
        with open(ph.HAND, encoding="utf-8") as f:
            book = json.load(f)
    except (OSError, ValueError):
        book = {}
    everyone = [one.strip() for p in data.get("people") or [] for one in p["n"].split(" / ") if one.strip()]
    others = known_names(everyone)
    if "--again" in argv:
        return again(book, others)
    todo = [n for n in missing(data) if n not in book]
    print(f"без фото {len(todo)}", flush=True)
    found = 0
    for i, n in enumerate(todo, 1):
        try:
            cat, urls = find(n, others)
        except (net.FetchError, ValueError, KeyError) as e:
            print(f"  ! {n}: {e}", flush=True)
            continue
        if urls:
            found += 1
            book[n] = {"u": urls, "src": "https://commons.wikimedia.org/wiki/" + quote(cat.replace(" ", "_"))}
            print(f"  + {n}: {cat} ({len(urls)})", flush=True)
            _save(book)
        if i % 100 == 0:
            print(f"  {i}/{len(todo)}, найдено {found}", flush=True)
    print(f"найдено {found} из {len(todo)}")


if __name__ == "__main__":
    main(sys.argv[1:])
