"""«Примечательное» в профиле спортсмена.

Два источника:
- первые в истории — выверенный вручную список data/feats.json; строка попадает в профиль, только если
  совпали имя и дата рождения (у тёзки другая дата — ему не достанется);
- мировые рекорды — таблицы ISU «Progression of Highest Scores» (isujsstat/phs*.htm). Верхняя строка —
  действующий рекорд, строка ниже — прежний, побитый тем, что над ним. Хозяин строки опознаётся по
  номеру биографии ISU в ссылке; если у профиля номера нет — по имени, стране и возрасту (взрослый
  рекорд в 14 лет — значит, это тёзка).

Таблицы сохраняются в data/records.json и перечитываются раз в сутки; ISU не ответила — берём
сохранённые. Нет ни того, ни другого — рекордов в профиле нет (а не выдуманных).
"""
import datetime as dt
import html
import json
import os
import re

from . import names as nm
from . import net
from .profiles import event_ru

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FEATS = os.path.join(ROOT, "data", "feats.json")
CACHE = os.path.join(ROOT, "data", "records.json")
STAT = "https://www.isuresults.com/isujsstat/"
FRESH = dt.timedelta(hours=20)

# таблица → (вид, отрезок); танцы — свои отрезки
TABLES = [(k, s) for k in "mwp" for s in ("sp", "fs", "to")] + [("d", s) for s in ("rd", "fd", "to")]
SEG_RU = {"sp": "в короткой программе", "fs": "в произвольной программе", "rd": "в ритм-танце",
          "fd": "в произвольном танце", "to": "по сумме баллов"}
PB_SEG = {"sp": "sp", "rd": "sp", "fs": "fs", "fd": "fs", "to": "total"}
RUS = {"RUS", "AIN", "AIN1", "AIN2", "ANA", "OAR", "FSR", "ROC"}
# имя источника в строке «По данным …»: «ISU и Википедии»
OF = {"Википедия": "Википедии"}


# ---------------------------------------------------------------- таблицы ISU

def parse(page):
    """Строки таблицы по порядку мест: [{id, n, c, ev, d, pts, l}]. id — номер биографии ISU из ссылки."""
    rows = []
    for r in re.findall(r"(?s)<tr[^>]*>(.*?)</tr>", page):
        raw = re.findall(r"(?s)<t[dh][^>]*>(.*?)</t[dh]>", r)
        cells = [re.sub(r"\s+", " ", html.unescape(re.sub(r"(?s)<[^>]+>", " ", c))).strip() for c in raw]
        if len(cells) < 6 or not re.fullmatch(r"\d+", cells[0]):
            continue
        d = re.fullmatch(r"(\d\d)/(\d\d)/(\d{4})", cells[4])
        nums = [c for c in cells[5:] if re.fullmatch(r"\d{1,3}\.\d\d", c)]
        if not d or not nums or not cells[1]:
            continue
        m = re.search(r"isufs(\d+)\.htm", raw[1])
        rows.append({"id": m.group(1) if m else "", "n": cells[1], "c": cells[2], "ev": cells[3],
                     "d": f"{d.group(3)}-{d.group(2)}-{d.group(1)}", "pts": nums[-1],
                     "l": cells[-1] if cells[-1] in ("S", "J") else ""})
    return rows


def _load_cache(path):
    try:
        with open(path, encoding="utf-8") as f:
            c = json.load(f)
        return c if isinstance(c, dict) else {}
    except (OSError, ValueError):
        return {}


def tables(now=None, path=CACHE, fetch=None, log=print):
    """{"msp": [...], …}: свежие таблицы ISU или сохранённые, если ISU не ответила."""
    now = now or dt.datetime.now(dt.timezone.utc)
    fetch = fetch or (lambda url: net.fetch(url, timeout=40))
    cache = _load_cache(path)
    have = cache.get("tables") or {}
    try:
        fresh = now - dt.datetime.fromisoformat(cache["at"]) < FRESH
    except (KeyError, TypeError, ValueError):
        fresh = False
    if fresh and all(k + s in have for k, s in TABLES):
        return have
    got, failed = dict(have), 0
    for k, s in TABLES:
        try:
            rows = parse(fetch(f"{STAT}phs{k}{s}.htm"))
        except net.FetchError as e:
            failed += 1
            log(f"  рекорды ISU: phs{k}{s} не ответила ({e})")
            continue
        if rows:  # пустая страница — сбой вёрстки, а не «рекордов нет»: держим прежнее
            got[k + s] = rows
    if failed < len(TABLES):  # хоть что-то ответило — отметка свежести; всё молчит — спросим в следующий раз
        with open(path, "w", encoding="utf-8") as f:
            f.write("{\"at\":" + json.dumps(now.isoformat()) + ",\"tables\":{\n")
            f.write(",\n".join(json.dumps(k, ensure_ascii=False) + ":[\n" +
                               ",\n".join(json.dumps(r, ensure_ascii=False, sort_keys=True) for r in got[k]) + "]"
                               for k in sorted(got)))
            f.write("\n}}\n")
    return got


def _holder(r):
    return r["id"] or nm.key(r["n"])


def _past_season_end(start, till):
    """Рекорд дожил до конца сезона (30 июня), в котором поставлен. Первые недели новой системы
    оценок (лето 2018) и рекорды, перебитые через минуты на том же турнире, этого не проходят."""
    y = int(start[:4]) + (1 if start[5:7] > "06" else 0)
    return till > f"{y}-06-30"


def records(tbls):
    """Мировые рекорды по хозяевам: [{row, s, kind, now, since, till}]. У каждого в каждом отрезке —
    серия его рекордов подряд с лучшей строкой во главе: since — когда серия началась, till — когда её
    перебил другой (у действующего пусто). Прежний рекорд — только если продержался до конца сезона."""
    out = []
    for code, rows in tbls.items():
        s = code[1:]
        if s not in SEG_RU or not rows:
            continue
        # прогрессия: чем выше строка, тем позже поставлена. Иначе это не та таблица — не верим ей
        if any(rows[i]["d"] < rows[i + 1]["d"] for i in range(len(rows) - 1)):
            continue
        i = 0
        while i < len(rows):
            r, j = rows[i], i
            while j + 1 < len(rows) and _holder(rows[j + 1]) == _holder(r):
                j += 1
            since, till = rows[j]["d"], rows[i - 1]["d"] if i else ""
            if r["l"] == "S" and (i == 0 or _past_season_end(since, till)):
                out.append({"row": r, "s": s, "kind": code[0], "now": i == 0, "since": since, "till": till})
            i = j + 1
    return out


def record_title(rec):
    seg = SEG_RU[rec["s"]]
    if rec["now"]:
        return f"Действующий мировой рекорд {seg}"
    y1, y2 = rec["since"][:4], rec["till"][:4]
    return f"Мировой рекорд {seg} в {y1} году" if y1 == y2 else f"Мировой рекорд {seg} в {y1}–{y2} годах"


# ---------------------------------------------------------------- к профилю

def load(path=FEATS, tbls=None, log=print):
    """Всё, что нужно write(): {"feats": [...], "src": {...}, "records": [...]}."""
    try:
        with open(path, encoding="utf-8") as f:
            cur = json.load(f)
    except (OSError, ValueError) as e:
        log("!! первые в истории: не прочитан data/feats.json:", e)
        cur = {}
    if tbls is None:
        tbls = tables(log=log)
    return {"feats": cur.get("feats") or [], "src": cur.get("src") or {}, "records": records(tbls or {})}


def _born(pr):
    who = pr.get("who") or []
    return who[0].get("born", "") if len(who) == 1 else ""


def _same_nation(a, b):
    return a == b or (a in RUS and b in RUS)


def _adult_then(born, day):
    """Взрослому рекорду не меньше 15 лет хозяина (возраст ISU для взрослых)."""
    if not born:
        return True
    try:
        b = dt.date.fromisoformat(born)
        return dt.date.fromisoformat(day) >= b.replace(year=b.year + 15)
    except ValueError:
        return False


def _pb_allows(pr, s, pts):
    """Личный рекорд ниже мирового, который ему приписан, — значит, строка не его."""
    want = PB_SEG[s]
    for p in pr.get("pb") or []:
        if p.get("s") == want:
            try:
                return float(p["pts"]) + 0.005 >= float(pts)
            except (TypeError, ValueError):
                return True
    return True


def owns(rec, name, nation, isu_id, pr):
    r = rec["row"]
    if isu_id and r["id"]:
        if r["id"] != isu_id:
            return False
    elif nm.key(r["n"]) != nm.key(name) or not _same_nation(r["c"], nation) or not _adult_then(_born(pr), r["d"]):
        return False
    return _pb_allows(pr, rec["s"], r["pts"])


def for_profile(name, nation, isu_id, pr, book):
    """Строки «Примечательного» для профиля: [{t, ev, d?, pts?, src, u}] по времени, от ранних к поздним."""
    out = []
    born = _born(pr)
    for f in book["feats"]:
        if nm.key(f.get("n", "")) != nm.key(name) or not born or f.get("born") != born:
            continue
        src = book["src"].get(f.get("src"), {})
        if not f.get("t") or not src.get("u"):
            continue
        x = {"t": f["t"], "ev": f.get("ev", ""), "src": src.get("n", ""), "u": src["u"]}
        if f.get("d"):
            x["d"] = f["d"]
        out.append(x)
    for rec in book["records"]:
        if owns(rec, name, nation, isu_id, pr):
            r = rec["row"]
            out.append({"t": record_title(rec), "ev": event_ru(r["ev"]), "d": r["d"], "pts": r["pts"],
                        "src": "ISU", "u": f"{STAT}phs{rec['kind']}{rec['s']}.htm"})

    def when(x):
        if x.get("d"):
            return x["d"]
        m = re.search(r"(\d{4})(?:/\d\d)?", x["ev"])
        return m.group(1) if m else "9999"

    return sorted(out, key=when)


def source_names(feats):
    return [OF.get(f["src"], f["src"]) for f in feats if f.get("src")]
