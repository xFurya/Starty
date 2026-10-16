"""Монотонность: сбор не теряет то, что уже было опубликовано.

Событие, собранное сейчас, сливается с тем же событием из прошлого events.json. Если новое
значение пусто или беднее из-за сбоя источника (табло не открылось, PDF не прочитан, RSS не
ответил) — остаётся прежнее. Явные изменения применяются: другое время, другое значение под
тем же ключом, снятый с заявки спортсмен при живом табло.

Поле → правило:
  facts     объединение по ключу (вид, спортсмен, текст до двоеточия без чисел); значение — новое.
            Оценочные факты (score, record) зависят от статистики ISU на момент расчёта и позже
            не воспроизводятся — они переносятся всегда. Остальные (element, place) — чистая
            функция протокола: переносятся, только если правила (facts_version) те же; смена
            правил ими и должна управлять (убрать неверный факт).
  podium, total  пусто → прежнее; короче прежнего → новые места плюс прежние, не занятые новыми.
  ours, field    по имени; no/warmup/place/final/time из прежнего, если новое их не знает. Спортсмен,
            пропавший из заявки, сохраняется, только если табло сейчас недоступно (live пропал).
  live      пусто → прежнее; пустые ссылки дополняются прежними (тот же idx).
  watch     по имени ресурса; конкретный эфир (watch?v=) не заменяется общей ссылкой /live.
            Ресурсы, которых нет в новом, сохраняются; снять — config.json → keep_retract.
  broadcast объединение имён.
  proto     пусто → прежнее.
Расписание (start, end, venue, title…) всегда новое. desc пересчитывается снаружи.
"""
import re

SCORE_KINDS = ("score", "record")


def _norm(s):
    return " ".join(str(s or "").split()).casefold()


def fact_key(f):
    """Ключ факта: вид, спортсмен и текст до двоеточия, числа заменены на #. Так обновлённый
    «Личный рекорд за ПП: 181.44 (был 165.76)» заменяет прежний, а другой рекорд — нет."""
    text = _norm(f.get("text")).split(":")[0]
    return (f.get("kind"), _norm(f.get("who")), re.sub(r"\d+(?:[.,]\d+)?", "#", text))


def ru_name(to_ru, name):
    """Имя из прежней записи по-русски: прежние факты писали латиницу в обычном регистре
    («Vasil Barakhouski»), а to_ru ждёт фамилию капсом, как в протоколе."""
    if " / " in name:
        return " / ".join(ru_name(to_ru, p.strip()) for p in name.split(" / "))
    got = to_ru(name)
    if got == name and name.isascii():
        given, _, family = name.rpartition(" ")
        if given:
            got = to_ru(f"{given} {family.upper()}")
    return got


def merge_facts(new, old, *, same_rules=True, retract=(), to_ru=None):
    """Новые факты + прежние, которых новые не заменили. Порядок — новые, затем прежние."""
    out = list(new or [])
    have = {fact_key(f) for f in out}
    for f in old or []:
        if not same_rules and f.get("kind") not in SCORE_KINDS:
            continue
        if to_ru and f.get("who"):
            f = dict(f, who=ru_name(to_ru, f["who"]))
        if any(re.search(r, f.get("text", "")) for r in retract):
            continue
        k = fact_key(f)
        if k not in have:
            have.add(k)
            out.append(f)
    return out


def merge_rows(new, old):
    """Итоговые строки (podium/total): новые места главнее, недостающие — из прежних."""
    if not new:
        return list(old or [])
    if not old or len(new) >= len(old):
        return list(new)
    names = {_norm(r["name"]) for r in new}
    places = {r["place"] for r in new}
    extra = [r for r in old if r["place"] not in places and _norm(r["name"]) not in names]
    return sorted(list(new) + extra, key=lambda r: r["place"])


_CARRY = ("time", "no", "warmup", "place", "final")


def merge_people(new, old, keep_missing=False):
    """ours/field: по имени. Данные, которых новое не знает, берём из прежнего (если номер
    жеребьёвки не поменялся — иначе это уже другая жеребьёвка)."""
    was = {}
    for o in old or []:
        was.setdefault(o["name"], o)
    out, seen = [], set()
    for o in new or []:
        p = was.get(o["name"])
        if p and not (o.get("no") and p.get("no") and o["no"] != p["no"]):
            o = dict(o)
            for k in _CARRY:
                if p.get(k) and not o.get(k):
                    o[k] = p[k]
        out.append(o)
        seen.add(o["name"])
    if keep_missing:
        out += [o for o in (old or []) if o["name"] not in seen]
    return out


def merge_live(new, old):
    if not new:
        return old or new
    if old and old.get("idx") == new.get("idx"):
        new = dict(new)
        for k, v in old.items():
            if v and not new.get(k):
                new[k] = v
    return new


def _concrete(url):
    return "watch?v=" in (url or "")


def merge_watch(new, old, retract=()):
    out = [dict(w) for w in new or []]
    idx = {w["name"]: w for w in out}
    for w in old or []:
        if w.get("url") in retract:
            continue
        cur = idx.get(w["name"])
        if cur is None:
            out.append(dict(w))
            idx[w["name"]] = out[-1]
        elif _concrete(w.get("url")) and not _concrete(cur.get("url")) \
                and cur.get("url", "").rstrip("/").endswith("/live"):
            cur["url"] = w["url"]
    return out


def merge_event(new, old, *, same_rules, retract_facts=(), retract_urls=(), to_ru=None):
    """Дополняет новое событие new из прежнего old (на месте). → True, если что-то взято из old."""
    changed = False

    def put(key, val):
        nonlocal changed
        if val not in (None, [], {}) and new.get(key) != val:
            new[key] = val
            changed = True

    live_lost = bool(old.get("live")) and not new.get("live")
    put("facts", merge_facts(new.get("facts"), old.get("facts"), same_rules=same_rules,
                             retract=retract_facts, to_ru=to_ru))
    for k in ("podium", "total"):
        put(k, merge_rows(new.get(k), old.get(k)))
    put("ours", merge_people(new.get("ours"), old.get("ours"), keep_missing=live_lost))
    put("field", merge_people(new.get("field"), old.get("field"), keep_missing=live_lost))
    if live_lost:
        put("athletes", sorted(set(new.get("athletes") or []) | set(old.get("athletes") or [])))
        if old.get("src") and new.get("src") != old["src"]:
            new["src"] = old["src"]
            changed = True
    put("live", merge_live(new.get("live"), old.get("live")))
    put("watch", merge_watch(new.get("watch"), old.get("watch"), retract_urls))
    bc = list(new.get("broadcast") or [])
    bc += [b for b in old.get("broadcast") or [] if b not in bc]
    if bc != new.get("broadcast"):
        new["broadcast"] = bc
        changed = True
    if old.get("proto") and not new.get("proto"):
        new["proto"] = old["proto"]
        changed = True
    return changed
