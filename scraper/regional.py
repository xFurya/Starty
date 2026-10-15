"""Региональные федерации: ФФКМ (Москва, ffkm.ru) и СООО «ФФКК» (Самарская область, skate63.ru).

Здесь только разбор страниц и календарей. Старты собирает build.py (do_ffkm, do_samara):
протоколы и табло идут через swisstiming, расписания PDF — через fsr, как у федерального
источника. Старт без времени здесь не возникает: без времени только строки календаря.
"""
import datetime as dt
import html
import re
from urllib.parse import quote, unquote, urljoin

from . import fsr
from . import net
from . import swisstiming as st

FFKM_CALENDAR = "https://ffkm.ru/season/competitions/calendar-of-sports-competitions/"
SKATE63 = "http://skate63.ru"
SKATE63_ARTICLES = SKATE63 + "/info/articles/"
SKATE63_CALENDAR = SKATE63 + "/o-federatsii/%D0%9A%D0%B0%D0%BB%D0%B5%D0%BD%D0%B4%D0%B0%D1%80%D1%8C/"


def ascii_url(u):
    """Адрес с кириллицей и тире — в вид, который принимает net.fetch (уже закодированное не трогаем)."""
    return quote(u, safe="/:%?=&()._-~")


def _year(month, season_year):
    """Месяцы с июля по декабрь — год начала сезона, с января по июнь — следующий год."""
    return season_year if month >= 7 else season_year + 1


# ---------------------------------------------------------------- ФФКМ: календарь

_FFKM_MONTH = re.compile(r'(?s)<li class="important__header[^"]*">\s*<p>([^<]*?)<span')
_FFKM_ROW = re.compile(r"(?s)<tr>(.*?)</tr>")
_CELL = re.compile(r"(?s)<td[^>]*>(.*?)</td>")
_FFKM_SEASON = re.compile(r"Сезон\s*(\d{4})\s*/\s*\d{4}")


def _ffkm_range(s, month, season_year):
    """«14 - 16» (месяц — из заголовка раздела) или «30.09 - 03.10» → (начало, конец) или None."""
    m = re.match(r"^(\d{1,2})\s*[-–]\s*(\d{1,2})$", s)
    try:
        if m:
            d1, d2 = int(m.group(1)), int(m.group(2))
            m1 = month
            m2 = month % 12 + 1 if d2 < d1 else month  # «30 - 2»: конец в следующем месяце
        else:
            m = re.match(r"^(\d{1,2})\.(\d{2})\s*[-–]\s*(\d{1,2})\.(\d{2})$", s)
            if not m:
                return None
            d1, m1, d2, m2 = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))
        start_year = _year(m1, season_year)
        return dt.date(start_year, m1, d1), dt.date(start_year + (1 if m2 < m1 else 0), m2, d2)
    except ValueError:
        return None


def ffkm_calendar(page=None):
    """Календарь ФФКМ за сезон: [{number, start, end, title, place, program, page}].
    Каждая строка — турнир; дата без месяца (месяц в заголовке раздела «Август» и т.п.)."""
    if page is None:
        page = net.fetch(FFKM_CALENDAR)
    y = _FFKM_SEASON.search(page)
    if not y:
        return []
    season_year = int(y.group(1))
    tokens = [(m.start(), "M", st._text(m.group(1))) for m in _FFKM_MONTH.finditer(page)]
    tokens += [(m.start(), "R", m.group(1)) for m in _FFKM_ROW.finditer(page)]
    tokens.sort(key=lambda t: t[0])
    out = []
    month = None
    for _, kind, val in tokens:
        if kind == "M":
            month = fsr.month_num(val)
            continue
        cells = _CELL.findall(val)
        if len(cells) < 6 or not month:
            continue
        rng = _ffkm_range(st._text(cells[1]), month, season_year)
        if not rng:
            continue
        strong = re.search(r"(?s)<strong>(.*?)</strong>", cells[2])
        link = re.search(r'href="([^"]+)"', cells[2])
        out.append({
            "number": st._text(cells[0]),
            "start": rng[0], "end": rng[1],
            "title": st._text(strong.group(1)) if strong else st._text(cells[2]),
            "place": st._text(cells[3]),
            "program": st._text(cells[4]),
            "page": urljoin(FFKM_CALENDAR, link.group(1)) if link else None,
        })
    return out


# ссылка на табло: «…/results/2026-2027/2026-08-24_pm/» (как у «Первенства Москвы») или «…/index.htm»
_FFKM_RESULTS = re.compile(r'href="([^"]*/results/\d{4}-\d{4}/([^"#?/]+)/?(?:index\.htm)?)"')


def ffkm_detail(url, start=None):
    """Карточка турнира ФФКМ → адрес табло (…/index.htm) или None, пока табло не открыто."""
    return ffkm_table_url(net.fetch(url), url, start)


def ffkm_table_url(page, url, start=None):
    """Адрес табло из карточки турнира (см. ffkm_detail). На карточке бывают ссылки на чужие
    табло: берём то, чья папка начинается с даты старта."""
    found = [(urljoin(url, href), slug) for href, slug in _FFKM_RESULTS.findall(page)]
    if not found:
        return None
    pick = found[0]
    if start is not None:
        pick = next((f for f in found if f[1].startswith(start.isoformat())), pick)
    table = pick[0]
    return table if table.endswith(".htm") else table.rstrip("/") + "/index.htm"


# ---------------------------------------------------------------- Самара: статьи и календарь

_CARD = re.compile(
    r'(?s)<div class="title">\s*<a href="([^"]+)">\s*(.*?)\s*</a>.*?<div class="previewtext">\s*<h4>([^<]+)</h4>')
_CARD_RANGE = re.compile(r"^(\d{1,2})(?:\s+([а-я]+))?\s*[-–]\s*(\d{1,2})\s+([а-я]+)\s+(\d{4})$")
_CARD_DAY = re.compile(r"^(\d{1,2})\s+([а-я]+)\s+(\d{4})$")


def card_dates(s):
    """«26-29 ноября 2026», «30 ноября - 2 декабря 2026», «25 января 2026» → (начало, конец)."""
    t = re.sub(r"\s+", " ", html.unescape(s).replace("\xa0", " ")).strip().lower()
    m = _CARD_RANGE.match(t)
    if m:
        m2 = fsr.month_num(m.group(4))
        m1 = fsr.month_num(m.group(2)) if m.group(2) else m2
        if not m1 or not m2:
            return None
        y = int(m.group(5))
        try:
            return dt.date(y - 1 if m1 > m2 else y, m1, int(m.group(1))), dt.date(y, m2, int(m.group(3)))
        except ValueError:
            return None
    m = _CARD_DAY.match(t)
    if m:
        mo = fsr.month_num(m.group(2))
        try:
            d = dt.date(int(m.group(3)), mo, int(m.group(1))) if mo else None
        except ValueError:
            d = None
        return (d, d) if d else None
    return None


def samara_cards(season_start):
    """Статьи о турнирах на skate63.ru, даты которых не раньше season_start:
    [{title, url, start, end}]. Список идёт от новых к старым, листаем, пока есть статьи сезона."""
    out = []
    for n in range(1, 4):
        try:
            page = net.fetch(SKATE63_ARTICLES + (f"?PAGEN_1={n}" if n > 1 else ""))
        except net.FetchError:
            if n == 1:
                raise
            break
        found = []
        for href, title, h4 in _CARD.findall(page):
            rng = card_dates(h4)
            if rng:
                found.append({"title": st._text(title), "url": urljoin(SKATE63, href),
                              "start": rng[0], "end": rng[1]})
        if not found:
            break
        out += [c for c in found if c["start"] >= season_start]
        if min(c["start"] for c in found) < season_start:
            break
    return out


_PDF_LINK = re.compile(r'(?is)<a[^>]*href="([^"]+\.pdf)"[^>]*>(.*?)</a>')
_SCHEDULE_WORD = re.compile(r"Р[а-яё]{0,2}писани", re.I)  # «Расписание» и опечатка «Раписание» на сайте


def samara_schedules(url):
    """PDF расписания из статьи турнира (ссылка с подписью «Расписание …»)."""
    return schedule_links(net.fetch(url), url)


def schedule_links(page, url):
    """Ссылки на PDF расписания в статье. Протоколы и регламенты не берём: протокол — своя
    вёрстка, разборщика пока нет."""
    return [ascii_url(urljoin(url, href)) for href, label in _PDF_LINK.findall(page)
            if _SCHEDULE_WORD.search(st._text(label))]


def samara_calendar_pdf(page=None):
    """PDF «Календарь основных мероприятий … в сезоне 2026-2027» со страницы календаря."""
    if page is None:
        page = net.fetch(SKATE63_CALENDAR)
    for href in re.findall(r'href="([^"]+\.pdf)"', page):
        name = unquote(href)
        if "Календарь" in name and "2026" in name:
            return ascii_url(urljoin(SKATE63_CALENDAR, href))
    return None


_MONTH_HDR = re.compile(r"^\s*([А-Яа-яЁё]+)\s+(\d{4})\s*$")
_CAL_ROW = re.compile(r"^\s{0,6}(\d{1,2})(?:[.](\d{2}))?(?:\s*[-–]\s*(\d{1,2})(?:[.](\d{2}))?)?\s{2,}\S")


def samara_calendar_ranges(text):
    """Календарь Самары (PDF, pdftotext -layout): [(начало, конец)] по строкам с датами.
    Нужен для сверки: даты статей должны совпадать с календарём. Название не разбираем —
    колонки в PDF переносятся по строкам."""
    out = []
    month = year = None
    for line in text.splitlines():
        h = _MONTH_HDR.match(line)
        if h and fsr.month_num(h.group(1)):
            month, year = fsr.month_num(h.group(1)), int(h.group(2))
            continue
        m = _CAL_ROW.match(line)
        if not m or month is None:
            continue
        d1 = int(m.group(1))
        m1 = int(m.group(2)) if m.group(2) else month
        if m.group(3):
            d2 = int(m.group(3))
            m2 = int(m.group(4)) if m.group(4) else (m1 if d2 >= d1 else m1 % 12 + 1)
        else:
            d2, m2 = d1, m1
        try:
            y2 = year + (1 if m2 < m1 else 0)
            out.append((dt.date(year, m1, d1), dt.date(y2, m2, d2)))
        except ValueError:
            continue
    return out


_VENUE = re.compile(r"(?m)^\s*г\.\s*([^,\n]+),\s*(.+?)\s{2,}\d{1,2}[-–\s]")


def schedule_venue(text):
    """Город и площадка из шапки расписания: «г. Самара, СКК «Дворец …»   16-19 апреля» → (город, площадка)."""
    m = _VENUE.search(text)
    return (m.group(1).strip(), m.group(2).strip()) if m else ("", "")


def tail(url):
    """Последний кусок адреса без «/» — основа для id турнира."""
    return url.rstrip("/").rsplit("/", 1)[-1]
