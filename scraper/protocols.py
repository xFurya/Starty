"""Протокол турнира: состояние сегментов, строки, детали оценок и файл site/data/protocols/<slug>.json.

Один расчёт для build.py (полный сбор) и live.py (каждые 10 минут, бюджет запросов).

Окончательность (ПРОЕКТ.md, решение владельца): сегмент окончательный, когда табло выложило
судейские оценки этого сегмента и они подтверждены (заголовок PDF совпал с категорией и
сегментом; JudgesDetails подтверждены без проверки). Без оценок сегмент промежуточный. Режим
«окончательный по времени» — флаг final_by_time, по умолчанию выключен.

Строки сегмента: со страницы табло (таблица результатов). Если страница стартового листа
или пустая, а оценки подтверждены (ФФКМ, одиночки), строки берутся из PDF оценок — но только
если они сходятся с табло: со стартовым листом страницы (номера и имена) или с колонкой сегмента
в итоге вида (место). Не сошлись — строк нет, причина в reason.

Файл (v=1, UTF-8, без отступов, ключи по алфавиту; подробно — protocol-design.md §2):
  {v, tid, tournament, src, built, marks, categories: [{kind, level, name, segments, total}]}
  Сегмент: {code, name, start, end, page, judges, table, state, basis, skipped, rows, panel?}
    judges — адрес PDF судейских оценок или null; panel — бригада [{no: "J1", name, nation}],
    если на табло есть страница судей (SEGnnnOF).
  Строка: {i, place, status, no (стартовый номер), name, nation, points} — points, tes, pcs, ded —
    строки «NN.NN», как на табло (ded — модуль снижения). Необязательные (нет в источнике —
    поля нет, а не 0), числами: bv — сумма баз;
    els — [{no, n, info?, b, x?, g, j, s}]: n — код элемента как в протоколе; info — отметки как
      в протоколе (<, <<, q, e, !, *, F) строкой; x — бонус второй половины; g — GOE в баллах;
      j — оценки судей J1…Jn (пропуск — null); s — оценка элемента;
    comp — [{n, f, j, s}]: Композиция / Представление / Техника катания (старая система:
      Скольжение, Связующие элементы, Исполнение, Хореография, Интерпретация);
    deds — [{n, v}]: сбавки по-русски, v отрицательное.
  els, comp, deds, bv — из PDF оценок (JudgesDetails или *_Scores.pdf). Строка PDF не
  сопоставилась со строкой табло — у этого спортсмена их нет, причина в журнале.
  Итог вида: {state, complete, cols, colsKind, rows (строки с parts), skipped} или null.
Состояние чтения табло — status.json рядом: {v, generated, items: {tid: {checked, read_ok, error}}}.
"""
import json
import math
import os
import re

from . import net
from . import swisstiming as st

STATUS_FILE = "status.json"
SEG_STATES = ("scheduled", "not_published", "in_progress", "provisional", "final", "judges_mismatch", "format")
TOTAL_STATES = ("final", "provisional", "not_published", "format")
TABLES = ("results", "judges_pdf", "starting", "empty", "format")
COLS_KINDS = ("places", "points", "unknown")
# Размер: с деталями оценок около 1 КБ на строку без сжатия (0.2 КБ в gzip, Pages сжимает);
# турнир с 8 сегментами — 150–250 КБ. Предел 150 КБ из первого проекта рассчитан без деталей.
MAX_CATEGORIES, MAX_SEGMENTS, MAX_ROWS, MAX_NAME, MAX_BYTES = 12, 8, 200, 200, 512 * 1024


def key(name):
    """Имя для сравнения: регистр, «ё» как «е», пробелы; без отчества — имя и фамилия каждого
    из пары. Табло ФФКМ пишет «Лев Дмитриевич ЛАЗАРЕВ», а PDF того же турнира — «Лев ЛАЗАРЕВ»."""
    parts = []
    for one in name.lower().replace("ё", "е").split("/"):
        words = one.split()
        parts.append(" ".join([words[0], words[-1]] if len(words) > 1 else words))
    return " / ".join(parts)


def slug(tid):
    """Имя файла турнира без расширения: tid, где «:» заменено на «_» (как у site/e/*.ics)."""
    return tid.replace(":", "_")


def proto_name(tid):
    return slug(tid) + ".json"


def segment_state(now, start, end, table, has_rows, marks, judges, final_by_time):
    """(state, basis) сегмента. now, start, end — aware datetime (start и end могут быть None).

    table — вид строк страницы (format — таблица не распознана). marks — есть ли на табло хоть
    одна ссылка на судейские оценки. judges — None (у сегмента нет ссылки), ok, mismatch
    (PDF не того сегмента), unread (PDF не прочитан). basis — judges или time, только у final."""
    if start is not None and now < start:
        return "scheduled", None
    if table == "format":
        return "format", None
    if judges == "mismatch":
        return "judges_mismatch", None
    if not has_rows:
        return ("format", None) if judges == "ok" else ("not_published", None)
    if judges == "ok":
        return "final", "judges"
    if end is not None and now < end:
        return "in_progress", None
    if final_by_time and not marks:
        return "final", "time"
    return "provisional", None


class Skipped(net.FetchError):
    """Запрос не сделан: бюджет прогона исчерпан. Не ошибка табло."""

    def __init__(self, url):
        super().__init__(f"{url}: бюджет запросов прогона исчерпан", kind="budget")


class Fetcher:
    """Страницы и PDF табло на один прогон: кэш (адрес — один запрос, ошибка тоже запоминается)
    и бюджет запросов (None — без лимита). skipped — адреса, на которые бюджета не хватило."""

    def __init__(self, budget=None, timeout=30, tries=3):
        self.budget, self.timeout, self.tries = budget, timeout, tries
        self.pages, self.pdfs = {}, {}
        self.requests = 0
        self.skipped = []
        self.errors = []  # [(адрес, kind)]

    def _take(self, url):
        if self.budget is not None and self.requests >= self.budget:
            self.skipped.append(url)
            return False
        self.requests += 1
        return True

    def page(self, url):
        if url in self.pages:
            got = self.pages[url]
            if isinstance(got, Exception):
                raise got
            return got
        if not self._take(url):
            raise Skipped(url)
        try:
            text = net.fetch(url, timeout=self.timeout, tries=self.tries)
        except net.FetchError as e:
            self.pages[url] = e
            self.errors.append((url, e.kind))
            raise
        self.pages[url] = text
        return text

    def pdf_text(self, url):
        """Текст PDF или None (сеть, не PDF, pdftotext, бюджет). Сбой здесь — «не прочитано»."""
        if url in self.pdfs:
            return self.pdfs[url]
        if not self._take(url):
            return None
        try:
            self.pdfs[url] = net.pdf_text(url, timeout=max(self.timeout, 15), tries=self.tries)
        except Exception as e:
            self.pdfs[url] = None
            self.errors.append((url, getattr(e, "kind", "format")))
        return self.pdfs[url]


def judges_state(seg, category, segment, fetcher):
    """Состояние оценок сегмента: None (ссылки нет), ok, mismatch или unread."""
    if seg.get("judges_pdf"):
        return "ok"
    url = seg.get("scores_pdf")
    if not url:
        return None
    text = fetcher.pdf_text(url)
    if text is None:
        return "unread"
    return "ok" if st.judges_header_ok(text, category, segment) else "mismatch"


def pdf_check(rows, starting, total_col):
    """Строки PDF оценок сходятся с табло: (ok, причина). Проверка по любому из источников,
    который есть: starting — стартовый лист страницы [{no, name}], total_col — {имя: место}
    колонки сегмента в итоге вида. Совпадения нет ни с одним — не сходится."""
    if not rows:
        return False, "empty"
    checked = 0
    if starting:
        want = {(r["no"], key(r["name"])) for r in starting if r.get("no")}
        got = {(r["no"], key(r["name"])) for r in rows}
        if want != got:
            return False, "start_list"
        checked += 1
    if total_col:
        for r in rows:
            v = total_col.get(key(r["name"]))
            if v is None:
                continue
            if v != str(r["place"]):
                return False, "total"
            checked += 1
    if not checked:
        return False, "unverified"
    return True, None


def total_column(cat_text, code):
    """{имя: место} колонки сегмента (КП, ПП) в итоге вида; None, если колонки нет."""
    total = st.parse_category_protocol(cat_text)
    if code not in total["cols"]:
        return None
    j = total["cols"].index(code)
    return {key(r["name"]): r["parts"][j] for r in total["rows"] if r["parts"][j]}


def segment_view(*, seg, category, code, page, cat_url, now, start, end, marks, fetcher,
                 final_by_time, podium_from_pdf):
    """Сегмент для события: {state, basis, table, rows, results, judges, reason, skipped}.

    seg — сегмент из parse_index_page; page — текст страницы сегмента (None — не скачана);
    cat_url — итог вида, если это последний сегмент категории (для сверки), иначе None;
    fetcher — загрузка PDF и итога на прогон. results — строки для мест и тройки в формате
    parse_segment_results (place, name, nation, points), либо None. Тройку берём из строк PDF
    только при podium_from_pdf и подтверждённых строках."""
    proto = st.parse_segment_protocol(page) if page is not None else \
        {"table": "empty", "rows": [], "skipped": 0, "reasons": []}
    table, rows = proto["table"], proto["rows"]
    results = st.parse_segment_results(page) if page is not None and table == "results" else None
    reason = None
    started = start is None or now >= start
    judges = None
    if started and (seg.get("judges_pdf") or seg.get("scores_pdf")):
        judges = judges_state(seg, category, seg["name"], fetcher)
    if judges == "ok" and not seg.get("judges_pdf") and table in ("starting", "empty"):
        # строки PDF оценок (ФФКМ, одиночки): страница стартового листа или пустая
        pdf_rows = st.parse_judges_pdf(fetcher.pdf_text(seg["scores_pdf"]))
        starting = st.parse_starting_order(seg["url"], page) if page is not None else []
        total_col = None
        if cat_url:
            try:
                total_col = total_column(fetcher.page(cat_url), code)
            except net.FetchError:
                total_col = None
        ok, why = pdf_check(pdf_rows, starting, total_col)
        if ok:
            rows, table = pdf_rows, "judges_pdf"
            if podium_from_pdf:
                results = [{"place": r["place"], "name": r["name"], "nation": "", "points": r["points"]}
                           for r in sorted(pdf_rows, key=lambda r: r["place"])]
        else:
            rows, reason = [], f"pdf_{why}"
    state, basis = segment_state(now, start, end, table, bool(rows), marks, judges, final_by_time)
    return {"state": state, "basis": basis, "table": table, "rows": rows, "results": results,
            "judges": judges, "reason": reason, "skipped": proto["skipped"]}


# ---------------------------------------------------------------- файл протокола

def _iso(t):
    return t.isoformat() if t is not None else None


def _num(v):
    if v is None or v == "":
        return None
    try:
        return round(float(str(v).replace(",", ".")), 2)
    except ValueError:
        return None


def details_for(seg, view, fetcher):
    """Детали оценок (parse_judges_details) из PDF сегмента, если оценки подтверждены; иначе None."""
    if view["judges"] != "ok" or not view["rows"]:
        return None
    url = seg.get("judges_pdf") or seg.get("scores_pdf")
    text = fetcher.pdf_text(url) if url else None
    if not text:
        return None
    return st.parse_judges_details(text)


def _detail_of(row, details):
    """Детали спортсмена: совпадают место и имя (и стартовый номер, если он есть с обеих сторон)."""
    for d in details:
        if d["place"] == row.get("place") and key(d["name"]) == key(row["name"]):
            if row.get("no") is None or d["no"] == row.get("no"):
                return d
    return None


def segment_record(*, seg, code, start, end, view, name_of, details=None, officials=None, log=None):
    """Сегмент для файла. name_of(имя с табло) → имя как в приложении (fix и to_ru сборщика).
    details — parse_judges_details этого сегмента; officials — parse_officials. Строка табло
    без пары в PDF остаётся без els/comp/deds, причина — в log."""
    rows = []
    for r in view["rows"]:
        out = {"i": r["i"], "place": r.get("place"), "status": r.get("status"), "no": r.get("no"),
               "name": name_of(r["name"]), "nation": r.get("nation") or "", "points": r.get("points")}
        for k in ("tes", "pcs", "ded"):  # строки NN.NN, как на табло (снижение — модуль)
            if r.get(k) is not None:
                out[k] = r[k]
        if details is not None and (r.get("place") is not None):
            d = _detail_of(r, details)
            if d is None:
                if log:
                    log("  ! строка протокола без пары в PDF оценок:", seg["url"], r["place"], r["name"])
            else:
                out.update({"bv": d["bv"], "els": d["els"], "comp": d["comp"]})
                for k in ("tes", "pcs", "ded"):  # колонки нет на табло — берём из PDF той же строкой
                    out.setdefault(k, f"{abs(d[k]):.2f}")
                if d["deds"]:
                    out["deds"] = d["deds"]
        rows.append(out)
    rec = {"code": code, "name": seg["name"], "start": _iso(start), "end": _iso(end), "page": seg["url"],
           "judges": seg.get("judges_pdf") or seg.get("scores_pdf"), "table": view["table"],
           "state": view["state"], "basis": view["basis"], "skipped": view["skipped"], "rows": rows}
    if officials:
        rec["panel"] = officials
    return rec


def make_segment(*, seg, code, start, end, view, name_of, fetcher, prev=None, log=None):
    """Сегмент для файла с бригадой и деталями оценок (один расчёт для build и live). Бригаду
    берём из прежнего файла, если она там есть: страницу судей второй раз не запрашиваем."""
    officials = (prev or {}).get("panel")
    if officials is None and view["rows"] and seg.get("officials"):
        try:
            officials = st.parse_officials(fetcher.page(seg["officials"])) or None
        except net.FetchError:
            officials = None
    return segment_record(seg=seg, code=code, start=start, end=end, view=view, name_of=name_of,
                          details=details_for(seg, view, fetcher), officials=officials, log=log)


# подписи колонок итога: в файл пишем русские (КП, ПП, РТ, ПТ), латиница из протокола переводится
TOTAL_COLS = {"SP": "КП", "FS": "ПП", "FD": "ПТ", "RD": "РТ", "PT": "РТ"}


def total_col_name(code):
    """Русская подпись колонки итога; неизвестную оставляем как в протоколе."""
    return TOTAL_COLS.get(re.sub(r"\s+", "", code or "").upper(), code)


def total_record(text, last_final, name_of):
    """Итог вида для файла по странице CATnnnRS.htm."""
    t = st.parse_category_protocol(text)
    rows = []
    for r in t["rows"]:
        rows.append({"i": r["i"], "place": r["place"], "status": r["status"], "no": r["no"],
                     "name": name_of(r["name"]), "nation": r["nation"] or "", "points": r["points"],
                     "parts": r["parts"]})
    if t["table"] == "format":
        state = "format"
    elif t["table"] != "results" or not rows:
        state = "not_published"
    else:
        state = "final" if t["complete"] and last_final else "provisional"
    return {"state": state, "complete": t["complete"], "cols": [total_col_name(c) for c in t["cols"]],
            "colsKind": t["colsKind"], "rows": rows, "skipped": t["skipped"]}


def category_record(kind, level, name, segments, total):
    return {"kind": kind, "level": level, "name": name, "segments": segments, "total": total}


def make_doc(*, tid, tournament, src, marks, categories, now):
    return {"v": 1, "tid": tid, "tournament": tournament, "src": src, "built": now.isoformat(),
            "marks": bool(marks), "categories": categories}


def guard(new, prev):
    """Защита от регресса сегмента: (сегмент, причина или None).
    Окончательный не откатывается, пока ссылка на оценки на месте (сеть, PDF не прочитан); если
    у окончательного строк стало меньше половины — берём прежний; пустая страница при прежних
    строках строк не стирает."""
    if prev is None:
        return new, None
    if prev["state"] == "final" and new["state"] != "final":
        if new.get("judges"):
            return prev, "final_kept"
        return new, "judges_vanished"
    if prev["state"] == "final" and len(prev["rows"]) >= 2 and len(new["rows"]) * 2 < len(prev["rows"]):
        return prev, "rows_dropped"
    if new["table"] in ("starting", "empty") and not new["rows"] and prev["rows"]:
        return prev, "rows_lost"
    return new, None


def find_segment(doc, category, code):
    for c in (doc or {}).get("categories", []):
        if c["name"] == category:
            for sg in c["segments"]:
                if sg["code"] == code:
                    return sg
    return None


def find_total(doc, category):
    for c in (doc or {}).get("categories", []):
        if c["name"] == category:
            return c.get("total")
    return None


def merge_prev(doc, prev):
    """Защита от регресса по всему файлу: сегменты (guard) и итоги. Возвращает причины для журнала."""
    notes = []
    if prev is None:
        return notes
    for c in doc["categories"]:
        for k, sg in enumerate(c["segments"]):
            kept, why = guard(sg, find_segment(prev, c["name"], sg["code"]))
            if why:
                notes.append(f"{c['name']} {sg['code']}: {why}")
                c["segments"][k] = kept
        have = {sg["code"] for sg in c["segments"]}
        prev_cat = next((pc for pc in prev.get("categories", []) if pc["name"] == c["name"]), None)
        for sg in (prev_cat or {}).get("segments", []):
            if sg["code"] not in have:  # в этом сборе страница сегмента не прочиталась
                c["segments"].append(sg)
                notes.append(f"{c['name']} {sg['code']}: kept_missing")
        c["segments"].sort(key=lambda sg: _SEG_ORDER.get(sg["code"], 9))
        old = find_total(prev, c["name"])
        if old and old["state"] == "final" and (c["total"] is None or c["total"]["state"] != "final"):
            c["total"] = old
            notes.append(f"{c['name']} итог: final_kept")
        elif old and c["total"] is None:
            c["total"] = old
            notes.append(f"{c['name']} итог: kept")
    names = {c["name"] for c in doc["categories"]}
    for pc in prev.get("categories", []):
        if pc["name"] not in names:
            doc["categories"].append(pc)
            notes.append(f"{pc['name']}: kept_missing")
    return notes


_SEG_ORDER = {"КП": 0, "РТ": 0, "ПП": 1, "ПТ": 1}


# ---------------------------------------------------------------- проверка и запись

POINTS_RE = re.compile(r"^\d{1,3}\.\d{2}$")


def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _check_row(r, where, errs, parts_len=None):
    if not isinstance(r.get("name"), str) or not r["name"] or len(r["name"]) > MAX_NAME:
        errs.append(f"{where}: имя")
    p = r.get("place")
    if p is not None and not (isinstance(p, int) and 1 <= p <= 999):
        errs.append(f"{where}: место {p!r}")
    if r.get("points") is not None and not (isinstance(r["points"], str) and POINTS_RE.match(r["points"])):
        errs.append(f"{where}: баллы {r['points']!r}")
    if r.get("status") is not None and not re.fullmatch(r"[A-Za-z]{2,4}", str(r["status"])):
        errs.append(f"{where}: статус")
    for k in ("tes", "pcs", "ded"):
        if r.get(k) is not None and not (isinstance(r[k], str) and re.match(r"^-?\d{1,3}\.\d{2}$", r[k])):
            errs.append(f"{where}: {k}")
    if "bv" in r and not _is_num(r["bv"]):
        errs.append(f"{where}: bv")
    for d in r.get("deds", []):
        if not isinstance(d.get("n"), str) or not _is_num(d.get("v")) or d["v"] > 0:
            errs.append(f"{where}: сбавка")
            break
    for e in r.get("els", []):
        if not isinstance(e.get("n"), str) or not all(_is_num(e.get(k)) for k in ("b", "g", "s")) \
                or not all(j is None or _is_num(j) for j in e.get("j", [])):
            errs.append(f"{where}: элемент")
            break
    for c in r.get("comp", []):
        if not isinstance(c.get("n"), str) or not all(_is_num(c.get(k)) for k in ("f", "s")):
            errs.append(f"{where}: компонент")
            break
    if parts_len is not None and (not isinstance(r.get("parts"), list) or len(r["parts"]) != parts_len):
        errs.append(f"{where}: parts")


def validate(doc, final_by_time=False):
    """Ошибки файла протокола (protocol-design.md §2.7). Пустой список — файл годен."""
    errs = []
    if doc.get("v") != 1:
        errs.append("v")
    for k in ("tid", "tournament", "src", "built"):
        if not isinstance(doc.get(k), str) or not doc[k]:
            errs.append(f"нет {k}")
    if isinstance(doc.get("src"), str) and not re.match(r"https?://", doc["src"]):
        errs.append("src не http")
    cats = doc.get("categories")
    if not isinstance(cats, list) or len(cats) > MAX_CATEGORIES:
        return errs + ["categories"]
    for c in cats:
        cn = c.get("name", "?")
        if not isinstance(cn, str) or len(cn) > MAX_NAME:
            errs.append("имя категории")
        segs = c.get("segments") or []
        if len(segs) > MAX_SEGMENTS:
            errs.append(f"{cn}: сегментов {len(segs)}")
        for sg in segs:
            where = f"{cn} {sg.get('code')}"
            if sg.get("state") not in SEG_STATES or sg.get("table") not in TABLES:
                errs.append(f"{where}: state/table")
            basis = sg.get("basis")
            if basis not in (None, "judges", "time") or (basis == "time" and not final_by_time):
                errs.append(f"{where}: basis")
            if sg.get("state") == "final" and basis is None:
                errs.append(f"{where}: final без basis")
            if not isinstance(sg.get("skipped"), int) or sg["skipped"] < 0:
                errs.append(f"{where}: skipped")
            rows = sg.get("rows") or []
            if len(rows) > MAX_ROWS:
                errs.append(f"{where}: строк {len(rows)}")
            last = 0
            for r in rows:
                if not isinstance(r.get("i"), int) or r["i"] <= last:
                    errs.append(f"{where}: i")
                    break
                last = r["i"]
                _check_row(r, where, errs)
        t = c.get("total")
        if t is not None:
            if t.get("state") not in TOTAL_STATES or t.get("colsKind") not in COLS_KINDS:
                errs.append(f"{cn} итог: state/colsKind")
            if len(t.get("rows") or []) > MAX_ROWS:
                errs.append(f"{cn} итог: строк")
            for r in t.get("rows") or []:
                _check_row(r, f"{cn} итог", errs, parts_len=len(t.get("cols") or []))
    try:
        body = canonical(doc)
    except ValueError:
        return errs + ["NaN"]
    if canonical(json.loads(body)) != body:
        errs.append("JSON разбирается с потерями")
    if len(body) > MAX_BYTES:
        errs.append(f"размер {len(body)} Б")
    return errs


def canonical(obj):
    """UTF-8, без отступов, ключи по алфавиту, без NaN."""
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")


def load_doc(path):
    """Прежний файл протокола или None (нет, битый)."""
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
        return doc if isinstance(doc, dict) and doc.get("v") == 1 else None
    except (OSError, ValueError):
        return None


def _atomic_write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def write_if_changed(path, doc):
    """Записать файл, если содержимое (без built) изменилось. True — записан.
    Запись атомарная: временный файл и os.replace, обрыв не оставит битый JSON."""
    def body(d):
        return canonical({k: v for k, v in d.items() if k != "built"})
    old = load_doc(path)
    if old is not None and body(old) == body(doc):
        return False
    _atomic_write(path, canonical(doc))
    return True


def publish(proto_dir, doc, final_by_time=False, log=print):
    """Проверить и записать файл турнира. → (ok, записан). Не прошёл проверку — прежний файл
    остаётся как есть (последний удачный), ошибки — в журнал."""
    errs = validate(doc, final_by_time)
    if errs and all(e.startswith("размер") for e in errs):
        # не влезает только из-за деталей: пишем без них, чем совсем без файла
        log(f"  ! протокол {doc.get('tid')}: {errs[0]}, детали оценок не пишем")
        for c in doc["categories"]:
            for sg in c["segments"]:
                for r in sg["rows"]:
                    for k in ("els", "comp", "deds", "bv"):
                        r.pop(k, None)
        errs = validate(doc, final_by_time)
    if errs:
        log(f"  ! протокол {doc.get('tid')} не прошёл проверку, оставлен прежний файл:", "; ".join(errs[:5]))
        return False, False
    return True, write_if_changed(os.path.join(proto_dir, proto_name(doc["tid"])), doc)


def read_status(proto_dir):
    try:
        with open(os.path.join(proto_dir, STATUS_FILE), encoding="utf-8") as f:
            items = json.load(f).get("items")
        return items if isinstance(items, dict) else {}
    except (OSError, ValueError, AttributeError):
        return {}


def status_item(prev, now, error, complete=True):
    """Строка status.json: checked — эта попытка; read_ok — только если прочитано всё нужное без
    ошибок (complete=False — часть пропущена по бюджету прогона: это не ошибка, но и не полное чтение)."""
    prev = prev or {}
    ok = error is None and complete
    return {"checked": now.isoformat(), "read_ok": now.isoformat() if ok else prev.get("read_ok"),
            "error": error}


def write_status(proto_dir, items, now):
    _atomic_write(os.path.join(proto_dir, STATUS_FILE),
                  canonical({"v": 1, "generated": now.isoformat(), "items": items}))


def fetch_error(errors):
    """Итог чтения табло для status.json: None, net или http. errors — [(адрес, kind)] Fetcher."""
    for _, kind in errors:
        if kind == "http":
            return "http"
        if kind in ("net", "timeout"):
            return "net"
    return None


def attach_proto(events, proto_dir):
    """events[].proto — имя файла турнира, если он есть, иначе null."""
    for ev in events:
        name = proto_name(ev["tid"])
        ev["proto"] = name if os.path.exists(os.path.join(proto_dir, name)) else None


def cleanup(proto_dir, keep):
    """Удалить файлы турниров, на которые не ссылается ни одно событие (status.json не трогаем)."""
    if not os.path.isdir(proto_dir):
        return
    for fn in os.listdir(proto_dir):
        if fn.endswith(".json") and fn != STATUS_FILE and fn not in keep:
            os.unlink(os.path.join(proto_dir, fn))
