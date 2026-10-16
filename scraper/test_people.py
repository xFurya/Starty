"""Справочник спортсменов: фильтры турниров и категорий, адреса табло, пары в списке ISU."""
import unittest
from unittest import mock

from scraper import net, people


class TournamentFilterTest(unittest.TestCase):
    def skipped(self, slug):
        return bool(people._SKIP_TOUR.search(slug.replace("-", " ")))

    def test_amateur_and_team_events_are_skipped(self):
        # названия из протоколов ФФККР, проверенные вручную: синхрон, балет, любительский кубок, межрегиональные
        for slug in [
            "kubok-rossii-po-sinkhronnomu-kataniyu-na-kon-kakh-2025-2026-gg-3-j-etap-syuyumbike",
            "vserossijskij-festival-po-sportivnym-baletam-na-l-du-final-2026",
            "vserossijskoe-fizkul-turnoe-meropriyatie-kubok-federatsii-sredi-vzroslykh-lyubitelej-final-2026",
            "mezhregional-nye-sorevnovaniya-pervenstvo-szfo-skfo-i-yufo-sredi-yunoshej-i-devushek-2026",
        ]:
            self.assertTrue(self.skipped(slug), slug)

    def test_sport_events_are_kept(self):
        for slug in [
            "vserossijskie-sorevnovaniya-kumparsita-vserossijskoe-fizkul-turnoe-meropriyatie-kumparsita-2026",
            "vserossijskie-sorevnovaniya-samarochka-2026",
            "pervenstvo-moskvy-2026",
        ]:
            self.assertFalse(self.skipped(slug), slug)


class CategoryFilterTest(unittest.TestCase):
    def skipped(self, name):
        return bool(people._SKIP_CAT.search(name.translate(people._HOMO)))

    def test_amateur_classes_are_skipped(self):
        for name in ["Одиночное катание, Класс I–III", "Женщины, Пре-бронза", "Молодежный класс"]:
            self.assertTrue(self.skipped(name), name)

    def test_ranked_categories_are_kept(self):
        for name in ["Женщины, КМС", "Юниорки, МС", "Юноши, КМС"]:
            self.assertFalse(self.skipped(name), name)


class AddressTest(unittest.TestCase):
    def test_cyrillic_host_becomes_punycode(self):
        url = net.ascii_url("https://роо-пкффкк.рф/ftp_tablo/197/index.htm")
        self.assertTrue(url.isascii())
        self.assertTrue(url.startswith("https://xn----"))
        self.assertTrue(url.endswith(".xn--p1ai/ftp_tablo/197/index.htm"))

    def test_ascii_address_is_unchanged(self):
        url = "https://fsrussia.ru/results/2526/1etap2026_adult/index.htm"
        self.assertEqual(net.ascii_url(url), url)

    def test_cyrillic_path_is_percent_encoded(self):
        url = net.ascii_url("https://example.org/протоколы/CAT001RS.HTM")
        self.assertTrue(url.isascii())
        self.assertIn("CAT001RS.HTM", url)


class IsuPairsTest(unittest.TestCase):
    """Пары и танцы в списке ISU: у строки пары имени нет, партнёры — в members."""

    def test_both_partners_are_listed(self):
        page = {
            "is_next_page": "N",
            "data": [
                {"skaters_type": "Single", "full_name": "Alina GORINA", "nationality_code": "RUS",
                 "status": "Active"},
                {"skaters_type": "Team", "full_name": None, "nf_organization_code": "RUS", "status": "Active",
                 "members": [
                     {"full_name": "Albina SOKUR", "nationality_code": "RUS"},
                     {"full_name": "Roman PLESHKOV"},
                 ]},
                {"skaters_type": "Team", "full_name": None, "nf_organization_code": "USA", "status": "Active",
                 "members": [{"full_name": "Jane DOE"}]},
            ],
        }
        with mock.patch.object(net, "fetch_json", return_value=page):
            got = {name: (nation, org) for name, nation, org in people.isu_russians(log=lambda *a: None)}
        self.assertEqual(set(got), {"Alina GORINA", "Albina SOKUR", "Roman PLESHKOV"})
        self.assertEqual(got["Roman PLESHKOV"], ("RUS", "RUS"))


if __name__ == "__main__":
    unittest.main()


class WikidataLabelTest(unittest.TestCase):
    def test_label_forms(self):
        f = people.wikidata_label
        self.assertEqual(f("Ксения Алексеевна Синицына", "ru"), "Ксения Синицына")
        self.assertEqual(f("Павлова, Наталья Евгеньевна", "ru"), "Наталья Павлова")
        self.assertEqual(f("Kseniya Sinitsina", "en"), "Kseniya Sinitsina")
