"""Проверки разбора табло: python3 -m unittest scraper.test_swisstiming"""
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


if __name__ == "__main__":
    unittest.main()
