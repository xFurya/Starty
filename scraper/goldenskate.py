"""Golden Skate: общий календарь международных турниров (WordPress «The Events
Calendar»). Нужен для турниров вне ISU-серий, куда могут поехать наши: у них нет
страницы на isu-skating.com, но есть табло Swiss Timing по ссылке «Results»."""
import html
import re

from . import net

API = "https://www.goldenskate.com/wp-json/tribe/events/v1/events"

# Это всё уже покрыто ISU — не дублируем
ISU_LIKE = re.compile(r"Challenger Series|Grand Prix|Junior Grand Prix|European|World|Four Continents|"
                      r"National|Championships", re.I)


def events(start, end, include_isu=False):
    url = f"{API}?start_date={start:%Y-%m-%d}&end_date={end:%Y-%m-%d}&per_page=100"
    data = net.fetch_json(url)
    out = []
    for e in data.get("events", []):
        title = html.unescape(e.get("title") or "")
        if ISU_LIKE.search(title) and not include_isu:
            continue
        desc = e.get("description") or ""
        res = re.findall(r'<a href="([^"]+)"[^>]*>\s*Results\s*</a>', desc)
        venue = e.get("venue") or {}
        if isinstance(venue, list):
            venue = venue[0] if venue else {}
        out.append({
            "title": title,
            "start": (e.get("start_date") or "")[:10],
            "end": (e.get("end_date") or "")[:10],
            "city": venue.get("city") or "",
            "country": venue.get("country") or "",
            "results_url": res[0] if res else None,
        })
    return out


def short_name(title):
    t = re.sub(r"^\d{4}(-\d\d)?\s+", "", title)
    t = re.sub(r"\s+\d{4}$", "", t)
    t = re.sub(r"^\d+(st|nd|rd|th)\s+", "", t)
    if re.search(r"\|\s*Challenger Series", t):
        t = "CS " + re.sub(r"\s*\|.*$", "", t)
        return re.sub(r"\s+Challenge$", "", t).strip()
    m = re.match(r"^Junior Grand Prix\s+(.+)$", t)
    if m:
        return "JGP " + m.group(1)
    m = re.match(r"^Grand Prix\s+(.+)$", t)
    if m:
        return "GP " + m.group(1)
    return t.strip()
