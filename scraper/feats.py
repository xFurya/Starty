"""«Примечательное» в профиле спортсмена.

Два источника, оба — из данных, а не из списка, составленного руками:
- мировые рекорды — таблицы ISU «Progression of Highest Scores» (isujsstat/phs*.htm). Верхняя строка —
  действующий рекорд, строка ниже — прежний, побитый тем, что над ним. Хозяин строки опознаётся по
  номеру биографии ISU в ссылке; если у профиля номера нет — по имени, стране и возрасту (взрослый
  рекорд в 14 лет — значит, это тёзка);
- архив протоколов (scraper/archive.py): самый дорогой прыжковый элемент и больше всех четверных
  с 2018 года, редкие элементы, единогласные +5 и десятки — у каждого, кто есть в протоколах.

Места в списках ISU — той же статистики: личные рекорды всех времён (pbs*.htm, с сезона 2018/19;
берём места 2–10, первое — это и есть мировой рекорд) и лучшие результаты сезона (sbYYYY-YY/sbts*.htm,
места 1–3). В обоих списках спортсмен стоит один раз, со своим лучшим результатом: место в списке —
это место его личного рекорда среди чужих, а не «N-й результат в истории».

Таблицы сохраняются в data/records.json и перечитываются раз в сутки; ISU не ответила — берём
сохранённые. Нет ни того, ни другого — рекордов в профиле нет (а не выдуманных).
"""
import datetime as dt
import html
import json
import os
import re

from . import archive as ar
from . import names as nm
from . import net
from .profiles import event_ru

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "data", "records.json")
STAT = "https://www.isuresults.com/isujsstat/"
FRESH = dt.timedelta(hours=20)

# таблица → (вид, отрезок); танцы — свои отрезки
TABLES = [(k, s) for k in "mwp" for s in ("sp", "fs", "to")] + [("d", s) for s in ("rd", "fd", "to")]
PB_ROWS = 10  # личные рекорды: сколько первых мест хранить
SB_ROWS = 3   # лучшие результаты сезона: сколько первых мест хранить
ORD = {1: "Лучший", 2: "Второй", 3: "Третий", 4: "Четвёртый", 5: "Пятый", 6: "Шестой", 7: "Седьмой",
       8: "Восьмой", 9: "Девятый", 10: "Десятый"}
PLACE = {2: "Второе", 3: "Третье"}
# порядок строк одной группы: сумма, короткая, произвольная
SEG_ORDER = {"to": 0, "sp": 1, "rd": 1, "fs": 2, "fd": 2}
SEG_RU = {"sp": "в короткой программе", "fs": "в произвольной программе", "rd": "в ритм-танце",
          "fd": "в произвольном танце", "to": "по сумме баллов"}
PB_SEG = {"sp": "sp", "rd": "sp", "fs": "fs", "fd": "fs", "to": "total"}
RUS = {"RUS", "AIN", "AIN1", "AIN2", "ANA", "OAR", "FSR", "ROC"}
# имя источника в строке «По данным …»: ISU и федерации — как есть, протокол другого турнира — общим словом
OWN = {"ISU", "ФФККР", "ФФКМ"}
OTHER = "протоколов турниров"


# ---------------------------------------------------------------- таблицы ISU

def parse(page):
    """Строки таблицы по порядку мест: [{r, id, n, c, ev, d, pts, l}]. r — место, id — номер биографии ISU из ссылки."""
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
        rows.append({"r": int(cells[0]), "id": m.group(1) if m else "", "n": cells[1], "c": cells[2], "ev": cells[3],
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


def _season_of(season_start):
    """«2026-07-01» → «2026/27»; нет даты — пусто."""
    try:
        y = int(season_start[:4])
    except (TypeError, ValueError):
        return ""
    return f"{y}/{(y + 1) % 100:02d}"


def tables(now=None, path=CACHE, fetch=None, log=print, season_start=None):
    """{"msp": [...], "pb:mto": [...], "sb:mto": [...], …}: свежие таблицы ISU или сохранённые, если ISU
    не ответила. Рекорды (ключи без «:») — целиком; личные рекорды (pb:) — первые PB_ROWS мест; лучшие
    результаты сезона season_start (sb:) — первые SB_ROWS, без season_start их не тянем. Сезон sb-таблиц
    лежит под ключом «season:» (например «2026/27»); при смене сезона прежние sb-таблицы выбрасываются."""
    now = now or dt.datetime.now(dt.timezone.utc)
    fetch = fetch or (lambda url: net.fetch(url, timeout=40))
    cache = _load_cache(path)
    have = dict(cache.get("tables") or {})
    season = _season_of(season_start)
    folder = "sb" + season.replace("/", "-")
    old_season = cache.get("season") or ""
    if season and old_season != season:  # новый сезон: прошлогодние лучшие результаты не годятся
        have = {k: v for k, v in have.items() if not k.startswith("sb:")}
    want = [(k + s, f"phs{k}{s}.htm", 0) for k, s in TABLES]
    want += [("pb:" + k + s, f"pbs{k}{s}.htm", PB_ROWS) for k, s in TABLES]
    if season:
        want += [("sb:" + k + s, f"{folder}/sbts{k}{s}.htm", SB_ROWS) for k, s in TABLES]
    try:
        fresh = now - dt.datetime.fromisoformat(cache["at"]) < FRESH
    except (KeyError, TypeError, ValueError):
        fresh = False
    if fresh and all(key in have for key, _, _ in want):
        return _with_season(have, season or old_season)
    got, failed = dict(have), 0
    for key, page, cut in want:
        try:
            rows = parse(fetch(STAT + page))
        except net.FetchError as e:
            failed += 1
            log(f"  рекорды ISU: {page} не ответила ({e})")
            continue
        if rows:  # пустая страница — сбой вёрстки, а не «рекордов нет»: держим прежнее
            got[key] = rows[:cut] if cut else rows
    if failed < len(want):  # хоть что-то ответило — отметка свежести; всё молчит — спросим в следующий раз
        keep = season or old_season
        with open(path, "w", encoding="utf-8") as f:
            f.write("{\"at\":" + json.dumps(now.isoformat()) + ",\"season\":" + json.dumps(keep) + ",\"tables\":{\n")
            f.write(",\n".join(json.dumps(k, ensure_ascii=False) + ":[\n" +
                               ",\n".join(json.dumps(r, ensure_ascii=False, sort_keys=True) for r in got[k]) + "]"
                               for k in sorted(got)))
            f.write("\n}}\n")
    return _with_season(got, season or old_season)


def _with_season(tbls, season):
    """Таблицы и под ключом «season:» сезон sb-таблиц (если они есть)."""
    out = dict(tbls)
    if season and any(k.startswith("sb:") for k in out):
        out["season:"] = season
    return out


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
        if ":" in code:  # pb:, sb:, season: — не таблицы рекордов
            continue
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

def load(tbls=None, arc=None, log=print, season_start=None):
    """Всё, что нужно write(): {"records": [...], "archive": archive.Index, "pb": {код: строки},
    "sb": {код: строки}, "season"}. arc — уже сводный архив (archive.combined); без него — сводный из
    файлов. Лучшие результаты сезона (sb) — только если задан season_start."""
    if tbls is None:
        tbls = tables(log=log, season_start=season_start)
    if arc is None:
        arc = ar.combined()
    tbls = tbls or {}
    pb = {k[3:]: v for k, v in tbls.items() if k.startswith("pb:")}
    sb = {k[3:]: v for k, v in tbls.items() if k.startswith("sb:")} if season_start else {}
    return {"records": records(tbls), "archive": ar.Index(arc), "pb": pb, "sb": sb,
            "season": tbls.get("season:") or _season_of(season_start) if sb else ""}


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


def _match(r, name, nation, isu_id):
    """Строка таблицы его? "id" — по номеру биографии ISU (есть и у профиля, и у строки), "name" — по имени
    и стране, иначе пусто."""
    if isu_id and r["id"]:
        return "id" if r["id"] == isu_id else ""
    return "name" if nm.key(r["n"]) == nm.key(name) and _same_nation(r["c"], nation) else ""


def owns(rec, name, nation, isu_id, pr):
    r = rec["row"]
    how = _match(r, name, nation, isu_id)
    if not how or (how == "name" and not _adult_then(_born(pr), r["d"])):
        return False
    return _pb_allows(pr, rec["s"], r["pts"])


def for_profile(name, nation, isu_id, pr, book):
    """Строки «Примечательного» для профиля: [{t, ev, d, pts?, src, u}]. Сначала мировые рекорды, за ними
    места в личных рекордах мира и лучшие результаты сезона, потом рекорды архива, редкие элементы,
    четверные, +5 и десятки; внутри группы — сумма, короткая, произвольная, затем от ранних к поздним."""
    out, owned = [], set()
    for rec in book.get("records") or []:
        if owns(rec, name, nation, isu_id, pr):
            r = rec["row"]
            owned.add((rec["s"], float(r["pts"])))
            out.append({"t": record_title(rec), "ev": event_ru(r["ev"]), "d": r["d"], "pts": r["pts"],
                        "src": "ISU", "u": f"{STAT}phs{rec['kind']}{rec['s']}.htm", "g": 0, "o": 0})
    season = (book.get("season") or "").replace("/", "-")
    for field, g, places, page in (("pb", 0.5, range(2, 11), lambda k, s: f"{STAT}pbs{k}{s}.htm"),
                                   ("sb", 0.7, range(1, 4), lambda k, s: f"{STAT}sb{season}/sbts{k}{s}.htm")):
        for code, rows in (book.get(field) or {}).items():
            k, s = code[0], code[1:]
            if s not in SEG_RU or (field == "sb" and not season):
                continue
            for r in rows:
                if r.get("r") not in places or not _match(r, name, nation, isu_id):
                    continue
                if field == "pb" and (s, float(r["pts"])) in owned:  # это и есть его мировой рекорд
                    continue
                # списки ISU — по одной строке на спортсмена (его лучший результат), поэтому место в них —
                # место личного рекорда, а не «N-й результат в истории»: у лидера выше может быть несколько
                if field == "pb":
                    t = f"{ORD[r['r']]} личный рекорд в мире {ar.SINCE} {SEG_RU[s]}"
                elif r["r"] == 1:
                    t = f"Лучший результат сезона в мире {SEG_RU[s]}"
                else:
                    t = f"{PLACE[r['r']]} место в мире в сезоне {SEG_RU[s]}"
                out.append({"t": t, "ev": event_ru(r["ev"]), "d": r["d"], "pts": r["pts"], "src": "ISU",
                            "u": page(k, s), "g": g, "o": SEG_ORDER[s]})
    out += [dict(x, o=0) for x in ar.for_profile(name, nation, book.get("archive"))]
    out.sort(key=lambda x: (x["g"], x["o"], x.get("d", "")))
    for x in out:
        del x["g"], x["o"]
    return out


def source_names(feats):
    return [f["src"] if f["src"] in OWN else OTHER for f in feats if f.get("src")]
