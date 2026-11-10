"""Сегменты в расписаниях ФФККР: полные слова и сокращения (КП, ПП, РП, ПТ)."""
import unittest
from unittest import mock

from scraper import fsr


class SegmentTest(unittest.TestCase):
    def test_abbreviations(self):
        cases = {
            "Женщины, КП": "КП",
            "Мужчины, ПП": "ПП",
            "Парное катание КП": "КП",
            "Парное катание, ПП": "ПП",
            # у танцев «РП» — ритм-танец, «ПП» последнего дня — произвольный танец
            "Танцы на льду, РП": "РТ",
            "Танцы на льду, ПП": "ПТ",
            "Танцы на льду, РТ": "РТ",
            "Танцы на льду, ПТ": "ПТ",
        }
        for text, seg in cases.items():
            self.assertEqual(fsr.segment_of(text), seg, text)

    def test_full_words_still_work(self):
        self.assertEqual(fsr.segment_of("Юниорки, короткая программа"), "КП")
        self.assertEqual(fsr.segment_of("Ритм-танец"), "РТ")
        self.assertEqual(fsr.segment_of("Произвольный танец"), "ПТ")

    def test_not_a_segment(self):
        for text in ("подготовка льда", "Церемония награждение", "жеребьевка участников МС"):
            self.assertIsNone(fsr.segment_of(text), text)


class TournamentTest(unittest.TestCase):
    """Заголовок страницы турнира: title — до « - », full — целиком, без хвоста сайта."""
    PAGE = ('<html><head><title>Всероссийские соревнования "Гран При России" - 2 этап - '
            'Федерация фигурного катания на коньках России</title></head><body></body></html>')

    def test_full_and_short_title(self):
        with mock.patch.object(fsr.net, "fetch", lambda u, **k: self.PAGE):
            t = fsr.tournament("https://fsrussia.ru/sorevnovaniya/gpr-2-etap")
        self.assertEqual(t["title"], 'Всероссийские соревнования "Гран При России"')
        self.assertEqual(t["full"], 'Всероссийские соревнования "Гран При России" - 2 этап')


if __name__ == "__main__":
    unittest.main()


class CardTest(unittest.TestCase):
    """Картотека спортсменов ФФККР: список и карточка."""
    LIST = ('<small>Страница 1 из 10 Всего: 182</small>'
            '<a data-rowid="1" href="/athlete/details/43/1.html" > Акатьева Софья Дмитриевна</a>'
            '<a data-rowid="1716" href="/athlete/details/43/1716.html" > Алексахин Михаил Владиславович</a>')
    CARD = '''<div class="fabrikElementReadOnly" id="ctl_athletes___athlete_photo_ro"><div class="fabrikSubElementContainer">
<img class="fabrikLightBoxImage" height="300px" src="https://fsrussia.ru/images/fabrik/athletes/aleksakhin.jpg" alt="" /> </div></div>
<div class="fabrikElementReadOnly" id="ctl_athletes___biography_ro"></div>
<div class="fabrikElementReadOnly" id="ctl_athletes___birthdate_ro">17-03-2011 </div>
<div class="fabrikElementReadOnly" id="ctl_athletes___fs_kind_ro"><span><strong>Мужское одиночное катание</strong></span></div>
<div class="fabrikElementReadOnly" id="ctl_athletes___partner_ro"></div>
<div class="fabrikElementReadOnly" id="ctl_athletes___club_ro"><ul><li>Академия ФК "Ангелы Плющенко"<li>УОР №1</li></ul><br /> </div>
<div class="fabrikElementReadOnly" id="ctl_athletes___coach_ro"><ul><li>Значков Артём Аркадьевич<li>Плющенко Евгений Викторович</li></ul></div>
<div class="fabrikElementReadOnly" id="ctl_athletes___sport_rank_ro">КМС</div>
<div class="fabrikElementReadOnly" id="ctl_athletes___region_ro">Пожалуйста, выберите</div>
<tr id="list_47_com_content_47_row_14461" class="fabrik_row">
<td class="ctl_athlete_results___season fabrik_element" > 2025-2026 </td>
<td class="ctl_athlete_results___id_competition fabrik_element" > Первенство России среди юниоров 2026 </td>
<td class="ctl_athlete_results___result fabrik_element" > 14 </td></tr>'''

    def test_list(self):
        rows, total = fsr.card_list(self.LIST)
        self.assertEqual(rows, [(1, "Акатьева Софья Дмитриевна"), (1716, "Алексахин Михаил Владиславович")])
        self.assertEqual(total, 182)

    def test_card(self):
        c = fsr.card(self.CARD)
        self.assertEqual(c["photo"], "https://fsrussia.ru/images/fabrik/athletes/aleksakhin.jpg")
        self.assertEqual((c["born"], c["kind"], c["rank"], c["region"]), ("2011-03-17", "m", "КМС", ""))
        self.assertEqual(c["club"], ['Академия ФК "Ангелы Плющенко"', "УОР №1"])
        self.assertEqual(c["coach"], ["Значков Артём Аркадьевич", "Плющенко Евгений Викторович"])
        self.assertEqual(c["partner"], [])
        self.assertEqual(c["results"], [{"season": "2025-2026", "event": "Первенство России среди юниоров 2026", "place": "14"}])

    def test_placeholder_image_is_not_a_photo(self):
        c = fsr.card('<div id="ctl_athletes___athlete_photo_ro"><img src="/media/com_fabrik/images/default.png"></div>')
        self.assertEqual(c["photo"], "")
