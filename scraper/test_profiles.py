import json
import os
import tempfile
import unittest
from unittest import mock

from scraper import profiles as pf

BIO = """<table>
<tr><td>Pairs</td><td>Date of birth:</td><td>10.06.1999</td></tr>
<tr><td>Minerva Fabienne HASE</td><td>Place of birth:</td><td>Berlin</td><td>Height:</td><td>168 cm</td><td>GER</td></tr>
<tr><td>Start sk. / Club:</td><td>2004 / BSV 92 Berlin</td><td>Former Partners:</td><td>Nolan SEEGERT</td></tr>
<tr><td>Date of birth:</td><td>29.06.1999</td><td>Nikita VOLODIN</td><td>Place of birth:</td><td>St. Petersburg RUS</td>
<td>Height:</td><td>188 cm</td><td>Start sk. / Club:</td><td>2003 / Berliner SV 92</td><td>Former Partners:</td><td></td></tr>
<tr><td>Coach:</td><td>Dmitri Savin, Knut Schubert</td><td>Choreographer:</td><td>Mark Pillay &amp; Paul Boll</td></tr>
<tr><td>Music Short Program as of season 2026/2027</td><td>Composition by Maxime Rodriguez<br/>1989 by Laake</td></tr>
<tr><td>Music Free Skating / Free Dance as of season 2026/2027</td><td>The Four Seasons by Antonio Vivaldi<br/></td></tr>
<tr><td>Personal Best Total Score</td><td>228.33</td><td>26.03.2026</td><td>ISU World Championships 2026</td></tr>
<tr><td>Personal Best Score Short Program</td><td>80.01</td><td>15.02.2026</td><td>Olympic Winter Games 2026 Figure Skating</td></tr>
<tr><td>Season Best Score Free Skating</td><td>140.10</td><td>04.10.2026</td><td>ISU CS Nebelhorn Trophy 2026</td></tr>
</table>"""

CR = """<table>
<tr><td>Competition Results</td></tr>
<tr><td>Minerva Fabienne HASE / Nikita VOLODIN (GER)</td></tr>
<tr><td>Olympic Games</td></tr>
<tr><td>Olympic Winter Games 2026 Figure Skating</td><td>Pairs</td><td>3</td><td>GER</td></tr>
<tr><td>World Championships</td></tr>
<tr><td>ISU World Championships 2026</td><td>Pairs</td><td>1</td><td>GER</td></tr>
<tr><td>ISU Grand Prix</td></tr>
<tr><td>ISU GP Skate Canada International 2025</td><td>Pairs</td><td>2</td><td>GER</td></tr>
<tr><td>National Championships</td></tr>
<tr><td>National Championhsips 2026</td><td>Pairs</td><td>1</td><td>GER</td></tr>
<tr><td>National Championships 2019</td><td>Junior Pairs</td><td>WD</td><td></td></tr>
<tr><td>03/11/2026 04:28:18 UTC</td></tr>
</table>"""


class ParseTest(unittest.TestCase):
    def test_bio_two_partners(self):
        b = pf.parse_bio(BIO)
        self.assertEqual([w["n"] for w in b["who"]], ["Minerva Fabienne HASE", "Nikita VOLODIN"])
        self.assertEqual(b["who"][0], {"n": "Minerva Fabienne HASE", "born": "1999-06-10", "place": "Berlin",
                                       "h": 168, "since": 2004, "club": "BSV 92 Berlin", "former": ["Nolan SEEGERT"]})
        self.assertNotIn("former", b["who"][1])
        self.assertEqual(b["coach"], ["Dmitri Savin", "Knut Schubert"])
        self.assertEqual(b["choreo"], ["Mark Pillay & Paul Boll"])
        self.assertEqual(b["music"], {"season": "2026/27", "sp": ["Composition by Maxime Rodriguez", "1989 by Laake"],
                                      "fs": ["The Four Seasons by Antonio Vivaldi"]})
        self.assertEqual(b["pb"], [{"s": "total", "pts": "228.33", "d": "2026-03-26", "ev": "Чемпионат мира 2026"},
                                   {"s": "sp", "pts": "80.01", "d": "2026-02-15", "ev": "Олимпийские игры 2026"}])
        self.assertEqual(b["sb"], [{"s": "fs", "pts": "140.10", "d": "2026-10-04", "ev": "CS Nebelhorn Trophy 2026"}])

    def test_cr_groups(self):
        cr = pf.parse_cr(CR)
        self.assertEqual([g["g"] for g in cr], ["Olympic Games", "World Championships", "ISU Grand Prix",
                                                "National Championships"])
        self.assertEqual(cr[0]["r"], [{"ev": "Olympic Winter Games 2026 Figure Skating", "k": "p", "pl": 3, "c": "GER"}])
        self.assertEqual(cr[3]["r"][1], {"ev": "National Championships 2019", "k": "P", "pl": "WD"})

    def test_cr_two_starts_in_one_row(self):
        # ISU пишет взрослый чемпионат и юниорское первенство одной строкой — делим на две
        page = """<table><tr><td>National Championships</td></tr>
<tr><td></td><td>National Championships 2021</td><td><span>Men, Junior Men,&nbsp;</span></td>
<td>11, 1,&nbsp;</td><td></td><td>RUS, RUS,&nbsp;</td></tr>
<tr><td></td><td>National Championships 2020</td><td>Junior Men, Men,</td><td>3, 9,</td><td></td><td>RUS, RUS,</td></tr>
<tr><td></td><td>National Championships 2019</td><td>Men, Junior Men,</td><td>4,</td><td></td><td>RUS,</td></tr>
</table>"""
        rows = pf.parse_cr(page)[0]["r"]
        self.assertEqual(rows[:4], [
            {"ev": "National Championships 2021", "k": "m", "pl": 11, "c": "RUS"},
            {"ev": "National Championships 2021", "k": "M", "pl": 1, "c": "RUS"},
            {"ev": "National Championships 2020", "k": "M", "pl": 3, "c": "RUS"},
            {"ev": "National Championships 2020", "k": "m", "pl": 9, "c": "RUS"},
        ])
        # списки не сходятся — места нет, но и сырой строки «4,» нет
        self.assertEqual(rows[4], {"ev": "National Championships 2019", "k": "", "pl": ""})
        self.assertEqual(len(rows), 5)
        self.assertFalse(pf.stale_cr(pf.parse_cr(page)))
        self.assertTrue(pf.stale_cr([{"g": "National Championships", "r": [{"ev": "x", "k": "", "pl": "11, 1,"}]}]))
        self.assertFalse(pf.stale_cr([{"g": "x", "r": [{"ev": "x", "k": "m", "pl": "WD"}]}]))

    def test_event_names(self):
        self.assertEqual(pf.event_ru("ISU GP Grand Prix de France 2024"), "GP de France 2024")
        self.assertEqual(pf.event_ru("ISU GP Skate Canada International 2025"), "GP Skate Canada 2025")
        self.assertEqual(pf.event_ru("ISU JGP Kosice 2021, Kosice"), "JGP Kosice 2021")
        self.assertEqual(pf.event_ru("ISU Grand Prix Final 2024/25"), "Финал Гран-при 2024/25")
        self.assertEqual(pf.event_ru("ISU World Junior Championships 2025"), "Чемпионат мира среди юниоров 2025")
        self.assertEqual(pf.event_ru("XXIV Olympic Winter Games 2022"), "Олимпийские игры 2022")
        self.assertEqual(pf.event_ru("JGP Final 2009/2010"), "Финал юниорского Гран-при 2009/10")
        self.assertEqual(pf.event_ru("National Championships 2026", "RUS", "w"), "Чемпионат России 2026")
        self.assertEqual(pf.event_ru("National Championships 2026", "AIN2", "W"), "Первенство России 2026")
        self.assertEqual(pf.event_ru("National Championships 2026", "GER", "p"), "Чемпионат Германии 2026")
        self.assertEqual(pf.event_ru("National Championships 2026", "XYZ", "p"), "Национальный чемпионат 2026")

    def test_season_of(self):
        self.assertEqual(pf.season_of("Чемпионат мира 2026"), "2025/26")
        self.assertEqual(pf.season_of("Финал Гран-при 2025"), "2025/26")
        self.assertEqual(pf.season_of("Финал Гран-при 2024/25"), "2024/25")
        self.assertEqual(pf.season_of("Budapest Trophy"), "")


class ProfileTest(unittest.TestCase):
    def store(self):
        return {"at": "2026-11-05T10:00:00+00:00", "bio": pf.parse_bio(BIO), "cr": pf.parse_cr(CR)}

    def test_pair_profile(self):
        p = pf.profile("Minerva Fabienne Hase / Nikita Volodin", "GER", self.store())
        self.assertEqual([w["n"] for w in p["who"]], ["Minerva Fabienne Hase", "Nikita Volodin"])
        self.assertEqual(p["who"][0]["former"], ["Nolan Seegert"])
        self.assertEqual(p["src"], ["ISU"])
        # два раздела: всё, кроме национальных чемпионатов, — международные
        self.assertEqual([g["g"] for g in p["res"]], ["Международные", "Внутренние"])
        self.assertTrue(all(r["ev"].startswith("Чемпионат Германии") or "Национальный" in r["ev"]
                            for r in p["res"][1]["r"]))
        # титулы — только пьедесталы главных турниров, Гран-при — не титул; внутри сезона — по весу
        self.assertEqual([(t["ev"], t["pl"], t["y"]) for t in p["titles"]],
                         [("Олимпийские игры 2026", 3, "2025/26"), ("Чемпионат мира 2026", 1, "2025/26"),
                          ("Чемпионат Германии 2026", 1, "2025/26")])

    def test_two_groups(self):
        out = pf.two_groups([
            ("ISU Grand Prix", [{"ev": "GP Rostelecom Cup 2020"}]),
            ("ISU Junior Grand Prix", [{"ev": "JGP Cup of Austria 2017"}]),
            ("ISU Challenger Series", [{"ev": "CS Finlandia Trophy 2021"}, {"ev": "CS 34th Nepela Memorial 2026"}]),
            ("International Competition", [{"ev": "Minsk Arena Ice Star 2020"}]),
            ("National Championships", [{"ev": "Чемпионат России 2024"}, {"ev": "Чемпионат России 2026"}]),
        ])
        self.assertEqual([g["g"] for g in out], ["Международные", "Внутренние"])
        # от новых к старым; при равном годе — как у ISU (Гран-при раньше приглашённых)
        self.assertEqual([r["ev"] for r in out[0]["r"]],
                         ["CS 34th Nepela Memorial 2026", "CS Finlandia Trophy 2021", "GP Rostelecom Cup 2020",
                          "Minsk Arena Ice Star 2020", "JGP Cup of Austria 2017"])
        self.assertEqual([r["ev"] for r in out[1]["r"]], ["Чемпионат России 2026", "Чемпионат России 2024"])
        self.assertEqual(pf.two_groups([("National Championships", [{"ev": "Чемпионат России 2026"}])]),
                         [{"g": "Внутренние", "r": [{"ev": "Чемпионат России 2026"}]}])
        self.assertEqual(pf.two_groups([]), [])

    def test_two_starts_in_profile(self):
        page = """<table><tr><td>National Championships</td></tr>
<tr><td>National Championships 2021</td><td>Men, Junior Men,</td><td>11, 1,</td><td>RUS, RUS,</td></tr></table>"""
        st = {"at": "2026-11-05T10:00:00+00:00", "bio": {}, "cr": pf.parse_cr(page)}
        p = pf.profile("Евгений Семененко", "RUS", st)
        self.assertEqual(p["res"], [{"g": "Внутренние", "r": [
            {"ev": "Чемпионат России 2021", "k": "m", "pl": 11},
            {"ev": "Первенство России 2021", "k": "M", "pl": 1}]}])
        # старый кэш (до деления строк) — прочерк, а не «11, 1,»
        old = {"at": "2026-11-05T10:00:00+00:00", "bio": {},
               "cr": [{"g": "National Championships", "r": [{"ev": "National Championships 2021", "k": "", "pl": "11, 1,"}]}]}
        p = pf.profile("Евгений Семененко", "RUS", old)
        self.assertEqual(p["res"], [{"g": "Внутренние", "r": [{"ev": "Чемпионат России 2021"}]}])

    def test_partner_count_mismatch_keeps_only_names(self):
        p = pf.profile("Minerva Fabienne Hase", "GER", self.store())
        self.assertEqual(p["who"], [{"n": "Minerva Fabienne Hase"}])

    def test_card_overrides_isu_in_russian(self):
        card = {"born": "2007-06-05", "rank": "МС", "region": "Москва", "club": ["МАФКК"],
                "coach": ["Гончаренко Инна Валерьевна"], "choreo": [], "results": [
                    {"season": "2025-2026", "event": "Чемпионат России", "place": "1 (МС)"}], "at": "2026-11-05T15:00:00"}
        store = {"at": "2026-11-01T00:00:00+00:00", "bio": {"who": [{"n": "Adeliia PETROSIAN", "h": 152}],
                                                            "coach": ["Inna Goncharenko"], "fcoach": ["Eteri Tutberidze"]},
                 "cr": []}
        p = pf.profile("Аделия Петросян", "RUS", store, card)
        self.assertEqual(p["who"], [{"n": "Аделия Петросян", "h": 152, "born": "2007-06-05", "rank": "МС",
                                     "region": "Москва", "club": "МАФКК"}])
        self.assertEqual(p["coach"], ["Гончаренко Инна Валерьевна"])
        self.assertNotIn("fcoach", p)  # прежние тренеры ISU рядом с тренером из картотеки путают
        self.assertEqual(p["season"], [{"s": "2025/26", "ev": "Чемпионат России", "pl": "1 (МС)"}])
        self.assertEqual(p["src"], ["ISU", "ФФККР"])

    def test_card_behind_isu_takes_isu_coach_and_club(self):
        # картотека ещё пишет прежних тренеров и их школу, а у ISU они уже в прежних
        card = {"born": "2007-06-05", "rank": "МС", "region": "Москва", "club": ['МАФКК, школа "Хрустальный"'],
                "coach": ["Тутберидзе Этери Георгиевна", "Дудаков Сергей Викторович"], "choreo": [], "results": [],
                "at": "2026-11-05T15:00:00"}
        store = {"at": "2026-11-05T15:30:00+00:00",
                 "bio": {"who": [{"n": "Adeliia PETROSIAN", "h": 152, "club": "Moscow Academy of Figure Skating"}],
                         "coach": ["Inna Goncharenko"], "fcoach": ["Eteri Tutberidze", "Sergei Dudako"],
                         "choreo": ["Anjelika Krylova", "Someone Unknown"]},
                 "cr": []}
        staff = ["Тутберидзе Этери Георгиевна", "Дудаков Сергей Викторович", "Крылова Анжелика Алексеевна"]
        p = pf.profile("Аделия Петросян", "RUS", store, card, staff=staff)
        self.assertEqual(p["coach"], ["Гончаренко Инна"])
        self.assertEqual(p["fcoach"], ["Тутберидзе Этери Георгиевна", "Дудаков Сергей Викторович"])
        self.assertEqual(p["choreo"], ["Крылова Анжелика Алексеевна", "Someone Unknown"])  # не знаем — как в ISU
        self.assertEqual(p["who"][0]["club"], "МАФКК")
        self.assertEqual(p["who"][0]["rank"], "МС")  # остальное из картотеки остаётся

    def test_card_behind_without_isu_club_leaves_dash(self):
        card = {"club": ['школа "Хрустальный"'], "coach": ["Тутберидзе Этери Георгиевна"], "results": []}
        store = {"bio": {"who": [{"n": "X Y"}], "coach": ["Inna Goncharenko"], "fcoach": ["Eteri Tutberidze"]}, "cr": []}
        p = pf.profile("Аделия Петросян", "RUS", store, card)
        self.assertNotIn("club", p["who"][0])

    def test_card_not_behind_when_isu_still_lists_coach(self):
        card = {"coach": ["Тутберидзе Этери Георгиевна"]}
        self.assertFalse(pf.card_behind(card, {"coach": ["Eteri Tutberidze"], "fcoach": ["Eteri Tutberidze"]}))
        self.assertFalse(pf.card_behind(card, {"coach": ["Inna Goncharenko"], "fcoach": ["Alexei Mishin"]}))
        self.assertTrue(pf.card_behind(card, {"coach": ["Inna Goncharenko"], "fcoach": ["Etery Tutberidze"]}))

    def test_staff_same_person_not_namesake(self):
        self.assertTrue(pf._same_staff("Дудаков Сергей Викторович", "Sergei Dudako"))
        self.assertTrue(pf._same_staff("Крылова Анжелика Алексеевна", "Anzhelika Krylova"))
        self.assertFalse(pf._same_staff("Мишина Татьяна Николаевна", "Anastasia Mishina"))
        self.assertFalse(pf._same_staff("Жулин Александр Вячеславович", "Andrei Zhulin"))

    def test_card_quotes(self):
        self.assertEqual(pf.ru_quotes('СК "Центр ФК Этери Тутберидзе"'), "СК «Центр ФК Этери Тутберидзе»")
        self.assertEqual(pf.ru_quotes('"Гран При России – Звезды Магнитки"'), "«Гран При России – Звезды Магнитки»")

    def test_no_source_no_profile(self):
        self.assertIsNone(pf.profile("Иван Иванов", "RUS"))


class StoreTest(unittest.TestCase):
    def test_refresh_order_budget_and_write(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "bios.json")
            pages = {pf.BIO.format("1"): BIO, pf.CR.format("1"): CR, pf.BIO.format("2"): BIO, pf.CR.format("2"): CR}
            with mock.patch.object(pf.net, "fetch", side_effect=lambda u, **k: pages[u]):
                s = pf.refresh({"a": "1", "b": "2"}, log=lambda *a: None, path=path, budget=1)
                self.assertEqual(len(s["bios"]), 1)
                s = pf.refresh({}, log=lambda *a: None, path=path, budget=5)
            self.assertEqual(sorted(s["bios"]), ["1", "2"])
            self.assertEqual(s["ids"], {"a": "1", "b": "2"})  # номера копятся между сборами
            with open(path, encoding="utf-8") as f:
                self.assertEqual(json.load(f)["ids"], {"a": "1", "b": "2"})
            people = [{"n": "Minerva Fabienne Hase / Nikita Volodin", "c": "GER", "k": "p"},
                      {"n": "Иван Иванов", "c": "RUS", "k": "m", "p": "old"}]
            from scraper import names as nm
            s["ids"] = {nm.key(people[0]["n"]): "1"}
            pf.write(people, s, {}, out_dir=os.path.join(d, "p"), log=lambda *a: None)
            self.assertEqual(people[0]["p"], pf.key(people[0]["n"]))
            self.assertNotIn("p", people[1])  # профиля больше нет — и ключа нет
            with open(os.path.join(d, "p", people[0]["p"] + ".json"), encoding="utf-8") as f:
                self.assertEqual(json.load(f)["n"], people[0]["n"])

    def test_competed_after_check_goes_first(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "bios.json")
            got = []
            with mock.patch.object(pf.net, "fetch", side_effect=lambda u, **k: got.append(u) or (BIO if "_cr_" not in u else CR)):
                pf.refresh({"a": "1", "b": "2"}, log=lambda *a: None, path=path, budget=5,
                           now=pf.dt.datetime(2026, 11, 1, tzinfo=pf.dt.timezone.utc))
                got.clear()
                pf.refresh({}, {"b": "2026-11-03T00:00:00+00:00"}, log=lambda *a: None, path=path, budget=5,
                           now=pf.dt.datetime(2026, 11, 4, tzinfo=pf.dt.timezone.utc))
            self.assertEqual(got, [pf.BIO.format("2"), pf.CR.format("2")])  # «a» свежая, «b» выступил после проверки

    def test_stale_cr_refetched_first(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "bios.json")
            fresh = "2026-11-03T00:00:00+00:00"
            old = [{"g": "National Championships", "r": [{"ev": "National Championships 2021", "k": "", "pl": "11, 1,"}]}]
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"ids": {"a": "1", "b": "2"},
                           "bios": {"1": {"at": fresh, "bio": {}, "cr": []}, "2": {"at": fresh, "bio": {}, "cr": old}}}, f)
            got = []
            with mock.patch.object(pf.net, "fetch", side_effect=lambda u, **k: got.append(u) or (BIO if "_cr_" not in u else CR)):
                s = pf.refresh({}, log=lambda *a: None, path=path, budget=5,
                               now=pf.dt.datetime(2026, 11, 4, tzinfo=pf.dt.timezone.utc))
            self.assertEqual(got, [pf.BIO.format("2"), pf.CR.format("2")])  # «1» свежая, у «2» неразделённая строка
            self.assertFalse(pf.stale_cr(s["bios"]["2"]["cr"]))

    def test_bio_lists_split_by_line(self):
        page = ("<table><tr><td>Coach:</td><td>Inna Goncharenko<br>Artem Fedorchenko</td></tr>"
                "<tr><td>Choreographer:</td><td>-</td></tr></table>")
        self.assertEqual(pf.parse_bio(page), {"coach": ["Inna Goncharenko", "Artem Fedorchenko"]})

    def test_stale_bio(self):
        self.assertTrue(pf.stale_bio({"coach": ["Inna Goncharenko | Artem Fedorchenko"]}))
        self.assertTrue(pf.stale_bio({"choreo": ["-"]}))
        self.assertTrue(pf.stale_bio({"who": [{"n": "A", "former": ["B | C"]}]}))
        self.assertFalse(pf.stale_bio({"coach": ["Inna Goncharenko", "Artem Fedorchenko"]}))
        self.assertFalse(pf.stale_bio(None))


class ArchiveProfiles(unittest.TestCase):
    NAMES = type("N", (), {"to_ru": staticmethod(lambda n: {"Evgenia MEDVEDEVA": "Евгения Медведева",
                                                            "Alina ZAGITOVA": "Alina Zagitova"}.get(n, n))})()
    ROWS = [["Evgenia MEDVEDEVA", "RUS", "00014068", "w"], ["Alina ZAGITOVA", "RUS", "00101053", "w"],
            ["Nathan CHEN", "USA", "00099999", "m"], ["Anna SHCHERBAKOVA", "RUS", "00103103", "w"]]

    def test_ids_by_table_row(self):
        people = [{"n": "Евгения Медведева", "c": "RUS", "k": "", "was": "w"},
                  {"n": "Alina Zagitova", "c": "RUS", "was": "w"},
                  {"n": "Nathan Chen", "c": "USA", "was": "m"},
                  {"n": "Анна Щербакова", "c": "RUS", "k": "d"},      # танцовщица — одиночной таблицы ей не годится
                  {"n": "Виктория Синицына", "c": "RUS", "was": "w"}]  # строки нет — ничего не угадываем
        got = pf.archive_ids(people, self.ROWS, self.NAMES)
        self.assertEqual(got, {pf.nm.key("Евгения Медведева"): "00014068", pf.nm.key("Alina Zagitova"): "00101053",
                               pf.nm.key("Nathan Chen"): "00099999"})
        # у кого номер уже есть — не трогаем
        self.assertNotIn(pf.nm.key("Nathan Chen"), pf.archive_ids(people, self.ROWS, self.NAMES, {pf.nm.key("Nathan Chen")}))

    def test_foreign_bio_does_not_fit_other_kind(self):
        bio = {"cr": [{"k": "w"}, {"k": "W"}]}
        self.assertTrue(pf.bio_fits(bio, {"w"}))
        self.assertFalse(pf.bio_fits(bio, {"d"}))
        self.assertTrue(pf.bio_fits({"cr": []}, {"d"}))   # видов у ISU нет — не отказываем
        self.assertTrue(pf.bio_fits(bio, set()))

    def test_profile_from_archive_when_there_is_no_bio(self):
        people = [{"n": "Евгения Медведева", "c": "RUS", "k": "", "was": "w", "y": "2019/20"}]
        intl = {pf.nm.key("Евгения Медведева"): {"total": {"pts": "225.76", "ev": "ЧЕ 2019", "d": "2019-01-25"},
                                                "sp": {"pts": "76.93", "ev": "ЧЕ 2019", "d": "2019-01-23"}}}
        with tempfile.TemporaryDirectory() as d:
            pf.write(people, {"ids": {}, "bios": {}}, {}, out_dir=d, log=lambda *a: None, aliases={}, intl=intl,
                     bests_from="2018/19")
            self.assertTrue(people[0]["p"])
            with open(os.path.join(d, people[0]["p"] + ".json"), encoding="utf-8") as f:
                pr = json.load(f)
        self.assertEqual([(x["s"], x["pts"]) for x in pr["pb"]], [("total", "225.76"), ("sp", "76.93")])
        self.assertEqual((pr["pb_from"], pr["src"]), ("2018/19", ["ISU"]))
        # нечего показать — профиля нет
        nobody = [{"n": "Никто Неизвестный", "c": "RUS", "k": "", "was": "m"}]
        with tempfile.TemporaryDirectory() as d:
            pf.write(nobody, {"ids": {}, "bios": {}}, {}, out_dir=d, log=lambda *a: None, aliases={}, intl={})
        self.assertNotIn("p", nobody[0])


if __name__ == "__main__":
    unittest.main()


class AliasTest(unittest.TestCase):
    """Картотека пишет фамилию по мужу, а знают по прежней: карточка (звание, регион) — тому же профилю."""

    def test_card_under_married_name_goes_to_known_profile(self):
        card = {"fio": "Игнатова Александра Вячеславовна", "born": "2004-06-23", "rank": "ЗМС", "region": "Москва",
                "club": [], "coach": [], "choreo": [], "partner": [], "results": [], "at": "2026-11-05T00:00:00+00:00"}
        people = [{"n": "Александра Трусова", "c": "RUS", "k": "w"}]
        with tempfile.TemporaryDirectory() as d:
            pf.write(people, {"ids": {}, "bios": {}}, {"138": card}, out_dir=d, log=lambda *a: None,
                     aliases={"Александра Игнатова": "Александра Трусова"})
            with open(os.path.join(d, people[0]["p"] + ".json"), encoding="utf-8") as f:
                who = json.load(f)["who"][0]
        self.assertEqual((who["rank"], who["region"], who["born"]), ("ЗМС", "Москва", "2004-06-23"))

    def test_config_alias_is_read(self):
        from scraper import names as nm
        self.assertEqual(nm.aliases().get("Александра Игнатова"), "Александра Трусова")

    def test_people_from_card_use_alias(self):
        from scraper import names as nm
        from scraper import people as pp
        names = nm.Names(None, {"Александра Игнатова": "Александра Трусова"})
        card = {"138": {"fio": "Игнатова Александра Вячеславовна", "photo": ""}}
        with mock.patch.object(pp, "_load", return_value={}), mock.patch.object(pp, "_save"), \
                mock.patch.object(pp, "isu_russians", return_value=[]), mock.patch.object(pp, "cards", return_value=card), \
                mock.patch.object(pp, "russians", return_value=[]), mock.patch.object(pp, "internationals", return_value=[]), \
                mock.patch.object(pp, "isu_photos", return_value=[]), \
                mock.patch.object(pp, "wikidata_photos", return_value=([], True)), \
                mock.patch("scraper.fsr.team", return_value=[]), \
                mock.patch("scraper.photos.load_hand", return_value=[]):
            got = pp.build(names, "2026-07-01", log=lambda *a: None)
        self.assertEqual([p["n"] for p in got["people"]], ["Александра Трусова"])


class CleanupTest(unittest.TestCase):
    def card(self, fio):
        return {"fio": fio, "born": "2004-06-23", "rank": "МС", "region": "Москва", "club": [], "coach": [],
                "choreo": [], "partner": [], "results": [], "at": "2026-11-05T00:00:00+00:00"}

    def test_orphan_files_removed_but_not_after_partial_run(self):
        cards = {str(i): self.card(f"Фамилия{i} Имя Отчество") for i in range(4)}
        people = [{"n": f"Имя Фамилия{i}", "c": "RUS", "k": "w"} for i in range(4)]
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, "orphan000000.json"), "w").close()
            pf.write(people, {"ids": {}, "bios": {}}, cards, out_dir=d, log=lambda *a: None, aliases={})
            self.assertEqual(sorted(os.listdir(d)), sorted(p["p"] + ".json" for p in people))
            # следующий сбор вернул одного человека из четырёх — источники сбоили: файлы остаются
            pf.write(people[:1], {"ids": {}, "bios": {}}, cards, out_dir=d, log=lambda *a: None, aliases={})
            self.assertEqual(len(os.listdir(d)), 4)
