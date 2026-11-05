"""Отбор снимков с Викисклада для тех, у кого фото нет ни в одном реестре: только где человек один."""
import unittest

from scraper import hand

# Справочник: среди «своих» есть и партнёры, которых снимки называют вместе с человеком.
OTHERS = hand.known_names(["Roman Pleshkov", "Sergei Novitski", "Valeria Dementieva", "Alexei Novikov",
                           "Ilia Zimin", "Gregory Smith"])


def ok(title, name):
    return hand.rank(title, name, OTHERS) is not None


class Rank(unittest.TestCase):
    def test_alone_and_named(self):
        self.assertTrue(ok("Alexandra Ievleva - 2009 Russian Championships - 01.jpg", "Alexandra Ievleva"))
        self.assertTrue(ok("2010 World Figure Skating Championships Men - Alexandr KAZAKOV - 3773a.jpg",
                           "Alexandr Kazakov"))
        self.assertTrue(ok("2009 JGP Lake Placid Men Stepanov01.jpg", "Alexander Stepanov"))
        self.assertTrue(ok("Erokhov - 2018 Junior Worlds 01.jpg", "Alexey Erokhov"))
        self.assertTrue(ok("Ivan Ivanov Skate Canada 2019.jpg", "Ivan Ivanov"))

    def test_spellings_and_scripts(self):
        self.assertTrue(ok("2018 Rostelecom Cup Andrei Kutovoy IMG 9692.jpg", "Andrei Kutovoi"))
        self.assertTrue(ok("Gpf-lobasheva.jpg", "Irina Lobacheva"))
        self.assertTrue(ok("Илья Авербух в спектакле.jpg", "Ilia Averbukh"))
        self.assertTrue(ok("Анна Семенович (Белые ночи - 2023, день 2).jpg", "Anna Semenovich"))

    def test_not_named_is_dropped(self):
        for t in ("2015 Russian Cup - Stage 4 - 01.jpg", "Vladimir Putin 5 March 2002-1.jpg",
                  "2008 Christmas On Ice32.jpg", "Samokhinband 2023.jpg"):
            self.assertFalse(ok(t, "Denis Samokhin"), t)

    def test_partner_named_too_is_dropped(self):
        self.assertFalse(ok("Righi, Dubrovin - 2019 Junior Worlds - 1.jpg", "Aleksei DUBROVIN"))
        self.assertFalse(ok("2007 JGP USA Khodkova-Sliusarenko01.jpg", "Anastaisa Khodkova"))
        self.assertFalse(ok("Alina Pepeleva Roman Pleshkov 2019.jpg", "Alina Pepeleva"))
        self.assertFalse(ok("2013 Nebelhorn Trophy Angelina Telegina Otar Japaridze IMG 8017.JPG",
                            "Angelina TELEGINA"))
        self.assertFalse(ok("Golovina Voiko EC04.jpg", "Julia GOLOVINA"))
        self.assertFalse(ok("EC 2006 Khokhlova Novitski.jpg", "Jana Khokhlova"))
        self.assertFalse(ok("Tatiana Tarasova with Irina Moiseeva.jpg", "Irina Moiseeva"))
        self.assertFalse(ok("A & B Petrova.jpg", "Anna Petrova"))

    def test_namesake_is_dropped(self):
        # Тот же род, другое имя — другой человек.
        self.assertFalse(ok("2006 Campbell Cup Gregory Petukhov P1050948.jpg", "Denis PETUKHOV"))

    def test_crowds_are_dropped(self):
        for t in ("Pairs - Russian GP 2023, stage 2 - medals Sikharulidze.jpg", "2007-2008 JGPF Pairs Podium Sheremetieva.jpg",
                  "2011 WFSC Audience Sikharulidze.JPG", "Medals Ceremonies Sikharulidze.jpg"):
            self.assertFalse(ok(t, "Anton Sikharulidze"), t)

    def test_crop_for_this_person_wins(self):
        t = "2019 Russian Figure Skating Championships Valeria Dementieva Alexei Novikov (cropped) - Novikov.jpg"
        self.assertEqual(hand.rank(t, "Aleksei Novikov", OTHERS), 0)
        self.assertIsNone(hand.rank(t, "Valeria Dementieva", OTHERS))  # вырезан не её кадр
        self.assertEqual(hand.rank("Alena Kanysheva at the 2018 Grand Prix Final (cropped).jpg", "Alena Kanysheva", OTHERS), 1)

    def test_only_pictures(self):
        self.assertFalse(ok("Alexandra Ievleva.pdf", "Alexandra Ievleva"))
        self.assertFalse(ok("Alexandra Ievleva.ogv", "Alexandra Ievleva"))


class Files(unittest.TestCase):
    def test_order_and_limit(self):
        members = ["Ivan Ivanov 2009.jpg", "Ivan Ivanov 2019.jpg", "Ivan Ivanov, Petr Petrov.jpg",
                   "Anna Ivanova Ivan Ivanov (cropped) - Ivanov.jpg", "Ivan Ivanov 2012.jpg", "Ivan Ivanov 2015.jpg"]
        got = hand.files(members, "Ivan Ivanov", OTHERS)
        self.assertEqual(len(got), hand.PER_PERSON)
        self.assertIn("%28cropped%29_-_Ivanov", got[0])
        self.assertIn("2019", got[1])
        self.assertTrue(all("width=500" in u and "Petrov" not in u for u in got))


if __name__ == "__main__":
    unittest.main()
