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
    if flat:
        page = _flat(page)
    out = []
    for r in re.findall(r"(?s)<tr[^>]*>(.*?)</tr>", page):
        cells = [_text(c) for c in re.findall(r"(?s)<t[dh][^>]*>(.*?)</t[dh]>", r)]
        links = re.findall(r"""href\s*=\s*["']?([^"' >]+)""", r)
        out.append((cells, links))
    return out


def parse_index(url):
    """Возвращает описание турнира с табло:
    {
      name, city, nation, venue, offset (минуты от UTC),
      categories: [{name, entries_url, segments: [{name, url, times_pdf, start}]}]
    }
    start — datetime с часовым поясом (из блока расписания), если есть.
    """
    page = net.fetch(url)
    title = re.search(r"(?s)<title>(.*?)</title>", page)
    name = _text(title.group(1)) if title else ""
    body_text = _text(page)

    m = OFFSET_RE.search(body_text)
    offset = None
    if m:
        sign = 1 if m.group(1) == "+" else -1
        offset = sign * (int(m.group(2)) * 60 + int(m.group(3)))

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
            nm = next((c for c in cells if c), "")
            res_link = next((l for l in links if re.search(r"CAT\d+RS\.htm", l, re.I)), None)
            cur = {"name": nm, "entries_url": urljoin(url, cat_link),
                   "results_url": urljoin(url, res_link) if res_link else None, "segments": []}
            categories.append(cur)
            continue
        if seg_link and cur is not None and not in_schedule:
            seg_name = next((c for c in cells if c), "")
            pdf = next((l for l in links if "StartListwithTimes" in l), None)
            cur["segments"].append({
                "name": seg_name,
                "url": urljoin(url, seg_link),
                "times_pdf": urljoin(url, pdf) if pdf else None,
                # судейские оценки выкладывают, когда сегмент закончен и протокол утверждён
                "final": any("JudgesDetails" in l for l in links),
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
    n = lambda s: re.sub(r"[\s\-–]+", " ", s).strip().lower()
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
    warmup = None
    header = None
    for cells, _ in rows:
        vals = [c for c in cells]
        joined = " ".join(vals)
        w = WARMUP_RE.search(joined)
        if w and len([v for v in vals if v]) <= 2:
            warmup = int(w.group(1))
            continue
        if not header and any(h in vals for h in ("StN.", "Ст.№", "Ст. №", "Pl.", "Мес.", "Место")):
            header = vals
            continue
        if header is None:
            continue
        nonempty = [v for v in vals if v]
        if len(nonempty) < 2:
            continue
        if header[0] not in ("Pl.", "Мес.", "Место", "Pl"):
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

RESULT_HEADS = ("Pl.", "Pl", "Мес.", "Место", "FPl.", "FPl", "Мест.")
NAME_HEADS = ("Name", "Имя", "Спортсмен", "Участник")
NATION_HEADS = ("Nation", "Nat.", "Регион", "Страна", "Нация")
POINTS_RE = re.compile(r"\d{1,3}\.\d{2}")
NATION_RE = re.compile(r"[A-ZА-ЯЁ]{2,4}\d?(?:\s*/\s*[A-ZА-ЯЁ]{2,4}\d?)?")


def _col(header, names, prefix=False):
    for i, h in enumerate(header):
        h = h.strip()
        if h in names or (prefix and any(h.startswith(n) for n in names)):
            return i
    return None


def _result_rows(page, points_heads):
    """Таблица протокола → (шапка, [{place, name, nation, points, cells}]).
    Шапка None — страница не в режиме результатов (стартовый лист)."""
    header = None
    out = []
    for cells, _ in _rows(page, flat=True):
        if header is None:
            first = next((c for c in cells if c), "")
            if first in RESULT_HEADS and _col(cells, NAME_HEADS) is not None:
                header = cells
            continue
        nonempty = [c for c in cells if c]
        if len(nonempty) < 3 or not re.fullmatch(r"\d+", nonempty[0]):
            continue
        aligned = len(cells) == len(header)
        ni = _col(header, NAME_HEADS) if aligned else None
        name = cells[ni] if ni is not None and cells[ni] else nonempty[1]
        after = cells[cells.index(name) + 1:]
        pi = _col(header, points_heads, prefix=True) if aligned else None
        points = cells[pi] if pi is not None and POINTS_RE.fullmatch(cells[pi]) else \
            next((v for v in after if POINTS_RE.fullmatch(v)), None)
        if not points:
            continue
        ci = _col(header, NATION_HEADS) if aligned else None
        if ci is not None and NATION_RE.fullmatch(cells[ci]):
            nation = cells[ci]
        else:
            before = after[:after.index(points)] if points in after else after
            nation = next((v for v in before if NATION_RE.fullmatch(v)), "")
        out.append({"place": int(nonempty[0]), "name": name, "nation": nation.replace(" ", ""),
                    "points": points, "cells": cells, "pi": pi})
    return header, out


def parse_segment_results(page):
    """Протокол сегмента (SEGnnn.htm после проката): [{place, name, nation, points}]
    по местам; points — сумма за сегмент (TSS) строкой, как в протоколе.
    None — страница ещё показывает стартовый порядок."""
    header, rows = _result_rows(page, ("TSS", "Сумма", "Points", "Баллы"))
    if header is None:
        return None
    return [{k: r[k] for k in ("place", "name", "nation", "points")}
            for r in sorted(rows, key=lambda r: r["place"])]


def parse_category_results(url):
    """Итог вида (CATnnnRS.htm): {rows: [{place, name, nation, points}], complete}.
    complete — у первой тройки заполнены места во всех сегментах (до конца
    последнего сегмента столбец ПП/ПТ пустой, а в «Points» сумма за КП)."""
    page = net.fetch(url)
    header, rows = _result_rows(page, ("Points", "Баллы", "Сумма", "Total", "TSS"))
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
