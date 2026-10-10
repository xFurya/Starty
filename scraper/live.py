"""Быстрый сбор во время стартов: только итоги идущих и только что прошедших сегментов.

    python3 -m scraper.live          — обновить site/data/events.json и календари
    python3 -m scraper.live --check  — есть ли что обновлять (код выхода 0 — есть)

Полный сбор (build) идёт минуты и дважды в день; этот — секунды и каждые 10 минут,
пока что-то идёт: промежуточные итоги, тройка, места наших, итог турнира и
примечательное появляются, как только их выложили на табло.
"""
import datetime as dt
import json
import sys

from . import build as b
from . import names as nm
from . import net
from . import results as rs
from . import swisstiming as st

BEFORE = dt.timedelta(minutes=15)
AFTER = dt.timedelta(hours=24)


def settled(ev):
    """Итог окончательный: тройка без пометки «промежуточные», итог вида (если он здесь
    бывает) на месте. Такой сегмент больше не опрашиваем."""
    live = ev.get("live") or {}
    return bool(ev.get("podium")) and not ev.get("provisional") and (not live.get("cat") or bool(ev.get("total")))


def active(ev, now):
    if not ev.get("live"):
        return False
    t0 = dt.datetime.fromisoformat(ev["start"])
    t1 = dt.datetime.fromisoformat(ev["end"])
    return t0 - BEFORE <= now <= t1 + AFTER and not settled(ev)


def load():
    with open(b.OUT_JSON, encoding="utf-8") as f:
        return json.load(f)


def _seg_of(idx, url):
    for c in idx["categories"]:
        for s in c["segments"]:
            if s["url"] == url:
                return s
    return None


def refresh(ev, idx, names, now):
    """Обновить событие по табло. True — что-то изменилось."""
    live = ev["live"]
    before = json.dumps(ev, sort_keys=True, ensure_ascii=False)
    seg = _seg_of(idx, live["seg"]) or {}
    try:
        results = st.parse_segment_results(net.fetch(live["seg"]))
    except net.FetchError as e:
        b.log("  ! табло:", live["seg"], e)
        return False
    if not results or dt.datetime.fromisoformat(ev["start"]) > now:
        return False
    done = bool(seg.get("final") or not idx.get("final_marks"))
    to_ru = lambda n: live.get("names", {}).get(n) or names.to_ru(n)
    place = {nm.key(to_ru(r["name"])): r["place"] for r in results}
    for o in ev["ours"]:
        p = place.get(nm.key(o["name"]))
        if p:
            o["place"] = p
    ev["podium"] = [{"place": r["place"], "name": to_ru(r["name"]), "nation": r["nation"],
                     "points": r["points"]} for r in results[:3]]
    if done:
        ev.pop("provisional", None)
    else:
        ev["provisional"] = True
    if done and seg.get("judges_pdf") and not ev.get("facts"):
        f = rs.segment_facts(seg["judges_pdf"], kind=ev["kind"], level=ev["level"], seg=ev["seg"],
                             intl=ev["intl"], season=rs.season_of(b.CFG), to_ru=to_ru, log=b.log)
        if f:
            ev["facts"] = f
    if done and live.get("cat") and not ev.get("total"):
        try:
            cr = st.parse_category_results(live["cat"])
        except net.FetchError as e:
            b.log("  ! итог вида:", live["cat"], e)
            cr = {"complete": False}
        if cr["complete"]:
            rows = cr["rows"]
            ev["total"] = [{"place": r["place"], "name": to_ru(r["name"]), "nation": r["nation"],
                            "points": r["points"]} for r in rows[:3]]
            final = {nm.key(to_ru(r["name"])): r["place"] for r in rows}
            for o in ev["ours"]:
                if final.get(nm.key(o["name"])):
                    o["final"] = final[nm.key(o["name"])]
            first = {}
            if live.get("first"):
                try:
                    first = {r["name"]: r["place"]
                             for r in st.parse_segment_results(net.fetch(live["first"])) or []}
                except net.FetchError:
                    pass
            f = rs.total_facts(live["cat"] + "#total", rows, first, kind=ev["kind"], level=ev["level"],
                               intl=ev["intl"], season=rs.season_of(b.CFG), to_ru=to_ru)
            if f:
                ev["facts"] = (ev.get("facts") or []) + f
    ev["desc"] = b.describe(ev)
    return json.dumps(ev, sort_keys=True, ensure_ascii=False) != before


def main():
    now = dt.datetime.now(dt.timezone.utc)
    data = load()
    todo = [e for e in data["events"] if active(e, now)]
    if "--check" in sys.argv:
        print(f"идут или только что прошли: {len(todo)}")
        return 0 if todo else 1
    if not todo:
        b.log("нечего обновлять")
        return 0
    names = nm.Names(b.NAMES, b.CFG.get("aliases"))
    indexes = {}
    changed = 0
    for ev in todo:
        url = ev["live"]["idx"]
        if url not in indexes:
            try:
                indexes[url] = st.parse_index(url)
            except net.FetchError as e:
                b.log("  ! табло турнира:", url, e)
                indexes[url] = None
        if indexes[url] and refresh(ev, indexes[url], names, now):
            changed += 1
            b.log("  обновлено:", ev["title"], "(промежуточные)" if ev.get("provisional") else "")
    if changed:
        data["checked"] = now.isoformat()
        b.write_site(data)
        rs.save()
    b.log(f"быстрый сбор: опрошено {len(todo)}, обновлено {changed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
