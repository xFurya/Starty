"""Где смотреть: ссылки со страницы турнира и правила из config.json (сеть не нужна)."""
import datetime as dt
import json
import unittest
from unittest import mock

from . import build as b
from . import fsr

PAGE = '''<div itemprop="articleBody"><p>Сроки проведения: 30 сентября - 4 октября 2026</p>
<p><a href="https://www.sport1tv.ru/figurnoe-katanie">Фигурное катание</a></p>
<p><a href="https://www.1tv.ru/sport/gran-pri-rossii-po-figurnomu-kataniyu-2026-27/">Онлайн-трансляции на Первом канале</a></p>
<p><a href="https://vk.com/video/@ruskating">VK</a></p>
<p><a href="javascript:void(0)">1tv.ru</a></p></div>'''


class WatchTest(unittest.TestCase):
    def test_page_links(self):
        with mock.patch.object(fsr.net, "fetch", return_value=PAGE):
            t = fsr.tournament("https://fsrussia.ru/x")
        self.assertEqual(t["broadcast"], ["Первый канал", "VK Видео"])
        self.assertEqual(t["watch"], [
            {"name": "Первый канал", "url": "https://www.1tv.ru/sport/gran-pri-rossii-po-figurnomu-kataniyu-2026-27/"},
            {"name": "VK Видео", "url": "https://vk.com/video/@ruskating"}])

    def test_rule_jgp(self):
        # ISU: Okko — Россия, Беларусь, Казахстан; остальной мир — YouTube ISU; у каждой площадки — где доступна
        self.assertEqual(b.watch_for("JGP Gdansk"), [
            {"name": "Okko", "url": "https://okko.tv/", "note": "Россия, Беларусь, Казахстан"},
            {"name": "YouTube ISU", "url": "https://www.youtube.com/@SkatingISU/live", "note": "Кроме России, Беларуси и Казахстана"}])
        self.assertEqual(b.broadcast_for("JGP Gdansk"), ["Okko", "YouTube ISU"])
        self.assertEqual(b.watch_for("Финал юниорского Гран-при"), [{"name": "Okko", "url": "https://okko.tv/"}])

    def test_page_wins_over_rule(self):
        base = [{"name": "Okko", "url": "https://okko.tv/event/1"}, {"name": "x", "url": "ftp://bad"}]
        w = b.watch_for("JGP Ankara", base)
        self.assertEqual(w[0], {"name": "Okko", "url": "https://okko.tv/event/1", "note": "Россия, Беларусь, Казахстан"})
        self.assertEqual([x["name"] for x in w], ["Okko", "YouTube ISU"])

    def test_event_field(self):
        import datetime as dt
        z = dt.datetime(2026, 9, 1, 12, tzinfo=dt.timezone.utc)
        ev = b.make_event(tid="t", tournament="JGP Ankara", kind="men", level="junior", seg="КП", mixed=False,
                          start=z, end=z, venue="", intl=True, broadcast=[], ours=[], athletes=[], src="")
        self.assertEqual([w["name"] for w in ev["watch"]], ["Okko", "YouTube ISU"])
        self.assertEqual(ev["broadcast"], ["Okko", "YouTube ISU"])
        ev = b.make_event(tid="t", tournament="Другой", kind="men", level="junior", seg="КП", mixed=False,
                          start=z, end=z, venue="", intl=True, broadcast=[], ours=[], athletes=[], src="")
        self.assertNotIn("watch", ev)


RSS = '''<feed><entry><yt:videoId>OSkvMe0MyDs</yt:videoId>
<title>III этап. Гран-при России по фигурному катанию среди юниоров  2026/27 . День 3</title>
<published>2026-10-14T05:00:00+00:00</published></entry>
<entry><yt:videoId>FeJpfaijtHQ</yt:videoId><title>Гран-при России по фигурному катанию 2026/27. Короткие программы</title>
<published>2026-10-15T05:00:00+00:00</published></entry></feed>'''


class YoutubeTest(unittest.TestCase):
    def setUp(self):
        b._YT.clear()
        self.addCleanup(b._YT.clear)

    def ev(self, tid, name, day):
        import datetime as dt
        z = dt.datetime(2026, 10, day, 10, tzinfo=dt.timezone.utc)
        return b.make_event(tid=tid, tournament=name, kind="men", level="junior", seg="КП", mixed=False,
                            start=z, end=z, venue="", intl=False, broadcast=[], ours=[], athletes=[], src="")

    def test_rule_and_live_fallback(self):
        with mock.patch.object(b.net, "fetch", return_value=RSS):
            e = self.ev("fsr:x", "ЮГП России «Рапсодия льда»", 12)
        self.assertEqual(e["watch"], [{"name": "YouTube", "url": "https://www.youtube.com/@ice_skating/live"}])
        self.assertIn("YouTube", e["broadcast"])

    def test_concrete_stream_by_day(self):
        with mock.patch.object(b.net, "fetch", return_value=RSS):
            e = self.ev("fsr:x", "ЮГП России «Рапсодия льда»", 14)
        self.assertEqual(e["watch"][0]["url"], "https://www.youtube.com/watch?v=OSkvMe0MyDs")

    def test_no_rss_and_other_tournaments(self):
        with mock.patch.object(b.net, "fetch", side_effect=b.net.FetchError("x")):
            e = self.ev("fsr:x", "Гран-при России «Рапсодия льда»", 14)
            self.assertEqual(e["watch"][0]["url"], "https://www.youtube.com/@ice_skating/live")
        self.assertEqual(b.watch_for("Первенство Москвы"), [])


ISU_RSS = '''<feed><entry><yt:videoId>AAAAAAAAAAA</yt:videoId>
<title>Men Short Program | ISU European Championships | Sheffield 2026 | #FigureSkating</title>
<published>2026-01-20T18:00:00+00:00</published></entry>
<entry><yt:videoId>BBBBBBBBBBB</yt:videoId>
<title>Junior Men Short Program | ISU Figure Skating Junior World Championships | Tallinn 2026</title>
<published>2026-01-20T18:30:00+00:00</published></entry></feed>'''


class IntlWatchTest(unittest.TestCase):
    def setUp(self):
        b._YT.clear()
        self.addCleanup(b._YT.clear)

    def ev(self, name, kind="men", level="senior", seg="КП"):
        import datetime as dt
        z = dt.datetime(2026, 1, 20, 17, tzinfo=dt.timezone.utc)
        return b.make_event(tid="isu:x", tournament=name, kind=kind, level=level, seg=seg, mixed=False,
                            start=z, end=z, venue="", intl=True, broadcast=[], ours=[], athletes=[], src="")

    def test_grand_prix_okko_and_isu(self):
        # В России этапы показывает Okko, остальному миру — YouTube ISU (страница ISU «Where to watch»).
        with mock.patch.object(b.net, "fetch", side_effect=b.net.FetchError("x")):
            e = self.ev("GP Skate America")
        self.assertEqual(e["watch"], [{"name": "Okko", "url": "https://okko.tv/", "note": "Россия"},
                                      {"name": "YouTube ISU", "url": "https://www.youtube.com/@SkatingISU/live",
                                       "note": "Кроме России"}])
        self.assertEqual(e["broadcast"], ["Okko", "YouTube ISU"])

    def test_final_has_both(self):
        with mock.patch.object(b.net, "fetch", side_effect=b.net.FetchError("x")):
            e = self.ev("Финал Гран-при")
        self.assertEqual([w["name"] for w in e["watch"]], ["Okko", "YouTube ISU"])
        self.assertEqual(e["watch"][1]["url"], "https://www.youtube.com/@SkatingISU/live")
        # страны финала ISU отдельно не называл — подписи нет, а не догадка
        self.assertFalse(any("note" in w for w in e["watch"]))

    def test_rss_match_by_segment(self):
        with mock.patch.object(b.net, "fetch", return_value=ISU_RSS):
            e = self.ev("Чемпионат Европы")
            self.assertEqual(e["watch"], [{"name": "YouTube ISU", "url": "https://www.youtube.com/watch?v=AAAAAAAAAAA"}])
            # другой сегмент и юниорский чемпионат мира: чужое видео не подставляем
            self.assertTrue(self.ev("Чемпионат Европы", seg="ПП")["watch"][0]["url"].endswith("/@SkatingISU/live"))
            self.assertTrue(self.ev("Чемпионат мира", level="junior")["watch"][0]["url"].endswith("/@SkatingISU/live"))
            j = self.ev("Чемпионат мира среди юниоров", level="junior")
            self.assertEqual(j["watch"][0]["url"], "https://www.youtube.com/watch?v=BBBBBBBBBBB")

    def test_rss_down_keeps_generic(self):
        with mock.patch.object(b.net, "fetch", side_effect=b.net.FetchError("x")):
            e = self.ev("Чемпионат Европы")
        self.assertEqual(e["watch"][0]["url"], "https://www.youtube.com/@SkatingISU/live")

    def test_tournament_page_wins(self):
        base = [{"name": "YouTube ISU", "url": "https://www.youtube.com/watch?v=PAGEPAGEPAG"}]
        self.assertEqual(b.watch_for("Чемпионат Европы", base), base)

    def test_unconfirmed_series_have_nothing(self):
        for n in ("CS Nebelhorn Trophy", "CS Lombardia Trophy", "CS Golden Spin of Zagreb", "Tayside Trophy"):
            self.assertEqual(b.watch_for(n), [])
            self.assertEqual(b.broadcast_for(n), [])

    def test_challenger_confirmed(self):
        want = {
            "CS Trialeti Trophy": "Okko",
            "CS Nepela Memorial": "Okko",
            "CS Ondrej Nepela Memorial": "Okko",
            "CS Denis Ten Memorial": "VK Видео",
            "CS Budapest Trophy": "HunSkate TV",
        }
        for n, name in want.items():
            w = b.watch_for(n)
            self.assertEqual([x["name"] for x in w], [name], n)
            self.assertTrue(w[0]["url"].startswith("https://"), n)
            self.assertEqual(b.broadcast_for(n), [name], n)

    def test_rules_have_sources(self):
        for r in b.CFG["broadcast_rules"]:
            self.assertTrue(r.get("source", "").startswith("http"), r["match"])


GP_RSS = '''<feed><entry><yt:videoId>SHENZHEN001</yt:videoId>
<title>Men Short Program | ISU Figure Skating Grand Prix | Shenzhen 2026</title>
<published>2026-11-03T07:45:00+00:00</published></entry>
<entry><yt:videoId>KELOWNA0001</yt:videoId>
<title>Men Short Program | ISU Figure Skating Grand Prix | Kelowna 2026</title>
<published>2026-10-27T07:45:00+00:00</published></entry>
<entry><yt:videoId>DANCESHENZH</yt:videoId>
<title>Ice Dance Rhythm Dance | ISU Figure Skating Grand Prix | Shenzhen 2026</title>
<published>2026-11-03T07:45:00+00:00</published></entry></feed>'''


class GrandPrixStreamTest(unittest.TestCase):
    """Эфир этапа Гран-при узнаётся по городу: ISU заводит эфиры за несколько дней до старта."""

    def setUp(self):
        b._YT.clear()
        self.addCleanup(b._YT.clear)

    def ev(self, venue, day, kind="men", seg="КП", name="GP Cup of China"):
        import datetime as dt
        z = dt.datetime(2026, 11, day, 6, tzinfo=dt.timezone.utc)
        with mock.patch.object(b.net, "fetch", return_value=GP_RSS):
            e = b.make_event(tid="isu:x", tournament=name, kind=kind, level="senior", seg=seg, mixed=False,
                             start=z, end=z, venue=venue, intl=True, broadcast=[], ours=[], athletes=[], src="")
        return {w["name"]: w["url"] for w in e["watch"]}

    def test_stream_created_days_ahead_is_found_by_city(self):
        w = self.ev("Shenzhen, China", 6)
        self.assertEqual(w["YouTube ISU"], "https://www.youtube.com/watch?v=SHENZHEN001")
        self.assertEqual(w["Okko"], "https://okko.tv/")
        self.assertEqual(self.ev("Shenzhen, China", 7, kind="dance", seg="РТ")["YouTube ISU"],
                         "https://www.youtube.com/watch?v=DANCESHENZH")

    def test_other_city_or_old_stream_not_used(self):
        self.assertEqual(self.ev("Everett, USA", 14, name="GP Skate America")["YouTube ISU"],
                         "https://www.youtube.com/@SkatingISU/live")
        # тот же город, но эфир заведён больше чем за 10 дней — это прошлый турнир
        self.assertEqual(self.ev("Shenzhen, China", 20)["YouTube ISU"], "https://www.youtube.com/@SkatingISU/live")

    def test_final_is_not_a_stage(self):
        self.assertEqual(b.broadcast_for("Финал Гран-при"), ["Okko", "YouTube ISU"])
        self.assertEqual(b._city("Shenzhen, China"), "Shenzhen")
        self.assertIsNone(b._city("ЛД «Мечта», Москва"))


def _solid(*items):
    return json.dumps([{"title": t, "start_at": ts, "price": price} for t, ts, price in items])


TALLINN_DAY1 = 1794917700  # 2026-11-16, Ice-Stars.TV «ISU CS Tallinn Trophy 2026 | Day 1»


class SolidsportTest(unittest.TestCase):
    """Челленджер на Ice-Stars.TV: ссылка — только если эфир заведён в дни турнира."""

    def setUp(self):
        b._SOLID.clear()
        self.addCleanup(b._SOLID.clear)

    def test_stream_in_tournament_days(self):
        feed = _solid(("ISU CS Tallinn Trophy 2026 | Day 1", TALLINN_DAY1, {"EUR": 9.99}))
        with mock.patch.object(b.net, "fetch", return_value=feed) as f:
            w = b.watch_for("CS Tallinn Trophy", days=(dt.date(2026, 11, 16), dt.date(2026, 11, 22)))
        self.assertEqual(w, [{"name": "Ice-Stars.TV", "url": "https://ice-stars.tv/tallinntrophy", "note": "Платно"}])
        self.assertIn("company=tallinntrophy", f.call_args[0][0])

    def test_free_stream_has_no_note(self):
        feed = _solid(("Day 1", TALLINN_DAY1, None))
        with mock.patch.object(b.net, "fetch", return_value=feed):
            w = b.watch_for("CS Tallinn Trophy", days=(dt.date(2026, 11, 16), dt.date(2026, 11, 16)))
        self.assertEqual(w, [{"name": "Ice-Stars.TV", "url": "https://ice-stars.tv/tallinntrophy"}])

    def test_last_year_channel_promises_nothing(self):
        # на канале только прошлогодние эфиры — турнира этого года там нет
        feed = _solid(("ISU CS Tallinn Trophy 2025 | Day 1", TALLINN_DAY1 - 365 * 86400, {"EUR": 9.99}))
        with mock.patch.object(b.net, "fetch", return_value=feed):
            self.assertEqual(b.watch_for("CS Tallinn Trophy", days=(dt.date(2026, 11, 16), dt.date(2026, 11, 22))), [])
        b._SOLID.clear()
        with mock.patch.object(b.net, "fetch", side_effect=b.net.FetchError("x")):
            self.assertEqual(b.watch_for("CS Tallinn Trophy", days=(dt.date(2026, 11, 16), dt.date(2026, 11, 22))), [])

    def test_event_day(self):
        feed = _solid(("Golden Spin of Zagreb | Day 1", 1796284800, {"EUR": 9.99}))  # 2026-12-03 08:00 UTC
        z = dt.datetime(2026, 12, 3, 10, tzinfo=dt.timezone.utc)
        with mock.patch.object(b.net, "fetch", return_value=feed):
            e = b.make_event(tid="isu:gs", tournament="CS Golden Spin of Zagreb", kind="men", level="senior", seg="КП",
                             mixed=False, start=z, end=z, venue="Zagreb, Croatia", intl=True, broadcast=[], ours=[],
                             athletes=[], src="")
        self.assertEqual(e["watch"][0]["url"], "https://ice-stars.tv/golden-spin")
        self.assertEqual(e["broadcast"], ["Ice-Stars.TV"])

    def test_upcoming_fields(self):
        feed = _solid(("Day 1", TALLINN_DAY1, {"EUR": 9.99}))
        with mock.patch.object(b.net, "fetch", return_value=feed):
            f = b._watch_fields("CS Tallinn Trophy", [], dt.date(2026, 11, 16), dt.date(2026, 11, 22))
        self.assertEqual(f["broadcast"], ["Ice-Stars.TV"])
        self.assertEqual(f["watch"][0]["name"], "Ice-Stars.TV")
        page = [{"name": "Первый канал", "url": "https://www.1tv.ru/sport/x"}]
        f = b._watch_fields("Гран-при России «Сердце Сибири»", ["Первый канал"], dt.date(2026, 11, 13),
                            dt.date(2026, 11, 15), page)
        self.assertEqual([w["name"] for w in f["watch"]], ["Первый канал", "YouTube"])
        self.assertEqual(f["broadcast"], ["Первый канал", "YouTube"])


PFSA_RSS = '''<feed><entry><yt:videoId>WARSAWDAY01</yt:videoId>
<title>PGE Warsaw Cup 2026 - Day I</title>
<published>2026-11-25T07:00:00+00:00</published></entry></feed>'''


class OnlyStreamTest(unittest.TestCase):
    """Варшава: канал федерации показывает много своих турниров — ссылка только на найденный эфир дня."""

    def setUp(self):
        b._YT.clear()
        self.addCleanup(b._YT.clear)

    def ev(self, day):
        z = dt.datetime(2026, 11, day, 10, tzinfo=dt.timezone.utc)
        with mock.patch.object(b.net, "fetch", return_value=PFSA_RSS):
            return b.make_event(tid="isu:w", tournament="CS PGE Warsaw Cup", kind="men", level="senior", seg="КП",
                                mixed=False, start=z, end=z, venue="Warsaw, Poland", intl=True, broadcast=[], ours=[],
                                athletes=[], src="")

    def test_found_day(self):
        self.assertEqual(self.ev(25)["watch"], [{"name": "YouTube PFSA", "url": "https://www.youtube.com/watch?v=WARSAWDAY01"}])

    def test_no_stream_no_link(self):
        self.assertNotIn("watch", self.ev(26))
        self.assertEqual(b.watch_for("CS PGE Warsaw Cup"), [])
        self.assertEqual(b.broadcast_for("CS PGE Warsaw Cup"), [])
