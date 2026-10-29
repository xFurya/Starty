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
from . import isu
from . import names as nm
from . import net
from . import pages_merge
from . import protocols as P
from . import swisstiming as st
from .test_protocols import FIX, FAMILIES, FAMILY_BUILD, FixtureNet, _pdf_text, _read, build_family

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

    def test_unscored_skaters_keep_no_place_while_segment_runs(self):
        # посреди старта на табло два оценённых, а ниже — остаток стартового порядка
        # (номер, ранг и баллы прошлого сегмента): это не места, и прежнее чужое место снимается
        self.page_override["seg007.htm"] = (
            '<table><tr><th>Pl.</th><th>Name</th><th>Nation</th><th>TSS</th><th>TES</th><th>PCS</th></tr>'
            '<tr><td>1</td><td>Ivan SEMENOV</td><td>RUS</td><td>99.55</td><td>49.82</td><td>50.73</td></tr>'
            '<tr><td>2</td><td>Max GALKIN</td><td>RUS</td><td>88.23</td><td>39.92</td><td>49.31</td></tr></table>'
            '<table><tr><th>StN.</th><th>Name</th><th>Nation</th><th>Rank</th><th>Points</th></tr>'
            '<tr><td>3</td><td>Petr PETROV</td><td>RUS</td><td>6</td><td>58.37</td></tr>'
            '<tr><td>4</td><td>Oleg OLEGOV</td><td>RUS</td><td>5</td><td>60.85</td></tr></table>')
        idx = self.index(scores=False)
        ev = self.event(idx, "SEG007.HTM", "РТ", "dance", "junior", self.start, self.end)
        ev["field"] = [{"name": n, "place": 7} for n in ("Ivan Semenov", "Petr Petrov")]
        ev["live"]["names"] = {n: n.title() for n in ("Ivan SEMENOV", "Max GALKIN", "Petr PETROV")}
        live.refresh(ev, idx, self.names, self.after, P.Fetcher())
        self.assertEqual([(r["place"], r["points"]) for r in ev["podium"]], [(1, "99.55"), (2, "88.23")])
        self.assertEqual({o["name"]: o.get("place") for o in ev["field"]}, {"Ivan Semenov": 1, "Petr Petrov": None})

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


class ScheduledToFinal(unittest.TestCase):
    """Прежний файл турнира собран до старта (всё scheduled, строк нет), потом табло выложило
    результаты и JudgesDetails: следующий проход обязан переписать файл — строки и final.
    Оба пути записи: полный сбор (build) и живой (live.protocols)."""

    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.fam = FAMILY_BUILD["isu"]
        self.path = os.path.join(self.dir, P.proto_name(self.fam["tid"]))
        self.start = dt.datetime(2026, 9, 17, 10, 0, tzinfo=MSK)
        self.before = self.start - dt.timedelta(hours=20)
        self.after = dt.datetime(2026, 10, 15, 23, 0, tzinfo=MSK)

    def women_kp(self):
        doc = P.load_doc(self.path)
        return P.find_segment(doc, "Junior Women", "КП")

    def stale_file(self):
        """Файл, как его собрал первый проход до старта: сегмент запланирован, строк нет."""
        events, _ = build_family("isu", self.dir, now=self.before)
        doc = P.load_doc(self.path)
        seg = P.find_segment(doc, "Junior Women", "КП")
        seg.update(state="scheduled", basis=None, judges=None, rows=[])
        seg.pop("panel", None)
        with open(self.path, "wb") as f:
            f.write(P.canonical(doc))
        self.assertEqual((self.women_kp()["state"], len(self.women_kp()["rows"])), ("scheduled", 0))
        return events

    def test_build_rewrites_scheduled_file(self):
        self.stale_file()
        _, summary = build_family("isu", self.dir, now=self.after)
        self.assertEqual(sum(summary.values()), 1)
        seg = self.women_kp()
        self.assertEqual((seg["state"], seg["basis"], len(seg["rows"])), ("final", "judges", 39))
        self.assertIn("els", seg["rows"][0])

    def test_live_rewrites_scheduled_file_even_for_segments_without_events(self):
        events = self.stale_file()
        for e in events:  # у события live — адреса табло, как в events.json
            self.assertTrue(e.get("live"))
        before = P.load_doc(self.path)
        # в календаре остался только один старт: у остальных сегментов событий нет
        only = [e for e in events if e["seg"] == "КП" and e["level"] == "junior" and e["kind"] == "women"]
        self.assertEqual(len(only), 1)
        with FixtureNet("isu"):
            fetcher = P.Fetcher(budget=live.BUDGET, timeout=live.TIMEOUT, tries=live.TRIES)
            spec = FAMILIES["isu"]
            idx = st.parse_index_page(_read(os.path.join(FIX, "isu", "index.htm")), spec["src"], spec["offset"])
            written = live.protocols(only, only, {only[0]["live"]["idx"]: idx}, nm.Names(None, {}),
                                     self.after, fetcher, self.dir)
        self.assertEqual(written, 1)
        seg = self.women_kp()
        self.assertEqual((seg["state"], len(seg["rows"])), ("final", 39))
        # будущие сегменты без событий остались «запланирован», а не «не опубликован»
        after = P.load_doc(self.path)
        states = lambda d: {(c["name"], sg["code"]): sg["state"] for c in d["categories"] for sg in c["segments"]}
        for key, state in states(before).items():
            if key != ("Junior Women", "КП"):
                self.assertEqual(states(after)[key], state, key)

    def test_segment_without_event_takes_time_from_board_not_state_none(self):
        # события есть только у мужского КП; мужской ПП (10.10) — в оглавлении табло со временем
        spec = FAMILIES["denistenmemorial"]
        now = dt.datetime(2026, 10, 9, 12, 0, tzinfo=dt.timezone(dt.timedelta(hours=5)))
        with FixtureNet("denistenmemorial"):
            idx = st.parse_index_page(_read(os.path.join(FIX, "denistenmemorial", "index.htm")),
                                      spec["src"], spec["offset"])
            events, _ = build_family("denistenmemorial", self.dir, now=now)
            only = [e for e in events if (e["kind"], e["level"], e["seg"]) == ("men", "senior", "КП")]
            self.assertEqual(len(only), 1)
            doc = live.tournament_doc(idx, only, nm.Names(None, {}), now,
                                      P.Fetcher(budget=live.BUDGET), None)
        seg = P.find_segment(doc, "Men", "ПП")
        self.assertEqual(seg["state"], "scheduled")
        self.assertTrue(seg["start"].startswith("2026-10-10T14:30"))


class Plan(unittest.TestCase):
    """live.plan: что делать циклу tools/live-loop.sh."""

    def ev(self, start, end, **live_extra):
        return {"live": dict({"idx": "i", "seg": "s", "basis": None}, **live_extra),
                "start": start.isoformat(), "end": end.isoformat(), "podium": None}

    def test_phases(self):
        t = dt.datetime(2026, 10, 16, 12, 0, tzinfo=MSK)
        h = dt.timedelta(hours=1)
        running = self.ev(t - h, t + h)
        self.assertEqual(live.plan([running], t), ("hot", 0))
        recent = self.ev(t - 3 * h, t - h)  # закончился час назад: ещё горячий
        self.assertEqual(live.plan([recent], t), ("hot", 0))
        old = self.ev(t - 10 * h, t - 8 * h)  # оценок так и нет: раз за запуск
        self.assertEqual(live.plan([old], t), ("cold", 0))
        soon = self.ev(t + dt.timedelta(minutes=40), t + 2 * h)
        self.assertEqual(live.plan([soon], t), ("wait", 25 * 60))  # до начала окна опроса (старт минус 15 минут)
        later = self.ev(t + 3 * h, t + 4 * h)  # в пределах горизонта: ждём, а не надеемся на cron
        self.assertEqual(live.plan([later], t), ("wait", 3 * 3600 - 15 * 60))
        far = self.ev(t + live.HORIZON + 2 * h, t + live.HORIZON + 3 * h)
        self.assertEqual(live.plan([far], t), ("none", 0))
        done = self.ev(t - 10 * h, t - 8 * h, basis="judges")
        done["podium"] = [{"place": 1}]
        self.assertEqual(live.plan([done], t), ("none", 0))
        self.assertEqual(live.plan([{"start": t.isoformat(), "end": t.isoformat()}], t), ("none", 0))

    def test_hot_flag_limits_active(self):
        t = dt.datetime(2026, 10, 16, 12, 0, tzinfo=MSK)
        old = self.ev(t - dt.timedelta(hours=10), t - dt.timedelta(hours=8))
        self.assertTrue(live.active(old, t))
        self.assertFalse(live.active(old, t, hot=True))

    def test_hot_events_go_first(self):
        """Утренний сегмент без итогов не должен остаться за бортом, но идущий опрашивается раньше."""
        t = dt.datetime(2026, 10, 16, 12, 0, tzinfo=MSK)
        h = dt.timedelta(hours=1)
        old = self.ev(t - 5 * h, t - 4 * h)
        running = self.ev(t - h, t + h)
        self.assertEqual(live.to_refresh([old, running], t, hot_only=False), [running, old])
        self.assertEqual(live.to_refresh([old, running], t, hot_only=True), [running])


def _isu_event(slug, sub, start, end, url=None):
    return {"event_id": "1" + str(abs(hash(slug)) % 1000), "slug": slug, "name": slug,
            "event_sub_type_name": sub, "from_date_utc": start, "to_date_utc": end,
            "time_zone": "Europe/Budapest", "city": "Budapest", "country_code": "HUN",
            "button_1_url": url, "buttons": []}


class IsuCalendar(unittest.TestCase):
    """Корень «файл Budapest не обновлялся»: страница календаря ISU, отрисованная на сервере, отдала
    список без Challenger Series, и турнир посреди проведения пропал из сборки, а с ним и запись
    его протокола. Календарь теперь — объединение страницы и API сезона."""

    BUDAPEST = _isu_event("isu-cs-budapest-trophy", "ISU Challenger Series", "2026-10-14T22:00:00.000Z",
                          "2026-10-18T21:59:59.000Z", "https://hunskate.hu/x/BudTrophy2026/index.htm")
    GP = _isu_event("isu-gp-skate-canada-international-2026", "ISU Grand Prix", "2026-10-30T07:00:00.000Z",
                    "2026-11-02T07:59:59.000Z")
    OPEN = _isu_event("budapest-open-2026", "International Competition", "2026-10-14T22:00:00.000Z",
                      "2026-10-18T21:59:59.000Z")

    def run_events(self, rsc=(), api=(), rsc_fails=False, api_fails=False):
        import json
        page = "RSC ... \"initialData\":" + json.dumps({"data": list(rsc)}) + ",\"x\":1"

        def fetch(url, *a, **k):
            if rsc_fails:
                raise net.FetchError("rsc", kind="timeout")
            return page

        def fetch_json(url, *a, **k):
            if api_fails:
                raise net.FetchError("api", kind="timeout")
            self.assertEqual(k["data"]["season"], "2026/2027")
            return {"data": list(api)}

        with mock.patch.object(net, "fetch", side_effect=fetch), \
                mock.patch.object(net, "fetch_json", side_effect=fetch_json):
            return {e["slug"]: e for e in isu.events(dt.date(2026, 10, 16))}

    def test_season_name(self):
        self.assertEqual(isu.season_name(dt.date(2026, 10, 16)), "2026/2027")
        self.assertEqual(isu.season_name(dt.date(2027, 3, 1)), "2026/2027")
        self.assertEqual(isu.season_name(dt.date(2027, 7, 1)), "2027/2028")

    def test_challenger_missing_on_page_comes_from_api(self):
        got = self.run_events(rsc=[self.GP], api=[self.BUDAPEST, self.GP, self.OPEN])
        self.assertEqual(set(got), {"isu-cs-budapest-trophy", "isu-gp-skate-canada-international-2026"})
        self.assertEqual(got["isu-cs-budapest-trophy"]["results_url"], "https://hunskate.hu/x/BudTrophy2026/index.htm")
        self.assertEqual(got["isu-cs-budapest-trophy"]["sub"], "ISU Challenger Series")

    def test_either_source_is_enough_both_failing_is_error(self):
        self.assertEqual(set(self.run_events(rsc=[self.BUDAPEST], api_fails=True)), {"isu-cs-budapest-trophy"})
        self.assertEqual(set(self.run_events(api=[self.BUDAPEST], rsc_fails=True)), {"isu-cs-budapest-trophy"})
        with self.assertRaises(net.FetchError):
            self.run_events(rsc_fails=True, api_fails=True)


class RunningTournaments(unittest.TestCase):
    """Идущий турнир, пропавший из источника, не теряет будущие старты прошлого сбора."""

    def ev(self, tid, start, end):
        return {"tid": tid, "start": start, "end": end}

    def test_running_and_vanished(self):
        now = dt.datetime(2026, 10, 16, 12, 0, tzinfo=MSK)
        prev = [self.ev("isu:budapest", "2026-10-16T09:00:00+03:00", "2026-10-16T09:55:00+03:00"),
                self.ev("isu:budapest", "2026-10-18T12:00:00+03:00", "2026-10-18T14:00:00+03:00"),
                self.ev("isu:nebelhorn", "2026-09-23T09:00:00+03:00", "2026-09-27T14:00:00+03:00"),
                self.ev("isu:later", "2026-10-30T09:00:00+03:00", "2026-11-01T14:00:00+03:00")]
        self.assertEqual(b.running_tids(prev, set(), now), {"isu:budapest"})
        self.assertEqual(b.running_tids(prev, {"isu:budapest"}, now), set())


class PagesMerge(unittest.TestCase):
    """Перед публикацией update.yml берёт с gh-pages протоколы, записанные live.yml за время полного сбора."""

    def setUp(self):
        import tempfile
        self.fresh, self.ours = tempfile.mkdtemp(), tempfile.mkdtemp()
        for d in (self.fresh, self.ours):
            self.addCleanup(shutil.rmtree, d, True)

    def put(self, d, name, built, rows):
        doc = {"v": 1, "tid": name, "built": built, "categories": [], "rows": rows}
        with open(os.path.join(d, name), "wb") as f:
            f.write(P.canonical(doc))

    def test_later_built_wins_and_set_is_ours(self):
        self.put(self.ours, "a.json", "2026-10-16T12:00:00+03:00", 1)   # наш старее
        self.put(self.fresh, "a.json", "2026-10-16T12:30:00+03:00", 2)
        self.put(self.ours, "b.json", "2026-10-16T12:30:00+03:00", 1)   # наш новее
        self.put(self.fresh, "b.json", "2026-10-16T12:00:00+03:00", 2)
        self.put(self.fresh, "gone.json", "2026-10-16T12:30:00+03:00", 3)  # такого у нас нет: не добавляем
        got = pages_merge.merge(self.fresh, self.ours, log=lambda *a: None)
        self.assertEqual(got, ["a.json"])
        self.assertEqual(P.load_doc(os.path.join(self.ours, "a.json"))["rows"], 2)
        self.assertEqual(P.load_doc(os.path.join(self.ours, "b.json"))["rows"], 1)
        self.assertFalse(os.path.exists(os.path.join(self.ours, "gone.json")))

    def test_status_per_tournament_by_checked(self):
        now = dt.datetime(2026, 10, 16, 12, 0, tzinfo=MSK)
        P.write_status(self.ours, {"t1": {"checked": "2026-10-16T10:00:00+03:00", "read_ok": None, "error": None},
                                   "t2": {"checked": "2026-10-16T11:00:00+03:00", "read_ok": None, "error": None}}, now)
        P.write_status(self.fresh, {"t1": {"checked": "2026-10-16T11:00:00+03:00", "read_ok": "x", "error": None},
                                    "t2": {"checked": "2026-10-16T10:00:00+03:00", "read_ok": None, "error": "net"}}, now)
        pages_merge.merge(self.fresh, self.ours, log=lambda *a: None)
        items = P.read_status(self.ours)
        self.assertEqual(items["t1"]["read_ok"], "x")
        self.assertIsNone(items["t2"]["error"])


if __name__ == "__main__":
    unittest.main()
