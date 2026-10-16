"""Где смотреть: ссылки со страницы турнира и правила из config.json (сеть не нужна)."""
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
        self.assertEqual(b.watch_for("JGP Gdansk"), [{"name": "Okko", "url": "https://okko.tv/"}])
        self.assertEqual(b.broadcast_for("JGP Gdansk"), ["Okko"])

    def test_page_wins_over_rule(self):
        base = [{"name": "Okko", "url": "https://okko.tv/event/1"}, {"name": "x", "url": "ftp://bad"}]
        self.assertEqual(b.watch_for("JGP Ankara", base), [{"name": "Okko", "url": "https://okko.tv/event/1"}])

    def test_event_field(self):
        import datetime as dt
        z = dt.datetime(2026, 9, 1, 12, tzinfo=dt.timezone.utc)
        ev = b.make_event(tid="t", tournament="JGP Ankara", kind="men", level="junior", seg="КП", mixed=False,
                          start=z, end=z, venue="", intl=True, broadcast=[], ours=[], athletes=[], src="")
        self.assertEqual(ev["watch"], [{"name": "Okko", "url": "https://okko.tv/"}])
        self.assertEqual(ev["broadcast"], ["Okko"])
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

    def test_grand_prix_okko(self):
        e = self.ev("GP Skate America")
        self.assertEqual(e["watch"], [{"name": "Okko", "url": "https://okko.tv/"}])
        self.assertEqual(e["broadcast"], ["Okko"])

    def test_final_has_both(self):
        with mock.patch.object(b.net, "fetch", side_effect=b.net.FetchError("x")):
            e = self.ev("Финал Гран-при")
        self.assertEqual([w["name"] for w in e["watch"]], ["Okko", "YouTube ISU"])
        self.assertEqual(e["watch"][1]["url"], "https://www.youtube.com/@SkatingISU/live")

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
