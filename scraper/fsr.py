"""ФФККР (fsrussia.ru): календарь сезона, страницы турниров, PDF-расписания, сборная."""
import datetime as dt
import html
import re
from urllib.parse import quote, urljoin

from . import net

BASE = "https://fsrussia.ru"

MONTHS = {
    "январ": 1, "феврал": 2, "март": 3, "апрел": 4, "ма": 5, "июн": 6, "июл": 7,
    "август": 8, "сентябр": 9, "октябр": 10, "ноябр": 11, "декабр": 12,
}
MONTH_NAMES = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август",
               "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"]


def month_num(word):
    w = word.lower()
    for k, v in sorted(MONTHS.items(), key=lambda kv: -len(kv[0])):
        if w.startswith(k):
            return v
    return None


def _text(s):
    s = re.sub(r"(?i)<br\s*/?>", "\n", s)
    s = re.sub(r"(?s)<[^>]+>", "", s)
    s = html.unescape(s).replace("\xa0", " ")
    return "\n".join(re.sub(r"[ \t]+", " ", l).strip() for l in s.split("\n") if l.strip())


def calendar():
    """Календарь «Одиночное и парное катание, танцы на льду»:
    [{title, levels, city, venue, start: date, end: date, page}]"""
    page = net.fetch(BASE + "/calendar")
    head = "Одиночное и парное катание, танцы на льду"
    starts = [m.start() for m in re.finditer(re.escape(head), page)]
    a = starts[1] if len(starts) > 1 else 0
    sync = [m.start() for m in re.finditer("Синхронное катание", page)]
    b = next((s for s in sync if s > a + 100), len(page))
    part = page[a:b]
    y0 = re.search(r"(\d{4})\s*год", part)
    season_year = int(y0.group(1)) if y0 else dt.date.today().year

    out = []
    # месяц раздела берём из ближайшего предшествующего заголовка <h2>
    tokens = [(m.start(), "month", m.group(1)) for m in
              re.finditer(r"(?s)<h2[^>]*>\s*([А-Яа-я]+)\s*</h2>", part)]
    tokens += [(m.start(), "row", m.group(1)) for m in re.finditer(r"(?s)<tr[^>]*>(.*?)</tr>", part)]
    tokens.sort()
    cur_month = None
    for _, kind, val in tokens:
        if kind == "month":
            cur_month = month_num(val)
            continue
        cells = re.findall(r"(?s)<td[^>]*>(.*?)</td>", val)
        if len(cells) < 3 or cur_month is None:
            continue
        dates = _text(cells[0]).replace("\n", " ")
        what = _text(cells[1]).split("\n")
        where = _text(cells[2]).split("\n")
        link = re.search(r'href="([^"]+)"', cells[3]) if len(cells) > 3 else None
        rng = parse_range(dates, cur_month, season_year)
        if not rng:
            continue
        title = what[0]
        levels = " ".join(what[1:])
        city = where[0].rstrip(",").strip() if where else ""
        venue = " ".join(w.strip() for w in where[1:]).strip()
        out.append({
            "title": title, "levels": levels, "city": city, "venue": venue,
            "start": rng[0], "end": rng[1],
            "page": urljoin(BASE, link.group(1)) if link else None,
        })
    return out


def _year_for(month, season_year):
    return season_year if month >= 7 else season_year + 1


def parse_range(s, section_month, season_year):
    s = s.strip()
    m = re.match(r"^(\d{1,2})\s*([а-я]+)\s*[-–]\s*(\d{1,2})\s*([а-я]+)$", s)
    if m:
        m1, m2 = month_num(m.group(2)), month_num(m.group(4))
        if not m1 or not m2:
            return None
        d1 = dt.date(_year_for(m1, season_year), m1, int(m.group(1)))
        d2 = dt.date(_year_for(m2, season_year), m2, int(m.group(3)))
        return d1, d2
    m = re.match(r"^(\d{1,2})\s*[-–]\s*(\d{1,2})$", s)
    if m:
        y = _year_for(section_month, season_year)
        return dt.date(y, section_month, int(m.group(1))), dt.date(y, section_month, int(m.group(2)))
    m = re.match(r"^(\d{1,2})$", s)
    if m:
        y = _year_for(section_month, season_year)
        d = dt.date(y, section_month, int(m.group(1)))
        return d, d
    return None


def recent_pages():
    """Свежие страницы турниров из раздела «Соревнования» (там они появляются раньше,
    чем ссылка в календаре)."""
    page = net.fetch(BASE + "/sorevnovaniya")
    links = re.findall(r'href="(/sorevnovaniya/sorevnovaniya/[^"#?]+)"', page)
    return sorted({urljoin(BASE, l) for l in links
                   if not re.search(r"/(page-\d+|rss|atom)$", l)})


BROADCASTERS = [
    (r"1tv\.(ru|com)", "Первый канал"),
    (r"okko\.(tv|sport)", "Okko"),
    (r"matchtv\.ru|matchtv", "Матч ТВ"),
    (r"kinopoisk\.ru", "Кинопоиск"),
    (r"wink\.ru", "Wink"),
    (r"vk\.com/video|vkvideo\.ru", "VK Видео"),
    (r"rutube\.ru", "Rutube"),
    (r"smotrim\.ru", "Смотрим"),
]


def tournament(url):
    """Страница турнира: даты, место, ссылки на табло, расписание, трансляции."""
    page = net.fetch(url)
    i = page.find('itemprop="articleBody"')
    j = page.find("tlparams")
    body = page[i if i >= 0 else 0: j if j > i else len(page)]
    text = _text(body)
    title = re.search(r'(?s)<h[12][^>]*itemprop="headline"[^>]*>(.*?)</h[12]>', page) or \
        re.search(r"(?s)<title>(.*?)</title>", page)
    t = {"url": url, "title": _text(title.group(1)).split(" - ")[0] if title else "",
         "results": None, "schedule_pdf": None, "broadcast": [], "place": "", "start": None, "end": None}
    m = re.search(r"Сроки проведения:\s*\n?\s*(\d{1,2})\s*([а-я]+)?\s*[-–]\s*(\d{1,2})\s+([а-я]+)\s+(\d{4})", text)
    if m:
        y = int(m.group(5))
        m2 = month_num(m.group(4))
        m1 = month_num(m.group(2)) if m.group(2) else m2
        y1 = y - 1 if m1 > m2 else y
        t["start"] = dt.date(y1, m1, int(m.group(1)))
        t["end"] = dt.date(y, m2, int(m.group(3)))
    m = re.search(r"Место проведения:\s*\n?\s*(.+)", text)
    if m:
        t["place"] = m.group(1).strip()
    for a in re.finditer(r'(?s)<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', body):
        href, label = a.group(1), _text(a.group(2)).lower()
        full = urljoin(BASE, href)
        if "/results/" in href and href.endswith(".htm"):
            t["results"] = full
        elif "расписание" in label and href.lower().endswith(".pdf"):
            t["schedule_pdf"] = full
        for rx, name in BROADCASTERS:
            if re.search(rx, href) and name not in t["broadcast"]:
                t["broadcast"].append(name)
    return t


SEG_WORDS = [
    (r"ритм", "РТ"),
    (r"произвольн\w*\s+танец", "ПТ"),
    (r"коротк", "КП"),
    (r"произвольн\w*\s+программ", "ПП"),
]


def classify(text):
    """По русскому описанию вида → (kind, level). level: junior/senior/None."""
    t = text.lower()
    kind = None
    if re.search(r"танц", t):
        kind = "dance"
    elif re.search(r"пар", t):
        kind = "pairs"
    elif re.search(r"девушк|юниорк|женщин|девочк", t):
        kind = "women"
    elif re.search(r"юнош|юниор|мужчин|мальчик", t):
        kind = "men"
    level = None
    if re.search(r"\bкмс\b", t) or re.search(r"девушк|юниорк|юнош|юниор", t):
        level = "junior"
    if re.search(r"(?<!к)\bмс\b", t) or re.search(r"женщин|мужчин", t):
        level = "senior"
    return kind, level


def segment_of(text):
    t = text.lower()
    for rx, code in SEG_WORDS:
        if re.search(rx, t):
            return code
    return None


def low_level(text):
    """Категории ниже КМС (разряды, дети, спецпрограмма) в календарь не берём."""
    return bool(re.search(r"разряд|девочк|мальчик|спецпрограмм|юношеск", text.lower()))


def schedule_pdf(url, season_hint):
    """PDF «Расписание соревнований»: [(date, (h, m), (h2, m2), описание)] —
    только строки из блоков «соревнования:», время местное."""
    text = net.pdf_text(url)
    out = []
    cur_date = None
    in_comp = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        d = re.match(r"^(\d{1,2})\s+([а-я]+)\s*(?:\(|$)", line)
        if d and month_num(d.group(2)):
            mn = month_num(d.group(2))
            y = season_hint if mn >= 7 else season_hint + 1
            cur_date = dt.date(y, mn, int(d.group(1)))
            in_comp = False
            continue
        low = line.lower()
        if low.startswith("соревнования"):
            in_comp = True
            continue
        if "тренировк" in low:
            in_comp = False
            continue
        if not in_comp or cur_date is None:
            continue
        m = re.match(r"^(\d{1,2})[.:](\d{2})\s*[–-]\s*(\d{1,2})[.:](\d{2})\s*[–-]?\s*(.+)$", line)
        if not m:
            continue
        what = m.group(5).strip()
        if segment_of(what) is None:
            continue
        out.append((cur_date, (int(m.group(1)), int(m.group(2))),
                    (int(m.group(3)), int(m.group(4))), what))
    return out


def team():
    """Сборная: [(ФАМИЛИЯ, Имя, фото или None)]. На странице у каждого две ссылки
    на /sbornaya/teams/<slug>: в первой фото, во второй <strong>ФАМИЛИЯ<br>Имя<br>Отчество."""
    page = net.fetch(BASE + "/sbornaya")
    photos = {}
    for m in re.finditer(r'(?s)<a href="/sbornaya/teams/([^"]+)"[^>]*>\s*<img[^>]*?\ssrc="([^"]+)"', page):
        photos.setdefault(m.group(1), urljoin(BASE, quote(html.unescape(m.group(2)), safe="/:%?=&.-_~")))
    out = []
    seen = set()
    for m in re.finditer(r'(?s)<a href="/sbornaya/teams/([^"]+)"[^>]*>\s*<strong[^>]*>(.*?)</strong>', page):
        parts = [p for p in _text(m.group(2)).split("\n") if p]
        if len(parts) >= 2 and m.group(1) not in seen:
            seen.add(m.group(1))
            out.append((parts[0], parts[1], photos.get(m.group(1))))
    return out


def team_names():
    """Сборная: [(ФАМИЛИЯ, Имя)]."""
    return [(sur, giv) for sur, giv, _ in team()]
