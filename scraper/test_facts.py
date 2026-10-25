"""Примечательное по прокату: каскад и четверной аксель без отметок качества в тексте.
Запуск: python3 -m unittest scraper.test_facts"""
import unittest

from . import facts as fx


def texts(elements, kind="men", level="senior", seg="ПП"):
    return [t for _, t in fx.element_facts({"elements": elements, "components": []}, kind, level, seg)]


class CascadeText(unittest.TestCase):
    def test_under_rotation_mark_is_not_written(self):
        # недокрут «<» у второго прыжка каскада — не в тексте, сам каскад — да
        self.assertIn("Каскад 4T+3A+3A", texts([{"code": "4T+3A<+3A", "info": ""}]))

    def test_edge_and_quality_marks_are_not_written(self):
        got = texts([{"code": "4T<+3A!", "info": ""}])
        self.assertIn("Каскад 4T+3A", got)
        self.assertFalse(any("недокрут" in t or "ребро" in t for t in got))

    def test_quad_axel_without_under_rotation_words(self):
        got = texts([{"code": "4A<", "info": "e"}], kind="men", level="senior", seg="КП")
        self.assertNotIn("Четверной аксель, недокрут", got)
        self.assertIn("Четверной аксель", got)

    def test_plain_keeps_eu_and_drops_marks(self):
        self.assertEqual(fx._plain("4Lz<<"), "4Lz")
        self.assertEqual(fx._plain("Eu"), "Eu")


if __name__ == "__main__":
    unittest.main()
