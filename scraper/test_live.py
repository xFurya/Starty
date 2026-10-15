"""Оперативный сбор на сохранённых страницах ФФКМ: python3 -m unittest scraper.test_live

Сценарий: табло выкладывает результаты сегмента раньше судейских оценок, оценки (PDF) приходят
позже. Сеть подменяется фикстурами scraper/fixtures/protocol/ffkm: страницы — по имени файла,
PDF — текстом pdftotext (без pdftotext тесты с оценками пропускаются). Время задаётся явно.
"""
import copy
import datetime as dt
import os
import shutil
import unittest
from unittest import mock

from . import build as b
from . import live
from . import names as nm
from . import net
from . import protocols as P
from . import swisstiming as st
from .test_protocols import FIX, FAMILIES, _pdf_text, _read

FFKM_DIR = os.path.join(FIX, "ffkm")
SRC = FAMILIES["ffkm"]["src"]
MSK = dt.timezone(dt.timedelta(hours=3))
HAS_PDFTOTEXT = shutil.which("pdftotext") is not None


def _fixture(name):
    """Файл фикстуры по имени без учёта регистра (в табло адреса в верхнем регистре)."""
    for f in os.listdir(FFKM_DIR):
        if f.lower() == name.lower():
            return os.path.join(FFKM_DIR, f)
    return None


class FfkmLive(unittest.TestCase):
    def setUp(self):
        self.pdf_fails = False
        self.page_override = {}  # имя файла в нижнем регистре → текст страницы
        fetch = mock.patch.object(net, "fetch", side_effect=self._fetch)
        pdf = mock.patch.object(net, "pdf_text", side_effect=self._pdf)
        cfg = mock.patch.dict(b.CFG, {"final_by_time": False, "podium_from_judges_pdf": True})
        quiet = mock.patch.object(b, "log")  # журнал сборки не нужен в тестах
        for p in (fetch, pdf, cfg, quiet):
            p.start()
            self.addCleanup(p.stop)
        self.names = nm.Names(None, {})
        self.index_text = _read(os.path.join(FFKM_DIR, "index.htm"))

    def _fetch(self, url, *args, **kwargs):
        name = url.rsplit("/", 1)[-1]
        if name.lower() in self.page_override:
            return self.page_override[name.lower()]
        path = _fixture(name)
        if path is None or path.lower().endswith(".pdf"):
            raise net.FetchError(f"{url}: нет в фикстурах", kind="http", status=404)
        return _read(path)

    def _pdf(self, url, *args, **kwargs):
        if self.pdf_fails:
            raise net.FetchError(f"{url}: сеть", kind="timeout")
        name = url.rsplit("/", 1)[-1]
        path = _fixture(name)
        if path is None:
            raise net.FetchError(f"{url}: нет в фикстурах", kind="http", status=404)
        return _pdf_text("ffkm", os.path.basename(path))

    def index(self, scores=True):
        idx = st.parse_index_page(self.index_text, SRC, b.MSK_OFFSET)
        if not scores:
            # табло без ссылок на судейские оценки (marks=false)
            idx["marks"] = False
            for c in idx["categories"]:
                for s in c["segments"]:
                    s["scores_pdf"], s["marks"], s["judges_shared"] = None, False, None
        return idx

    def seg(self, idx, page_name):
        for c in idx["categories"]:
            for s in c["segments"]:
                if s["url"].rsplit("/", 1)[-1].lower() == page_name.lower():
                    return c, s
        raise AssertionError(page_name)

    def event(self, idx, page_name, code, kind, level, start, end):
        c, s = self.seg(idx, page_name)
        ev = b.make_event(tid="ffkm:2026-08-24_pm", tournament="Первенство Москвы", kind=kind,
                          level=level, seg=code, mixed=True, start=start, end=end, venue="",
                          intl=False, broadcast=[], ours=[], athletes=[], src=idx["url"])
        ev["field"] = []
        ev["live"] = {"idx": idx["url"], "seg": s["url"], "cat": None, "first": None,
                      "names": {}, "basis": None}
        return ev


class WomenKpScores(FfkmLive):
    """Женщины КП: страница — стартовый лист, строки и тройка — из PDF оценок."""

    def setUp(self):
        super().setUp()
        self.start = dt.datetime(2026, 8, 26, 14, 30, tzinfo=MSK)
        self.end = dt.datetime(2026, 8, 26, 16, 30, tzinfo=MSK)
        self.after = self.end + dt.timedelta(minutes=30)

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_podium_from_pdf_and_settled_when_scores_present(self):
        idx = self.index(scores=True)
        ev = self.event(idx, "SEG001.HTM", "КП", "women", "junior", self.start, self.end)
        self.assertFalse(live.settled(ev))
        changed = live.refresh(ev, idx, self.names, self.after, P.Fetcher())
        self.assertTrue(changed)
        self.assertEqual(ev["live"]["basis"], "judges")
        self.assertNotIn("provisional", ev)
        # тройка — из строк PDF (стартовый лист страницы в этом сегменте пустой по результатам)
        # имена проходят через names.to_ru (регистр), сравниваем без регистра
        self.assertEqual([(r["place"], r["name"].upper(), r["points"]) for r in ev["podium"]],
                         [(1, "ДИАНА ВАДИМОВНА МИЛЬТО", "68.21"), (2, "СОФЬЯ СЕРГЕЕВНА СМАГИНА", "68.03"),
                          (3, "ДАРЬЯ ЕВГЕНЬЕВНА ЛЕБЕДЕВА", "67.42")])
        self.assertTrue(live.settled(ev))

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_pdf_start_list_mismatch_gives_no_podium_and_reason(self):
        # на странице подменено одно имя: строки PDF не сходятся со стартовым листом
        page = _read(os.path.join(FFKM_DIR, "SEG001.htm")).replace("МИЛЬТО", "ИВАНОВА", 1)
        self.page_override["seg001.htm"] = page
        idx = self.index(scores=True)
        ev = self.event(idx, "SEG001.HTM", "КП", "women", "junior", self.start, self.end)
        c, s = self.seg(idx, "SEG001.HTM")
        view = live.P.segment_view(seg=s, category=c["name"], code="КП", page=page, cat_url=None,
                                   now=self.after, start=self.start, end=self.end, marks=True,
                                   fetcher=P.Fetcher(), final_by_time=False, podium_from_pdf=True)
        self.assertEqual(view["reason"], "pdf_start_list")
        self.assertEqual(view["state"], "format")
        self.assertIsNone(view["basis"])
        self.assertFalse(live.refresh(ev, idx, self.names, self.after, P.Fetcher()))
        self.assertNotIn("podium", ev)

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_final_is_not_downgraded_when_pdf_unreadable_later(self):
        idx = self.index(scores=True)
        ev = self.event(idx, "SEG001.HTM", "КП", "women", "junior", self.start, self.end)
        live.refresh(ev, idx, self.names, self.after, P.Fetcher())
        self.assertEqual(ev["live"]["basis"], "judges")
        podium = copy.deepcopy(ev["podium"])
        self.pdf_fails = True  # сеть подвела: оценки не прочитаны в этом опросе
        live.refresh(ev, idx, self.names, self.after, P.Fetcher())
        self.assertEqual(ev["live"]["basis"], "judges")
        self.assertNotIn("provisional", ev)
        self.assertEqual(ev["podium"], podium)


class DanceRtMarks(FfkmLive):
    """Ритм-танец: страница с результатами. Без оценок на табло — промежуточный по умолчанию."""

    def setUp(self):
        super().setUp()
        self.start = dt.datetime(2026, 8, 24, 15, 0, tzinfo=MSK)
        self.end = dt.datetime(2026, 8, 24, 16, 30, tzinfo=MSK)
        self.after = self.end + dt.timedelta(hours=1)

    def test_marks_false_is_provisional_by_default(self):
        idx = self.index(scores=False)
        ev = self.event(idx, "SEG007.HTM", "РТ", "dance", "junior", self.start, self.end)
        self.assertTrue(live.refresh(ev, idx, self.names, self.after, P.Fetcher()))
        self.assertIs(ev["provisional"], True)
        self.assertIsNone(ev["live"]["basis"])
        self.assertEqual(ev["podium"][0]["points"], "66.36")
        self.assertFalse(live.settled(ev))

    def test_marks_false_is_final_by_time_only_with_flag(self):
        idx = self.index(scores=False)
        ev = self.event(idx, "SEG007.HTM", "РТ", "dance", "junior", self.start, self.end)
        with mock.patch.dict(b.CFG, {"final_by_time": True}):
            live.refresh(ev, idx, self.names, self.after, P.Fetcher())
        self.assertEqual(ev["live"]["basis"], "time")
        self.assertNotIn("provisional", ev)
        self.assertTrue(live.settled(ev))

    def test_no_change_while_segment_is_running(self):
        idx = self.index(scores=False)
        ev = self.event(idx, "SEG007.HTM", "РТ", "dance", "junior", self.start, self.end)
        during = self.start + dt.timedelta(minutes=40)
        live.refresh(ev, idx, self.names, during, P.Fetcher())
        self.assertIsNone(ev["live"]["basis"])
        self.assertTrue(ev["provisional"])

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_judges_appear_later_then_final(self):
        ev = None
        idx_none = self.index(scores=False)
        ev = self.event(idx_none, "SEG007.HTM", "РТ", "dance", "junior", self.start, self.end)
        live.refresh(ev, idx_none, self.names, self.after, P.Fetcher())
        self.assertEqual(ev["live"]["basis"], None)
        idx = self.index(scores=True)
        live.refresh(ev, idx, self.names, self.after, P.Fetcher())
        self.assertEqual(ev["live"]["basis"], "judges")
        self.assertNotIn("provisional", ev)
        self.assertTrue(live.settled(ev))


class MenKpMismatch(FfkmLive):
    """Мужской КП ссылается на файл женского: тройки нет, сегмент не окончательный."""

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_judges_mismatch_no_podium(self):
        start = dt.datetime(2026, 8, 27, 14, 0, tzinfo=MSK)
        end = dt.datetime(2026, 8, 27, 16, 0, tzinfo=MSK)
        idx = self.index(scores=True)
        ev = self.event(idx, "SEG003.HTM", "КП", "men", "junior", start, end)
        self.assertFalse(live.refresh(ev, idx, self.names, end + dt.timedelta(hours=1), {}))
        self.assertNotIn("podium", ev)
        self.assertIsNone(ev["live"]["basis"])


class Replay(FfkmLive):
    """Переигрывание: окончательный сегмент не откатывается в промежуточный."""

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_states_are_monotonic_across_polls(self):
        start = dt.datetime(2026, 8, 24, 15, 0, tzinfo=MSK)
        end = dt.datetime(2026, 8, 24, 16, 30, tzinfo=MSK)
        no_marks, with_marks = self.index(scores=False), self.index(scores=True)
        ev = self.event(no_marks, "SEG007.HTM", "РТ", "dance", "junior", start, end)
        order = []
        for idx, when in ((no_marks, start + dt.timedelta(minutes=10)),
                          (no_marks, end + dt.timedelta(minutes=5)),
                          (with_marks, end + dt.timedelta(minutes=20)),
                          (with_marks, end + dt.timedelta(hours=2))):
            live.refresh(ev, idx, self.names, when, P.Fetcher())
            order.append(ev["live"]["basis"])
        # промежуточный → окончательный по оценкам; дальше не откатывается
        self.assertEqual(order, [None, None, "judges", "judges"])
        self.pdf_fails = True
        live.refresh(ev, with_marks, self.names, end + dt.timedelta(hours=3), {})
        self.assertEqual(ev["live"]["basis"], "judges")


class Network(FfkmLive):
    def test_page_error_changes_nothing(self):
        start = dt.datetime(2026, 8, 24, 15, 0, tzinfo=MSK)
        end = dt.datetime(2026, 8, 24, 16, 30, tzinfo=MSK)
        idx = self.index(scores=False)
        ev = self.event(idx, "SEG007.HTM", "РТ", "dance", "junior", start, end)
        before = copy.deepcopy(ev)
        with mock.patch.object(net, "fetch", side_effect=net.FetchError("x", kind="timeout")):
            self.assertFalse(live.refresh(ev, idx, self.names, end + dt.timedelta(hours=1), {}))
        self.assertEqual(ev, before)


class Budget(unittest.TestCase):
    """Бюджет запросов live: не больше BUDGET за прогон, пропущенное — в журнал, файл годен."""

    def setUp(self):
        import tempfile
        from .test_protocols import NOW, build_family
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.now = NOW
        self.events, _ = build_family("ffkm", self.dir)  # прежний файл, как после полного сбора
        self.path = os.path.join(self.dir, "ffkm_2026-08-24_pm.json")

    def run_live(self, budget):
        from .test_protocols import FixtureNet
        fetcher = P.Fetcher(budget=budget, timeout=live.TIMEOUT, tries=live.TRIES)
        with FixtureNet("ffkm"):
            idx = st.parse_index_page(fetcher.page(SRC), SRC)
            live.protocols(self.events, self.events, {SRC: idx}, nm.Names(None, {}), self.now, fetcher, self.dir)
        return fetcher

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_final_segments_are_not_refetched(self):
        fetcher = self.run_live(live.BUDGET)
        self.assertLessEqual(fetcher.requests, live.BUDGET)
        asked = set(fetcher.pages) | set(fetcher.pdfs)
        for name in ("SEG001.HTM", "SEG005.HTM", "SEG007.HTM", "TaaCopop_PT_Scores.pdf", "apoeaaeCopop_K_Scores.pdf"):
            # женский КП, пары и ритм-танец уже окончательные в прежнем файле
            self.assertFalse(any(u.endswith(name) for u in asked), name)
        # PDF женского КП скачан для мужского КП: адрес у них общий, мужской не окончательный
        self.assertTrue(any(u.endswith("SEG003.HTM") for u in asked))
        self.assertEqual(P.validate(P.load_doc(self.path)), [])

    @unittest.skipUnless(HAS_PDFTOTEXT, "нужен pdftotext")
    def test_budget_limits_requests_and_keeps_previous_segments(self):
        before = P.load_doc(self.path)
        fetcher = self.run_live(2)
        self.assertEqual(fetcher.requests, 2)
        self.assertTrue(fetcher.skipped)
        doc = P.load_doc(self.path)
        self.assertEqual(P.validate(doc), [])
        codes = lambda d: [(c["name"], sg["code"], sg["state"]) for c in d["categories"] for sg in c["segments"]]
        self.assertEqual(codes(doc), codes(before))
        item = P.read_status(self.dir)["ffkm:2026-08-24_pm"]
        self.assertIsNone(item["error"])
        self.assertNotEqual(item["read_ok"], item["checked"])  # чтение неполное: read_ok — от полного сбора

    def test_timeout_and_tries_reach_fetch(self):
        with mock.patch.object(net, "fetch", return_value="x") as f:
            P.Fetcher(budget=1, timeout=live.TIMEOUT, tries=live.TRIES).page("https://x/a")
        f.assert_called_once_with("https://x/a", timeout=15, tries=2)
        fetcher = P.Fetcher(budget=1)
        with mock.patch.object(net, "fetch", return_value="x"):
            fetcher.page("https://x/a")
            fetcher.page("https://x/a")  # тот же адрес — из кэша, бюджет не тратится
            with self.assertRaises(P.Skipped):
                fetcher.page("https://x/b")
        self.assertEqual((fetcher.requests, fetcher.skipped), (1, ["https://x/b"]))


if __name__ == "__main__":
    unittest.main()
