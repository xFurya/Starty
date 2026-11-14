"""Проверки разбора табло: python3 -m unittest scraper.test_swisstiming"""
import datetime as dt
import unittest

from . import swisstiming as st

SEG = ('<tr><th>Pl.</th><th>Name</th><th>Nation</th><th>TSS</th><th>TES</th><th>PCS</th></tr>')
TOT = ('<tr><th>Pl.</th><th>Name</th><th>Nation</th><th>Total</th><th>SP</th><th>FS</th></tr>')
TOTAL = ('<table>' + TOT +
         '<tr><td>1</td><td>Ivan SEMENOV</td><td>RUS</td><td>178.37</td><td>1</td><td>1</td></tr>'
         '<tr><td>2</td><td>Max GALKIN</td><td>RUS</td><td>169.82</td><td>2</td><td>2</td></tr></table>')
SEGMENT = ('<table>' + SEG +
           '<tr><td>1</td><td>Ivan SEMENOV</td><td>RUS</td><td>115.66</td><td>56.56</td><td>59.10</td></tr>'
           '<tr><td>2</td><td>Max GALKIN</td><td>RUS</td><td>114.72</td><td>52.78</td><td>61.94</td></tr></table>')


class Tables(unittest.TestCase):
    def test_segment_table_beats_total_in_any_order(self):
        for page in (TOTAL + SEGMENT, SEGMENT + TOTAL):
            rows = st.parse_segment_results(page)
            self.assertEqual([r["points"] for r in rows], ["115.66", "114.72"])

    def test_one_person_one_row(self):
        page = ('<table>' + SEG +
                '<tr><td>1</td><td>A B</td><td>RUS</td><td>100.00</td><td>50.00</td><td>50.00</td></tr>'
                '<tr><td>1</td><td>A B</td><td>RUS</td><td>90.00</td><td>45.00</td><td>45.00</td></tr></table>')
        rows = st.parse_segment_results(page)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["points"], "100.00")

    def test_starting_list_is_not_results(self):
        page = '<table><tr><th>StN.</th><th>Name</th><th>Nation</th></tr><tr><td>1</td><td>A B</td><td>RUS</td></tr></table>'
        self.assertIsNone(st.parse_segment_results(page))

    def test_remaining_starting_order_is_not_results(self):
        # табло посреди старта: после таблицы сегмента идёт «Remaining Starting Order» —
        # номер, команда, ранг и баллы прошлого сегмента; это не места
        page = ('<table>' + SEG +
                '<tr><td>1</td><td>Ivan SEMENOV</td><td>RUS</td><td>99.55</td><td>49.82</td><td>50.73</td></tr>'
                '<tr><td>2</td><td>Max GALKIN</td><td>RUS</td><td>88.23</td><td>39.92</td><td>49.31</td></tr></table>'
                '<table><tr><th>StN.</th><th>Name</th><th>Nation</th><th>Rank</th><th>Points</th></tr>'
                '<tr><td>3</td><td>Petr PETROV</td><td>RUS</td><td>6</td><td>58.37</td></tr>'
                '<tr><td>4</td><td>Oleg OLEGOV</td><td>RUS</td><td>5</td><td>60.85</td></tr></table>')
        rows = st.parse_segment_results(page)
        self.assertEqual([(r["place"], r["points"]) for r in rows], [(1, "99.55"), (2, "88.23")])


INDEX = ('<html><title>T</title><body><table>'
         '<tr><td><a href="CAT001EN.htm">Men</a></td><td><a href="CAT001RS.htm">R</a></td></tr>'
         '<tr><td><a href="SEG001.htm">Short Program</a></td></tr>'
         '<tr><td>Time Schedule (Local Time, UTC {label})</td></tr>'
         '<tr><td>{date}</td><td>{time}</td><td>Men</td><td>Short Program</td></tr>'
         '</table></body></html>')


def _start(idx):
    return idx["categories"][0]["segments"][0]["start"]


class Zones(unittest.TestCase):
    """Подпись пояса на табло ненадёжна: ФФКР ставит её неверно, ISU — на момент выкладки страницы."""

    def test_fsr_label_is_ignored_when_city_zone_is_known(self):
        # «Золото Урала»: табло пишет «UTC +03:00», а время — екатеринбургское (+5)
        idx = st.parse_index_page(INDEX.format(label="+03:00", date="05.11.2026", time="16:40:00"), "u")
        st.set_zone(idx, dt.timezone(dt.timedelta(hours=5)))
        self.assertEqual(_start(idx).astimezone(dt.timezone.utc), dt.datetime(2026, 11, 5, 11, 40, tzinfo=dt.timezone.utc))

    def test_iana_zone_gives_offset_of_the_segment_date(self):
        # Skate Canada: страница выложена после перевода часов (UTC -08:00), старт 30.10 — ещё летнее (-7)
        from zoneinfo import ZoneInfo
        idx = st.parse_index_page(INDEX.format(label="-08:00", date="30.10.2026", time="18:00:00"), "u")
        st.set_zone(idx, ZoneInfo("America/Los_Angeles"))
        self.assertEqual(_start(idx).astimezone(dt.timezone.utc), dt.datetime(2026, 10, 31, 1, 0, tzinfo=dt.timezone.utc))

    def test_zone_from_label_at_page_time(self):
        # США: страница выложена после перевода часов (UTC -08:00), старт 30.10 — ещё летнее (-7)
        at = dt.datetime(2026, 11, 2, 1, 22, tzinfo=dt.timezone.utc)
        z = st.zone_from_label("USA", -480, at, [dt.datetime(2026, 10, 30, 18, 0)])
        self.assertIsNotNone(z)
        self.assertEqual(dt.datetime(2026, 10, 30, 18, 0, tzinfo=z).utcoffset(), dt.timedelta(hours=-7))
        # Франция: страница 25.10 вечером (+01:00), старт 24.10 — ещё +02:00
        z = st.zone_from_label("FRA", 60, dt.datetime(2026, 10, 25, 18, 14, tzinfo=dt.timezone.utc),
                               [dt.datetime(2026, 10, 24, 18, 0)])
        self.assertEqual(dt.datetime(2026, 10, 24, 18, 0, tzinfo=z).utcoffset(), dt.timedelta(hours=2))

    def test_zone_from_label_unknown_country_keeps_label(self):
        self.assertIsNone(st.zone_from_label("XYZ", 60, dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)))
        self.assertIsNone(st.zone_from_label("FRA", None, dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)))
        # подпись, которой у страны не бывает, — не угадываем
        self.assertIsNone(st.zone_from_label("FRA", 300, dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)))

    def test_fix_zone_without_known_zone_uses_label_and_page_time(self):
        from . import net
        url = "https://example.org/fra/index.htm"
        net.LAST_MODIFIED[url] = "Sun, 25 Oct 2026 18:14:51 GMT"
        try:
            idx = st.parse_index_page(INDEX.format(label="+01:00", date="24.10.2026", time="18:00:00"), url)
            idx["nation"] = "FRA"
            st.fix_zone(idx)
        finally:
            net.LAST_MODIFIED.pop(url, None)
        self.assertEqual(_start(idx).astimezone(dt.timezone.utc), dt.datetime(2026, 10, 24, 16, 0, tzinfo=dt.timezone.utc))


class ElementLine(unittest.TestCase):
    """Строка элемента судейских оценок (comnet): заглавная X — отметка второй половины, как строчная x."""
    LINE = ("   7     4Tq                                 q      10.45 X 0.00                     0      0         1   -1      0"
            "       -1    0      0        1                             10.45")

    def test_capital_x_is_second_half_bonus(self):
        el = st._element(self.LINE)
        self.assertIsNotNone(el)
        self.assertEqual(el["code"], "4Tq")
        self.assertEqual(el["base"], 10.45)
        self.assertTrue(el.get("x"))

    def test_same_as_lowercase_x(self):
        self.assertEqual(st._element(self.LINE), st._element(self.LINE.replace(" X ", " x ")))


class SplitNation(unittest.TestCase):
    """Страна в хвосте имени: у длинной пары в PDF один пробел, у одиночного имени — колонка страны."""

    def test_pair_with_one_space_before_nation(self):
        self.assertEqual(st.split_nation("Deanna STELLATO-DUDEK / Maxime DESCHAMPS CAN"),
                         ("Deanna STELLATO-DUDEK / Maxime DESCHAMPS", "CAN"))

    def test_short_latin_surname_is_not_nation(self):
        # «MA» — фамилия: до неё нет другой фамилии заглавными
        self.assertEqual(st.split_nation("Jimmy MA"), ("Jimmy MA", ""))

    def test_short_cyrillic_surname_is_not_nation(self):
        self.assertEqual(st.split_nation("Анна ЛИ"), ("Анна ЛИ", ""))

    def test_name_without_tail_is_unchanged(self):
        self.assertEqual(st.split_nation("Kaori SAKAMOTO"), ("Kaori SAKAMOTO", ""))

    def test_nation_with_digit(self):
        self.assertEqual(st.split_nation("Иван ИВАНОВ AIN2"), ("Иван ИВАНОВ", "AIN2"))

    def test_russian_region_after_pair(self):
        self.assertEqual(st.split_nation("Мария ПЕТРОВА / Пётр СИДОРОВ МОС"),
                         ("Мария ПЕТРОВА / Пётр СИДОРОВ", "МОС"))


# Строки протокола «Judges Details per Skater» (pdftotext -layout), по образцу scraper/fixtures/protocol/archive
HEAD_NO_NATION = "   1   Софья СМАГИНА   30   145.04   114.74   30.30   0.00"
HEAD_PAIR_ONE_SPACE = "   2   Deanna STELLATO-DUDEK / Maxime DESCHAMPS CAN   30   145.04   114.74   30.30   0.00"
HEAD_WITH_NATION = "          1   Vladislav DIKIDZHI                                       AIN2                  10           205.48           114.74              90.74                 0.00"
ELEMENT_3A = "   3   3A      8.80 {mark}   1.76   3 2 1 2 2 2 3   10.56"


class JudgesRow(unittest.TestCase):
    """Заголовок спортсмена в parse_judges: основной разбор с колонкой страны и запасной (JUDGES_PDF_ROW)."""

    def test_row_without_nation_column(self):
        rows = st.parse_judges(HEAD_NO_NATION)
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["name"], rows[0]["nation"]), ("Софья СМАГИНА", ""))
        self.assertEqual((rows[0]["tss"], rows[0]["tes"], rows[0]["pcs"], rows[0]["ded"]), (145.04, 114.74, 30.3, 0.0))

    def test_pair_with_one_space_before_nation(self):
        rows = st.parse_judges(HEAD_PAIR_ONE_SPACE)
        self.assertEqual((rows[0]["name"], rows[0]["nation"]), ("Deanna STELLATO-DUDEK / Maxime DESCHAMPS", "CAN"))

    def test_normal_row_with_nation_column(self):
        rows = st.parse_judges(HEAD_WITH_NATION)
        self.assertEqual((rows[0]["name"], rows[0]["nation"], rows[0]["tss"]), ("Vladislav DIKIDZHI", "AIN2", 205.48))

    def test_bonus_mark_b_after_element_sum(self):
        # «B» после суммы за элементы (российские старты 2020/21) — строка разбирается, B не мешает
        rows = st.parse_judges("   3   Иван ИВАНОВ AIN2   31   150.00   100.00 B   50.00   0.00")
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["name"], rows[0]["nation"]), ("Иван ИВАНОВ", "AIN2"))
        self.assertEqual((rows[0]["tes"], rows[0]["pcs"]), (100.0, 50.0))

    def test_decimal_comma_in_component_scores(self):
        text = HEAD_NO_NATION + "\nComposition   3,33   8,75   9,25   8,50   9,25   9,25   7,75   9,25   9,10"
        comp = st.parse_judges(text)[0]["components"]
        self.assertEqual(comp, [{"name": "Composition", "judges": [8.75, 9.25, 8.5, 9.25, 9.25, 7.75, 9.25]}])

    def test_capital_x_second_half_mark_same_as_lowercase(self):
        upper = st.parse_judges(HEAD_NO_NATION + "\n" + ELEMENT_3A.format(mark="X"))[0]["elements"]
        lower = st.parse_judges(HEAD_NO_NATION + "\n" + ELEMENT_3A.format(mark="x"))[0]["elements"]
        self.assertEqual(upper, lower)
        self.assertTrue(upper[0]["x"])
        self.assertEqual(upper[0]["base"], 8.8)



class TimesPdf(unittest.TestCase):
    def test_warmup_line_is_not_skater_two(self):
        # Гран-при России, Омск 2026: «2 -я РАЗМИНКА» затирала время второго по счёту (18:07 вместо 17:38)
        text = """17:25:00 - 17:32:00        1 -я РАЗМИНКА
17:32:30 - 17:38:20   1    Артемий МАРИНИН                                                      МОС
17:38:20 - 17:44:10   2    Арсений ДИМИТРИЕВ                                                    МОС
18:07:30 - 18:14:30        2 -я РАЗМИНКА
18:15:00 - 18:20:50   7    Илья СТРОГАНОВ                                                       СПБ
"""
        times, warm = st.parse_times_pdf_text(text)
        self.assertEqual(times, {1: (17, 32), 2: (17, 38), 7: (18, 15)})
        self.assertEqual(warm, {1: 1, 2: 1, 7: 2})

    def test_english_warmup_and_resurfacing(self):
        text = """Warm-Up Group 3
19:00:00 - 19:06:00   8    Kao MIURA   JPN
19:06:00 - 19:20:00   9    Ice Resurfacing
"""
        times, warm = st.parse_times_pdf_text(text)
        self.assertEqual(times, {8: (19, 0)})
        self.assertEqual(warm, {8: 3})

if __name__ == "__main__":
    unittest.main()
