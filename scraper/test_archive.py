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
from scraper import names as nm
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


class NoPatronymicTest(unittest.TestCase):
    """Отчество региональных табло убирается, чтобы человек с отчеством и без — одна запись."""

    def test_patronymic_dropped(self):
        self.assertEqual(ar._no_patronymic("Илья Денисович СТАРКОВ"), "Илья СТАРКОВ")

    def test_name_without_patronymic_unchanged(self):
        self.assertEqual(ar._no_patronymic("Илья СТАРКОВ"), "Илья СТАРКОВ")
        self.assertEqual(ar._no_patronymic("Ilia MALININ"), "Ilia MALININ")

    def test_pair_each_person_patronymic_dropped(self):
        self.assertEqual(ar._no_patronymic("Илья Денисович СТАРКОВ / Мария Андреевна ПЕТРОВА"),
                         "Илья СТАРКОВ / Мария ПЕТРОВА")


class IngestTest(unittest.TestCase):
    def test_patronymic_and_plain_name_are_one_athlete(self):
        arc = ar.empty()
        ar.ingest(arc, [sk("Илья Денисович СТАРКОВ", el("4A", 12.5))], meta("regional.pdf"))
        ar.ingest(arc, [sk("Илья СТАРКОВ", el("4A", 12.5))], meta("senior.pdf", d="2025-01-10"))
        self.assertEqual(len(arc["ath"]), 1)
        key = nm.key("Илья СТАРКОВ")
        self.assertEqual(list(arc["ath"]), [key])
        self.assertEqual(arc["ath"][key]["el"]["4A"][0], 2)

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

    def test_urls(self):
        """urls: адреса всех протоколов архива; у пустого (файла нет) — пустой список."""
        arc = ar.empty()
        ar.ingest(arc, [sk("Ilia MALININ", el("4A", 12.5))], meta("a.pdf"))
        ar.ingest(arc, [sk("Nathan CHEN", el("4Lz", 11.5))], meta("b.pdf"))
        self.assertEqual(sorted(ar.urls(arc)), ["a.pdf", "b.pdf"])
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(ar.urls(ar.load(os.path.join(d, "нет.json"))), [])


def full(arc):
    arc["full"] = True
    return ar.Index(arc)


def titles(arc, name, nation=""):
    return [x["t"] for x in ar.for_profile(name, nation, full(arc))]


class VersionTest(unittest.TestCase):
    def test_version_two_and_foreign_version_is_empty(self):
        self.assertEqual(ar.empty()["v"], 2)
        arc = ar.empty()
        ar.ingest(arc, [sk("Ilia MALININ", el("4A", 12.5))], meta("a.pdf"))
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "archive.json")
            ar.save(arc, path)
            with open(path, encoding="utf-8") as f:
                self.assertEqual(json.load(f)["v"], 2)
            self.assertTrue(ar.has(ar.load(path), "a.pdf"))
            arc["full"] = True
            ar.save(arc, path)
            with open(path, encoding="utf-8") as f:
                text = f.read()
            self.assertEqual((json.loads(text)["v"], json.loads(text)["full"]), (2, True))
            # архив прежней версии читается как пустой
            with open(path, "w", encoding="utf-8") as f:
                f.write(text.replace('"v": 2', '"v": 1', 1))
            self.assertEqual(ar.load(path), ar.empty())


class MaxMarksTest(unittest.TestCase):
    """g5/t10: оценка бригады после отбрасывания высшей и низшей."""

    def ath(self, *elements, comps=()):
        arc = ar.empty()
        ar.ingest(arc, [sk("Ilia MALININ", *elements, components=comps)], meta("a.pdf"))
        return arc, arc["ath"]["ilia malinin"]

    def test_g5_needs_five_judges_and_trimmed_all_five(self):
        _, a = self.ath(el("4Lo", judges=(5, 5, 5, 5, 5, 5, 3)), el("4F", judges=(5, 5, 5, 5, 2)),
                        el("4S", judges=(5, 5, 5, 3)), el("4T", judges=(5, 5, 4, 5, 5, 3, 5)),
                        el("3A", judges=(5, 5, 5, 5, 4)))
        self.assertEqual(a["g5"], {"4Lo": 0, "4F": 0, "3A": 0})  # 4S — всего четыре судьи, 4T — две оценки ниже +5
        self.assertNotIn("p5", a)

    def test_unanimous_is_in_both(self):
        _, a = self.ath(el("4Lo", judges=(5, 5, 5, 5, 5)), el("4F", judges=(5, 5, 5)))
        self.assertEqual((a["p5"], a["g5"]), ({"4Lo": 0, "4F": 0}, {"4Lo": 0}))

    def test_t10_trims_one_each_side(self):
        comps = [{"name": "Composition", "judges": [10, 10, 10, 10, 9.75]},
                 {"name": "Presentation", "judges": [10, 10, 9.75, 9.75, 10]},
                 {"name": "Skating Skills", "judges": [10, 10, 10, 10, 10]},
                 {"name": "Other", "judges": [10, 10, 10, 9]}]
        _, a = self.ath(el("4A"), comps=comps)
        self.assertEqual(a["t10"], {"Composition": 0, "Skating Skills": 0})
        self.assertEqual(a["c10"], {"Skating Skills": 0})

    def test_first_protocol_wins(self):
        arc = ar.empty()
        e = el("4Lo", judges=(5, 5, 5, 5, 4))
        ar.ingest(arc, [sk("Ilia MALININ", e)], meta("late.pdf", d="2025-01-01"))
        ar.ingest(arc, [sk("Ilia MALININ", e)], meta("early.pdf", d="2023-01-01"))
        self.assertEqual(arc["segs"][arc["ath"]["ilia malinin"]["g5"]["4Lo"]][0], "early.pdf")

    def test_profile_rows_unanimous_not_duplicated_as_max(self):
        comps = [{"name": "Composition", "judges": [10] * 5}, {"name": "Presentation", "judges": [10, 10, 10, 10, 9.5]}]
        arc, _ = self.ath(el("4Lo", judges=(5, 5, 5, 5, 5)), el("4F", judges=(5, 5, 5, 5, 4)),
                          el("CCoSp4", judges=(5, 5, 5, 5, 5, 5, 4)), comps=comps)
        t = titles(arc, "Ilia Malinin", "USA")
        self.assertIn("Все судьи — +5 за четверной риттбергер", t)
        self.assertIn("Максимальные +5 за четверной флип", t)
        self.assertIn("Максимальные +5 за комбинированное вращение со сменой ноги", t)
        self.assertNotIn("Максимальные +5 за четверной риттбергер", t)
        self.assertIn("Все судьи — 10 за композицию", t)
        self.assertIn("Максимальные 10.00 за представление", t)
        self.assertNotIn("Максимальные 10.00 за композицию", t)
        # порядок группы: по дате, затем по коду
        plus5 = [x for x in t if "+5" in x]
        self.assertEqual(plus5, ["Максимальные +5 за четверной флип", "Все судьи — +5 за четверной риттбергер",
                                 "Максимальные +5 за комбинированное вращение со сменой ноги"])

    def test_merge_carries_g5_and_t10(self):
        comps = [{"name": "Composition", "judges": [10, 10, 10, 10, 9]}]
        dst, src = ar.empty(), ar.empty()
        ar.ingest(dst, [sk("Ilia MALININ", el("3A"))], meta("x.pdf", d="2024-01-01"))
        ar.ingest(src, [sk("Ilia MALININ", el("4Lo", judges=(5, 5, 5, 5, 4)), components=comps)],
                  meta("y.pdf", d="2023-01-01"))
        ar.ingest(src, [sk("Ilia MALININ", el("4Lo", judges=(5, 5, 5, 5, 4)), components=comps)],
                  meta("z.pdf", d="2025-01-01"))
        ar.merge(dst, src)
        a = dst["ath"]["ilia malinin"]
        self.assertEqual((dst["segs"][a["g5"]["4Lo"]][0], dst["segs"][a["t10"]["Composition"]][0]), ("y.pdf", "y.pdf"))
        # второй раз — более поздний не перетирает
        ar.merge(dst, src)
        self.assertEqual(dst["segs"][dst["ath"]["ilia malinin"]["g5"]["4Lo"]][0], "y.pdf")


class DanceTest(unittest.TestCase):
    def test_dance_items(self):
        for code in ("MiSt4", "DiStW4+DiStM4", "OFStL4+OFStM4", "OfStL4+OfStM4", "StSq4", "SeStW4+SeStM4", "PSt4"):
            self.assertEqual(ar.dance_items(el(code)), ["St4"], code)
        for code in ("OFStL4+OFStM3", "MiSt3", "StSq3", "DiStW4+DiStM3", "ChSt1", "SlLi4"):
            self.assertEqual(ar.dance_items(el(code)), [], code)
        self.assertEqual(ar.dance_items(el("1FS4+kpYYYY")), ["Kp4"])
        self.assertEqual(ar.dance_items(el("2SS4+kpYYNY")), ["Kp4"])
        for code in ("1FS3+kpYNYY", "1MB2+kpYYNN", "1FS4", "kpYYYY"):
            self.assertEqual(ar.dance_items(el(code)), [], code)

    def test_ingest_dance_only(self):
        arc = ar.empty()
        ar.ingest(arc, [sk("Madison CHOCK / Evan BATES", el("DiStW4+DiStM4"), el("1FS4+kpYYYY"), el("MiSt3"),
                           el("DiStW4+DiStM4"), el("4Lz"))], meta("d.pdf", kind="dance", seg="РТ"))
        ar.ingest(arc, [sk("Ilia MALININ", el("MiSt4"))], meta("m.pdf"))
        self.assertEqual(arc["ath"][ar.nm.key("Madison CHOCK / Evan BATES")]["el"], {"St4": [2, 0, None, None], "Kp4": [1, 0, None, None]})
        self.assertNotIn("ilia malinin", arc["ath"])  # у мужчин дорожки шагов в архив не идут

    def test_title_and_signature(self):
        self.assertEqual(ar.title("St4"), "Дорожка шагов четвёртого уровня")
        self.assertEqual(ar.title("Kp4"), "Серия обязательного рисунка четвёртого уровня")
        self.assertEqual((ar.signature("St4"), ar.signature("Kp4")), ("St4", "Kp4"))

    def test_rare_in_profile(self):
        arc = ar.empty()
        ar.ingest(arc, [sk("Madison CHOCK / Evan BATES", el("MiSt4"), el("1FS4+kpYYYY"))],
                  meta("d.pdf", kind="dance", seg="РТ"))
        self.assertEqual(titles(arc, "Madison Chock / Evan Bates", "USA"),
                         ["Серия обязательного рисунка четвёртого уровня", "Дорожка шагов четвёртого уровня"])  # с одного старта — по коду


def crowd(arc, n, per_athlete, prefix="Q", kind="men", d="2024-11-01", u="c.pdf"):
    """n спортсменов с одинаковым набором элементов в одном протоколе."""
    ar.ingest(arc, [sk(name, *[el(c) for c in per_athlete]) for name in many(prefix, n)], meta(u, kind=kind, d=d))


class RareTest(unittest.TestCase):
    def filled(self, performers):
        """200 мужчин без редкого и performers мужчин с чистым 4Lz."""
        arc = ar.empty()
        ar.ingest(arc, [sk(n, el("3Lz+3T", 10.1)) for n in many("Fill", 200)], meta("f.pdf"))
        crowd(arc, performers, ["4Lz"], "Lz")
        return arc

    def test_share_is_seven_percent(self):
        self.assertEqual(ar.RARE_SHARE, 0.07)
        idx = full(self.filled(14))
        self.assertTrue(idx.rare("men", "4Lz"))  # 14 из 214 — не больше max(3, 0.07 * 214 = 14.98)
        self.assertFalse(full(self.filled(16)).rare("men", "4Lz"))

    def test_few(self):
        idx = full(self.filled(1))
        pop = idx.pop["men"]  # 201
        edge = int(ar.RARE_SHARE * pop)
        self.assertEqual(edge, 14)
        self.assertTrue(idx.few("men", edge))
        self.assertFalse(idx.few("men", edge + 1))
        self.assertFalse(idx.few("men", 0))  # никого — не «мало», а «нет»
        self.assertTrue(idx.few("women", 3))  # вида нет: порог — RARE_MIN
        self.assertFalse(idx.few("women", 4))


class QuadTypesTest(unittest.TestCase):
    def arc_with(self, protocols, others=0, other_codes=("4T", "4S")):
        arc = ar.empty()
        ar.ingest(arc, [sk(n, el("3Lz+3T", 10.1)) for n in many("Fill", 200)], meta("f.pdf"))
        for u, d, codes in protocols:
            ar.ingest(arc, [sk("Ilia MALININ", *[el(c) for c in codes])], meta(u, d=d))
        if others:
            crowd(arc, others, other_codes, "Oth", u="o.pdf")
        return arc

    def test_index_types_order_and_exclusions(self):
        arc = self.arc_with([("a.pdf", "2024-01-01", ["4Lz", "4A", "4T+3T", "4STh", "4Tw3", "4F+3A+SEQ"]),
                             ("b.pdf", "2024-02-01", ["4Lo"])])
        idx = full(arc)
        self.assertEqual(idx.types["ilia malinin"], ["T", "Lo", "F", "Lz", "A"])  # без выброса сальхов
        self.assertEqual(idx.with_types("men", 5), 1)
        self.assertEqual(idx.with_types("men", 6), 0)

    def test_row_number_word_order_and_protocol(self):
        arc = self.arc_with([("a.pdf", "2024-01-01", ["4T", "4Lz"]), ("b.pdf", "2024-03-01", ["4S"]),
                             ("c.pdf", "2024-05-01", ["4F+3T", "4Lo"]), ("d.pdf", "2024-09-01", ["4T", "4A"])])
        rows = [x for x in ar.for_profile("Ilia Malinin", "USA", full(arc)) if "разных" in x["t"]]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["t"], "Шесть разных четверных прыжков: тулуп, сальхов, риттбергер, флип, лутц, аксель")
        self.assertEqual((rows[0]["u"], rows[0]["d"]), ("d.pdf", "2024-09-01"))  # аксель набрался последним
        arc = self.arc_with([("a.pdf", "2024-01-01", ["4T", "4Lz"]), ("b.pdf", "2024-03-01", ["4S"]),
                             ("c.pdf", "2024-05-01", ["4F+3T", "4Lo"]), ("d.pdf", "2024-09-01", ["4T"])])
        rows = [x for x in ar.for_profile("Ilia Malinin", "USA", full(arc)) if "разных" in x["t"]]
        self.assertEqual(rows[0]["t"], "Пять разных четверных прыжков: тулуп, сальхов, риттбергер, флип, лутц")
        self.assertEqual(rows[0]["u"], "c.pdf")  # у каждого типа — первый протокол, из них самый поздний
        self.assertEqual(rows[0]["g"], ar.GROUP["types"])

    def test_words(self):
        for codes, want in ((["4T", "4S"], "Два разных четверных прыжка: тулуп, сальхов"),
                             (["4T", "4S", "4Lo"], "Три разных четверных прыжка: тулуп, сальхов, риттбергер"),
                             (["4T", "4S", "4Lo", "4F"], "Четыре разных четверных прыжка: тулуп, сальхов, риттбергер, флип")):
            arc = self.arc_with([("a.pdf", "2024-01-01", codes)])
            self.assertIn(want, titles(arc, "Ilia Malinin", "USA"))

    def test_one_type_or_throws_only_no_row(self):
        arc = self.arc_with([("a.pdf", "2024-01-01", ["4T", "4STh", "4T+3T"])])
        self.assertFalse([t for t in titles(arc, "Ilia Malinin", "USA") if "разных" in t])

    def test_absent_when_many_have_it(self):
        # у 16 из 216 мужчин (больше 7 %) два разных четверных — это не редкость; у 14 — редкость
        arc = self.arc_with([("a.pdf", "2024-01-01", ["4T", "4S"])], others=15)
        self.assertFalse([t for t in titles(arc, "Ilia Malinin", "USA") if "разных" in t])
        arc = self.arc_with([("a.pdf", "2024-01-01", ["4T", "4S"])], others=13)
        self.assertTrue([t for t in titles(arc, "Ilia Malinin", "USA") if "разных" in t])


class QuadProgramTest(unittest.TestCase):
    def test_row_depends_on_rarity_not_fixed_thresholds(self):
        arc = ar.empty()
        ar.ingest(arc, [sk(n, el("3Lz+3T", 10.1)) for n in many("Fill", 200)], meta("f.pdf"))
        crowd(arc, 20, ["4T", "4S", "4Lo"], "Three", d="2024-02-01", u="t.pdf")  # трёх четверных много
        ar.ingest(arc, [sk("Four ATH", el("4T"), el("4S"), el("4Lo"), el("4F"))], meta("4.pdf", d="2024-03-01"))
        ar.ingest(arc, [sk("Four BTH", el("4T"), el("4S"), el("4Lo"), el("4F"))], meta("4b.pdf", d="2024-03-02"))
        ar.ingest(arc, [sk("Five ATH", el("4T"), el("4S"), el("4Lo"), el("4F"), el("4Lz"))], meta("5.pdf", d="2024-04-01"))
        idx = full(arc)
        self.assertEqual((idx.with_quads("men", 3), idx.with_quads("men", 4), idx.with_quads("men", 5)), (23, 3, 1))
        # четыре — у троих (≤ 15): строка есть, хоть у мужчин раньше нужно было пять
        self.assertIn("4 четверных в одной программе: 4T, 4S, 4Lo, 4F", [x["t"] for x in ar.for_profile("Four Ath", "", idx)])
        # три — у 23 (> 15): строки нет
        self.assertFalse([x for x in ar.for_profile(many("Three", 1)[0], "", idx) if "в одной программе" in x["t"]])


class MergeTest(unittest.TestCase):
    """Прошлые сезоны и архив сбора — разные файлы; сведённые, они дают то же, что один общий."""

    PROTOCOLS = [
        ("p1.pdf", "2019-03-20", [sk("Nathan CHEN", el("4Lz+3T", 15.7), el("4F"), el("4S"), el("4T"), el("4T+3T")),
                                  sk("Ilia MALININ", el("4T"))]),
        ("p2.pdf", "2022-12-10", [sk("Ilia MALININ", el("4A", 12.5, judges=(5, 5, 5)), el("4Lz+3T", 15.7), el("4Lz"),
                                     el("4F"), el("4S"), el("4T"))]),
        ("p3.pdf", "2026-10-10", [sk("Ilia MALININ", el("4A", 12.5), el("4Lz+3A+SEQ", 17.0)),
                                  sk("Gleb LUTFULLIN", el("4T+3A+3A+SEQ", 25.5), nation="AIN")]),
        ("p4.pdf", "2026-10-25", [sk("Глеб ЛУТФУЛЛИН", el("4T+3A+3A+SEQ", 25.5), nation="СПБ"),
                                  sk("Илья МАЛИНИН", el("4A", 12.5, judges=(5, 5, 5)))]),
    ]

    def build(self, protocols):
        arc = ar.empty()
        for u, d, skaters in protocols:
            ar.ingest(arc, skaters, meta(u, d=d))
        return arc

    def rows(self, arc, name, nation=""):
        arc["full"] = True
        return ar.for_profile(name, nation, ar.Index(arc))

    def test_merged_equals_one_archive(self):
        whole = self.build(self.PROTOCOLS)
        # сбор начал копить раньше, чем залили прошлое: в его архиве нынешние протоколы стоят первыми
        live, past = self.build(self.PROTOCOLS[2:]), self.build(self.PROTOCOLS[:2])
        merged = ar.merge(past, live)
        for who, nation in (("Ilia MALININ", "USA"), ("Глеб Лутфуллин", "RUS"), ("Nathan CHEN", "USA")):
            self.assertEqual(self.rows(merged, who, nation), self.rows(whole, who, nation), who)
        a, b = merged["ath"]["gleb lutfulin"], whole["ath"]["gleb lutfulin"]
        self.assertEqual((a["n"], a["c"]), (b["n"], b["c"]))
        self.assertEqual(merged["_pop"], whole["_pop"])
        n, first, base, bi = merged["ath"]["ilia malinin"]["el"]["4A"]
        self.assertEqual((n, merged["segs"][first][0], merged["segs"][bi][0]), (3, "p2.pdf", "p2.pdf"))
        m = merged["ath"]["ilia malinin"]
        self.assertEqual((m["n"], merged["segs"][m["p5"]["4A"]][0], m["q"][0], merged["segs"][m["q"][1]][0]),
                         ("Илья МАЛИНИН", "p2.pdf", 6, "p2.pdf"))

    def test_combined_keeps_files_apart(self):
        with tempfile.TemporaryDirectory() as d:
            past_path = os.path.join(d, "past.json")
            past = self.build(self.PROTOCOLS[:2])
            past["full"] = True
            ar.save(past, past_path)
            live = self.build(self.PROTOCOLS[2:])
            before = json.dumps(live["ath"], sort_keys=True)
            both = ar.combined(live, past_path)
            self.assertTrue(both["full"])
            self.assertEqual(len(both["segs"]), 4)
            self.assertEqual(json.dumps(live["ath"], sort_keys=True), before)  # архив сбора не тронут
            self.assertEqual(len(live["segs"]), 2)
            self.assertNotIn("full", live)
            # одинаковый протокол в обоих — один
            self.assertEqual(len(ar.combined(past, past_path)["segs"]), 2)
            # прошлого нет — профилю ничего
            self.assertFalse(ar.combined(live, os.path.join(d, "нет.json")).get("full"))


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
            "Секвенция 4T+1Eu+3S",  # отдельные 4Lz и 4T с того же старта уже названы в каскадах
            "Два разных четверных прыжка: тулуп, лутц"])
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
