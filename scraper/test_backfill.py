"""Добор архива: коды турниров ISU, ссылки списка ФФККР, обход турнира (без сети)."""
import datetime as dt
import unittest
from unittest import mock

from scraper import backfill as bf
from scraper import net


def ev(name, sub, cc, frm, season="2021/2022"):
    return {"name": name, "event_sub_type_name": sub, "country_code": cc,
            "from_date": frm + "T00:00:00.000Z", "_season": season}


class CodesTest(unittest.TestCase):
    def test_seasons(self):
        s = bf.seasons(dt.date(2026, 11, 8))
        self.assertEqual(s[0], "2018/2019")
        self.assertEqual(s[-1], "2026/2027")
        self.assertEqual(len(s), 9)
        self.assertEqual(bf.seasons(dt.date(2027, 3, 1))[-1], "2026/2027")

    def test_season_dir(self):
        self.assertEqual(bf.season_dir("2018/2019"), "season1819")

    def test_simple_codes(self):
        self.assertEqual(bf.isu_codes(ev("ISU GP Skate America 2018", "ISU Grand Prix", "USA", "2018-10-19")), ["gpusa2018"])
        self.assertEqual(bf.isu_codes(ev("ISU JGP Canada 2018", "ISU Junior Grand Prix", "CAN", "2018-09-12")), ["jgpcan2018"])
        self.assertEqual(bf.isu_codes(ev("ISU European Championships 2019", "European Championships", "BLR", "2019-01-21")), ["ec2019"])
        self.assertEqual(bf.isu_codes(ev("ISU Four Continents Championships 2019", "Four Continents Championships", "USA", "2019-02-05")), ["fc2019"])
        self.assertEqual(bf.isu_codes(ev("ISU World Championships 2019", "World Championships", "JPN", "2019-03-18")), ["wc2019"])
        self.assertEqual(bf.isu_codes(ev("ISU World Junior Championships 2019", "World Junior Championships", "CRO", "2019-03-04")), ["wjc2019"])
        self.assertEqual(bf.isu_codes(ev("XXIV Olympic Winter Games 2022", "Olympic Games", "CHN", "2022-02-04")), ["owg2022"])
        self.assertEqual(bf.isu_codes(ev("ISU World Team Trophy 2019", "International Competition", "JPN", "2019-04-11")), ["wtt2019"])

    def test_final(self):
        e = ev("ISU Grand Prix Final 2018/2019", "ISU Grand Prix Final", "CAN", "2018-12-05", "2018/2019")
        self.assertEqual(bf.isu_kind(e), "gpf")
        self.assertEqual(bf.isu_codes(e), ["gpf1819", "gpf2018"])
        j = ev("ISU Junior Grand Prix Final 2018/19", "ISU Junior Grand Prix Final", "CAN", "2018-12-06", "2018/2019")
        self.assertEqual(bf.isu_kind(j), "jgpf")
        self.assertEqual(bf.isu_codes(j)[0], "jgpf1819")
        # в сезоне 2025/26 финал числится среди «ISU Grand Prix»
        g = ev("ISU Grand Prix of Figure Skating Final 2025", "ISU Grand Prix", "JPN", "2025-12-04", "2025/2026")
        self.assertEqual(bf.isu_kind(g), "gpf")
        self.assertIn("gpf2025", bf.isu_codes(g))

    def test_duplicate_country(self):
        e = ev("ISU JGP Courchevel (2) 2021", "ISU Junior Grand Prix", "FRA", "2021-08-25")
        codes = bf.isu_codes(e, dup=2, n=1)
        self.assertEqual(codes[:2], ["jgpfra2021", "jgpfra22021"])
        self.assertIn("jgpfra12021", codes)

    def test_skipped_kinds(self):
        for sub in ("ISU Challenger Series", "International Competition", "Solo Ice Dance", ""):
            self.assertIsNone(bf.isu_kind(ev("Lombardia Trophy 2021", sub, "ITA", "2021-09-11")))
            self.assertEqual(bf.isu_codes(ev("Lombardia Trophy 2021", sub, "ITA", "2021-09-11")), [])

    def test_not_ours(self):
        self.assertIsNone(bf.isu_kind(ev("Winter Youth Olympic Games 2024", "Olympic Games", "KOR", "2024-01-19")))
        self.assertIsNone(bf.isu_kind(ev("ISU World Synchronized Championships 2020", "World Championships", "FRA", "2020-04-03")))
        self.assertEqual(bf.isu_kind(ev("ISU World Figure Skating Team Trophy", "World Championships", "JPN", "2027-04-01")), "wtt")

    def test_page_dates(self):
        page = "<p>Courchevel / FRA 25.08.2021 - 28.08.2021</p>"
        self.assertEqual(bf._page_dates(page), (dt.date(2021, 8, 25), dt.date(2021, 8, 28)))
        e = ev("x", "ISU Junior Grand Prix", "FRA", "2021-08-25")
        self.assertTrue(bf._date_ok(page, e))
        self.assertFalse(bf._date_ok(page, ev("x", "", "FRA", "2021-08-18")))
        self.assertTrue(bf._date_ok("без дат", e))
        # Олимпиада: на странице считается с командного турнира, раньше официального начала
        oly = dict(ev("x", "Olympic Games", "CHN", "2022-02-04"), to_date="2022-02-20T23:59:59.000Z")
        self.assertTrue(bf._date_ok("27.01.2022 - 20.02.2022", oly))

    def test_display_name(self):
        self.assertEqual(bf.display_name(ev("ISU World Championships 2019", "World Championships", "JPN", "2019-03-18")),
                         "Чемпионат мира 2019")
        g = ev("ISU Grand Prix of Figure Skating Final 2025", "ISU Grand Prix", "JPN", "2025-12-04", "2025/2026")
        self.assertEqual(bf.display_name(g), "Финал Гран-при 2025")

    def test_discover_isu_mocked(self):
        """Сквозной обход с подменой сети: второй JGP одной страны находится по варианту с «2»."""
        events = [ev("ISU JGP Courchevel 2021", "ISU Junior Grand Prix", "FRA", "2021-08-18"),
                  ev("ISU JGP Courchevel (2) 2021", "ISU Junior Grand Prix", "FRA", "2021-08-25"),
                  ev("Lombardia Trophy 2021", "International Competition", "ITA", "2021-09-11")]
        pages = {
            "season2122/jgpfra2021/": "FRA 18.08.2021 - 21.08.2021",
            "season2122/jgpfra22021/": "FRA 25.08.2021 - 28.08.2021",
        }

        def fetch(url, **kw):
            for k, v in pages.items():
                if k in url:
                    return v
            raise net.FetchError("404", kind="http", status=404)

        def fetch_json(url, data=None, **kw):
            return {"data": events if data["season"] == "2021/2022" else []}

        with mock.patch.object(bf.net, "fetch", fetch), mock.patch.object(bf.net, "fetch_json", fetch_json), \
                mock.patch.object(bf, "pause", lambda: None), \
                mock.patch.object(bf.st, "parse_index_page", lambda page, url: {"categories": [1]}), \
                mock.patch.object(bf, "seasons", lambda today=None: ["2021/2022"]):
            found, missing, skipped = bf.discover_isu()
        self.assertEqual([f["code"] for f in found], ["jgpfra2021", "jgpfra22021"])
        self.assertEqual([f["start"] for f in found], ["2021-08-18", "2021-08-25"])
        self.assertEqual(missing, [])
        self.assertEqual(skipped, {"International Competition": 1})


LIST_PAGE = """
<a href="/sorevnovaniya/sorevnovaniya/rss">rss</a><a href="/sorevnovaniya/sorevnovaniya/atom">atom</a>
<a href="/sorevnovaniya/sorevnovaniya/chempionat-rossii-2026">A</a>
<a href="/sorevnovaniya/sorevnovaniya/chempionat-rossii-2026">dup</a>
<a href="/sorevnovaniya/sorevnovaniya/pervenstvo-rossii-sinhronnoe-katanie-2026?x=1">B</a>
<a href="/sorevnovaniya/sorevnovaniya/page-2">2</a><a href="/sorevnovaniya/sorevnovaniya/page-64">64</a>
<a href="/sorevnovaniya/sorevnovaniya/kubok-2021#top">C</a>
"""


class FsrTest(unittest.TestCase):
    def test_list_links(self):
        self.assertEqual(bf.list_links(LIST_PAGE), [
            "https://fsrussia.ru/sorevnovaniya/sorevnovaniya/chempionat-rossii-2026",
            "https://fsrussia.ru/sorevnovaniya/sorevnovaniya/pervenstvo-rossii-sinhronnoe-katanie-2026",
            "https://fsrussia.ru/sorevnovaniya/sorevnovaniya/kubok-2021",
        ])

    def test_synchro(self):
        self.assertTrue(bf.is_synchro("Первенство России по синхронному катанию"))
        self.assertTrue(bf.is_synchro("https://fsrussia.ru/sorevnovaniya/sorevnovaniya/x-sinhronnoe-katanie"))
        self.assertFalse(bf.is_synchro("Чемпионат России"))

    def test_jgp_title(self):
        self.assertTrue(bf.is_jgp_title("Первенство России. Гран-при России «Сириус»"))
        self.assertTrue(bf.is_jgp_title("x", "https://fsrussia.ru/results/2425/2etap_jun/index.htm"))
        self.assertFalse(bf.is_jgp_title("Чемпионат России"))

    def test_single_day(self):
        page = "<b>Сроки проведения: &nbsp;02 мая 2026 года </b>"
        self.assertEqual(bf.single_day(page), dt.date(2026, 5, 2))
        self.assertIsNone(bf.single_day("нет"))

    def test_season_of(self):
        self.assertEqual(bf.season_of(dt.date(2019, 1, 5)), "2018/2019")
        self.assertEqual(bf.season_of(dt.date(2019, 7, 1)), "2019/2020")

    def test_discover_fsr_mocked(self):
        calls = []

        def fetch(url, **kw):
            calls.append(url)
            if url.endswith("/sorevnovaniya"):
                return LIST_PAGE
            raise net.FetchError("302", kind="http", status=302)

        def tournament(u):
            return {"title": "Чемпионат России 2026", "results": "https://fsrussia.ru/results/2526/CR/",
                    "start": dt.date(2025, 12, 20) if "2026" in u else dt.date(2018, 5, 1), "end": None}

        with mock.patch.object(bf.net, "fetch", fetch), mock.patch.object(bf, "pause", lambda: None), \
                mock.patch.object(bf.fsr, "tournament", tournament):
            out, stat = bf.discover_fsr()
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["url"], "https://fsrussia.ru/results/2526/CR/index.htm")
        self.assertEqual(out[0]["ev"], "Чемпионат России")
        self.assertEqual(out[0]["season"], "2025/2026")
        self.assertEqual((stat["old"], stat["synchro"]), (1, 1))

    def test_discover_fsr_skips_repeated_page(self):
        """page-3 повторяет page-2 — идём дальше; три повтора подряд — конец."""
        a = '<a href="/sorevnovaniya/sorevnovaniya/a-2026">x</a>'
        b = '<a href="/sorevnovaniya/sorevnovaniya/b-2026">x</a>'
        c = '<a href="/sorevnovaniya/sorevnovaniya/c-2026">x</a>'
        pages = {"/sorevnovaniya": a, "page-2": b, "page-3": b, "page-4": c}

        def fetch(url, **kw):
            for k, v in pages.items():
                if url.endswith(k):
                    return v
            return b

        tour = lambda u: {"title": "Т", "results": "https://fsrussia.ru/results/x/", "start": dt.date(2026, 1, 1), "end": None}
        with mock.patch.object(bf.net, "fetch", fetch), mock.patch.object(bf, "pause", lambda: None), \
                mock.patch.object(bf.fsr, "tournament", tour):
            out, stat = bf.discover_fsr()
        self.assertEqual(len(out), 3)
        self.assertEqual(stat["pages"], 3)


class StubArchive:
    def __init__(self):
        self.urls, self.rows = set(), []

    def load(self):
        return {}

    def has(self, arc, u):
        return u in self.urls

    def ingest(self, arc, skaters, meta):
        self.urls.add(meta["u"])
        self.rows.append((len(skaters), meta))

    def save(self, arc):
        pass


class IngestTest(unittest.TestCase):
    def test_ingest_event(self):
        seg = lambda n, pdf, start=None: {"name": n, "judges_pdf": pdf, "start": start}
        cat = {"name": "Men", "segments": [
            seg("Short Program", "http://x/a.pdf", dt.datetime(2020, 1, 2, 18, 0)),
            seg("Free Skating", "http://x/b.pdf"),
            seg("Free Skating", None),
        ]}
        idx = {"categories": [cat]}
        ar = StubArchive()
        ar.urls.add("http://x/b.pdf")
        stats = bf.new_stats()
        item = {"url": "http://x/index.htm", "intl": True, "ev": "Чемпионат мира 2020", "start": "2020-01-01", "src": "ISU"}
        with mock.patch.object(bf.st, "parse_index", lambda u: idx), mock.patch.object(bf, "pause", lambda: None), \
                mock.patch.object(bf.net, "pdf_text", lambda u: "t"), \
                mock.patch.object(bf.st, "parse_judges", lambda t: [{"name": "A"}, {"name": "B"}]):
            bf.ingest_event(ar, {}, item, stats)
        self.assertEqual((stats["segments"], stats["skaters"], stats["have"]), (1, 2, 1))
        meta = ar.rows[0][1]
        self.assertEqual((meta["d"], meta["seg"], meta["kind"], meta["level"]), ("2020-01-02", "КП", "men", "senior"))

    def test_bad_index_does_not_crash(self):
        stats = bf.new_stats()
        item = {"url": "http://x/index.htm", "intl": False, "ev": "e", "start": "2020-01-01", "src": "ФФККР"}
        with mock.patch.object(bf.st, "parse_index", mock.Mock(side_effect=net.FetchError("boom"))):
            bf.ingest_event(StubArchive(), {}, item, stats)
        self.assertEqual(len(stats["index_errors"]), 1)


if __name__ == "__main__":
    unittest.main()
