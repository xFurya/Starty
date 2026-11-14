import datetime as dt
import json
import os
import tempfile
import unittest

from scraper import archive as ar
from scraper import feats as ft
from scraper import net
from scraper import profiles as pf


def row(rank, name, nat, ev, date, pts, lvl="S", bio=""):
    a = f"<a href='http://www.isuresults.com/bios/isufs{bio}.htm'>{name}</a>" if bio else name
    return (f"<tr><td>{rank}</td><td><span>{a}</span></td><td>{nat}</td><td>{ev}</td><td>{date}</td>"
            f"<td>{pts}</td><td>{lvl}</td></tr>")


# прогрессия: сверху действующий, ниже — побитые
WFS = "<table><tr><th>Rank</th><th>Name</th></tr>" + "".join([
    row(1, "Kamila VALIEVA", "RUS", "ISU GP Rostelecom Cup 2021", "27/11/2021", "185.29", bio="00090000"),
    row(2, "Kamila VALIEVA", "RUS", "ISU CS Finlandia Trophy 2021", "10/10/2021", "174.31", bio="00090000"),
    row(3, "Alexandra IGNATOVA", "RUS", "ISU GP Skate Canada International 2019", "26/10/2019", "166.62", bio="00102760"),
    row(4, "Alexandra IGNATOVA", "RUS", "ISU CS 27th Nepela Memorial 2019", "21/09/2019", "163.78", bio="00102760"),
    row(5, "Alina ZAGITOVA", "RUS", "ISU CS Nebelhorn Trophy 2018", "28/09/2018", "158.50", bio="00066666"),
    row(6, "Rika KIHIRA", "JPN", "ISU CS Nepela 2018", "22/09/2018", "147.37", bio="00055555"),
    row(7, "Alexandra IGNATOVA", "RUS", "ISU JGP Amber Cup 2018", "07/09/2018", "146.70", "J", bio="00102760"),
    row(8, "Mako YAMASHITA", "JPN", "ISU CS Asian Open Figure Skating Trophy 2018", "05/08/2018", "112.48", bio="00011111"),
]) + "</table>"

# танцы: две серии одних хозяев, вторая — до конца сезона не дожила
DFD = "<table>" + "".join([
    row(1, "Madison CHOCK / Evan BATES", "USA", "ISU World Team Trophy 2023", "14/04/2023", "138.41", bio="00013665"),
    row(2, "Gabriella PAPADAKIS / Guillaume CIZERON", "FRA", "ISU World Championships 2022", "26/03/2022", "137.09"),
    row(3, "Gabriella PAPADAKIS / Guillaume CIZERON", "FRA", "ISU GP NHK Trophy 2019", "23/11/2019", "136.58"),
]) + "</table>"


def book(tables, arc=None, pb=None, sb=None, season=""):
    arc = arc or ar.empty()
    arc["full"] = True
    return {"records": ft.records(tables), "archive": ar.Index(arc), "pb": pb or {}, "sb": sb or {}, "season": season}


def el(code, base, judges=(1, 1, 1), info="", score=None):
    return {"code": code, "info": info, "base": base, "goe": 0.5, "judges": list(judges),
            "score": score if score is not None else base + 0.5}


def protocol(arc, u, ev, d, skaters, kind="men", seg="ПП", src="ISU"):
    ar.ingest(arc, skaters, {"u": u, "ev": ev, "d": d, "kind": kind, "level": "senior", "seg": seg, "src": src})


class ParseTest(unittest.TestCase):
    def test_rows_with_bio_number_and_iso_date(self):
        rows = ft.parse(WFS)
        self.assertEqual(len(rows), 8)
        self.assertEqual(rows[0], {"r": 1, "id": "00090000", "n": "Kamila VALIEVA", "c": "RUS", "ev": "ISU GP Rostelecom Cup 2021",
                                   "d": "2021-11-27", "pts": "185.29", "l": "S"})
        self.assertEqual(rows[6]["l"], "J")
        self.assertEqual([r["r"] for r in rows], list(range(1, 9)))  # место — из первой колонки

    def test_total_table_takes_last_number(self):
        page = "<table>" + ("<tr><td>1</td><td>Wenjing SUI / Cong HAN</td><td>CHN</td><td>XXIV Olympic Winter Games 2022</td>"
                            "<td>19/02/2022</td><td>84.41</td><td>155.47</td><td>239.88</td><td>S</td></tr>") + "</table>"
        self.assertEqual(ft.parse(page)[0]["pts"], "239.88")


class RecordsTest(unittest.TestCase):
    def test_current_and_former_series(self):
        recs = ft.records({"wfs": ft.parse(WFS)})
        got = [(r["row"]["n"], r["now"], r["since"], r["till"], ft.record_title(r)) for r in recs]
        self.assertEqual(got, [
            ("Kamila VALIEVA", True, "2021-10-10", "", "Действующий мировой рекорд в произвольной программе"),
            # серия с 21.09.2019 до 10.10.2021 — пережила конец сезона
            ("Alexandra IGNATOVA", False, "2019-09-21", "2021-10-10",
             "Мировой рекорд в произвольной программе в 2019–2021 годах"),
            ("Alina ZAGITOVA", False, "2018-09-28", "2019-09-21", "Мировой рекорд в произвольной программе в 2018–2019 годах"),
        ])
        # Кихира (неделя до перебития), юниорская строка и первые недели новой системы — не рекорды для профиля
        names = {r["row"]["n"] for r in recs}
        self.assertNotIn("Rika KIHIRA", names)
        self.assertNotIn("Mako YAMASHITA", names)

    def test_series_counted_from_its_first_row(self):
        recs = ft.records({"dfd": ft.parse(DFD)})
        pc = [r for r in recs if not r["now"]][0]
        self.assertEqual((pc["since"], pc["till"], pc["row"]["pts"]), ("2019-11-23", "2023-04-14", "137.09"))
        self.assertEqual(ft.record_title(pc), "Мировой рекорд в произвольном танце в 2019–2023 годах")

    def test_table_out_of_order_is_ignored(self):
        rows = ft.parse(WFS)
        rows[0], rows[2] = rows[2], rows[0]
        self.assertEqual(ft.records({"wfs": rows}), [])

    def test_season_end(self):
        self.assertTrue(ft._past_season_end("2019-03-20", "2019-11-22"))
        self.assertFalse(ft._past_season_end("2019-10-26", "2019-12-07"))
        self.assertFalse(ft._past_season_end("2022-01-12", "2022-02-04"))
        self.assertTrue(ft._past_season_end("2018-09-28", "2019-09-21"))


class OwnerTest(unittest.TestCase):
    def setUp(self):
        self.b = book({"wfs": ft.parse(WFS), "dfd": ft.parse(DFD)})

    def titles(self, name, nation, isu_id, pr):
        return [x["t"] for x in ft.for_profile(name, nation, isu_id, pr, self.b)]

    def test_by_isu_number_despite_new_surname(self):
        pr = {"who": [{"n": "Александра Трусова", "born": "2004-06-23"}], "pb": [{"s": "fs", "pts": "177.13"}]}
        self.assertEqual(self.titles("Александра Трусова", "RUS", "00102760", pr),
                         ["Мировой рекорд в произвольной программе в 2019–2021 годах"])

    def test_isu_number_mismatch_rejects_namesake(self):
        pr = {"who": [{"n": "Камила Валиева", "born": "2006-04-26"}]}
        self.assertEqual(self.titles("Камила Валиева", "RUS", "00012345", pr), [])

    def test_by_name_nation_and_age_without_isu_number(self):
        pr = {"who": [{"n": "Камила Валиева", "born": "2006-04-26"}]}
        fe = ft.for_profile("Камила Валиева", "RUS", "", pr, self.b)
        self.assertEqual([(x["t"], x["ev"], x["d"], x["pts"], x["src"]) for x in fe],
                         [("Действующий мировой рекорд в произвольной программе", "GP Rostelecom Cup 2021",
                           "2021-11-27", "185.29", "ISU")])
        self.assertEqual(fe[0]["u"], "https://www.isuresults.com/isujsstat/phswfs.htm")
        # тёзка из другой страны или слишком юная для взрослого рекорда — не она
        self.assertEqual(self.titles("Камила Валиева", "KAZ", "", pr), [])
        young = {"who": [{"n": "Камила Валиева", "born": "2010-01-01"}]}
        self.assertEqual(self.titles("Камила Валиева", "RUS", "", young), [])

    def test_personal_best_below_record_rejects(self):
        pr = {"who": [{"n": "Камила Валиева", "born": "2006-04-26"}], "pb": [{"s": "fs", "pts": "150.00"}]}
        self.assertEqual(self.titles("Камила Валиева", "RUS", "", pr), [])

    def test_pair_by_isu_number(self):
        pr = {"who": [{"n": "Madison Chock"}, {"n": "Evan Bates"}]}
        self.assertEqual(self.titles("Madison Chock / Evan Bates", "USA", "00013665", pr),
                         ["Действующий мировой рекорд в произвольном танце"])

    def test_world_records_go_first_then_archive(self):
        arc = ar.empty()
        protocol(arc, "https://results.isu.org/a.pdf", "Финал Гран-при", "2019-12-07",
                 [{"name": "Alexandra TRUSOVA", "nation": "RUS",
                   "elements": [el("4Lz+3T", 15.7), el("4S", 9.7), el("4T", 9.5)]}], kind="women")
        protocol(arc, "https://results.isu.org/b.pdf", "Чемпионат мира", "2021-03-26",
                 [{"name": "Kaori SAKAMOTO", "nation": "JPN", "elements": [el("3Lz+3T", 10.1)]}], kind="women")
        b = book({"wfs": ft.parse(WFS)}, arc)
        pr = {"who": [{"n": "Александра Трусова", "born": "2004-06-23"}]}
        fe = ft.for_profile("Александра Трусова", "RUS", "00102760", pr, b)
        self.assertEqual([x["t"] for x in fe], [
            "Мировой рекорд в произвольной программе в 2019–2021 годах",
            "Самый дорогой прыжковый элемент с 2018 года: 4Lz+3T",
            "3 четверных в одной программе — больше всех с 2018 года",
            "Четверной сальхов", "Четверной тулуп",
            "Три разных четверных прыжка: тулуп, сальхов, лутц"])
        self.assertEqual(fe[1], {"t": "Самый дорогой прыжковый элемент с 2018 года: 4Lz+3T",
                                 "ev": "Финал Гран-при, произвольная программа", "d": "2019-12-07", "pts": "15.70",
                                 "src": "ISU", "u": "https://results.isu.org/a.pdf"})
        self.assertEqual(ft.source_names(fe), ["ISU"] * 6)
        # тёзка из другой страны архивных строк не получает
        self.assertEqual(ft.for_profile("Александра Трусова", "KAZ", "", {"who": []}, b), [])

    def test_source_names(self):
        self.assertEqual(ft.source_names([{"src": "ISU"}, {"src": "ФФККР"}, {"src": "CS Denis Ten Memorial"}, {}]),
                         ["ISU", "ФФККР", "протоколов турниров"])


class TablesTest(unittest.TestCase):
    def test_fetch_cache_and_fallback(self):
        now = dt.datetime(2026, 11, 6, 12, tzinfo=dt.timezone.utc)
        calls = []

        def ok(url):
            calls.append(url)
            return WFS

        def down(url):
            calls.append(url)
            raise net.FetchError("сеть", kind="net")

        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "records.json")
            # кэша нет, ISU молчит — рекордов нет, файл не пишется
            self.assertEqual(ft.tables(now, path, down, log=lambda *a: None), {})
            self.assertFalse(os.path.exists(path))
            got = ft.tables(now, path, ok, log=lambda *a: None)
            self.assertEqual(len(got), 2 * len(ft.TABLES))  # рекорды и личные рекорды
            self.assertEqual(len(calls), 4 * len(ft.TABLES))
            # свежий кэш — без запросов
            calls.clear()
            self.assertEqual(ft.tables(now + dt.timedelta(hours=3), path, down, log=lambda *a: None), got)
            self.assertEqual(calls, [])
            # кэш устарел, ISU молчит — берём сохранённое
            later = now + dt.timedelta(days=2)
            self.assertEqual(ft.tables(later, path, down, log=lambda *a: None), got)
            self.assertEqual(len(calls), 2 * len(ft.TABLES))


def page(n):
    return "<table>" + "".join(row(i, f"Skater {i}", "USA", "ISU Event 2026", "01/11/2026", f"{300 - i}.00")
                               for i in range(1, n + 1)) + "</table>"


class ExtraTablesTest(unittest.TestCase):
    """Личные рекорды и лучшие результаты сезона: адреса, обрезка, смена сезона."""

    NOW = dt.datetime(2026, 11, 6, 12, tzinfo=dt.timezone.utc)

    def run_tables(self, path, now=None, season_start="2026-07-01", fetch=None):
        calls = []

        def ok(url):
            calls.append(url)
            return page(15)

        got = ft.tables(now or self.NOW, path, fetch or ok, log=lambda *a: None, season_start=season_start)
        return got, calls

    def test_pb_and_sb_are_fetched_and_cut(self):
        with tempfile.TemporaryDirectory() as d:
            got, calls = self.run_tables(os.path.join(d, "r.json"))
            self.assertIn(ft.STAT + "pbsdrd.htm", calls)
            self.assertIn(ft.STAT + "sb2026-27/sbtswto.htm", calls)
            self.assertEqual(len(got["wto"]), 15)  # рекорды — целиком
            self.assertEqual(len(got["pb:wto"]), 10)
            self.assertEqual(len(got["sb:wto"]), 3)
            self.assertEqual(got["season:"], "2026/27")
            self.assertEqual(len(calls), 3 * len(ft.TABLES))
            with open(os.path.join(d, "r.json"), encoding="utf-8") as f:
                self.assertEqual(json.load(f)["season"], "2026/27")

    def test_without_season_start_no_season_tables(self):
        with tempfile.TemporaryDirectory() as d:
            got, calls = self.run_tables(os.path.join(d, "r.json"), season_start=None)
            self.assertFalse([k for k in got if k.startswith("sb:")])
            self.assertFalse([u for u in calls if "/sb" in u])

    def test_old_season_is_dropped(self):
        def down(url):
            raise net.FetchError("сеть", kind="net")

        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "r.json")
            self.run_tables(path)
            # тот же сезон, ISU молчит — прежние лучшие результаты остаются
            got, _ = self.run_tables(path, self.NOW + dt.timedelta(days=2), fetch=down)
            self.assertEqual(len(got["sb:wto"]), 3)
            # сезон сменился, ISU молчит — прошлогоднее выброшено, а не выдано за нынешнее
            got, _ = self.run_tables(path, self.NOW + dt.timedelta(days=400), "2027-07-01", down)
            self.assertFalse([k for k in got if k.startswith("sb:")])
            self.assertIn("pb:wto", got)

    def test_empty_page_keeps_saved(self):
        pages = {"n": 15}

        def fetch(url):
            return page(pages["n"])

        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "r.json")
            self.run_tables(path, fetch=fetch)
            pages["n"] = 0
            got, _ = self.run_tables(path, self.NOW + dt.timedelta(days=2), fetch=fetch)
            self.assertEqual(len(got["pb:wto"]), 10)

    def test_records_ignore_new_keys(self):
        rows = ft.parse(WFS)
        both = {"wfs": rows, "pb:wfs": rows, "sb:wfs": rows[:3], "season:": "2026/27"}
        self.assertEqual(ft.records(both), ft.records({"wfs": rows}))
        self.assertEqual(ft.records({"pb:wfs": rows, "sb:wfs": rows}), [])

    def test_load_splits_tables(self):
        tbls = {"wfs": ft.parse(WFS), "pb:wfs": ft.parse(WFS)[:2], "sb:wfs": ft.parse(WFS)[:1], "season:": "2026/27"}
        got = ft.load(tbls, ar.empty(), season_start="2026-07-01")
        self.assertEqual((sorted(got["pb"]), sorted(got["sb"]), got["season"]), (["wfs"], ["wfs"], "2026/27"))
        self.assertEqual(len(got["records"]), 3)
        self.assertEqual(ft.load(tbls, ar.empty())["sb"], {})


def pbrow(place, name="Kamila VALIEVA", nat="RUS", pts="150.00", bio="00090000", ev="ISU GP Rostelecom Cup 2021",
          date="27/11/2021"):
    return ft.parse("<table>" + row(place, name, nat, ev, date, pts, bio=bio) + "</table>")


class PlacesTest(unittest.TestCase):
    PR = {"who": [{"n": "Камила Валиева", "born": "2006-04-26"}]}

    def feats(self, pb=None, sb=None, arc=None, name="Камила Валиева", nation="RUS", isu_id="00090000"):
        b = book({"wfs": ft.parse(WFS)}, arc, pb, sb, "2026/27")
        return ft.for_profile(name, nation, isu_id, self.PR, b)

    def test_places_two_to_ten_have_titles(self):
        words = ["Второй", "Третий", "Четвёртый", "Пятый", "Шестой", "Седьмой", "Восьмой", "Девятый", "Десятый"]
        for place, word in zip(range(2, 11), words):
            with self.subTest(place=place):
                fe = self.feats(pb={"wsp": pbrow(place, pts="80.00")})
                self.assertEqual([x["t"] for x in fe][1:], [f"{word} личный рекорд в мире с 2018 года в короткой программе"])
                self.assertEqual({k: fe[1][k] for k in ("ev", "d", "pts", "src", "u")},
                                 {"ev": "GP Rostelecom Cup 2021", "d": "2021-11-27", "pts": "80.00", "src": "ISU",
                                  "u": ft.STAT + "pbswsp.htm"})

    def test_first_and_eleventh_place_are_not_shown(self):
        fe = self.feats(pb={"wsp": pbrow(1), "wto": pbrow(11)})
        self.assertEqual([x["t"] for x in fe], ["Действующий мировой рекорд в произвольной программе"])

    def test_duplicate_of_world_record_is_not_shown(self):
        # второе место в личных рекордах с теми же 185.29 — это тот же мировой рекорд
        fe = self.feats(pb={"wfs": pbrow(2, pts="185.29"), "wsp": pbrow(3, pts="85.00")})
        self.assertEqual([x["t"] for x in fe], ["Действующий мировой рекорд в произвольной программе",
                                                "Третий личный рекорд в мире с 2018 года в короткой программе"])
        # другие баллы того же отрезка — показываем
        fe = self.feats(pb={"wfs": pbrow(2, pts="170.00")})
        self.assertEqual(fe[1]["t"], "Второй личный рекорд в мире с 2018 года в произвольной программе")

    def test_former_record_also_counts_as_duplicate(self):
        pr = {"who": [{"n": "Александра Трусова", "born": "2004-06-23"}]}
        b = book({"wfs": ft.parse(WFS)}, pb={"wfs": pbrow(2, "Alexandra IGNATOVA", pts="166.62", bio="00102760")})
        self.assertEqual([x["t"] for x in ft.for_profile("Александра Трусова", "RUS", "00102760", pr, b)],
                         ["Мировой рекорд в произвольной программе в 2019–2021 годах"])

    def test_season_places_one_to_three_and_order(self):
        sb = {"wfs": pbrow(3, pts="160.00"), "wsp": pbrow(1, pts="82.00"), "wto": pbrow(2, pts="240.00"),
              "mto": pbrow(1, "Ilia MALININ", "USA", bio="00108049")}
        fe = self.feats(sb=sb)
        self.assertEqual([x["t"] for x in fe], [
            "Действующий мировой рекорд в произвольной программе",
            "Второе место в мире в сезоне по сумме баллов",
            "Лучший результат сезона в мире в короткой программе",
            "Третье место в мире в сезоне в произвольной программе"])
        self.assertEqual(fe[1]["u"], ft.STAT + "sb2026-27/sbtswto.htm")
        self.assertEqual(self.feats(sb={"wsp": pbrow(4)})[1:], [])  # четвёртое место сезона — не показываем

    def test_group_order(self):
        arc = ar.empty()
        protocol(arc, "https://results.isu.org/v.pdf", "Чемпионат России", "2022-01-01",
                 [{"name": "Kamila VALIEVA", "nation": "RUS", "elements": [el("4Lz", 11.5)]}], kind="women")
        fe = self.feats(arc=arc, pb={"wto": pbrow(4, pts="230.00"), "wsp": pbrow(5, pts="80.00")},
                        sb={"wto": pbrow(2, pts="240.00")})
        self.assertEqual([x["t"] for x in fe], [
            "Действующий мировой рекорд в произвольной программе",
            "Четвёртый личный рекорд в мире с 2018 года по сумме баллов",
            "Пятый личный рекорд в мире с 2018 года в короткой программе",
            "Второе место в мире в сезоне по сумме баллов",
            "Самый дорогой прыжковый элемент с 2018 года: 4Lz"])
        self.assertTrue(all("g" not in x and "o" not in x for x in fe))

    def test_other_holder_is_not_shown(self):
        pb = {"wsp": pbrow(3, bio="00012345")}  # другой номер ISU
        self.assertEqual(len(self.feats(pb=pb)), 1)
        pb = {"wsp": pbrow(3, bio="")}  # номера у строки нет — по имени и стране
        self.assertEqual(len(self.feats(pb=pb)), 2)
        self.assertEqual(len(self.feats(pb=pb, nation="KAZ", isu_id="")), 0)  # тёзка из другой страны
        self.assertEqual(len(self.feats(pb={"wsp": pbrow(3, nat="KAZ", bio="")}, isu_id="")), 1)


class WriteTest(unittest.TestCase):
    def test_profile_gets_feats_and_sources(self):
        people = [{"n": "Ilia Malinin", "c": "USA", "k": "m"}]
        bio = {"who": [{"n": "Ilia Malinin", "born": "2004-12-02"}], "pb": [{"s": "fs", "pts": "238.24", "d": "2025-12-06",
                                                                              "ev": "Финал Гран-при 2025"}]}
        store = {"ids": {pf.nm.key("Ilia Malinin"): "00108049"}, "bios": {"00108049": {"at": "2026-11-05T00:00:00+00:00",
                                                                                       "bio": bio, "cr": []}}}
        mfs = "<table>" + row(1, "Ilia MALININ", "USA", "ISU Grand Prix Final 2025", "06/12/2025", "238.24",
                              bio="00108049") + "</table>"
        arc = ar.empty()
        protocol(arc, "https://example.org/fs.pdf", "CS U.S. International Classic", "2022-09-14",
                 [{"name": "Ilia MALININ", "nation": "USA", "elements": [el("4A", 12.5)]},
                  {"name": "Nathan CHEN", "nation": "USA", "elements": [el("4Lz", 11.5)]}],
                 src="CS U.S. International Classic")
        with tempfile.TemporaryDirectory() as d:
            pf.write(people, store, {}, out_dir=d, log=lambda *a: None, book=book({"mfs": ft.parse(mfs)}, arc))
            with open(os.path.join(d, pf.key("Ilia Malinin") + ".json"), encoding="utf-8") as f:
                pr = json.load(f)
        self.assertEqual([x["t"] for x in pr["feats"]],
                         ["Действующий мировой рекорд в произвольной программе",
                          "Самый дорогой прыжковый элемент с 2018 года: 4A"])
        self.assertEqual(pr["src"], ["ISU", "протоколов турниров"])
        # без «книги» раздела нет
        with tempfile.TemporaryDirectory() as d:
            pf.write(people, store, {}, out_dir=d, log=lambda *a: None)
            with open(os.path.join(d, pf.key("Ilia Malinin") + ".json"), encoding="utf-8") as f:
                self.assertNotIn("feats", json.load(f))

    def test_domestic_record_after_world_records(self):
        # у россиянки лучшая сумма — на чемпионате России, а рекорд ISU ниже: «Примечательное» это
        # называет, личные рекорды показывают обе стороны
        people = [{"n": "Аделия Петросян", "c": "RUS", "k": "w"}]
        bio = {"who": [{"n": "Аделия Петросян", "born": "2007-06-05"}],
               "pb": [{"s": "total", "pts": "214.53", "d": "2026-02-19", "ev": "Олимпийские игры 2026"}]}
        store = {"ids": {pf.nm.key("Аделия Петросян"): "1"}, "bios": {"1": {"at": "2026-11-05T00:00:00+00:00",
                                                                          "bio": bio, "cr": []}}}
        mine = {"total": {"pts": "262.92", "ev": "Чемпионат России", "d": "2024-12-21", "src": "ФФККР"},
                "sp": {"pts": "86.52", "ev": "Чемпионат России", "d": "2025-12-19", "src": "ФФККР"}}
        bests = {pf.nm.key("Аделия Петросян"): mine}
        with tempfile.TemporaryDirectory() as d:
            pf.write(people, store, {}, out_dir=d, log=lambda *a: None, book=book({}, ar.empty()), bests=bests,
                     bests_from="2018/19")
            with open(os.path.join(d, pf.key("Аделия Петросян") + ".json"), encoding="utf-8") as f:
                pr = json.load(f)
        self.assertEqual(pr["feats"], [{"t": "Лучшая сумма на российских стартах — выше рекорда ISU",
                                        "ev": "Чемпионат России", "d": "2024-12-21", "pts": "262.92", "src": "ФФККР"}])
        self.assertEqual([(x["s"], x["pts"]) for x in pr["pbru"]], [("total", "262.92"), ("sp", "86.52")])
        self.assertEqual(pr["pbru_from"], "2018/19")
        self.assertIn("ФФККР", pr["src"])
        # рекорд ISU выше — строки в «Примечательном» нет, блок в личных рекордах остаётся
        bio["pb"][0]["pts"] = "270.00"
        with tempfile.TemporaryDirectory() as d:
            pf.write(people, store, {}, out_dir=d, log=lambda *a: None, book=book({}, ar.empty()), bests=bests)
            with open(os.path.join(d, pf.key("Аделия Петросян") + ".json"), encoding="utf-8") as f:
                pr = json.load(f)
        self.assertNotIn("feats", pr)
        self.assertEqual(len(pr["pbru"]), 2)

    def test_namesake_from_other_discipline_gets_own_profile(self):
        # Анна Щербакова в справочнике — танцовщица (её вид «d»), а в таблицах ISU по имени — одиночница:
        # танцовщице чужие рекорды не достаются, у одиночницы свой профиль
        people = [{"n": "Анна Щербакова", "c": "RUS", "k": "d"}]
        card = {"fio": "Щербакова Анна Михайловна", "born": "2006-01-10", "kind": "d", "rank": "МС", "at": "2026-11-13"}
        tot = "<table>" + row(2, "Anna SHCHERBAKOVA", "RUS", "XXIV Olympic Winter Games 2022", "17/02/2022", "255.95",
                              bio="00103103") + "</table>"
        b = book({}, ar.empty(), pb={"wto": ft.parse(tot)})
        bests = {pf.nm.key("Анна Щербакова"): {"total": {"pts": "264.10", "ev": "Чемпионат России", "d": "2020-12-26", "src": "ФФККР"}}}
        self.assertEqual(pf.alt_ids(people, b), {pf.nm.key("Анна Щербакова") + "|w": "00103103"})
        with tempfile.TemporaryDirectory() as d:
            pf.write(people, {"ids": {}, "bios": {}}, {"1304": card}, out_dir=d, log=lambda *a: None, book=b, bests=bests,
                     aliases={})
            p = people[0]
            with open(os.path.join(d, p["p"] + ".json"), encoding="utf-8") as f:
                main = json.load(f)
            self.assertEqual(main["who"][0]["born"], "2006-01-10")
            self.assertNotIn("feats", main)
            self.assertNotIn("pbru", main)
            self.assertEqual(p["alt"][0]["was"], "w")
            with open(os.path.join(d, p["alt"][0]["p"] + ".json"), encoding="utf-8") as f:
                alt = json.load(f)
        self.assertEqual([x["t"] for x in alt["feats"]][:2],
                         ["Лучшая сумма на российских стартах — выше рекорда ISU", "Второй личный рекорд в мире с 2018 года по сумме баллов"])
        self.assertEqual(alt["pbru"][0]["pts"], "264.10")

    def test_domestic_against_world_record_without_isu_pb(self):
        # ISU личных рекордов не прислал, а мировой рекорд по сумме у неё есть — мерка он
        pr = {"src": ["ISU"]}
        wr = {"t": "Действующий мировой рекорд по сумме баллов", "ev": "GP Rostelecom Cup 2021", "d": "2021-11-27",
              "pts": "272.71", "src": "ISU", "u": ft.STAT + "phswto.htm"}
        mine = {"total": {"pts": "283.48", "ev": "Чемпионат России", "d": "2021-12-25", "src": "ФФККР"}}
        self.assertEqual([x["pts"] for x in pf.domestic(pr, mine, "2018/19", [wr])], ["283.48"])
        self.assertEqual(pf.domestic(dict(src=[]), mine, "", [dict(wr, pts="290.00")]), [])
        self.assertEqual(pf.domestic(dict(src=[]), mine, "", []), [])  # мерки нет — строки нет


if __name__ == "__main__":
    unittest.main()
