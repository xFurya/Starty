"""Место рождения по-русски: разбор строки ISU, выбор места, кэш."""
import datetime as dt
import json
import os
import shutil
import tempfile
import unittest
import unittest.mock

from . import places as pl


def row(q, ru, links, key, cc):
    return {"item": {"value": "http://www.wikidata.org/entity/" + q}, "ru": {"value": ru},
            "links": {"value": str(links)}, key: {"value": cc}}


FACTS_AB = {"A": {"ru": "Москва", "links": 300, "cc": {"RUS"}},
            "B": {"ru": "Москоу", "links": 60, "cc": {"USA"}}}

ROWS = [row("Q2746", "Рязань", 106, "ioc", "RUS"),
        row("Q649", "Москва", 338, "iso", "RUS"),
        row("Q499927", "Москоу", 61, "iso", "USA")]

HITS = {"Riazan": [("Q2746", "Riazan", "Ryazan")],
        "Moscow": [("Q649", "Moscow", "Moscow"), ("Q499927", "Moscow", "Moscow")],
        "Nowhere": []}

PAIRS = [("Riazan", "RUS"), ("Moscow", "USA"), ("Nowhere", "FRA")]
TODAY = dt.date(2026, 11, 11)


class SplitTest(unittest.TestCase):
    def test_split_codes_regions_and_fallback(self):
        self.assertEqual(pl.split("Moscow RUS"), (["Moscow"], "RUS"))
        self.assertEqual(pl.split("Boston, MA"), (["Boston"], ""))
        self.assertEqual(pl.split("Toronto ON"), (["Toronto"], ""))
        self.assertEqual(pl.split("Changchun Jilin"), (["Changchun Jilin", "Changchun"], ""))
        self.assertEqual(pl.split("Riazan"), (["Riazan"], ""))
        self.assertEqual(pl.split("Chicago USA"), (["Chicago"], "USA"))
        # два названия через тире — второй запрос первое из них, а не обрубок «Donostia - San»
        self.assertEqual(pl.split("Donostia - San Sebastian ESP"), (["Donostia - San Sebastian", "Donostia"], "ESP"))

    def test_variants_of_russian_endings(self):
        self.assertEqual(pl.variants("Nizhnyi Tagil"), ["Nizhny Tagil"])
        self.assertEqual(pl.variants("Nizhniy Novgorod"), ["Nizhny Novgorod"])
        self.assertEqual(pl.variants("Moscow"), [])


class NormTest(unittest.TestCase):
    def test_norm_saint_and_punctuation(self):
        self.assertEqual(pl._norm("St. Petersburg"), pl._norm("Saint-Petersburg"))
        self.assertEqual(pl._norm("Saint-Petersburg"), pl._norm("Sankt Petersburg"))

    def test_norm_diacritics(self):
        self.assertEqual(pl._norm("Mölndal"), pl._norm("Molndal"))
        self.assertEqual(pl._norm("Tiumén"), pl._norm("Tiumen"))


class ExactTest(unittest.TestCase):
    def test_exact_keeps_whole_matches_only(self):
        hits = [("Q649", "Moscow", "Moscow"), ("Q1", "Moscow Oblast", "Moscow Oblast"),
                ("Q499927", "Moscow", "Moscow")]
        self.assertEqual(pl.exact("Moscow", hits), ["Q649", "Q499927"])

    def test_exact_matches_by_label_for_other_spelling(self):
        self.assertEqual(pl.exact("Riazan", [("Q2746", "Riazan", "Ryazan")]), ["Q2746"])


class ChooseTest(unittest.TestCase):
    def test_explicit_code_picks_matching_country(self):
        self.assertEqual(pl.choose(["A", "B"], FACTS_AB, "RUS", "USA"), "A")
        self.assertIsNone(pl.choose(["A", "B"], FACTS_AB, "GER", "USA"))

    def test_famous_namesake_abroad_is_not_guessed(self):
        self.assertIsNone(pl.choose(["A", "B"], FACTS_AB, "", "USA"))
        self.assertEqual(pl.choose(["A", "B"], FACTS_AB, "", "RUS"), "A")

    def test_home_country_wins_when_namesake_not_much_more_famous(self):
        facts = {"F": {"ru": "Сент-Питерсберг", "links": 200, "cc": {"USA"}},
                 "R": {"ru": "Санкт-Петербург", "links": 273, "cc": {"RUS"}}}
        self.assertEqual(pl.choose(["R", "F"], facts, "", "USA"), "F")

    def test_namesakes_at_home_do_not_block(self):
        # «Neuchâtel» у швейцарца: город и кантон, оба в Швейцарии, кантон известнее
        facts = {"C": {"ru": "Невшатель", "links": 90, "cc": {"SUI"}},
                 "K": {"ru": "Невшатель (кантон)", "links": 120, "cc": {"SUI"}}}
        self.assertEqual(pl.choose(["C", "K"], facts, "", "SUI"), "C")
        # а куда более известный тёзка за границей по-прежнему останавливает
        facts["X"] = {"ru": "Икс", "links": 1000, "cc": {"USA"}}
        self.assertIsNone(pl.choose(["C", "K", "X"], facts, "", "SUI"))

    def test_home_namesake_with_russian_name_preferred(self):
        # «Hyogo»: деревня без русского названия первой в поиске, префектура Хиого — второй
        facts = {"V": {"ru": "", "links": 3, "cc": {"JPN"}},
                 "P": {"ru": "Хиого", "links": 150, "cc": {"JPN"}}}
        self.assertEqual(pl.choose(["V", "P"], facts, "", "JPN"), "P")
        self.assertEqual(pl.choose(["V", "P"], facts, "", "RUS"), "P")  # одна страна, без дома

    def test_single_foreign_country_accepted_without_home(self):
        facts = {"K": {"ru": "Харьков", "links": 150, "cc": {"UKR"}}}
        self.assertEqual(pl.choose(["K"], facts, "", "RUS"), "K")
        facts["X"] = {"ru": "Икс", "links": 100, "cc": {"POL"}}
        self.assertIsNone(pl.choose(["K", "X"], facts, "", "RUS"))  # обе известны — не угадываем

    def test_much_more_famous_place_abroad_wins_without_home(self):
        # «Prague» у итальянки: Прага против Праги в Оклахоме
        facts = {"P": {"ru": "Прага", "links": 270, "cc": {"CZE"}},
                 "O": {"ru": "", "links": 37, "cc": {"USA"}}}
        self.assertEqual(pl.choose(["P", "O"], facts, "", "ITA"), "P")

    def test_fallback_without_home_is_none(self):
        facts = {"K": {"ru": "Харьков", "links": 150, "cc": {"UKR"}}}
        self.assertIsNone(pl.choose(["K"], facts, "", "RUS", fallback=True))

    def test_ids_missing_from_facts_are_ignored(self):
        facts = {"K": {"ru": "Харьков", "links": 150, "cc": {"UKR"}}}
        self.assertEqual(pl.choose(["Z", "K"], facts, "", "UKR"), "K")
        self.assertIsNone(pl.choose(["Z"], {}, "", "UKR"))


class RegionTest(unittest.TestCase):
    def test_region(self):
        self.assertEqual(pl.region("London, Ontario"), "Ontario")
        self.assertEqual(pl.region("Calgary, AB, CAN"), "AB")
        self.assertEqual(pl.region("Toronto ON"), "ON")
        self.assertEqual(pl.region("Mostoles (Madrid) ESP"), "Madrid")
        self.assertEqual(pl.region("Moscow RUS"), "")
        self.assertEqual(pl.region("Riazan"), "")

    def test_region_in_description_beats_famous_namesake(self):
        facts = {"L": {"ru": "Лондон", "links": 357, "cc": {"GBR"}},
                 "O": {"ru": "Лондон", "links": 86, "cc": {"CAN"}}}
        descs = {"L": "capital and largest city of the United Kingdom", "O": "city in Ontario, Canada"}
        self.assertIsNone(pl.choose(["L", "O"], facts, "", "CAN"))
        self.assertEqual(pl.choose(["L", "O"], facts, "", "CAN", region="Ontario", descs=descs), "O")
        self.assertEqual(pl.choose(["L", "O"], facts, "", "CAN", region="ON", descs=descs), "O")
        # уточнение называет другую страну: «Paris, France» у канадца — Париж, а не Париж в Онтарио
        facts = {"F": {"ru": "Париж", "links": 350, "cc": {"FRA"}},
                 "C": {"ru": "Пэрис", "links": 20, "cc": {"CAN"}}}
        descs = {"F": "capital and largest city of France", "C": "community in Ontario, Canada"}
        self.assertEqual(pl.choose(["F", "C"], facts, "", "CAN", region="France", descs=descs), "F")


class NationCodeTest(unittest.TestCase):
    def test_nation_codes(self):
        self.assertEqual(pl.nation_code("AIN2"), "RUS")
        self.assertEqual(pl.nation_code("AIN1"), "BLR")
        self.assertEqual(pl.nation_code("МОС"), "RUS")
        self.assertEqual(pl.nation_code("USA"), "USA")


class RefreshTest(unittest.TestCase):
    def setUp(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        self.path = os.path.join(d, "places.json")
        self.calls = []

    def search(self, q):
        self.calls.append(q)
        return HITS[q]

    def rows_of(self, query):
        return list(ROWS)

    def refresh(self, pairs, today=TODAY, search=None, budget=pl.BUDGET):
        return pl.refresh(pairs, log=lambda *a: None, path=self.path, budget=budget, today=today,
                          search=search or self.search, rows_of=self.rows_of)

    def test_refresh_resolves_and_caches(self):
        cache = self.refresh(PAIRS)
        self.assertEqual(pl.ru("Riazan", "RUS", cache), "Рязань")
        self.assertEqual(pl.ru("Moscow", "USA", cache), "Moscow")
        self.assertEqual(pl.ru("Nowhere", "FRA", cache), "Nowhere")
        with open(self.path, encoding="utf-8") as f:
            self.assertEqual(len(json.load(f)), 3)
        self.assertEqual(cache["Moscow|USA"]["ru"], "")

    def test_refresh_uses_cache_then_retries_only_unresolved(self):
        self.refresh(PAIRS)

        def no_search(q):
            raise AssertionError("поиск не должен идти: " + q)

        self.refresh(PAIRS, search=no_search)

        self.calls.clear()
        self.refresh(PAIRS, today=TODAY + dt.timedelta(days=61))
        self.assertEqual(set(self.calls), {"Moscow", "Nowhere"})

    def test_refresh_budget_limits_searches(self):
        cache = self.refresh([("Riazan", "RUS"), ("Moscow", "USA")], budget=1)
        self.assertEqual(self.calls, ["Riazan"])
        self.assertIn("Riazan|RUS", cache)
        self.assertNotIn("Moscow|USA", cache)

    def test_own_code_of_territory(self):
        # «Hong Kong HKG»: страна по P17 — Китай, но у самого Гонконга код HKG
        rows = [row("Q8646", "Гонконг", 304, "iso", "CHN"), row("Q8646", "Гонконг", 304, "sioc", "HKG")]
        cache = pl.refresh([("Hong Kong HKG", "USA")], log=lambda *a: None, path=self.path, today=TODAY,
                           search=lambda q: [("Q8646", "Hong Kong", "Hong Kong", "special administrative region")],
                           rows_of=lambda q: rows)
        self.assertEqual(pl.ru("Hong Kong HKG", "USA", cache), "Гонконг")

    def test_cyrillic_nation_shares_cache_key(self):
        cache = self.refresh([("Riazan", "AIN2")])
        self.assertEqual(pl.ru("Riazan", "RUS", cache), "Рязань")

    def test_search_failure_stops_this_run(self):
        def flaky(q):
            self.calls.append(q)
            raise pl.net.FetchError("429", kind="http", status=429)

        cache = self.refresh(PAIRS, search=flaky)
        self.assertEqual(self.calls, ["Riazan"])  # после первого отказа больше не спрашиваем
        self.assertEqual(cache, {})  # и ничего не помечаем ненайденным


    def test_other_spelling_when_nothing_found(self):
        hits = {"Nizhnyi Tagil": [], "Nizhnyi": [], "Nizhny": [],
                "Nizhny Tagil": [("Q1", "Nizhny Tagil", "Nizhny Tagil", "city in Sverdlovsk Oblast, Russia")]}
        rows = [row("Q1", "Нижний Тагил", 90, "ioc", "RUS")]

        def search(q):
            self.calls.append(q)
            return hits[q]

        cache = pl.refresh([("Nizhnyi Tagil RUS", "RUS")], log=lambda *a: None, path=self.path, today=TODAY,
                           search=search, rows_of=lambda q: rows)
        self.assertEqual(pl.ru("Nizhnyi Tagil RUS", "RUS", cache), "Нижний Тагил")
        self.assertIn("Nizhny Tagil", self.calls)

    def test_other_spelling_out_of_budget_is_not_marked_missing(self):
        def search(q):
            self.calls.append(q)
            return []

        cache = pl.refresh([("Nizhnyi", "RUS")], log=lambda *a: None, path=self.path, today=TODAY,
                           search=search, rows_of=lambda q: [], budget=1)
        self.assertEqual(self.calls, ["Nizhnyi"])
        self.assertNotIn("Nizhnyi|RUS", cache)  # «Nizhny» не искали — в следующий сбор

    def test_new_rules_version_resolves_again(self):
        self.refresh(PAIRS)
        self.calls.clear()
        with unittest.mock.patch.object(pl, "VERSION", pl.VERSION + 1):
            self.refresh(PAIRS)
        self.assertEqual(set(self.calls), {"Riazan", "Moscow", "Nowhere"})


class ProfileTest(unittest.TestCase):
    def test_profile_writes_known_place_in_russian(self):
        from . import profiles as pf
        bio = {"at": "2026-11-01", "cr": [], "bio": {"who": [{"born": "01.01.2008", "place": "Riazan"}]}}
        cache = {"Riazan|RUS": {"ru": "Рязань", "q": "Q2746", "at": "2026-11-11"}}
        self.assertEqual(pf.profile("Иван Иванов", "RUS", bio, places=cache)["who"][0]["place"], "Рязань")
        self.assertEqual(pf.profile("Иван Иванов", "USA", bio, places=cache)["who"][0]["place"], "Riazan")
        self.assertEqual(pf.profile("Иван Иванов", "RUS", bio)["who"][0]["place"], "Riazan")
