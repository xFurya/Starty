"""Состояние сегмента и строки протокола для событий: один расчёт для build.py и live.py.

Окончательность (ПРОЕКТ.md, решение владельца): сегмент окончательный, когда табло выложило
судейские оценки этого сегмента и они подтверждены (заголовок PDF совпал с категорией и
сегментом; JudgesDetails подтверждены без проверки). Без оценок сегмент промежуточный. Режим
«окончательный по времени» — флаг final_by_time, по умолчанию выключен.

Строки сегмента: со страницы табло (таблица результатов). Если страница стартового листа
или пустая, а оценки подтверждены (ФФКМ, одиночки), строки берутся из PDF оценок — но только
если они сходятся с табло: со стартовым листом страницы (номера и имена) или с колонкой сегмента
в итоге вида (место). Не сошлись — строк нет, причина в reason.
"""
from . import net
from . import swisstiming as st


def key(name):
    """Имя для сравнения: регистр, «ё» как «е», пробелы."""
    return " ".join(name.lower().replace("ё", "е").split())


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


def _pdf(url, cache):
    """Текст PDF по адресу, один запрос на прогон (cache). None — не прочитан: сеть, не PDF,
    pdftotext. Любой сбой здесь не должен отбрасывать строки страницы — оценки просто не подтверждены."""
    if url not in cache:
        try:
            cache[url] = net.pdf_text(url)
        except Exception:
            cache[url] = None
    return cache[url]


def judges_state(seg, category, segment, cache):
    """Состояние оценок сегмента: None (ссылки нет), ok, mismatch или unread."""
    if seg.get("judges_pdf"):
        return "ok"
    url = seg.get("scores_pdf")
    if not url:
        return None
    text = _pdf(url, cache)
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


def segment_view(*, seg, category, code, page, cat_url, now, start, end, marks, cache,
                 final_by_time, podium_from_pdf):
    """Сегмент для события: {state, basis, table, rows, results, judges, reason, skipped}.

    seg — сегмент из parse_index_page; page — текст страницы сегмента (None — не скачана);
    cat_url — итог вида, если это последний сегмент категории (для сверки), иначе None;
    cache — словарь PDF на один прогон. results — строки для мест и тройки в формате
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
        judges = judges_state(seg, category, seg["name"], cache)
    if judges == "ok" and not seg.get("judges_pdf") and table in ("starting", "empty"):
        # строки PDF оценок (ФФКМ, одиночки): страница стартового листа или пустая
        pdf_rows = st.parse_judges_pdf(cache[seg["scores_pdf"]])
        starting = st.parse_starting_order(seg["url"], page) if page is not None else []
        total_col = None
        if cat_url:
            try:
                total_col = total_column(net.fetch(cat_url), code)
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
