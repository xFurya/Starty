import datetime as dt
import json
import os
import tempfile
import unittest

from scraper import net
from scraper import profiles as pf
from scraper import teams as tm


def ffkr_section(title, tabs):
    """Раздел-аккордеон ФФККР: заголовок и вкладки {id: [(ФАМИЛИЯ, Имя)]}."""
    out = [f'<div class="accordion-heading"><a title="{title}"><strong>{title}</strong></a></div>',
           f'<h2 class="rl_sliders-title nn_sliders-title"><strong>{title}</strong></h2>']
    for tab, people in tabs.items():
        out.append(f'<div class="tab-pane rl_tabs-pane nn_tabs-pane color_content" id="{tab}"\nrole="tabpanel">')
        for sur, giv in people:
            slug = sur.lower()
            out.append(f'<a href="/sbornaya/teams/{slug}"><img src="/images/{slug}.jpg"></a>'
                       f'<a href="/sbornaya/teams/{slug}"><strong>{sur}<br>{giv}<br>Отчество</strong></a>')
        out.append("</div>")
    return "\n".join(out)


FFKR = "\n".join([
    "<ul><li>Списки кандидатов в спортивные сборные команды РФ по фигурному катанию на коньках на 2026-2027 гг.</li>",
    "<li>Списки кандидатов в спортивные сборные команды РФ по фигурному катанию на коньках на 2025-2026 гг.</li></ul>",
    ffkr_section("Мужчины, женщины. Основной состав", {
        "parnoe-katanie": [("БОЙКОВА", "Александра"), ("КОЗЛОВСКИЙ", "Дмитрий")],
        "odinochnoe-katanie-muzhchiny": [("ГУМЕННИК", "Пётр")],
        "odinochnoe-katanie-zhenshchiny": [("ПЕТРОСЯН", "Аделия")],
    }),
    ffkr_section("Мужчины, женщины. Резервный состав", {
        "odinochnoe-katanie-zhenshchiny-2": [("ИГНАТОВА", "Александра")],
        "tantsy-na-l-du-2": [("ЖДАНОВА", "Варвара")],
    }),
    ffkr_section("Юниоры, юниорки. Основной состав", {
        "odinochnoe-katanie-yuniory": [("КОВТУН", "Глеб")],
    }),
])

JSF = """<p class="u-tac u-mb40">2026/2027 シーズン( 公財) 日本スケート連盟 強化選手です。</p>
<h2 class="c-secTtl05">特別強化選手</h2>
<ul><li><div class="c-cornerBox"><p class="c-palyeyList_item_ttl">MEN</p></div></li>
<li><a href="./detail.php?id=1"><figure><img src="a.jpg"></figure>
<p class="c-palyeyList_item_name2"><span>佐藤 駿</span><small>SATO Shun</small></p></a></li></ul>
<ul><li><p class="c-palyeyList_item_ttl">WOMEN</p></li>
<li><a href="./detail.php?id=2"><p class="c-palyeyList_item_name2"><span>島田 麻央</span><small>SHIMADA Mao</small></p></a></li></ul>
<h2 class="c-secTtl05">強化選手B</h2>
<ul><li><p class="c-palyeyList_item_ttl">MEN</p></li>
<li><a><p class="c-palyeyList_item_name2"><span>片伊勢 武 アミン</span><small>KATAISE Takeru Amine</small></p></a></li></ul>
<h2 class="c-secTtl05">ペア特別強化選手</h2>
<ul><li><a><p class="c-palyeyList_item_name2"><span>長岡 柚奈</span><small>NAGAOKA Yuna</small></p></a></li>
<li><a><p class="c-palyeyList_item_name2"><span>森口 澄士</span><small>MORIGUCHI Sumitada</small></p></a></li></ul>
<h2 class="c-secTtl05">シンクロナイズド強化チームB</h2>
<ul><li><a><p class="c-palyeyList_item_name2"><span>Jingu Ice Messengers</span><small>Jingu Ice Messengers</small></p></a></li></ul>
"""

TODAY = dt.date(2026, 11, 7)


def lists():
    return {"RUS": {"src": "ФФККР", "y": "2026/27", "m": tm.parse_ffkr(FFKR)["m"]},
            "JPN": {"src": "федерации Японии", "y": "2026/27", "m": tm.parse_jsf(JSF)["m"]},
            "CAN": {"src": "Skate Canada", "y": "2026/27", "m": [
                {"n": "Marjorie Lajoie", "k": "d", "t": "основной состав"},
                {"n": "Jean-Luc Baker", "k": "d", "t": "основной состав"},
                {"n": "Fée Ann Landry", "k": "w", "t": "основной состав"}]}}


class ParseTest(unittest.TestCase):
    def test_ffkr_sections_kinds_and_latest_season(self):
        got = tm.parse_ffkr(FFKR)
        self.assertEqual(got["y"], "2026/27")
        self.assertIn({"n": "Пётр Гуменник", "k": "m", "t": "основной состав"}, got["m"])
        self.assertIn({"n": "Александра Бойкова", "k": "p", "t": "основной состав"}, got["m"])
        self.assertIn({"n": "Варвара Жданова", "k": "d", "t": "резервный состав"}, got["m"])
        self.assertIn({"n": "Глеб Ковтун", "k": "m", "t": "юниорский основной состав"}, got["m"])
        self.assertEqual(len(got["m"]), 7)

    def test_ffkr_without_season_or_people_is_none(self):
        self.assertIsNone(tm.parse_ffkr(FFKR.replace("2026-2027 гг.", "").replace("2025-2026 гг.", "")))
        self.assertIsNone(tm.parse_ffkr("<html>Списки кандидатов … на 2026-2027 гг.</html>"))

    def test_jsf_groups_latin_names_and_no_synchro(self):
        got = tm.parse_jsf(JSF)
        self.assertEqual(got["y"], "2026/27")
        self.assertEqual(got["m"], [
            {"n": "Shun Sato", "k": "m", "t": "особый состав"},
            {"n": "Mao Shimada", "k": "w", "t": "особый состав"},
            {"n": "Takeru Amine Kataise", "k": "m", "t": "состав B"},
            {"n": "Yuna Nagaoka", "k": "p", "t": "особый состав"},
            {"n": "Sumitada Moriguchi", "k": "p", "t": "особый состав"},
        ])

    def test_season_end(self):
        self.assertEqual(tm.season_end("2026/27"), dt.date(2027, 6, 30))
        self.assertIsNone(tm.season_end("2026"))


class ForProfileTest(unittest.TestCase):
    def find(self, name, nation, kind, today=TODAY, aliases=None):
        return tm.for_profile(name, nation, kind, lists(), today, aliases)

    def test_single_by_name_nation_kind(self):
        self.assertEqual(self.find("Пётр Гуменник", "RUS", "m"),
                         ({"c": "Россия", "t": "основной состав", "y": "2026/27"}, "ФФККР"))
        # на турнирах ISU россиянин — нейтральный
        self.assertEqual(self.find("Petr Gumennik", "AIN", "m")[0]["c"], "Россия")
        self.assertEqual(self.find("Shun Sato", "JPN", "m")[0]["t"], "особый состав")
        self.assertEqual(self.find("Takeru Amine KATAISE", "JPN", "M")[0]["t"], "состав B")
        self.assertEqual(self.find("Fee Ann Landry", "CAN", "w")[0]["c"], "Канада")

    def test_namesake_elsewhere_gets_nothing(self):
        self.assertEqual(self.find("Shun Sato", "USA", "m"), (None, ""))  # другая страна
        self.assertEqual(self.find("Пётр Гуменник", "RUS", "d"), (None, ""))  # другой вид
        self.assertEqual(self.find("Иван Иванов", "RUS", "m"), (None, ""))

    def test_pair_needs_both_partners_in_one_squad(self):
        self.assertEqual(self.find("Yuna Nagaoka / Sumitada Moriguchi", "JPN", "p")[0]["t"], "особый состав")
        self.assertEqual(self.find("Александра Бойкова / Дмитрий Козловский", "RUS", "p")[0]["t"], "основной состав")
        # прежняя пара: Лажуа в сборной уже с Бейкером
        self.assertEqual(self.find("Marjorie Lajoie / Zachary Lagha", "CAN", "d"), (None, ""))
        self.assertEqual(self.find("Marjorie Lajoie / Jean-Luc Baker", "CAN", "d")[0]["t"], "основной состав")

    def test_alias_married_name(self):
        al = {"Александра Игнатова": "Александра Трусова"}
        self.assertEqual(self.find("Александра Трусова", "RUS", "w", aliases=al)[0]["t"], "резервный состав")

    def test_season_over_no_row(self):
        self.assertEqual(self.find("Пётр Гуменник", "RUS", "m", today=dt.date(2027, 7, 1)), (None, ""))
        self.assertIsNotNone(self.find("Пётр Гуменник", "RUS", "m", today=dt.date(2027, 6, 30))[0])


class LoadTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "teams.json")
        tm._write(self.path, {"_": "заметка", "at": "", "lists": {
            "CAN": {"src": "Skate Canada", "u": "https://skatecanada.ca/?p=22798", "y": "2026/27",
                    "m": [{"n": "Wesley Chiu", "k": "m", "t": "основной состав"}]}}})
        self.now = dt.datetime(2026, 11, 7, 6, tzinfo=dt.timezone.utc)

    def test_fetches_auto_keeps_manual(self):
        pages = {tm.FFKR: FFKR, tm.JSF: JSF}
        got = tm.load(self.now, self.path, fetch=pages.__getitem__, log=lambda *a: None)
        self.assertEqual(sorted(got), ["CAN", "JPN", "RUS"])
        self.assertEqual(got["CAN"]["m"][0]["n"], "Wesley Chiu")
        with open(self.path, encoding="utf-8") as f:
            saved = json.load(f)
        self.assertEqual(saved["_"], "заметка")
        self.assertEqual(saved["lists"]["RUS"]["src"], "ФФККР")
        # свежее — второй раз не спрашиваем
        got2 = tm.load(self.now + dt.timedelta(hours=1), self.path, fetch=lambda u: 1 / 0, log=lambda *a: None)
        self.assertEqual(got2["JPN"]["y"], "2026/27")

    def test_silence_or_new_markup_keeps_saved(self):
        pages = {tm.FFKR: FFKR, tm.JSF: JSF}
        tm.load(self.now, self.path, fetch=pages.__getitem__, log=lambda *a: None)

        def broken(url):
            if url == tm.FFKR:
                raise net.FetchError("503")
            return "<html>新しいデザイン</html>"
        got = tm.load(self.now + dt.timedelta(days=2), self.path, fetch=broken, log=lambda *a: None)
        self.assertEqual(len(got["RUS"]["m"]), 7)
        self.assertEqual(len(got["JPN"]["m"]), 5)


class WriteTest(unittest.TestCase):
    def test_profile_gets_team_and_source(self):
        out = tempfile.mkdtemp()
        people = [{"n": "Shun Sato", "c": "JPN", "k": "m"}, {"n": "Ilia Malinin", "c": "USA", "k": "m"}]
        bio = {"at": "2026-11-01T00:00:00+00:00", "bio": {"who": [{"born": "2004-01-20"}]}, "cr": []}
        store = {"ids": {"sato shun": "1", "ilia malinin": "2"}, "bios": {"1": bio, "2": bio}}
        pf.write(people, store, {}, out_dir=out, log=lambda *a: None, teams=lists(), today=TODAY, aliases={})
        with open(os.path.join(out, people[0]["p"] + ".json"), encoding="utf-8") as f:
            sato = json.load(f)
        with open(os.path.join(out, people[1]["p"] + ".json"), encoding="utf-8") as f:
            malinin = json.load(f)
        self.assertEqual(sato["team"], {"c": "Япония", "t": "особый состав", "y": "2026/27"})
        self.assertEqual(sato["src"], ["ISU", "федерации Японии"])
        self.assertNotIn("team", malinin)
        self.assertEqual(malinin["src"], ["ISU"])


if __name__ == "__main__":
    unittest.main()
