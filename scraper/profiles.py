"""Профили спортсменов: справка, лучшие оценки, титулы и результаты.

Откуда:
  • биография ISU (isuresults.com/bios/isufsNNNNNNNN.htm) — у всех, кто выступал на турнирах ISU:
    дата и место рождения, рост, с какого года катается, клуб, тренеры, хореографы, музыка программ,
    личные рекорды и лучшее в сезоне; её «Competition Results» (isufs_cr_…) — все результаты
    по видам турниров: Олимпиады, чемпионаты, Гран-при, челленджеры, национальные чемпионаты;
  • картотека ФФККР (сборные России) — звание, регион, клуб, тренеры, хореографы, старты сезона.

Каждый профиль — отдельный файл site/p/<ключ>.json: телефон берёт его, только когда профиль
открыт, и events.json от этого почти не растёт — у человека в справочнике лишь поле "p" с ключом.

Разобранные биографии копятся в data/bios.json и обновляются раз в неделю, а у того, кто выступил
после последней проверки, — в первую очередь: лучшее в сезоне не должно отставать от протоколов."""
import datetime as dt
import hashlib
import html
import json
import os
import re

from . import names as nm
from . import net

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "data", "bios.json")
OUT = os.path.join(ROOT, "site", "p")
BIO = "https://www.isuresults.com/bios/isufs{}.htm"
CR = "https://www.isuresults.com/bios/isufs_cr_{}.htm"
STALE = dt.timedelta(days=7)
BUDGET = 120  # биографий за сбор (по два запроса): остальное доберётся в следующий раз

KIND = {"women": "w", "ladies": "w", "men": "m", "pairs": "p", "ice dance": "d", "ice dancing": "d"}
# группы результатов ISU → по-русски; чего нет в списке — как у ISU
GROUPS = {
    "olympic games": "Олимпийские игры",
    "world championships": "Чемпионаты мира",
    "european championships": "Чемпионаты Европы",
    "four continents championships": "Чемпионаты четырёх континентов",
    "world junior championships": "Чемпионаты мира среди юниоров",
    "isu grand prix": "Гран-при",
    "isu grand prix final / isu junior grand prix final": "Финалы Гран-при",
    "isu junior grand prix": "Юниорский Гран-при",
    "isu challenger series": "Челленджеры",
    "world team trophy": "Командные чемпионаты мира",
    "isu world team trophy": "Командные чемпионаты мира",
    "international competition": "Международные турниры",
    "national championships": "Национальные чемпионаты",
}
# «Чемпионат Германии»: страны, чьи фигуристы чаще всего выступают на турнирах ISU
COUNTRY_OF = {
    "ARM": "Армении", "AUS": "Австралии", "AUT": "Австрии", "AZE": "Азербайджана", "BEL": "Бельгии",
    "BRA": "Бразилии", "BUL": "Болгарии", "CAN": "Канады", "CHN": "Китая", "CRO": "Хорватии", "CZE": "Чехии",
    "DEN": "Дании", "ESP": "Испании", "EST": "Эстонии", "FIN": "Финляндии", "FRA": "Франции",
    "GBR": "Великобритании", "GEO": "Грузии", "GER": "Германии", "GRE": "Греции", "HKG": "Гонконга",
    "HUN": "Венгрии", "IRL": "Ирландии", "ISR": "Израиля", "ITA": "Италии", "JPN": "Японии",
    "KAZ": "Казахстана", "KOR": "Республики Корея", "LAT": "Латвии", "LTU": "Литвы", "MAS": "Малайзии",
    "MEX": "Мексики", "MGL": "Монголии", "NED": "Нидерландов", "NOR": "Норвегии", "NZL": "Новой Зеландии",
    "PHI": "Филиппин", "POL": "Польши", "ROU": "Румынии", "SGP": "Сингапура", "SLO": "Словении",
    "SRB": "Сербии", "SUI": "Швейцарии", "SVK": "Словакии", "SWE": "Швеции", "THA": "Таиланда",
    "TUR": "Турции", "UKR": "Украины", "USA": "США", "UZB": "Узбекистана", "KGZ": "Киргизии",
}
# титул — место на пьедестале одного из этих турниров
_TITLE = re.compile(r"^(Олимпийские игры|Чемпионат |Первенство (России|Беларуси)|Финал (юниорского )?Гран-при|"
                    r"Национальный чемпионат)")


def key(name):
    """Ключ файла профиля: короткий и один и тот же для одного имени."""
    return hashlib.sha1(name.encode("utf-8")).hexdigest()[:12]


# ---------------------------------------------------------------- разбор страниц ISU

def _cells(page):
    out = []
    for c in re.findall(r"(?s)<td[^>]*>(.*?)</td>", page):
        c = re.sub(r"(?i)<br\s*/?>", " | ", c)
        c = html.unescape(re.sub(r"(?s)<[^>]+>", "", c)).replace("\xa0", " ")
        c = re.sub(r"\s+", " ", c).strip(" |")
        if c:
            out.append(c)
    return out


def _date(s):
    m = re.fullmatch(r"(\d\d)\.(\d\d)\.(\d{4})", s or "")
    return f"{m.group(3)}-{m.group(2)}-{m.group(1)}" if m else ""


def _list(s):
    """«Inna Goncharenko, Artem Fedorchenko» → [..]; пустое и «-» — []."""
    return [x.strip() for x in re.split(r",\s*|\s\|\s", s or "") if x.strip() and x.strip() not in ("-", "—")]


def _kind(cat):
    """«Junior Women» → «W», «Pairs» → «p»: буква вида, заглавная — юниоры. Неизвестное — ""."""
    low = (cat or "").lower().strip()
    junior = low.startswith("junior ")
    low = low.removeprefix("junior ").strip()
    k = KIND.get(low, "")
    return k.upper() if junior else k


def parse_bio(page):
    """Биография ISU → {who: [{n, born, place, h, since, club, former}], coach, choreo, fcoach,
    music: {season, sp, fs}, pb: [{s, pts, d, ev}], sb: [...] }. Чего нет на странице — нет и в ответе."""
    cells = _cells(page)
    is_label = lambda c: c.endswith(":")
    val = lambda i: cells[i + 1] if i + 1 < len(cells) and not is_label(cells[i + 1]) else ""
    who, out = [], {}
    cur = None
    for i, c in enumerate(cells):
        if c == "Date of birth:":
            cur = {}
            who.append(cur)
            j = i + 1
            if j < len(cells) and _date(cells[j]):
                cur["born"] = _date(cells[j])
                j += 1
            if j < len(cells) and re.search(r"\b[A-ZÀ-ÖØ-Þ][A-ZÀ-ÖØ-Þ'\-]+\b", cells[j]) and not is_label(cells[j]):
                cur["n"] = cells[j]
        elif cur is not None and c == "Place of birth:" and val(i):
            cur["place"] = val(i)
        elif cur is not None and c == "Height:":
            m = re.match(r"(\d{3}) cm", val(i))
            if m and 120 <= int(m.group(1)) <= 220:
                cur["h"] = int(m.group(1))
        elif cur is not None and c == "Start sk. / Club:":
            m = re.match(r"(\d{4})?\s*/?\s*(.*)$", val(i))
            if m and m.group(1):
                cur["since"] = int(m.group(1))
            if m and m.group(2).strip():
                cur["club"] = m.group(2).strip()
        elif cur is not None and c == "Former Partners:" and _list(val(i)):
            cur["former"] = _list(val(i))
        elif c == "Coach:" and _list(val(i)):
            out["coach"] = _list(val(i))
        elif c == "Choreographer:" and _list(val(i)):
            out["choreo"] = _list(val(i))
        elif c == "Former Coach:" and _list(val(i)):
            out["fcoach"] = _list(val(i))
        else:
            m = re.fullmatch(r"Music (.+?) as of season (\d{4})/(\d{4})", c)
            if m and i + 1 < len(cells) and not cells[i + 1].startswith(("Music ", "Personal Best", "Season Best")):
                seg = "sp" if re.search(r"(?i)short|rhythm", m.group(1)) else "fs"
                music = out.setdefault("music", {"season": f"{m.group(2)}/{m.group(3)[2:]}"})
                music[seg] = [x.strip() for x in cells[i + 1].split(" | ") if x.strip()]
                continue
            m = re.fullmatch(r"(Personal|Season) Best (?:Total )?Score ?(Short Program|Free Skating|Rhythm Dance|Free Dance|Short Dance)?",
                             c)
            if m and i + 3 < len(cells) and re.fullmatch(r"\d+\.\d\d", cells[i + 1]):
                seg = {"Short Program": "sp", "Rhythm Dance": "sp", "Short Dance": "sp",
                       "Free Skating": "fs", "Free Dance": "fs"}.get(m.group(2) or "", "total")
                out.setdefault("pb" if m.group(1) == "Personal" else "sb", []).append(
                    {"s": seg, "pts": cells[i + 1], "d": _date(cells[i + 2]), "ev": event_ru(cells[i + 3])})
    who = [w for w in who if w.get("n")]
    if who:
        out["who"] = who
    return out


def parse_cr(page):
    """«Competition Results» ISU → [{g: группа, r: [{ev, k, pl, c}]}] в порядке страницы
    (внутри группы — новые первыми). k — вид буквой, pl — место числом или как написано, c — страна."""
    groups = []
    for r in re.findall(r"(?s)<tr[^>]*>(.*?)</tr>", page):
        cells = [c for c in _cells("".join(re.findall(r"(?s)<td[^>]*>.*?</td>", r)))]
        if len(cells) == 1:
            groups.append({"g": cells[0], "r": []})
        elif len(cells) >= 3 and groups:
            pl = cells[2]
            row = {"ev": cells[0], "k": _kind(cells[1]), "pl": int(pl) if pl.isdigit() else pl}
            if len(cells) >= 4 and re.fullmatch(r"[A-Z]{3}\d?", cells[3]):
                row["c"] = cells[3]
            groups[-1]["r"].append(row)
    return [g for g in groups if g["r"]]


# ---------------------------------------------------------------- названия по-русски

def event_ru(raw, nation="", k=""):
    """Название турнира ISU → как в приложении: «Чемпионат мира 2026», «GP Finlandia Trophy 2025»."""
    s = re.sub(r"\s+Figure Skating$", "", raw.strip())
    s = re.sub(r",\s+[^,]+$", "", s) if re.search(r"\d{4}(/\d\d)?,\s", s) else s  # «…2021, Kosice» → без города
    s = re.sub(r"(\d{4})/\d\d(\d\d)$", r"\1/\2", s)  # «2009/2010» → «2009/10»
    y = re.search(r"(\d{4}(?:/\d\d)?)\s*$", s)
    year = y.group(1) if y else ""
    low = s.lower()
    tail = f" {year}" if year else ""
    if re.search(r"\bolympic winter games", low):  # и «XXIV Olympic Winter Games 2022»
        return "Олимпийские игры" + tail
    if "world junior championships" in low:
        return "Чемпионат мира среди юниоров" + tail
    if "world team trophy" in low:
        return "Командный чемпионат мира" + tail
    if re.search(r"world (figure skating )?championships", low):
        return "Чемпионат мира" + tail
    if "european" in low and "championships" in low:
        return "Чемпионат Европы" + tail
    if "four continents" in low:
        return "Чемпионат четырёх континентов" + tail
    if "junior grand prix final" in low or re.match(r"(isu )?jgp final", low):
        return "Финал юниорского Гран-при" + tail
    if "grand prix final" in low:
        return "Финал Гран-при" + tail
    if re.match(r"(?i)national champ", s):
        junior = k[:1].isupper()
        if nation in ("RUS", "AIN", "AIN1", "AIN2"):
            return ("Первенство России" if junior else "Чемпионат России") + tail
        if nation == "BLR":
            return ("Первенство Беларуси" if junior else "Чемпионат Беларуси") + tail
        where = COUNTRY_OF.get(nation)
        if where:
            return f"Чемпионат {where}" + (" среди юниоров" if junior else "") + tail
        return ("Национальный чемпионат среди юниоров" if junior else "Национальный чемпионат") + tail
    s = re.sub(r"^ISU\s+", "", s)
    s = re.sub(r"^GP (Grand Prix )?", "GP ", s)
    return re.sub(r" International( \d{4})$", r"\1", s) if s.startswith("GP ") else s


def group_ru(g):
    return GROUPS.get(g.lower().strip(), g)


# порядок титулов внутри сезона — по весу турнира
_WEIGHT = ("Олимпийские игры", "Чемпионат мира 2", "Финал Гран-при", "Чемпионат Европы", "Чемпионат четырёх",
           "Чемпионат мира среди", "Финал юниорского", "Чемпионат ", "Первенство ", "Национальный")


def season_of(ev):
    """Сезон турнира «2025/26» по названию. Финалы Гран-при — в декабре, у них год — начало сезона;
    чемпионаты и Олимпиада — зимой и весной, их год — конец сезона. Нет года — ""."""
    m = re.search(r"(\d{4})(?:/(\d\d))?$", ev)
    if not m:
        return ""
    y = int(m.group(1))
    if not m.group(2) and not ev.startswith("Финал"):
        y -= 1
    return f"{y}/{(y + 1) % 100:02d}"


def titles(res):
    """Пьедесталы главных турниров: [{ev, k, pl, y}] — новые сезоны первыми, внутри сезона по весу турнира."""
    out = []
    for g in res:
        for r in g["r"]:
            if isinstance(r["pl"], int) and 1 <= r["pl"] <= 3 and _TITLE.match(r["ev"]):
                out.append({"ev": r["ev"], "k": r["k"], "pl": r["pl"], "y": season_of(r["ev"])})
    weight = lambda ev: next((i for i, w in enumerate(_WEIGHT) if ev.startswith(w)), len(_WEIGHT))
    out.sort(key=lambda t: (weight(t["ev"]), t["pl"]))
    out.sort(key=lambda t: t["y"], reverse=True)
    return out


# ---------------------------------------------------------------- кэш и сборка

def _load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def refresh(ids, competed=None, log=print, path=None, budget=BUDGET, now=None):
    """Обновить биографии ISU в кэше. ids — {ключ имени: номер биографии ISU} из этого сбора
    (копится: кого нет в этом сборе, тот остаётся с прежним номером); competed — {ключ имени: когда
    последний раз выступал (iso)}: такие обновляются первыми, если выступили после последней проверки.
    Возвращает кэш {"ids": {ключ имени: номер}, "bios": {номер: {at, bio, cr}}}."""
    path = path or CACHE
    now = now or dt.datetime.now(dt.timezone.utc)
    store = _load(path)
    store.setdefault("ids", {}).update(ids or {})
    c = store.setdefault("bios", {})
    competed_id = {}
    for k, when in (competed or {}).items():
        i = store["ids"].get(k)
        if i and when > competed_id.get(i, ""):
            competed_id[i] = when
    bios = set(store["ids"].values())

    def due(i):
        old = c.get(i)
        if not old:
            return (0, "")
        if competed_id.get(i, "") > old["at"]:
            return (1, old["at"])
        if now - dt.datetime.fromisoformat(old["at"]) >= STALE:
            return (2, old["at"])
        return None

    todo = sorted((d, i) for i in bios for d in [due(i)] if d is not None)
    fetched = 0
    for _, i in todo:
        if fetched >= budget:
            break
        fetched += 1
        try:
            bio = parse_bio(net.fetch(BIO.format(i), timeout=40))
            cr = parse_cr(net.fetch(CR.format(i), timeout=40))
        except net.FetchError as e:
            log(f"  ! биография ISU {i}:", e)
            continue
        if not bio.get("who") and not cr:
            continue  # страница пустая или другая: прежнее не стираем
        c[i] = {"at": now.isoformat(), "bio": bio, "cr": cr}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        # по строке на биографию: в истории git меняется только обновлённое
        f.write("{\"ids\":" + json.dumps(store["ids"], ensure_ascii=False, sort_keys=True) + ",\n\"bios\":{\n")
        f.write(",\n".join(json.dumps(i) + ":" + json.dumps(c[i], ensure_ascii=False, separators=(",", ":"),
                                                             sort_keys=True) for i in sorted(c)))
        f.write("\n}}\n")
    log(f"  биографии ISU: {len(c)} в кэше, обновлено {fetched}, ждут {max(0, len(todo) - fetched)}")
    return store


def ru_quotes(s):
    """Прямые кавычки картотеки → «ёлочки»: «школа "Хрустальный"» → «школа «Хрустальный»»."""
    return re.sub(r'"([^"]*)"', r"«\1»", s)


def _card_who(card):
    w = {}
    if card.get("born"):
        w["born"] = card["born"]
    for k in ("rank", "region"):
        if card.get(k):
            w[k] = card[k]
    if card.get("club"):
        w["club"] = ru_quotes(", ".join(card["club"]))
    return w


def profile(name, nation, bio=None, card=None, cards_by_name=None):
    """Профиль для телефона. name — как в приложении («Анна Билибина / Дмитрий Кашаев»),
    bio — запись кэша ISU или None, card — карточка картотеки одиночника или None;
    cards_by_name — {имя: карточка} для партнёров пары."""
    out = {"n": name}
    parts = [p.strip() for p in name.split(" / ")]
    who = [{"n": p} for p in parts]
    src = []
    if bio:
        b = bio["bio"]
        src.append("ISU")
        isu_who = b.get("who") or []
        if len(isu_who) == len(who):
            for w, x in zip(who, isu_who):
                for k in ("born", "place", "h", "since", "club", "former"):
                    if k in x:
                        w[k] = [nm.pretty_latin(f) for f in x[k]] if k == "former" else x[k]
        for k in ("coach", "choreo", "fcoach", "music", "pb", "sb"):
            if b.get(k):
                out[k] = b[k]
        res = []
        for g in bio["cr"]:
            rows = []
            for r in g["r"]:
                ev = event_ru(r["ev"], r.get("c") or nation, r["k"])
                rows.append({k: v for k, v in (("ev", ev), ("k", r["k"]), ("pl", r["pl"])) if v != ""})
            res.append({"g": group_ru(g["g"]), "r": rows})
        if res:
            out["res"] = res
            t = titles(res)
            if t:
                out["titles"] = t
    # картотека ФФККР — по-русски и официально: её поля важнее латиницы ISU
    cards_by_name = cards_by_name or {}
    season = []
    for w in who:
        cd = card if (card and len(who) == 1) else cards_by_name.get(w["n"])
        if not cd:
            continue
        w.update(_card_who(cd))
        if len(who) == 1:
            for k, ck in (("coach", "coach"), ("choreo", "choreo")):
                if cd.get(ck):
                    out[k] = cd[ck]
            out.pop("fcoach", None) if cd.get("coach") else None
        season = season or cd.get("results") or []
        if "ФФККР" not in src:
            src.append("ФФККР")
    if season:
        out["season"] = [{"s": r.get("season", "").replace("-20", "/"), "ev": ru_quotes(r["event"]), "pl": r["place"]}
                         for r in season if r.get("event")]
    out["who"] = who
    out["src"] = src
    return out if src else None


def write(people, store, cards, out_dir=None, log=print):
    """Записать профили и проставить людям ключ "p". people — справочник [{n, c, k}];
    store — кэш биографий из refresh; cards — {номер: карточка картотеки с fio}."""
    from .people import card_name
    out_dir = out_dir or OUT
    ids, cache = store.get("ids", {}), store.get("bios", {})
    by_name = {}
    for cd in (cards or {}).values():
        n = card_name(cd.get("fio", ""))
        if n:
            by_name[nm.key(n)] = cd
    cards_by_name = {}
    os.makedirs(out_dir, exist_ok=True)
    written = 0
    for p in people:
        name = p["n"]
        parts = [x.strip() for x in name.split(" / ")]
        for x in parts:
            if nm.key(x) in by_name:
                cards_by_name[x] = by_name[nm.key(x)]
        bio = cache.get(ids.get(nm.key(name), ""))
        card = by_name.get(nm.key(name)) if len(parts) == 1 else None
        pr = profile(name, p.get("c", ""), bio, card, cards_by_name)
        if not pr:
            p.pop("p", None)
            continue
        pr["at"] = max([bio["at"] if bio else ""] + [(card or {}).get("at", "")] +
                       [cards_by_name[x].get("at", "") for x in parts if x in cards_by_name])[:10]
        k = key(name)
        fn = os.path.join(out_dir, k + ".json")
        body = json.dumps(pr, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        try:
            with open(fn, encoding="utf-8") as f:
                same = f.read() == body
        except OSError:
            same = False
        if not same:
            with open(fn, "w", encoding="utf-8") as f:
                f.write(body)
            written += 1
        p["p"] = k
    log(f"  профили: у {sum(1 for p in people if p.get('p'))} человек, переписано {written}")
    return people
