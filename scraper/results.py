"""Итоги сегмента и примечательное — общее для полного сбора (build) и быстрого (live).

Примечательное считается один раз, когда протокол утверждён (есть судейские
оценки), и запоминается в data/facts.json по адресу протокола.
"""
import json
import os

from . import facts as fx
from . import net
from . import swisstiming as st

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FACTS = os.path.join(ROOT, "data", "facts.json")

_store = None


def _load():
    global _store
    if _store is None:
        try:
            with open(FACTS, encoding="utf-8") as f:
                _store = json.load(f)
        except (OSError, ValueError):
            _store = {}
    return _store


def save():
    if _store is None:
        return
    os.makedirs(os.path.dirname(FACTS), exist_ok=True)
    with open(FACTS, "w", encoding="utf-8") as f:
        json.dump(_store, f, ensure_ascii=False, indent=1, sort_keys=True)


def season_of(cfg):
    y = int(cfg["season_start"][:4])
    return f"{y}-{str(y + 1)[2:]}"


def _ours(nation):
    return nation in ("RUS", "AIN2") or (len(nation) == 3 and nation.isalpha() and not nation.isascii())


def segment_facts(pdf, *, kind, level, seg, intl, season, to_ru, log=print):
    """Факты сегмента по судейским оценкам: [{who, text, kind}] (кэш — по адресу PDF)."""
    store = _load()
    if pdf in store:
        return store[pdf]
    try:
        skaters = st.parse_judges(net.pdf_text(pdf))
    except Exception as e:  # примечательное необязательно — расписание и итоги важнее
        log("  ! судейские оценки:", pdf, e)
        return []
    if not skaters:
        # не разобрали — не запоминаем, попробуем в следующий раз
        return []
    try:
        out = _segment(skaters, kind, level, seg, intl, season, to_ru)
    except Exception as e:
        log("  ! примечательное:", pdf, e)
        return []
    store[pdf] = out
    return out


def _segment(skaters, kind, level, seg, intl, season, to_ru):
    out = []
    for sk in sorted(skaters, key=lambda x: x["rank"]):
        who = to_ru(sk["name"])
        for k, text in fx.element_facts(sk, kind, level, seg):
            out.append({"who": who, "text": text, "kind": k})
        # с мировой статистикой сравниваем только международные старты: у российских другое судейство
        if intl:
            notable = sk["rank"] <= 3 or _ours(sk["nation"])
            for k, text in fx.score_facts(sk["name"], sk["tss"], kind, level, seg, season, notable):
                out.append({"who": who, "text": text, "kind": k})
    return out


def total_facts(key, rows, first_places, *, kind, level, intl, season, to_ru):
    """Итог вида: рекорд суммы, лучшая сумма сезона, личный рекорд суммы, взлёт после
    первого сегмента, весь пьедестал — наши, большой отрыв. rows — итог по местам
    (имена латиницей, как в протоколе); first_places — {имя латиницей: место после первого сегмента}."""
    store = _load()
    if key in store:
        return store[key]
    try:
        out = _total(rows, first_places, kind, level, intl, season, to_ru)
    except Exception:
        return []
    store[key] = out
    return out


def _total(rows, first_places, kind, level, intl, season, to_ru):
    out = []
    top = sorted(rows, key=lambda r: r["place"])
    for r in top:
        notable = r["place"] <= 3 or _ours(r["nation"])
        if not intl or not notable:
            continue
        try:
            pts = float(r["points"])
        except (TypeError, ValueError):
            continue
        for k, text in fx.score_facts(r["name"], pts, kind, level, "total", season, True):
            out.append({"who": to_ru(r["name"]), "text": text, "kind": k})
    firsts = {fx._key(n): p for n, p in first_places.items()}
    margin = 8 if kind == "dance" else 15
    for name, k, text in fx.place_facts(firsts, top, intl, lambda r: _ours(r["nation"]), margin):
        out.append({"who": to_ru(name) if name else "", "text": text, "kind": k})
    return out
