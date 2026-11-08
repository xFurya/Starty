"""Архив элементов: что считается чистым исполнением, как копится, какие строки дают профилю.

Настоящие протоколы — scraper/fixtures/protocol/archive/*.txt (pdftotext -layout): произвольная
программа мужчин Мемориала Дениса Тена 2026 (у Лутфуллина чистый 4T+3A+3A+SEQ, база 25.50) и
второго этапа Гран-при России 2026 (тот же элемент с недокрученным 3A).
"""
import json
import os
import tempfile
import unittest
from unittest import mock

from scraper import archive as ar
from scraper import results as rs
from scraper import swisstiming as st

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "protocol", "archive")
TEN = "https://www.denistenmemorial.kz/results/FSKMSINGLES-----------FNL-000100--_JudgesDetailsperSkater.pdf"
FSR = "https://fsrussia.ru/results/2627/2etap_sen/FSKMSINGLES-----------FNL-000100--_JudgesDetailsperSkater.pdf"


def el(code, base=10.0, judges=(1, 1, 1), info="", goe=0.5, **kw):
    return dict({"code": code, "info": info, "base": base, "goe": goe, "judges": list(judges),
                 "score": round(base + goe, 2)}, **kw)


def sk(name, *elements, nation="USA", components=()):
    return {"name": name, "nation": nation, "elements": list(elements), "components": list(components)}


def meta(u, d="2024-11-01", kind="men", ev="Турнир", seg="ПП", level="senior", src="ISU"):
    return {"u": u, "ev": ev, "d": d, "kind": kind, "level": level, "seg": seg, "src": src}


SYL = ["ba", "ko", "ri", "mu", "te", "lo", "sa", "vi", "de", "nu"]


def many(prefix, n):
    """n разных фамилий: names.key сводит цифры и двойные буквы, поэтому — слоги."""
    return [f"{prefix} {SYL[i // 100]}{SYL[i // 10 % 10]}{SYL[i % 10]}ov" for i in range(n)]


def real(name):
    with open(os.path.join(FIX, name + ".txt"), encoding="utf-8") as f:
        return st.parse_judges(f.read())


class ItemsTest(unittest.TestCase):
    def test_clean_combo_and_its_jumps(self):
        self.assertEqual(ar.items(el("4T+3A+3A+SEQ", 25.5)), [("4T", None), ("3A", None), ("4T+3A+3A+SEQ", 25.5)])
        self.assertEqual(ar.items(el("4Lz", 11.5)), [("4Lz", 11.5)])
        self.assertEqual(ar.items(el("3Lz+3T", 10.1)), [])  # без четверных и акселя — не в архив

    def test_flip_is_not_a_fall(self):
        self.assertEqual(ar.items(el("4F", 11.0)), [("4F", 11.0)])
        self.assertEqual(ar.items(el("4F+3T", 15.2)), [("4F", None), ("4F+3T", 15.2)])

    def test_fall_by_mark_or_judges(self):
        self.assertEqual(ar.items(el("4Lz", 11.5, info="F")), [])
        self.assertEqual(ar.items(el("4LzF", 11.5)), [])
        self.assertEqual(ar.items(el("4Fq", 11.0, judges=(-5, -4, -4, -4, -5, -3, -4), info="q")), [])

    def test_under_rotation_belongs_to_its_jump(self):
        # недокрут у 3A: каскада нет, 4T — чистый
        self.assertEqual(ar.items(el("4T+3A<+3A+SEQ", 23.9, info="<")), [("4T", None), ("3A", None)])
        # отметка только в графе info — чей недокрут, не видно: элемент целиком неполный
        self.assertEqual(ar.items(el("4T+3A", 17.5, info="<")), [])
        # q — засчитан полностью
        self.assertEqual(ar.items(el("4Lzq", 11.5, info="q")), [("4Lz", 11.5)])
        self.assertEqual(ar.items(el("4Lz<<", 4.2, info="<<")), [])

    def test_second_half_bonus_and_repeat(self):
        self.assertEqual(ar.items(el("4S+3T", 15.29, x=True)), [("4S", None), ("4S+3T", 13.9)])
        self.assertEqual(ar.items(el("4T+REP", 6.65)), [("4T", None)])

    def test_throws_and_twists(self):
        self.assertEqual(ar.items(el("4STh", 7.5)), [("4STh", None)])
        self.assertEqual(ar.items(el("3ATh", 7.5)), [("3ATh", None)])
        self.assertEqual(ar.items(el("3LzTh", 6.0)), [])
        self.assertEqual(ar.items(el("4STh<", 6.0, info="<")), [])
        self.assertEqual(ar.items(el("4Tw2", 8.0)), [("4Tw", None)])
        self.assertEqual(ar.items(el("3Tw4", 6.2)), [])

    def test_quads_in_program(self):
        s = sk("A", el("4Lz+3T"), el("4F<", info="<"), el("4S", info="F"), el("4T+4T"))
        self.assertEqual(ar.quads(s), ["4Lz", "4T", "4T"])


class TitleTest(unittest.TestCase):
    def test_titles(self):
        self.assertEqual(ar.title("4Lz"), "Четверной лутц")
        self.assertEqual(ar.title("4A"), "Четверной аксель")
        self.assertEqual(ar.title("3A"), "Тройной аксель")
        self.assertEqual(ar.title("4T+3A+3A+SEQ"), "Секвенция 4T+3A+3A")
        self.assertEqual(ar.title("4Lz+3T"), "Каскад 4Lz+3T")
        self.assertEqual(ar.title("4STh"), "Четверной выброс сальхов")
        self.assertEqual(ar.title("3ATh"), "Тройной аксель выбросом")
        self.assertEqual(ar.title("4Tw"), "Четверная подкрутка")

    def test_signature_merges_variants(self):
        self.assertEqual(ar.signature("4Lz+3T"), ar.signature("4Lz+1Eu+3S+SEQ"))
        self.assertNotEqual(ar.signature("4Lz+3T"), ar.signature("4Lz"))
        self.assertEqual(ar.signature("4T+3A+3A+SEQ"), "+3A+3A+4T")

    def test_source_of(self):
        self.assertEqual(ar.source_of("https://results.isu.org/results/season2627/gpfra2026/x.pdf", "GP"), "ISU")
        self.assertEqual(ar.source_of("https://fsrussia.ru/results/2627/x.pdf", "Гран-при России"), "ФФККР")
        self.assertEqual(ar.source_of("https://ffkm.ru/results/x.pdf", "Чемпионат Москвы"), "ФФКМ")
        self.assertEqual(ar.source_of(TEN, "CS Denis Ten Memorial"), "CS Denis Ten Memorial")


class IngestTest(unittest.TestCase):
    def test_once_per_protocol_and_not_before_2018(self):
        arc = ar.empty()
        self.assertTrue(ar.ingest(arc, [sk("Ilia MALININ", el("4A", 12.5))], meta("a.pdf")))
        self.assertFalse(ar.ingest(arc, [sk("Ilia MALININ", el("4A", 12.5))], meta("a.pdf")))
        self.assertFalse(ar.ingest(arc, [sk("Nathan CHEN", el("4Lz", 11.5))], meta("old.pdf", d="2018-03-20")))
        self.assertFalse(ar.ingest(arc, [], meta("empty.pdf")))
        a = arc["ath"]["ilia malinin"]
        self.assertEqual(a["el"]["4A"], [1, 0, 12.5, 0])
        self.assertEqual(len(arc["segs"]), 1)
        self.assertNotIn("chen nathan", arc["ath"])

    def test_first_is_earliest_by_date_not_by_order(self):
        arc = ar.empty()
        ar.ingest(arc, [sk("Ilia MALININ", el("4A", 12.5))], meta("late.pdf", d="2025-03-28"))
        ar.ingest(arc, [sk("Ilia MALININ", el("4A", 12.5))], meta("early.pdf", d="2022-09-14"))
        n, first, base, bi = arc["ath"]["ilia malinin"]["el"]["4A"]
        self.assertEqual((n, arc["segs"][first][0], arc["segs"][bi][0]), (2, "early.pdf", "early.pdf"))

    def test_cyrillic_name_nations_unanimous_marks(self):
        arc = ar.empty()
        comps = [{"name": "Composition", "judges": [10, 10, 10]}, {"name": "Presentation", "judges": [10, 9.75, 10]}]
        ar.ingest(arc, [sk("Gleb LUTFULLIN", el("4Lo", judges=(5, 5, 5)), nation="AIN2", components=comps)], meta("a.pdf"))
        ar.ingest(arc, [sk("Глеб ЛУТФУЛЛИН", el("3A", 8.0), nation="СПБ")], meta("b.pdf", d="2026-10-25", src="ФФККР"))
        a = arc["ath"]["gleb lutfulin"]
        self.assertEqual((a["n"], a["c"]), ("Глеб ЛУТФУЛЛИН", ["AIN2", "СПБ"]))
        self.assertEqual((a["p5"], a["c10"]), ({"4Lo": 0}, {"Composition": 0}))

    def test_most_quads_program(self):
        arc = ar.empty()
        ar.ingest(arc, [sk("A B", el("4Lz"), el("4F"))], meta("a.pdf"))
        ar.ingest(arc, [sk("A B", el("4Lz"), el("4F"), el("4T+3T"))], meta("b.pdf", d="2025-01-01"))
        ar.ingest(arc, [sk("A B", el("4Lz"), el("4F"), el("4S"))], meta("c.pdf", d="2024-01-01"))
        self.assertEqual(arc["ath"]["a b"]["q"], [3, 2, "4Lz 4F 4S"])  # при равенстве — раньше по дате

    def test_save_and_load(self):
        arc = ar.empty()
        ar.ingest(arc, [sk("Ilia MALININ", el("4A", 12.5)), sk("Nathan CHEN", el("4Lz", 11.5))], meta("a.pdf"))
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "archive.json")
            ar.save(arc, path)
            with open(path, encoding="utf-8") as f:
                text = f.read()
            back = ar.load(path)
            arc["full"] = True
            ar.save(arc, path)
            self.assertTrue(ar.load(path)["full"])
        self.assertEqual(json.loads(text)["ath"], arc["ath"])
        self.assertEqual(back["pop"], {"men|senior": ["chen nathan", "ilia malinin"]})
        self.assertNotIn("_idx", text)
        self.assertTrue(any(x.startswith('"ilia malinin": {') for x in text.splitlines()))  # спортсмен — своя строка
        self.assertTrue(ar.has(back, "a.pdf"))
        self.assertNotIn("full", back)
        self.assertEqual(ar.load(os.path.join(d, "нет.json")), ar.empty())


class ProfileTest(unittest.TestCase):
    def setUp(self):
        self.arc = ar.empty()
        ar.ingest(self.arc, real("denisten_men_fs"), meta(TEN, d="2026-10-10", ev="CS Denis Ten Memorial",
                                                          src="CS Denis Ten Memorial"))
        ar.ingest(self.arc, real("fsr_2etap_men_fs"), meta(FSR, d="2026-10-25", ev="Гран-при России «Невский лёд»",
                                                           src="ФФККР"))
        self.arc["full"] = True

    def test_nothing_until_past_seasons_are_in(self):
        self.arc.pop("full")
        self.assertEqual(ar.for_profile("Глеб Лутфуллин", "RUS", ar.Index(self.arc)), [])

    def test_lutfullin_most_expensive_jump_element(self):
        idx = ar.Index(self.arc)
        fe = ar.for_profile("Глеб Лутфуллин", "RUS", idx)
        self.assertEqual(fe[0], {"t": "Самый дорогой прыжковый элемент с 2018 года: 4T+3A+3A", "pts": "25.50",
                                 "ev": "CS Denis Ten Memorial, произвольная программа", "d": "2026-10-10",
                                 "src": "CS Denis Ten Memorial", "u": TEN, "g": ar.GROUP["record"]})
        # тот же элемент с недокрученным 3A на втором этапе в рекорд не идёт
        n, first, base, bi = self.arc["ath"]["gleb lutfulin"]["el"]["4T+3A+3A+SEQ"]
        self.assertEqual((n, self.arc["segs"][bi][0]), (1, TEN))

    def test_namesake_from_elsewhere_gets_nothing(self):
        idx = ar.Index(self.arc)
        self.assertEqual(ar.for_profile("Глеб Лутфуллин", "USA", idx), [])
        self.assertEqual(ar.for_profile("Нет Такого", "RUS", idx), [])
        self.assertEqual(ar.for_profile("Глеб Лутфуллин", "RUS", None), [])

    def test_women_record_is_qualified_and_rare_is_by_signature(self):
        arc = ar.empty()
        men = [sk(n, el("4Lz+3T", 15.7)) for n in many("Man", 200)]
        ar.ingest(arc, men + [sk("Top MAN", el("4T+3A+3A+SEQ", 25.5))], meta("m.pdf"))
        women = [sk(n, el("3Lz+3T", 10.1)) for n in many("Woman", 200)]
        women += [sk("Quad WOMAN", el("4Lz+3T", 15.7), el("4T+1Eu+3S+SEQ", 14.3), el("4T", 9.5))]
        ar.ingest(arc, women, meta("w.pdf", kind="women", d="2024-11-02"))
        arc["full"] = True
        idx = ar.Index(arc)
        fe = ar.for_profile("Quad Woman", "", idx)
        self.assertEqual([x["t"] for x in fe], [
            "Самый дорогой прыжковый элемент у женщин с 2018 года: 4Lz+3T",
            "3 четверных в одной программе — больше всех с 2018 года",
            "Секвенция 4T+1Eu+3S"])  # отдельные 4Lz и 4T с того же старта уже названы в каскадах
        # у мужчин каскад с 4Lz не редкость
        self.assertEqual(ar.for_profile(many("Man", 2)[1], "", idx), [])
        self.assertEqual(ar.for_profile("Top Man", "", idx)[0]["t"],
                         "Самый дорогой прыжковый элемент с 2018 года: 4T+3A+3A")


class HookTest(unittest.TestCase):
    """results.segment_facts пополняет архив, только когда ему дали meta (полный сбор)."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        for name, val in (("FACTS", "facts.json"), ("ARCHIVE", "archive.json")):
            p = mock.patch.object(rs, name, os.path.join(self.dir.name, val))
            p.start()
            self.addCleanup(p.stop)
        for name in ("_store", "_arc"):
            setattr(rs, name, None)
            self.addCleanup(setattr, rs, name, None)
        rs._arc_dirty = False
        self.addCleanup(setattr, rs, "_arc_dirty", False)
        with open(os.path.join(FIX, "denisten_men_fs.txt"), encoding="utf-8") as f:
            self.text = f.read()

    def call(self, m=None):
        with mock.patch.object(rs.fx, "score_facts", return_value=[]), \
                mock.patch.object(rs, "side", return_value=""):
            return rs.segment_facts(TEN, kind="men", level="senior", seg="ПП", intl=False, season="2026-27",
                                    to_ru=lambda n: n, log=lambda *a: None, meta=m)

    def test_live_does_not_write_archive(self):
        with mock.patch.object(rs.net, "pdf_text", return_value=self.text):
            self.assertTrue(self.call())
        rs.save()
        self.assertFalse(os.path.exists(rs.ARCHIVE))

    def test_full_collection_ingests_and_cached_is_read_once(self):
        m = {"ev": "CS Denis Ten Memorial", "d": "2026-10-10", "src": "CS Denis Ten Memorial"}
        with mock.patch.object(rs.net, "pdf_text", return_value=self.text):
            self.call()  # быстрый сбор посчитал факты, архив не тронут
        with mock.patch.object(rs.net, "pdf_text", return_value=self.text) as get:
            self.call(m)  # полный сбор: факты из кэша, протокол дочитан в архив
            self.call(m)  # уже в архиве — больше не качается
        self.assertEqual(get.call_count, 1)
        rs.save()
        saved = ar.load(rs.ARCHIVE)
        self.assertEqual([s[0] for s in saved["segs"]], [TEN])
        self.assertEqual(saved["ath"]["gleb lutfulin"]["el"]["4T+3A+3A+SEQ"][2], 25.5)


if __name__ == "__main__":
    unittest.main()
