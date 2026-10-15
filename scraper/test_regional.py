"""Региональные источники на сохранённых фрагментах: python3 -m unittest scraper.test_regional

Фрагменты — с ffkm.ru (календарь, карточка турнира, табло Первенства Москвы, Чемпиона
Москвы), skate63.ru (карточки статей, календарь PDF) и PDF расписания 2025/26.
Сеть не нужна."""
import datetime as dt
import unittest

from . import build as b
from . import fsr
from . import people as pp
from . import regional as rg
from . import swisstiming as st

FFKM_CAL = """
<div class="calendar__show">Сезон 2026/2027</div>
<section class="important"><ul class="important__items">
<li class="important__header important__header_padding accordion-start-js ">
    <p>Август <span class="ffkm-cal-count">1</span></p></li>
<li class="important__list list accordion-content-js "><table class="table_calendar"><tbody>
<tr>
    <td data-number="р/н">89500</td>
    <td data-date="Даты">
        14 - 16    </td>
    <td data-name="Название соревнования">
        <div class="ffkm-cal-title-row">
            <span class="ffkm-cal-rn-badge" title="Реестровый номер">р/н 89500</span>
            <a href="detail/turnir-na-prizy-magazinov-figurist-sportivnoe-sovershenstvo-a1550/">
                <strong>
                    Турнир на призы магазина «Фигурист»                </strong>
            </a>
        </div>
    </td>
    <td data-place="Место проведения">
        ЛД «Мечта»    </td>
    <td data-program="Виды программы">
                    Одиночное катание: Девочки, Девушки, Мальчики, Юноши: 3,2,1 юношеские разряды 3,2,1 спортивные разряды КМС            </td>
    <td data-judges="Ответственные организации"><p>РОО «ФФКМ»</p></td>
</tr>
</tbody></table></li>
<li class="important__header important__header_padding accordion-start-js ">
    <p>Сентябрь <span class="ffkm-cal-count">1</span></p></li>
<li class="important__list list accordion-content-js "><table class="table_calendar"><tbody>
<tr>
    <td data-number="р/н">1</td>
    <td data-date="Даты">30 - 2</td>
    <td data-name="Название соревнования"><a href="detail/x-a2/"><strong>Турнир «Осень»</strong></a></td>
    <td data-place="Место проведения">СК «Вдохновение»</td>
    <td data-program="Виды программы">Все виды: КМС</td>
    <td data-judges="Ответственные организации"><p>ФФКМ</p></td>
</tr>
</tbody></table></li>
</ul></section>
"""

FFKM_CARD_CHEMPION = """
<p>Турнир на призы сети</p>
<a href="https://ffkm.ru/results/2026-2027/2026-08-24_pm/">Первенство Москвы</a>
<a href="https://ffkm.ru/results/2026-2027/2026-10-13_chamion/index.htm">Табло</a>
<a href="/upload/iblock/988/x/Reglament.pdf">Регламент</a>
"""

# Классическая вёрстка табло (ISUCalcFS): категории, расписание в <caption> вне <tr>
TABLO_INDEX = """
<html><head><title>Тестовое первенство </title></head><body>
<table cellspacing="1">
<tr bgcolor="CC33CC"> <th>Категория</th><th>Сегмент</th><th> </th><th> </th><th> </th></tr>
<tr bgcolor="#FFFF88"> <td>Taнцы нa льду, КМC, Юниopки, Юниopы</td><td></td><td><a href="CAT004EN.HTM"> Заявка </a></td><td><a href="CAT004RS.HTM"> Результаты </a></td><td> </td></tr>
<tr bgcolor="#FFFF88"> <td></td><td>Ритм-танец</td><td><a href="SEG007OF.HTM">Судьи</a></td><td><a href="SEG007.HTM"> Стартовый лист / Детализация </a></td><td></td></tr>
<tr bgcolor="#FFFF88"> <td></td><td>Произвольный танец</td><td><a href="SEG008OF.HTM">Судьи</a></td><td><a href="SEG008.HTM"> Стартовый лист / Детализация </a></td><td></td></tr>
</table>
<table cellspacing="1"><caption><h3>Расписание</h3></caption>
<tr bgcolor="CC33CC"><th>Дата</th><th>Час</th><th>Категория</th><th>Сегмент</th></tr>
<tr bgcolor="999999"><td>24.08.2026</td></tr>
<tr bgcolor="#FFFF88"> <td></td><td>15:00:00</td><td>Taнцы нa льду, КМC, Юниopки, Юниopы</td><td><a href="SEG007.HTM">Ритм-танец</a></td></tr>
</table>
</body></html>
"""

# Протокол сегмента/итога ФФКМ: шапка «М.», «Регион»; клуб в одной ячейке с именем после <br/>
PROTOCOL = """
<table>
<tr><th>М.</th><th>Имя</th><th>Регион</th><th>Баллы</th><th>KП</th><th>ПП</th></tr>
<tr><td align="center">1</td><td><a>Дарья Евгеньевна ЛЕБЕДЕВА</a><br/>ГБУ ДО МАФКК школа Хрустальный</td><td> </td><td align="right">205.43</td><td align="center">3</td><td align="center">1</td></tr>
<tr><td align="center">2</td><td><a>Софья Сергеевна СМАГИНА</a><br/>СШОР им.С.А.Жука</td><td>МОС</td><td align="right">200.21</td><td align="center">2</td><td align="center">2</td></tr>
</table>
"""

SAMARA_ARTICLE = """
<table><tr><td><a href="/upload/iblock/07e/a.pdf">Регламент - ВС «Самарочка» 2025</a></td></tr>
<tr><td><a href="/upload/iblock/3ab/b.pdf">Список участников - Общий</a></td></tr>
<tr><td><a href="/upload/iblock/6e8/c.pdf">Расписание (от 11.12.2025) - I этап</a></td></tr>
<tr><td><a href="/upload/iblock/b0d/d.pdf">Раписание - ВФМ Сызранская ласточка (от 23.02.2026)</a></td></tr>
<tr><td><a href="/upload/iblock/c68/e.pdf">Протокол - ВС Самарочка 2026</a></td></tr>
</table>
"""

SAMARA_CARDS = """
<div class="title">
  <a href="/info/articles/vs-samarochka-2026-/">ВС «Самарочка» 2026</a>
</div>
<div class="previewtext"><h4>19-21 февраля 2026</h4></div>
<div class="title"><a href="/info/articles/vfm-x-/">ВФМ &quot;Возрождение&quot;</a></div>
<div class="previewtext"><h4>30 ноября - 2 декабря 2026&nbsp;</h4></div>
"""

SAMARA_CAL = """
                                                                                  Октябрь 2026
21-24     Соревнования Самарской       Г. Самара      Одиночное катание:      СООО «ФФКК»,
                                          Ноябрь 2026
04      Соревнования по                Г. Сызрань     Одиночное катание:      СООО «ФФКК»
11-12   Чемпионат и первенство     Г. Самара    Синхронное катание:       СООО «ФФКК»
"""

SAMARA_SCHEDULE_HEAD = """
           г. Самара, СКК «Дворец спорта им. В. Высоцкого»                       16-19 апреля 2026 г.
"""

SAMARA_SCHEDULE_TEXT = """16 апреля (четверг)
Соревнования
20.00 – 21.15 – Женщины, КП
17 апреля (пятница)
Соревнования
12.20 – 13.15 – Танцы на льду, РП
Тренировки
08.00 – 09.20 – Женщины, КП
"""


class FfkmCalendar(unittest.TestCase):
    def test_rows_dates_and_fields(self):
        rows = rg.ffkm_calendar(FFKM_CAL)
        self.assertEqual(len(rows), 2)
        r = rows[0]
        self.assertEqual(r["start"], dt.date(2026, 8, 14))
        self.assertEqual(r["end"], dt.date(2026, 8, 16))
        self.assertEqual(r["title"], "Турнир на призы магазина «Фигурист»")
        self.assertEqual(r["place"], "ЛД «Мечта»")
        self.assertIn("КМС", r["program"])
        self.assertTrue(r["page"].endswith("/detail/turnir-na-prizy-magazinov-figurist-sportivnoe-sovershenstvo-a1550/"))

    def test_month_rollover(self):
        # «30 - 2» в сентябре: конец — 2 октября
        r = rg.ffkm_calendar(FFKM_CAL)[1]
        self.assertEqual((r["start"], r["end"]), (dt.date(2026, 9, 30), dt.date(2026, 10, 2)))

    def test_no_season_header_gives_nothing(self):
        self.assertEqual(rg.ffkm_calendar("<html></html>"), [])


class FfkmTable(unittest.TestCase):
    def test_table_link_prefers_tournament_date(self):
        url = "https://ffkm.ru/season/competitions/calendar-of-sports-competitions/detail/chempion-a1/"
        self.assertEqual(rg.ffkm_table_url(FFKM_CARD_CHEMPION, url, dt.date(2026, 10, 13)),
                         "https://ffkm.ru/results/2026-2027/2026-10-13_chamion/index.htm")
        # папка без index.htm — тоже табло, адрес дополняется
        self.assertEqual(rg.ffkm_table_url(FFKM_CARD_CHEMPION, url, dt.date(2026, 8, 24)),
                         "https://ffkm.ru/results/2026-2027/2026-08-24_pm/index.htm")

    def test_no_table_yet(self):
        self.assertIsNone(rg.ffkm_table_url("<p>Регламент</p>", "https://ffkm.ru/x/", None))


class Dates(unittest.TestCase):
    def test_card_dates(self):
        self.assertEqual(rg.card_dates("26-29 ноября 2026"),
                         (dt.date(2026, 11, 26), dt.date(2026, 11, 29)))
        self.assertEqual(rg.card_dates("30 ноября - 2 декабря 2026"),
                         (dt.date(2026, 11, 30), dt.date(2026, 12, 2)))
        self.assertEqual(rg.card_dates("25 декабря - 2 января 2026"),
                         (dt.date(2025, 12, 25), dt.date(2026, 1, 2)))
        self.assertEqual(rg.card_dates("25 января 2026\xa0"), (dt.date(2026, 1, 25), dt.date(2026, 1, 25)))
        self.assertIsNone(rg.card_dates("скоро"))

    def test_samara_calendar_ranges(self):
        got = rg.samara_calendar_ranges(SAMARA_CAL)
        self.assertIn((dt.date(2026, 10, 21), dt.date(2026, 10, 24)), got)
        self.assertIn((dt.date(2026, 11, 4), dt.date(2026, 11, 4)), got)
        self.assertIn((dt.date(2026, 11, 11), dt.date(2026, 11, 12)), got)

    def test_samara_cards_regex(self):
        found = rg._CARD.findall(SAMARA_CARDS)
        self.assertEqual(len(found), 2)
        self.assertEqual(rg.card_dates(found[1][2]), (dt.date(2026, 11, 30), dt.date(2026, 12, 2)))

    def test_schedule_links_skip_protocols_and_accept_typo(self):
        base = "http://skate63.ru/info/articles/vs-samarochka-2026-/"
        got = rg.schedule_links(SAMARA_ARTICLE, base)
        self.assertEqual(len(got), 2)
        self.assertTrue(got[0].endswith("/upload/iblock/6e8/c.pdf"))
        self.assertTrue(got[1].endswith("/upload/iblock/b0d/d.pdf"))

    def test_schedule_venue(self):
        self.assertEqual(rg.schedule_venue(SAMARA_SCHEDULE_HEAD),
                         ("Самара", "СКК «Дворец спорта им. В. Высоцкого»"))

    def test_season_hint_from_card_date(self):
        # расписание 2025/26 (апрель 2026) разбирается с hint=2025; с hint=2026 даты уехали бы в 2027
        rows = fsr.schedule_text(SAMARA_SCHEDULE_TEXT, 2025)
        self.assertEqual(rows[0][0], dt.date(2026, 4, 16))
        self.assertEqual(rows[0][3], "Женщины, КП")
        self.assertEqual(len(rows), 2)  # строки из «Тренировки» не берём


class Swisstiming(unittest.TestCase):
    def test_caption_schedule_and_mixed_script(self):
        idx = st.parse_index_page(TABLO_INDEX, "https://ffkm.ru/results/2026-2027/x/index.htm", 180)
        self.assertEqual(idx["offset"], 180)
        self.assertEqual(len(idx["categories"]), 1)
        c = idx["categories"][0]
        self.assertEqual(c["name"], "Танцы на льду, КМС, Юниорки, Юниоры")
        self.assertEqual([s["name"] for s in c["segments"]], ["Ритм-танец", "Произвольный танец"])
        start = c["segments"][0]["start"]
        self.assertEqual(start.isoformat(), "2026-08-24T15:00:00+03:00")
        self.assertNotIn("start", c["segments"][1])

    def test_no_offset_on_page_and_no_default_gives_naive_start(self):
        idx = st.parse_index_page(TABLO_INDEX, "u", None)
        self.assertIsNone(idx["offset"])
        self.assertIsNone(idx["categories"][0]["segments"][0]["start"].tzinfo)

    def test_protocol_header_region_and_club(self):
        header, rows = st._result_rows(PROTOCOL, ("TSS", "Сумма", "Points", "Баллы"), False)
        self.assertEqual(header[0], "М.")
        self.assertEqual([r["place"] for r in rows], [1, 2])
        self.assertEqual(rows[0]["name"], "Дарья Евгеньевна ЛЕБЕДЕВА")  # без клуба
        self.assertEqual(rows[0]["points"], "205.43")
        self.assertEqual(rows[1]["nation"], "МОС")
        self.assertEqual(pp.entry_name(rows[0]["name"]), "Дарья ЛЕБЕДЕВА")

    def test_fix_script(self):
        self.assertEqual(st.fix_script("Oдинoчнoe кaтaниe, КМC, Девушки"), "Одиночное катание, КМС, Девушки")
        self.assertEqual(st.fix_script("Men Singles"), "Men Singles")
        self.assertEqual(st.fix_script("Одиночное катание, MC - Мужчины"), "Одиночное катание, МС - Мужчины")
        self.assertEqual(st.fix_script("Одиночное катание, KMC, Юниоры"), "Одиночное катание, КМС, Юниоры")

    def test_name_entries_without_patronymic(self):
        self.assertEqual(pp.entry_name("Таисия Денисовна ГУСЕВА / Даниил Дмитриевич ОВЧИННИКОВ"),
                         "Таисия ГУСЕВА / Даниил ОВЧИННИКОВ")


class BuildHelpers(unittest.TestCase):
    def test_federal_duplicate_by_dates_and_name(self):
        fed = [{"start": dt.date(2026, 8, 24), "end": dt.date(2026, 8, 28), "title": "Первенство Москвы"}]
        self.assertTrue(b._fed_dup("Первенство Москвы", dt.date(2026, 8, 24), dt.date(2026, 8, 28), fed))
        self.assertFalse(b._fed_dup("Первенство Москвы", dt.date(2026, 8, 25), dt.date(2026, 8, 28), fed))
        self.assertFalse(b._fed_dup("Кубок «Другой»", dt.date(2026, 8, 24), dt.date(2026, 8, 28), fed))

    def test_regional_upcoming_is_tagged(self):
        u = b._regional_upcoming("ffkm:x", "Первенство", dt.date(2026, 8, 24), dt.date(2026, 8, 28), "ЛД", "Москва")
        self.assertEqual((u["tier"], u["region"], u["intl"]), ("regional", "Москва", False))
        self.assertEqual(u["start"], "2026-08-24")


if __name__ == "__main__":
    unittest.main()
