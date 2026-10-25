"""Итоги сегмента и примечательное — общее для полного сбора (build) и быстрого (live).

Примечательное считается один раз, когда протокол утверждён (есть судейские
оценки), и запоминается в data/facts.json по адресу протокола.
"""
import json
import os

from . import facts as fx
from . import keep
from . import net
from . import swisstiming as st

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FACTS = os.path.join(ROOT, "data", "facts.json")

_store = None

# версия правил: при смене примечательное считается заново; оценочные факты (score/record) прежней
# версии при этом переносятся — их не пересчитать, статистика ISU уже включает этот турнир
VERSION = "7"


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
    # записи прошлых версий правил нужны, пока по их адресу нет записи текущей версии:
    # из них переносятся оценочные факты (_adopt)
    for k in [k for k in _store if not k.startswith(VERSION + "|") and f"{VERSION}|{_url(k)}" in _store]:
        del _store[k]
    os.makedirs(os.path.dirname(FACTS), exist_ok=True)
    with open(FACTS, "w", encoding="utf-8") as f:
        json.dump(_store, f, ensure_ascii=False, indent=1, sort_keys=True)


def _url(key):
    return key.partition("|")[2]


def _adopt(url, facts, to_ru=None):
    """К фактам текущей версии добавляет оценочные факты прежних версий по тому же адресу."""
    legacy = []
    for k, v in _load().items():
        if not k.startswith(VERSION + "|") and _url(k) == url:
            legacy += [f for f in v if f.get("kind") in keep.SCORE_KINDS]
    if not legacy:
        return facts
    return unique_facts(keep.merge_facts(facts, legacy, same_rules=False, to_ru=to_ru))


def unique_facts(facts):
    """Убирает повторы по отображаемому содержимому (спортсмен + текст факта)."""
    out = []
    seen = set()
    for fact in facts or []:
        who = " ".join(str(fact.get("who") or "").split()).casefold()
        text = " ".join(str(fact.get("text") or "").split()).casefold()
        if not text:
            continue
        key = (who, text)
        if key not in seen:
            seen.add(key)
            out.append(fact)
    return out


def season_of(cfg):
    y = int(cfg["season_start"][:4])
    return f"{y}-{str(y + 1)[2:]}"


def side(nation):
    """ru — россиянин (RUS, AIN2, регион на российских стартах), by — белорус (BLR, AIN1), иначе пусто."""
    if nation in ("RUS", "AIN2") or (len(nation) == 3 and nation.isalpha() and not nation.isascii()):
        return "ru"
    if nation in ("BLR", "AIN1"):
        return "by"
    return ""


def _ours(nation):
    return bool(side(nation))


def segment_facts(pdf, *, kind, level, seg, intl, season, to_ru, log=print):
    """Факты сегмента по судейским оценкам: [{who, text, kind}] (кэш — по адресу PDF)."""
    store = _load()
    pdf_key = f"{VERSION}|{pdf}"
    if pdf_key in store:
        store[pdf_key] = _adopt(pdf, unique_facts(store[pdf_key]), to_ru)
        return store[pdf_key]
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
    except Exception as e:  # в том числе fx.StatUnavailable: пустой расчёт в кэш не пишем
        log("  ! примечательное:", pdf, e)
        return []
    store[pdf_key] = _adopt(pdf, unique_facts(out), to_ru)
    return store[pdf_key]


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
    if intl:
        rows = [{"place": sk["rank"], "name": sk["name"], "nation": sk["nation"]} for sk in skaters]
        for name, k, text in fx.lead_facts(rows, intl, lambda r: side(r["nation"])):
            out.append({"who": to_ru(name) if name else "", "text": text, "kind": k})
    return unique_facts(out)


def total_facts(key, rows, first_places, *, kind, level, intl, season, to_ru):
    """Итог вида: рекорд суммы, лучшая сумма сезона, личный рекорд суммы, взлёт после
    первого сегмента, россияне и белорусы впереди (белорусов называем только если выиграли), большой отрыв. rows — итог по местам
    (имена латиницей, как в протоколе); first_places — {имя латиницей: место после первого сегмента}."""
    store = _load()
    url, key = key, f"{VERSION}|{key}"
    if key in store:
        store[key] = _adopt(url, unique_facts(store[key]), to_ru)
        return store[key]
    try:
        out = _total(rows, first_places, kind, level, intl, season, to_ru)
    except Exception:  # в том числе статистика ISU не ответила: не запоминаем, посчитаем в следующий раз
        return []
    store[key] = _adopt(url, unique_facts(out), to_ru)
    return store[key]


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
    first_seg = "ритм-танца" if kind == "dance" else "короткой программы"
    for name, k, text in fx.place_facts(firsts, top, intl, lambda r: side(r["nation"]), margin, first_seg):
        out.append({"who": to_ru(name) if name else "", "text": text, "kind": k})
    return unique_facts(out)
