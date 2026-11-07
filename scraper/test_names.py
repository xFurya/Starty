import unittest

from . import names as nm


class SpellingTest(unittest.TestCase):
    def test_homoglyphs_inside_russian_words(self):
        self.assertEqual(nm.pretty_ru("Семён Нетcев"), "Семён Нетсев")
        self.assertEqual(nm.pretty_ru("Алиса КРАЙНЮКОВА"), "Алиса Крайнюкова")
        # латинское слово не трогаем
        self.assertEqual(nm.cyr_word("Cirisano"), "Cirisano")

    def test_one_spelling(self):
        got = nm.one_spelling({"Петр Гуменник", "Пётр Гуменник", "Dmitri Aliev", "Дмитрий Алиев",
                               "Алиса Крайнюкова / Семён Нетcев", "Алиса Крайнюкова / Семён Нетсев",
                               "Алиса Крайнюкова / Семен Нетсев", "Ekaterina KUZNETSOVA",
                               "Ekaterina Kuznetcova", "Аливия Алиева"})
        self.assertEqual(got, {"Пётр Гуменник", "Дмитрий Алиев", "Алиса Крайнюкова / Семён Нетсев",
                               "Ekaterina Kuznetcova", "Аливия Алиева"})

    def test_one_spelling_tie_prefers_fresh(self):
        self.assertEqual(nm.one_spelling({"Maksim Varakin", "Maxim Varakin"}, fresh={"Maxim Varakin"}),
                         {"Maxim Varakin"})
        self.assertEqual(nm.one_spelling({"Maksim Varakin", "Maxim Varakin"}, fresh={"Maksim Varakin"}),
                         {"Maksim Varakin"})

    def test_dictionary_keeps_yo(self):
        n = nm.Names()
        n.add("Пётр Гуменник")
        n.add("Петр ГУМЕННИК")
        self.assertEqual(n.to_ru("Petr GUMENNIK"), "Пётр Гуменник")
        n = nm.Names()
        n.add("Петр Гуменник")
        n.add("Пётр Гуменник")
        self.assertEqual(n.to_ru("Petr GUMENNIK"), "Пётр Гуменник")


if __name__ == "__main__":
    unittest.main()
