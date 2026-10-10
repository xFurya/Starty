"""Примечательное в сегменте — то, что не бывает на каждом турнире.

Источник — судейские оценки (…JudgesDetailsperSkater.pdf) и статистика ISU
(isuresults.com/isujsstat): прогрессия высших оценок (мировые рекорды), личные
рекорды и лучшие оценки сезона. Считается один раз, когда протокол утверждён,
и запоминается в data/facts.json: статистика ISU потом пополнится этим же
турниром, и пересчёт уже не увидел бы, что рекорд был побит здесь.

Факт — {"who": «Имя Фамилия», "text": «Четверной аксель», "kind": record|element|score|place}.
"""
import html
import re
import unicodedata

from . import net

STAT = "https://www.isuresults.com/isujsstat/"
_cache = {}

ROT = {1: "одинарный", 2: "двойной", 3: "тройной", 4: "четверной", 5: "пятиоборотный"}
JUMP_RU = {"A": "аксель", "Lz": "лутц", "F": "флип", "Lo": "риттбергер", "S": "сальхов", "T": "тулуп",
           "Eu": "ойлер"}
JUMP = re.compile(r"^([1-5])(A|Lz|F|Lo|S|T|Eu)((?:<<|<|q|e|!|\*|F|V)*)$")
THROW = re.compile(r"^([1-5])(A|Lz|F|Lo|S|T)Th((?:<<|<|q|e|!|\*|F|V)*)$")
TWIST = re.compile(r"^([1-5])Tw")


def _key(name):
    s = unicodedata.normalize("NFKD", name)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-zа-я/]", "", s.lower().replace("ё", "е"))


def _jump(part):
    """«4Lz<» → (4, "Lz", "<") или None. Пропуск, «Eu» без цифры — 1Eu."""
    if part == "Eu":
        return (1, "Eu", "")
    m = JUMP.match(part)
    return (int(m.group(1)), m.group(2), m.group(3)) if m else None


def _credited(rot, marks):
    """Засчитан ли прыжок в полное число оборотов: не понижен (<<) и не отменён (*)."""
    return rot and "<<" not in marks and "*" not in marks


def _jumps(code):
    parts = [p for p in code.split("+") if p not in ("SEQ", "COMBO", "REP")]
    out = [_jump(p) for p in parts]
    return out if out and all(out) else None


def _fmt(x):
    return f"{x:.2f}"


def _plural(n, one, few, many):
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return few
    return many


# ---------------------------------------------------------------- элементы

def element_facts(sk, kind, level, seg):
    """Факты одного проката по элементам: [(kind, text)]."""
    out = []
    quads = []
    for el in sk["elements"]:
        code = el["code"]
        info = el.get("info", "")
        js = _jumps(code)
        if js:
            credited = [(r, j, m) for r, j, m in js if _credited(r, m + info)]
            for r, j, m in credited:
                if r == 5:
                    out.append(("element", f"Пятиоборотный {JUMP_RU[j]}"))
                elif r == 4 and j == "A":
                    under = "<" in m or "<" in info
                    out.append(("element", "Четверной аксель" + (", недокрут" if under else "")))
                elif r == 3 and j == "A" and kind == "women":
                    out.append(("element", "Тройной аксель"))
            quads += [f"4{j}" for r, j, m in credited if r == 4]
            big = [(r, j) for r, j, m in credited if r >= 3 and j != "Eu"]
            nq = sum(1 for r, j in big if r >= 4)
            na = sum(1 for r, j in big if r == 3 and j == "A")
            if len(js) >= 2 and (nq >= 2 or (nq >= 1 and na >= 1) or na >= 2 or (nq >= 1 and len(big) >= 3)):
                clean = "+".join(p for p in code.split("+") if p not in ("SEQ", "COMBO", "REP"))
                out.append(("element", f"Каскад {clean}"))
            continue
        m = THROW.match(code)
        if m and int(m.group(1)) >= 4 and _credited(4, m.group(3) + info):
            out.append(("element", f"Четверной выброс {JUMP_RU[m.group(2)]}"))
            continue
        m = TWIST.match(code)
        if m and int(m.group(1)) >= 4:
            out.append(("element", "Четверная подкрутка"))
            continue
    # четверные: у женщин и пар — любой, у юношей — три и больше, у мужчин в ПП — пять и больше
    n = len(quads)
    need = {"women": 1, "pairs": 1}.get(kind, 3 if level == "junior" else (5 if seg == "ПП" else 99))
    if n >= need and kind != "dance":
        if n == 1 and kind in ("women", "pairs"):
            q = quads[0]
            r, j, _ = _jump(q)
            out.append(("element", f"Четверной {JUMP_RU[j]}" + (" (параллельный)" if kind == "pairs" else "")))
        elif n > 1:
            word = _plural(n, "четверной", "четверных", "четверных")
            out.append(("element", f"{n} {word} в программе: {', '.join(quads)}"))
    # единогласные высшие оценки
    for el in sk["elements"]:
        j = el.get("judges") or []
        if len(j) >= 3 and all(v == 5 for v in j):
            out.append(("element", f"Все судьи — +5 за {el['code']}"))
    for c in sk.get("components", []):
        j = c.get("judges") or []
        if len(j) >= 3 and all(v >= 10 for v in j):
            ru = {"Composition": "композицию", "Presentation": "представление",
                  "Skating Skills": "мастерство катания", "Skating skills": "мастерство катания"}.get(c["name"], c["name"])
            out.append(("element", f"Все судьи — 10 за {ru}"))
    # повторы одного факта (два четверных акселя) — один раз
    seen, uniq = set(), []
    for f in out:
        if f not in seen:
            seen.add(f)
            uniq.append(f)
    return uniq


# ---------------------------------------------------------------- статистика ISU

KIND_CODE = {"men": "m", "women": "w", "pairs": "p", "dance": "d"}
SEG_CODE = {"КП": "sp", "ПП": "fs", "РТ": "rd", "ПТ": "fd", "total": "to"}


def _stat(path):
    """Строки таблицы статистики: [{name, score, level, event, date}]; пусто — нет страницы."""
    if path in _cache:
        return _cache[path]
    rows = []
    try:
        page = net.fetch(STAT + path, timeout=40)
    except net.FetchError:
        _cache[path] = rows
        return rows
    for r in re.findall(r"(?s)<tr[^>]*>(.*?)</tr>", page):
        cells = [re.sub(r"\s+", " ", html.unescape(re.sub(r"(?s)<[^>]+>", " ", c))).strip()
                 for c in re.findall(r"(?s)<t[dh][^>]*>(.*?)</t[dh]>", r)]
        cells = [c for c in cells if c]
        if len(cells) < 5 or not re.fullmatch(r"\d+", cells[0]):
            continue
        lvl = cells[-1] if cells[-1] in ("S", "J") else ""
        nums = [c for c in cells if re.fullmatch(r"\d{1,3}\.\d\d", c)]
        if not nums:
            continue
        date = next((c for c in cells if re.fullmatch(r"\d\d/\d\d/\d{4}", c)), "")
        rows.append({"name": cells[1], "score": float(nums[-1]), "level": lvl,
                     "event": cells[3] if len(cells) > 3 else "", "date": date})
    _cache[path] = rows
    return rows


def score_facts(name, score, kind, level, seg, season, ours_or_top):
    """Оценка против статистики ISU: мировой рекорд (взрослые), лучшая оценка сезона
    в мире (своего уровня) и личный рекорд (у россиян, белорусов и тройки)."""
    k, s = KIND_CODE.get(kind), SEG_CODE.get(seg)
    if not k or not s:
        return []
    out = []
    what = {"to": "сумма", "sp": "оценка сезона за КП", "fs": "оценка сезона за ПП",
            "rd": "оценка сезона за РТ", "fd": "оценка сезона за ПТ"}[s]
    if s == "to":
        what = "сумма сезона"
    if level == "senior":
        wr = _stat(f"phs{k}{s}.htm")
        if wr:
            best = max(wr, key=lambda r: r["score"])
            if score > best["score"]:
                where = {"to": "по сумме", "sp": "за КП", "fs": "за ПП", "rd": "за РТ", "fd": "за ПТ"}[s]
                out.append(("record", f"Выше исторического рекорда {where}: {_fmt(score)} (рекорд {_fmt(best['score'])})"))
    sb = [r for r in _stat(f"sb{season}/sbts{k}{s}.htm") if r["level"] == ("J" if level == "junior" else "S")]
    if sb and not out:
        top = max(r["score"] for r in sb)
        if score > top:
            who = "среди юниоров" if level == "junior" else "в мире"
            out.append(("score", f"Лучшая {who} {what}: {_fmt(score)}"))
    if ours_or_top:
        pb = {}
        for r in _stat(f"pbs{k}{s}.htm"):
            pb.setdefault(_key(r["name"]), r["score"])
        old = pb.get(_key(name))
        if old is not None and score > old:
            where = {"to": "по сумме", "sp": "за КП", "fs": "за ПП", "rd": "за РТ", "fd": "за ПТ"}[s]
            out.append(("score", f"Личный рекорд {where}: {_fmt(score)} (был {_fmt(old)})"))
    return out


# ---------------------------------------------------------------- итоги вида

def place_facts(seg_places, final_rows, intl, who_key, margin_min):
    """По итогу вида: взлёт после первого сегмента, весь пьедестал — наши, большой отрыв.
    seg_places — {ключ имени: место после первого сегмента}; final_rows — итог по местам."""
    out = []
    top = sorted(final_rows, key=lambda r: r["place"])[:3]
    for r in top:
        first = seg_places.get(_key(r["name"]))
        if first and first - r["place"] >= 3:
            out.append((r["name"], "place", f"После первого сегмента — {first}-е место, в итоге — {r['place']}-е"))
    if intl and len(top) == 3:
        sides = {who_key(r) for r in top}
        if sides <= {"ru", "by"} and sides:
            text = {"ru": "россияне", "by": "белорусы"}
            label = text[next(iter(sides))] if len(sides) == 1 else "россияне и белорусы"
            out.append(("", "place", f"Весь пьедестал — {label}"))
    if len(top) >= 2:
        try:
            gap = float(top[0]["points"]) - float(top[1]["points"])
        except (TypeError, ValueError):
            gap = 0
        if gap >= margin_min:
            out.append((top[0]["name"], "place", f"Отрыв от второго места — {_fmt(gap)} балла"))
    return out
