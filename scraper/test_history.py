"""Архив прошлых сезонов (history.py): страницы прошлых лет, имена, файлы месяцев, история выступлений."""
import json
import os
import tempfile
import unittest

from . import history as h
from . import protocols as P


def read(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def ev(eid, start, **kw):
    tid = eid.rsplit(":", 1)[0]
    e = {"id": eid, "tid": tid, "tournament": "Турнир", "kind": "women", "level": "senior", "seg": "КП",
         "title": "Турнир — женщины КП", "start": start, "end": start, "venue": "", "intl": False, "src": "https://x/i.htm"}
    e.update(kw)
    return e


def row(i, name, place, pts, **kw):
    r = {"i": i, "place": place, "status": None, "no": i, "name": name, "nation": "", "points": pts}
    r.update(kw)
    return r


def doc(tid, name, rows, total=None, start="2024-12-20T14:00:00+03:00", code="КП"):
    return {"v": 1, "tid": tid, "tournament": name, "src": "https://x/index.htm", "built": "2026-11-14T00:00:00+03:00",
            "marks": True, "categories": [{"kind": "women", "level": "senior", "name": "Женщины", "total": total, "segments": [
                {"code": code, "name": "Короткая программа", "start": start, "end": start, "page": "https://x/SEG001.htm",
                 "judges": None, "table": "results", "state": "final", "basis": "judges", "skipped": 0, "rows": rows}]}]}


class NormPage(unittest.TestCase):
    def test_slash_dates_of_2018(self):
        self.assertIn(">23.08.2018<", h.norm_page("<td>23/08/18</td>"))
        self.assertIn(">06.09.2018<", h.norm_page("<td>06/09/2018</td>"))

    def test_us_dates_when_day_is_second(self):
        # этап Гран-при России 2023: месяц впереди — видно по числу больше 12 на втором месте
        page = h.norm_page("<td>11/18/2023</td><td>11/05/2023</td>")
        self.assertIn(">18.11.2023<", page)
        self.assertIn(">05.11.2023<", page)

    def test_month_names_and_typo(self):
        page = h.norm_page("<td>20-Dec-18</td><td>Rythm Dance</td>")
        self.assertIn(">20.12.2018<", page)
        self.assertIn("Rhythm Dance", page)

    def test_comnet_page(self):
        page = h.norm_page(
            '<meta content="Figure Skating Support System by comnet"><TABLE><TR><TD>PL</TD><TD>Competitor</TD></TR>'
            '<TR><td style="display: none">1</td><TD>1.</TD><TD><A href="x">Riku&nbsp;MIURA<BR>Ryuichi&nbsp;KIHARA</A></TD></TR>'
            '<TR Class="detail1"><td><table class="detail"><tr><td>4F</td></tr></table></td></TR></TABLE>')
        self.assertIn("<td>Pl.</td><td>Name</td>", page)
        self.assertIn("<td>1</td>", page)
        self.assertIn("Riku&nbsp;MIURA / Ryuichi&nbsp;KIHARA", page)
        self.assertNotIn("4F", page)
        self.assertNotIn("display: none", page)


class Names(unittest.TestCase):
    def setUp(self):
        self.sp = h.Speller(["Владимир Морозов", "Евгения Тарасова", "Алина Загитова", "Александр Самарин"])

    def test_russians_by_nation(self):
        self.assertEqual(self.sp.spell("Alina ZAGITOVA", "RUS", True), "Алина Загитова")
        self.assertEqual(self.sp.spell("Alexander SAMARIN", "RUS", True), "Александр Самарин")

    def test_similar_name_is_not_the_same_person(self):
        # Vladimir — не Владислав: только точное совпадение имени
        sp = h.Speller(["Владислав Морозов"])
        self.assertEqual(sp.spell("Vladimir MOROZOV", "RUS", True), "Vladimir Morozov")

    def test_pair_whole_or_latin(self):
        self.assertEqual(self.sp.spell("Evgenia TARASOVA / Vladimir MOROZOV", "RUS", True), "Евгения Тарасова / Владимир Морозов")
        sp = h.Speller(["Евгения Тарасова"])
        self.assertEqual(sp.spell("Evgenia TARASOVA / Vladimir MOROZOV", "RUS", True), "Evgenia Tarasova / Vladimir Morozov")

    def test_foreigners_stay_latin_family_last(self):
        self.assertEqual(self.sp.spell("CHEN Nathan", "USA", True), "Nathan Chen")
        self.assertEqual(self.sp.spell("Alina ZAGITOVA", "KAZ", True), "Alina Zagitova")

    def test_patronymic_dropped(self):
        self.assertEqual(self.sp.spell("Аделия Тиграновна ПЕТРОСЯН", "МОС", False), "Аделия Петросян")


class Months(unittest.TestCase):
    def test_put_events_and_index(self):
        with tempfile.TemporaryDirectory() as d:
            h.put_events([ev("fsr:a:women-senior-kp", "2024-12-20T14:00:00+03:00"),
                          ev("fsr:b:women-senior-kp", "2025-01-10T14:00:00+03:00")], (), d)
            idx = read(os.path.join(d, "index.json"))
            self.assertEqual(idx["months"], {"2024-12": 1, "2025-01": 1})
            self.assertEqual((idx["first"], idx["last"]), ("2024-12", "2025-01"))

    def test_richer_record_wins(self):
        with tempfile.TemporaryDirectory() as d:
            full = ev("fsr:a:women-senior-kp", "2024-12-20T14:00:00+03:00",
                      podium=[{"place": 1, "name": "А Б", "nation": "", "points": "70.00"}])
            h.put_events([full], (), d)
            h.put_events([ev("fsr:a:women-senior-kp", "2024-12-20T14:00:00+03:00")], (), d)
            events, _ = h.load_month("2024-12", d)
            self.assertEqual(len(events), 1)
            self.assertTrue(events[0].get("podium"))

    def test_tournament_without_times_spans_months(self):
        with tempfile.TemporaryDirectory() as d:
            t = {"tid": "fsr:z", "name": "Жигули", "start": "2024-11-29", "end": "2024-12-02", "venue": "", "intl": False,
                 "proto": "fsr_z.json", "kinds": ["women"]}
            h.put_events([], [t], d)
            self.assertEqual(h.load_month("2024-11", d)[1][0]["tid"], "fsr:z")
            self.assertEqual(h.load_month("2024-12", d)[1][0]["tid"], "fsr:z")
            # у турнира появились старты со временем — из «без расписания» он уходит
            h.put_events([ev("fsr:z:women-senior-kp", "2024-12-01T14:00:00+03:00")], (), d)
            self.assertEqual(h.load_month("2024-12", d)[1], [])

    def test_fold_keeps_finished_only(self):
        with tempfile.TemporaryDirectory() as d:
            done = ev("fsr:a:women-senior-kp", "2026-03-01T14:00:00+03:00", desc="x", live={"seg": "u"},
                      field=[{"name": "А Б", "nation": "МОС", "place": 1, "points": "70.00", "time": "14:05", "warmup": 1}],
                      podium=[{"place": 1, "name": "А Б", "nation": "МОС", "points": "70.00"}])
            empty = ev("fsr:b:women-senior-kp", "2026-03-02T14:00:00+03:00")
            h.fold([done, empty], d)
            events, _ = h.load_month("2026-03", d)
            self.assertEqual([e["id"] for e in events], ["fsr:a:women-senior-kp"])
            self.assertNotIn("desc", events[0])
            self.assertNotIn("live", events[0])
            self.assertEqual(events[0]["field"], [{"name": "А Б", "nation": "МОС", "place": 1, "points": "70.00"}])


class Slim(unittest.TestCase):
    def test_no_judge_marks_and_final(self):
        d = doc("fsr:a", "Турнир", [row(1, "А Б", 1, "70.00", els=[{"no": 1, "n": "3A", "b": 8.0, "g": 1.0, "s": 9.0, "j": [1, 2]}],
                                        comp=[{"n": "Композиция", "f": 1.0, "s": 8.0, "j": [8, 8]}])])
        d["categories"][0]["segments"][0].update(state="provisional", basis=None, panel=[{"no": "J1", "name": "X", "nation": "RUS"}])
        s = h.slim_doc(d)["categories"][0]["segments"][0]
        self.assertEqual((s["state"], s["basis"]), ("final", "time"))
        self.assertNotIn("panel", s)
        self.assertNotIn("j", s["rows"][0]["els"][0])
        self.assertNotIn("j", s["rows"][0]["comp"][0])
        self.assertEqual(P.validate(d, final_by_time=True), [])


class Athletes(unittest.TestCase):
    def test_history_files(self):
        with tempfile.TemporaryDirectory() as d:
            past, live, out = (os.path.join(d, x) for x in ("past", "live", "h"))
            os.makedirs(past)
            os.makedirs(live)
            total = {"state": "final", "complete": True, "cols": ["КП"], "colsKind": "places", "skipped": 0,
                     "rows": [dict(row(1, "Анна Иванова", 1, "200.00"), parts=["1"])]}
            rows = [row(1, "Анна Иванова", 1, "70.00", tes="40.00", pcs="30.00", ded="0.00", bv=30.5,
                        els=[{"no": 1, "n": "3Lz!+3T<", "info": "! <", "b": 10.0, "g": -1.2, "s": 8.8}]),
                    row(2, "Мария Петрова", 2, "60.00")]
            P._atomic_write(os.path.join(past, "fsr_a.json"), P.canonical(doc("fsr:a", "Чемпионат", rows, total)))
            P._atomic_write(os.path.join(live, "isu_b.json"), P.canonical(doc(
                "isu:b", "Гран-при", [row(1, "Анна Иванова", 3, "65.00")], start="2026-10-01T10:00:00+03:00")))
            stat = h.athletes(past, live, out)
            self.assertEqual((stat["athletes"], stat["skates"], stat["twins"]), (2, 3, 0))
            f = read(os.path.join(out, f"{h.bucket('Анна Иванова'):02x}.json"))
            mine = f["a"]["Анна Иванова"]["r"]
            self.assertEqual([r["t"] for r in mine], ["fsr:a", "isu:b"])
            self.assertEqual(mine[0]["els"], [["3Lz!+3T<", "! <", -1.2]])
            self.assertEqual((mine[0]["tp"], mine[0]["tpts"], mine[0]["of"]), (1, "200.00", 2))
            self.assertEqual(f["t"]["fsr:a"], ["Чемпионат", 0, 1])
            self.assertEqual(f["t"]["isu:b"], ["Гран-при", 1, 0])

    def test_twins_are_marked(self):
        with tempfile.TemporaryDirectory() as d:
            past, out = os.path.join(d, "past"), os.path.join(d, "h")
            os.makedirs(past)
            rows = [row(1, "Анна Иванова", 1, "70.00"), row(2, "Анна Иванова", 2, "60.00")]
            P._atomic_write(os.path.join(past, "fsr_a.json"), P.canonical(doc("fsr:a", "Чемпионат", rows)))
            h.athletes(past, os.path.join(d, "none"), out)
            f = read(os.path.join(out, f"{h.bucket('Анна Иванова'):02x}.json"))
            self.assertTrue(f["a"]["Анна Иванова"].get("x"))

    def test_domestic_bests(self):
        # лучшее на российских стартах: сумма — только где был короткий сегмент; международные не в счёт
        def two(tid, name, sp, fs, tot, day):
            d = doc(tid, name, [row(1, "Анна Иванова", 1, sp)], start=f"{day}T14:00:00+03:00")
            free = dict(d["categories"][0]["segments"][0], code="ПП", start=f"{day}T18:00:00+03:00",
                        rows=[row(1, "Анна Иванова", 1, fs)])
            d["categories"][0]["segments"].append(free)
            d["categories"][0]["total"] = {"state": "final", "rows": [dict(row(1, "Анна Иванова", 1, tot), parts=["1", "1"])]}
            return d
        with tempfile.TemporaryDirectory() as d:
            past, live = os.path.join(d, "past"), os.path.join(d, "live")
            os.makedirs(past)
            os.makedirs(live)
            P._atomic_write(os.path.join(past, "fsr_a.json"), P.canonical(two("fsr:a", "Чемпионат России", "86.52", "176.40", "262.92", "2024-12-20")))
            P._atomic_write(os.path.join(past, "ffkm_b.json"), P.canonical(two("ffkm:b", "Кубок Москвы", "88.00", "170.00", "258.00", "2019-10-05")))
            only_free = doc("fsr:c", "Шоу-турнир", [row(1, "Анна Иванова", 1, "190.00")], code="ПП",
                            total={"state": "final", "rows": [dict(row(1, "Анна Иванова", 1, "190.00"), parts=["1"])]})
            P._atomic_write(os.path.join(live, "fsr_c.json"), P.canonical(only_free))
            P._atomic_write(os.path.join(live, "isu_d.json"), P.canonical(two("isu:d", "Олимпийские игры", "90.00", "200.00", "290.00", "2026-02-17")))
            # младший возраст: в итог входят ОФП и СФП — итог не сумма, в «сумму» не идёт
            P._atomic_write(os.path.join(past, "fsr_e.json"), P.canonical(two("fsr:e", "Первенство (младший возраст)", "89.00", "150.00", "300.00", "2020-03-11")))
            best, since = h.domestic_bests(past, live)
            mine = best[h.nm.key("Анна Иванова")]
            self.assertEqual(mine["total"], {"pts": "262.92", "ev": "Чемпионат России", "d": "2024-12-20", "src": "ФФККР"})
            self.assertEqual((mine["sp"]["pts"], mine["sp"]["ev"]), ("89.00", "Первенство (младший возраст)"))
            self.assertEqual(mine["fs"]["pts"], "190.00")  # произвольная — да, сумма из одной произвольной — нет
            self.assertEqual(since, "2019/20")
            os.remove(os.path.join(past, "fsr_e.json"))
            best, _ = h.domestic_bests(past, live)
            self.assertEqual(best[h.nm.key("Анна Иванова")]["sp"]["src"], "ФФКМ")

    def test_bucket_is_crc32_of_normalized_name(self):
        # тот же расчёт — в приложении (history.dart): менять только вместе
        self.assertEqual(h.bucket("Аделия Петросян"), h.bucket("аделия петросян"))
        self.assertEqual(h.bucket("Пётр Гуменник"), h.bucket("Петр Гуменник"))
        self.assertEqual(h.bucket("Kaori Sakamoto"), 0x34)


if __name__ == "__main__":
    unittest.main()
