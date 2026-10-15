"""Разбор табло Swiss Timing (FS Manager): index.htm, стартовые листы SEGnnn.htm,
заявки CATnnnEN.htm, итоги CATnnnRS.htm и PDF «Start List with Times».

Этот формат одинаков у ISU (results.isu.org), у организаторов челленджеров и у
ФФККР (fsrussia.ru/results/...), поэтому один разборщик кормит обе стороны.

Когда сегмент прошёл, та же страница SEGnnn.htm показывает протокол (шапка
«Pl.»), а в index.htm рядом с сегментом появляется ссылка на судейские оценки
(…JudgesDetailsperSkater.pdf) вместо PDF со временем выхода.
"""
import datetime as dt
import html
import re
from urllib.parse import urljoin

from . import net

TIME_RE = re.compile(r"^(\d{1,2}):(\d{2})(?::(\d{2}))?$")
DATE_RE = re.compile(r"^(\d{2})\.(\d{2})\.(\d{4})$")
OFFSET_RE = re.compile(r"UTC\s*([+-])\s*(\d{1,2}):(\d{2})")
WARMUP_RE = re.compile(r"(?:Warm-?Up Group|Разминка|Группа разминки)\s*(\d+)", re.I)


def _text(s):
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    s = html.unescape(s).replace("\xa0", " ")
    return re.sub(r"\s+", " ", s).strip()


# Латинские буквы, набранные вместо похожих кириллических (табло ФФКМ: «Oдинoчнoe кaтaниe, КМC»)
_LAT2CYR = str.maketrans("AaBEeKMHOoPpCcTXxy", "АаВЕеКМНОоРрСсТХху")


def fix_script(s):
    """Слово, где кириллица смешана с латиницей, переводится в кириллицу.
    Чисто латинские слова (ISU: «Men Singles») не трогаем, кроме «MC»/«KMC» — это «МС»/«КМС»
    на табло ФФКМ (по ним различается уровень, КМС — юниорский)."""
    def fix(m):
        w = m.group(0)
        if re.search(r"[А-Яа-яЁё]", w) and re.search(r"[A-Za-z]", w):
            return w.translate(_LAT2CYR)
        if re.fullmatch(r"K?MC[,.;:]?", w):
            return w.translate(_LAT2CYR)
        return w
    return re.sub(r"\S+", fix, s)


def _cell_text(c):
    """Текст ячейки. «<a>Имя Фамилия</a><br/>Клуб» — только имя: клуб в той же ячейке."""
    m = re.search(r"(?is)</a>\s*<br\s*/?>", c)
    if m:
        c = c[:m.start()] + "</a>"
    return _text(c)


_NESTED = re.compile(
    r"(?is)(<td[^>]*>)\s*<table[^>]*>\s*(?:<tbody[^>]*>\s*)?<tr[^>]*>"
    r"((?:(?!<table\b|<tr\b|</tr>).)*)</tr>\s*(?:</tbody>\s*)?</table>\s*(</td>)")


def _flat(page):
    """Флаг с кодом страны в заявках и итогах лежит во вложенной табличке
    (<td><table><tr><td><img></td><td></td><td>AIN2</td></tr></table></td>);
    сворачиваем её в текст ячейки, иначе строка рвётся на внутреннем </tr>."""
    return _NESTED.sub(
        lambda m: m.group(1) + re.sub(r"(?is)</?t[dh]\b[^>]*>", " ", m.group(2)) + m.group(3), page)


def _rows(page, flat=False):
    """Список строк таблиц: (ячейки-текст, ссылки)."""
    page = re.sub(r"(?s)<(script|style)[^>]*>.*?</\1>", "", page)
    # подпись таблицы стоит вне <tr>: делаем из неё строку, иначе «Расписание» не находится
    page = re.sub(r"(?is)<caption[^>]*>(.*?)</caption>", r"<tr><td>\1</td></tr>", page)
    if flat:
        page = _flat(page)
    out = []
    for r in re.findall(r"(?s)<tr[^>]*>(.*?)</tr>", page):
        cells = [_cell_text(c) for c in re.findall(r"(?s)<t[dh][^>]*>(.*?)</t[dh]>", r)]
        links = re.findall(r"""href\s*=\s*["']?([^"' >]+)""", r)
        out.append((cells, links))
    return out


def parse_index(url, default_offset=None):
    """Возвращает описание турнира с табло:
    {
      name, city, nation, venue, offset (минуты от UTC),
      categories: [{name, entries_url, segments: [{name, url, times_pdf, start}]}]
    }
    start — datetime с часовым поясом (из блока расписания), если есть.
    default_offset — минуты от UTC, если на табло смещения нет (ФФКМ: московское время).
    """
    return parse_index_page(net.fetch(url), url, default_offset)


def parse_index_page(page, url, default_offset=None):
    """Разбор уже скачанной страницы index.htm (см. parse_index)."""
    title = re.search(r"(?s)<title>(.*?)</title>", page)
    name = _text(title.group(1)) if title else ""
    body_text = _text(page)

    m = OFFSET_RE.search(body_text)
    offset = None
    if m:
        sign = 1 if m.group(1) == "+" else -1
        offset = sign * (int(m.group(2)) * 60 + int(m.group(3)))
    if offset is None:
        offset = default_offset

    # Город / страна и площадка: первые строки шапки до таблицы категорий
    lines = [l.strip() for l in re.sub(r"(?s)<[^>]+>", "\n", html.unescape(
        re.sub(r"(?s)<(script|style)[^>]*>.*?</\1>", "", page))).split("\n")]
    lines = [l.replace("\xa0", " ").strip() for l in lines if l.strip()]
    city = nation = venue = ""
    for i, l in enumerate(lines[:60]):
        mm = re.match(r"^(.+?)\s*/\s*([A-ZА-ЯЁ]{3})$", l)
        if mm:
            city, nation = mm.group(1).strip(), mm.group(2)
            if i + 1 < len(lines) and not DATE_RE.match(lines[i + 1][:10]):
                venue = lines[i + 1]
            break

    categories = []
    cur = None
    schedule = []  # (date, time, category, segment)
    cur_date = None
    in_schedule = False
    for cells, links in _rows(page):
        joined = " ".join(cells)
        if re.search(r"Time Schedule|Расписание", joined) and not links:
            in_schedule = True
        cat_link = next((l for l in links if re.search(r"CAT\d+EN\.htm", l, re.I)), None)
        seg_link = next((l for l in links if re.fullmatch(r"SEG\d+\.htm", l, re.I)), None)
        if cat_link and not in_schedule:
            nm = fix_script(next((c for c in cells if c), ""))
            res_link = next((l for l in links if re.search(r"CAT\d+RS\.htm", l, re.I)), None)
            cur = {"name": nm, "entries_url": urljoin(url, cat_link),
                   "results_url": urljoin(url, res_link) if res_link else None, "segments": []}
            categories.append(cur)
            continue
        if seg_link and cur is not None and not in_schedule:
            seg_name = fix_script(next((c for c in cells if c), ""))
            pdf = next((l for l in links if "StartListwithTimes" in l), None)
            cur["segments"].append({
                "name": seg_name,
                "url": urljoin(url, seg_link),
                "times_pdf": urljoin(url, pdf) if pdf else None,
                # судейские оценки выкладывают, когда сегмент закончен и протокол утверждён
                "final": any("JudgesDetails" in l for l in links),
                "judges_pdf": next((urljoin(url, l) for l in links if "JudgesDetails" in l), None),
            })
            continue
        if in_schedule:
            vals = [c for c in cells if c]
            if not vals:
                continue
            if DATE_RE.match(vals[0]):
                cur_date = vals[0]
                vals = vals[1:]
            if len(vals) >= 3 and TIME_RE.match(vals[0]) and cur_date:
                schedule.append((cur_date, vals[0], vals[1], vals[2]))

    tz = dt.timezone(dt.timedelta(minutes=offset)) if offset is not None else None
    for d, t, cat, seg in schedule:
        dd = DATE_RE.match(d)
        tt = TIME_RE.match(t)
        when = dt.datetime(int(dd.group(3)), int(dd.group(2)), int(dd.group(1)),
                           int(tt.group(1)), int(tt.group(2)), tzinfo=tz)
        for c in categories:
            if _same(c["name"], cat):
                for s in c["segments"]:
                    if _same(s["name"], seg) and "start" not in s:
                        s["start"] = when
                        break
    final_marks = any(s["final"] for c in categories for s in c["segments"])
    return {"url": url, "name": name, "city": city, "nation": nation, "venue": venue,
            "offset": offset, "categories": categories, "final_marks": final_marks}


def _same(a, b):
    n = lambda s: re.sub(r"[\s\-–]+", " ", fix_script(s)).strip().lower()
    return n(a) == n(b)


def parse_starting_order(url, page=None):
    """Стартовый лист сегмента: [{no, name, nation, warmup}].
    Пока сегмент не прошёл — это стартовый порядок с разминками; после — результаты,
    где стартовый номер стоит в последнем столбце как «#15».
    page — уже скачанная страница, чтобы не тянуть её второй раз."""
    if page is None:
        page = net.fetch(url)
    rows = _rows(page)
    out = []
    seen = set()
    warmup = None
    header = None
    for cells, _ in rows:
        vals = [c for c in cells]
        joined = " ".join(vals)
        w = WARMUP_RE.search(joined)
        if w and len([v for v in vals if v]) <= 2:
            warmup = int(w.group(1))
            continue
        if not header and any(h in vals for h in STARTING_HEADS):
            header = vals
            continue
        if header is None:
            continue
        nonempty = [v for v in vals if v]
        if len(nonempty) < 2:
            continue
        if header[0] not in RESULT_HEADS:
            if not re.fullmatch(r"\d+", nonempty[0]):
                continue
            no = int(nonempty[0])
            name = nonempty[1]
            nation = _nation_from(nonempty[2:])
            out.append({"no": no, "name": name, "nation": nation, "warmup": warmup})
        else:  # результаты
            if not re.fullmatch(r"\d+", nonempty[0]):
                continue
            name = nonempty[1]
            if name in seen:  # вторая таблица с той же шапкой — общий зачёт: человек один раз
                continue
            seen.add(name)
            stn = next((v for v in reversed(nonempty) if re.fullmatch(r"#\d+", v)), None)
            nation = _nation_from(nonempty[2:])
            out.append({"no": int(stn[1:]) if stn else None, "name": name,
                        "nation": nation, "warmup": None, "rank": int(nonempty[0])})
    return out


def _nation_from(vals):
    for v in vals:
        if re.fullmatch(r"[A-Z]{3}\d?", v) or re.fullmatch(r"[А-ЯЁ]{3}", v):
            return v
    return ""


# ---------------------------------------------------------------- протоколы

RESULT_HEADS = ("Pl.", "Pl", "Мес.", "Место", "Мест.", "М.", "FPl.", "FPl")
# шапка стартового листа: стартовый номер в первой колонке (или место, пока сегмент не прошёл)
STARTING_HEADS = ("StN.", "Ст.№", "Ст. №", "СН.", "Pl.", "Мес.", "Место", "М.", "FPl.", "FPl")
NAME_HEADS = ("Name", "Имя", "Спортсмен", "Участник")
NATION_HEADS = ("Nation", "Nat.", "Регион", "Страна", "Нация")
NO_HEADS = ("СН.", "СН", "StN.", "StN", "Ст.№", "Ст. №", "Стартовый номер")
POINTS_RE = re.compile(r"\d{1,3}\.\d{2}")
NATION_RE = re.compile(r"[A-ZА-ЯЁ]{2,4}\d?(?:\s*/\s*[A-ZА-ЯЁ]{2,4}\d?)?")
NUM_RE = re.compile(r"-?\d{1,3}\.\d{2}")  # баллы с минусом (снижение)
STATUS_RE = re.compile(r"[A-Za-z]{2,4}")  # WD, DNS, DSQ, Ret, NQD — в колонке места вместо числа
SEG_POINTS = ("TSS", "Сумма", "Points", "Баллы")
CAT_POINTS = ("Points", "Баллы", "Сумма", "Total", "TSS")


def _col(header, names, prefix=False):
    for i, h in enumerate(header):
        h = h.strip()
        if h in names or (prefix and any(h.startswith(n) for n in names)):
            return i
    return None


def _row_result(cells, header, points_heads):
    """Строка таблицы протокола → {place, name, nation, points, cells, pi} или None."""
    nonempty = [c for c in cells if c]
    if len(nonempty) < 3 or not re.fullmatch(r"\d+", nonempty[0]):
        return None
    aligned = len(cells) == len(header)
    ni = _col(header, NAME_HEADS) if aligned else None
    name = cells[ni] if ni is not None and cells[ni] else nonempty[1]
    after = cells[cells.index(name) + 1:]
    pi = _col(header, points_heads, prefix=True) if aligned else None
    points = cells[pi] if pi is not None and POINTS_RE.fullmatch(cells[pi]) else \
        next((v for v in after if POINTS_RE.fullmatch(v)), None)
    if not points:
        return None
    ci = _col(header, NATION_HEADS) if aligned else None
    if ci is not None and NATION_RE.fullmatch(cells[ci]):
        nation = cells[ci]
    else:
        before = after[:after.index(points)] if points in after else after
        nation = next((v for v in before if NATION_RE.fullmatch(v)), "")
    return {"place": int(nonempty[0]), "name": name, "nation": nation.replace(" ", ""),
            "points": points, "cells": cells, "pi": pi}


def _has_components(header):
    """Таблица самого сегмента — с оценками за элементы и компоненты (TES, PCS)."""
    return any(h.strip().startswith(("TES", "PCS")) for h in header)


def _tables(page):
    """Таблицы протокола на странице: [(шапка, [ячейки строк ниже шапки])].
    Таблица начинается с шапки, где первая колонка — место, а есть колонка имени."""
    tables = []
    for cells, _ in _rows(page, flat=True):
        first = next((c for c in cells if c), "")
        if first in RESULT_HEADS and _col(cells, NAME_HEADS) is not None:
            tables.append((cells, []))
        elif tables:
            tables[-1][1].append(cells)
    return tables


def _result_rows(page, points_heads, segment):
    """Таблица протокола → (шапка, [{place, name, nation, points, cells}]).
    Шапка None — страница не в режиме результатов (стартовый лист).

    Во время старта на странице бывает несколько таблиц с одной и той же шапкой «Pl.»:
    сам сегмент и общий зачёт (короткая + произвольная). Берётся одна: у сегмента
    (segment=True) — с TES/PCS, у итога — без них; если такой нет — первая. Один человек
    на одном месте — один раз: однофамильцы с разными местами не схлопываются."""
    parsed = []  # [(шапка, [строки с местом и баллами])]
    for header, cells_rows in _tables(page):
        rows = [r for r in (_row_result(c, header, points_heads) for c in cells_rows) if r]
        parsed.append((header, rows))
    if not parsed:
        return None, []
    pick = next((t for t in parsed if t[1] and _has_components(t[0]) == segment), None) \
        or next((t for t in parsed if t[1]), parsed[0])
    header, rows = pick
    seen, out = set(), []
    for r in rows:
        key = (r["place"], r["name"])
        if key in seen:
            continue
        seen.add(key)
        out.append(r)
    return header, out


def parse_segment_results(page):
    """Протокол сегмента (SEGnnn.htm после проката): [{place, name, nation, points}]
    по местам; points — сумма за сегмент (TSS) строкой, как в протоколе.
    None — страница ещё показывает стартовый порядок."""
    header, rows = _result_rows(page, ("TSS", "Сумма", "Points", "Баллы"), True)
    if header is None:
        return None
    return [{k: r[k] for k in ("place", "name", "nation", "points")}
            for r in sorted(rows, key=lambda r: r["place"])]


def parse_category_results(url):
    """Итог вида (CATnnnRS.htm): {rows: [{place, name, nation, points}], complete}.
    complete — у первой тройки заполнены места во всех сегментах (до конца
    последнего сегмента столбец ПП/ПТ пустой, а в «Points» сумма за КП)."""
    page = net.fetch(url)
    header, rows = _result_rows(page, ("Points", "Баллы", "Сумма", "Total", "TSS"), False)
    if header is None or not rows:
        return {"rows": [], "complete": False}
    rows.sort(key=lambda r: r["place"])
    complete = True
    for r in rows[:3]:
        cells, pi = r["cells"], r["pi"]
        # строка не совпала со шапкой — проверить не можем, значит и не показываем
        seg_cols = [j for j in range(pi + 1, len(header)) if header[j]] if pi is not None else []
        if not seg_cols or not all(cells[j] for j in seg_cols):
            complete = False
            break
    return {"rows": [{k: r[k] for k in ("place", "name", "nation", "points")} for r in rows],
            "complete": complete}


def nation_of(text):
    """Колонка «Регион» или «Нация» как есть: пробелы сведены к одному, «МОС / СПБ» остаётся
    с пробелами, как на табло. Не похоже на код или регион — пустая строка (клуб, мусор)."""
    s = re.sub(r"\s*/\s*", " / ", re.sub(r"\s+", " ", text or "").strip())
    return s if NATION_RE.fullmatch(s) else ""


def _num(raw, pattern=NUM_RE):
    """Значение баллов как строка NN.NN, иначе None (запятая, текст, пусто)."""
    return raw if raw and pattern.fullmatch(raw) else None


def parse_protocol_row(cells, header, points_heads):
    """Строка таблицы протокола → (строка, причина). Строка None — не участник.

    Участник — строка, совпадающая с шапкой по числу колонок, с именем и местом (число или
    статус из колонки места: WD, NQD). Легенда («Обозн.», «SK — Мастерство катания») и
    разделители по числу колонок не совпадают с шапкой и отбрасываются. Причина «points» —
    баллы похожи на число, но записаны с запятой: points = None, строка учитывается в skipped."""
    if len(cells) != len(header):
        return None, None
    ni = _col(header, NAME_HEADS)
    name = cells[ni] if ni is not None else ""
    if not name:
        return None, None
    pi0 = _col(header, RESULT_HEADS)
    place_cell = cells[pi0] if pi0 is not None else ""
    place = None
    status = None
    if re.fullmatch(r"\d{1,3}", place_cell) and 1 <= int(place_cell) <= 999:
        place = int(place_cell)
    elif STATUS_RE.fullmatch(place_cell):
        status = place_cell
    if place is None and status is None:
        return None, None

    no = None
    noi = _col(header, NO_HEADS)
    if noi is not None:
        m = re.fullmatch(r"#?(\d{1,3})", cells[noi])
        if m:
            no = int(m.group(1))

    ci = _col(header, NATION_HEADS)
    nation = nation_of(cells[ci]) if ci is not None else ""

    def col(names, pattern=NUM_RE):
        j = _col(header, names, prefix=True)
        return _num(cells[j], pattern) if j is not None else None

    pi = _col(header, points_heads, prefix=True)
    raw_points = cells[pi] if pi is not None else ""
    points = _num(raw_points, POINTS_RE)
    reason = "points" if raw_points and points is None else None
    row = {"place": place, "status": status, "no": no, "name": name, "nation": nation,
           "points": points, "tes": col(("TES",)), "pcs": col(("PCS",)),
           "ded": col(("Снижение", "Ded"))}
    return row, reason


def _protocol(page, points_heads, segment):
    """Общий разбор таблицы протокола: {table, header, rows, kept, skipped, reasons}.
    kept — ячейки строк, по порядку совпадающие с rows (нужны итогу вида для колонок)."""
    tables = [t for t in _tables(page) if t[1]]
    out = {"table": "results", "header": None, "rows": [], "kept": [], "skipped": 0, "reasons": []}
    if not tables:
        starting = any(c in STARTING_HEADS for cells, _ in _rows(page, flat=True) for c in cells)
        out["table"] = "starting" if starting else "empty"
        return out
    matching = [t for t in tables if _has_components(t[0]) == segment]
    if len(matching) == 1:
        header, cells_rows = matching[0]
    elif len(tables) == 1:
        header, cells_rows = tables[0]
    else:
        out["table"] = "format"
        return out
    out["header"] = header
    seen = set()
    for cells in cells_rows:
        row, reason = parse_protocol_row(cells, header, points_heads)
        if row is None:
            continue
        key = (row["place"] if row["place"] is not None else row["status"], row["name"])
        if key in seen:
            out["skipped"] += 1
            out["reasons"].append("duplicate")
            continue
        seen.add(key)
        if reason:
            out["skipped"] += 1
            out["reasons"].append(reason)
        row["i"] = len(out["rows"]) + 1
        out["rows"].append(row)
        out["kept"].append(cells)
    if not out["rows"]:
        # шапка есть, участников с местом или статусом нет: стартовый лист до старта
        out["table"] = "starting" if any(c in STARTING_HEADS for c in header) else "empty"
    return out


def parse_segment_protocol(page):
    """Протокол сегмента (SEGnnn.htm) для файла: {table, rows, skipped, reasons}.
    table — results, starting (стартовый лист, результатов нет), empty (страница без таблицы
    результатов), format (таблицы есть, одну выбрать нельзя). rows — участники по порядку
    таблицы, i с 1; place и status — из колонки места; points, tes, pcs, ded — «NN.NN» или None.
    skipped — строки участников, которые не разобрать (запятая в баллах, повтор пары)."""
    out = _protocol(page, SEG_POINTS, True)
    return {k: out[k] for k in ("table", "rows", "skipped", "reasons")}


def parse_category_protocol(page):
    """Итог вида (CATnnnRS.htm) для файла: {table, cols, colsKind, rows, complete, skipped, reasons}.
    cols — колонки после баллов, как на табло (КП, ПП), с исправленной кириллицей. У строк
    parts — значения этих колонок (строка) или None. complete — у трёх первых мест заполнены
    все колонки (эвристика parse_category_results). colsKind — places, если значения целые."""
    out = _protocol(page, CAT_POINTS, False)
    header = out["header"] or []
    pi = _col(header, CAT_POINTS, prefix=True)
    seg_cols = [j for j in range(pi + 1, len(header)) if header[j]] if pi is not None else []
    rows = out["rows"]
    for row, cells in zip(rows, out["kept"]):
        row["parts"] = [cells[j] or None for j in seg_cols]
    values = [p for r in rows for p in r["parts"] if p]
    if values and all(re.fullmatch(r"\d{1,3}", v) for v in values):
        colskind = "places"
    elif values and all(POINTS_RE.fullmatch(v) for v in values):
        colskind = "points"
    else:
        colskind = "unknown"
    ranked = sorted((r for r in rows if r["place"] is not None), key=lambda r: r["place"])
    complete = bool(ranked) and all(all(r["parts"]) for r in ranked[:3])
    return {"table": out["table"], "cols": [fix_script(header[j]) for j in seg_cols],
            "colsKind": colskind, "rows": rows, "complete": complete,
            "skipped": out["skipped"], "reasons": out["reasons"]}


def parse_entries(url):
    """Заявка категории: [{name, nation}]."""
    page = net.fetch(url)
    out = []
    started = False
    for cells, _ in _rows(page):
        vals = [c for c in cells if c]
        if not vals:
            continue
        if vals[0] in ("No.", "№", "Nr."):
            started = True
            continue
        if not started or not re.fullmatch(r"\d+", vals[0]) or len(vals) < 2:
            continue
        out.append({"name": vals[1], "nation": _nation_from(vals[2:])})
    return out


PDF_LINE = re.compile(
    r"^\s*(\d{1,2}):(\d{2})(?::(\d{2}))?\s*-\s*\d{1,2}:\d{2}(?::\d{2})?\s+(\d{1,3})\s+(\S.*)$")


def parse_times_pdf(url):
    """PDF со временем выхода: {стартовый номер: (час, минута), ...} и разминки.
    Время — местное, как в PDF."""
    text = net.pdf_text(url)
    times = {}
    warm = {}
    group = None
    for line in text.splitlines():
        w = WARMUP_RE.search(line)
        m = PDF_LINE.match(line)
        if m:
            no = int(m.group(4))
            times[no] = (int(m.group(1)), int(m.group(2)))
            warm[no] = group
        elif w:
            group = int(w.group(1))
    return times, warm


# ---------------------------------------------------------------- судейские оценки

JUDGES_HEAD = re.compile(
    r"^\s*(\d{1,3})\s+(\S.*?)\s{2,}([A-ZА-ЯЁ]{2,4}\d?)\s+(\d{1,3})\s+"
    r"(-?\d+\.\d\d)\s+(-?\d+\.\d\d)\s+(-?\d+\.\d\d)\s+(-?\d+\.\d\d)\s*$")
FLOAT = re.compile(r"^-?\d+\.\d\d$")
COMPONENTS = ("Composition", "Presentation", "Skating Skills", "Skating skills",
              "Композиция", "Представление", "Мастерство катания")


def parse_judges(text):
    """Судейские оценки по каждому (…JudgesDetailsperSkater.pdf, pdftotext -layout):
    [{rank, name, nation, tss, tes, pcs, ded,
      elements: [{code, info, base, goe, judges: [int], score}],
      components: [{name, judges: [float]}]}]"""
    out = []
    cur = None
    for line in text.splitlines():
        m = JUDGES_HEAD.match(line)
        if m:
            cur = {"rank": int(m.group(1)), "name": m.group(2).strip(), "nation": m.group(3),
                   "tss": float(m.group(5)), "tes": float(m.group(6)), "pcs": float(m.group(7)),
                   "ded": float(m.group(8)), "elements": [], "components": []}
            out.append(cur)
            continue
        if cur is None:
            continue
        el = _element(line)
        if el:
            cur["elements"].append(el)
            continue
        stripped = line.strip()
        for c in COMPONENTS:
            if stripped.startswith(c):
                nums = [float(t) for t in stripped[len(c):].split() if FLOAT.match(t)]
                # множитель, оценки судей, итог
                if len(nums) >= 4:
                    cur["components"].append({"name": c, "judges": nums[1:-1]})
                break
    return out


def _element(line):
    """«   3    4T+3A+3A+SEQ      25.50    1.14   0 1 1 1 2 1 2     26.64» → элемент."""
    t = line.split()
    if len(t) < 5 or not re.fullmatch(r"\d{1,2}", t[0]):
        return None
    code = t[1]
    rest = t[2:]
    info = []
    while rest and not FLOAT.match(rest[0]):
        if rest[0] == "x":
            rest = rest[1:]
            continue
        info.append(rest[0])
        rest = rest[1:]
    nums = []
    for v in rest:
        if v == "x":
            continue
        if FLOAT.match(v) or re.fullmatch(r"-?\d", v) or v == "-":
            nums.append(v)
        else:
            return None
    floats = [v for v in nums if FLOAT.match(v)]
    if len(floats) < 3:
        return None
    base, goe, score = float(nums[0]), float(nums[1]), float(nums[-1])
    judges = [int(v) for v in nums[2:-1] if re.fullmatch(r"-?\d", v)]
    return {"code": code, "info": " ".join(info), "base": base, "goe": goe,
            "judges": judges, "score": score}


# ---------------------------------------------------------------- PDF оценок (ФФКМ «Scores»)

# «ДЕТАЛИЗАЦИЯ СУДЕЙСКИХ ОЦЕНОК» (ФФКМ): строка участника — место, имя, стартовый номер,
# общая сумма за вид, элементы, компоненты, снижения. Строки элементов и компонентов сюда не
# попадают: у них в конце нет четырёх чисел с точкой подряд.
JUDGES_PDF_ROW = re.compile(
    r"^\s{0,12}(\d{1,2})\s+(\S.*?\S)\s+(\d{1,3})\s+(\d{1,3}\.\d{2})\s+(\d{1,3}\.\d{2})\s+"
    r"(\d{1,3}\.\d{2})\s+(-?\d{1,3}\.\d{2})\s*$")


def parse_judges_pdf(text):
    """Строки участников PDF оценок (pdftotext -layout): [{place, name, no, points, tes, pcs, ded, i}].
    points — общая сумма за вид, tes — за элементы, pcs — за компоненты, ded — снижения (модуль).
    Места в таблице уникальны; повтор места — строка пропускается (как в протоколе табло)."""
    rows, seen = [], set()
    for line in text.splitlines():
        m = JUDGES_PDF_ROW.match(line)
        if not m:
            continue
        place = int(m.group(1))
        if place in seen:
            continue
        seen.add(place)
        rows.append({"place": place, "name": m.group(2), "no": int(m.group(3)),
                     "points": m.group(4), "tes": m.group(5), "pcs": m.group(6),
                     # снижение как модуль, как в колонке «Снижение -» табло (в PDF — со знаком минус)
                     "ded": m.group(7).lstrip("-"), "i": len(rows) + 1})
    return rows


def _words(s):
    return set(re.findall(r"[а-яёa-z0-9]+(?:-[а-яёa-z0-9]+)*", fix_script(s).lower()))


def judges_header_ok(text, category_name, segment_name):
    """Заголовок PDF оценок совпадает с категорией и сегментом: все слова названия категории
    (вид, пол, уровень, например «Одиночное катание, КМС, Юноши, Юниоры») и все слова названия
    сегмента («Короткая программа») есть в первых 1500 символах. Мужской и женский КП ФФКМ
    ссылаются на один файл: несовпадение — не наш файл, оценки чужие."""
    head = _words(text[:1500])
    cat, seg = _words(category_name), _words(segment_name)
    return bool(cat) and bool(seg) and cat <= head and seg <= head
