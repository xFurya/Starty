"""Быстрый сбор во время стартов: только итоги идущих и только что прошедших сегментов.

    python3 -m scraper.live          — один проход: обновить site/data/events.json, календари, протоколы
    python3 -m scraper.live --hot    — то же, но только идущие и свежие старты (для цикла)
    python3 -m scraper.live --check  — есть ли что обновлять (код выхода 0 — есть)
    python3 -m scraper.live --plan   — что делать циклу: hot | cold | wait <секунд> | none

Полный сбор (build) идёт минуты и дважды в день; этот — секунды. Задание live.yml крутит его
циклом (tools/live-loop.sh) каждые несколько минут, пока что-то идёт: промежуточные итоги,
тройка, места наших, итог турнира и примечательное появляются, как только их выложили на табло.
"""
import datetime as dt
import json
import os
import sys

from . import build as b
from . import names as nm
from . import net
from . import people as pp
from . import protocols as P
from . import results as rs
from . import swisstiming as st

BEFORE = dt.timedelta(minutes=15)
AFTER = dt.timedelta(hours=24)
# «Горячий» старт — идёт или закончился недавно: его опрашиваем в каждом проходе цикла. Остальные
# несостоявшиеся итоги (оценки так и не выложили) — раз за запуск задания, то есть раз в час.
HOT_AFTER = dt.timedelta(minutes=90)
# Старт, до которого меньше этого, цикл ждёт, не выходя: следующий запуск по расписанию может
# опоздать (cron GitHub не точен: 29 октября запусков не было с 5:31 до 13:05 МСК, и утренние
# сегменты остались без итогов), и начало старта было бы пропущено. Задание живёт до 5 ч 50 мин.
HORIZON = dt.timedelta(hours=5)
# Запросов к табло за прогон (оглавления, страницы сегментов, PDF оценок, итоги, судьи) и
# таймаут одного запроса: задание live — 10 минут. Не хватило бюджета — сегмент остаётся
# как в прошлом файле, в журнал пишется, что пропущено. Полный проход (горячие и старые
# неокончательные вместе) шире: старых сегментов в нём может быть несколько.
BUDGET = 12
COLD_BUDGET = 30
TIMEOUT, TRIES = 15, 2


def settled(ev):
    """Итог окончательный: сегмент окончательный по судейским оценкам (или по времени, если
    включено), тройка на месте, итог вида (если он здесь бывает) тоже. Такой сегмент больше
    не опрашиваем. У старых событий без live.basis — прежнее правило."""
    live = ev.get("live") or {}
    if "basis" in live:
        return live["basis"] in ("judges", "time") and bool(ev.get("podium")) and \
            (not live.get("cat") or bool(ev.get("total")))
    return bool(ev.get("podium")) and not ev.get("provisional") and (not live.get("cat") or bool(ev.get("total")))


def active(ev, now, hot=False):
    """Событие нужно опросить сейчас. hot — только идущие и недавно закончившиеся."""
    if not ev.get("live"):
        return False
    t0 = dt.datetime.fromisoformat(ev["start"])
    t1 = dt.datetime.fromisoformat(ev["end"])
    after = HOT_AFTER if hot else AFTER
    return t0 - BEFORE <= now <= t1 + after and not settled(ev)


def plan(events, now):
    """Что делать циклу: ("hot", 0) — есть горячие, опрашиваем; ("cold", 0) — горячих нет, но есть
    старые неокончательные (один проход и выход); ("wait", секунд) — скоро начнётся, ждём;
    ("none", 0) — делать нечего."""
    if any(active(e, now, hot=True) for e in events):
        return "hot", 0
    if any(active(e, now) for e in events):
        return "cold", 0
    soon = [dt.datetime.fromisoformat(e["start"]) - BEFORE - now for e in events
            if e.get("live") and not settled(e) and dt.datetime.fromisoformat(e["start"]) > now]
    soon = [d for d in soon if d <= HORIZON]
    if soon:
        return "wait", max(1, int(min(soon).total_seconds()))
    return "none", 0


def to_refresh(events, now, hot_only):
    """События прохода. Горячие — первыми: бюджет запросов не должен уйти на старые сегменты
    раньше идущих (сортировка устойчивая, внутри групп порядок файла)."""
    todo = [e for e in events if active(e, now, hot=hot_only)]
    todo.sort(key=lambda e: not active(e, now, hot=True))
    return todo


def load():
    with open(b.OUT_JSON, encoding="utf-8") as f:
        return json.load(f)


def _seg_of(idx, url):
    for c in idx["categories"]:
        for s in c["segments"]:
            if s["url"] == url:
                return s
    return None


def _cat_of(idx, url):
    for c in idx["categories"]:
        for s in c["segments"]:
            if s["url"] == url:
                return c
    return None


def refresh(ev, idx, names, now, fetcher=None):
    """Обновить событие по табло. True — что-то изменилось.

    Окончательность — от protocols.segment_view (судейские оценки сегмента). Окончательный
    сегмент не понижаем: если оценки пропали или PDF не прочитан (сеть), остаётся final.
    fetcher — загрузка на прогон (кэш и бюджет запросов)."""
    fetcher = fetcher or P.Fetcher()
    live = ev["live"]
    before = json.dumps(ev, sort_keys=True, ensure_ascii=False)
    seg = _seg_of(idx, live["seg"])
    if not seg:
        b.log("  ! сегмента нет в табло:", live["seg"])
        return False
    cat = _cat_of(idx, live["seg"]) or {}
    try:
        page = fetcher.page(live["seg"])
    except net.FetchError as e:
        b.log("  ! табло:", live["seg"], e)
        return False
    start = dt.datetime.fromisoformat(ev["start"])
    if start > now:
        return False
    view = P.segment_view(
        seg=seg, category=cat.get("name", ""), code=ev["seg"], page=page, cat_url=live.get("cat"),
        now=now, start=start, end=dt.datetime.fromisoformat(ev["end"]),
        marks=bool(idx.get("marks")), fetcher=fetcher,
        final_by_time=b.CFG.get("final_by_time", False),
        podium_from_pdf=b.CFG.get("podium_from_judges_pdf", False))
    if view["reason"]:
        b.log("  ! оценки не сошлись с табло, тройку не ставим:", ev["title"], view["reason"])
    results = view["results"] or []
    if not results:
        return False
    prev_final = live.get("basis") == "judges"
    basis = view["basis"] or ("judges" if prev_final else None)
    if prev_final and not view["basis"]:
        b.log("  ! оценки сегмента сейчас не подтверждены, окончательный протокол оставляем:", ev["title"])
    done = basis is not None
    to_ru = lambda n: live.get("names", {}).get(n) or names.to_ru(n)
    place = {nm.key(to_ru(r["name"])): r["place"] for r in results}
    for o in ev["ours"] + ev.get("field", []):
        p = place.get(nm.key(o["name"]))
        if p:
            o["place"] = p
        elif not prev_final:
            # табло не оценило ещё: прежнее место (чужое, из старого разбора) не оставляем
            o.pop("place", None)
    ev["podium"] = [{"place": r["place"], "name": to_ru(r["name"]), "nation": r["nation"],
                     "points": r["points"]} for r in results[:3]]
    live["basis"] = basis
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
            cr = st.parse_category_results(live["cat"], fetcher.page(live["cat"]))
        except net.FetchError as e:
            b.log("  ! итог вида:", live["cat"], e)
            cr = {"complete": False}
        if cr["complete"]:
            rows = cr["rows"]
            ev["total"] = [{"place": r["place"], "name": to_ru(r["name"]), "nation": r["nation"],
                            "points": r["points"]} for r in rows[:3]]
            final = {nm.key(to_ru(r["name"])): r["place"] for r in rows}
            for o in ev["ours"] + ev.get("field", []):
                if final.get(nm.key(o["name"])):
                    o["final"] = final[nm.key(o["name"])]
            first = {}
            if live.get("first"):
                try:
                    first = {r["name"]: r["place"]
                             for r in st.parse_segment_results(fetcher.page(live["first"])) or []}
                except net.FetchError:
                    pass
            f = rs.total_facts(live["cat"] + "#total", rows, first, kind=ev["kind"], level=ev["level"],
                               intl=ev["intl"], season=rs.season_of(b.CFG), to_ru=to_ru)
            if f:
                ev["facts"] = rs.unique_facts((ev.get("facts") or []) + f)
    ev["desc"] = b.describe(ev)
    return json.dumps(ev, sort_keys=True, ensure_ascii=False) != before


def tournament_doc(idx, events, names, now, fetcher, prev):
    """Файл протокола турнира по табло: окончательные сегменты — из прежнего файла (не
    перечитываем), будущие — без запросов, остальные — страница, PDF оценок, итог вида.
    Страница не прочиталась (сеть, бюджет) — сегмент остаётся как в прежнем файле."""
    ev0 = events[0]
    fix = pp.entry_name if ev0.get("tier") == "regional" else (lambda s: s)
    name_of = b.protocol_name_of(names, fix)
    sched = {(e["kind"], e["level"], e["seg"]): (dt.datetime.fromisoformat(e["start"]),
                                                  dt.datetime.fromisoformat(e["end"])) for e in events}
    final_by_time = b.CFG.get("final_by_time", False)
    podium_from_pdf = b.CFG.get("podium_from_judges_pdf", False)
    cats = []
    for c, kind, level in b.categories_of(idx, ev0["intl"]):
        codes = [b.seg_code(s["name"]) for s in c["segments"]]
        last_seg = max((b.SEG_ORDER[x] for x in codes if x), default=None)
        recs = []
        for s, code in zip(c["segments"], codes):
            if not code:
                continue
            prev_seg = P.find_segment(prev, c["name"], code)
            start, end = sched.get((kind, level, code), (None, None))
            if start is None:
                # события на сегмент нет (наших в нём нет): время — из прежнего файла или оглавления табло,
                # иначе сегмент будущих дней стал бы «не опубликован» вместо «запланирован»
                if prev_seg and prev_seg.get("start"):
                    start = dt.datetime.fromisoformat(prev_seg["start"])
                    end = dt.datetime.fromisoformat(prev_seg["end"]) if prev_seg.get("end") else None
                elif s.get("start"):
                    start = s["start"]
            if prev_seg and prev_seg["state"] == "final":
                recs.append(prev_seg)
                continue
            page = None
            skipped = len(fetcher.skipped)
            if start is None or now >= start:
                try:
                    page = fetcher.page(s["url"])
                except net.FetchError:
                    if prev_seg:
                        recs.append(prev_seg)
                    continue
            view = P.segment_view(
                seg=s, category=c["name"], code=code, page=page,
                cat_url=c.get("results_url") if b.SEG_ORDER[code] == last_seg else None,
                now=now, start=start, end=end, marks=idx["marks"], fetcher=fetcher,
                final_by_time=final_by_time, podium_from_pdf=podium_from_pdf)
            rec = P.make_segment(seg=s, code=code, start=start, end=end, view=view, name_of=name_of,
                                 fetcher=fetcher, prev=prev_seg, log=b.log)
            if prev_seg and len(fetcher.skipped) > skipped:
                rec = prev_seg  # не хватило бюджета на PDF или итог — состояние не меняем
            recs.append(rec)
        prev_total = P.find_total(prev, c["name"])
        total = prev_total
        last_final = any(r["state"] == "final" for r in recs if b.SEG_ORDER[r["code"]] == last_seg)
        if c.get("results_url") and any(r["state"] != "scheduled" for r in recs) \
                and not (prev_total and prev_total["state"] == "final"):
            try:
                total = P.total_record(fetcher.page(c["results_url"]), last_final, name_of)
            except net.FetchError:
                total = prev_total
        cats.append(P.category_record(kind, level, c["name"], recs, total))
    return P.make_doc(tid=ev0["tid"], tournament=ev0["tournament"], src=idx["url"], marks=idx["marks"],
                      categories=cats, now=now)


def protocols(todo, events, indexes, names, now, fetcher, proto_dir=None):
    """Файлы протоколов турниров, у которых сейчас идёт или только что прошёл старт, и status.json.
    → сколько файлов записано (изменилось содержимое)."""
    proto_dir = proto_dir or b.PROTO_DIR
    os.makedirs(proto_dir, exist_ok=True)
    status = P.read_status(proto_dir)
    written = 0
    for tid in dict.fromkeys(e["tid"] for e in todo):
        evs = [e for e in events if e["tid"] == tid]
        idx = indexes.get(evs[0]["live"]["idx"])
        if idx is None:
            status[tid] = P.status_item(status.get(tid), now, "net")
            continue
        errors_before, skipped_before = len(fetcher.errors), len(fetcher.skipped)
        path = os.path.join(proto_dir, P.proto_name(tid))
        prev = P.load_doc(path)
        try:
            doc = tournament_doc(idx, evs, names, now, fetcher, prev)
        except Exception as e:  # один турнир не должен срывать остальные
            b.log(f"  ! протокол {tid}:", e)
            status[tid] = P.status_item(status.get(tid), now, "format")
            continue
        for note in P.merge_prev(doc, prev):
            b.log(f"  протокол {tid}: {note}")
        ok, wrote = P.publish(proto_dir, doc, b.CFG.get("final_by_time", False), b.log)
        written += wrote
        error = "format" if not ok else P.fetch_error(fetcher.errors[errors_before:])
        status[tid] = P.status_item(status.get(tid), now, error, complete=len(fetcher.skipped) == skipped_before)
    P.write_status(proto_dir, status, now)
    return written


def main():
    now = dt.datetime.now(dt.timezone.utc)
    data = load()
    if "--plan" in sys.argv:
        what, secs = plan(data["events"], now)
        print(f"wait {secs}" if what == "wait" else what)
        return 0
    hot_only = "--hot" in sys.argv
    todo = to_refresh(data["events"], now, hot_only)
    if "--check" in sys.argv:
        print(f"идут или только что прошли: {len(todo)}")
        return 0 if todo else 1
    if not todo:
        b.log("нечего обновлять")
        return 0
    names = nm.Names(b.NAMES, b.CFG.get("aliases"))
    indexes = {}
    budget = BUDGET if hot_only else COLD_BUDGET
    fetcher = P.Fetcher(budget=budget, timeout=TIMEOUT, tries=TRIES)
    changed = 0
    for ev in todo:
        url = ev["live"]["idx"]
        if url not in indexes:
            try:
                indexes[url] = st.parse_index_page(fetcher.page(url), url)
            except net.FetchError as e:
                b.log("  ! табло турнира:", url, e)
                indexes[url] = None
        if indexes[url] and refresh(ev, indexes[url], names, now, fetcher):
            changed += 1
            b.log("  обновлено:", ev["title"], "(промежуточные)" if ev.get("provisional") else "")
    written = protocols(todo, data["events"], indexes, names, now, fetcher)
    before = [e.get("proto") for e in data["events"]]
    P.attach_proto(data["events"], b.PROTO_DIR)
    if [e.get("proto") for e in data["events"]] != before:
        changed += 1
    b.log(f"запросов к табло: {fetcher.requests} из {budget}; файлов протоколов записано: {written}")
    if fetcher.skipped:
        b.log(f"  ! бюджет запросов исчерпан, пропущено {len(fetcher.skipped)}: "
              + ", ".join(dict.fromkeys(fetcher.skipped)))
    if changed:
        data["checked"] = now.isoformat()
        b.write_site(data)
        rs.save()
    b.log(f"быстрый сбор: опрошено {len(todo)}, обновлено {changed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
