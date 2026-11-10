"""Справочник спортсменов: фильтры турниров и категорий, адреса табло, пары в списке ISU."""
import unittest
from unittest import mock

from scraper import net, people


class TournamentFilterTest(unittest.TestCase):
    def skipped(self, slug):
        return bool(people._SKIP_TOUR.search(slug.replace("-", " ")))

    def test_amateur_and_team_events_are_skipped(self):
        # названия из протоколов ФФККР, проверенные вручную: синхрон, балет, любительский кубок, межрегиональные
        for slug in [
            "kubok-rossii-po-sinkhronnomu-kataniyu-na-kon-kakh-2025-2026-gg-3-j-etap-syuyumbike",
            "vserossijskij-festival-po-sportivnym-baletam-na-l-du-final-2026",
            "vserossijskoe-fizkul-turnoe-meropriyatie-kubok-federatsii-sredi-vzroslykh-lyubitelej-final-2026",
            "mezhregional-nye-sorevnovaniya-pervenstvo-szfo-skfo-i-yufo-sredi-yunoshej-i-devushek-2026",
        ]:
            self.assertTrue(self.skipped(slug), slug)

    def test_sport_events_are_kept(self):
        for slug in [
            "vserossijskie-sorevnovaniya-kumparsita-vserossijskoe-fizkul-turnoe-meropriyatie-kumparsita-2026",
            "vserossijskie-sorevnovaniya-samarochka-2026",
            "pervenstvo-moskvy-2026",
        ]:
            self.assertFalse(self.skipped(slug), slug)


class CategoryFilterTest(unittest.TestCase):
    def skipped(self, name):
        return bool(people._SKIP_CAT.search(name.translate(people._HOMO)))

    def test_amateur_classes_are_skipped(self):
        for name in ["Одиночное катание, Класс I–III", "Женщины, Пре-бронза", "Молодежный класс"]:
            self.assertTrue(self.skipped(name), name)

    def test_ranked_categories_are_kept(self):
        for name in ["Женщины, КМС", "Юниорки, МС", "Юноши, КМС"]:
            self.assertFalse(self.skipped(name), name)


class AddressTest(unittest.TestCase):
    def test_cyrillic_host_becomes_punycode(self):
        url = net.ascii_url("https://роо-пкффкк.рф/ftp_tablo/197/index.htm")
        self.assertTrue(url.isascii())
        self.assertTrue(url.startswith("https://xn----"))
        self.assertTrue(url.endswith(".xn--p1ai/ftp_tablo/197/index.htm"))

    def test_ascii_address_is_unchanged(self):
        url = "https://fsrussia.ru/results/2526/1etap2026_adult/index.htm"
        self.assertEqual(net.ascii_url(url), url)

    def test_cyrillic_path_is_percent_encoded(self):
        url = net.ascii_url("https://example.org/протоколы/CAT001RS.HTM")
        self.assertTrue(url.isascii())
        self.assertIn("CAT001RS.HTM", url)


class IsuPairsTest(unittest.TestCase):
    """Пары и танцы в списке ISU: у строки пары имени нет, партнёры — в members."""

    def test_both_partners_are_listed(self):
        page = {
            "is_next_page": "N",
            "data": [
                {"skaters_type": "Single", "full_name": "Alina GORINA", "nationality_code": "RUS",
                 "status": "Active"},
                {"skaters_type": "Team", "full_name": None, "nf_organization_code": "RUS", "status": "Active",
                 "members": [
                     {"full_name": "Albina SOKUR", "nationality_code": "RUS"},
                     {"full_name": "Roman PLESHKOV"},
                 ]},
                {"skaters_type": "Team", "full_name": None, "nf_organization_code": "USA", "status": "Active",
                 "members": [{"full_name": "Jane DOE"}]},
            ],
        }
        with mock.patch.object(net, "fetch_json", return_value=page):
            got = {name: (nation, org) for name, nation, org in people.isu_russians(log=lambda *a: None)}
        self.assertEqual(set(got), {"Alina GORINA", "Albina SOKUR", "Roman PLESHKOV"})
        self.assertEqual(got["Roman PLESHKOV"], ("RUS", "RUS"))


if __name__ == "__main__":
    unittest.main()


class WikidataLabelTest(unittest.TestCase):
    def test_label_forms(self):
        f = people.wikidata_label
        self.assertEqual(f("Ксения Алексеевна Синицына", "ru"), "Ксения Синицына")
        self.assertEqual(f("Павлова, Наталья Евгеньевна", "ru"), "Наталья Павлова")
        self.assertEqual(f("Kseniya Sinitsina", "en"), "Kseniya Sinitsina")


class WikidataIdentityTest(unittest.TestCase):
    ITEM = {"dob": {"2004-08-05"}, "prec": 11, "countries": {"RUS"}, "skater": True, "sport": True}

    def same(self, item=None, dob="2004-08-05", nat="RUS", **kw):
        return people.wikidata_same_person({**(item or self.ITEM), **kw}, dob, nat)

    def test_same_person(self):
        self.assertTrue(self.same())

    def test_other_birth_year_is_rejected(self):
        self.assertFalse(self.same(dob="1998-08-05"))

    def test_same_year_other_day_is_rejected_when_wikidata_is_exact(self):
        self.assertFalse(self.same(dob="2004-03-01"))

    def test_year_only_in_wikidata_matches_by_year(self):
        self.assertTrue(people.wikidata_same_person({**self.ITEM, "prec": 9}, "2004-03-01", "RUS"))
        self.assertFalse(people.wikidata_same_person({**self.ITEM, "prec": 9}, "2005-03-01", "RUS"))

    def test_other_country_is_rejected(self):
        self.assertFalse(self.same(nat="USA"))

    def test_not_a_skater_is_rejected(self):
        self.assertFalse(self.same(skater=False, sport=False))
        self.assertTrue(self.same(skater=False, sport=True))

    def test_no_birth_data_means_no_photo(self):
        self.assertFalse(self.same(dob=None))
        self.assertFalse(self.same(dob=""))
        self.assertFalse(people.wikidata_same_person({**self.ITEM, "dob": set()}, "2004-08-05", "RUS"))

    def test_photos_only_for_verified_people(self):
        def row(p, en, dob, c="RUS", sk="true"):
            return {"p": {"value": p}, "en": {"value": en}, "img": {"value": "http://commons.wikimedia.org/wiki/Special:FilePath/" + en.replace(" ", "_") + ".jpg"},
                    "dob": {"value": dob + "T00:00:00Z"}, "prec": {"value": "11"}, "cc": {"value": c},
                    "sk": {"value": sk}, "fs": {"value": "false"}}
        rows = [row("Q1", "Ksenia Sinitsyna", "2004-08-05"),
                row("Q2", "Anna Same", "1980-01-01"),      # однофамилец: другой год
                row("Q3", "Nobody Known", "2004-08-05")]   # в ISU не найден
        directory = [("Ksenia SINITSYNA", "ksenia-sinitsyna", "RUS"), ("Anna SAME", "anna-same", "RUS")]

        class B:
            def get(self, slug):
                return {"ksenia-sinitsyna": ("2004-08-05", "RUS"), "anna-same": ("2003-02-02", "RUS")}.get(slug)

            def save(self):
                pass
        with mock.patch.object(people, "_wikidata_rows", side_effect=[rows, []]):
            out, ok = people.wikidata_photos(log=lambda *a: None, directory=directory, births=B())
        self.assertTrue(ok)
        self.assertEqual([n for n, _ in out], ["Ksenia Sinitsyna"])


import datetime as dt

from scraper import names as nm

TODAY = dt.date(2026, 11, 10)
QUIET = lambda *a: None  # noqa: E731


def http(status):
    return net.FetchError(f"HTTP {status}", kind="http", status=status)


class GoneTest(unittest.TestCase):
    def test_404_and_410_are_gone(self):
        self.assertTrue(people._gone(http(404)))
        self.assertTrue(people._gone(http(410)))

    def test_server_error_and_network_failure_are_not_gone(self):
        self.assertFalse(people._gone(http(500)))
        self.assertFalse(people._gone(net.FetchError("обрыв", kind="net")))
        self.assertFalse(people._gone(net.FetchError("таймаут", kind="timeout")))


class RecheckTest(unittest.TestCase):
    L = "/sorevnovaniya/sorevnovaniya/"

    def due(self, links, known, dates, today=TODAY):
        return people.recheck(links, known, dates, today)

    def test_page_inside_window_is_rechecked(self):
        a, b, c = self.L + "a-2026", self.L + "b-2026", self.L + "c-2026"
        d = {a: ["2026-11-13", "2026-11-15"],   # старт через 3 дня: окно уже открыто
             b: ["2026-11-14", "2026-11-16"],   # старт через 4 дня: рано
             c: ["2026-09-26", "2026-09-26"]}   # конец был ровно 45 дней назад: последний день окна
        got = self.due([a, b, c], {a: "", b: "", c: ""}, d)
        self.assertEqual(sorted(got), sorted([a, c]))

    def test_page_after_window_is_not_rechecked(self):
        a = self.L + "old-2026"
        self.assertEqual(self.due([a], {a: ""}, {a: ["2026-09-01", "2026-09-25"]}), [])

    def test_pages_without_dates_are_limited_and_fresh_first(self):
        old = [f"{self.L}n{i:02d}-2019" for i in range(10)]
        new = [f"{self.L}m{i:02d}-2026" for i in range(people.RECHECK_BUDGET)]
        got = self.due(old + new, {l: "" for l in old + new}, {})
        self.assertEqual(len(got), people.RECHECK_BUDGET)
        self.assertEqual(set(got), set(new))

    def test_known_scoreboard_skipped_and_amateur_skipped_and_unseen_skipped(self):
        done = self.L + "done-2026"
        amateur = self.L + "vserossijskij-lyubitel-skij-kubok-2026"
        unseen = self.L + "unseen-2026"
        got = self.due([done, amateur, unseen], {done: "https://fsrussia.ru/results/2627/x/index.htm", amateur: ""}, {})
        self.assertEqual(got, [])


class RussiansTest(unittest.TestCase):
    PAGE = "/sorevnovaniya/sorevnovaniya/kubok-2026"
    RES = "https://fsrussia.ru/results/2627/kubok/index.htm"
    ROWS = [["Анна Тестова", "women", "senior"]]

    def run_russians(self, cache, tour, rows=None, today=TODAY):
        """tour — ответ fsr.tournament (словарь или исключение); rows — ответ _results (список/None/исключение)."""
        def fetch(url, *a, **kw):
            return f'<a href="{self.PAGE}">t</a>' if url.endswith("start=0") else ""

        def maybe(x):
            if isinstance(x, Exception):
                raise x
            return x
        miss = []
        with mock.patch.object(net, "fetch", side_effect=fetch), \
                mock.patch("scraper.fsr.tournament", side_effect=lambda url: maybe(tour)), \
                mock.patch.object(people, "_results", side_effect=lambda url, log: maybe(rows)):
            out = people.russians(cache, ["2627", "2526"], QUIET, today=today, miss=miss)
        return out, miss

    def cache(self, **pages):
        return {"pages": dict(pages), "dates": {}, "results": {}}

    def test_page_with_empty_scoreboard_is_reread_and_protocols_taken(self):
        cache = self.cache(**{self.PAGE: ""})
        cache["dates"][self.PAGE] = ["2026-11-12", "2026-11-14"]
        tour = {"results": self.RES, "start": dt.date(2026, 11, 12), "end": dt.date(2026, 11, 14)}
        out, miss = self.run_russians(cache, tour, self.ROWS)
        self.assertEqual(out, [("Анна Тестова", "women", "senior", "2627")])
        self.assertEqual(cache["pages"][self.PAGE], self.RES)
        self.assertEqual(miss, [])

    def test_unfinished_tournament_is_not_cached_but_finished_is(self):
        for end, cached in ((dt.date(2026, 11, 10), False), (dt.date(2026, 11, 11), False),
                            (dt.date(2026, 11, 9), True)):
            cache = self.cache()
            tour = {"results": self.RES, "start": dt.date(2026, 11, 8), "end": end}
            out, _ = self.run_russians(cache, tour, self.ROWS)
            self.assertEqual(len(out), 1, end)
            self.assertEqual(self.RES in cache["results"], cached, end)

    def test_scoreboard_failure_goes_to_miss_and_is_not_cached(self):
        cache = self.cache()
        tour = {"results": self.RES, "start": dt.date(2026, 10, 1), "end": dt.date(2026, 10, 3)}
        out, miss = self.run_russians(cache, tour, net.FetchError("обрыв", kind="net"))
        self.assertEqual(out, [])
        self.assertEqual(miss, [(self.RES, "2627")])
        self.assertEqual(cache["results"], {})

    def test_server_error_on_scoreboard_goes_to_miss(self):
        cache = self.cache()
        tour = {"results": self.RES, "start": dt.date(2026, 10, 1), "end": dt.date(2026, 10, 3)}
        _, miss = self.run_russians(cache, tour, http(500))
        self.assertEqual(miss, [(self.RES, "2627")])

    def test_missing_scoreboard_404_is_not_a_failure(self):
        cache = self.cache()
        tour = {"results": self.RES, "start": dt.date(2026, 10, 1), "end": dt.date(2026, 10, 3)}
        out, miss = self.run_russians(cache, tour, http(404))
        self.assertEqual((out, miss), ([], []))

    def test_tournament_page_failure_goes_to_miss_but_404_does_not(self):
        _, miss = self.run_russians(self.cache(), http(500))
        self.assertEqual(miss, [(self.PAGE, None)])
        _, miss = self.run_russians(self.cache(), http(404))
        self.assertEqual(miss, [])


class StatRowsTest(unittest.TestCase):
    ROW = ('<table><tr><td>1</td><td><a href="bios/isufs12345.htm">Ivan PETROV</a></td>'
           '<td>RUS</td><td>J</td></tr></table>')

    def test_not_found_is_not_a_failure(self):
        miss = []
        with mock.patch.object(net, "fetch", side_effect=http(404)):
            self.assertEqual(people._stat_rows("sb2026-27/x.htm", "2627", miss, QUIET), [])
        self.assertEqual(miss, [])

    def test_server_error_is_a_failure(self):
        miss = []
        with mock.patch.object(net, "fetch", side_effect=http(500)):
            self.assertEqual(people._stat_rows("sb2026-27/x.htm", "2627", miss, QUIET), [])
        self.assertEqual(miss, [("sb2026-27/x.htm", "2627")])

    def test_internationals_one_row_per_season_and_failures_by_season(self):
        def fetch(url, *a, **kw):
            if "sb2026-27" in url:
                raise http(404)  # сезон ещё не начался
            if "sb2025-26" in url and "sbtsmto" in url:
                return self.ROW
            raise http(500)
        miss = []
        with mock.patch.object(net, "fetch", side_effect=fetch):
            got = people.internationals(["2627", "2526"], QUIET, miss=miss)
        self.assertEqual(got, [("Ivan PETROV", "RUS", "men", "junior", "12345", "2526")])
        self.assertTrue(miss and all(s == "2526" for _, s in miss))
        self.assertNotIn(("sb2025-26/sbtsmto.htm", "2526"), miss)

    def test_both_seasons_are_kept(self):
        senior = self.ROW.replace("<td>J</td>", "<td>S</td>")
        def fetch(url, *a, **kw):
            if "sbtsmto" not in url:
                return ""
            return senior if "sb2026-27" in url else self.ROW
        with mock.patch.object(net, "fetch", side_effect=fetch):
            got = people.internationals(["2627", "2526"], QUIET, miss=[])
        self.assertEqual([(g[3], g[5]) for g in got], [("senior", "2627"), ("junior", "2526")])


class BookTest(unittest.TestCase):
    """build(): вид с сезоном. Источники — заглушки."""

    def book(self, ru=(), intl=(), seen=(), prev=None, cards=(), ru_miss=(), int_miss=()):
        def fake_ru(cache, codes, log=print, today=None, miss=None):
            miss.extend(ru_miss)
            return list(ru)

        def fake_int(codes, log=print, miss=None):
            miss.extend(int_miss)
            return list(intl)
        card = {str(i): {"fio": fio, "photo": ""} for i, fio in enumerate(cards)}
        with mock.patch.object(people, "_load", return_value={}), mock.patch.object(people, "_save"), \
                mock.patch.object(people, "isu_russians", return_value=[]), \
                mock.patch.object(people, "cards", return_value=card), \
                mock.patch.object(people, "russians", side_effect=fake_ru), \
                mock.patch.object(people, "internationals", side_effect=fake_int), \
                mock.patch.object(people, "isu_photos", return_value=[]), \
                mock.patch.object(people, "wikidata_photos", return_value=([], True)), \
                mock.patch("scraper.fsr.team", return_value=[]), \
                mock.patch("scraper.photos.load_hand", return_value=[]):
            return people.build(nm.Names(None, {}), "2026-07-01", QUIET, seen=seen, prev=prev)

    def by_name(self, book):
        return {p["n"]: p for p in book["people"]}

    def crowd(self, n, kind="women", level="senior", seasons=("2627", "2526")):
        return [(f"Участник{chr(1040 + i)} Фамилия{chr(1040 + i)}", kind, level, s) for i in range(n) for s in seasons]

    def test_junior_last_season_senior_now_shows_current_level(self):
        got = self.book(ru=[("Анна Тестова", "women", "junior", "2526"), ("Анна Тестова", "women", "senior", "2627")])
        p = self.by_name(got)["Анна Тестова"]
        self.assertEqual(p["k"], "w")
        self.assertNotIn("was", p)

    def test_last_season_only_in_closed_class_stays_current(self):
        got = self.book(ru=[("Анна Тестова", "women", "senior", "2526")] + self.crowd(4, seasons=("2526",)))
        p = self.by_name(got)["Анна Тестова"]
        self.assertEqual(p["k"], "w")
        self.assertNotIn("was", p)
        self.assertNotIn("y", p)

    def test_last_season_only_in_open_class_becomes_was(self):
        ru = [("Анна Тестова", "women", "senior", "2526")] + self.crowd(5)
        p = self.by_name(self.book(ru=ru))["Анна Тестова"]
        self.assertEqual((p["k"], p["was"], p["y"]), ("", "w", "2025/26"))

    def test_class_open_threshold_scales_with_last_season(self):
        # прошлый сезон — 20 человек, текущий — 5: 5 < 0.5 * 20, класс ещё не открыт
        ru = [("Анна Тестова", "women", "senior", "2526")] + self.crowd(5, seasons=("2627",)) + \
            self.crowd(20, seasons=("2526",))
        p = self.by_name(self.book(ru=ru))["Анна Тестова"]
        self.assertEqual(p["k"], "w")
        self.assertNotIn("was", p)

    def test_seen_gives_current_kind_to_existing_only(self):
        seen = [("Анна Тестова", "women", "senior"), ("Никто Новый", "men", "senior"),
                ("Анна Тестова / Борис Тестов", "pairs", "senior"),
                ("Анна Тестова", "bogus", "senior"), ("Анна Тестова", "men", "adult")]
        got = self.by_name(self.book(cards=["Тестова Анна Ивановна", "Тестов Борис Петрович"], seen=seen))
        self.assertEqual(set(got), {"Анна Тестова", "Борис Тестов"})
        self.assertEqual(got["Анна Тестова"]["k"], "pw")
        self.assertEqual(got["Борис Тестов"]["k"], "p")

    def test_seen_never_makes_a_man_a_woman_too(self):
        # табло перепутало разряды: мужчина в составе «женской» произвольной — видом это не становится
        got = self.book(intl=[("Arin YORKE", "GBR", "men", "senior", "", "2526")],
                        seen=[("Arin Yorke", "women", "senior"), ("Arin Yorke", "men", "senior")])
        self.assertEqual(self.by_name(got)["Arin Yorke"]["k"], "m")
        # и из двух свидетельств без источника остаётся первое, а не оба
        got = self.book(cards=["Тестов Борис Петрович"],
                        seen=[("Борис Тестов", "men", "senior"), ("Борис Тестов", "women", "senior")])
        self.assertEqual(self.by_name(got)["Борис Тестов"]["k"], "m")

    def test_seen_does_not_override_level_of_the_same_season(self):
        got = self.book(ru=[("Анна Тестова", "women", "junior", "2627")],
                        seen=[("Анна Тестова", "women", "senior")])
        self.assertEqual(self.by_name(got)["Анна Тестова"]["k"], "W")

    def test_pair_partner_without_kind_gets_pair_kind(self):
        got = self.by_name(self.book(
            cards=["Чернышова Анастасия Игоревна"],
            ru=[("Анастасия Чернышова / Владислав Вильчик", "pairs", "senior", "2627")]))
        self.assertEqual(got["Анастасия Чернышова"]["k"], "p")
        self.assertNotIn("Владислав Вильчик", got)  # своей записи нет — новой не заводим
        self.assertEqual(got["Анастасия Чернышова / Владислав Вильчик"]["k"], "p")

    def test_international_failure_keeps_previous_for_those_without_current_evidence(self):
        prev = [{"n": "Jane Doe", "c": "USA", "k": "w"}, {"n": "Bob Roe", "c": "USA", "k": "m"},
                {"n": "Ann Lee", "c": "USA", "k": "", "was": "p", "y": "2025/26"}]
        intl = [("Jane DOE", "USA", "dance", "senior", "", "2627"),   # есть текущее — верим найденному
                ("Bob ROE", "USA", "women", "senior", "", "2526"),    # только прошлое — держим прежнее
                ("Ann LEE", "USA", "women", "senior", "", "2526")]
        got = self.book(intl=intl, prev=prev, int_miss=[("sb2026-27/x.htm", "2627")])
        p = self.by_name(got)
        self.assertEqual(p["Jane Doe"]["k"], "d")
        self.assertEqual(p["Bob Roe"]["k"], "m")
        self.assertNotIn("was", p["Bob Roe"])
        self.assertEqual((p["Ann Lee"]["k"], p["Ann Lee"]["was"], p["Ann Lee"]["y"]), ("", "p", "2025/26"))
        self.assertIs(got["sure"]["INT"], False)
        self.assertIs(got["sure"]["RU"], True)

    def test_failure_without_previous_record_uses_old_kinds_without_was(self):
        intl = [("Bob ROE", "USA", "women", "senior", "", "2526")] + \
               [(f"Pl{chr(97 + i)} X{chr(97 + i)}", "USA", "women", "senior", "", s) for i in range(6) for s in ("2627", "2526")]
        got = self.book(intl=intl, int_miss=[("x", "2627")])
        p = self.by_name(got)["Bob Roe"]
        self.assertEqual(p["k"], "w")
        self.assertNotIn("was", p)

    def test_russian_failure_does_not_distrust_foreigners(self):
        prev = [{"n": "Bob Roe", "c": "USA", "k": "m"}]
        intl = [("Bob ROE", "USA", "women", "senior", "", "2526")]
        got = self.book(intl=intl, prev=prev, ru_miss=[("список соревнований", None)])
        self.assertEqual(got["sure"], {"RU": False, "INT": True})
        self.assertEqual(self.by_name(got)["Bob Roe"]["k"], "w")  # класс не открыт: прошлогодний вид остаётся

    def test_person_without_kinds_in_fresh_book_ages_previous_kind(self):
        prev = [{"n": "Анна Тестова", "c": "RUS", "k": "w"}]
        p = self.by_name(self.book(cards=["Тестова Анна Ивановна"], prev=prev))["Анна Тестова"]
        self.assertEqual((p["k"], p["was"], p["y"]), ("", "w", ""))

    def test_person_without_kinds_keeps_previous_when_source_failed(self):
        prev = [{"n": "Анна Тестова", "c": "RUS", "k": "w"}]
        p = self.by_name(self.book(cards=["Тестова Анна Ивановна"], prev=prev, ru_miss=[("x", None)]))["Анна Тестова"]
        self.assertEqual(p["k"], "w")
        self.assertNotIn("was", p)


class AgedTest(unittest.TestCase):
    SURE = {"RU": True, "INT": True}

    def test_missing_person_with_kind_becomes_was(self):
        prev = [{"n": "Анна Тестова", "c": "RUS", "k": "w", "p": "abc"}]
        got = people.aged(prev, {"people": [], "sure": self.SURE})
        self.assertEqual(got, [{"n": "Анна Тестова", "c": "RUS", "k": "", "was": "w", "y": "", "p": "abc"}])

    def test_present_person_untouched(self):
        prev = [{"n": "Анна Тестова", "c": "RUS", "k": "w"}]
        book = {"people": [{"n": "Анна Тестова", "c": "RUS", "k": "m"}], "sure": self.SURE}
        self.assertEqual(people.aged(prev, book), prev)

    def test_unsure_or_no_sure_changes_nothing(self):
        prev = [{"n": "Анна Тестова", "c": "RUS", "k": "w"}, {"n": "Jane Doe", "c": "USA", "k": "w"}]
        self.assertEqual(people.aged(prev, {"people": [], "sure": {"RU": True, "INT": False}}), prev)
        self.assertEqual(people.aged(prev, {"people": []}), prev)
        # сбой россиян не мешает верить отсутствию иностранца
        got = people.aged(prev, {"people": [], "sure": {"RU": False, "INT": True}})
        self.assertEqual(got[0], prev[0])
        self.assertEqual(got[1]["was"], "w")

    def test_entry_with_was_is_kept(self):
        prev = [{"n": "Анна Тестова", "c": "RUS", "k": "", "was": "w", "y": "2025/26"}]
        self.assertEqual(people.aged(prev, {"people": [], "sure": self.SURE}), prev)

    def test_input_is_not_mutated_and_none_is_ok(self):
        prev = [{"n": "Анна Тестова", "c": "RUS", "k": "w"}]
        people.aged(prev, {"people": [], "sure": self.SURE})
        self.assertEqual(prev, [{"n": "Анна Тестова", "c": "RUS", "k": "w"}])
        self.assertIsNone(people.aged(None, {"people": [], "sure": self.SURE}))
