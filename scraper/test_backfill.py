"""Добор архива: коды турниров ISU, ссылки списка ФФККР, обход турнира (без сети)."""
import datetime as dt
import os
import tempfile
import unittest
from unittest import mock

from scraper import archive as real_ar
from scraper import backfill as bf
from scraper import net

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "isu_comnet_index.htm")
COMNET_URL = "https://results.isu.org/results/season2324/jgpjpn2023/index.htm"


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

    def test_skip_event(self):
        """Любители, балеты на льду и синхронное катание — по названию и по адресам латиницей."""
        for t in ("Первенство России по синхронному катанию",
                  "https://fsrussia.ru/sorevnovaniya/sorevnovaniya/x-sinhronnoe-katanie",
                  "http://skate63.ru/results/2324/SinchroKMS2024/index.htm",
                  "http://skate63.ru/results/2425/Synchro_Syzrany2025_1sp/index.htm",
                  "https://skate63.ru/results/2526/Syzranochka_2026_synkh_KMC_1razr/index.htm",
                  'Всероссийское физкультурное мероприятие "Кубок Федерации" среди балетов на льду',
                  "https://fsrussia.ru/results/2526/1etap2026_ballet/index.htm",
                  "Финал Кубка Федерации среди взрослых любителей",
                  "https://fsrussia.ru/results/2526/1etap2026_adult/index.htm"):
            self.assertTrue(bf.skip_event(t), t)
        for t in ("Чемпионат России", "https://fsrussia.ru/results/2526/rusnat2526/index.htm",
                  "https://fsrussia.ru/results/1819/olimpic_hopes1819/ss/index.htm",
                  "https://fsrussia.ru/results/1819/samarochka2019/sys/index.htm",
                  "http://www.fschelresults.ru/results/season2324/45_Romarovski/index.htm"):
            self.assertFalse(bf.skip_event(t), t)
        self.assertTrue(bf.skip_event("Финал Кубка России", None, "…/Synchro_Samara2025_FEST/index.htm"))

    def test_jgp_title(self):
        self.assertTrue(bf.is_jgp_title("Первенство России. Гран-при России «Сириус»"))
        self.assertTrue(bf.is_jgp_title("x", "https://fsrussia.ru/results/2425/2etap_jun/index.htm"))
        self.assertTrue(bf.is_jgp_title("x", "https://fsrussia.ru/results/2223/1etap/jun/index.htm"))
        self.assertFalse(bf.is_jgp_title("x", "https://fsrussia.ru/results/2223/1etap/sen/index.htm"))
        self.assertFalse(bf.is_jgp_title("Чемпионат России"))

    def test_past_title(self):
        """Заголовки страниц ФФККР прошлых сезонов, как они есть на сайте, → название в приложении."""
        r = "https://fsrussia.ru/results/"
        for full, url, want in [
            ("Ростелеком - Чемпионат России 2019", "http://www.fsrussia.ru/results/1819/rusnat1819_ENG/index.htm",
             "Чемпионат России"),
            ("Чемпионат России 2026", r + "2526/rusnat2526/index.htm", "Чемпионат России"),
            ("Первенство России среди юниоров 2020", "http://www.fsrussia.ru/results/1920/junnat1920/ENG/index.htm",
             "Первенство России среди юниоров"),
            ("Кубок России - Ростелеком 2018-2019 гг. 4-й этап", r + "1819/4etap/index.htm", "4 этап Кубка России"),
            ("1 этап Кубка России - Ростелеком", r + "2122/1etap/index.htm", "1 этап Кубка России"),
            ("Финал Кубка России - Ростелеком 2018-2019", r + "1819/cor1819/index.htm", "Финал Кубка России"),
            ('Финал Кубка России "Гран При России"', r + "2223/cor/sen/index.htm", "Финал Гран-при России"),
            ('Всероссийские соревнования "Гран При России Золотой конек Москвы"', r + "2223/1etap/sen/index.htm",
             "Гран-при России «Золотой конек Москвы»"),
            ('Всероссийские соревнования "Гран При России Идель-2022"', r + "2223/3etap/sen/index.htm",
             "Гран-при России «Идель»"),
            ("Всероссийские соревнования “Золотой конек Москвы” среди юниоров", r + "2223/1etap/jun/index.htm",
             "ЮГП России «Золотой конек Москвы»"),
            ('Всероссийские соревнования "Идель-2023 памяти ЗТР Г.С. Тарасова" среди юниоров',
             r + "2324/4etap/jun/index.htm", "ЮГП России «Идель»"),
            ('Всероссийские соревнования "Ростелеком Гран При России - Край курая"', r + "2324/1etap/sen/index.htm",
             "Гран-при России «Край курая»"),
            ('Всероссийские соревнования "Ростелеком Гран При России - Идель-2024"', r + "2425/2etap/index.htm",
             "Гран-при России «Идель»"),
            ('Всероссийские соревнования “Ростелеком Гран При России – Звезды Магнитки"', r + "2425/1etap/index.htm",
             "Гран-при России «Звезды Магнитки»"),
            ('Всероссийские соревнования "Гран При России – Невский лед"', r + "2627/2etap_sen/index.htm",
             "Гран-при России «Невский лёд»"),
            ('Всероссийские соревнования "Лед Мечты" среди юниоров', r + "2425/1etap_jun/index.htm",
             "ЮГП России «Лёд Мечты»"),
            ('Международные соревнования "Кубок Содружества"', r + "2526/commonwealth_cup2026/index.htm",
             "Кубок Содружества"),
            ('Всероссийское физкультурное мероприятие "Возрождение"', "https://skate63.ru/results/2526/NVFM/index.htm",
             "Возрождение"),
            ('ВС "Кубок Мечты"', r + "2627/mechta_2026_sys/index.htm", "Кубок Мечты"),
            ("Всероссийские соревнования памяти ЗРФК П.Я. Ромаровского",
             "http://www.fschelresults.ru/results/season2324/45_Romarovski/index.htm", "Памяти Ромаровского"),
            ('Всероссийские соревнования "Мемориал ЗМС СССР, первого отечественного чемпиона мира С.Волкова"',
             r + "2526/volkov_memorial2026/index.htm", "Мемориал Волкова"),
            ('Всероссийские соревнования "Памяти Олимпийского чемпиона С.Гринькова"',
             "https://ffkm.ru/results/2026-2027/2026-09-19_vsgrinkov/index.htm", "Памяти Гринькова"),
            ("Мордовские узоры 2019", r + "1920/mordovian_ornament2019/index.htm", "Мордовские узоры"),
            ('Всероссийские соревнования "Мемориал С.А. Жука" среди мальчиков и девочек (младший возраст)',
             r + "2122/mlvoz2122/index.htm",
             'Всероссийские соревнования "Мемориал С.А. Жука" среди мальчиков и девочек (младший возраст)'),
        ]:
            self.assertEqual(bf.past_title(full, url), want, full)

    def test_clean_ru_name_memorial(self):
        """Мемориал с должностями и инициалами: титулы и «С.Н.» уходят, фамилия остаётся."""
        from scraper import build
        self.assertEqual(build.clean_ru_name("Мемориал ЗТ СССР, первого отечественного чемпиона мира С.Н. Волкова"),
                         "Мемориал Волкова")

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
        self.assertEqual((stat["old"], stat["skip"]), (1, 1))

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


class ScoresTest(unittest.TestCase):
    PAGE = """<table>
<tr><td>Men</td><td><a href=CAT001EN.HTM>Entries</a></td></tr>
<tr><td>Short</td><td><a href=SEG001.HTM>x</a></td><td><a href=gpusa2018_Men_SP_Scores.pdf>Judges Scores</a></td></tr>
<tr><td>Free</td><td><a href="SEG002.HTM">x</a></td><td><a href="gpusa2018_Men_FS_Scores.pdf">Judges Scores</a></td></tr>
<tr><td>A</td><td><a href=SEG003.HTM>x</a></td><td><a href=shared_Scores.pdf>s</a></td></tr>
<tr><td>B</td><td><a href=SEG004.HTM>x</a></td><td><a href=shared_Scores.pdf>s</a></td></tr>
</table>"""

    def test_scores_links(self):
        got = bf.scores_links(self.PAGE, "http://h/r/e/index.htm")
        self.assertEqual(got, {"http://h/r/e/seg001.htm": "http://h/r/e/gpusa2018_Men_SP_Scores.pdf",
                               "http://h/r/e/seg002.htm": "http://h/r/e/gpusa2018_Men_FS_Scores.pdf"})


def comnet_page():
    with open(FIXTURE, encoding="utf-8") as f:
        return f.read()


class ComnetTest(unittest.TestCase):
    BASE = "https://results.isu.org/results/season2324/jgpjpn2023/"

    def test_index(self):
        idx = bf.comnet_index(comnet_page(), COMNET_URL)
        self.assertEqual([c["name"] for c in idx["categories"]], ["Junior Men", "Junior Ice Dance"])
        men, dance = idx["categories"]
        self.assertEqual([s["name"] for s in men["segments"]], ["Short Program", "Free Skating"])
        self.assertEqual(men["segments"][0], {"name": "Short Program", "url": self.BASE + "data0103.htm",
                                              "judges_pdf": self.BASE + "data0103.pdf",
                                              "start": dt.datetime(2023, 9, 14, 18, 20)})
        self.assertEqual(men["segments"][1]["judges_pdf"], self.BASE + "data0105.pdf")
        self.assertEqual(men["segments"][1]["start"], dt.datetime(2023, 9, 15, 19, 10))
        self.assertEqual([s["name"] for s in dance["segments"]], ["Rhythm Dance", "Free Dance"])
        # дата с rowspan действует на вторую строку; чужие категории и «Entries» не примешиваются
        self.assertEqual(dance["segments"][0]["start"], dt.datetime(2023, 9, 14, 16, 0))
        self.assertEqual(dance["segments"][1]["start"], dt.datetime(2023, 9, 16, 12, 30))

    def test_names_recognised(self):
        from scraper import build
        for c in bf.comnet_index(comnet_page(), COMNET_URL)["categories"]:
            kind, level = build.cat_en(c["name"])
            self.assertIsNotNone(kind)
            self.assertEqual(level, "junior")
            for s in c["segments"]:
                self.assertIsNotNone(build.seg_code(s["name"]))

    def test_case_and_no_pdf(self):
        page = comnet_page().replace('<A HREF="data0105.pdf" target="_blank">Judges Score (pdf)</A>', "")
        page = page.replace("<A HREF=", "<a href=").replace("</A>", "</a>").replace("<TR", "<tr").replace("</TR>", "</tr>")
        page = page.replace("<TD", "<td").replace("</TD>", "</td>")
        idx = bf.comnet_index(page, COMNET_URL)
        segs = idx["categories"][0]["segments"]
        self.assertTrue(segs[0]["judges_pdf"].endswith("data0103.pdf"))
        self.assertFalse(segs[1].get("judges_pdf"))

    def test_not_comnet(self):
        self.assertEqual(bf.comnet_index("<html><table><tr><td>x</td></tr></table></html>", COMNET_URL), {"categories": []})

    def test_probe_accepts(self):
        e = ev("x", "Junior", "JPN", "2023-09-14", "2023/2024")
        e["to_date"] = "2023-09-16"
        with mock.patch.object(bf.net, "fetch", lambda u, **k: comnet_page()), mock.patch.object(bf, "pause", lambda: None):
            self.assertEqual(bf._probe("2023/2024", "jgpjpn2023", e), (COMNET_URL, "ok"))

    def test_probe_still_rejects_unknown(self):
        e = ev("x", "Junior", "JPN", "2023-09-14", "2023/2024")
        with mock.patch.object(bf.net, "fetch", lambda u, **k: "<html>без таблиц</html>"), mock.patch.object(bf, "pause", lambda: None):
            self.assertEqual(bf._probe("2023/2024", "x", e), (None, "старый формат"))

    def test_ingest_event(self):
        ar = real_ar
        arc = ar.empty()
        stats = bf.new_stats()
        item = {"url": COMNET_URL, "intl": True, "ev": "ЮГП Осака", "start": "2023-09-14", "src": "ISU"}
        skater = {"rank": 1, "name": "Test SKATER", "nation": "JPN", "tss": 100.0, "tes": 50.0, "pcs": 50.0, "ded": 0.0,
                  "elements": [], "components": []}
        with mock.patch.object(bf.net, "fetch", lambda u, **k: comnet_page()), mock.patch.object(bf, "pause", lambda: None), \
                mock.patch.object(bf.net, "pdf_text", lambda u: "t"), \
                mock.patch.object(bf.st, "parse_judges", lambda t: [skater]):
            bf.ingest_event(ar, arc, item, stats)
        self.assertEqual(stats["segments"], 4)
        self.assertEqual(stats["index_errors"], [])
        self.assertEqual(len(arc["segs"]), 4)
        self.assertTrue(ar.has(arc, "https://results.isu.org/results/season2324/jgpjpn2023/data0103.pdf"))
        meta = [s for s in arc["segs"] if s[0].endswith("data0103.pdf")][0]
        self.assertEqual((meta[2], meta[3], meta[4], meta[5]), ("2023-09-14", "men", "junior", "КП"))


class StubArchive:
    def __init__(self):
        self.urls, self.rows = set(), []

    def load(self, path=None):
        return {}

    def has(self, arc, u):
        return u in self.urls

    def ingest(self, arc, skaters, meta):
        self.urls.add(meta["u"])
        self.rows.append((len(skaters), meta))

    def save(self, arc, path=None):
        pass


class IngestTest(unittest.TestCase):
    def test_ingest_event(self):
        seg = lambda n, pdf, start=None: {"name": n, "judges_pdf": pdf, "start": start, "url": "http://x/SEG9.htm"}
        cat = {"name": "Men", "segments": [
            seg("Short Program", "http://x/a.pdf", dt.datetime(2020, 1, 2, 18, 0)),
            seg("Free Skating", "http://x/b.pdf"),
            seg("Free Skating", None),
            {"name": "Short Program", "judges_pdf": None, "start": None, "url": "http://x/SEG7.htm"},
        ]}
        idx = {"categories": [cat]}
        ar = StubArchive()
        ar.urls.add("http://x/b.pdf")
        stats = bf.new_stats()
        item = {"url": "http://x/index.htm", "intl": True, "ev": "Чемпионат мира 2020", "start": "2020-01-01", "src": "ISU"}
        with mock.patch.object(bf.net, "fetch", lambda u, **k: ""), \
                mock.patch.object(bf, "scores_links", lambda p, u: {"http://x/seg7.htm": "http://x/c_Scores.pdf"}), \
                mock.patch.object(bf.st, "parse_index_page", lambda p, u: idx), mock.patch.object(bf, "pause", lambda: None), \
                mock.patch.object(bf.net, "pdf_text", lambda u: "t"), \
                mock.patch.object(bf.st, "parse_judges", lambda t: [{"name": "A"}, {"name": "B"}]):
            bf.ingest_event(ar, {}, item, stats)
        self.assertEqual((stats["segments"], stats["skaters"], stats["have"]), (2, 4, 1))
        self.assertIn("http://x/c_Scores.pdf", ar.urls)
        meta = ar.rows[0][1]
        self.assertEqual((meta["d"], meta["seg"], meta["kind"], meta["level"]), ("2020-01-02", "КП", "men", "senior"))

    def test_english_ffkkr_index(self):
        """Табло ФФККР в английской версии: Russian-классификатор молчит, берём английский."""
        idx = {"categories": [{"name": "Ladies", "segments": [
            {"name": "Short Program", "judges_pdf": "http://x/l.pdf", "start": None, "url": "http://x/SEG1.htm"}]}]}
        ar = StubArchive()
        stats = bf.new_stats()
        item = {"url": "http://x/ENG/index.htm", "intl": False, "ev": "Чемпионат России", "start": "2020-01-01", "src": "ФФККР"}
        with mock.patch.object(bf.net, "fetch", lambda u, **k: ""), mock.patch.object(bf, "scores_links", lambda p, u: {}), \
                mock.patch.object(bf.st, "parse_index_page", lambda p, u: idx), mock.patch.object(bf, "pause", lambda: None), \
                mock.patch.object(bf.net, "pdf_text", lambda u: "t"), \
                mock.patch.object(bf.st, "parse_judges", lambda t: [{"name": "A"}]):
            bf.ingest_event(ar, {}, item, stats)
        self.assertEqual(stats["segments"], 1)
        self.assertEqual(ar.rows[0][1]["kind"], "women")

    def test_skip_not_downloaded(self):
        """Протокол из skip (его уже взял сбор) не скачивается, но считается в have."""
        seg = {"name": "Short Program", "judges_pdf": "http://x/a.pdf", "start": None, "url": "http://x/SEG1.htm"}
        idx = {"categories": [{"name": "Men", "segments": [seg]}]}
        ar = StubArchive()
        stats = bf.new_stats()
        item = {"url": "http://x/index.htm", "intl": True, "ev": "e", "start": "2020-01-01", "src": "ISU"}
        pdf_text = mock.Mock(return_value="t")
        with mock.patch.object(bf.net, "fetch", lambda u, **k: ""), mock.patch.object(bf, "scores_links", lambda p, u: {}), \
                mock.patch.object(bf.st, "parse_index_page", lambda p, u: idx), mock.patch.object(bf, "pause", lambda: None), \
                mock.patch.object(bf.net, "pdf_text", pdf_text):
            bf.ingest_event(ar, {}, item, stats, skip=("http://x/a.pdf",))
        pdf_text.assert_not_called()
        self.assertEqual((stats["have"], stats["segments"]), (1, 0))
        self.assertEqual(ar.rows, [])

    def test_russian_low_category_not_archived(self):
        """Не-международный турнир: «Женщины, новички» отсекает people._SKIP_CAT, «Женщины, МС» — нет."""
        from scraper import build
        seg = lambda pdf: {"name": "Short Program", "judges_pdf": pdf, "start": None, "url": "http://x/SEG1.htm"}
        idx = {"categories": [{"name": "Женщины, новички", "segments": [seg("http://x/n.pdf")]},
                              {"name": "Женщины, МС", "segments": [seg("http://x/ms.pdf")]}]}
        # без фильтра обе категории прошли бы классификацию
        self.assertEqual(len(build.categories_of(idx, False)), 2)
        ar = StubArchive()
        stats = bf.new_stats()
        item = {"url": "http://x/index.htm", "intl": False, "ev": "Чемпионат России", "start": "2020-01-01", "src": "ФФККР"}
        with mock.patch.object(bf.net, "fetch", lambda u, **k: ""), mock.patch.object(bf, "scores_links", lambda p, u: {}), \
                mock.patch.object(bf.st, "parse_index_page", lambda p, u: idx), mock.patch.object(bf, "pause", lambda: None), \
                mock.patch.object(bf.net, "pdf_text", lambda u: "t"), \
                mock.patch.object(bf.st, "parse_judges", lambda t: [{"name": "A"}]):
            bf.ingest_event(ar, {}, item, stats)
        self.assertEqual([m["u"] for _, m in ar.rows], ["http://x/ms.pdf"])

    def test_english_low_category_not_archived(self):
        """«Girls Basic Novice» в английской версии табло ФФККР — тоже не в архиве (имя проверяется
        и до перевода латиницы в кириллицу people._HOMO, иначе «basic»/«novice» не нашлись бы)."""
        seg = {"name": "Short Program", "judges_pdf": "http://x/g.pdf", "start": None, "url": "http://x/SEG1.htm"}
        idx = {"categories": [{"name": "Girls Basic Novice", "segments": [seg]}]}
        ar = StubArchive()
        stats = bf.new_stats()
        item = {"url": "http://x/ENG/index.htm", "intl": False, "ev": "Чемпионат России", "start": "2020-01-01", "src": "ФФККР"}
        with mock.patch.object(bf.net, "fetch", lambda u, **k: ""), mock.patch.object(bf, "scores_links", lambda p, u: {}), \
                mock.patch.object(bf.st, "parse_index_page", lambda p, u: idx), mock.patch.object(bf, "pause", lambda: None), \
                mock.patch.object(bf.net, "pdf_text", lambda u: "t"), \
                mock.patch.object(bf.st, "parse_judges", lambda t: [{"name": "A"}]):
            bf.ingest_event(ar, {}, item, stats)
        self.assertEqual(ar.rows, [])

    def test_bad_index_does_not_crash(self):
        stats = bf.new_stats()
        item = {"url": "http://x/index.htm", "intl": False, "ev": "e", "start": "2020-01-01", "src": "ФФККР"}
        with mock.patch.object(bf.net, "fetch", mock.Mock(side_effect=net.FetchError("boom"))):
            bf.ingest_event(StubArchive(), {}, item, stats)
        self.assertEqual(len(stats["index_errors"]), 1)


class RunTest(unittest.TestCase):
    def _fetcher(self, only_men=False):
        page = comnet_page()
        skater = {"rank": 1, "name": "Test SKATER", "nation": "JPN", "tss": 100.0, "tes": 50.0, "pcs": 50.0, "ded": 0.0,
                  "elements": [], "components": []}
        return mock.patch.object(bf.net, "fetch", lambda u, **k: page), skater

    def _run(self, items, path, **kw):
        fetch, skater = self._fetcher()
        with fetch, mock.patch.object(bf, "pause", lambda: None), mock.patch.object(bf.net, "pdf_text", lambda u: "t"), \
                mock.patch.object(bf.st, "parse_judges", lambda t: [skater]):
            return bf.run(real_ar, items, path=path, **kw)

    def test_run_writes_to_path_only(self):
        item = {"src": "ISU", "season": "2023/2024", "ev": "ЮГП Осака", "start": "2023-09-14", "url": COMNET_URL, "intl": True}
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "part.json")
            fake_main = os.path.join(d, "archive.json")
            with mock.patch.object(real_ar, "ARCHIVE", fake_main), mock.patch.object(real_ar, "PAST", os.path.join(d, "past.json")):
                stats = self._run([item], out)
                self.assertEqual(stats["segments"], 4)
                self.assertEqual(len(real_ar.load(out)["segs"]), 4)
                self.assertFalse(os.path.exists(fake_main))
                self.assertFalse(os.path.exists(os.path.join(d, "past.json")))
                # по умолчанию — PAST, ARCHIVE по-прежнему не тронут
                self._run([item], None)
                self.assertEqual(len(real_ar.load(os.path.join(d, "past.json"))["segs"]), 4)
                self.assertFalse(os.path.exists(fake_main))

    def test_run_resumes(self):
        item = {"src": "ISU", "season": "2023/2024", "ev": "ЮГП Осака", "start": "2023-09-14", "url": COMNET_URL, "intl": True}
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "part.json")
            self._run([item], out)
            again = self._run([item], out)
            self.assertEqual((again["segments"], again["have"]), (0, 4))

    def test_shard(self):
        items = list(range(7))
        self.assertEqual(bf.shard(items, "0/3"), [0, 3, 6])
        self.assertEqual(bf.shard(items, "2/3"), [2, 5])
        for bad in ("3/3", "-1/2", "1", "a/b", "0/0"):
            with self.assertRaises(ValueError):
                bf.shard(items, bad)

    def test_merge_command(self):
        def part(path, urls):
            arc = real_ar.empty()
            for u, name in urls:
                real_ar.ingest(arc, [{"rank": 1, "name": name, "nation": "JPN", "tss": 1.0, "tes": 1.0, "pcs": 1.0,
                                      "ded": 0.0, "components": [],
                                      "elements": [{"code": "3A", "info": "", "base": 8.0, "goe": 1.0, "judges": [1, 1, 1],
                                                    "score": 9.0}]}],
                               {"u": u, "ev": "e", "d": "2023-01-01", "kind": "men", "level": "senior", "seg": "КП", "src": "ISU"})
            real_ar.save(arc, path)

        with tempfile.TemporaryDirectory() as d:
            a, b, out = (os.path.join(d, x) for x in ("a.json", "b.json", "out.json"))
            part(a, [("http://x/1.pdf", "Aaa AAA")])
            part(b, [("http://x/2.pdf", "Bbb BBB")])
            self.assertEqual(bf.main(["merge", a, b, "--out", out]), 0)
            got = real_ar.load(out)
            self.assertEqual(len(got["segs"]), 2)
            self.assertEqual(set(got["ath"]), set(real_ar.load(a)["ath"]) | set(real_ar.load(b)["ath"]))
            self.assertFalse(got.get("full"))
            self.assertEqual(bf.main(["merge", a, b, "--out", out, "--full"]), 0)
            self.assertTrue(real_ar.load(out)["full"])
            with self.assertRaises(SystemExit):
                bf.main(["merge", "--out", out])


def _part(path, urls):
    """Часть архива: по одному протоколу на каждый (адрес, фамилия)."""
    arc = real_ar.empty()
    for u, name in urls:
        real_ar.ingest(arc, [{"rank": 1, "name": name, "nation": "JPN", "tss": 1.0, "tes": 1.0, "pcs": 1.0,
                              "ded": 0.0, "components": [],
                              "elements": [{"code": "3A", "info": "", "base": 8.0, "goe": 1.0, "judges": [1, 1, 1],
                                            "score": 9.0}]}],
                       {"u": u, "ev": "e", "d": "2023-01-01", "kind": "men", "level": "senior", "seg": "КП", "src": "ISU"})
    real_ar.save(arc, path)


class MergePartsTest(unittest.TestCase):
    def test_overlap_with_not_in_refuses(self):
        """Протокол и в частях, и в архиве сбора — ValueError, out не пишется."""
        with tempfile.TemporaryDirectory() as d:
            a, b, out, common = (os.path.join(d, x) for x in ("a.json", "b.json", "out.json", "common.json"))
            _part(a, [("http://x/1.pdf", "Aaa AAA")])
            _part(b, [("http://x/2.pdf", "Bbb BBB")])
            _part(common, [("http://x/2.pdf", "Bbb BBB")])
            with self.assertRaisesRegex(ValueError, "x/2.pdf"):
                bf.merge_parts(real_ar, [a, b], out=out, not_in=common)
            self.assertFalse(os.path.exists(out))

    def test_no_overlap_writes(self):
        """Без пересечений с not_in части сливаются и пишутся в out как обычно."""
        with tempfile.TemporaryDirectory() as d:
            a, b, out, common = (os.path.join(d, x) for x in ("a.json", "b.json", "out.json", "common.json"))
            _part(a, [("http://x/1.pdf", "Aaa AAA")])
            _part(b, [("http://x/2.pdf", "Bbb BBB")])
            _part(common, [("http://x/9.pdf", "Ccc CCC")])
            bf.merge_parts(real_ar, [a, b], out=out, not_in=common)
            self.assertEqual(sorted(real_ar.urls(real_ar.load(out))), ["http://x/1.pdf", "http://x/2.pdf"])


class RunSkipTest(unittest.TestCase):
    def test_skip_event_not_ingested(self):
        """Турнир по skip_event пропускается целиком; обычный — вызывается, и skip доходит до ingest_event."""
        base = {"src": "ФФККР", "season": "2025/2026", "start": "2026-01-01", "intl": False}
        items = [dict(base, ev="Чемпионат России по синхронному катанию", url="https://fsrussia.ru/results/s/index.htm"),
                 dict(base, ev="Чемпионат России", url="https://fsrussia.ru/results/y/index.htm")]
        with tempfile.TemporaryDirectory() as d, mock.patch.object(bf, "ingest_event") as ing, \
                mock.patch.object(bf, "pause", lambda: None):
            bf.run(real_ar, items, path=os.path.join(d, "p.json"), skip=("http://x/a.pdf",))
        self.assertEqual(ing.call_count, 1)
        self.assertEqual(ing.call_args[0][2]["ev"], "Чемпионат России")
        self.assertEqual(ing.call_args[0][5], ("http://x/a.pdf",))


if __name__ == "__main__":
    unittest.main()
