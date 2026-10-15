"""Сегменты в расписаниях ФФККР: полные слова и сокращения (КП, ПП, РП, ПТ)."""
import unittest

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


if __name__ == "__main__":
    unittest.main()
