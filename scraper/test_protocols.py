"""Снимок разбора табло на сохранённых страницах: python3 -m unittest scraper.test_protocols

Фикстуры — scraper/fixtures/protocol/<семейство>/: страницы и PDF в том виде, в каком их отдали
табло (cp1251 не перекодируем). expected.json рядом — что видит разборщик на каждой странице.
Снимок меняется только осознанно, с объяснением в коммите:
    STARTY_REGEN=1 python3 -m unittest scraper.test_protocols
перезаписывает expected.json текущим разборщиком. Без STARTY_REGEN тест сравнивает и падает
при любом расхождении. Сеть не нужна: адреса страниц подставляются из FAMILIES.
"""
import datetime as dt
import glob
import json
import os
import re
import shutil
import subprocess
import unittest
from unittest import mock

from . import build as b
from . import net
from . import protocols as P
from . import swisstiming as st

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "protocol")
MSK = dt.timezone(dt.timedelta(hours=3))

# Адрес оглавления каждого семейства: по нему разрешаются относительные ссылки на страницы.
FAMILIES = {
    "denistenmemorial": {"src": "https://www.denistenmemorial.kz/results/index.htm", "offset": None},
    "ffkm": {"src": "https://ffkm.ru/results/2026-2027/2026-08-24_pm/index.htm", "offset": b.MSK_OFFSET},
    "fsrussia": {"src": "https://fsrussia.ru/results/2627/1etap_jun/index.htm", "offset": None},
    "isu": {"src": "https://results.isu.org/results/season2627/jgptur2026/index.htm", "offset": None},
}


def _read(path):
    """Страница как её отдал сервер: сначала UTF-8, иначе cp1251 (как net._decode)."""
    with open(path, "rb") as f:
        raw = f.read()
    for enc in ("utf-8", "cp1251"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    raise AssertionError(f"{path}: не декодируется")


def _disk(family, name):
    """Путь к фикстуре по имени без учёта регистра (в адресах табло — верхний регистр)."""
    d = os.path.join(FIX, family)
    for f in os.listdir(d):
        if f.lower() == name.lower():
            return os.path.join(d, f)
    raise AssertionError(f"нет фикстуры {family}/{name}")


def _base(url):
    return url.rsplit("/", 1)[-1] if url else None


def _index_view(idx):
    return {
        "name": idx["name"], "city": idx["city"], "nation": idx["nation"], "venue": idx["venue"],
        "offset": idx["offset"], "marks": idx["marks"],
        "categories": [{
            "name": c["name"],
            "entries": _base(c["entries_url"]),
            "results": _base(c["results_url"]),
            "segments": [{
                "name": s["name"],
                "page": _base(s["url"]),
                "times_pdf": _base(s["times_pdf"]),
                "judges_pdf": _base(s["judges_pdf"]),
                "scores_pdf": _base(s["scores_pdf"]),
                "marks": s["marks"],
                "judges_shared": s["judges_shared"],
                "start": s["start"].isoformat() if s.get("start") else None,
            } for s in c["segments"]],
        } for c in idx["categories"]],
    }


def snapshot(family):
    """Что текущий разборщик говорит о каждой странице семейства (только то, что он умеет)."""
    spec = FAMILIES[family]
    base = spec["src"].rsplit("/", 1)[0] + "/"
    d = os.path.join(FIX, family)
    out = {"index": {}, "segments": {}, "totals": {}}
    for path in sorted(glob.glob(os.path.join(d, "*.htm*"))):
        name = os.path.basename(path)
        text = _read(path)
        if re.fullmatch(r"index[\w]*\.html?", name, re.I):
            out["index"][name] = _index_view(st.parse_index_page(text, base + "index.htm", spec["offset"]))
        elif re.fullmatch(r"SEG\d+\.html?", name, re.I):
            url = base + name
            out["segments"][name] = {
                "results": st.parse_segment_results(text),
                "starting": st.parse_starting_order(url, text),
                "protocol": st.parse_segment_protocol(text),
            }
        elif re.fullmatch(r"CAT\d+RS\.html?", name, re.I):
            url = base + name
            with mock.patch.object(net, "fetch", return_value=text):
                out["totals"][name] = st.parse_category_results(url)
            out["totals"][name]["protocol"] = st.parse_category_protocol(text)
    return out


def _dump(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=1) + "\n"


class Snapshot(unittest.TestCase):
    def test_families_match_expected(self):
        regen = bool(os.environ.get("STARTY_REGEN"))
        for family in sorted(FAMILIES):
            with self.subTest(family=family):
                got = snapshot(family)
                path = os.path.join(FIX, family, "expected.json")
                if regen:
                    with open(path, "w", encoding="utf-8", newline="\n") as f:
                        f.write(_dump(got))
                    continue
                with open(path, encoding="utf-8") as f:
                    want = json.load(f)
                self.assertEqual(got, want)


def _pdf_text(family, name):
    """Текст PDF как его отдаёт pdftotext -layout (нужен poppler). Без него тест пропускается."""
    return subprocess.run(["pdftotext", "-layout", os.path.join(FIX, family, name), "-"],
                          capture_output=True, text=True, check=True).stdout


HAS_PDFTOTEXT = shutil.which("pdftotext") is not None
FFKM_PDF = {
    "women_kp": ("OooeaaeCop_K_Scores.pdf", "Одиночное катание, КМС, Девушки, Юниорки", "Короткая программа"),
    "women_fs": ("OooeaaeCop__Scores.pdf", "Одиночное катание, КМС, Девушки, Юниорки", "Произвольная программа"),
    "men_kp": ("OooeaaeCop_K_Scores.pdf", "Одиночное катание, КМС, Юноши, Юниоры", "Короткая программа"),
    "pairs_kp": ("apoeaaeCopop_K_Scores.pdf", "Парное катание, КМС, Юниорки, Юниоры", "Короткая программа"),
    "dance_rt": ("TaaCopop_PT_Scores.pdf", "Танцы на льду, КМС, Юниорки, Юниоры", "Ритм-танец"),
}


class SegmentRows(unittest.TestCase):
    """Разбор таблицы протокола на синтетике и на страницах табло."""

    HEAD = ("<tr><th>Pl.</th><th>Name</th><th>Nation</th><th>TSS =</th><th>TES +</th>"
            "<th>PCS +</th><th>Снижение -</th><th>StN.</th></tr>")

    def _page(self, *rows):
        return "<table>" + self.HEAD + "".join(rows) + "</table>"

    def test_withdrawn_row_kept_with_status(self):
        page = self._page(
            "<tr><td>1</td><td>A B</td><td>RUS</td><td>100.00</td><td>50.00</td><td>50.00</td><td>0.00</td><td>#4</td></tr>",
            "<tr><td>WD</td><td>C D</td><td>RUS</td><td></td><td></td><td></td><td></td><td>#7</td></tr>")
        p = st.parse_segment_protocol(page)
        self.assertEqual(p["table"], "results")
        self.assertEqual(len(p["rows"]), 2)
        wd = p["rows"][1]
        self.assertEqual((wd["place"], wd["status"], wd["name"], wd["points"], wd["no"]), (None, "WD", "C D", None, 7))
        self.assertEqual(p["skipped"], 0)

    def test_comma_points_is_skipped_not_guessed(self):
        page = self._page(
            "<tr><td>1</td><td>A B</td><td>RUS</td><td>115,66</td><td>56.56</td><td>59.10</td><td>0.00</td><td>#1</td></tr>",
            "<tr><td>2</td><td>C D</td><td>RUS</td><td>114.72</td><td>52.78</td><td>61.94</td><td>0.00</td><td>#2</td></tr>")
        p = st.parse_segment_protocol(page)
        self.assertEqual([r["points"] for r in p["rows"]], [None, "114.72"])
        self.assertEqual(p["skipped"], 1)
        self.assertEqual(p["reasons"], ["points"])

    def test_same_surname_other_place_is_kept_same_pair_is_duplicate(self):
        page = self._page(
            "<tr><td>1</td><td>A Petrov</td><td>RUS</td><td>100.00</td><td>50.00</td><td>50.00</td><td>0.00</td><td>#1</td></tr>",
            "<tr><td>2</td><td>A Petrov</td><td>RUS</td><td>90.00</td><td>45.00</td><td>45.00</td><td>0.00</td><td>#2</td></tr>",
            "<tr><td>2</td><td>A Petrov</td><td>RUS</td><td>90.00</td><td>45.00</td><td>45.00</td><td>0.00</td><td>#2</td></tr>")
        p = st.parse_segment_protocol(page)
        self.assertEqual([r["place"] for r in p["rows"]], [1, 2])
        self.assertEqual(p["skipped"], 1)
        self.assertEqual(p["reasons"], ["duplicate"])
        # и то же правило в контракте parse_segment_results: однофамилец на другом месте не схлопывается
        self.assertEqual([r["place"] for r in st.parse_segment_results(page)], [1, 2])

    def test_legend_rows_are_not_participants(self):
        page = self._page(
            "<tr><td>1</td><td>A B</td><td>RUS</td><td>100.00</td><td>50.00</td><td>50.00</td><td>0.00</td><td>#1</td></tr>",
            "<tr><td>SK</td><td>Мастерство катания</td></tr>",
            "<tr><td>TSS</td><td>Сумма за сегмент</td></tr>")
        p = st.parse_segment_protocol(page)
        self.assertEqual(len(p["rows"]), 1)
        self.assertEqual(p["skipped"], 0)

    def test_two_tables_without_components_is_format(self):
        page = ("<table><tr><th>Pl.</th><th>Name</th><th>Points</th></tr>"
                "<tr><td>1</td><td>A B</td><td>100.00</td></tr></table>"
                "<table><tr><th>Pl.</th><th>Name</th><th>Points</th></tr>"
                "<tr><td>1</td><td>C D</td><td>99.00</td></tr></table>")
        self.assertEqual(st.parse_segment_protocol(page)["table"], "format")

    def test_starting_list_and_empty_page(self):
        start = '<table><tr><th>StN.</th><th>Name</th><th>Nation</th></tr><tr><td>1</td><td>A B</td><td>RUS</td></tr></table>'
        self.assertEqual(st.parse_segment_protocol(start)["table"], "starting")
        legend = "<table><tr><th>Обозн.</th><th></th></tr><tr><td>TSS</td><td>Сумма за сегмент</td></tr></table>"
        self.assertEqual(st.parse_segment_protocol(legend)["table"], "empty")

    def test_header_only_before_start_is_starting(self):
        page = '<table><tr><th>Pl.</th><th>Name</th><th>Nation</th><th>StN.</th></tr><tr><td></td><td>A B</td><td>RUS</td><td>#3</td></tr></table>'
        self.assertEqual(st.parse_segment_protocol(page)["table"], "starting")

    def test_fpl_header_starting_list(self):
        page = ('<table><tr><th>FPl.</th><th>Name</th><th>Nation</th></tr>'
                '<tr><td>1</td><td>A B</td><td>RUS</td></tr>'
                '<tr><td>2</td><td>C D</td><td>RUS</td></tr></table>')
        got = st.parse_starting_order("u", page)
        self.assertEqual([g["name"] for g in got], ["A B", "C D"])

    def test_nation_of(self):
        self.assertEqual(st.nation_of("МОС  /  СПБ"), "МОС / СПБ")
        self.assertEqual(st.nation_of("AIN2"), "AIN2")
        self.assertEqual(st.nation_of("ГБУ ДО"), "")
        self.assertEqual(st.nation_of(""), "")
        self.assertEqual(st.nation_of("МОС"), "МОС")

    def test_ffkm_dance_page_has_components(self):
        p = st.parse_segment_protocol(_read(os.path.join(FIX, "ffkm", "SEG007.htm")))
        r = p["rows"][0]
        self.assertEqual((r["place"], r["no"], r["points"], r["tes"], r["pcs"], r["ded"]),
                         (1, 6, "66.36", "37.77", "28.59", "0.00"))
        self.assertEqual([x["i"] for x in p["rows"]], list(range(1, 25)))
        self.assertEqual(p["skipped"], 0)

    def test_ffkm_singles_page_is_starting_and_legend_is_empty(self):
        self.assertEqual(st.parse_segment_protocol(_read(os.path.join(FIX, "ffkm", "SEG001.htm"))),
                         {"table": "starting", "rows": [], "skipped": 0, "reasons": []})
        self.assertEqual(st.parse_segment_protocol(_read(os.path.join(FIX, "ffkm", "SEG002.htm")))["table"], "empty")


class TotalRows(unittest.TestCase):
    def test_ffkm_women_total_has_places_and_not_qualified(self):
        t = st.parse_category_protocol(_read(os.path.join(FIX, "ffkm", "CAT001RS.htm")))
        self.assertEqual(t["cols"], ["КП", "ПП"])
        self.assertEqual(t["colsKind"], "places")
        self.assertTrue(t["complete"])
        ranked = [r for r in t["rows"] if r["place"] is not None]
        nqd = [r for r in t["rows"] if r["status"] == "NQD"]
        self.assertEqual((len(ranked), len(nqd)), (24, 24))
        self.assertEqual(ranked[0]["parts"], ["3", "1"])
        self.assertEqual(nqd[0]["parts"], [None, None])
        self.assertEqual(nqd[0]["points"], None)

    def test_ffkm_men_total_has_withdrawn_rows(self):
        t = st.parse_category_protocol(_read(os.path.join(FIX, "ffkm", "CAT002RS.htm")))
        self.assertIn("WD", [r["status"] for r in t["rows"]])

    def test_denistenmemorial_total_fpl_header(self):
        t = st.parse_category_protocol(_read(os.path.join(FIX, "denistenmemorial", "CAT001RS.htm")))
        self.assertEqual(t["table"], "results")
        self.assertEqual(t["cols"], ["SP", "FS"])
        self.assertEqual(len(t["rows"]), 10)

    def test_parts_none_for_empty_cell_and_colskind_points(self):
        page = ('<table><tr><th>Pl.</th><th>Name</th><th>Nation</th><th>Points</th><th>SP</th><th>FS</th></tr>'
                '<tr><td>1</td><td>A B</td><td>RUS</td><td>200.00</td><td>3</td><td></td></tr></table>')
        t = st.parse_category_protocol(page)
        self.assertEqual(t["rows"][0]["parts"], ["3", None])
        self.assertFalse(t["complete"])
        self.assertEqual(t["colsKind"], "places")


class JudgesPdf(unittest.TestCase):
    """Разбор текста PDF оценок на синтетике: работает без pdftotext."""

    LINES = [
        "   Место     Имя        Старт.  Общая сумма за вид   Сумма за элементы  Сумма за компоненты   Общая сумма снижений",
        "     1       Анна Иванова                       42   68.21       39.39          28.82            0.00",
        "                  ГБУ ДО МАФКК школа Наши надежды",
        "     1       2A                                                      3.30            0.99    3      3      3      2      4                                                       4.29",
        "     2       Ева Петрова                        7    60.10       33.00          27.10           -2.00",
        "     2       Ева Петрова                        7    60.10       33.00          27.10           -2.00",
        "     3       Ольга Смирнова / Иван Сидоров      9   55.5       30.00          25.00            0.00",
        "   Снижения                                      Падения:        -2.00",
    ]

    def test_summary_rows_only(self):
        rows = st.parse_judges_pdf("\n".join(self.LINES))
        self.assertEqual([r["place"] for r in rows], [1, 2])  # повтор места 2 пропущен
        self.assertEqual(rows[0], {"place": 1, "name": "Анна Иванова", "no": 42, "points": "68.21",
                                   "tes": "39.39", "pcs": "28.82", "ded": "0.00", "i": 1})
        self.assertEqual(rows[1]["ded"], "2.00")  # снижение — модуль, как на табло

    def test_header_matches_own_category_and_segment(self):
        text = ("Первенство Москвы\n"
                "OДИНOЧНOE КAТAНИE, КМC, ДЕВУШКИ, ЮНИOPКИ Короткая программа\n"
                "Первенство Москвы -- Oдинoчнoe кaтaниe, КМC, Девушки, Юниopки (Короткая программа)")
        self.assertTrue(st.judges_header_ok(text, "Одиночное катание, КМС, Девушки, Юниорки", "Короткая программа"))
        self.assertFalse(st.judges_header_ok(text, "Одиночное катание, КМС, Юноши, Юниоры", "Короткая программа"))
        self.assertFalse(st.judges_header_ok(text, "Одиночное катание, КМС, Девушки, Юниорки", "Произвольная программа"))
        self.assertFalse(st.judges_header_ok("", "Одиночное катание", "Короткая программа"))

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext (poppler)")
    def test_ffkm_pdf_rows_and_headers(self):
        counts = {"women_kp": 48, "women_fs": 24, "dance_rt": 24, "pairs_kp": 8}
        for key, n in counts.items():
            pdf, cat, seg = FFKM_PDF[key]
            text = _pdf_text("ffkm", pdf)
            rows = st.parse_judges_pdf(text)
            with self.subTest(key=key):
                self.assertEqual(len(rows), n)
                self.assertEqual([r["place"] for r in rows], list(range(1, n + 1)))
                self.assertTrue(st.judges_header_ok(text, cat, seg))
        # мужской КП ссылается на тот же файл, что и женский
        text = _pdf_text("ffkm", FFKM_PDF["men_kp"][0])
        pdf, cat, seg = FFKM_PDF["men_kp"]
        self.assertFalse(st.judges_header_ok(text, cat, seg))
        pdf, cat, seg = FFKM_PDF["dance_rt"]
        self.assertFalse(st.judges_header_ok(_pdf_text("ffkm", pdf), cat, "Произвольный танец"))

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext (poppler)")
    def test_dance_page_rows_equal_pdf_rows(self):
        pdf_rows = st.parse_judges_pdf(_pdf_text("ffkm", FFKM_PDF["dance_rt"][0]))
        page = st.parse_segment_protocol(_read(os.path.join(FIX, "ffkm", "SEG007.htm")))["rows"]
        key = lambda r: (r["place"], r["no"], " ".join(r["name"].split()), r["points"], r["tes"], r["pcs"], r["ded"])
        self.assertEqual([key(r) for r in page], [key(r) for r in pdf_rows])


class SegmentStates(unittest.TestCase):
    """Правило состояния сегмента (protocols.segment_state) на границах времени."""

    START = dt.datetime(2026, 8, 24, 15, 0, tzinfo=MSK)
    END = dt.datetime(2026, 8, 24, 16, 35, tzinfo=MSK)

    def state(self, now, table="results", rows=True, marks=True, judges=None, by_time=False):
        return P.segment_state(now, self.START, self.END, table, rows, marks, judges, by_time)

    def test_boundaries_by_time(self):
        self.assertEqual(self.state(self.START - dt.timedelta(seconds=1), table="starting", rows=False),
                         ("scheduled", None))
        self.assertEqual(self.state(self.START, table="starting", rows=False), ("not_published", None))
        self.assertEqual(self.state(self.END - dt.timedelta(seconds=1)), ("in_progress", None))
        self.assertEqual(self.state(self.END), ("provisional", None))

    def test_judges_make_final_at_any_time_after_start(self):
        self.assertEqual(self.state(self.START + dt.timedelta(minutes=5), judges="ok"), ("final", "judges"))
        self.assertEqual(self.state(self.END + dt.timedelta(days=3), judges="ok"), ("final", "judges"))

    def test_mismatch_unread_and_format(self):
        self.assertEqual(self.state(self.END, judges="mismatch"), ("judges_mismatch", None))
        self.assertEqual(self.state(self.END, judges="unread"), ("provisional", None))
        self.assertEqual(self.state(self.END, table="format"), ("format", None))
        self.assertEqual(self.state(self.END, table="starting", rows=False, judges="ok"), ("format", None))

    def test_final_by_time_only_without_marks_and_only_with_flag(self):
        after = self.END + dt.timedelta(minutes=1)
        self.assertEqual(self.state(after, marks=False), ("provisional", None))
        self.assertEqual(self.state(after, marks=False, by_time=True), ("final", "time"))
        self.assertEqual(self.state(after, marks=True, by_time=True), ("provisional", None))
        self.assertEqual(self.state(self.END - dt.timedelta(seconds=1), marks=False, by_time=True),
                         ("in_progress", None))


class FfkmSegments(unittest.TestCase):
    """Сегменты ФФКМ на фикстурах (protocols.segment_view). Время задано явно; PDF — pdftotext."""

    def setUp(self):
        self.idx = st.parse_index_page(_read(os.path.join(FIX, "ffkm", "index.htm")),
                                       FAMILIES["ffkm"]["src"], b.MSK_OFFSET)
        self.cache = {}

    def seg(self, page_name):
        for c in self.idx["categories"]:
            for s in c["segments"]:
                if s["url"].rsplit("/", 1)[-1].lower() == page_name.lower():
                    return c, s
        raise AssertionError(page_name)

    def view(self, page_name, code, start, end, now, cat_url=None, podium=True, page=None, pdf=None):
        c, s = self.seg(page_name)
        page = page if page is not None else _read(_disk("ffkm", page_name))
        if pdf is not None:
            self.cache[s["scores_pdf"]] = pdf
        return P.segment_view(seg=s, category=c["name"], code=code, page=page, cat_url=cat_url,
                              now=now, start=start, end=end, marks=self.idx["marks"], cache=self.cache,
                              final_by_time=False, podium_from_pdf=podium)

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_women_kp_final_by_judges_rows_from_pdf(self):
        start = dt.datetime(2026, 8, 26, 14, 30, tzinfo=MSK)
        end = dt.datetime(2026, 8, 26, 16, 30, tzinfo=MSK)
        v = self.view("SEG001.HTM", "КП", start, end, end + dt.timedelta(hours=1))
        self.assertEqual((v["state"], v["basis"], v["table"], v["judges"]), ("final", "judges", "judges_pdf", "ok"))
        self.assertEqual(len(v["rows"]), 48)
        # results — все строки по местам (как parse_segment_results); тройку берёт top3
        self.assertEqual([r["place"] for r in v["results"]], list(range(1, 49)))
        self.assertIsNone(v["reason"])

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_women_kp_podium_off_keeps_state_without_podium(self):
        start = dt.datetime(2026, 8, 26, 14, 30, tzinfo=MSK)
        end = dt.datetime(2026, 8, 26, 16, 30, tzinfo=MSK)
        v = self.view("SEG001.HTM", "КП", start, end, end + dt.timedelta(hours=1), podium=False)
        self.assertEqual(v["state"], "final")
        self.assertIsNone(v["results"])

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_men_kp_shared_url_is_mismatch(self):
        start = dt.datetime(2026, 8, 27, 14, 0, tzinfo=MSK)
        end = dt.datetime(2026, 8, 27, 16, 0, tzinfo=MSK)
        v = self.view("SEG003.HTM", "КП", start, end, end + dt.timedelta(hours=1))
        self.assertEqual((v["state"], v["judges"], v["rows"], v["results"]), ("judges_mismatch", "mismatch", [], None))

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_women_fs_checked_against_total_column(self):
        # страница ПП пустая (только легенда): сверка только с колонкой ПП в итоге вида
        start = dt.datetime(2026, 8, 26, 17, 0, tzinfo=MSK)
        end = dt.datetime(2026, 8, 26, 18, 30, tzinfo=MSK)
        cat = _read(_disk("ffkm", "CAT001RS.htm"))
        with mock.patch.object(net, "fetch", return_value=cat):
            v = self.view("SEG002.HTM", "ПП", start, end, end + dt.timedelta(hours=1),
                          cat_url="https://ffkm.ru/x/CAT001RS.HTM",
                          pdf=_pdf_text("ffkm", FFKM_PDF["women_fs"][0]))
        self.assertEqual((v["state"], v["table"], len(v["rows"])), ("final", "judges_pdf", 24))
        self.assertEqual(v["results"][0]["points"], "138.01")

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_women_fs_without_total_is_unverified_and_not_final(self):
        start = dt.datetime(2026, 8, 26, 17, 0, tzinfo=MSK)
        end = dt.datetime(2026, 8, 26, 18, 30, tzinfo=MSK)
        v = self.view("SEG002.HTM", "ПП", start, end, end + dt.timedelta(hours=1), cat_url=None,
                      pdf=_pdf_text("ffkm", FFKM_PDF["women_fs"][0]))
        self.assertEqual((v["state"], v["reason"], v["rows"]), ("format", "pdf_unverified", []))

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_total_mismatch_is_detected(self):
        start = dt.datetime(2026, 8, 26, 17, 0, tzinfo=MSK)
        end = dt.datetime(2026, 8, 26, 18, 30, tzinfo=MSK)
        cat = _read(_disk("ffkm", "CAT001RS.htm"))
        rows = st.parse_judges_pdf(_pdf_text("ffkm", FFKM_PDF["women_fs"][0]))
        self.assertEqual(rows[0]["name"], "Дарья Евгеньевна ЛЕБЕДЕВА")  # ПП = 1 в итоге
        rows[0]["place"] = 2  # в PDF место не то, что в итоге вида
        with mock.patch.object(net, "fetch", return_value=cat):
            col = P.total_column(cat, "ПП")
        self.assertEqual(P.pdf_check(rows, [], col), (False, "total"))


class FfkmPdfNames(unittest.TestCase):
    def test_key_ignores_case_yo_and_spaces(self):
        self.assertEqual(P.key("  Анна   ЁЖИКОВА "), P.key("анна ежикова"))

    def test_pdf_check_start_list_and_empty(self):
        rows = [{"place": 1, "name": "A B", "no": 3}]
        self.assertEqual(P.pdf_check([], [], None), (False, "empty"))
        self.assertEqual(P.pdf_check(rows, [{"no": 3, "name": "a b"}], None), (True, None))
        self.assertEqual(P.pdf_check(rows, [{"no": 4, "name": "A B"}], None), (False, "start_list"))
        self.assertEqual(P.pdf_check(rows, [], None), (False, "unverified"))


if __name__ == "__main__":
    unittest.main()
