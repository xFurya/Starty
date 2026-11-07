"""Сборная в профиле: страна, состав и сезон — по официальному списку федерации.

Званий вроде МС и ЗМС у большинства стран нет; то, что есть у всех, — список сборной на сезон.
Берём только официальные списки:
- Россия — ФФККР, fsrussia.ru/sbornaya: основной и резервный составы, взрослые и юниоры. Сезон —
  самый поздний из «Списков кандидатов … на 2026-2027 гг.» на той же странице;
- Япония — JSF, skatingjapan.or.jp/figure/player/: 特別強化選手 (особый состав), 強化選手A и B.
  Имена там и иероглифами, и латиницей — берём латиницу;
- Канада — Skate Canada: сайт закрыт от сборщиков, список выверен вручную по объявлению федерации
  и лежит в data/teams.json со ссылкой (национальная сборная и резерв NextGen).

Списки сохраняются в data/teams.json; ФФККР и JSF перечитываются раз в сутки, молчат — берём
сохранённое. Сезон списка кончился (30 июня второго года) — строки нет: прошлогодний состав за
нынешний не выдаём. Пара получает строку, только если в списке оба партнёра — в одном составе
и одном виде: иначе это не та пара, что в сборной.
"""
import datetime as dt
import html
import json
import os
import re

from . import names as nm
from . import net
from .fsr import _text

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "data", "teams.json")
FFKR = "https://fsrussia.ru/sbornaya"
JSF = "https://www.skatingjapan.or.jp/figure/player/"
FRESH = dt.timedelta(hours=20)

COUNTRY = {"RUS": "Россия", "JPN": "Япония", "CAN": "Канада"}
# кто выступает за страну под другим кодом: россияне на турнирах ISU — нейтральные
SAME = {"RUS": {"RUS", "AIN", "AIN1", "AIN2", "ANA", "OAR", "FSR", "ROC"}}

_FFKR_TAB = [("parnoe", "p"), ("muzhchiny", "m"), ("yuniory", "m"), ("zhenshchiny", "w"),
             ("yuniorki", "w"), ("tantsy", "d")]
_JSF_GROUP = {"特別強化選手": "особый состав", "強化選手A": "состав A", "強化選手B": "состав B"}


def season_end(y):
    """«2026/27» → 30 июня 2027; не разобрать — None."""
    m = re.fullmatch(r"(\d{4})/(\d\d)", y or "")
    return dt.date(int(m.group(1)) + 1, 6, 30) if m else None


def _season(a, b):
    return f"{a}/{str(b)[-2:]}" if int(b) == int(a) + 1 else ""


# ---------------------------------------------------------------- ФФККР

def parse_ffkr(page):
    """{"y": "2026/27", "m": [{"n", "k", "t"}]} со страницы сборной ФФККР или None.
    Страница: разделы-аккордеоны «Мужчины, женщины. Основной состав» и т. п., в каждом вкладки
    по видам (id вкладки — «parnoe-katanie-2», «odinochnoe-katanie-yuniorki»…), в них ссылки
    на карточки с <strong>ФАМИЛИЯ<br>Имя<br>Отчество</strong>."""
    marks = []
    for m in re.finditer(r'(?s)<h2[^>]*rl_sliders-title[^>]*>(.*?)</h2>', page):
        marks.append((m.start(), "sec", _text(m.group(1))))
    for m in re.finditer(r'<div[^>]*class="tab-pane[^"]*"[^>]*\bid="([^"]+)"', page):
        kind = next((k for w, k in _FFKR_TAB if w in m.group(1)), "")
        marks.append((m.start(), "tab", kind))
    for m in re.finditer(r'(?s)<a href="/(?:sbornaya|contacts|team-profiles)/teams/[^"]+"[^>]*>\s*<strong[^>]*>(.*?)</strong>',
                         page):
        marks.append((m.start(), "who", m.group(1)))
    marks.sort(key=lambda x: x[0])
    sec, kind, out, seen = "", "", [], set()
    for _, what, v in marks:
        if what == "sec":
            sec, kind = v, ""
        elif what == "tab":
            kind = v
        else:
            low = sec.lower()
            sq = "основной состав" if "основн" in low else "резервный состав" if "резерв" in low else ""
            parts = [p for p in _text(v).split("\n") if p]
            if not sq or not kind or len(parts) < 2:
                continue
            t = ("юниорский " + sq) if "юниор" in low else sq
            n = nm.pretty_ru(f"{parts[1]} {parts[0]}")
            if (n, kind, t) not in seen:
                seen.add((n, kind, t))
                out.append({"n": n, "k": kind, "t": t})
    years = [_season(a, b) for a, b in re.findall(r"на\s+(20\d\d)\s*[-–]\s*(20\d\d)\s*гг", _text(page))]
    years = sorted(y for y in years if y)
    if not out or not years:
        return None
    return {"y": years[-1], "m": out}


# ---------------------------------------------------------------- JSF

def parse_jsf(page):
    """{"y": "2026/27", "m": [{"n", "k", "t"}]} со страницы 強化選手 JSF или None.
    Разделы — <h2 class="c-secTtl05">特別強化選手 / 強化選手A / ペア特別強化選手 / アイスダンス強化選手B…,
    в одиночных — подзаголовки MEN и WOMEN; имя латиницей — <small>SATO Shun</small>."""
    y = re.search(r"(20\d\d)\s*/\s*(20\d\d)\s*シーズン", page)
    year = _season(*y.groups()) if y else ""
    marks = [(m.start(), "sec", html.unescape(m.group(1)).strip())
             for m in re.finditer(r'(?s)<h2[^>]*c-secTtl05[^>]*>(.*?)</h2>', page)]
    marks += [(m.start(), "sub", m.group(1).strip().upper())
              for m in re.finditer(r'(?s)class="c-palyeyList_item_ttl"[^>]*>(.*?)<', page)]
    marks += [(m.start(), "who", html.unescape(m.group(1)).strip())
              for m in re.finditer(r'(?s)class="c-palyeyList_item_name2".*?<small>(.*?)</small>', page)]
    marks.sort(key=lambda x: x[0])
    sec, sub, out = "", "", []
    for _, what, v in marks:
        if what == "sec":
            sec, sub = re.sub(r"\s+", "", v), ""
        elif what == "sub":
            sub = v
        else:
            if sec.startswith("ペア"):
                kind, grp = "p", sec[2:]
            elif sec.startswith("アイスダンス"):
                kind, grp = "d", sec[6:]
            else:
                kind, grp = {"MEN": "m", "WOMEN": "w"}.get(sub, ""), sec
            t = _JSF_GROUP.get(grp.replace("Ａ", "A").replace("Ｂ", "B"))
            w = v.split()
            if not kind or not t or len(w) < 2 or not re.fullmatch(r"[A-Za-z' -]+", v):
                continue  # синхронное катание, незнакомый раздел, имя без латиницы — мимо
            # «KATAISE Takeru Amine»: фамилия — заглавными, впереди
            n = " ".join(x.capitalize() for x in w[1:]) + " " + w[0].capitalize()
            out.append({"n": n, "k": kind, "t": t})
    if not out or not year:
        return None
    return {"y": year, "m": out}


# ---------------------------------------------------------------- хранение

AUTO = {"RUS": (FFKR, parse_ffkr, "ФФККР"), "JPN": (JSF, parse_jsf, "федерации Японии")}


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _write(path, d):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lists = d.get("lists") or {}
    with open(path, "w", encoding="utf-8") as f:
        f.write("{\"_\":" + json.dumps(d.get("_", ""), ensure_ascii=False) + ",\n\"at\":" + json.dumps(d.get("at", "")) +
                ",\n\"lists\":{\n")
        chunks = []
        for c in sorted(lists):
            lst = lists[c]
            head = {k: v for k, v in lst.items() if k != "m"}
            chunks.append(json.dumps(c) + ":{" + json.dumps(head, ensure_ascii=False, sort_keys=True)[1:-1] +
                          ",\"m\":[\n" + ",\n".join(json.dumps(m, ensure_ascii=False, sort_keys=True)
                                                    for m in lst.get("m") or []) + "]}")
        f.write(",\n".join(chunks))
        f.write("\n}}\n")


def load(now=None, path=PATH, fetch=None, log=print):
    """{страна: {"src", "u", "y", "m": [{"n", "k", "t"}]}}: свежие списки ФФККР и JSF или сохранённые,
    плюс выверенные вручную (Канада)."""
    now = now or dt.datetime.now(dt.timezone.utc)
    fetch = fetch or (lambda url: net.fetch(url, timeout=40))
    d = _read(path)
    lists = d.get("lists") or {}
    try:
        fresh = now - dt.datetime.fromisoformat(d["at"]) < FRESH
    except (KeyError, TypeError, ValueError):
        fresh = False
    if fresh and all(c in lists for c in AUTO):
        return lists
    answered = 0
    for c, (url, parse, src) in AUTO.items():
        try:
            got = parse(fetch(url))
        except net.FetchError as e:
            log(f"  сборная {c}: источник не ответил ({e})")
            continue
        answered += 1
        if not got:  # вёрстка поменялась — это не «сборной нет»: держим прежний список
            log(f"  ! сборная {c}: список не разобран, оставляю сохранённый")
            continue
        lists[c] = {"src": src, "u": url, "y": got["y"], "m": got["m"]}
    if answered:
        d["lists"], d["at"] = lists, now.isoformat()
        _write(path, d)
    log("  сборные: " + ", ".join(f"{c} {lists[c].get('y', '?')} — {len(lists[c].get('m') or [])}" for c in sorted(lists)))
    return lists


# ---------------------------------------------------------------- к профилю

def _country(nation, lists):
    for c in lists:
        if nation == c or nation in SAME.get(c, ()):
            return c
    return None


def for_profile(name, nation, kind, lists, today, aliases=None):
    """{"c": "Россия", "t": "основной состав", "y": "2026/27"} или None, и имя источника.
    name — как в приложении (пара — «A / B»), kind — вид из справочника (m/w/p/d, заглавная — юниоры)."""
    c = _country(nation, lists or {})
    if not c:
        return None, ""
    lst = lists[c]
    end = season_end(lst.get("y", ""))
    if not end or today > end:
        return None, ""
    aliases = aliases or {}
    k = (kind or "").lower()
    by_key = {}
    for m in lst.get("m") or []:
        if not k or not m.get("k") or m["k"] == k:
            by_key.setdefault(nm.key(aliases.get(m["n"], m["n"])), []).append(m)
    found = set()
    for p in [x.strip() for x in name.split(" / ")]:
        hits = by_key.get(nm.key(aliases.get(p, p)), [])
        if len({h["t"] for h in hits}) != 1:
            return None, ""  # нет в списке или тёзки в разных составах — не гадаем
        found.add(hits[0]["t"])
    if len(found) != 1:
        return None, ""  # партнёры в разных составах — это не одна пара сборной
    return {"c": COUNTRY.get(c, c), "t": found.pop(), "y": lst["y"]}, lst.get("src", "")
