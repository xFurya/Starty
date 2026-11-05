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
        self.assertEqual([g["g"] for g in p["res"]], ["Олимпийские игры", "Чемпионаты мира", "Гран-при",
                                                       "Национальные чемпионаты"])
        # титулы — только пьедесталы главных турниров, Гран-при — не титул; внутри сезона — по весу
        self.assertEqual([(t["ev"], t["pl"], t["y"]) for t in p["titles"]],
                         [("Олимпийские игры 2026", 3, "2025/26"), ("Чемпионат мира 2026", 1, "2025/26"),
                          ("Чемпионат Германии 2026", 1, "2025/26")])

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


if __name__ == "__main__":
    unittest.main()
