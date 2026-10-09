"""Разбор табло Swiss Timing (FS Manager): index.htm, стартовые листы SEGnnn.htm,
заявки CATnnnEN.htm и PDF «Start List with Times».

Этот формат одинаков у ISU (results.isu.org), у организаторов челленджеров и у
ФФККР (fsrussia.ru/results/...), поэтому один разборщик кормит обе стороны.
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


def _rows(page):
    """Список строк таблиц: (ячейки-текст, ссылки)."""
    page = re.sub(r"(?s)<(script|style)[^>]*>.*?</\1>", "", page)
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
            cur = {"name": nm, "entries_url": urljoin(url, cat_link), "segments": []}
            categories.append(cur)
            continue
        if seg_link and cur is not None and not in_schedule:
            seg_name = next((c for c in cells if c), "")
            pdf = next((l for l in links if "StartListwithTimes" in l), None)
            cur["segments"].append({
                "name": seg_name,
                "url": urljoin(url, seg_link),
                "times_pdf": urljoin(url, pdf) if pdf else None,
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
    return {"url": url, "name": name, "city": city, "nation": nation, "venue": venue,
            "offset": offset, "categories": categories}


def _same(a, b):
    n = lambda s: re.sub(r"[\s\-–]+", " ", s).strip().lower()
    return n(a) == n(b)


def parse_starting_order(url):
    """Стартовый лист сегмента: [{no, name, nation, warmup}].
    Пока сегмент не прошёл — это стартовый порядок с разминками; после — результаты,
    где стартовый номер стоит в последнем столбце как «#15»."""
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
