"""ISU: календарь турниров (Гран-при, юниорский Гран-при, челленджеры, чемпионаты),
расписание сегментов и заявки по категориям.

Сайт isu-skating.com — это Next.js; список турниров и категории лежат в ответе
RSC (заголовок «RSC: 1»), а расписание и заявки отдаёт открытый front-api.isu.org.
Время в getschedule — настоящее UTC (сверено с табло Swiss Timing).
"""
import datetime as dt
import json
import re

from . import net

SITE = "https://isu-skating.com/en/figure-skating"
API = "https://front-api.isu.org"
RSC = {"RSC": "1"}

_dec = json.JSONDecoder()


def _grab(text, marker):
    i = text.find(marker)
    if i < 0:
        return None
    obj, _ = _dec.raw_decode(text, i + len(marker))
    return obj


def events():
    """[{event_id, slug, name, sub, from, to, tz, city, country, country_name,
    results_url, where_to_watch}]"""
    raw = net.fetch(SITE + "/events/", headers=RSC)
    data = _grab(raw, '"initialData":')
    if not data:
        raise net.FetchError("ISU: нет initialData в списке турниров")
    out = []
    for e in data.get("data", []):
        res = None
        for b in e.get("buttons") or []:
            u = b.get("url") or ""
            if u.startswith("http") and ("result" in (b.get("title") or "").lower()):
                res = u
        if not res and (e.get("button_1_url") or "").startswith("http"):
            res = e["button_1_url"]
        if res and "urlsand.com" in res:  # обёртка «безопасных ссылок» вокруг настоящего адреса
            from urllib.parse import parse_qs, urlparse
            res = parse_qs(urlparse(res).query).get("u", [res])[0]
        if res:
            res = re.sub(r"[?&]utm_[^&]*", "", res)
        out.append({
            "event_id": str(e.get("event_id")),
            "slug": e.get("slug"),
            "name": e.get("name") or "",
            "sub": e.get("event_sub_type_name") or "",
            "from": e.get("from_date_utc") or e.get("from_date"),
            "to": e.get("to_date_utc") or e.get("to_date"),
            "tz": e.get("time_zone") or "",
            "city": e.get("city") or "",
            "country": e.get("country_code") or "",
            "country_name": e.get("country_name") or "",
            "results_url": res,
            "where_to_watch": e.get("where_to_watch") or "",
        })
    return out


def categories(slug, event_id):
    """[{id, name, type}] — категории турнира (Men, Women, Pairs, Ice Dance, Junior …)."""
    raw = net.fetch(f"{SITE}/events/eventdetail/{slug}/?tab=entries_{event_id}", headers=RSC)
    res = _grab(raw, '"eventResults":')
    out = []
    for r in res or []:
        out.append({"id": r.get("event_result_id"), "name": r.get("name") or "",
                    "type": r.get("discipline_type") or ""})
    return out


def entries(event_id, cat):
    """[{name, code, nationality}] — заявка категории. code — под каким флагом
    выступает (AIN1/AIN2/RUS/…), nationality — гражданство участников."""
    # тип категории в ISU бывает перепутан (юниоры-одиночники помечены «Couples»),
    # поэтому решаем по названию
    team = bool(re.search(r"pair|dance", cat["name"], re.I))
    kind = "team" if team else "single"
    body = {"event_result_id": cat["id"], "event_id": int(event_id), "country_code": ""}
    data = net.fetch_json(f"{API}/events/get-event-result-entrylist-{kind}", data=body)
    out = []
    for x in data.get("data") or []:
        code = x.get("started_for_nf_code") or ""
        if x.get("skaters_team"):
            t = x["skaters_team"]
            members = t.get("members") or []
            name = " / ".join(m.get("full_name", "") for m in members) or t.get("name", "")
            nats = {m.get("nationality_code") for m in members}
        else:
            s = x.get("skaters") or x.get("skater") or {}
            name = s.get("full_name") or ""
            nats = {s.get("nationality_code")}
        if (x.get("participant_status_name") or "Active") not in ("Active", ""):
            continue
        out.append({"name": name, "code": code, "nationality": sorted(n for n in nats if n)})
    return out


def schedule(slug):
    """[(datetime UTC, category, segment)]"""
    data = net.fetch_json(f"{API}/events/getschedule/{slug}")
    out = []
    for v in (data.get("data") or {}).get("value") or []:
        t = v.get("start_time")
        if not t:
            continue
        when = dt.datetime.fromisoformat(t.replace("Z", "+00:00"))
        out.append((when, v.get("event_schedule_title") or "", v.get("round_information") or ""))
    return out


def short_name(e):
    """Название без года и лишних слов: «GP de France», «CS Denis Ten Memorial», «JGP Gdansk»."""
    name = re.sub(r"\s*20\d\d(/\d\d)?\s*", " ", e["name"]).strip()
    name = re.sub(r"^ISU\s+", "", name)
    name = re.sub(r"^Figure Skating\s+", "", name)
    sub = e["sub"].lower()
    slug = e["slug"] or ""
    if "challenger" in sub or slug.startswith("isu-cs-"):
        name = re.sub(r"^CS\s+", "", name)
        name = re.sub(r"^\d+(st|nd|rd|th)\s+", "", name)
        name = re.sub(r"\s+Challenge$", "", name)
        return "CS " + name
    if "junior grand prix" in sub or slug.startswith("isu-jgp") or "junior-grand-prix" in slug:
        if "final" in slug:
            return "Финал юниорского Гран-при"
        city = re.sub(r"^.*?(Junior Grand Prix|JGP)\s+(of\s+Figure\s+Skating\s+)?", "", name).strip()
        city = re.sub(r"\s+City$", "", city)
        return "JGP " + city
    if "grand prix" in sub or slug.startswith("isu-gp-") or "grand-prix-final" in slug:
        if "final" in slug or "Final" in name:
            return "Финал Гран-при"
        n = re.sub(r"^GP\s+", "", name)
        n = re.sub(r"^Grand Prix\s+", "", n)
        n = re.sub(r"\s+International$", "", n)
        return "GP " + n
    low = name.lower()
    if "european" in low:
        return "Чемпионат Европы"
    if "four continents" in low:
        return "Чемпионат четырёх континентов"
    if "world junior" in low or "world-junior" in slug:
        return "Чемпионат мира среди юниоров"
    if "world championships" in low:
        return "Чемпионат мира"
    if "team trophy" in low:
        return "Командный чемпионат мира"
    return name
