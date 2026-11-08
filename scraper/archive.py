"""Архив элементов из судейских протоколов — источник «Примечательного» в профиле.

Копится в data/archive.json из протоколов (…JudgesDetailsperSkater.pdf): прошлые сезоны с 2018/19
заливает scraper/backfill.py (ISU и ФФККР), дальше — каждый протокол, который читает сбор
(results.segment_facts). С 2018/19 действуют нынешние базовые стоимости и шкала GOE −5…+5: раньше
стоимости были другими, сравнивать с ними нельзя. Поэтому рекорды звучат «с 2018 года», а не
«в истории» — что было до архива, он не знает.

У каждого спортсмена (ключ — names.key имени из протокола):
  el   редкие элементы, исполненные чисто: полное вращение (без <, <<, *) и без падения. Прыжки от
       четверных и тройной аксель, каскады и секвенции с ними, выбросы от четверных и тройной
       аксель выбросом, четверная подкрутка.
       код → [сколько раз, первый протокол, база без надбавки за вторую половину, протокол с ней]
  q    программа с наибольшим числом чистых четверных (от двух): [число, протокол, «4F 4Lo 4T»]
  p5   единогласные +5: код → первый протокол; c10 — все судьи 10 за компонент
pop — кто вообще выступал в каждом виде и уровне: по нему считается, насколько элемент редок.
full — прошлые сезоны залиты (scraper/backfill.py). Пока нет, профилю архив не даёт ничего:
«больше всех с 2018 года» по одному нынешнему сезону было бы неправдой.
Протокол — номер строки в segs: [адрес PDF, турнир, дата, вид, уровень, сегмент, источник].

Оценки за элементы (GOE) в рекорды не идут: архив видит не все турниры (национальные чемпионаты
других стран, прошлые «Челленджеры»), а судейство на них разное. Стоимость и число четверных от
судейства не зависят, а самое дорогое исполняется на турнирах, которые архив видит.
"""
import json
import os
import re
import statistics
import urllib.parse

from . import facts as fx
from . import names as nm

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARCHIVE = os.path.join(ROOT, "data", "archive.json")
SINCE = "с 2018 года"
FIRST_DAY = "2018-07-01"  # начало сезона 2018/19 — нынешних стоимостей

SEG_RU = {"КП": "короткая программа", "ПП": "произвольная программа", "РТ": "ритм-танец",
          "ПТ": "произвольный танец"}
KIND_RU = {"men": "у мужчин", "women": "у женщин", "pairs": "у пар"}
COMP_RU = {"Composition": "композицию", "Presentation": "представление", "Skating Skills": "мастерство катания",
           "Skating skills": "мастерство катания"}


# ---------------------------------------------------------------- хранилище

def empty():
    return {"v": 1, "segs": [], "ath": {}, "pop": {}}


def load(path=ARCHIVE):
    try:
        with open(path, encoding="utf-8") as f:
            arc = json.load(f)
        if not isinstance(arc, dict) or arc.get("v") != 1:
            arc = empty()
    except (OSError, ValueError):
        arc = empty()
    for k, v in empty().items():
        arc.setdefault(k, v)
    return arc


def _index(arc):
    if "_idx" not in arc:
        arc["_idx"] = {s[0]: i for i, s in enumerate(arc["segs"])}
        arc["_pop"] = {k: set(v) for k, v in arc["pop"].items()}
    return arc["_idx"]


def has(arc, url):
    return url in _index(arc)


def save(arc, path=ARCHIVE):
    """Одна строка — один протокол или один спортсмен: правка в git — несколько строк, а не файл целиком."""
    _index(arc)
    segs, keys, pops = arc["segs"], sorted(arc["ath"]), sorted(arc["_pop"])

    def rows(items):
        return [x + ("," if i < len(items) - 1 else "") for i, x in enumerate(items)]

    lines = ['{"v": 1, "full": true,' if arc.get("full") else '{"v": 1,', '"segs": [']
    lines += rows([json.dumps(s, ensure_ascii=False) for s in segs])
    lines += ["],", '"ath": {']
    lines += rows([json.dumps(k, ensure_ascii=False) + ": " + json.dumps(arc["ath"][k], ensure_ascii=False,
                                                                       sort_keys=True) for k in keys])
    lines += ["},", '"pop": {']
    lines += rows([json.dumps(k, ensure_ascii=False) + ": " + json.dumps(sorted(arc["_pop"][k]), ensure_ascii=False)
                   for k in pops])
    lines += ["}}"]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def source_of(url, tournament):
    """Чей протокол: ISU, ФФККР, ФФКМ — по адресу; у остальных источник — сам турнир."""
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    for end, name in (("isu.org", "ISU"), ("isuresults.com", "ISU"), ("fsrussia.ru", "ФФККР"), ("ffkm.ru", "ФФКМ")):
        if host == end or host.endswith("." + end):
            return name
    return tournament


# ---------------------------------------------------------------- разбор элемента

def _fallen(el, marks):
    """Падение: F в графе отметок или в отметках прыжка (не «4F» — это флип); если отметок нет —
    все судьи в середине не выше −4 (за падение ставят −5)."""
    if "F" in el.get("info", "").split() or any("F" in m for m in marks):
        return True
    j = el.get("judges") or []
    if j:
        return statistics.median(j) <= -4
    return el.get("base", 0) > 0 and el.get("goe", 0) / el["base"] <= -0.4


def _full(marks):
    """Полное вращение: не недокрут (<), не понижение (<<), не отменён (*). q — засчитан полностью."""
    return "<" not in marks and "*" not in marks


def _base(el):
    """База без надбавки 10 % за вторую половину программы."""
    b = el["base"] / 1.1 if el.get("x") else el["base"]
    return round(b + 1e-9, 2)


def notable_jump(r, j):
    return r >= 4 or (r == 3 and j == "A")


def _parts_full(js, info):
    """Полное ли вращение у каждого прыжка. Отметки в коде у каждого прыжка свои, а графа info —
    сводка по элементу: если в коде отметок нет, а в info недокрут есть, чей он — не знаем, и
    неполным считается весь элемент."""
    in_code = any(mk for _, _, mk in js)
    info_ok = _full(info)
    return [_full(mk) and (in_code or info_ok) for _, _, mk in js]


def items(el):
    """Что из элемента идёт в архив: [(код, база без надбавки или None)]. Элемент с падением — ничего."""
    code, info = el["code"], el.get("info", "")
    parts = code.split("+")
    m = fx.TWIST.match(code)
    if m:
        return [("4Tw", None)] if int(m.group(1)) >= 4 and not _fallen(el, []) else []
    m = fx.THROW.match(code)
    if m:
        r, j, mk = int(m.group(1)), m.group(2), m.group(3)
        ok = notable_jump(r, j) and _full(mk + info) and not _fallen(el, [mk])
        return [(f"{r}{j}Th", None)] if ok else []
    js = fx._jumps(code)
    if not js or _fallen(el, [mk for _, _, mk in js]):
        return []
    full = _parts_full(js, info)
    rep = "REP" in parts
    out = []
    for (r, j, _), ok in zip(js, full):
        c = f"{r}{j}"
        if ok and notable_jump(r, j) and c not in [x for x, _ in out]:
            out.append((c, None))
    if len(js) >= 2:
        if all(full) and any(notable_jump(r, j) for r, j, _ in js):
            name = "+".join(f"{r}{j}" for r, j, _ in js) + ("+SEQ" if "SEQ" in parts else "")
            out.append((name, None if rep else _base(el)))
    elif out and not rep:
        out = [(out[0][0], _base(el))]
    return out


def quads(sk):
    """Чистые четверные программы по порядку: ["4F", "4Lo", …]."""
    out = []
    for el in sk.get("elements", []):
        js = fx._jumps(el["code"])
        if not js or _fallen(el, [mk for _, _, mk in js]):
            continue
        out += [f"{r}{j}" for (r, j, _), ok in zip(js, _parts_full(js, el.get("info", ""))) if r == 4 and ok]
    return out


def _plain_code(code):
    js = fx._jumps(code)
    if js:
        return "+".join(f"{r}{j}" for r, j, _ in js)
    m = fx.THROW.match(code)
    return f"{m.group(1)}{m.group(2)}Th" if m else code


# ---------------------------------------------------------------- пополнение

def _earlier(arc, i, j):
    """Протокол i раньше протокола j: по дате, при равной — по порядку в архиве."""
    return (arc["segs"][i][2], i) < (arc["segs"][j][2], j)


def ingest(arc, skaters, meta):
    """Протокол сегмента в архив (на месте). meta: {u, ev, d, kind, level, seg, src}.
    Тот же адрес второй раз не берётся; протоколы раньше 2018/19 не берутся. → взят ли."""
    idx = _index(arc)
    u, kind, level = meta["u"], meta["kind"], meta.get("level") or "senior"
    if u in idx or not skaters or (meta.get("d") or "") < FIRST_DAY:
        return False
    i = len(arc["segs"])
    arc["segs"].append([u, meta.get("ev", ""), meta["d"], kind, level, meta.get("seg", ""), meta.get("src", "")])
    idx[u] = i
    pop = arc["_pop"].setdefault(f"{kind}|{level}", set())
    for sk in skaters:
        key = nm.key(sk.get("name", ""))
        if not key:
            continue
        pop.add(key)
        box = {}

        def me():
            if not box:
                rec = arc["ath"].setdefault(key, {"n": sk["name"], "c": [], "k": kind})
                if sk.get("nation") and sk["nation"] not in rec["c"]:
                    rec["c"].append(sk["nation"])
                if nm.is_cyr(sk["name"]) and not nm.is_cyr(rec["n"]):
                    rec["n"] = sk["name"]
                box["r"] = rec
            return box["r"]

        for el in sk.get("elements", []):
            for code, base in items(el):
                e = me().setdefault("el", {})
                cur = e.get(code)
                if cur is None:
                    e[code] = [1, i, base, i if base is not None else None]
                    continue
                cur[0] += 1
                if _earlier(arc, i, cur[1]):
                    cur[1] = i
                if base is not None and (cur[2] is None or base > cur[2] + 1e-9
                                         or (abs(base - cur[2]) < 1e-9 and _earlier(arc, i, cur[3]))):
                    cur[2], cur[3] = base, i
            j = el.get("judges") or []
            if len(j) >= 3 and all(v == 5 for v in j):
                p5 = me().setdefault("p5", {})
                c = _plain_code(el["code"])
                if c not in p5 or _earlier(arc, i, p5[c]):
                    p5[c] = i
        q = quads(sk)
        if len(q) >= 2:
            old = me().get("q")
            if not old or len(q) > old[0] or (len(q) == old[0] and _earlier(arc, i, old[1])):
                me()["q"] = [len(q), i, " ".join(q)]
        for c in sk.get("components", []):
            j = c.get("judges") or []
            if len(j) >= 3 and all(v >= 10 for v in j):
                c10 = me().setdefault("c10", {})
                if c["name"] not in c10 or _earlier(arc, i, c10[c["name"]]):
                    c10[c["name"]] = i
    return True


# ---------------------------------------------------------------- вывод: рекорды и редкое

def title(code):
    """«4Lz» → «Четверной лутц», «4T+3A+3A+SEQ» → «Секвенция 4T+3A+3A», «4STh» → «Четверной выброс сальхов»."""
    if code == "4Tw":
        return "Четверная подкрутка"
    m = re.fullmatch(r"(\d)(A|Lz|F|Lo|S|T)Th", code)
    if m:
        r, j = int(m.group(1)), m.group(2)
        return "Тройной аксель выбросом" if r == 3 else f"{fx.ROT[r].capitalize()} выброс {fx.JUMP_RU[j]}"
    parts = code.split("+")
    jumps = [p for p in parts if p != "SEQ"]
    if len(jumps) == 1:
        r, j, _ = fx._jump(jumps[0])
        return f"{fx.ROT[r].capitalize()} {fx.JUMP_RU[j]}"
    return f"{'Секвенция' if 'SEQ' in parts else 'Каскад'} {'+'.join(jumps)}"


def _jump_element(code):
    return not code.endswith("Tw") and not code.endswith("Th")


def signature(code):
    """Чем элемент примечателен — по нему считается редкость. Отдельный прыжок, выброс, подкрутка —
    они сами; каскад и секвенция — их прыжки от четверных и тройного акселя, без порядка и мелких
    прыжков: 4Lz+3T и 4Lz+1Eu+3S+SEQ — один «каскад с 4Lz», иначе редким выглядел бы каждый вариант."""
    parts = [p for p in code.split("+") if p != "SEQ"]
    if not _jump_element(code) or len(parts) == 1:
        return code
    big = sorted(p for p in parts if notable_jump(*fx._jump(p)[:2]))
    return "+" + "+".join(big)


# редкий элемент — тот, что чисто исполнили не больше RARE_SHARE спортсменов вида (но хотя бы RARE_MIN)
RARE_SHARE = 0.02
RARE_MIN = 3


class Index:
    """Архив, готовый к профилям: рекорды по видам и редкость элементов."""

    def __init__(self, arc):
        self.arc = arc
        _index(arc)
        self.ready = bool(arc.get("full"))
        self.ath = arc["ath"]
        pop = {}
        for kl, keys in arc["_pop"].items():
            pop.setdefault(kl.split("|")[0], set()).update(keys)
        self.pop = {k: len(v) for k, v in pop.items()}
        self.performers = {}
        for a in self.ath.values():
            for sig in {signature(c) for c in a.get("el", {})}:
                self.performers[(a["k"], sig)] = self.performers.get((a["k"], sig), 0) + 1
        self.records = self._records()

    def rare(self, kind, code):
        n = self.performers.get((kind, signature(code)), 0)
        return 0 < n <= max(RARE_MIN, RARE_SHARE * self.pop.get(kind, 0))

    def _records(self):
        """{(что, вид): (значение, {ключи хозяев})}: base — самый дорогой прыжковый элемент,
        quads — больше всего чистых четверных в одной программе. У пар и танцев их нет."""
        best = {}

        def put(what, kind, value, key):
            cur = best.get((what, kind))
            if cur is None or value > cur[0] + 1e-9:
                best[(what, kind)] = (value, {key})
            elif abs(value - cur[0]) < 1e-9:
                cur[1].add(key)

        for key, a in self.ath.items():
            if a["k"] not in ("men", "women"):
                continue
            for code, (n, first, base, bi) in a.get("el", {}).items():
                if base is not None and _jump_element(code):
                    put("base", a["k"], base, key)
            if a.get("q"):
                put("quads", a["k"], a["q"][0], key)
        return best

    def qualifier(self, what, kind):
        """Пусто — рекорд вида и общий; иначе « у женщин»."""
        top = max((v for (w, _), (v, _) in self.records.items() if w == what), default=None)
        mine = self.records.get((what, kind))
        if mine and top is not None and mine[0] >= top - 1e-9:
            return ""
        return " " + KIND_RU[kind]


def _seg_row(arc, i):
    u, ev, d, kind, level, seg, src = arc["segs"][i]
    return {"ev": ev + (f", {SEG_RU[seg]}" if seg in SEG_RU else ""), "d": d, "src": src, "u": u}


def _same_nation(nation, seen):
    """Страна профиля — одна из тех, за кого он выступал в протоколах, или та же сторона (RUS и AIN —
    одна). Страна неизвестна — не мешает."""
    if not nation or not seen:
        return True
    from .results import side
    mine = side(nation)
    return any(c == nation or (mine and side(c) == mine) for c in seen)


# порядок групп: рекорды архива, редкие элементы, программа с четверными, +5, 10
GROUP = {"record": 1, "rare": 2, "quads": 3, "plus5": 4, "ten": 5}


def for_profile(name, nation, index):
    """Строки «Примечательного» из архива: [{t, ev, d, pts?, src, u, g}]; g — группа для порядка."""
    if index is None or not index.ready:
        return []
    key = nm.key(name)
    a = index.ath.get(key)
    if not a or not _same_nation(nation, a.get("c")):
        return []
    arc, kind = index.arc, a["k"]
    els = a.get("el", {})
    out, used = [], set()

    def when(i):
        return arc["segs"][i][2]

    rec = index.records.get(("base", kind))
    if rec and key in rec[1]:
        code = min((c for c, v in els.items() if v[2] is not None and _jump_element(c) and abs(v[2] - rec[0]) < 1e-9),
                   key=lambda c: (when(els[c][3]), c))
        out.append(dict(_seg_row(arc, els[code][3]), g=GROUP["record"], pts=f"{rec[0]:.2f}", c=code,
                        t=f"Самый дорогой прыжковый элемент{index.qualifier('base', kind)} {SINCE}: "
                          f"{code.replace('+SEQ', '')}"))
        used.add(code)
    rec = index.records.get(("quads", kind))
    if rec and key in rec[1]:
        n, i, codes = a["q"]
        word = fx._plural(n, "четверной", "четверных", "четверных")
        out.append(dict(_seg_row(arc, i), g=GROUP["record"],
                        t=f"{n} {word} в одной программе — больше всех{index.qualifier('quads', kind)} {SINCE}"))
        used.add("q")
    # редкие элементы — по первому разу в архиве; из вариантов одного каскада — самый ранний
    rare, seen = [], {signature(c) for c in used}
    for c, v in sorted(els.items(), key=lambda x: (when(x[1][1]), x[0])):
        sig = signature(c)
        if sig not in seen and index.rare(kind, c):
            seen.add(sig)
            rare.append(dict(_seg_row(arc, v[1]), g=GROUP["rare"], t=title(c), c=c))
    out += _drop_echo(rare, out + rare)
    # программа с четверными: у женщин и пар — от двух, у юниоров — от трёх, у мужчин — от пяти
    if a.get("q") and "q" not in used:
        n, i, codes = a["q"]
        need = 2 if kind in ("women", "pairs") else (3 if arc["segs"][i][4] == "junior" else 5)
        if n >= need:
            word = fx._plural(n, "четверной", "четверных", "четверных")
            out.append(dict(_seg_row(arc, i), g=GROUP["quads"],
                            t=f"{n} {word} в одной программе: {', '.join(codes.split())}"))
    for code, i in sorted(a.get("p5", {}).items(), key=lambda x: (when(x[1]), x[0])):
        out.append(dict(_seg_row(arc, i), g=GROUP["plus5"], t=f"Все судьи — +5 за {code}"))
    for comp, i in sorted(a.get("c10", {}).items(), key=lambda x: (when(x[1]), x[0])):
        out.append(dict(_seg_row(arc, i), g=GROUP["ten"], t=f"Все судьи — 10 за {COMP_RU.get(comp, comp)}"))
    for x in out:
        x.pop("c", None)
    return out


def _drop_echo(rows, named):
    """Отдельный прыжок с того же старта, что и названный каскад с ним (редкий или рекордный), —
    уже назван в каскаде."""
    combos = [x for x in named if "+" in x.get("c", "")]
    return [r for r in rows if "+" in r["c"] or not any(
        r["u"] == x["u"] and r["c"] in x["c"].split("+") for x in combos)]
