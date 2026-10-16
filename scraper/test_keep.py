"""Монотонность: сбой источника не стирает опубликованное, явное изменение применяется."""
import json
import os
import tempfile
import unittest
from unittest import mock

from . import facts as fx
from . import keep as kp
from . import net
from . import results as rs


def fact(kind, text, who="Иван Иванов"):
    return {"kind": kind, "text": text, "who": who}


def ev(**kw):
    e = {"id": "i", "ours": [], "athletes": [], "broadcast": [], "src": "new"}
    e.update(kw)
    return e


class MergeTest(unittest.TestCase):
    def test_failure_does_not_erase_facts_podium_live(self):
        old = ev(facts=[fact("element", "Каскад 4T+3A")], podium=[{"place": 1, "name": "А", "points": "1"}],
                 total=[{"place": 1, "name": "А", "points": "2"}], live={"idx": "u", "seg": "s"}, proto="p.json")
        new = ev()
        self.assertTrue(kp.merge_event(new, old, same_rules=True))
        for k in ("facts", "podium", "total", "live", "proto"):
            self.assertEqual(new[k], old[k], k)

    def test_explicit_change_applies(self):
        old = ev(facts=[fact("score", "Личный рекорд за ПП: 100.00 (был 90.00)")],
                 podium=[{"place": 1, "name": "А", "points": "1"}, {"place": 2, "name": "Б", "points": "1"},
                         {"place": 3, "name": "В", "points": "1"}])
        new = ev(facts=[fact("score", "Личный рекорд за ПП: 105.50 (был 90.00)")],
                 podium=[{"place": 1, "name": "Б", "points": "2"}, {"place": 2, "name": "А", "points": "1"},
                         {"place": 3, "name": "В", "points": "1"}])
        kp.merge_event(new, old, same_rules=True)
        self.assertEqual([f["text"] for f in new["facts"]], ["Личный рекорд за ПП: 105.50 (был 90.00)"])
        self.assertEqual([r["name"] for r in new["podium"]], ["Б", "А", "В"])

    def test_facts_union_by_key(self):
        old = [fact("element", "Каскад 4T+3A"), fact("place", "Отрыв от второго места — 10.00 балла")]
        new = [fact("place", "Отрыв от второго места — 12.50 балла"), fact("element", "Четверной аксель")]
        got = kp.merge_facts(new, old)
        self.assertEqual(sorted(f["text"] for f in got),
                         sorted(["Каскад 4T+3A", "Отрыв от второго места — 12.50 балла", "Четверной аксель"]))

    def test_rules_change_drops_pure_facts_but_keeps_scores(self):
        old = [fact("element", "Пятиоборотный аксель"), fact("score", "Личный рекорд за КП: 90.00 (был 80.00)")]
        got = kp.merge_facts([], old, same_rules=False)
        self.assertEqual([f["kind"] for f in got], ["score"])

    def test_retract(self):
        old = [fact("element", "Неверный факт")]
        self.assertEqual(kp.merge_facts([], old, retract=["Неверный"]), [])

    def test_truncated_podium_is_filled(self):
        old = [{"place": i, "name": n, "points": "1"} for i, n in ((1, "А"), (2, "Б"), (3, "В"))]
        self.assertEqual([r["name"] for r in kp.merge_rows([old[0]], old)], ["А", "Б", "В"])
        self.assertEqual(kp.merge_rows([], old), old)

    def test_withdrawn_skater_applies_only_when_board_is_alive(self):
        old = ev(ours=[{"name": "А", "nation": "RUS"}, {"name": "Б", "nation": "RUS"}], live={"idx": "u"})
        alive = ev(ours=[{"name": "А", "nation": "RUS"}], live={"idx": "u"})
        kp.merge_event(alive, old, same_rules=True)
        self.assertEqual([o["name"] for o in alive["ours"]], ["А"])
        down = ev(ours=[{"name": "А", "nation": "RUS"}])
        kp.merge_event(down, old, same_rules=True)
        self.assertEqual([o["name"] for o in down["ours"]], ["А", "Б"])
        self.assertEqual(down["live"], {"idx": "u"})

    def test_people_keep_time_and_place_unless_draw_changed(self):
        old = [{"name": "А", "no": 3, "time": "13:00", "place": 2}]
        got = kp.merge_people([{"name": "А", "nation": "RUS"}], old)
        self.assertEqual((got[0]["no"], got[0]["time"], got[0]["place"]), (3, "13:00", 2))
        got = kp.merge_people([{"name": "А", "no": 5}], old)
        self.assertNotIn("time", got[0])

    def test_watch_rss_failure_keeps_concrete_link(self):
        old = [{"name": "YouTube ISU", "url": "https://www.youtube.com/watch?v=AAAAAAAAAAA"}]
        new = [{"name": "YouTube ISU", "url": "https://www.youtube.com/@SkatingISU/live"}]
        self.assertEqual(kp.merge_watch(new, old), old)
        # конкретное новое остаётся, ресурс, пропавший из нового, сохраняется, retract снимает
        newer = [{"name": "YouTube ISU", "url": "https://www.youtube.com/watch?v=BBBBBBBBBBB"}]
        self.assertEqual(kp.merge_watch(newer, old), newer)
        self.assertEqual(kp.merge_watch([], old), old)
        self.assertEqual(kp.merge_watch([], old, retract=[old[0]["url"]]), [])
        # другой адрес под тем же именем, не /live, — явное изменение
        other = [{"name": "Okko", "url": "https://okko.tv/event/2"}]
        self.assertEqual(kp.merge_watch(other, [{"name": "Okko", "url": "https://okko.tv/"}]), other)

    def test_schedule_always_new(self):
        old = ev(start="2026-01-01T10:00:00+03:00", venue="A")
        new = ev(start="2026-01-02T10:00:00+03:00", venue="B")
        kp.merge_event(new, old, same_rules=True)
        self.assertEqual((new["start"], new["venue"]), ("2026-01-02T10:00:00+03:00", "B"))


class StatTest(unittest.TestCase):
    def setUp(self):
        fx._cache.clear()
        self.addCleanup(fx._cache.clear)

    def test_404_is_empty_but_outage_raises(self):
        with mock.patch.object(net, "fetch", side_effect=net.FetchError("x", kind="http", status=404)):
            self.assertEqual(fx._stat("a.htm"), [])
        with mock.patch.object(net, "fetch", side_effect=net.FetchError("x", kind="http", status=503)):
            with self.assertRaises(fx.StatUnavailable):
                fx._stat("b.htm")
        with mock.patch.object(net, "fetch", side_effect=net.FetchError("x", kind="timeout")):
            with self.assertRaises(fx.StatUnavailable):
                fx._stat("c.htm")
        self.assertNotIn("b.htm", fx._cache)


SK = [{"name": "A B", "rank": 1, "nation": "RUS", "tss": 100.0, "elements": []}]


class CacheTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        p = mock.patch.object(rs, "FACTS", os.path.join(self.dir.name, "facts.json"))
        p.start()
        self.addCleanup(p.stop)
        rs._store = None
        self.addCleanup(setattr, rs, "_store", None)

    def call(self, pdf="u.pdf", intl=True):
        return rs.segment_facts(pdf, kind="men", level="senior", seg="ПП", intl=intl, season="2026-27",
                                to_ru=lambda n: n, log=lambda *a: None)

    def test_stat_outage_is_not_cached(self):
        with mock.patch.object(rs.net, "pdf_text", return_value="x"), \
                mock.patch.object(rs.st, "parse_judges", return_value=SK), \
                mock.patch.object(rs.fx, "score_facts", side_effect=fx.StatUnavailable("503")):
            self.assertEqual(self.call(), [])
        self.assertNotIn(f"{rs.VERSION}|u.pdf", rs._load())
        # источник ожил — считается и запоминается
        with mock.patch.object(rs.net, "pdf_text", return_value="x"), \
                mock.patch.object(rs.st, "parse_judges", return_value=SK), \
                mock.patch.object(rs.fx, "score_facts", return_value=[("score", "Личный рекорд за ПП: 100.00 (был 90.00)")]):
            self.assertEqual(len(self.call()), 1)
        self.assertEqual(len(rs._load()[f"{rs.VERSION}|u.pdf"]), 1)

    def test_pdf_failure_is_not_cached(self):
        with mock.patch.object(rs.net, "pdf_text", side_effect=net.FetchError("x")):
            self.assertEqual(self.call(), [])
        with mock.patch.object(rs.net, "pdf_text", return_value="x"), \
                mock.patch.object(rs.st, "parse_judges", return_value=[]):
            self.assertEqual(self.call(), [])
        self.assertEqual(rs._load(), {})

    def test_version_bump_keeps_score_facts(self):
        old_score = fact("score", "Личный рекорд за ПП: 100.00 (был 90.00)", who="Vasil Barakhouski")
        rs._store = {"5|u.pdf": [old_score, fact("element", "Устаревший факт")]}
        # новые правила, статистика уже включает турнир: оценочных фактов не получилось
        with mock.patch.object(rs.net, "pdf_text", return_value="x"), \
                mock.patch.object(rs.st, "parse_judges", return_value=SK), \
                mock.patch.object(rs.fx, "score_facts", return_value=[]):
            got = rs.segment_facts("u.pdf", kind="men", level="senior", seg="ПП", intl=True, season="s",
                                   to_ru=lambda n: "Василий Бараховский" if n.startswith("Vasil") else n,
                                   log=lambda *a: None)
        self.assertEqual([(f["who"], f["kind"]) for f in got], [("Василий Бараховский", "score")])
        rs.save()
        saved = json.load(open(rs.FACTS, encoding="utf-8"))
        self.assertNotIn("5|u.pdf", saved)  # перенесено, прежняя запись больше не нужна
        self.assertIn(f"{rs.VERSION}|u.pdf", saved)

    def test_legacy_without_current_survives_save(self):
        rs._store = {"5|other.pdf": [fact("score", "Лучшая в мире сумма сезона: 300.00")]}
        rs.save()
        self.assertIn("5|other.pdf", json.load(open(rs.FACTS, encoding="utf-8")))

    def test_restored_legacy_is_adopted_into_existing_current(self):
        rs._store = {f"{rs.VERSION}|u.pdf": [fact("element", "Каскад 4T+3A")],
                     "5|u.pdf": [fact("score", "Лучшая в мире оценка сезона за ПП: 205.48")]}
        got = self.call()
        self.assertEqual(sorted(f["kind"] for f in got), ["element", "score"])


if __name__ == "__main__":
    unittest.main()


class NameTest(unittest.TestCase):
    def test_ru_name_handles_proper_case_latin(self):
        table = {"Vasil BARAKHOUSKI": "Василий Бараховский"}
        to_ru = lambda n: table.get(n, n)
        self.assertEqual(kp.ru_name(to_ru, "Vasil Barakhouski"), "Василий Бараховский")
        self.assertEqual(kp.ru_name(to_ru, "Неизвестный Человек"), "Неизвестный Человек")


class TopLevelTest(unittest.TestCase):
    def test_photos_add_only_new_value_wins_retract_removes(self):
        old = {"А": "u1", "Б": "u2"}
        self.assertEqual(kp.merge_map({"А": "u3"}, old), {"А": "u3", "Б": "u2"})
        self.assertEqual(kp.merge_map({}, old, retract=["Б"]), {"А": "u1"})

    def test_people_and_roster(self):
        old = [{"n": "А", "x": 1}, {"n": "Б"}]
        got = kp.merge_named([{"n": "А", "x": 2}], old)
        self.assertEqual(got, [{"n": "А", "x": 2}, {"n": "Б"}])
        self.assertEqual([p["n"] for p in kp.merge_named([], old, retract=["Б"])], ["А"])
        self.assertEqual(kp.merge_names({"А"}, ["Б"], retract=["А"]), {"Б"})

    def test_upcoming(self):
        old = [{"tid": "fsr:a", "start": "2026-11-01", "end": "2026-11-03"},
               {"tid": "isu:b", "start": "2026-11-05", "end": "2026-11-07"},
               {"tid": "isu:done", "start": "2026-09-01", "end": "2026-09-03"},
               {"tid": "isu:scheduled", "start": "2026-11-09", "end": "2026-11-10"},
               {"tid": "gs:c", "start": "2026-11-11", "end": "2026-11-12"}]
        new = [{"tid": "fsr:new", "start": "2026-11-02", "end": "2026-11-04"}]
        # ФФККР не ответил: его записи остаются; ISU ok — isu:b пропал по-настоящему
        # (isu:scheduled ушёл, потому что у него появились события — вызывающий убирает его из old)
        got = kp.merge_upcoming(new, [u for u in old if u["tid"] != "isu:scheduled"],
                                {"ФФККР": "fail", "ISU": "ok", "Golden Skate": "ok"}, set(), "2026-10-16")
        self.assertEqual([u["tid"] for u in got], ["fsr:a", "fsr:new"])
        # сбой самого турнира
        got = kp.merge_upcoming([], old, {"ISU": "ok"}, {"gs:c"}, "2026-10-16")
        self.assertEqual([u["tid"] for u in got], ["gs:c"])
        # префикс:* в failed
        got = kp.merge_upcoming([], old, {"ISU": "ok"}, {"isu:*"}, "2026-10-16")
        self.assertEqual({u["tid"] for u in got}, {"isu:b", "isu:scheduled"})


class UniqueIdTest(unittest.TestCase):
    def mk(self, eid, cat, start):
        return {"id": eid, "_cat": cat, "start": start}

    def test_collisions_get_stable_category_suffix_others_untouched(self):
        from . import build as b
        evs = [self.mk("gs:t:dance-senior-pt", "Solo Dance U12", "1"),
               self.mk("gs:t:dance-senior-pt", "Solo Dance Adult", "2"),
               self.mk("gs:t:men-senior-pp", "Men", "3")]
        b.unique_ids(evs)
        ids = [e["id"] for e in evs]
        self.assertEqual(ids[2], "gs:t:men-senior-pp")
        self.assertEqual(len(set(ids)), 3)
        self.assertEqual(evs[0]["_old_id"], "gs:t:dance-senior-pt")
        # порядок категорий в табло не влияет на id
        again = [self.mk("gs:t:dance-senior-pt", "Solo Dance Adult", "2"),
                 self.mk("gs:t:dance-senior-pt", "Solo Dance U12", "1")]
        b.unique_ids(again)
        self.assertEqual({e["id"] for e in again}, set(ids[:2]))

    def test_same_category_name_still_unique(self):
        from . import build as b
        evs = [self.mk("x:a", "Same", "1"), self.mk("x:a", "Same", "2")]
        b.unique_ids(evs)
        self.assertEqual(len({e["id"] for e in evs}), 2)

    def test_current_events_json_has_no_duplicate_ids(self):
        from . import build as b
        data = json.load(open(b.OUT_JSON, encoding="utf-8"))
        ids = [e["id"] for e in data["events"]]
        dup = {i for i in ids if ids.count(i) > 1}
        self.assertEqual(dup, set())
